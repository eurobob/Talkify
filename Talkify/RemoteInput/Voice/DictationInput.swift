import AVFAudio

/// Where a dictation session's audio comes from.
///
/// The two sources are not two devices: the built-in microphone is an audio
/// device, and the remote's microphone is a decoded stream from the voice
/// helper. Naming the source rather than a device is what keeps the choice
/// honest — there is no device name that could stand for the remote.
enum DictationInputSource: Sendable, Hashable {
  case microphone
  case siriRemote
}

/// What a session needs from whichever source it is using.
///
/// Both implementations end at the same analyzer, so nothing downstream
/// knows or cares which one is speaking.
protocol DictationInput: AnyObject, Sendable {
  func start(outputFormat: AVAudioFormat) throws
  func stop()
}
