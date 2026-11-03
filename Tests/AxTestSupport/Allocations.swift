import Darwin
import Synchronization

/// Counts the heap allocations a block makes on the calling thread, exactly.
///
/// libmalloc calls `malloc_logger`, when one is set, for every malloc, calloc and realloc
/// in every zone (the hook `MallocStackLogging` uses). A count is a fact about the code, not
/// the machine, so a budget on it holds the same on any Mac and under any load, where a
/// timing bound would not. Sanitizers replace malloc and never call the hook: `works` is
/// false under them, and a budget test is off there.
public enum Allocations {
    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    private static let watched = Atomic<UInt>(0)
    private static let counted = Atomic<Int>(0)
    private static let one = Mutex<Void>(())

    /// The hook, once found. No allocation happens inside it: an atomic load, a compare and
    /// an add. Written only under `one`.
    private nonisolated(unsafe) static let hook: UnsafeMutablePointer<Logger?>? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        return sym.assumingMemoryBound(to: Logger?.self)
    }()

    /// Allocations `body` made on this thread (other threads' are not counted).
    public static func count<R>(_ body: () throws -> R) rethrows -> (count: Int, result: R) {
        try one.withLock { _ in
            guard let hook else { return (0, try body()) }
            _ = counted.load(ordering: .relaxed)
            watched.store(UInt(bitPattern: pthread_self()), ordering: .releasing)
            counted.store(0, ordering: .relaxed)
            hook.pointee = { type, _, _, _, _, _ in
                // stack_logging_type_alloc is 2; a bare vm_allocate (16) is not malloc's.
                guard type & 2 != 0, type & 16 == 0,
                      UInt(bitPattern: pthread_self()) == Allocations.watched.load(ordering: .relaxed)
                else { return }
                Allocations.counted.wrappingAdd(1, ordering: .relaxed)
            }
            defer {
                hook.pointee = nil
                watched.store(0, ordering: .releasing)
            }
            let result = try body()
            return (counted.load(ordering: .relaxed), result)
        }
    }

    /// Allocations per run of `body`, over `runs` runs after one to warm up (buffers growing
    /// to their size, lazy statics).
    public static func each(_ runs: Int, _ body: () throws -> Void) rethrows -> Double {
        try body()
        return Double(try count { for _ in 0 ..< runs { try body() } }.count) / Double(runs)
    }

    /// Whether counting works here: it sees an allocation planted for the purpose.
    public static let works: Bool = {
        let n = count { () -> Int in
            let planted = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
            defer { planted.deallocate() }
            return withExtendedLifetime(planted) { 1 }
        }.count
        return n == 1
    }()
}
