import Foundation

/// Decodes the remote's Opus packets to 16 kHz mono PCM.
///
/// libopus is resolved at runtime rather than linked, for the same reason
/// `MultitouchSupport` is: it is not part of the system, it arrives through
/// Homebrew or beside the binary, and a missing copy has to be a reported
/// failure rather than a process that refuses to launch.
final class OpusDecoder {
  /// The remote sends CELT wideband at 20 ms, which is 16 kHz mono. Every
  /// packet is therefore exactly this many samples.
  static let sampleRate: Int32 = 16_000
  static let channels: Int32 = 1
  static let samplesPerFrame: Int32 = 320

  enum Failure: Error, Equatable {
    case libraryMissing
    case symbolMissing(String)
    case decoderCreationFailed(Int32)
  }

  /// Where libopus is looked for, in order. The Homebrew paths cover both
  /// architectures; the bare name lets a copy beside the binary win.
  private static let searchPaths = [
    "/opt/homebrew/lib/libopus.dylib",
    "/usr/local/lib/libopus.dylib",
    "libopus.dylib",
  ]

  private typealias CreateDecoder = @convention(c) (
    Int32, Int32, UnsafeMutablePointer<Int32>
  ) -> UnsafeMutableRawPointer?
  private typealias Decode = @convention(c) (
    UnsafeMutableRawPointer, UnsafePointer<UInt8>?, Int32,
    UnsafeMutablePointer<Int16>, Int32, Int32
  ) -> Int32
  private typealias DestroyDecoder = @convention(c) (UnsafeMutableRawPointer) -> Void

  private let decode: Decode
  private let destroy: DestroyDecoder
  private let decoder: UnsafeMutableRawPointer
  private var pcm: [Int16]

  init() throws {
    var handle: UnsafeMutableRawPointer?
    for path in Self.searchPaths {
      handle = dlopen(path, RTLD_LAZY)
      if handle != nil { break }
    }
    guard let handle else { throw Failure.libraryMissing }

    func symbol(_ name: String) throws -> UnsafeMutableRawPointer {
      guard let found = dlsym(handle, name) else { throw Failure.symbolMissing(name) }
      return found
    }

    let create = unsafeBitCast(try symbol("opus_decoder_create"), to: CreateDecoder.self)
    decode = unsafeBitCast(try symbol("opus_decode"), to: Decode.self)
    destroy = unsafeBitCast(try symbol("opus_decoder_destroy"), to: DestroyDecoder.self)

    var error: Int32 = 0
    guard let decoder = create(Self.sampleRate, Self.channels, &error), error == 0 else {
      throw Failure.decoderCreationFailed(error)
    }
    self.decoder = decoder
    pcm = [Int16](repeating: 0, count: Int(Self.samplesPerFrame))
  }

  deinit {
    destroy(decoder)
  }

  /// Decodes one packet. Returns nil when libopus refuses it, which means
  /// the bytes were not a packet and the frame is better dropped than
  /// played.
  func decode(_ packet: [UInt8]) -> [Int16]? {
    let written = packet.withUnsafeBufferPointer { bytes in
      pcm.withUnsafeMutableBufferPointer { output in
        decode(
          decoder, bytes.baseAddress, Int32(bytes.count),
          output.baseAddress!, Self.samplesPerFrame, 0
        )
      }
    }
    guard written > 0 else { return nil }
    return Array(pcm.prefix(Int(written)))
  }

  /// Fills the gap a lost frame left.
  ///
  /// libopus is asked to conceal it rather than silence being inserted:
  /// the codec continues the signal it was already decoding, so a dropped
  /// radio packet becomes a smudge rather than a click. Passing a nil
  /// packet is how the API asks for that.
  func concealLostFrame() -> [Int16] {
    let written = pcm.withUnsafeMutableBufferPointer { output in
      decode(decoder, nil, 0, output.baseAddress!, Self.samplesPerFrame, 0)
    }
    guard written > 0 else {
      return [Int16](repeating: 0, count: Int(Self.samplesPerFrame))
    }
    return Array(pcm.prefix(Int(written)))
  }
}
