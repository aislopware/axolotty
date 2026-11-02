import AppKit
import AxProtocol
import AxVT

/// NSEvent → `KeyInput`. The host encodes against its terminal's modes, so this
/// only reports what physically happened: the W3C key, modifiers, and the text the
/// layout produced (Control not applied; the encoder does that).
enum KeyTranslation {
    static func mods(_ flags: NSEvent.ModifierFlags) -> UInt16 {
        var m: UInt16 = 0
        if flags.contains(.shift) { m |= KeyInput.shift }
        if flags.contains(.control) { m |= KeyInput.ctrl }
        if flags.contains(.option) { m |= KeyInput.alt }
        if flags.contains(.command) { m |= KeyInput.super }
        return m
    }

    /// Whether Option acts as Alt for this event (per side).
    static func optionIsAlt(_ event: NSEvent, _ pref: Preferences.OptionAsAlt) -> Bool {
        guard event.modifierFlags.contains(.option) else { return false }
        let raw = event.modifierFlags.rawValue
        let left = raw & UInt(NX_DEVICELALTKEYMASK) != 0, right = raw & UInt(NX_DEVICERALTKEYMASK) != 0
        return switch pref {
        case .off: false
        case .both: true
        case .left: left
        case .right: right
        }
    }

    /// The text this key produces with Control (and Option-as-Alt) removed;
    /// empty for control characters and function keys.
    static func text(_ event: NSEvent, optionAsAlt: Bool) -> String {
        guard event.type == .keyDown else { return "" }
        var flags = event.modifierFlags
        flags.remove(.control)
        flags.remove(.command)
        if optionAsAlt { flags.remove(.option) }
        return printable(event.characters(byApplyingModifiers: flags) ?? "")
    }

    static func printable(_ s: String) -> String {
        guard let first = s.unicodeScalars.first else { return "" }
        if s.unicodeScalars.count == 1 {
            let v = first.value
            if v < 0x20 || v == 0x7F || (0xF700 ... 0xF8FF).contains(v) { return "" }
        }
        return s
    }

    static func unshifted(_ event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp,
              let s = event.characters(byApplyingModifiers: []), let u = s.unicodeScalars.first
        else { return 0 }
        return (0xF700 ... 0xF8FF).contains(u.value) ? 0 : u.value
    }

    static func input(_ event: NSEvent, action: KeyInput.Action, text: String, optionAsAlt: Bool,
                      composing: Bool = false) -> KeyInput
    {
        let mods = mods(event.modifierFlags)
        var consumed: UInt16 = 0
        if !text.isEmpty {
            if event.modifierFlags.contains(.shift) { consumed |= KeyInput.shift }
            if event.modifierFlags.contains(.option), !optionAsAlt { consumed |= KeyInput.alt }
        }
        return KeyInput(action: action, key: VTKeys.mac(event.keyCode), mods: mods, consumedMods: consumed, text: text,
                        unshifted: unshifted(event), composing: composing)
    }

    /// Modifier key presses for `flagsChanged` (Kitty "report all keys").
    static func modifierAction(_ event: NSEvent) -> KeyInput.Action? {
        let mask: NSEvent.ModifierFlags? = switch event.keyCode {
        case 56, 60: .shift
        case 59, 62: .control
        case 58, 61: .option
        case 55, 54: .command
        case 57: .capsLock
        default: nil
        }
        guard let mask else { return nil }
        return event.modifierFlags.contains(mask) ? .press : .release
    }
}
