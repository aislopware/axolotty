public import Foundation

/// Loads every file with `ext` under `dir` of a test bundle, sorted by name, so a
/// parameterized test names the file that failed.
public struct Fixture: Sendable, CustomStringConvertible {
    public let name: String
    public let bytes: [UInt8]
    public var description: String { name }

    public init(name: String, bytes: [UInt8]) {
        self.name = name
        self.bytes = bytes
    }

    public static func all(in bundle: Bundle, dir: String, ext: String) -> [Fixture] {
        guard let root = bundle.resourceURL?.appending(path: dir),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path())
        else { return [] }
        return names.filter { $0.hasSuffix(".\(ext)") }.sorted().compactMap { name in
            guard let data = try? Data(contentsOf: root.appending(path: name)) else { return nil }
            return Fixture(name: name, bytes: Array(data))
        }
    }
}

/// Deterministic xorshift generator for seeded tests (no global RNG in tests).
public struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
