#if os(macOS)
internal import AxSys
public import Foundation

/// A session's output journal: shared memory written by whichever process holds
/// the reader role (the holder while detached, the server while attached).
/// Offsets are absolute for the life of the session and double as the stream
/// sequence numbers clients acknowledge.
public final class JournalRing: @unchecked Sendable {
    public let fd: Int32
    private let base: UnsafeMutableRawPointer
    private let size: Int

    /// Maps `fd` and takes ownership of it.
    public init(fd: Int32) throws(CustodyError) {
        var size = 0
        guard let p = ax_ring_map(fd, &size) else {
            Darwin.close(fd)
            throw .errno(EINVAL)
        }
        self.fd = fd
        base = p
        self.size = size
    }

    deinit {
        munmap(base, size)
        Darwin.close(fd)
    }

    public var head: UInt64 { ax_ring_head(base) }
    public var tail: UInt64 { ax_ring_tail(base) }
    public var capacity: Int { size - MemoryLayout<ax_ring_header>.size }

    /// Single writer only.
    @discardableResult
    public func append(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        ax_ring_append(base, bytes.baseAddress, bytes.count)
    }

    @discardableResult
    public func append(_ data: Data) -> UInt64 { data.withUnsafeBytes { append($0) } }

    /// Bytes from `offset` to the head (at most `limit`), or nil if `offset` was overwritten.
    public func read(from offset: UInt64, limit: Int = .max) -> Data? {
        let avail = head &- offset
        guard offset <= head else { return nil }
        let n = Int(min(avail, UInt64(min(limit, capacity))))
        var out = Data(count: n)
        let got = out.withUnsafeMutableBytes { ax_ring_read(base, offset, $0.baseAddress, n) }
        guard got >= 0 else { return nil }
        out.count = got
        return out
    }
}
#endif
