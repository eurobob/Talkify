import Foundation

/// Turns the remote's notifications into a stream of PCM.
///
/// This is the whole voice path in one place: fragments in, samples out.
/// It holds the decoder and the sequence counter, so a lost frame is
/// concealed by the codec instead of arriving as a click, and it is
/// deliberately free of any transport: the helper feeds it from
/// PacketLogger, and a test feeds it from a captured file.
final class SiriRemoteVoiceStream {
  enum Event: Equatable, Sendable {
    /// The microphone button went down. Any samples before this belong to
    /// a previous utterance.
    case began
    /// 16 kHz mono samples, in order, with lost frames already concealed.
    case samples([Int16])
    /// The button was released, or the remote sent its end-of-stream frame.
    case ended
  }

  private let decoder: OpusDecoder
  private var reassembler = BluetoothTrace.Reassembler()
  private var lastSequence: UInt16?
  private var isSpeaking = false

  /// How many missing frames are worth concealing before the gap is
  /// treated as a break in the stream. Concealment is a guess, and a long
  /// run of guesses sounds worse than the silence it replaces.
  private static let concealmentLimit = 5

  init() throws {
    decoder = try OpusDecoder()
  }

  /// Feeds one traced packet in and returns whatever it completed.
  func accept(packet: [UInt8]) -> [Event] {
    guard let l2cap = reassembler.accept(packet),
          let notification = BluetoothTrace.notification(fromL2CAP: l2cap)
    else { return [] }

    switch notification.handle {
    case SiriRemoteVoice.buttonHandle:
      return button(pressed: SiriRemoteVoice.isButtonPressed(notification.value))
    case SiriRemoteVoice.audioHandle:
      return audio(value: notification.value)
    default:
      return []
    }
  }

  private func button(pressed: Bool) -> [Event] {
    if pressed {
      guard !isSpeaking else { return [] }
      isSpeaking = true
      lastSequence = nil
      return [.began]
    }
    return finish()
  }

  private func audio(value: [UInt8]) -> [Event] {
    guard let frame = SiriRemoteVoice.frame(from: value) else { return [] }

    // Audio can arrive before the button notification does; the stream
    // starting is itself proof the button is down.
    var events: [Event] = []
    if !isSpeaking {
      isSpeaking = true
      lastSequence = nil
      events.append(.began)
    }

    guard !frame.endsStream else { return events + finish() }

    if let lastSequence {
      let lost = SiriRemoteVoice.framesLost(from: lastSequence, to: frame.sequence)
      if lost > 0, lost <= Self.concealmentLimit {
        for _ in 0..<lost {
          events.append(.samples(decoder.concealLostFrame()))
        }
      }
    }
    lastSequence = frame.sequence

    if let pcm = decoder.decode(frame.opus) {
      events.append(.samples(pcm))
    }
    return events
  }

  private func finish() -> [Event] {
    guard isSpeaking else { return [] }
    isSpeaking = false
    lastSequence = nil
    return [.ended]
  }
}
