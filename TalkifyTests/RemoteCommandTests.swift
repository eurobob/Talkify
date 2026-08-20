import CoreGraphics
import Foundation
import Testing

@testable import Talkify

/// The vocabulary is fixed, so it is worth pinning: these are the phrases
/// the remote answers to, and a change that drops one is a regression a
/// user feels immediately.
struct RemoteCommandTests {
  @Test func aPhraseIsMatchedWhateverThePolitenessAroundIt() {
    #expect(RemoteCommandParser.command(from: "copy") == .press(.command("c")))
    #expect(RemoteCommandParser.command(from: "Copy.") == .press(.command("c")))
    #expect(RemoteCommandParser.command(from: "please copy") == .press(.command("c")))
    #expect(RemoteCommandParser.command(from: "  COPY  ") == .press(.command("c")))
  }

  /// "close this window" must not match "close" with words left over.
  @Test func theLongestPhraseWins() {
    #expect(RemoteCommandParser.command(from: "close this window") == .press(.command("w")))
    #expect(RemoteCommandParser.command(from: "close tab") == .press(.command("w")))
    #expect(RemoteCommandParser.command(from: "new tab") == .press(.command("t")))
  }

  @Test func openingNamesAnApplication() {
    #expect(RemoteCommandParser.command(from: "open Safari") == .open(app: "safari"))
    #expect(RemoteCommandParser.command(from: "launch Xcode") == .open(app: "xcode"))
    #expect(RemoteCommandParser.command(from: "please open the Music app") == .open(app: "music app"))
  }

  /// Switching and opening differ: one should not launch something that is
  /// not running.
  @Test func switchingIsNotOpening() {
    #expect(RemoteCommandParser.command(from: "switch to Mail") == .switchTo(app: "mail"))
    #expect(RemoteCommandParser.command(from: "go to Finder") == .switchTo(app: "finder"))
    #expect(RemoteCommandParser.command(from: "quit Safari") == .quit(app: "safari"))
  }

  /// A verb with nothing after it names no application, and guessing one
  /// would be worse than saying so.
  @Test func aVerbAloneIsNotACommand() {
    #expect(RemoteCommandParser.command(from: "open") == nil)
    #expect(RemoteCommandParser.command(from: "switch to") == nil)
    #expect(RemoteCommandParser.command(from: "please") == nil)
    #expect(RemoteCommandParser.command(from: "") == nil)
  }

  /// The whole reason for a fixed vocabulary: anything outside it is
  /// reported, never approximated.
  @Test func anythingUnknownIsRefused() {
    #expect(RemoteCommandParser.command(from: "make me a sandwich") == nil)
    #expect(RemoteCommandParser.command(from: "delete everything important") == nil)
  }

  @Test func fillerIsStrippedButMeaningIsNot() {
    #expect(RemoteCommandParser.normalise("Please, could you copy?") == "copy")
    #expect(RemoteCommandParser.normalise("Open the Safari") == "open safari")
    #expect(RemoteCommandParser.normalise("scroll down") == "scroll down")
  }

  @Test func scrollingHasADirection() {
    guard case let .scroll(down)? = RemoteCommandParser.command(from: "scroll down") else {
      Issue.record("scroll down did not parse")
      return
    }
    guard case let .scroll(up)? = RemoteCommandParser.command(from: "scroll up") else {
      Issue.record("scroll up did not parse")
      return
    }
    #expect(down < 0)
    #expect(up > 0)
  }

  /// The key codes are positions on the keyboard, so a wrong one sends a
  /// different key entirely.
  @Test func theLetterKeyCodesArePositions() {
    #expect(KeyBinding.command("c").keyCode == 8)
    #expect(KeyBinding.command("v").keyCode == 9)
    #expect(KeyBinding.command("z").keyCode == 6)
    #expect(KeyBinding.command("a").keyCode == 0)
    #expect(KeyBinding.command("c").modifiers.contains(.maskCommand))
    #expect(KeyBinding.commandShift("z").modifiers.contains(.maskShift))
  }
}
