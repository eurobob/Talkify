import Foundation
import IOKit
import IOKit.hid

/// Reads the Siri Remote's buttons straight from IOKit HID.
///
/// macOS pairs the remote as a HID device, but it routes none of the
/// remote's buttons through the CGEvent tap. `GlobalKeyEventMonitor`
/// therefore never sees them, and this monitor opens the device itself.
///
/// The remote publishes seven HID interfaces. One carries every button:
/// usage page `0x0C` (Consumer), usage `0x01`, report ID 251, three bytes
/// per report. The other six stay silent for a third-party process. The
/// microphone is the one that matters here, and it never arrives: the
/// remote sends its audio over the Bluetooth link, and macOS keeps that
/// stream to itself. So `siri` below is a trigger and nothing more. The
/// audio reaches the app as an ordinary input device instead; see
/// `AudioInputDevice`.
///
/// The device needs the Input Monitoring permission, which the event tap
/// already requires.
final class SiriRemoteButtonMonitor: @unchecked Sendable {
  /// A button on the remote, named as the case on the device reads.
  enum Button: Sendable, Hashable, CaseIterable {
    case up
    case down
    case left
    case right
    case select
    case back
    case tv
    case playPause
    case mute
    case volumeUp
    case volumeDown
    case power
    case siri
  }

  enum Event: Sendable {
    case pressed(Button)
    case released(Button)
  }

  /// Apple's vendor, and the product of the third-generation remote
  /// (A2854). Earlier remotes report a different product and are untested.
  private static let vendorID = 0x004C
  private static let productID = 0x0315

  /// Measured on an A2854 on 2026-08-20. The clickpad reports its four
  /// edges as Consumer menu directions, and its click as Selection.
  private static let buttonsByUsage: [UInt64: Button] = [
    key(page: 0x0C, usage: 0x0042): .up,
    key(page: 0x0C, usage: 0x0043): .down,
    key(page: 0x0C, usage: 0x0044): .left,
    key(page: 0x0C, usage: 0x0045): .right,
    key(page: 0x0C, usage: 0x0080): .select,
    key(page: 0x0C, usage: 0x0060): .back,
    key(page: 0x01, usage: 0x0086): .tv,
    key(page: 0x0C, usage: 0x00CD): .playPause,
    key(page: 0x0C, usage: 0x00E2): .mute,
    key(page: 0x0C, usage: 0x00E9): .volumeUp,
    key(page: 0x0C, usage: 0x00EA): .volumeDown,
    key(page: 0x0C, usage: 0x0030): .power,
    key(page: 0x0C, usage: 0x0004): .siri,
  ]

  private static func key(page: UInt32, usage: UInt32) -> UInt64 {
    UInt64(page) << 32 | UInt64(usage)
  }

  private let handler: @Sendable (Event) -> Void
  private let stateLock = NSLock()

  private var manager: IOHIDManager?
  /// Which buttons are down, so a repeated report cannot open a second
  /// session under the first one.
  private var heldButtons: Set<Button> = []

  init(handler: @escaping @Sendable (Event) -> Void) {
    self.handler = handler
  }

  deinit {
    stop()
  }

  /// Opens the remote and starts to report presses. Returns false when
  /// macOS refuses the device, which in practice means the Input
  /// Monitoring permission is missing.
  ///
  /// A remote that is asleep or out of range is not a failure: the manager
  /// matches it whenever it comes back, so start() still returns true.
  @discardableResult
  func start() -> Bool {
    stop()

    let manager = IOHIDManagerCreate(
      kCFAllocatorDefault,
      IOOptionBits(kIOHIDOptionsTypeNone)
    )
    let matching: [String: Any] = [
      kIOHIDVendorIDKey: Self.vendorID,
      kIOHIDProductIDKey: Self.productID,
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

    guard IOHIDManagerOpen(
      manager,
      IOOptionBits(kIOHIDOptionsTypeNone)
    ) == kIOReturnSuccess else {
      return false
    }

    let context = Unmanaged.passUnretained(self).toOpaque()
    IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
      guard let context else { return }
      Unmanaged<SiriRemoteButtonMonitor>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receive(value)
    }, context)

    IOHIDManagerScheduleWithRunLoop(
      manager,
      CFRunLoopGetMain(),
      CFRunLoopMode.commonModes.rawValue
    )

    stateLock.withLock { self.manager = manager }
    return true
  }

  func stop() {
    let manager = stateLock.withLock { () -> IOHIDManager? in
      let current = self.manager
      self.manager = nil
      heldButtons.removeAll()
      return current
    }

    guard let manager else { return }
    IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
    IOHIDManagerUnscheduleFromRunLoop(
      manager,
      CFRunLoopGetMain(),
      CFRunLoopMode.commonModes.rawValue
    )
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
  }

  private func receive(_ value: IOHIDValue) {
    let element = IOHIDValueGetElement(value)
    let usage = Self.key(
      page: IOHIDElementGetUsagePage(element),
      usage: IOHIDElementGetUsage(element)
    )
    guard let button = Self.buttonsByUsage[usage] else { return }

    let isDown = IOHIDValueGetIntegerValue(value) != 0
    let changed = stateLock.withLock { () -> Bool in
      if isDown {
        return heldButtons.insert(button).inserted
      }
      return heldButtons.remove(button) != nil
    }

    guard changed else { return }
    handler(isDown ? .pressed(button) : .released(button))
  }
}
