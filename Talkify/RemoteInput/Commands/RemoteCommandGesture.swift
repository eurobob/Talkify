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
    /// Two quick taps: the next hold speaks a command rather than text.
    case commandArmed
    /// The armed hold began. The microphone is live from here.
    case commandBegan
    /// The armed hold ended: run what was said.
    case commandCommitted
    /// Armed, then nothing was held. The arming lapsed.
    case commandCancelled
  }

  /// A press shorter than this is a tap rather than a hold. It is the same
  /// threshold a trackpad uses, and it has to be short enough that holding
  /// to dictate never reads as a tap.
  static let tapDuration: TimeInterval = 0.35

  /// How long a second tap has after the first. Longer than a double click,
  /// because the button is under a thumb on a remote rather than a finger
  /// on a mouse.
  static let doubleTapWindow: TimeInterval = 0.6

  /// How long an arming lasts before it lapses. Long enough to bring the
  /// remote up to the mouth, short enough that a forgotten double tap does
  /// not turn a later dictation into a command.
  static let armedWindow: TimeInterval = 5

  private var pressedAt: Date?
  private var lastTapAt: Date?
  private var isDictating = false
  private var isSpeakingCommand = false
  private var armedAt: Date?

  init() {}

  /// True once a double tap has armed a command and the hold has not
  /// happened yet.
  var isArmedForCommand: Bool { armedAt != nil }

  /// True while a command is actually being spoken.
  var isSpeakingACommand: Bool { isSpeakingCommand }

  mutating func press(at now: Date = Date()) -> [Event] {
    pressedAt = now

    // An arming that was never used lapses rather than waiting forever for
    // a hold the user has forgotten about.
    if let armedAt, now.timeIntervalSince(armedAt) > Self.armedWindow {
      self.armedAt = nil
      return [.commandCancelled]
    }
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

    // A tap. The second one inside the window arms a command, which the
    // next hold speaks.
    if let lastTapAt, now.timeIntervalSince(lastTapAt) < Self.doubleTapWindow {
      self.lastTapAt = nil
      armedAt = now
      return [.commandArmed]
    }
    lastTapAt = now
    return []
  }

  /// Called when the press has lasted long enough to be a hold. Dictation
  /// starts here rather than on the press, so the first tap of a double tap
  /// never opens a session that has to be thrown away.
  mutating func holdElapsed(at now: Date = Date()) -> [Event] {
    guard pressedAt != nil, !isDictating, !isSpeakingCommand else { return [] }
    lastTapAt = nil

    // Armed: this hold speaks a command instead of dictating.
    if let armedAt, now.timeIntervalSince(armedAt) <= Self.armedWindow {
      self.armedAt = nil
      isSpeakingCommand = true
      return [.commandBegan]
    }
    armedAt = nil

    isDictating = true
    return [.dictationBegan]
  }

  /// Abandons whatever is in flight, for a remote that disconnects mid-press.
  mutating func reset() -> [Event] {
    let wasDictating = isDictating
    let wasSpeakingCommand = isSpeakingCommand
    pressedAt = nil
    lastTapAt = nil
    armedAt = nil
    isDictating = false
    isSpeakingCommand = false
    if wasSpeakingCommand { return [.commandCommitted] }
    return wasDictating ? [.dictationEnded] : []
  }
}
