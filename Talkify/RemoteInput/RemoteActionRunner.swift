import OSLog
import ApplicationServices
import AppKit
import CoreGraphics

/// Sends a recorded key combination, so a Siri Remote button can do
/// anything the keyboard can.
///
/// The combination is posted as synthetic key events rather than being
/// interpreted here. That keeps this to one function whatever the user
/// records, and it means a shortcut they have rebound in System Settings,
/// or one that belongs to whichever app is in front, works without this
/// app knowing anything about it.
///
/// Posting events needs Accessibility, which dictation's event tap already
/// requires, plus permission to post events, which is a separate grant.
enum RemoteActionRunner {
  /// Virtual key codes for the modifiers, from Carbon's `Events.h`. They
  /// are positions on the keyboard, so they hold for every layout.
  private enum ModifierKey {
    static let command: CGKeyCode = 55
    static let shift: CGKeyCode = 56
    static let option: CGKeyCode = 58
    static let control: CGKeyCode = 59
  }

  /// Posting runs off the main thread because the sequence has to be paced.
  /// Serial, so two quick presses cannot interleave their modifiers and
  /// leave one held down.
  private static let queue = DispatchQueue(label: "digital.chaotic.remote-keys")

  /// Long enough that the system registers each edge as a real one, short
  /// enough to feel instant. A press with no duration is discarded by many
  /// apps, and by the window manager in particular.
  private static let step: useconds_t = 18_000

  @MainActor
  static func send(_ binding: KeyBinding) {
    // A bare modifier has nothing to press. The recorder refuses to record
    // one for a remote button, and this is the matching guard.
    // Nothing recorded yet: the button stays inert rather than pressing
    // whatever the placeholder happened to be.
    guard !binding.isUnrecorded else {
      RemoteInputLog.logger.info("button has no combination recorded yet")
      return
    }

    guard !binding.isModifierKey else {
      RemoteInputLog.logger.error("refused a bare modifier: \(binding.label, privacy: .public)")
      return
    }

    guard CGPreflightPostEventAccess() else {
      RemoteInputLog.logger.error("not allowed to post key events — asking for permission now")
      _ = CGRequestPostEventAccess()
      return
    }

    let key = CGKeyCode(binding.keyCode)
    let flags = binding.modifiers
    let label = binding.label

    queue.async {
      post(key: key, flags: flags)
      RemoteInputLog.logger.info(
        "sent \(label, privacy: .public) keyCode=\(binding.keyCode) flags=\(binding.modifierFlags)"
      )
    }
  }

  /// Presses the combination the way a keyboard does: each modifier goes
  /// down as its own key event, then the key, then everything lifts in
  /// reverse.
  ///
  /// Setting the flags on the key event alone is not enough for the
  /// system's own shortcuts. Mission Control and its neighbours are handled
  /// by the window server, which watches the modifiers go down as events in
  /// their own right; given only a flagged arrow key it does nothing at
  /// all, while an ordinary app receiving the same event acts on it. That
  /// is why Return worked and Control-Up did not.
  private static func post(key: CGKeyCode, flags: CGEventFlags) {
    let source = CGEventSource(stateID: .combinedSessionState)

    var held: [CGKeyCode] = []
    if flags.contains(.maskControl) { held.append(ModifierKey.control) }
    if flags.contains(.maskAlternate) { held.append(ModifierKey.option) }
    if flags.contains(.maskShift) { held.append(ModifierKey.shift) }
    if flags.contains(.maskCommand) { held.append(ModifierKey.command) }

    // Each modifier arrives carrying every modifier already down, which is
    // what a real keyboard reports.
    var accumulated: CGEventFlags = []
    for modifier in held {
      accumulated.insert(flag(for: modifier))
      emit(modifier, down: true, flags: accumulated, source: source)
    }

    emit(key, down: true, flags: flags, source: source)
    emit(key, down: false, flags: flags, source: source)

    for modifier in held.reversed() {
      accumulated.remove(flag(for: modifier))
      emit(modifier, down: false, flags: accumulated, source: source)
    }
  }

  private static func emit(
    _ key: CGKeyCode,
    down: Bool,
    flags: CGEventFlags,
    source: CGEventSource?
  ) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else {
      return
    }
    event.flags = flags
    event.post(tap: .cghidEventTap)
    usleep(step)
  }

  private static func flag(for modifier: CGKeyCode) -> CGEventFlags {
    switch modifier {
    case ModifierKey.command: .maskCommand
    case ModifierKey.shift: .maskShift
    case ModifierKey.option: .maskAlternate
    default: .maskControl
    }
  }
}
