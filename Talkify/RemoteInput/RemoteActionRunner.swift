import AppKit
import CoreGraphics

/// Sends a recorded key combination, so a Siri Remote button can do
/// anything the keyboard can.
///
/// The combination is posted as a synthetic key press rather than being
/// interpreted here. That keeps this to one function whatever the user
/// records, and it means a shortcut they have rebound in System Settings,
/// or one that belongs to whichever app is in front, works without this
/// app knowing anything about it.
///
/// Posting events needs Accessibility, which dictation's event tap already
/// requires.
enum RemoteActionRunner {
  @MainActor
  static func send(_ binding: KeyBinding) {
    // A bare modifier has nothing to press. The recorder refuses to record
    // one for a remote button, and this is the matching guard.
    guard !binding.isModifierKey else { return }

    // The combined session state, matching the paste keystroke in
    // TextInsertionService that is known to work on this Mac. A
    // hidSystemState source builds the same event and delivers nothing.
    let key = CGKeyCode(binding.keyCode)
    guard let source = CGEventSource(stateID: .combinedSessionState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
    else { return }

    down.flags = binding.modifiers
    up.flags = binding.modifiers
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }
}
