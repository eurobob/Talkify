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
    /// The pad's own identifier for this finger. It survives for the life
    /// of one contact, so a change means a different finger is being
    /// reported — and the distance between two fingers is not a movement.
    let identifier: Int
    /// Where the finger is in its life: landing, settled, or lifting. Only
    /// a settled finger has a position worth acting on.
    let state: Int

    /// True once the pad is confident where the finger is. A landing or
    /// lifting finger reports a position that is still being estimated,
    /// and acting on it is what throws the pointer across the screen the
    /// instant the pad is touched.
    var isSettled: Bool { state == Self.settledState }

    /// MultitouchSupport's "touching" state. The states either side of it
    /// are the transitional ones.
    private static let settledState = 4
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
    static let identifier = 16
    static let state = 20
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
    let deviceID: @convention(c) (DeviceRef, UnsafeMutablePointer<UInt64>) -> Int32

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
            let family = load("MTDeviceGetFamilyID"),
            let identifier = load("MTDeviceGetDeviceID")
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
      self.deviceID = unsafeBitCast(
        identifier, to: (@convention(c) (DeviceRef, UnsafeMutablePointer<UInt64>) -> Int32).self
      )
    }
  }

  private let handler: @Sendable (Touch) -> Void
  private let stateLock = NSLock()

  private var symbols: Symbols?
  /// Keyed by the pad's own identifier, not by pointer. Every call to
  /// MTDeviceCreateList hands back fresh references for the same hardware,
  /// so comparing pointers makes the pad look new on every scan: it is
  /// restarted several times a second and delivers nothing.
  private var startedDevices: [UInt64: DeviceRef] = [:]
  /// Re-scans for the pad. The remote drops its connection whenever it
  /// idles — hundreds of times a day — and comes back as a new multitouch
  /// device. Enumerating once at launch means the pointer works until the
  /// first time the remote sleeps and never again, while the buttons keep
  /// working and hide the fault: the button monitor has a matching
  /// callback for exactly this, and MultitouchSupport offers none.
  private var rescanTimer: DispatchSourceTimer?
  private static let rescanInterval: DispatchTimeInterval = .seconds(3)

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

    let found = attachNewDevices(symbols: symbols)
    startRescanning()

    // Not finding it now is not a failure: the remote is asleep more often
    // than it is awake, and the re-scan picks it up when it returns.
    return found ? .started : .noRemoteFound
  }

  /// Starts any pad that is present and not already running. Returns
  /// whether one is running by the end.
  @discardableResult
  private func attachNewDevices(symbols: Symbols) -> Bool {
    guard let list = symbols.createList() else { return false }

    var present: [UInt64: DeviceRef] = [:]
    for index in 0..<CFArrayGetCount(list) {
      guard let value = CFArrayGetValueAtIndex(list, index) else { continue }
      let device = DeviceRef(mutating: value)

      var family: Int32 = 0
      _ = symbols.familyID(device, &family)
      guard family == Self.remoteFamily else { continue }

      var identifier: UInt64 = 0
      _ = symbols.deviceID(device, &identifier)
      present[identifier] = device
    }

    // A pad that has gone is forgotten, so its return counts as new.
    let added: [DeviceRef] = stateLock.withLock {
      for identifier in startedDevices.keys where present[identifier] == nil {
        startedDevices[identifier] = nil
        RemoteInputLog.logger.info("clickpad detached")
      }
      var new: [DeviceRef] = []
      for (identifier, device) in present where startedDevices[identifier] == nil {
        startedDevices[identifier] = device
        new.append(device)
      }
      return new
    }

    for device in added {
      symbols.registerCallback(device, touchpadCallback)
      symbols.start(device, 0)
      RemoteInputLog.logger.info("clickpad attached")
    }

    return stateLock.withLock { !startedDevices.isEmpty }
  }

  private func startRescanning() {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + Self.rescanInterval, repeating: Self.rescanInterval)
    timer.setEventHandler { [weak self] in
      guard let self, let symbols = stateLock.withLock({ self.symbols }) else { return }
      attachNewDevices(symbols: symbols)
    }
    timer.resume()
    rescanTimer = timer
  }

  func stop() {
    rescanTimer?.cancel()
    rescanTimer = nil

    let (symbols, devices) = stateLock.withLock { () -> (Symbols?, [DeviceRef]) in
      let currentSymbols = self.symbols
      let currentDevices = Array(startedDevices.values)
      startedDevices = [:]
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
      handler(Touch(x: 0, y: 0, contacts: 0, identifier: 0, state: 0))
      return
    }

    handler(
      Touch(
        x: touches.load(fromByteOffset: Offset.x, as: Float.self),
        y: touches.load(fromByteOffset: Offset.y, as: Float.self),
        contacts: Int(count),
        identifier: Int(touches.load(fromByteOffset: Offset.identifier, as: Int32.self)),
        state: Int(touches.load(fromByteOffset: Offset.state, as: Int32.self))
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
