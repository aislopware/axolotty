#if os(macOS)
// A fault-injecting relay on loopback, after Toxiproxy: a client dials it
// over TCP (so `HostConnection` treats the link as remote and runs its
// liveness), and it splices each connection to the host's Unix socket.
//
// The faults are the ones a remote link meets:
// - `blackout()`: nothing crosses either way, and new dials are refused,
//   as when the path drops. Bytes already read are held, not lost, and go
//   on `restore()`, the way TCP delivers them once the path comes back.
// - `cut()`: every connection reset at once (a NAT that forgot us).
// - `strand()`: every connection so far goes silent for good, with no
//   reset, while new dials are answered: what a Mac waking from sleep or
//   moving to another network finds. `strand(new: true)` takes new dials
//   into the silence as well.
// - `delay`: added to every chunk each way.
//
// Tests on it wait on the events they mean, never on wall-clock bounds;
// the timing rules themselves are held in virtual time (`LinkLivenessTests`).
import AxProtocol
import Darwin
import Foundation
import Synchronization

public final class LinkRelay: @unchecked Sendable {
    public let port: UInt16
    private let listenFD: Int32
    private let target: String

    private struct State {
        var dark = false
        var delay: Duration = .zero
        var fds: [Int32] = []
        var accepted = 0
        var closed = false
        /// Connections numbered below this carry nothing any more.
        var strandedBelow = 0
    }

    private let state = Mutex(State())
    private let lit = NSCondition()

    /// A relay to the Unix socket at `target`, listening on 127.0.0.1.
    public init(to target: String) throws {
        self.target = target
        let fd = try TCPSocket.listen(address: "127.0.0.1", port: 0)
        var sa = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        listenFD = fd
        port = UInt16(bigEndian: sa.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit { close() }

    /// Connections accepted so far: a redial shows as one more.
    public var accepted: Int { state.withLock { $0.accepted } }

    public var delay: Duration {
        get { state.withLock { $0.delay } }
        set { state.withLock { $0.delay = newValue } }
    }

    /// The path drops: nothing crosses, new dials are refused.
    public func blackout() {
        lit.lock()
        state.withLock { $0.dark = true }
        lit.unlock()
    }

    /// The path is back: held bytes go, dials are answered.
    public func restore() {
        lit.lock()
        state.withLock { $0.dark = false }
        lit.broadcast()
        lit.unlock()
    }

    /// Every connection so far goes silent for good (bytes read, never
    /// passed on, nothing reset); new dials are answered as usual. With
    /// `new`, dials from now on are taken and go silent too (a path that
    /// accepts and then carries nothing), until the next `strand()`.
    public func strand(new: Bool = false) { state.withLock { $0.strandedBelow = new ? .max : $0.accepted } }

    /// Resets every connection now.
    public func cut() {
        let fds = state.withLock { s -> [Int32] in
            defer { s.fds = [] }
            return s.fds
        }
        for fd in fds {
            var l = linger(l_onoff: 1, l_linger: 0)  // RST, not FIN
            _ = setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
            shutdown(fd, SHUT_RDWR)
        }
    }

    public func close() {
        guard !state.withLock({ s in defer { s.closed = true }; return s.closed }) else { return }
        shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
        cut()
        restore()
    }

    private var isDark: Bool { state.withLock { $0.dark } }

    private func waitLit() {
        lit.lock()
        while isDark, !state.withLock({ $0.closed }) { lit.wait() }
        lit.unlock()
    }

    private func acceptLoop() {
        while true {
            let c = accept(listenFD, nil, nil)
            guard c >= 0 else {
                if errno == EINTR { continue }
                return
            }
            if isDark {
                var l = linger(l_onoff: 1, l_linger: 0)
                _ = setsockopt(c, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
                Darwin.close(c)
                continue
            }
            guard let u = try? UnixSocket.connect(path: target) else {
                Darwin.close(c)
                continue
            }
            var one: Int32 = 1
            for fd in [c, u] { _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) }
            let number = state.withLock { s -> Int in
                defer { s.accepted += 1 }
                s.fds += [c, u]
                return s.accepted
            }
            let done = Atomic<Int>(0)
            for (from, to) in [(c, u), (u, c)] {
                Thread.detachNewThread { [self] in
                    pump(from, to, number)
                    shutdown(from, SHUT_RDWR)
                    shutdown(to, SHUT_RDWR)
                    if done.add(1, ordering: .acquiringAndReleasing).newValue == 2 {
                        state.withLock { $0.fds.removeAll { $0 == c || $0 == u } }
                        Darwin.close(c)
                        Darwin.close(u)
                    }
                }
            }
        }
    }

    private func pump(_ from: Int32, _ to: Int32, _ number: Int) {
        var buf = [UInt8](repeating: 0, count: 32 << 10)
        while true {
            let n = buf.withUnsafeMutableBytes { read(from, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            if number < state.withLock({ $0.strandedBelow }) { continue }  // into the void
            waitLit()
            let d = delay
            if d > .zero { Thread.sleep(forTimeInterval: Double(d.components.attoseconds) / 1e18 + Double(d.components.seconds)) }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { write(to, $0.baseAddress! + off, n - off) }
                if w < 0, errno == EINTR { continue }
                guard w > 0 else { return }
                off += w
            }
        }
    }
}
#endif
