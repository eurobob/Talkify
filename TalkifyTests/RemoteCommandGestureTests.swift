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
    #expect(gesture.holdElapsed() == [.dictationBegan])
    #expect(gesture.release(at: start.addingTimeInterval(2)) == [.dictationEnded])
  }

  /// One tap does nothing at all. It is half of a double tap, and acting on
  /// it would make every command start with a stray dictation.
  @Test func oneTapDoesNothing() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    #expect(gesture.release(at: start.addingTimeInterval(0.1)).isEmpty)
  }

  @Test func twoQuickTapsArmACommand() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.release(at: start.addingTimeInterval(0.1))
    _ = gesture.press(at: start.addingTimeInterval(0.3))
    #expect(gesture.release(at: start.addingTimeInterval(0.4)) == [.commandArmed])
    #expect(gesture.isListeningForCommand)
  }

  /// Two taps far apart are two separate taps, not a double tap.
  @Test func twoSlowTapsDoNotArm() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.release(at: start.addingTimeInterval(0.1))
    _ = gesture.press(at: start.addingTimeInterval(2))
    #expect(gesture.release(at: start.addingTimeInterval(2.1)).isEmpty)
    #expect(!gesture.isListeningForCommand)
  }

  @Test func aTapWhileArmedRunsTheCommand() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.release(at: start.addingTimeInterval(0.1))
    _ = gesture.press(at: start.addingTimeInterval(0.3))
    _ = gesture.release(at: start.addingTimeInterval(0.4))

    #expect(gesture.press(at: start.addingTimeInterval(3)) == [.commandCommitted])
    #expect(!gesture.isListeningForCommand)
  }

  /// A hold must never begin while a command is being spoken: the button is
  /// the full stop then, whatever its duration.
  @Test func holdingWhileArmedDoesNotDictate() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.release(at: start.addingTimeInterval(0.1))
    _ = gesture.press(at: start.addingTimeInterval(0.3))
    _ = gesture.release(at: start.addingTimeInterval(0.4))

    _ = gesture.press(at: start.addingTimeInterval(3))
    #expect(gesture.holdElapsed().isEmpty)
  }

  /// A hold is not a tap, however it ends. Without this a long press would
  /// count towards a double tap and arm a command the user never asked for.
  @Test func aHoldIsNeverHalfOfADoubleTap() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.holdElapsed()
    _ = gesture.release(at: start.addingTimeInterval(1))

    _ = gesture.press(at: start.addingTimeInterval(1.2))
    #expect(gesture.release(at: start.addingTimeInterval(1.3)).isEmpty)
    #expect(!gesture.isListeningForCommand)
  }

  /// A remote that disconnects mid-hold must not leave a session open.
  @Test func resetEndsAnOpenDictation() {
    var gesture = RemoteCommandGesture()
    _ = gesture.press(at: start)
    _ = gesture.holdElapsed()
    #expect(gesture.reset() == [.dictationEnded])

    var untouched = RemoteCommandGesture()
    #expect(untouched.reset().isEmpty)
  }
}
