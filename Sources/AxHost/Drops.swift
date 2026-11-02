#if os(macOS)
import AxProtocol
import Foundation

/// Files sent to this Mac from a far pane (`ClientMessage.file`): each in a
/// folder of its own under `root`, under the name it had there, so the path
/// a program is given reads as what was dropped. A file whose link goes
/// before its last piece is removed; folders older than a week go too.
struct Drops {
    let root: URL
    private var open: [UUID: Entry] = [:]
    private var prunedAt: Date?

    private struct Entry {
        var handle: FileHandle?
        let url: URL
        var size: UInt64 = 0
        let owner: ObjectIdentifier
    }

    init(root: URL) { self.root = root }

    /// Takes one piece. Returns nil while the file is still coming; with the
    /// last piece, where it was saved (`.some(nil)` if it couldn't be).
    mutating func put(_ token: UUID, name: String, bytes: Data, last: Bool, from owner: ObjectIdentifier) -> String?? {
        if open[token] == nil { open[token] = start(token, name: name, owner: owner) }
        guard var e = open[token], e.owner == owner else { return last ? .some(nil) : nil }
        if let h = e.handle {
            e.size += UInt64(bytes.count)
            if e.size > HostFile.maxBytes || (try? h.write(contentsOf: bytes)) == nil {
                try? h.close()
                e.handle = nil
                try? FileManager.default.removeItem(at: e.url.deletingLastPathComponent())
            }
        }
        open[token] = e
        guard last else { return nil }
        open[token] = nil
        guard let h = e.handle, (try? h.close()) != nil else { return .some(nil) }
        return .some(e.url.path(percentEncoded: false))
    }

    /// The link went: what it was still sending is removed.
    mutating func drop(owner: ObjectIdentifier) {
        for (token, e) in open where e.owner == owner {
            try? e.handle?.close()
            try? FileManager.default.removeItem(at: e.url.deletingLastPathComponent())
            open[token] = nil
        }
    }

    private mutating func start(_ token: UUID, name: String, owner: ObjectIdentifier) -> Entry {
        prune()
        let fm = FileManager.default
        let dir = root.appending(path: String(token.uuidString.lowercased().prefix(8)), directoryHint: .isDirectory)
        let url = dir.appending(path: HostFile.safeName(name))
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard fm.createFile(atPath: url.path(percentEncoded: false), contents: nil, attributes: [.posixPermissions: 0o600]) else {
                return Entry(handle: nil, url: url, owner: owner)
            }
            return Entry(handle: try FileHandle(forWritingTo: url), url: url, owner: owner)
        } catch {
            return Entry(handle: nil, url: url, owner: owner)
        }
    }

    /// At most hourly: folders not touched in a week go.
    private mutating func prune(now: Date = Date()) {
        if let t = prunedAt, now.timeIntervalSince(t) < 3600 { return }
        prunedAt = now
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for d in dirs {
            let m = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(m) > 7 * 86400 { try? fm.removeItem(at: d) }
        }
    }
}
#endif
