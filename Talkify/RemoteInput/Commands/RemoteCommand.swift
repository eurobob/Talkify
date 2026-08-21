import CoreGraphics
import Foundation

/// A spoken command, once it has been understood.
///
/// The vocabulary is fixed and written down. That is the point: a command
/// that cannot be matched is reported as not understood rather than guessed
/// at, so the remote never confidently does the wrong thing to a document.
enum RemoteCommand: Equatable, Sendable {
  case open(app: String)
  case switchTo(app: String)
  case quit(app: String)
  case press(KeyBinding)
  case missionControl
  case scroll(lines: Int)
  case arrangeWindow(WindowArrangement)

  /// What to say back after running it. Short, because it is read at a
  /// glance while the remote is still in the hand.
  var confirmation: String {
    switch self {
    case let .open(app): "Opening \(app)"
    case let .switchTo(app): "Switching to \(app)"
    case let .quit(app): "Quitting \(app)"
    case let .press(binding): binding.label
    case .missionControl: "Mission Control"
    case let .scroll(lines): lines < 0 ? "Scrolling down" : "Scrolling up"
    case let .arrangeWindow(arrangement): arrangement.title
    }
  }
}

/// Turns a transcript into a command.
///
/// Pure, so the whole vocabulary can be pinned by tests without a
/// microphone in the room. Speech transcripts arrive with capitals,
/// punctuation and filler, so matching happens on a normalised form rather
/// than on what was literally heard.
enum RemoteCommandParser {
  /// Phrases that carry no meaning here. "Please open Safari" and "open
  /// Safari" are the same instruction, and a speaker being polite should
  /// not be told their command was not understood.
  private static let filler: Set<String> = [
    "please", "can", "you", "could", "would", "the", "a", "an", "for", "me",
    "now", "just", "um", "uh", "okay", "ok", "hey", "let's", "lets",
  ]

  /// Verbs that open an application, and the ones that only bring it
  /// forward. They differ: "switch to Mail" should not launch Mail if it is
  /// not running, and "open Mail" should.
  private static let openVerbs = ["open", "launch", "start", "run"]
  private static let switchVerbs = ["switch to", "go to", "activate", "focus"]
  private static let quitVerbs = ["quit", "exit"]

  /// The fixed phrases, longest first so "close window" is matched before
  /// "close" alone.
  private static let phrases: [(String, RemoteCommand)] = [
    ("mission control", .missionControl),
    ("show all windows", .missionControl),
    ("new tab", .press(.command("t"))),
    ("close tab", .press(.command("w"))),
    ("close window", .press(.command("w"))),
    ("close this tab", .press(.command("w"))),
    ("close this window", .press(.command("w"))),
    ("new window", .press(.command("n"))),
    ("next tab", .press(.commandShift("]"))),
    ("previous tab", .press(.commandShift("["))),
    ("last tab", .press(.commandShift("["))),
    ("go back", .press(.command("["))),
    ("go forward", .press(.command("]"))),
    ("select all", .press(.command("a"))),
    ("copy", .press(.command("c"))),
    ("paste", .press(.command("v"))),
    ("cut", .press(.command("x"))),
    ("undo", .press(.command("z"))),
    ("redo", .press(.commandShift("z"))),
    ("save", .press(.command("s"))),
    ("find", .press(.command("f"))),
    ("search", .press(.command("f"))),
    ("print", .press(.command("p"))),
    ("refresh", .press(.command("r"))),
    ("reload", .press(.command("r"))),
    ("zoom in", .press(.command("="))),
    ("zoom out", .press(.command("-"))),

    // Windows and applications. These are ordinary application shortcuts,
    // which a synthesised keystroke does reach — unlike the window
    // server's own, which ignore one however faithfully it is assembled.
    ("minimise", .press(.command("m"))),
    ("minimize", .press(.command("m"))),
    ("full screen", .press(.modified(3, flags: [.maskControl, .maskCommand], label: "⌃ ⌘ F"))),
    ("hide this", .press(.command("h"))),
    ("hide others", .press(.modified(4, flags: [.maskCommand, .maskAlternate], label: "⌥ ⌘ H"))),
    ("quit this", .press(.command("q"))),
    ("settings", .press(.command(","))),
    ("preferences", .press(.command(","))),

    // Writing.
    ("bold", .press(.command("b"))),
    ("italic", .press(.command("i"))),
    ("underline", .press(.command("u"))),
    ("new document", .press(.command("n"))),
    ("find next", .press(.command("g"))),
    ("find previous", .press(.commandShift("g"))),
    ("replace", .press(.modified(3, flags: [.maskCommand, .maskAlternate], label: "⌥ ⌘ F"))),
    ("indent", .press(.plain(48, label: "⇥"))),

    // Moving about a document.
    ("top", .press(.modified(126, flags: .maskCommand, label: "⌘ ↑"))),
    ("bottom", .press(.modified(125, flags: .maskCommand, label: "⌘ ↓"))),
    ("start of line", .press(.modified(123, flags: .maskCommand, label: "⌘ ←"))),
    ("end of line", .press(.modified(124, flags: .maskCommand, label: "⌘ →"))),
    ("up", .press(.plain(126, label: "↑"))),
    ("down", .press(.plain(125, label: "↓"))),
    ("left", .press(.plain(123, label: "←"))),
    ("right", .press(.plain(124, label: "→"))),
    ("space", .press(.plain(49, label: "space"))),
    ("enter", .press(.plain(36, label: "↩"))),
    ("return", .press(.plain(36, label: "↩"))),
    ("escape", .press(.plain(53, label: "⎋"))),
    ("cancel", .press(.plain(53, label: "⎋"))),
    ("tab", .press(.plain(48, label: "⇥"))),
    ("delete", .press(.plain(51, label: "⌫"))),
    ("backspace", .press(.plain(51, label: "⌫"))),
    ("scroll down", .scroll(lines: -6)),
    ("scroll up", .scroll(lines: 6)),
    ("page down", .scroll(lines: -18)),
    ("page up", .scroll(lines: 18)),
    ("scroll to top", .press(.modified(126, flags: .maskCommand, label: "⌘ ↑"))),
    ("scroll to bottom", .press(.modified(125, flags: .maskCommand, label: "⌘ ↓"))),
  ]

