import Foundation

/// Turns a PacketLogger trace of the Siri Remote into the notifications the
/// remote sent.
///
/// Three layers sit between a trace line and a voice frame, and each one is
/// a pure function here so its rules can be pinned by a test against a real
/// capture rather than against a live remote:
///
///   ACL     a 2-byte header. The handle is the low 12 bits; bits 12-13 are
///           the packet-boundary flag. `0b10` starts a packet and `0b01`
///           continues one, because a 102-byte notification does not fit in
///           a single fragment.
///   L2CAP   a 2-byte length and a 2-byte channel. Channel 4 is ATT.
///   ATT     opcode `0x1B` is a handle-value notification: a 2-byte handle,
///           then the value.
enum BluetoothTrace {
  /// One notification the remote sent.
  struct Notification: Equatable, Sendable {
    let handle: UInt16
    let value: [UInt8]
  }

  /// Reads one trace line. PacketLogger prints a timestamp, the device, the
  /// connection handle, a direction, and then the packet as hex.
  ///
  /// Only received packets matter: the Mac's own writes are in the trace
  /// too, and decoding those would be decoding our own echo.
  static func packet(fromTraceLine line: String) -> [UInt8]? {
    guard let range = line.range(of: "RECV") else { return nil }

    var bytes: [UInt8] = []
    for field in line[range.upperBound...].split(separator: " ") {
      guard field.count == 2, let byte = UInt8(field, radix: 16) else { return nil }
      bytes.append(byte)
    }
    return bytes.isEmpty ? nil : bytes
  }

  /// Rebuilds whole L2CAP packets from ACL fragments.
  ///
  /// Stateful on purpose: a continuation only means anything after the
  /// start it belongs to. A continuation that arrives with no start in hand
  /// is dropped, which is what happens when a capture begins mid-packet.
  struct Reassembler {
    private var pending: [UInt8] = []
    private var wanted = 0

    init() {}

    /// Returns the completed L2CAP packet, if this fragment finished one.
    mutating func accept(_ fragment: [UInt8]) -> [UInt8]? {
      guard fragment.count >= 4 else { return nil }

      let header = UInt16(fragment[0]) | UInt16(fragment[1]) << 8
      let boundary = (header >> 12) & 0b11
      let length = Int(fragment[2]) | Int(fragment[3]) << 8
      let body = Array(fragment.dropFirst(4).prefix(length))

      switch boundary {
      case 0b10:
        guard body.count >= 4 else { return nil }
        let l2capLength = Int(body[0]) | Int(body[1]) << 8
        pending = body
        wanted = 4 + l2capLength
      case 0b01:
        guard !pending.isEmpty else { return nil }
        pending.append(contentsOf: body)
      default:
        return nil
      }

      guard pending.count >= wanted else { return nil }
      let complete = Array(pending.prefix(wanted))
      pending = []
      wanted = 0
      return complete
    }
  }

  /// Reads an ATT handle-value notification out of a complete L2CAP packet.
  static func notification(fromL2CAP packet: [UInt8]) -> Notification? {
    guard packet.count >= 4 else { return nil }

    let length = Int(packet[0]) | Int(packet[1]) << 8
    let channel = UInt16(packet[2]) | UInt16(packet[3]) << 8
    guard channel == 0x0004 else { return nil }

    let payload = Array(packet.dropFirst(4).prefix(length))
    guard payload.count >= 3, payload[0] == 0x1B else { return nil }

    return Notification(
      handle: UInt16(payload[1]) | UInt16(payload[2]) << 8,
      value: Array(payload.dropFirst(3))
    )
  }
}
