import OSLog

/// One log for the Siri Remote path.
///
/// The remote crosses three boundaries before anything happens — the HID
/// device, the button map, and a posted keystroke — and a failure at any of
/// them looks identical from the outside: the button does nothing. This
/// makes each step say what it did, so the next fault is read rather than
/// guessed at.
///
/// Read it with:
///
///     log stream --predicate 'subsystem == "digital.chaotic.RemoteInput"'
enum RemoteInputLog {
  static let logger = Logger(
    subsystem: "digital.chaotic.RemoteInput",
    category: "remote"
  )
}
