public import Dispatch
public import Foundation

/// A link that carries frames on numbered lanes: in order within a lane, never across lanes.
///
/// Two kinds: `FramedConnection`, one byte stream (a tailnet TCP socket, the local server's
/// Unix socket, ssh's pipes) whose lanes share it a frame at a time; and `QuicLink`, where each
/// lane is a QUIC stream of its own, so a packet lost in one pane's output holds back that pane
/// alone and an echo can leave ahead of everything (`Rust/axquic`).
public protocol FrameLink: AnyObject, Sendable {
    /// Where frames and the close are delivered, in order.
    var queue: DispatchQueue { get }
    var isClosed: Bool { get }
    /// Bytes queued and not yet handed to the transport, every lane.
    var pendingBytes: Int { get }
    /// Bytes queued on one lane (a pane's backlog on this link).
    func pendingBytes(lane: Int) -> Int
    /// Starts reading. Callbacks run on `queue`; `onClose` once and last.
    func start(onFrame: @escaping (Frame) -> Void, onClose: @escaping ((any Error)?) -> Void)
    /// Queues an encoded frame (or several) on `lane`; never blocks. `priority` orders lanes on
    /// a link that can: 1 for an echo, 0 for control and panes, below 0 for bulk.
    func send(_ data: Data, lane: Int, priority: Int32)
    func close(_ error: (any Error)?)
    /// What a remote command printed before its preamble (ssh banners), for diagnostics.
    var bannerText: String { get }
    /// The path's bandwidth in bytes per second, when the link measures it (QUIC's congestion
    /// controller does); nil otherwise.
    var bandwidth: Int? { get }
}

/// Send priorities on a link that orders lanes (QUIC); a byte stream ignores them.
public enum LanePriority {
    /// A pane's output while it answers a key: ahead of every other lane, unpaced.
    public static let echo: Int32 = 1
    public static let normal: Int32 = 0
    /// Forwarded ports: behind the terminals, ahead of files.
    public static let tunnel: Int32 = -1
    /// Files: never ahead of a key's echo.
    public static let bulk: Int32 = -2
}

/// The output a key buys ahead of everything (Slopty's `EchoBurst`): the reads that follow a
/// person's input within `window` go at `LanePriority.echo`, `reads` of them at most, so a flood
/// beside the typing stays at its own priority.
public struct EchoBurst: Sendable {
    /// Output read this long after the input no longer counts as its echo.
    public static let window: Duration = .milliseconds(50)
    /// The echo, and a second write that repaints it (a highlighter recolouring the line).
    public static let reads = 2

    private var until: ContinuousClock.Instant?
    private var left = 0

    public init() {}

    /// A person's input reached the program at `now`.
    public mutating func arm(_ now: ContinuousClock.Instant) {
        until = now + Self.window
        left = Self.reads
    }

    /// The priority of output read at `now`, spending one of the burst's reads when it is an echo.
    public mutating func priority(_ now: ContinuousClock.Instant) -> Int32 {
        guard left > 0, let until, now <= until else { return LanePriority.normal }
        left -= 1
        return LanePriority.echo
    }
}

extension FrameLink {
    public func send(_ data: Data, lane: Int = 0) { send(data, lane: lane, priority: LanePriority.normal) }

    public func send(_ frame: Frame, lane: Int = 0, priority: Int32 = LanePriority.normal) {
        send(Wire.encode(frame), lane: lane, priority: priority)
    }

    public func send(_ message: HostMessage, lane: Int = 0) {
        if let d = try? MessageCodec.frame(message) { send(d, lane: lane, priority: LanePriority.normal) }
    }

    public func send(_ message: ClientMessage, lane: Int = 0, priority: Int32? = nil) {
        if let d = try? MessageCodec.frame(message) { send(d, lane: lane, priority: priority ?? message.priority) }
    }

    public func close() { close(nil) }

    public var bandwidth: Int? { nil }
}

extension ClientMessage {
    /// A person's input rides at the echo's priority, so the key leaves ahead of a file going up.
    public var priority: Int32 {
        switch self {
        case .key, .mouse, .paste, .text: LanePriority.echo
        default: LanePriority.normal
        }
    }
}
