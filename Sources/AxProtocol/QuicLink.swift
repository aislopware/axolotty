#if canImport(AxQuic)
internal import AxQuic
public import Dispatch
public import Foundation
import Synchronization

/// The UDP port a host's QUIC link listens on (beside TCP's on the same number).
public enum QuicPort {
    public static let host: UInt16 = 7518
}

public struct QuicError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A UDP socket speaking Axolotty's QUIC (`Rust/axquic`): plaintext, since the tailnet beneath
/// already encrypts and authenticates, and tuned for a key's echo (Slopty's measurements).
public final class QuicEndpoint: @unchecked Sendable {
    private let ptr: OpaquePointer
    private let closed = Atomic<Bool>(false)
    /// The listener's callback box, alive as long as the endpoint.
    private var listener: Unmanaged<ListenBox>?

    /// The bound port (useful after asking for 0).
    public let port: UInt16

    /// Binds `address` ("::" for every address, dual-stack) on `port`; `server` also accepts.
    public init(address: String = "::", port: UInt16 = 0, server: Bool) throws {
        var err = [CChar](repeating: 0, count: 256)
        guard let p = axq_endpoint_bind(address, port, server, &err, err.count) else {
            throw QuicError(String(decoding: err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        ptr = p
        self.port = axq_endpoint_port(p)
    }

    deinit { close() }

    /// Accepts links until closed: `onLink(link, peer address)` for each, on a library thread.
    public func listen(_ onLink: @escaping @Sendable (QuicLink, String) -> Void) {
        let box = Unmanaged.passRetained(ListenBox(onLink))
        listener = box
        axq_endpoint_listen(ptr, box.toOpaque()) { ctx, link, text in
            guard let ctx, let link else { return }
            let box = Unmanaged<ListenBox>.fromOpaque(ctx).takeUnretainedValue()
            box.onLink(QuicLink(link), text.map { String(cString: $0) } ?? "")
        }
    }

    /// Dials `host` (an address or a MagicDNS name) on `port`.
    public func connect(host: String, port: UInt16, timeout: Duration = .seconds(5)) async throws -> QuicLink {
        let ms = UInt32(clamping: timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<QuicLink, any Error>) in
            let box = Unmanaged.passRetained(DialBox(k))
            axq_endpoint_connect(ptr, host, port, ms, box.toOpaque()) { ctx, link, text in
                guard let ctx else { return }
                let box = Unmanaged<DialBox>.fromOpaque(ctx).takeRetainedValue()
                if let link {
                    box.k.resume(returning: QuicLink(link))
                } else {
                    box.k.resume(throwing: QuicError(text.map { String(cString: $0) } ?? "couldn't connect"))
                }
            }
        }
    }

    /// Closes every link on it and frees the socket.
    public func close() {
        guard !closed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        axq_endpoint_close(ptr)
        // The accept loop has ended with the endpoint; a callback already running holds no
        // reference past its own call, so the box can go once the library has let it go.
        if let listener { DispatchQueue.global().asyncAfter(deadline: .now() + 1) { listener.release() } }
    }

    private final class ListenBox: Sendable {
        let onLink: @Sendable (QuicLink, String) -> Void
        init(_ onLink: @escaping @Sendable (QuicLink, String) -> Void) { self.onLink = onLink }
    }

    private final class DialBox {
        let k: CheckedContinuation<QuicLink, any Error>
        init(_ k: CheckedContinuation<QuicLink, any Error>) { self.k = k }
    }
}

/// One QUIC connection as a `FrameLink`: each lane its own stream, decoded on its own.
public final class QuicLink: FrameLink, @unchecked Sendable {
    private let ptr: OpaquePointer
    public let queue: DispatchQueue
    public let bannerText = ""
    private let closedFlag = Atomic<Bool>(false)
    private let started = Atomic<Bool>(false)
    // On `queue` only:
    private var decoders: [UInt32: FrameDecoder] = [:]
    private var onFrame: ((Frame) -> Void)?
    private var onClose: (((any Error)?) -> Void)?
    /// Why this side closed it, told to `onClose` when the library confirms.
    private let closeReason = Mutex<(any Error)?>(nil)

    init(_ ptr: OpaquePointer) {
        self.ptr = ptr
        queue = DispatchQueue(label: "axolotty.quic", qos: .userInteractive)
    }

    deinit {
        // A started link is kept alive by the library until it is closed, so this one either
        // never started or has already ended.
        axq_link_close(ptr, 0)
        axq_link_free(ptr)
    }

    public var isClosed: Bool { closedFlag.load(ordering: .acquiring) }
    public var pendingBytes: Int { axq_link_pending_total(ptr) }
    public func pendingBytes(lane: Int) -> Int { axq_link_pending(ptr, Self.wire(lane)) }

    /// The path's smoothed round trip, once measured.
    public var roundTrip: Duration? {
        let us = axq_link_rtt_us(ptr)
        return us == 0 ? nil : .microseconds(Int(us))
    }

    public func start(onFrame: @escaping (Frame) -> Void, onClose: @escaping ((any Error)?) -> Void) {
        guard !started.exchange(true, ordering: .acquiringAndReleasing) else { return }
        queue.sync {
            self.onFrame = onFrame
            self.onClose = onClose
        }
        // Held by the library until `closed`, its last call.
        let me = Unmanaged.passRetained(self).toOpaque()
        axq_link_start(ptr, me, { ctx, lane, bytes, len in
            guard let ctx, let bytes else { return }
            let link = Unmanaged<QuicLink>.fromOpaque(ctx).takeUnretainedValue()
            let data = Data(bytes: bytes, count: len)
            link.queue.async { link.received(lane, data) }
        }, { ctx, reason in
            guard let ctx else { return }
            let link = Unmanaged<QuicLink>.fromOpaque(ctx).takeRetainedValue()
            let why: (any Error)? = reason.map { QuicError(String(cString: $0)) }
            link.queue.async { link.ended(why) }
        })
    }

    public func send(_ data: Data, lane: Int, priority: Int32) {
        guard !data.isEmpty, !isClosed else { return }
        data.withUnsafeBytes { raw in
            axq_link_send(ptr, Self.wire(lane), priority, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
    }

    public func close(_ error: (any Error)?) {
        guard !closedFlag.exchange(true, ordering: .acquiringAndReleasing) else { return }
        closeReason.withLock { $0 = error }
        if started.load(ordering: .acquiring) {
            axq_link_close(ptr, 0)
        } else {
            queue.async { [self] in onClose?(error) }
        }
    }

    // MARK: On queue

    private func received(_ lane: UInt32, _ data: Data) {
        guard onFrame != nil else { return }
        var decoder = decoders.removeValue(forKey: lane) ?? FrameDecoder()
        decoder.feed(data)
        do {
            while let frame = try decoder.next() { onFrame?(frame) }
            decoders[lane] = decoder
        } catch {
            close(error)
        }
    }

    private func ended(_ remote: (any Error)?) {
        closedFlag.store(true, ordering: .releasing)
        let local = closeReason.withLock { $0 }
        onClose?(local ?? remote)
        onFrame = nil
        onClose = nil
        decoders = [:]
    }

    /// A Swift lane (a hash) as the library's: its low 32 bits, never 0 unless it is control's.
    static func wire(_ lane: Int) -> UInt32 {
        let w = UInt32(truncatingIfNeeded: lane)
        return lane != 0 && w == 0 ? 1 : w
    }
}
#endif
