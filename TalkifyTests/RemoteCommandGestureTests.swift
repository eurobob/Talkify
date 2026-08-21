import Foundation
import Testing

@testable import Talkify

/// The Siri button does two jobs from the same press, so these rules decide
/// which one runs. Getting them wrong means dictation starting when a
/// command was meant, which loses the user's words into a document.
struct RemoteCommandGestureTests {
  private let start = Date(timeIntervalSince1970: 1_000)

  @Test func holdingDictates() {
    var gesture = RemoteCommandGesture()
    #expect(gesture.press(at: start).isEmpty)
    #expect(gesture.holdElapsed(at: start.addingTimeInterval(0.4)) == [.dictationBegan])
    #expect(gesture.release(at: start.addingTimeInterval(2)) == [.dictationEnded])
  }

  /// One tap does nothing at all. It is the first half of a tap and hold,
  /// and acting on it would make every command start with a stray session.
  @Test func oneTapDoesNothing() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    #expect(gesture.release(at: start.addingTimeInterval(0.1)).isEmpty)
  }

  /// Tap, then hold: two presses, the second held. The same gesture a
  /// trackpad uses for drag, and the one a hand actually performs.
  @Test func tapThenHoldSpeaksACommand() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.release(at: start.addingTimeInterval(0.12))

    _ = gesture.press(at: start.addingTimeInterval(0.2))
    #expect(gesture.holdElapsed(at: start.addingTimeInterval(0.55)) == [.commandBegan])
    #expect(gesture.isSpeakingACommand)
    #expect(gesture.release(at: start.addingTimeInterval(3)) == [.commandCommitted])
    #expect(!gesture.isSpeakingACommand)
  }

  /// The microphone only transmits while the button is down, so a command
  /// is spoken during the hold and run on the release.
  @Test func aCommandRunsWhenTheHoldEnds() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.release(at: start.addingTimeInterval(0.1))
    _ = gesture.press(at: start.addingTimeInterval(0.2))
    _ = gesture.holdElapsed(at: start.addingTimeInterval(0.55))

    // A long command must still end as a command, not lapse into anything.
    #expect(gesture.release(at: start.addingTimeInterval(12)) == [.commandCommitted])
  }

  /// A tap too long ago is not part of this gesture, so the hold dictates.
  @Test func aHoldLongAfterATapDictates() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.release(at: start.addingTimeInterval(0.1))

    let later = start.addingTimeInterval(0.1 + RemoteCommandGesture.doubleTapWindow + 0.5)
    _ = gesture.press(at: later)
    #expect(gesture.holdElapsed(at: later.addingTimeInterval(0.4)) == [.dictationBegan])
  }

  /// The window is measured to when the press began, not to when the hold
  /// was recognised: otherwise a slow hand would dictate when it meant to
  /// command.
  @Test func theWindowIsMeasuredToThePressNotTheHold() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.release(at: start.addingTimeInterval(0.1))

    // Press well inside the window, recognised as a hold well outside it.
    _ = gesture.press(at: start.addingTimeInterval(0.3))
    #expect(gesture.holdElapsed(at: start.addingTimeInterval(5)) == [.commandBegan])
  }

  /// A hold is not a tap, however it ends. Without this a long press would
  /// count as the first half and turn the next hold into a command.
  @Test func aHoldIsNeverHalfOfATapAndHold() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.holdElapsed(at: start.addingTimeInterval(0.4))
    _ = gesture.release(at: start.addingTimeInterval(1))

    _ = gesture.press(at: start.addingTimeInterval(1.1))
    #expect(gesture.holdElapsed(at: start.addingTimeInterval(1.5)) == [.dictationBegan])
  }

  /// A remote that disconnects mid-gesture must not leave a session open.
  @Test func resetEndsWhateverWasOpen() {
    var dictating = RemoteCommandGesture()
    _ = dictating.press(at: start)
    _ = dictating.holdElapsed(at: start.addingTimeInterval(0.4))
    #expect(dictating.reset() == [.dictationEnded])

    var commanding = RemoteCommandGesture()
    _ = commanding.press(at: start)
    _ = commanding.release(at: start.addingTimeInterval(0.1))
    _ = commanding.press(at: start.addingTimeInterval(0.2))
    _ = commanding.holdElapsed(at: start.addingTimeInterval(0.55))
    #expect(commanding.reset() == [.commandCommitted])

    var untouched = RemoteCommandGesture()
    #expect(untouched.reset().isEmpty)
  }
}
