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

  /// One tap does nothing at all. It is half of a double tap, and acting on
  /// it would make every command start with a stray dictation.
  @Test func oneTapDoesNothing() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    #expect(gesture.release(at: start.addingTimeInterval(0.1)).isEmpty)
  }

  /// Two taps arm a command; the hold that follows speaks it. The remote's
  /// microphone only transmits while the button is down, so there is no
  /// gesture that records with the button up.
  @Test func twoQuickTapsArmACommandAndTheNextHoldSpeaksIt() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.release(at: start.addingTimeInterval(0.1))
    _ = gesture.press(at: start.addingTimeInterval(0.3))
    #expect(gesture.release(at: start.addingTimeInterval(0.4)) == [.commandArmed])
    #expect(gesture.isArmedForCommand)

    _ = gesture.press(at: start.addingTimeInterval(1))
    #expect(gesture.holdElapsed(at: start.addingTimeInterval(1.4)) == [.commandBegan])
    #expect(gesture.isSpeakingACommand)
    #expect(gesture.release(at: start.addingTimeInterval(3)) == [.commandCommitted])
  }

  /// An arming the user forgot about must not turn a later dictation into a
  /// command, which would swallow their words instead of typing them.
  @Test func anArmingLapses() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.release(at: start.addingTimeInterval(0.1))
    _ = gesture.press(at: start.addingTimeInterval(0.3))
    _ = gesture.release(at: start.addingTimeInterval(0.4))

    let late = start.addingTimeInterval(0.4 + RemoteCommandGesture.armedWindow + 1)
    #expect(gesture.press(at: late) == [.commandCancelled])
    #expect(gesture.holdElapsed(at: late.addingTimeInterval(0.4)) == [.dictationBegan])
  }

  /// Two taps far apart are two separate taps, not a double tap.
  @Test func twoSlowTapsDoNotArm() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.release(at: start.addingTimeInterval(0.1))
    _ = gesture.press(at: start.addingTimeInterval(2))
    #expect(gesture.release(at: start.addingTimeInterval(2.1)).isEmpty)
    #expect(!gesture.isArmedForCommand)
  }

  /// Without arming, a hold is ordinary dictation. This is the path the
  /// user takes every day, so it must not be reachable by accident from
  /// the command side.
  @Test func anUnarmedHoldDictates() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    #expect(gesture.holdElapsed(at: start.addingTimeInterval(0.4)) == [.dictationBegan])
    #expect(gesture.release(at: start.addingTimeInterval(2)) == [.dictationEnded])
  }

  /// A hold is not a tap, however it ends. Without this a long press would
  /// count towards a double tap and arm a command the user never asked for.
  @Test func aHoldIsNeverHalfOfADoubleTap() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.holdElapsed(at: start.addingTimeInterval(0.4))
    _ = gesture.release(at: start.addingTimeInterval(1))

    _ = gesture.press(at: start.addingTimeInterval(1.2))
    #expect(gesture.release(at: start.addingTimeInterval(1.3)).isEmpty)
    #expect(!gesture.isArmedForCommand)
  }

  /// A remote that disconnects mid-hold must not leave a session open.
  @Test func resetEndsAnOpenDictation() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.holdElapsed(at: start.addingTimeInterval(0.4))
    #expect(gesture.reset() == [.dictationEnded])

    var untouched = RemoteCommandGesture()
    #expect(untouched.reset().isEmpty)
  }
}
