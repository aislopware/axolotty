public import AxModel
public import AxProtocol
public import AxVT
import Foundation
import Synchronization

/// A client-side replica of one pane's terminal.
///
/// Fed only by the host's stream (snapshot, then output by journal offset), it
/// never answers the program: `replies` is off, so N clients never reply N
/// times. Scrollback, selection and search run locally on it.
///
/// Thread-safety: the connection applies frames on its queue while the UI reads
/// on the main thread; both go through `withTerminal`, which holds a lock.
public final class MirrorTerminal: @unchecked Sendable {
    public let pane: PaneID
    private let lock = NSLock()
    private var terminal: VTTerminal? {
        // A search is bound to one terminal: release it before that one goes.
        willSet { if newValue !== terminal { endSearchLocked() } }
    }
    private var search: VTSearch?
    private var appearance: Appearance?
    /// Journal offset of the next byte this mirror expects.
    private var applied: UInt64 = 0
    private var snapshot: [UInt8]?
    private var snapshotAt: UInt64 = 0
    private let changes = Atomic<UInt64>(0)
    private let observer = Mutex<(@Sendable () -> Void)?>(nil)
    /// The raw output as it is applied (`axolotty attach`), under the lock,
    /// so it is ordered with `withTerminal`. Nil for views.
    private var tap: (@Sendable (UnsafeRawBufferPointer) -> Void)?

    init(pane: PaneID, appearance: Appearance?) {
        self.pane = pane
        self.appearance = appearance
    }

    /// Bumps on every applied change; renderers compare it per frame.
    public var generation: UInt64 { changes.load(ordering: .acquiring) }

    /// Called after every change, on whatever thread made it (usually the
    /// connection queue). Views use it to wake their display link; keep it cheap.
    public func onChange(_ body: (@Sendable () -> Void)?) { observer.withLock { $0 = body } }

    /// Receives every output byte applied from now on, in order, while the
    /// mirror's lock is held (keep it to a write).
    public func onOutput(_ body: (@Sendable (UnsafeRawBufferPointer) -> Void)?) { lock.withLock { tap = body } }

    /// Marks a local change (selection, scrolling) so renderers pick it up.
    public func touch() { bump() }

    /// The offset this mirror has applied through (for warm resume).
    public var offset: UInt64 { lock.withLock { applied } }

    public var isReady: Bool { lock.withLock { terminal != nil } }

    /// Runs `body` with exclusive access to the terminal (nil until the first snapshot arrives).
    public func withTerminal<R>(_ body: (VTTerminal) throws -> R) rethrows -> R? {
        try lock.withLock { try terminal.map(body) }
    }

    // MARK: Find

    /// Runs `body` with the terminal and a search for `needle` caught up with
    /// it (created on first use, and again after a snapshot replaced the
    /// terminal). nil until the first snapshot.
    public func withSearch<R>(_ needle: String, _ body: (VTTerminal, VTSearch) throws -> R) rethrows -> R? {
        try lock.withLock {
            guard let terminal else { return nil }
            if search.map({ !$0.isBound(to: terminal) }) ?? true {
                search?.close()
                search = VTSearch(terminal)
            }
            guard let search else { return nil }
            search.setNeedle(needle)
            search.update()
            return try body(terminal, search)
        }
    }

    /// Ends the find: drops the search and its state in the terminal.
    public func endSearch() {
        lock.withLock { endSearchLocked() }
        bump()
    }

    private func endSearchLocked() {
        search?.close()
        search = nil
    }

    deinit { search?.close() }

    public func setAppearance(_ a: Appearance) {
        lock.withLock {
            appearance = a
            if let terminal { Self.apply(a, to: terminal) }
        }
        bump()
    }

    // MARK: Stream (connection queue)

    func attached(cols: UInt16, rows: UInt16, at: UInt64, resume: Bool) {
        lock.withLock {
            if resume, terminal != nil {
                applied = at
            } else {
                snapshot = []
                snapshotAt = at
            }
        }
    }

    func snapshotChunk(at: UInt64, flags: FrameFlags, bytes: Data) {
        let restored: Bool = lock.withLock {
            if flags.contains(.first) || snapshot == nil {
                snapshot = []
                snapshotAt = at
            }
            snapshot?.append(contentsOf: bytes)
            guard flags.contains(.last), let snap = snapshot else { return false }
            snapshot = nil
            guard let t = try? VTTerminal.restore(snap, replies: false) else { return false }
            if let appearance { Self.apply(appearance, to: t) }
            terminal = t
            applied = snapshotAt
            return true
        }
        if restored { bump() }
    }

    enum OutputResult { case applied(Int), duplicate, gap }

    /// Applies output at `offset`. A gap means bytes were lost: the caller re-attaches.
    func output(at offset: UInt64, _ bytes: Data) -> OutputResult {
        let r: OutputResult = lock.withLock {
            guard let terminal, snapshot == nil else { return .duplicate }  // still waiting for a snapshot
            let end = offset + UInt64(bytes.count)
            if end <= applied { return .duplicate }
            if offset > applied { return .gap }
            let skip = Int(applied - offset)
            bytes.withUnsafeBytes { raw in
                let fresh = UnsafeRawBufferPointer(rebasing: raw[skip...])
                _ = terminal.write(fresh)
                tap?(fresh)
            }
            applied = end
            return .applied(bytes.count - skip)
        }
        if case .applied = r { bump() }
        return r
    }

    func resized(cols: UInt16, rows: UInt16) {
        lock.withLock { terminal?.resize(cols: cols, rows: rows) }
        bump()
    }

    private func bump() {
        changes.add(1, ordering: .releasing)
        observer.withLock { $0 }?()
    }

    private static func apply(_ a: Appearance, to t: VTTerminal) {
        t.setDefaultColors(foreground: (a.foreground.r, a.foreground.g, a.foreground.b),
                           background: (a.background.r, a.background.g, a.background.b),
                           cursor: (a.cursor.r, a.cursor.g, a.cursor.b),
                           palette: a.palette.map { ($0.r, $0.g, $0.b) })
    }
}
