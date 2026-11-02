public import AxModel
public import Foundation

/// The envelope every Axolotty link speaks (Unix socket, TLS, stdio):
///
///     u32 len (LE, bytes after this field) · u8 type · u8 flags · payload
///
/// Control messages are JSON-encoded `Codable` values (rare, small, evolvable by
/// adding optional fields). Terminal bytes never touch a codec: they ride raw
/// `output` and `snapshot` frames addressed by pane id and journal offset.
public enum FrameType: UInt8, Sendable {
    case control = 0x01
    case output = 0x02
    case snapshot = 0x03
    case ack = 0x05
}

public struct FrameFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let first = FrameFlags(rawValue: 1 << 1)
    public static let last = FrameFlags(rawValue: 1 << 2)
}

public enum Frame: Sendable, Equatable {
    case control(Data)
    /// Program output for `pane`, starting at journal offset `offset`.
    case output(pane: PaneID, offset: UInt64, bytes: Data)
    /// A slice of a libghostty snapshot taken at journal offset `at`.
    case snapshot(pane: PaneID, at: UInt64, flags: FrameFlags, bytes: Data)
    /// The client applied everything for `pane` up to `offset`.
    case ack(pane: PaneID, offset: UInt64)
}

public enum Wire {
    /// The wire generation. Bumped only for a change an older peer can't skip.
    public static let version = 1
    /// What this build can do beyond the generation's baseline.
    public static let features = ["heartbeat", "bridge"]
    /// What `axolotty bridge` prints before it splices: a client reading a
    /// remote command's output skips everything up to and including it (ssh
    /// banners, rc files that echo).
    public static let bridgePreamble = Data("\u{0}AXOLOTTY-BRIDGE\u{0}\(version)\n".utf8)
    /// Largest frame either side accepts.
    public static let maxFrame = 1 << 20
    /// Data frames are cut to this size, so a lane switches often: on a
    /// lossy TCP link an echo waits behind at most the rest of one frame
    /// and `notSentLowat` (LinkSimTests: 32 KiB frames held echo at p50 29 /
    /// p99 71 ms under 1 % loss, 8 KiB at 16 / 46 ms, for the same rate).
    public static let maxData = 8 << 10
    /// TCP_NOTSENT_LOWAT on TCP links: little unsent data in the kernel, so
    /// the lanes, not one FIFO socket buffer, decide what goes next.
    public static let notSentLowat = 4 << 10

    public static func encode(_ frame: Frame) -> Data {
        var out = Data()
        func header(_ type: FrameType, _ flags: FrameFlags, _ payloadCount: Int) {
            out.reserveCapacity(4 + 2 + payloadCount)
            appendLE(&out, UInt32(2 + payloadCount))
            out.append(type.rawValue)
            out.append(flags.rawValue)
        }
        switch frame {
        case let .control(json):
            header(.control, [], json.count)
            out.append(json)
        case let .output(pane, offset, bytes):
            header(.output, [], 24 + bytes.count)
            appendID(&out, pane)
            appendLE(&out, offset)
            out.append(bytes)
        case let .snapshot(pane, at, flags, bytes):
            header(.snapshot, flags, 24 + bytes.count)
            appendID(&out, pane)
            appendLE(&out, at)
            out.append(bytes)
        case let .ack(pane, offset):
            header(.ack, [], 24)
            appendID(&out, pane)
            appendLE(&out, offset)
        }
        return out
    }

    static func appendLE<T: FixedWidthInteger>(_ d: inout Data, _ v: T) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }

    static func appendID(_ d: inout Data, _ id: PaneID) {
        withUnsafeBytes(of: id.raw.uuid) { d.append(contentsOf: $0) }
    }
}

public enum WireError: Error, Equatable, Sendable {
    case frameTooLarge(Int)
    case malformed(String)
    case unknownType(UInt8)
}

/// Incremental frame decoder: feed arbitrary chunks, take whole frames.
public struct FrameDecoder: Sendable {
    private var buffer = Data()
    private var start = 0
    public let limit: Int

    public init(limit: Int = Wire.maxFrame) { self.limit = limit }

    public mutating func feed(_ bytes: some DataProtocol) { buffer.append(contentsOf: bytes) }

    /// Next complete frame, nil when more bytes are needed.
    public mutating func next() throws(WireError) -> Frame? {
        let available = buffer.count - start
        guard available >= 4 else { return nil }
        let len = Int(readLE(UInt32.self, at: start))
        guard len >= 2, len <= limit else { throw .frameTooLarge(len) }
        guard available >= 4 + len else { return nil }
        let body = start + 4
        let typeByte = buffer[buffer.startIndex + body]
        let flags = FrameFlags(rawValue: buffer[buffer.startIndex + body + 1])
        let payload = (buffer.startIndex + body + 2) ..< (buffer.startIndex + body + len)
        start += 4 + len
        defer { compact() }
        guard let type = FrameType(rawValue: typeByte) else { throw .unknownType(typeByte) }
        switch type {
        case .control:
            return .control(Data(buffer[payload]))
        case .output, .snapshot, .ack:
            guard payload.count >= 24 else { throw .malformed("short data frame") }
            let pane = readID(at: payload.lowerBound - buffer.startIndex)
            let offset = readLE(UInt64.self, at: payload.lowerBound - buffer.startIndex + 16)
            let bytes = Data(buffer[(payload.lowerBound + 24) ..< payload.upperBound])
            switch type {
            case .output: return .output(pane: pane, offset: offset, bytes: bytes)
            case .snapshot: return .snapshot(pane: pane, at: offset, flags: flags, bytes: bytes)
            default:
                guard bytes.isEmpty else { throw .malformed("ack with payload") }
                return .ack(pane: pane, offset: offset)
            }
        }
    }

    private mutating func compact() {
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 64 << 10, start > buffer.count / 2 {
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + start)
            start = 0
        }
    }

    private func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var v: T = 0
        _ = withUnsafeMutableBytes(of: &v) { dst in
            buffer.copyBytes(to: dst, from: (buffer.startIndex + offset) ..< (buffer.startIndex + offset + MemoryLayout<T>.size))
        }
        return T(littleEndian: v)
    }

    private func readID(at offset: Int) -> PaneID {
        var u = UUID().uuid
        _ = withUnsafeMutableBytes(of: &u) { dst in
            buffer.copyBytes(to: dst, from: (buffer.startIndex + offset) ..< (buffer.startIndex + offset + 16))
        }
        return PaneID(raw: UUID(uuid: u))
    }
}
