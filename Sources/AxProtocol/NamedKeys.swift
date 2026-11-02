/// Keys by name, for scripts and agents (`axolotty send --keys ctrl+c,enter`):
/// "[mods+]key" where mods are ctrl, alt (opt), shift, super (cmd) and key is
/// a letter, a digit, or one of enter, esc, tab, space, backspace, delete,
/// up, down, left, right, home, end, pageup, pagedown, f1…f12. The host
/// encodes the result like a real key press, so the program's keyboard mode
/// (application cursor keys, Kitty protocol) applies.
///
/// Key numbers are `GhosttyKey` raw values (W3C physical keys); a test in
/// AxVTTests pins them to the library's own constants.
public enum NamedKeys {
    static let letterA: UInt16 = 20
    static let digit0: UInt16 = 6
    static let named: [String: UInt16] = [
        "backspace": 53, "enter": 58, "return": 58, "space": 63, "tab": 64, "delete": 68, "end": 69,
        "home": 71, "pagedown": 73, "pageup": 74, "down": 75, "left": 76, "right": 77, "up": 78,
        "esc": 120, "escape": 120,
    ]
    static let f1: UInt16 = 121

    /// One chord, or nil when a part is unknown.
    public static func parse(_ chord: String) -> KeyInput? {
        let parts = chord.lowercased().split(separator: "+").map { $0.trimmingWhitespace }
        guard let name = parts.last, !name.isEmpty else { return nil }
        var mods: UInt16 = 0
        for m in parts.dropLast() {
            switch m {
            case "ctrl", "control": mods |= KeyInput.ctrl
            case "alt", "opt", "option", "meta": mods |= KeyInput.alt
            case "shift": mods |= KeyInput.shift
            case "super", "cmd", "command": mods |= KeyInput.super
            default: return nil
            }
        }
        if let k = named[name] {
            let text = name == "space" && mods & (KeyInput.ctrl | KeyInput.alt) == 0 ? " " : ""
            return KeyInput(key: k, mods: mods, text: text, unshifted: name == "space" ? 0x20 : 0)
        }
        if name.count >= 2, name.first == "f", let n = Int(name.dropFirst()), (1 ... 12).contains(n) {
            return KeyInput(key: f1 + UInt16(n - 1), mods: mods)
        }
        guard name.count == 1, let u = name.unicodeScalars.first, u.isASCII else { return nil }
        let v = UInt16(u.value)
        let key: UInt16
        switch u {
        case "a" ... "z": key = letterA + (v - 0x61)
        case "0" ... "9": key = digit0 + (v - 0x30)
        default: return nil
        }
        var text = String(u)
        if mods & KeyInput.shift != 0 { text = text.uppercased() }
        return KeyInput(key: key, mods: mods, consumedMods: mods & KeyInput.shift, text: text, unshifted: u.value)
    }

    /// "ctrl+c,enter" → presses, in order; nil names the first bad chord.
    public static func parseList(_ list: String) -> Result<[KeyInput], BadChord> {
        var out: [KeyInput] = []
        for chord in list.split(separator: ",") {
            guard let k = parse(String(chord)) else { return .failure(BadChord(chord: String(chord))) }
            out.append(k)
        }
        return .success(out)
    }

    public struct BadChord: Error, Equatable {
        public var chord: String
        public init(chord: String) { self.chord = chord }
    }
}

private extension Substring {
    var trimmingWhitespace: String {
        String(drop(while: { $0 == " " }).reversed().drop(while: { $0 == " " }).reversed())
    }
}
