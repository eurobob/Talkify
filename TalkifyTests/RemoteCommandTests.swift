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

/// The parameterised commands, which are the ones that make voice control
/// feel like using a computer rather than reciting a list.
struct RemoteCommandParameterTests {
  @Test func tabsAreReachedByNumber() {
    #expect(RemoteCommandParser.command(from: "tab two") == .press(.command("2")))
    #expect(RemoteCommandParser.command(from: "go to tab 3") == .press(.command("3")))
    #expect(RemoteCommandParser.command(from: "switch to tab five") == .press(.command("5")))
  }

  /// "new tab" and "close tab" are their own commands and must not be read
  /// as numbered ones, or a mis-heard number would open something instead
  /// of closing it.
  @Test func aNumberedTabNeedsTabToBeTheSubject() {
    #expect(RemoteCommandParser.command(from: "new tab") == .press(.command("t")))
    #expect(RemoteCommandParser.command(from: "close tab") == .press(.command("w")))
    #expect(RemoteCommandParser.command(from: "tab") == .press(.plain(48, label: "⇥")))
  }

  @Test func windowsAreArrangedByName() {
    #expect(RemoteCommandParser.command(from: "left half") == .arrangeWindow(.leftHalf))
    #expect(RemoteCommandParser.command(from: "right") == .arrangeWindow(.rightHalf))
    #expect(RemoteCommandParser.command(from: "top left") == .arrangeWindow(.topLeft))
    #expect(RemoteCommandParser.command(from: "maximise") == .arrangeWindow(.fill))
    #expect(RemoteCommandParser.command(from: "left two thirds") == .arrangeWindow(.leftTwoThirds))
  }

  /// People do not agree on what these are called, and being made to learn
  /// one wording is what makes voice control feel like an obstacle.
  @Test func anArrangementAnswersToSeveralNames() {
    #expect(RemoteCommandParser.command(from: "center") == .arrangeWindow(.centre))
    #expect(RemoteCommandParser.command(from: "centre") == .arrangeWindow(.centre))
    #expect(RemoteCommandParser.command(from: "maximize") == .arrangeWindow(.fill))
    #expect(RemoteCommandParser.command(from: "fill the screen") == .arrangeWindow(.fill))
  }

  /// Nothing that throws away work the user cannot get back should be one
  /// mis-hearing away.
  @Test func thereIsNoCommandThatClosesEverything() {
    #expect(RemoteCommandParser.command(from: "close everything") == nil)
  }
}

/// A window put slightly off screen is the difference between a feature
/// people use and one they stop trusting, so the arithmetic is pinned.
struct WindowArrangementTests {
  // A width that does not divide by three, on purpose.
  private let screen = CGRect(x: 0, y: 25, width: 1_601, height: 975)

  @Test func halvesDivideTheUsableScreen() {
    let left = WindowArrangement.leftHalf.frame(in: screen)
    let right = WindowArrangement.rightHalf.frame(in: screen)
    #expect(left.maxX == right.minX)
    #expect(abs(left.width - right.width) <= 1)
    #expect(left.minX == screen.minX)
    #expect(right.maxX == screen.maxX)
    #expect(left.height == screen.height)
  }

  /// Thirds must tile exactly. A rounding error here leaves a visible strip
  /// of desktop between two windows.
  @Test func thirdsTileWithoutAGap() {
    let left = WindowArrangement.leftThird.frame(in: screen)
    let middle = WindowArrangement.middleThird.frame(in: screen)
    let right = WindowArrangement.rightThird.frame(in: screen)
    #expect(left.maxX == middle.minX)
    #expect(middle.maxX == right.minX)
    #expect(right.maxX == screen.maxX)
  }

  /// Every arrangement has to stay inside the usable screen, or the window
  /// lands under the menu bar or off the edge.
  @Test func nothingLandsOffScreen() {
    for arrangement in WindowArrangement.allCases {
      let frame = arrangement.frame(in: screen)
      #expect(frame.minX >= screen.minX, "\(arrangement.rawValue) starts left of the screen")
      #expect(frame.minY >= screen.minY, "\(arrangement.rawValue) starts above the screen")
      #expect(frame.maxX <= screen.maxX, "\(arrangement.rawValue) runs off the right")
      #expect(frame.maxY <= screen.maxY, "\(arrangement.rawValue) runs off the bottom")
      #expect(frame.width > 0 && frame.height > 0, "\(arrangement.rawValue) is empty")
    }
  }

