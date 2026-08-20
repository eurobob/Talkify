import Foundation

/// The Siri Remote's voice protocol, as it arrives on its two notification
/// handles.
///
/// Worked out from a capture of a third-generation remote (A2854) on
/// 2026-08-20: 366 notifications, every one of them 99 bytes, and libopus
/// accepted all 363 that carried audio without a single error.
enum SiriRemoteVoice {
  /// The remote sends its audio on this handle and its microphone button
  /// on the other. Both are fixed for the A2854.
  static let audioHandle: UInt16 = 0x0035
  static let buttonHandle: UInt16 = 0x0039

  /// The value the button handle carries while the microphone button is
  /// held. It reads `00 00` on release.
  static let buttonPressedValue: UInt8 = 0x20

  /// One frame of the voice stream.
  ///
  /// The layout, by byte:
  ///
  ///     0..1  unknown, usually zero
  ///     2..3  sequence number, 16-bit little endian
  ///     4     length of the Opus packet that follows
  ///     5..   the Opus packet, its TOC byte first
  ///
  /// The TOC reads `0xB8` on a normal frame: CELT wideband, 20 ms, mono,
  /// one frame per packet. Wideband is 16 kHz, which is why the decoder is
  /// built at 16 kHz and every packet is 320 samples.
  struct Frame: Equatable, Sendable {
    let sequence: UInt16
    /// The Opus packet, or empty when this frame ends the stream.
    let opus: [UInt8]

    /// True when the remote is saying the microphone button was released.
    /// A zero length is the only end-of-stream marker the remote sends.
    var endsStream: Bool { opus.isEmpty }
  }

  /// The header is five bytes, and a frame shorter than that carries
  /// nothing to decode.
  private static let headerLength = 5

  /// Reads a frame from a notification value on the audio handle.
  ///
  /// Returns nil when the value cannot be a frame: too short, or a length
  /// that runs past the end. A frame whose length overruns is corrupt
  /// rather than merely truncated, and feeding its bytes to the decoder
  /// would turn a radio glitch into a burst of noise.
  static func frame(from value: [UInt8]) -> Frame? {
    guard value.count >= headerLength else { return nil }

    let sequence = UInt16(value[2]) | UInt16(value[3]) << 8
    let length = Int(value[4])
    guard headerLength + length <= value.count else { return nil }

    return Frame(
      sequence: sequence,
      opus: Array(value[headerLength..<(headerLength + length)])
    )
  }

  /// Whether a value on the button handle means the button is down.
  static func isButtonPressed(_ value: [UInt8]) -> Bool {
    value.first == buttonPressedValue
  }

  /// How many frames were lost between two sequence numbers.
  ///
  /// The counter wraps at 16 bits, so the difference is taken in that
  /// width. Knowing the size of a gap is what lets a lost frame be
  /// concealed as silence rather than heard as a click.
  static func framesLost(from previous: UInt16, to current: UInt16) -> Int {
    Int(current &- previous) - 1
  }
}
