import AppKit
import CoreGraphics

/// Runs the Siri Remote actions that belong to macOS rather than to
/// dictation: Mission Control, the window views, Spotlight.
///
/// Each one is the keyboard shortcut macOS already ships, posted as a
/// synthetic key press. That keeps this to a table of key codes instead of
/// a set of private calls, and it obeys whatever the user has rebound the
/// shortcut to in System Settings. Posting events needs Accessibility,
/// which dictation's event tap already requires.
enum RemoteActionRunner {
  /// The virtual key codes behind the shortcuts, from Carbon's
  /// `Events.h`. They are positions on the keyboard, not letters, so they
  /// hold for every layout.
  private enum KeyCode {
    static let upArrow: CGKeyCode = 126
    static let downArrow: CGKeyCode = 125
    static let f11: CGKeyCode = 103
    static let space: CGKeyCode = 49
  }

  /// Runs `action`, or returns false when it is not one of ours. Dictation
  /// actions are not handled here: they belong to the dictation controller,
  /// which owns the session.
  @MainActor
  @discardableResult
  static func run(_ action: RemoteButtonAction) -> Bool {
    switch action {
    case .missionControl:
      post(KeyCode.upArrow, flags: .maskControl)
    case .applicationWindows:
      post(KeyCode.downArrow, flags: .maskControl)
    case .showDesktop:
      post(KeyCode.f11, flags: [])
    case .spotlight:
      post(KeyCode.space, flags: .maskCommand)
    case .none, .dictateHold, .dictateToggle, .cancelDictation, .readAloud:
      return false
    }
    return true
  }

  private static func post(_ key: CGKeyCode, flags: CGEventFlags) {
    // The HID session, so the events land the way a real keyboard's do.
    // A tap-level source is filtered out by some of the system's own
    // shortcut handling, Mission Control included.
    let source = CGEventSource(stateID: .hidSystemState)

    guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
    else { return }

    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }
}
