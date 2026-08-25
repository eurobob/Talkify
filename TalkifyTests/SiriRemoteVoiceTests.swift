import Foundation
import Testing

@testable import Talkify

/// Every byte in these tests came off a third-generation Siri Remote on
/// 2026-08-20. They are the capture the protocol was worked out from, so
/// they are the thing worth pinning: a change that still parses these still
/// parses the remote.
struct SiriRemoteVoiceTests {
  /// A microphone-button press: one ACL fragment carrying a 5-byte ATT
  /// notification on handle 0x0039.
  private let buttonPressLine =
    "Aug 20 20:58:25.595  Siri remote        0x004D  RECV  "
    + "4D 20 09 00 05 00 04 00 1B 39 00 20 00  "

  private let buttonReleaseLine =
    "Aug 20 20:58:27.817  Siri remote        0x004D  RECV  "
    + "4D 20 09 00 05 00 04 00 1B 39 00 00 00  "

  /// The first voice frame, which arrives as two ACL fragments: a start
  /// carrying 86 bytes of the notification, and a continuation carrying
  /// the remaining 16.
  private let voiceStartLine =
    "Aug 20 20:58:25.625  Siri remote        0x004D  RECV  "
    + "4D 20 5A 00 66 00 04 00 1B 35 00 B0 5B 00 00 5E B8 60 B3 B4 74 DF 68 "
    + "1D B5 F1 A4 59 34 7C 95 FD 6D A5 94 B9 BB 0F 15 B0 BA 0E FD FF CF A3 "
    + "3F A3 35 B9 51 D6 10 04 6B E8 0A 2E 35 88 2E D0 F7 D1 C8 4F 73 F7 34 "
    + "F2 2D 73 02 C8 A6 D1 84 3D 4C A8 A8 DA 30 28 D6 86 86 46 65 C2 B7 D7 DC 7F  "

  private let voiceContinuationLine =
    "Aug 20 20:58:25.626  Siri remote        0x004D  RECV  "
    + "4D 10 10 00 12 93 AE DA 71 45 69 AA 16 4D D0 BF D2 19 26 1A"

  @Test func aTraceLineYieldsItsPacketBytes() {
    let packet = BluetoothTrace.packet(fromTraceLine: buttonPressLine)
    #expect(packet?.prefix(4) == [0x4D, 0x20, 0x09, 0x00])
    #expect(packet?.count == 13)
  }

  /// The Mac's own writes appear in the trace too. Decoding those would be
  /// decoding our own echo.
  @Test func aLineThatIsNotReceivedIsIgnored() {
    let sent = buttonPressLine.replacingOccurrences(of: "RECV", with: "SENT")
    #expect(BluetoothTrace.packet(fromTraceLine: sent) == nil)
    #expect(BluetoothTrace.packet(fromTraceLine: "not a trace line at all") == nil)
  }

  /// The handle is learned from the shape of what arrives, not assumed.
  /// GATT handles belong to a connection and this remote reconnects
  /// hundreds of times a day; a hardcoded one works until it moves, and
  /// then the stream goes silent while everything else looks healthy.
  @Test func aVoiceFrameIsRecognisedOnAnyHandle() {
    var reassembler = BluetoothTrace.Reassembler()
    _ = reassembler.accept(BluetoothTrace.packet(fromTraceLine: voiceStartLine)!)
    let notification = reassembler
      .accept(BluetoothTrace.packet(fromTraceLine: voiceContinuationLine)!)
      .flatMap(BluetoothTrace.notification(fromL2CAP:))!

    #expect(SiriRemoteVoice.looksLikeVoiceFrame(notification.value))
    #expect(!SiriRemoteVoice.looksLikeButtonReport(notification.value))
  }

  @Test func aButtonReportIsRecognisedByItsShape() {
    #expect(SiriRemoteVoice.looksLikeButtonReport([0x20, 0x00]))
    #expect(SiriRemoteVoice.looksLikeButtonReport([0x00, 0x00]))
    #expect(!SiriRemoteVoice.looksLikeButtonReport([0x20]))
    #expect(!SiriRemoteVoice.looksLikeButtonReport([0x20, 0x00, 0x00]))
  }

  /// Anything that is not this remote's voice must not be mistaken for it,
  /// or a battery notification would be decoded as audio.
  @Test func otherNotificationsAreNotVoice() {
    #expect(!SiriRemoteVoice.looksLikeVoiceFrame([0x46]))
    #expect(!SiriRemoteVoice.looksLikeVoiceFrame([]))
    // Right shape, wrong codec byte.
    var wrongTOC: [UInt8] = [0x00, 0x00, 0x01, 0x00, 0x02, 0x11, 0x22]
    #expect(!SiriRemoteVoice.looksLikeVoiceFrame(wrongTOC))
    wrongTOC[5] = SiriRemoteVoice.expectedTOC
    #expect(SiriRemoteVoice.looksLikeVoiceFrame(wrongTOC))
  }

