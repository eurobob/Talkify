import Foundation
import OSLog

/// Reads the Siri Remote's clickpad.
///
/// The pad is not a HID digitizer. macOS presents it through
/// `MultitouchSupport`, which is why every HID probe watched the remote's
/// digitizer interface stay silent while the pad was being swiped. That
/// framework is private and lives in the dyld shared cache, so every symbol
/// is resolved by hand at launch: a symbol that disappears in a macOS
/// update has to become a logged line and a dead feature, never a crash in
/// a dictation app.
///
/// The clickpad's press is not read here. It arrives as an ordinary HID
/// button — `select` — through `SiriRemoteButtonMonitor`, which is what
/// lets a click be held still while the finger is still on the pad.
final class SiriRemoteTouchpad: @unchecked Sendable {
  /// One frame from the pad.
  struct Touch: Sendable, Equatable {
    /// Position across the pad, 0 to 1, origin bottom left.
    let x: Float
    let y: Float
    /// How many fingers the pad currently reports. Zero means the last one
    /// lifted, which is the only reliable end-of-gesture signal.
    let contacts: Int
  }

  enum StartResult: Sendable, Equatable {
    case started
    /// The framework or one of its symbols is gone. Expected one day: this
    /// is a private API.
    case frameworkUnavailable
    /// No pad with the remote's sensor family is present.
    case noRemoteFound
  }

  /// The remote's clickpad reports this sensor family. The built-in
  /// trackpad reports 105, so the family separates them without depending
  /// on the order the framework happens to list devices in.
  private static let remoteFamily: Int32 = 145

  /// Byte offsets into the frame the callback receives. The layout is not
  /// published, so these are read as offsets rather than declared as a
  /// struct: a struct definition would compile and quietly read the wrong
  /// bytes. Measured against a live remote on 2026-08-20.
  private enum Offset {
    static let x = 32
    static let y = 36
  }

  private typealias DeviceRef = UnsafeMutableRawPointer
  private typealias ContactCallback = @convention(c) (
    DeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32
  ) -> Int32

  private struct Symbols {
    let createList: @convention(c) () -> CFMutableArray?
    let registerCallback: @convention(c) (DeviceRef, ContactCallback) -> Void
    let start: @convention(c) (DeviceRef, Int32) -> Void
    let stop: @convention(c) (DeviceRef) -> Void
    let familyID: @convention(c) (DeviceRef, UnsafeMutablePointer<Int32>) -> Int32

    init?(handle: UnsafeMutableRawPointer) {
      func load(_ name: String) -> UnsafeMutableRawPointer? {
        guard let symbol = dlsym(handle, name) else {
          RemoteInputLog.logger.error(
            "MultitouchSupport has no \(name, privacy: .public)"
          )
          return nil
        }
        return symbol
      }

      guard let createList = load("MTDeviceCreateList"),
            let register = load("MTRegisterContactFrameCallback"),
            let start = load("MTDeviceStart"),
            let stop = load("MTDeviceStop"),
            let family = load("MTDeviceGetFamilyID")
      else { return nil }

      self.createList = unsafeBitCast(createList, to: (@convention(c) () -> CFMutableArray?).self)
      self.registerCallback = unsafeBitCast(
        register, to: (@convention(c) (DeviceRef, ContactCallback) -> Void).self
      )
      self.start = unsafeBitCast(start, to: (@convention(c) (DeviceRef, Int32) -> Void).self)
      self.stop = unsafeBitCast(stop, to: (@convention(c) (DeviceRef) -> Void).self)
      self.familyID = unsafeBitCast(
        family, to: (@convention(c) (DeviceRef, UnsafeMutablePointer<Int32>) -> Int32).self
      )
    }
  }

  private let handler: @Sendable (Touch) -> Void
  private let stateLock = NSLock()

  private var symbols: Symbols?
  private var startedDevices: [DeviceRef] = []

  init(handler: @escaping @Sendable (Touch) -> Void) {
    self.handler = handler
  }

  deinit {
    stop()
  }

  @discardableResult
  func start() -> StartResult {
    stop()

    let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
    guard let handle = dlopen(path, RTLD_LAZY), let symbols = Symbols(handle: handle) else {
      RemoteInputLog.logger.error("could not load MultitouchSupport")
      return .frameworkUnavailable
    }
    stateLock.withLock { self.symbols = symbols }

    guard let list = symbols.createList() else { return .noRemoteFound }

    // The callback is a C function pointer and cannot capture, so the
    // instance is reached through a file-scope reference rather than a
    // context pointer: MTRegisterContactFrameCallback takes no context.
    activeTouchpad = self

    var found = false
    for index in 0..<CFArrayGetCount(list) {
      guard let value = CFArrayGetValueAtIndex(list, index) else { continue }
      let device = DeviceRef(mutating: value)

      var family: Int32 = 0
      _ = symbols.familyID(device, &family)
      guard family == Self.remoteFamily else { continue }

      symbols.registerCallback(device, touchpadCallback)
      symbols.start(device, 0)
      stateLock.withLock { startedDevices.append(device) }
      found = true
      RemoteInputLog.logger.info("clickpad started, family \(family)")
    }

    return found ? .started : .noRemoteFound
  }

  func stop() {
    let (symbols, devices) = stateLock.withLock { () -> (Symbols?, [DeviceRef]) in
      let currentSymbols = self.symbols
      let currentDevices = startedDevices
      startedDevices = []
      return (currentSymbols, currentDevices)
    }

    guard let symbols else { return }
    for device in devices {
      symbols.stop(device)
    }
    if activeTouchpad === self { activeTouchpad = nil }
  }

  fileprivate func receive(_ touches: UnsafeMutableRawPointer?, count: Int32) {
    // A frame with no contacts is the end of a gesture, and the only
    // reliable one: it must reach the handler even though there is no
    // position to read.
    guard let touches, count > 0 else {
      handler(Touch(x: 0, y: 0, contacts: 0))
      return
    }

    handler(
      Touch(
        x: touches.load(fromByteOffset: Offset.x, as: Float.self),
        y: touches.load(fromByteOffset: Offset.y, as: Float.self),
        contacts: Int(count)
      )
    )
  }
}

/// The one touchpad currently started. `MTRegisterContactFrameCallback`
/// accepts no context pointer, so the callback has no way back to an
/// instance other than this. Only one remote exists, so only one is ever
/// wanted.
private nonisolated(unsafe) weak var activeTouchpad: SiriRemoteTouchpad?

private let touchpadCallback: @convention(c) (
  UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32 = { _, touches, count, _, _ in
  activeTouchpad?.receive(touches, count: count)
  return 0
}
