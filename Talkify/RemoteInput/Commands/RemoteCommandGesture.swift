import Foundation

/// Recognises the Siri button's gestures.
///
/// The button does two jobs and they must never be confused: held, it
/// dictates; double tapped and then held, it listens for a command.
///
/// The second hold is not a stylistic choice. The remote's microphone only
/// transmits while the button is physically down — the capture shows audio
/// beginning when the button handle reports pressed and stopping on
/// release — so speaking with the button up records silence. Arming and
/// then holding is the only gesture the hardware allows.
///
/// Pure, so the timing rules can be pinned by tests rather than by holding
/// a button and hoping.
struct RemoteCommandGesture {
  enum Event: Equatable, Sendable {
    /// Hold to dictate, exactly as before.
    case dictationBegan
    case dictationEnded
    /// A tap, then a hold: this hold speaks a command rather than text.
    case commandBegan
    /// That hold ended: run what was said.
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
  private var isSpeakingCommand = false

  init() {}

  /// True while a command is being spoken.
  var isSpeakingACommand: Bool { isSpeakingCommand }

  /// True when the next hold would speak a command: a tap has just landed
  /// and its window is still open.
  func isArmedForCommand(at now: Date = Date()) -> Bool {
    guard let lastTapAt else { return false }
    return now.timeIntervalSince(lastTapAt) < Self.doubleTapWindow
  }

  mutating func press(at now: Date = Date()) -> [Event] {
    pressedAt = now
    return []
  }

  mutating func release(at now: Date = Date()) -> [Event] {
    guard let pressedAt else { return [] }
    let held = now.timeIntervalSince(pressedAt)
    self.pressedAt = nil

    // A hold that was speaking a command ends it, and the words are run.
    if isSpeakingCommand {
      isSpeakingCommand = false
      return [.commandCommitted]
    }

    // A hold that already began dictating just ends it.
    if isDictating {
      isDictating = false
      return [.dictationEnded]
    }

    guard held < Self.tapDuration else { return [] }

    // A tap on its own means nothing yet. It is the first half of a tap
    // and hold, and what follows decides.
    lastTapAt = now
    return []
  }

  /// Called when the press has lasted long enough to be a hold. Dictation
  /// starts here rather than on the press, so the first tap of a double tap
  /// never opens a session that has to be thrown away.
  mutating func holdElapsed(at now: Date = Date()) -> [Event] {
    guard let pressedAt, !isDictating, !isSpeakingCommand else { return [] }

    // A tap immediately before this press makes the hold a command. This is
    // tap-and-hold, the same gesture a trackpad uses for drag: two presses,
    // the second one held — not three.
    //
    // The window is measured to when this press began, not to now, so a
    // long command is not mistaken for a slow second tap.
    let followsTap = lastTapAt.map {
      pressedAt.timeIntervalSince($0) < Self.doubleTapWindow
    } ?? false
    lastTapAt = nil

    if followsTap {
      isSpeakingCommand = true
      return [.commandBegan]
    }

    isDictating = true
    return [.dictationBegan]
  }

  /// Abandons whatever is in flight, for a remote that disconnects mid-press.
  mutating func reset() -> [Event] {
    let wasDictating = isDictating
    let wasSpeakingCommand = isSpeakingCommand
    pressedAt = nil
    lastTapAt = nil
    isDictating = false
    isSpeakingCommand = false
    if wasSpeakingCommand { return [.commandCommitted] }
    return wasDictating ? [.dictationEnded] : []
  }
}