  @Test func fillingUsesTheWholeUsableScreen() {
    #expect(WindowArrangement.fill.frame(in: screen) == screen)
  }

  /// Only centring keeps the window's own size; everything else is a shape.
  @Test func onlyCentringKeepsTheSize() {
    for arrangement in WindowArrangement.allCases {
      #expect(arrangement.keepsSize == (arrangement == .centre))
    }
  }

  /// Every arrangement must be reachable by speech, or it may as well not
  /// exist.
  @Test func everyArrangementHasAPhrase() {
    for arrangement in WindowArrangement.allCases {
      #expect(!arrangement.phrases.isEmpty)
      for phrase in arrangement.phrases {
        #expect(WindowArrangement.named(phrase) != nil, "\(phrase) reaches nothing")
      }
    }
  }
}

/// Typing exists for slash commands: "/model" is heard as "slash model",
/// and no amount of dictation accuracy produces the character itself.
struct TypedTextTests {
  @Test func typingTakesEverythingAfterTheVerb() {
    #expect(RemoteCommandParser.command(from: "type hello world") == .type("hello world"))
    #expect(RemoteCommandParser.command(from: "Type Hello There") == .type("Hello There"))
  }

  /// A symbol attaches to what follows it. "/ model" is not a slash
  /// command; "/model" is.
  @Test func spokenSymbolsBecomeCharacters() {
    #expect(RemoteCommandParser.command(from: "type slash model") == .type("/model"))
    #expect(RemoteCommandParser.command(from: "type slash clear") == .type("/clear"))
    #expect(RemoteCommandParser.command(from: "type dash dash help") == .type("--help"))
  }

  /// The text is taken as spoken, not normalised: stripping filler and
  /// punctuation is right for a command and wrong for the user's words.
  @Test func typedTextKeepsItsFillerAndCase() {
    #expect(RemoteCommandParser.command(from: "type please can you help") == .type("please can you help"))
  }

  @Test func typeAloneTypesNothing() {
    #expect(RemoteCommandParser.command(from: "type") == nil)
    #expect(RemoteCommandParser.command(from: "type   ") == nil)
  }

  /// "type" must win over everything, or "type open safari" would launch a
  /// browser instead of typing the words.
  @Test func typingBeatsTheOtherVerbs() {
    #expect(RemoteCommandParser.command(from: "type open safari") == .type("open safari"))
    #expect(RemoteCommandParser.command(from: "type tab two") == .type("tab two"))
  }
}

/// An unrecorded Send keys binding must press nothing. The placeholder used
/// to be a real combination the app had lying about — Read Aloud's — so an
/// unrecorded button toggled Read Aloud.
struct UnrecordedBindingTests {
  @Test func anUnrecordedBindingIsMarkedAsSuch() {
    #expect(KeyBinding.unrecorded.isUnrecorded)
    #expect(!KeyBinding.command("c").isUnrecorded)
    #expect(!KeyBinding.optionEscape.isUnrecorded)
  }

  @Test func theUnrecordedPlaceholderIsNotARealShortcut() {
    #expect(KeyBinding.unrecorded.keyCode != KeyBinding.optionEscape.keyCode)
    #expect(KeyBinding.unrecorded.modifierFlags == 0)
  }
}

/// Apple's transcriber turns spoken punctuation into characters by itself,
/// so the verb is often not followed by a space. A rule wanting "type "
/// matched none of these.
struct TypedTextTranscriptionTests {
  @Test func theVerbNeedsNoSpaceAfterIt() {
    #expect(RemoteCommandParser.command(from: "Type/model") == .type("/model"))
    #expect(RemoteCommandParser.command(from: "type/clear") == .type("/clear"))
    #expect(RemoteCommandParser.command(from: "Type-v") == .type("-v"))
  }

  /// A letter or digit after the verb means it is part of a longer word,
  /// not a command.
  @Test func aLongerWordIsNotTheVerb() {
    #expect(RemoteCommandParser.command(from: "typewriter") == nil)
    #expect(RemoteCommandParser.command(from: "types") == nil)
    #expect(RemoteCommandParser.command(from: "type2") == nil)
  }

  /// Both spellings have to work: the transcriber converts some spoken
  /// punctuation and leaves other words alone.
  @Test func spokenAndConvertedPunctuationBothWork() {
    #expect(RemoteCommandParser.command(from: "type slash model") == .type("/model"))
    #expect(RemoteCommandParser.command(from: "Type/model") == .type("/model"))
  }
}
