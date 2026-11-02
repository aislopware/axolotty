import AppKit
import Carbon.HIToolbox

/// Secure Keyboard Entry, held while a focused pane reads a hidden line
/// (a password). The system call is a counter: this keeps it balanced, on at
/// most once, whoever asks.
@MainActor
enum SecureInput {
    private static var holders = Set<ObjectIdentifier>()
    private static var enabled = false

    static func set(_ owner: AnyObject, _ on: Bool) {
        let key = ObjectIdentifier(owner)
        if on { holders.insert(key) } else { holders.remove(key) }
        let want = !holders.isEmpty
        guard want != enabled else { return }
        enabled = want
        if want { EnableSecureEventInput() } else { DisableSecureEventInput() }
    }
}