  @Test func aButtonPressArrivesInOneFragment() {
    var reassembler = BluetoothTrace.Reassembler()
    let packet = BluetoothTrace.packet(fromTraceLine: buttonPressLine)!

    let l2cap = reassembler.accept(packet)
    let notification = l2cap.flatMap(BluetoothTrace.notification(fromL2CAP:))

    #expect(notification?.handle == SiriRemoteVoice.expectedButtonHandle)
    #expect(notification.map { SiriRemoteVoice.isButtonPressed($0.value) } == true)
  }

  @Test func aButtonReleaseReadsAsNotPressed() {
    var reassembler = BluetoothTrace.Reassembler()
    let packet = BluetoothTrace.packet(fromTraceLine: buttonReleaseLine)!
    let notification = reassembler.accept(packet)
      .flatMap(BluetoothTrace.notification(fromL2CAP:))

    #expect(notification?.handle == SiriRemoteVoice.expectedButtonHandle)
    #expect(notification.map { SiriRemoteVoice.isButtonPressed($0.value) } == false)
  }

  /// A voice notification is 102 bytes and does not fit one fragment, so
  /// the start alone must yield nothing and only the continuation completes
  /// it. Getting this wrong is what GoatRemote's own log calls "mic-button
  /// press was lost during ACL reassembly".
  @Test func aVoiceFrameIsRebuiltFromTwoFragments() {
    var reassembler = BluetoothTrace.Reassembler()

    let start = BluetoothTrace.packet(fromTraceLine: voiceStartLine)!
    #expect(reassembler.accept(start) == nil, "a start fragment cannot be complete")

    let continuation = BluetoothTrace.packet(fromTraceLine: voiceContinuationLine)!
    let l2cap = reassembler.accept(continuation)
    let notification = l2cap.flatMap(BluetoothTrace.notification(fromL2CAP:))

    #expect(notification?.handle == SiriRemoteVoice.expectedAudioHandle)
    #expect(notification?.value.count == 99)
  }

  @Test func theFirstVoiceFrameCarriesNinetyFourOpusBytes() {
    var reassembler = BluetoothTrace.Reassembler()
    _ = reassembler.accept(BluetoothTrace.packet(fromTraceLine: voiceStartLine)!)
    let notification = reassembler
      .accept(BluetoothTrace.packet(fromTraceLine: voiceContinuationLine)!)
      .flatMap(BluetoothTrace.notification(fromL2CAP:))!

    let frame = SiriRemoteVoice.frame(from: notification.value)
    #expect(frame?.sequence == 0)
    #expect(frame?.opus.count == 94)
    // 0xB8: CELT wideband, 20 ms, mono, one frame per packet. Wideband is
    // 16 kHz, which is why the decoder runs at 16 kHz.
    #expect(frame?.opus.first == 0xB8)
    #expect(frame?.endsStream == false)
  }

  /// A zero length is the only end-of-stream marker the remote sends.
  @Test func aZeroLengthFrameEndsTheStream() {
    let value: [UInt8] = [0x00, 0x00, 0x2A, 0x00, 0x00] + [UInt8](repeating: 0, count: 94)
    let frame = SiriRemoteVoice.frame(from: value)
    #expect(frame?.endsStream == true)
    #expect(frame?.sequence == 42)
  }

  /// A length that runs past the end is corruption, not truncation.
  /// Decoding those bytes would turn a radio glitch into a burst of noise.
  @Test func aLengthThatOverrunsTheFrameIsRefused() {
    let value: [UInt8] = [0x00, 0x00, 0x01, 0x00, 0xFF, 0xB8, 0x01, 0x02]
    #expect(SiriRemoteVoice.frame(from: value) == nil)
    #expect(SiriRemoteVoice.frame(from: [0x00, 0x00, 0x01]) == nil)
  }

  /// The sequence counter is what makes a lost frame concealable as silence
  /// rather than audible as a click, and it wraps at 16 bits.
  @Test func lostFramesAreCountedAcrossTheWrap() {
    #expect(SiriRemoteVoice.framesLost(from: 10, to: 11) == 0)
    #expect(SiriRemoteVoice.framesLost(from: 10, to: 14) == 3)
    #expect(SiriRemoteVoice.framesLost(from: 65535, to: 0) == 0)
    #expect(SiriRemoteVoice.framesLost(from: 65534, to: 2) == 3)
  }
}
