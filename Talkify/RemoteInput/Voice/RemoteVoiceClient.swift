import Foundation
import OSLog

/// Receives the Siri Remote's microphone from the voice helper.
///
/// The helper runs as root because only root may read the Bluetooth link.
/// It hands over finished 16 kHz mono PCM, so nothing privileged and
/// nothing codec-shaped lives in the app: this reads samples off a socket.
///
/// It reconnects on its own. The helper is a launchd daemon that may be
/// reinstalled or restarted underneath a running app, and a dictation app
/// that needs relaunching after that is a dictation app that is broken
/// once a week.
final class RemoteVoiceClient: @unchecked Sendable {
  static let socketPath = "/var/run/talkify-remote-voice.sock"

  private let handler: @Sendable ([Int16]) -> Void
  private let stateLock = NSLock()
  private var descriptor: Int32 = -1
  private var isRunning = false

  /// Long enough not to spin while the helper is absent, short enough that
  /// a reinstall is picked up before the user tries to dictate again.
  private static let retryInterval: TimeInterval = 3

  init(handler: @escaping @Sendable ([Int16]) -> Void) {
    self.handler = handler
  }

  deinit {
    stop()
  }

  /// True when the helper is installed. The socket only exists while the
  /// daemon is loaded, so its absence is exactly the case worth reporting
  /// to the user: the feature needs installing, not debugging.
  static var isHelperInstalled: Bool {
    FileManager.default.fileExists(atPath: socketPath)
  }

  func start() {
    stateLock.withLock {
      guard !isRunning else { return }
      isRunning = true
    }

    Thread.detachNewThread { [weak self] in
      while self?.keepRunning == true {
        guard let self else { return }
        if connectOnce() {
          readUntilClosed()
        }
        guard keepRunning else { return }
        Thread.sleep(forTimeInterval: Self.retryInterval)
      }
    }
  }

  func stop() {
    let descriptor = stateLock.withLock { () -> Int32 in
      isRunning = false
      let current = self.descriptor
      self.descriptor = -1
      return current
    }
    if descriptor >= 0 { close(descriptor) }
  }

  private var keepRunning: Bool {
    stateLock.withLock { isRunning }
  }

  private func connectOnce() -> Bool {
    let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else { return false }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    // The capacity is read before the write begins: taking it from
    // `address.sun_path` inside the closure would be two accesses to the
    // same storage, one of them a mutation.
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    _ = withUnsafeMutablePointer(to: &address.sun_path) { path in
      path.withMemoryRebound(to: CChar.self, capacity: pathCapacity) {
        strcpy($0, Self.socketPath)
      }
    }

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(socketDescriptor, $0, size)
      }
    }
    guard connected == 0 else {
      close(socketDescriptor)
      return false
    }

    stateLock.withLock { descriptor = socketDescriptor }
    RemoteInputLog.logger.info("connected to the voice helper")
    return true
  }

  private func readUntilClosed() {
    let descriptor = stateLock.withLock { self.descriptor }
    guard descriptor >= 0 else { return }

    // 20 ms of 16 kHz mono is 320 samples, so this holds several frames
    // without ever splitting one across two reads more than once.
    var buffer = [UInt8](repeating: 0, count: 4_096)
    var carry: [UInt8] = []

    while keepRunning {
      let count = recv(descriptor, &buffer, buffer.count, 0)
      guard count > 0 else { break }

      carry.append(contentsOf: buffer[0..<count])
      // Samples are 16-bit, so an odd trailing byte is the front half of
      // one and has to wait for its other half.
      let whole = carry.count - (carry.count % 2)
      guard whole > 0 else { continue }

      let samples = carry.prefix(whole).withUnsafeBytes { bytes in
        Array(bytes.bindMemory(to: Int16.self))
      }
      carry.removeFirst(whole)
      handler(samples)
    }

    stateLock.withLock {
      if self.descriptor >= 0 {
        close(self.descriptor)
        self.descriptor = -1
      }
    }
    RemoteInputLog.logger.info("voice helper disconnected")
  }
}
