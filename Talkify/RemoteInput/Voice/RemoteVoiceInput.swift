import AVFAudio
import Accelerate
import Foundation
import OSLog
import Speech

/// Feeds a dictation session from the Siri Remote's microphone.
///
/// It stands where `MicrophoneInput` stands, and has the same shape, but it
/// opens no audio device: the samples arrive from the voice helper, already
/// decoded, so there is no engine to start, no format to negotiate with the
/// hardware, and nothing for a device switch to get wrong.
///
/// The helper always sends 16 kHz mono, which is what the remote's codec
/// produces. Only the conversion to the analyzer's own format is done here.
final class RemoteVoiceInput: DictationInput, @unchecked Sendable {
  enum InputError: LocalizedError, Sendable {
    case helperUnavailable
    case converterCreationFailed

    var errorDescription: String? {
      switch self {
      case .helperUnavailable:
        "The Siri Remote's microphone helper is not installed."
      case .converterCreationFailed:
        "The Siri Remote's audio format is unsupported."
      }
    }
  }

  /// What the helper sends: 16 kHz, one channel, signed 16-bit.
  private static let sourceFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: true
  )

  private let analyzerContinuation: AsyncStream<AnalyzerInput>.Continuation
  private let levelHandler: (@Sendable (Float) -> Void)?
  private let stateLock = NSLock()

  private var client: RemoteVoiceClient?
  /// Samples handed to the analyzer this session, logged when the session
  /// ends. This is the boundary between the helper and the transcriber,
  /// and neither side could see across it: the helper reported decoding
  /// audio and the app reported a clean session, while no text appeared.
  private var samplesReceived = 0
  private var converter: AVAudioConverter?
  private var outputFormat: AVAudioFormat?

  init(
    analyzerContinuation: AsyncStream<AnalyzerInput>.Continuation,
    levelHandler: (@Sendable (Float) -> Void)? = nil
  ) {
    self.analyzerContinuation = analyzerContinuation
    self.levelHandler = levelHandler
  }

  deinit {
    stop()
  }

  func start(outputFormat: AVAudioFormat) throws {
    guard RemoteVoiceClient.isHelperInstalled else { throw InputError.helperUnavailable }
    guard let sourceFormat = Self.sourceFormat,
          let converter = AVAudioConverter(from: sourceFormat, to: outputFormat)
    else { throw InputError.converterCreationFailed }

    stateLock.withLock {
      self.converter = converter
      self.outputFormat = outputFormat
    }

    samplesReceived = 0
    let client = RemoteVoiceClient { [weak self] samples in
      self?.receive(samples)
    }
    client.start()
    stateLock.withLock { self.client = client }
  }

  func stop() {
    let client = stateLock.withLock { () -> RemoteVoiceClient? in
      let current = self.client
      self.client = nil
      converter = nil
      outputFormat = nil
      return current
    }
    client?.stop()

    let seconds = Double(samplesReceived) / 16_000
    RemoteInputLog.logger.info(
      "remote session received \(self.samplesReceived) samples (\(String(format: "%.2f", seconds))s)"
    )
  }

  private func receive(_ samples: [Int16]) {
    guard !samples.isEmpty else { return }
    stateLock.withLock { samplesReceived += samples.count }

    let (converter, outputFormat) = stateLock.withLock {
      (self.converter, self.outputFormat)
    }
    guard let converter, let outputFormat,
          let sourceFormat = Self.sourceFormat,
          let input = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
          ),
          let channel = input.int16ChannelData
    else { return }

    input.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      channel[0].update(from: source.baseAddress!, count: samples.count)
    }
    publishLevel(of: samples)

    let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
    let capacity = AVAudioFrameCount(ceil(Double(samples.count) * ratio)) + 1
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
    else { return }

    var supplied = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
      // The converter asks repeatedly; the buffer is only ever offered
      // once, and saying so is what ends the conversion rather than
      // repeating the same samples.
      if supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return input
    }

    guard conversionError == nil, status == .haveData || status == .inputRanDry else { return }
    analyzerContinuation.yield(AnalyzerInput(buffer: output))
  }

  /// The HUD's voice visual, on the same 50 dB window the microphone path
  /// uses, so a remote session and a keyboard session look alike.
  private func publishLevel(of samples: [Int16]) {
    guard let levelHandler, !samples.isEmpty else { return }

    var floats = [Float](repeating: 0, count: samples.count)
    vDSP.convertElements(of: samples, to: &floats)
    var scaled = [Float](repeating: 0, count: samples.count)
    vDSP.divide(floats, Float(Int16.max), result: &scaled)

    let rms = vDSP.rootMeanSquare(scaled)
    let decibels = 20 * log10(max(rms, .leastNormalMagnitude))
    levelHandler(min(1, max(0, (decibels + 50) / 50)))
  }
}
