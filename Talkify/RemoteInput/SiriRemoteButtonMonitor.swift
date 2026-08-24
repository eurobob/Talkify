import OSLog
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
  /// A button on the remote, named as the case on the device reads. The
  /// raw values are stored in the button map, so they must not change.
  enum Button: String, Sendable, Hashable, CaseIterable, Codable {
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

    /// What the button is called on the device, for the Settings list.
    var title: String {
      switch self {
      case .up: "Clickpad up"
      case .down: "Clickpad down"
      case .left: "Clickpad left"
      case .right: "Clickpad right"
      case .select: "Clickpad press"
      case .back: "Back"
      case .tv: "TV"
      case .playPause: "Play / Pause"
      case .mute: "Mute"
      case .volumeUp: "Volume up"
      case .volumeDown: "Volume down"
      case .power: "Power"
      case .siri: "Siri"
      }
    }
  }

  enum Event: Sendable {
    case pressed(Button)
    case released(Button)
  }

  /// Why the buttons are not arriving. Every case is worth telling the user
  /// about: each one leaves the remote silent, and none of them is
  /// something the user can see for themselves.
  enum StartResult: Sendable, Equatable {
    case started
    /// macOS refused the device. In practice: no Input Monitoring.
    case permissionDenied
    /// Another running app holds the button interface. BetterTouchTool and
    /// GoatRemote both do this when they are configured for the remote.
    case buttonsHeldByAnotherApp
    /// No remote is paired, or it is asleep and has not reconnected.
    case noRemoteFound
  }

  /// Apple's vendor, and the product of the third-generation remote
  /// (A2854). Earlier remotes report a different product and are untested.
  private static let vendorID = 0x004C
  private static let productID = 0x0315

  /// The one interface that carries the buttons.
  private static let buttonUsagePage = 0x0C
  private static let buttonUsage = 0x01

  /// Measured on an A2854 on 2026-08-20. The clickpad reports its four
  /// edges as Consumer menu directions, and its click as Selection.
  private static let buttonsByUsage: [UInt64: Button] = [
    key(page: 0x0C, usage: 0x0042): .up,
    key(page: 0x0C, usage: 0x0043): .down,
    key(page: 0x0C, usage: 0x0044): .left,
    key(page: 0x0C, usage: 0x0045): .right,
    key(page: 0x0C, usage: 0x0080): .select,
    // Named from the remote, not from the usage numbers. The Consumer
    // "Data On Screen" usage is the TV button and Generic Desktop's
    // "System App Menu" is Back, which is the opposite of what those names
    // suggest. Confirmed against the physical remote on 2026-08-20.
    key(page: 0x0C, usage: 0x0060): .tv,
    key(page: 0x01, usage: 0x0086): .back,
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
  /// The interfaces this monitor has opened and scheduled. Identity, not
  /// usage, because a remote that sleeps and reconnects presents new
  /// device objects for the same seven interfaces and every one of them
  /// must be registered again.
  private var openDevices: [IOHIDDevice] = []
  /// Retries devices that would not open.
  ///
  /// The usual reason is that another app has seized the buttons —
  /// BetterTouchTool does, and it starts at login like this app, so which
  /// one wins is a race. Without a retry the loser stays blind until it is
  /// relaunched, so quitting the other app appears to fix nothing and the
  /// remote looks unreliable rather than contended.
  private var retryTimer: DispatchSourceTimer?
  private static let retryInterval: DispatchTimeInterval = .seconds(3)
  /// True once the buttons have been reported as taken, so reclaiming them
  /// is logged as the event it is rather than in silence.
  private var hasReportedSeizure = false
  /// Which buttons are down, so a repeated report cannot open a second
  /// session under the first one.
  private var heldButtons: Set<Button> = []

  init(handler: @escaping @Sendable (Event) -> Void) {
    self.handler = handler
  }

  deinit {
    stop()
  }

  /// Opens the remote and starts to report presses.
  ///
  /// Every interface is opened on its own rather than through the manager.
  /// `IOHIDManagerOpen` reports failure when any single matched interface
  /// is held by another process, and the remote has seven: reading that
  /// one result as fatal throws away six working interfaces and, worse,
  /// gives no clue which one was the problem.
  @discardableResult
  func start() -> StartResult {
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

    let context = Unmanaged.passUnretained(self).toOpaque()
    // A remote that wakes from sleep arrives here, which is the normal way
    // it comes back: the link drops whenever the remote idles.
    IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
      guard let context else { return }
      _ = Unmanaged<SiriRemoteButtonMonitor>
        .fromOpaque(context)
        .takeUnretainedValue()
        .register(device)
    }, context)
    IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
      guard let context else { return }
      Unmanaged<SiriRemoteButtonMonitor>
        .fromOpaque(context)
        .takeUnretainedValue()
        .forget(device)
    }, context)

    let managerOpen = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerScheduleWithRunLoop(
      manager,
      CFRunLoopGetMain(),
      CFRunLoopMode.commonModes.rawValue
    )
    stateLock.withLock { self.manager = manager }
    startRetrying()

    let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
    guard !devices.isEmpty else {
      return managerOpen == kIOReturnNotPermitted ? .permissionDenied : .noRemoteFound
    }

    var buttonResult: IOReturn?
    for device in devices {
      let result = register(device)
      if isButtonInterface(device) {
        buttonResult = result
      }
    }

    switch buttonResult {
    case kIOReturnSuccess: return .started
    case kIOReturnNotPermitted: return .permissionDenied
    case kIOReturnExclusiveAccess: return .buttonsHeldByAnotherApp
    case nil: return .noRemoteFound
    default:
      return managerOpen == kIOReturnNotPermitted ? .permissionDenied : .noRemoteFound
    }
  }

  /// Keeps trying to open anything that is matched but not yet open, so
  /// the buttons are picked up within seconds of whatever held them
  /// letting go.
  private func startRetrying() {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + Self.retryInterval, repeating: Self.retryInterval)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let manager = stateLock.withLock { self.manager }
      guard let manager else { return }

      for device in (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [] {
        let alreadyOpen = stateLock.withLock {
          openDevices.contains { $0 === device }
        }
        guard !alreadyOpen else { continue }

        let result = register(device)
        guard isButtonInterface(device) else { continue }

        if result == kIOReturnSuccess, hasReportedSeizure {
          hasReportedSeizure = false
          RemoteInputLog.logger.info("buttons reclaimed")
        } else if result == kIOReturnExclusiveAccess, !hasReportedSeizure {
          hasReportedSeizure = true
          RemoteInputLog.logger.error("buttons seized by another app")
        }
      }
    }
    timer.resume()
    retryTimer = timer
  }

  func stop() {
    retryTimer?.cancel()
    retryTimer = nil

    let (manager, devices) = stateLock.withLock { () -> (IOHIDManager?, [IOHIDDevice]) in
      let current = self.manager
      let open = openDevices
      self.manager = nil
      openDevices = []
      heldButtons.removeAll()
      return (current, open)
    }

    for device in devices {
      IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
      IOHIDDeviceUnscheduleFromRunLoop(
        device,
        CFRunLoopGetMain(),
        CFRunLoopMode.commonModes.rawValue
      )
      IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    guard let manager else { return }
    IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
    IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
    IOHIDManagerUnscheduleFromRunLoop(
      manager,
      CFRunLoopGetMain(),
      CFRunLoopMode.commonModes.rawValue
    )
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
  }

  /// Opens one interface and starts to read it. Doing this twice for the
  /// same interface is harmless and expected: the matching callback fires
  /// for interfaces the first enumeration already found.
  @discardableResult
  private func register(_ device: IOHIDDevice) -> IOReturn {
    let isNew = stateLock.withLock { () -> Bool in
      guard !openDevices.contains(where: { $0 === device }) else { return false }
      return true
    }
    guard isNew else { return kIOReturnSuccess }

    let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
    guard result == kIOReturnSuccess else { return result }

    let context = Unmanaged.passUnretained(self).toOpaque()
    IOHIDDeviceRegisterInputValueCallback(device, { context, _, _, value in
      guard let context else { return }
      Unmanaged<SiriRemoteButtonMonitor>
        .fromOpaque(context)
        .takeUnretainedValue()
        .receive(value)
    }, context)
    IOHIDDeviceScheduleWithRunLoop(
      device,
      CFRunLoopGetMain(),
      CFRunLoopMode.commonModes.rawValue
    )

    stateLock.withLock { openDevices.append(device) }
    return kIOReturnSuccess
  }

  /// A remote that sleeps takes its interfaces with it. Any button still
  /// marked down would otherwise stay down forever, and the next press of
  /// it would be swallowed as a repeat.
  private func forget(_ device: IOHIDDevice) {
    stateLock.withLock {
      openDevices.removeAll { $0 === device }
      heldButtons.removeAll()
    }
  }

  private func isButtonInterface(_ device: IOHIDDevice) -> Bool {
    let page = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
    let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int
    return page == Self.buttonUsagePage && usage == Self.buttonUsage
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
    RemoteInputLog.logger.info(
      "button \(button.rawValue, privacy: .public) \(isDown ? "down" : "up", privacy: .public)"
    )
    handler(isDown ? .pressed(button) : .released(button))
  }
}
