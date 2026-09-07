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

/// Timestamped, because the whole point of this log is to be lined up
/// against the app's: "the helper decoded audio" and "the app received a
/// session" are only useful together.
let logFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "HH:mm:ss.SSS"
  return formatter
}()

func log(_ message: String) {
  let stamp = logFormatter.string(from: Date())
  FileHandle.standardError.write(Data("[\(stamp)] talkify-remote-voiced: \(message)\n".utf8))
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
  // Nobody listening: the trace keeps running, the samples are dropped.
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

var decodedSinceStart = 0

func clientCount() -> Int {
  clientsLock.lock()
  defer { clientsLock.unlock() }
  return clients.count
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

/// Kills any PacketLogger this helper did not start.
///
/// Only one live Bluetooth trace is useful: a second one competes for the
/// same stream and ours is starved, so audio is decoded by nobody while
/// everything reports healthy. Orphans are easy to create — launchd kills
/// this daemon outright for a signature problem, and its PacketLogger
/// child survives with nothing to stop it.
func killStrayPacketLoggers(except ours: pid_t?) {
  let listing = Process()
  listing.executableURL = URL(fileURLWithPath: "/bin/ps")
  listing.arguments = ["-axo", "pid=,command="]
  let pipe = Pipe()
  listing.standardOutput = pipe
  guard (try? listing.run()) != nil else { return }

  // Read before waiting. ps prints more than a pipe buffer holds, so
  // waiting first deadlocks: ps blocks writing, this blocks waiting, and
  // the helper never reaches the capture it was about to start.
  let output = String(
    decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
  )
  listing.waitUntilExit()
  for line in output.split(separator: "\n") {
    guard line.contains("packetlogger") else { continue }
    let fields = line.split(separator: " ", omittingEmptySubsequences: true)
    guard let first = fields.first, let pid = pid_t(first), pid != ours else { continue }
    kill(pid, SIGTERM)
    log("ended a stray PacketLogger (pid \(pid))")
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

  // Before starting ours: a leftover trace starves it.
  killStrayPacketLoggers(except: nil)

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
        case .began:
          decodedSinceStart = 0
          log("voice started, \(clientCount()) client(s) listening")
        case .ended:
          log("voice ended, decoded \(decodedSinceStart) samples")
        case let .samples(pcm):
          broadcast(pcm)
          decodedSinceStart += pcm.count
        }
      }
    }
  }

  process.terminate()
  log("PacketLogger exited")
}

/// Exits when the binary on disk is no longer the one running.
///
/// launchd keeps running whatever it started, so rebuilding the app leaves
/// the old helper serving audio indefinitely — this one had been running
/// five days and none of the changes made in between had ever executed.
/// That is invisible: it works, just not as the version anybody is
/// reading. Exiting lets KeepAlive start the new one.
func binaryHasChanged(since stamp: Date?) -> Bool {
  guard let stamp else { return false }
  let path = CommandLine.arguments[0]
  let current = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  guard let current else { return false }
  return abs(current.timeIntervalSince(stamp)) > 1
}

let ownBinaryStamp = (try? FileManager.default.attributesOfItem(
  atPath: CommandLine.arguments[0]
))?[.modificationDate] as? Date

// Capture continuously, whether or not anybody is listening.
//
// Starting the capture when a client connects looked thrifty and could
// never work: PacketLogger takes about two seconds to begin producing, and
// by then the user has said their sentence and released the button. The
// measured order was the app connecting, the session ending with no audio,
// and the capture starting a tenth of a second after that.
//
// The audio has to already be flowing when the button goes down, so the
// trace runs for the life of the daemon and its samples are dropped when
// nobody is connected.
log("capturing continuously; audio must be flowing before the button is pressed")
while true {
  if binaryHasChanged(since: ownBinaryStamp) {
    log("a newer helper has been installed; exiting so launchd starts it")
    exit(0)
  }
  capture()
  // Only reached if PacketLogger exited: the Bluetooth stack restarting,
  // usually. Pause briefly rather than spinning on a failure.
  Thread.sleep(forTimeInterval: 2)
}
