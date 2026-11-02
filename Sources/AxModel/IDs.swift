public import Foundation

/// Typed identifiers. All are UUIDs so any host or client can mint them without
/// coordination, and they are stable across reconnects and restarts.
public protocol AxID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    var raw: UUID { get }
    init(raw: UUID)
}

extension AxID {
    public init() { self.init(raw: UUID()) }
    public var description: String { String(raw.uuidString.prefix(8)).lowercased() }
    public static func < (a: Self, b: Self) -> Bool { a.raw.uuidString < b.raw.uuidString }
    public init(from decoder: any Decoder) throws { self.init(raw: try UUID(from: decoder)) }
    public func encode(to encoder: any Encoder) throws { try raw.encode(to: encoder) }
    /// Parses a full UUID string.
    public init?(_ string: String) {
        guard let u = UUID(uuidString: string) else { return nil }
        self.init(raw: u)
    }
}

public struct HostID: AxID { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct ClientID: AxID { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct WorkspaceID: AxID { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct SessionID: AxID { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct PaneID: AxID { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
