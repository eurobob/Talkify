// talkify-remote-voiced — reads the Siri Remote's microphone and serves it.
//
// It exists because PacketLogger can only read the Bluetooth link as root,
// and an app cannot elevate itself. launchd starts this at boot, so the
// app finds audio waiting for it and the user never runs a script or types
// a password after installing it once.
//
// It publishes 16 kHz mono PCM on a Unix socket, and nothing else: no
// transcription, no virtual audio device, no shared memory. A client that
// is not connected costs nothing, because PacketLogger is only spawned
// while somebody is listening.
import Foundation

let socketPath = "/var/run/talkify-remote-voice.sock"
let packetLoggerPaths = [
  "/Applications/PacketLogger.app/Contents/Resources/packetlogger",
  "/Users/rob/Library/Application Support/GoatRemote/Additional Tools/Hardware/PacketLogger.app/Contents/Resources/packetlogger",
]

func log(_ message: String) {
  FileHandle.standardError.write(Data("talkify-remote-voiced: \(message)\n".utf8))
}

guard let packetLogger = packetLoggerPaths.first(where: {
  FileManager.default.isExecutableFile(atPath: $0)
}) else {
  log("PacketLogger not found. Install Apple's Additional Tools for Xcode.")
  exit(1)
}

// One listener, many short-lived clients. The app connects when it starts
// and stays connected; anything else that connects gets the same stream.
let listener = socket(AF_UNIX, SOCK_STREAM, 0)
guard listener >= 0 else { log("socket() failed"); exit(1) }

unlink(socketPath)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
_ = withUnsafeMutablePointer(to: &address.sun_path) { path in
  path.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: address.sun_path)) {
    strcpy($0, socketPath)
  }
}
let size = socklen_t(MemoryLayout<sockaddr_un>.size)
guard withUnsafePointer(to: &address, {
  $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
}) == 0 else {
  log("bind() failed on \(socketPath)")
  exit(1)
}
// The app runs as the user and this runs as root, so the socket has to be
// reachable by both.
chmod(socketPath, 0o666)
listen(listener, 4)
log("listening on \(socketPath)")

let clientsLock = NSLock()
var clients: [Int32] = []

func broadcast(_ samples: [Int16]) {
  clientsLock.lock()
  let current = clients
  clientsLock.unlock()
  guard !current.isEmpty else { return }

  samples.withUnsafeBytes { bytes in
    for client in current {
      // A client that has gone away or stopped reading must not stall the
      // radio: the write is best effort and a broken pipe drops the client.
      let written = send(client, bytes.baseAddress, bytes.count, 0)
      if written < 0 {
        clientsLock.lock()
        clients.removeAll { $0 == client }
        clientsLock.unlock()
        close(client)
      }
    }
  }
}

func hasClients() -> Bool {
  clientsLock.lock()
  defer { clientsLock.unlock() }
  return !clients.isEmpty
}

// Accepting runs on its own thread so the radio is never waiting on a
// connection, and vice versa.
Thread.detachNewThread {
  while true {
    let client = accept(listener, nil, nil)
    guard client >= 0 else { continue }
    var on: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    clientsLock.lock()
    clients.append(client)
    let count = clients.count
    clientsLock.unlock()
    log("client connected (\(count) total)")
  }
}

/// Runs PacketLogger and feeds every traced packet through the decoder.
/// Returns when PacketLogger exits, which happens if Bluetooth restarts.
func capture() {
  let stream: SiriRemoteVoiceStream
  do {
    stream = try SiriRemoteVoiceStream()
  } catch {
    log("could not start the decoder: \(error). Is libopus installed?")
    exit(1)
  }

  let process = Process()
  process.executableURL = URL(fileURLWithPath: packetLogger)
  process.arguments = ["convert", "-s", "-f", "nhdr"]

  let pipe = Pipe()
  // PacketLogger writes its trace to stderr, not stdout. Discarding stderr
  // discards every packet, and the capture then looks perfectly healthy
  // while decoding nothing at all.
  process.standardError = pipe
  process.standardOutput = pipe

  do { try process.run() } catch {
    log("could not start PacketLogger: \(error)")
    return
  }
  log("capturing")

  var carry = Data()
  while true {
    let chunk = pipe.fileHandleForReading.availableData
    if chunk.isEmpty { break }
    carry.append(chunk)

    while let newline = carry.firstIndex(of: 0x0A) {
      let line = String(decoding: carry[carry.startIndex..<newline], as: UTF8.self)
      carry.removeSubrange(carry.startIndex...newline)

      guard line.contains("Siri"),
            let packet = BluetoothTrace.packet(fromTraceLine: line)
      else { continue }

      for event in stream.accept(packet: packet) {
        switch event {
        case .began: log("voice started")
        case .ended: log("voice ended")
        case let .samples(pcm): broadcast(pcm)
        }
      }
    }
  }

  process.terminate()
  log("PacketLogger exited")
}

// Capture only while something is listening, and restart it if the
// Bluetooth stack takes it down.
while true {
  if hasClients() {
    capture()
  }
  Thread.sleep(forTimeInterval: 2)
}
