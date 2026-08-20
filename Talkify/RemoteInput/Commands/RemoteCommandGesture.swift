import Foundation

/// Recognises the Siri button's gestures.
///
/// The button does two jobs and they must never be confused: held, it
/// dictates; tapped twice, it listens for a command. Both start with the
/// same press, so the difference is decided by what happens next.
///
/// Pure, so the timing rules can be pinned by tests rather than by holding
/// a button and hoping.
struct RemoteCommandGesture {
  enum Event: Equatable, Sendable {
    /// Hold to dictate, exactly as before.
    case dictationBegan
    case dictationEnded
    /// Two quick taps: listen for a command.
    case commandArmed
    /// A tap while armed: stop listening and run what was said.
    case commandCommitted
  }

  /// A press shorter than this is a tap rather than a hold. It is the same
  /// threshold a trackpad uses, and it has to be short enough that holding
  /// to dictate never reads as a tap.
  static let tapDuration: TimeInterval = 0.35

  /// How long a second tap has after the first. Longer than a double click,
  /// because the button is under a thumb on a remote rather than a finger
  /// on a mouse.
  static let doubleTapWindow: TimeInterval = 0.6

  private var pressedAt: Date?
  private var lastTapAt: Date?
  private var isDictating = false
  private var isArmed = false

  init() {}

  /// True while a command is being spoken, so the caller knows which kind
  /// of session is running.
  var isListeningForCommand: Bool { isArmed }

  mutating func press(at now: Date = Date()) -> [Event] {
    pressedAt = now

    // While armed, the next press is the full stop: it ends the command
    // rather than starting anything.
    if isArmed {
      isArmed = false
      pressedAt = nil
      lastTapAt = nil
      return [.commandCommitted]
    }
    return []
  }

  mutating func release(at now: Date = Date()) -> [Event] {
    guard let pressedAt else { return [] }
    let held = now.timeIntervalSince(pressedAt)
    self.pressedAt = nil

    // A hold that already began dictating just ends it.
    if isDictating {
      isDictating = false
      return [.dictationEnded]
    }

    guard held < Self.tapDuration else { return [] }

    // A tap. The second one inside the window arms a command.
    if let lastTapAt, now.timeIntervalSince(lastTapAt) < Self.doubleTapWindow {
      self.lastTapAt = nil
      isArmed = true
      return [.commandArmed]
    }
    lastTapAt = now
    return []
  }

  /// Called when the press has lasted long enough to be a hold. Dictation
  /// starts here rather than on the press, so the first tap of a double tap
  /// never opens a session that has to be thrown away.
  mutating func holdElapsed() -> [Event] {
    guard pressedAt != nil, !isDictating, !isArmed else { return [] }
    isDictating = true
    lastTapAt = nil
    return [.dictationBegan]
  }

  /// Abandons whatever is in flight, for a remote that disconnects mid-press.
  mutating func reset() -> [Event] {
    let wasDictating = isDictating
    pressedAt = nil
    lastTapAt = nil
    isDictating = false
    isArmed = false
    return wasDictating ? [.dictationEnded] : []
  }
}
