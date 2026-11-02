import Foundation

/// A file sent to a host (`ClientMessage.file`): how it is cut, how big it
/// may be, and what it is called there.
public enum HostFile {
    /// Bytes per piece. Small, so a key typed meanwhile waits behind little
    /// (a piece is about 22 KB on the wire once JSON-encoded).
    public static let piece = 16 << 10
    /// Largest file sent.
    public static let maxBytes: UInt64 = 2 << 30
    /// A piece lane holding this much waits before reading more of the file.
    public static let window = 256 << 10

    /// `name` as one plain file name: no folders, nothing hidden, never empty.
    public static func safeName(_ name: String) -> String {
        var n = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .filter { !$0.isNewline && $0 != "\0" && !($0.unicodeScalars.first.map(CharacterSet.controlCharacters.contains) ?? false) }
        while n.hasPrefix(".") { n.removeFirst() }
        n = n.trimmingCharacters(in: .whitespaces)
        if n.utf8.count > 200 {
            let ext = (n as NSString).pathExtension
            let stem = String((n as NSString).deletingPathExtension.prefix(120))
            n = ext.isEmpty ? stem : stem + "." + ext
        }
        return n.isEmpty ? "file" : n
    }
}