  /// Spoken numbers, because a transcript says "two" as often as "2".
  private static let numbers: [String: Int] = [
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9,
    "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9,
  ]

  /// Reads a transcript. Returns nil when nothing matched, which is a
  /// result rather than a failure: the user is told, and nothing happens.
  static func command(from transcript: String) -> RemoteCommand? {
    let text = normalise(transcript)
    guard !text.isEmpty else { return nil }

    // Before the verbs: "go to tab two" starts with a switching verb and
    // would otherwise be read as an application called "tab two".
    if let tab = numberedTab(in: text) { return tab }
    if let arrangement = WindowArrangement.named(text) {
      return .arrangeWindow(arrangement)
    }

    // Longest phrase first, so "close this window" is not matched as
    // "close" with "this window" left over.
    for (phrase, command) in phrases.sorted(by: { $0.0.count > $1.0.count })
    where text == phrase {
      return command
    }

    for verb in switchVerbs {
      if let name = remainder(of: text, after: verb) {
        return .switchTo(app: name)
      }
    }
    for verb in quitVerbs {
      if let name = remainder(of: text, after: verb) {
        return .quit(app: name)
      }
    }
    for verb in openVerbs {
      if let name = remainder(of: text, after: verb) {
        return .open(app: name)
      }
    }
    return nil
  }

  /// "tab two", "go to tab 3", "switch to tab five". Numbered tabs are
  /// ⌘1 through ⌘9 in every application that has tabs at all, and the
  /// ninth is the last one rather than the ninth in most of them.
  private static func numberedTab(in text: String) -> RemoteCommand? {
    let words = text.split(separator: " ").map(String.init)
    guard let tabIndex = words.firstIndex(of: "tab"),
          tabIndex + 1 < words.count,
          let number = numbers[words[tabIndex + 1]]
    else { return nil }

    // Only when "tab" is the subject: "new tab" and "close tab" are their
    // own commands and must not be read as a numbered one.
    let leading = words[..<tabIndex].joined(separator: " ")
    guard leading.isEmpty || switchVerbs.contains(leading) || leading == "go" else {
      return nil
    }
    return .press(.command(String(number)))
  }

  /// Lowercased, stripped of punctuation and filler, single-spaced.
  static func normalise(_ transcript: String) -> String {
    let lowered = transcript.lowercased()
    let stripped = lowered.unicodeScalars
      .map { CharacterSet.punctuationCharacters.contains($0) ? " " : Character($0) }
    let words = String(stripped)
      .split(separator: " ")
      .map(String.init)
      .filter { !filler.contains($0) }
    return words.joined(separator: " ")
  }

  /// The words after a verb, or nil when the verb is absent or nothing
  /// follows it. "Open" alone names no application.
  private static func remainder(of text: String, after verb: String) -> String? {
    guard text == verb || text.hasPrefix(verb + " ") else { return nil }
    let rest = text.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)
    return rest.isEmpty ? nil : rest
  }
}

extension KeyBinding {
  /// Where each character sits on the keyboard, as a virtual key code.
  ///
  /// These are positions, not letters: the code for "c" is the third key on
  /// the bottom row whatever the layout calls it, which is what makes ⌘C
  /// copy on a French keyboard too.
  private static let keyCodes: [String: Int64] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
    "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
    "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ";": 41, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47,
  ]

  /// The shorthands the command table is written in.
  static func command(_ character: String) -> KeyBinding {
    modified(keyCodes[character] ?? 0, flags: .maskCommand, label: "⌘ \(character.uppercased())")
  }

  static func commandShift(_ character: String) -> KeyBinding {
    modified(
      keyCodes[character] ?? 0,
      flags: [.maskCommand, .maskShift],
      label: "⌘ ⇧ \(character.uppercased())"
    )
  }

  static func modified(_ keyCode: Int64, flags: CGEventFlags, label: String) -> KeyBinding {
    KeyBinding(
      keyCode: keyCode,
      modifierFlags: flags.rawValue,
      isModifierKey: false,
      label: label,
      keyEquivalent: ""
    )
  }

  static func plain(_ keyCode: Int64, label: String) -> KeyBinding {
    modified(keyCode, flags: [], label: label)
  }
}
