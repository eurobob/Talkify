import AVFAudio
import CoreAudio
import Foundation

/// Finds CoreAudio input devices by name, so a session can record from a
/// device other than the system default.
///
/// The Siri Remote's microphone is why this exists. macOS never publishes
/// that microphone as an audio device: the remote sends Opus frames over
/// the Bluetooth link and the system discards them. A bridge process
/// decodes those frames and publishes the result as an ordinary input
/// device. From `AVAudioEngine`'s point of view it is one more microphone,
/// so nothing downstream of the tap needs to know where the audio began.
///
/// Selection is by name, not by identifier: CoreAudio assigns a new
/// identifier every time a device appears, so a stored identifier goes
/// stale as soon as the bridge restarts.
enum AudioInputDevice {
  struct Device: Sendable, Hashable {
    let id: AudioDeviceID
    let name: String
  }

  /// Every input device on the system, in CoreAudio's own order. Devices
  /// with no input channels are left out, so an output-only device cannot
  /// be picked by mistake.
  static func available() -> [Device] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &dataSize
    ) == noErr else {
      return []
    }

    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return [] }

    var identifiers = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &dataSize,
      &identifiers
    ) == noErr else {
      return []
    }

    return identifiers.compactMap { identifier in
      guard hasInputChannels(identifier), let name = name(of: identifier) else {
        return nil
      }
      return Device(id: identifier, name: name)
    }
  }

  /// The first input device whose name matches, ignoring case. Returns nil
  /// when the device is absent, which is the normal state whenever the
  /// bridge process is not running.
  static func device(named name: String) -> Device? {
    let wanted = name.lowercased()
    return available().first { $0.name.lowercased() == wanted }
  }

  /// Points the engine's input node at `device`.
  ///
  /// Call this before the engine starts. The input node reads its format
  /// from whichever device is current, so a switch after the tap is
  /// installed leaves the tap describing the old device.
  @discardableResult
  static func apply(_ device: Device, to engine: AVAudioEngine) -> Bool {
    guard let unit = engine.inputNode.audioUnit else { return false }
    var identifier = device.id
    return AudioUnitSetProperty(
      unit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &identifier,
      UInt32(MemoryLayout<AudioDeviceID>.size)
    ) == noErr
  }

  private static func hasInputChannels(_ identifier: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
      identifier,
      &address,
      0,
      nil,
      &dataSize
    ) == noErr, dataSize > 0 else {
      return false
    }

    let buffer = UnsafeMutableRawPointer.allocate(
      byteCount: Int(dataSize),
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { buffer.deallocate() }

    guard AudioObjectGetPropertyData(
      identifier,
      &address,
      0,
      nil,
      &dataSize,
      buffer
    ) == noErr else {
      return false
    }

    let list = UnsafeMutableAudioBufferListPointer(
      buffer.assumingMemoryBound(to: AudioBufferList.self)
    )
    return list.contains { $0.mNumberChannels > 0 }
  }

  private static func name(of identifier: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    // CoreAudio hands back a retained string here, so the value is taken
    // through Unmanaged rather than bridged straight into a CFString
    // variable: a pointer to an object reference is not a safe out-parameter.
    var name: Unmanaged<CFString>?
    var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(
      identifier,
      &address,
      0,
      nil,
      &dataSize,
      &name
    ) == noErr, let name else {
      return nil
    }
    return name.takeRetainedValue() as String
  }
}
