import CoreGraphics
import Foundation

/// Types text, character for character.
///
/// Not as key codes. A key code is a position on the keyboard, so building
/// text out of them means knowing the user's layout and gives up on
/// anything outside it. A synthetic event can instead carry the characters
/// themselves, which types the same text on every layout and covers
/// punctuation a remote could never otherwise reach.
///
/// This is what makes a slash command possible: "/model" is heard as
/// "slash model", and no amount of dictation accuracy produces the
/// character.
@MainActor
enum TextTyper {
  /// Characters per event. Long strings are split because the system
  /// silently truncates an event carrying too many.
  private static let chunkSize = 16

  static func type(_ text: String) {
    guard !text.isEmpty else { return }
    let source = CGEventSource(stateID: .combinedSessionState)

    for chunk in text.chunked(into: chunkSize) {
      let characters = Array(chunk.utf16)
      guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
      else { return }

      characters.withUnsafeBufferPointer { buffer in
        down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
      }
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
    }
  }
}

private extension String {
  func chunked(into size: Int) -> [String] {
    var chunks: [String] = []
    var index = startIndex
    while index < endIndex {
      let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
      chunks.append(String(self[index..<end]))
      index = end
    }
    return chunks
  }
}
