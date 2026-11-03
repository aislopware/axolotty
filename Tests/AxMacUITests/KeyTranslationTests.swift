import AppKit
@testable import AxMacUI
import AxProtocol
import AxVT
import Testing

/// A key as the person pressed it, read off a synthetic `NSEvent`: what the host's encoder
/// is told, which decides whether ⌃C, ⌥←, ⇧A and the rest do on the far Mac what they do here.
/// The layout-dependent cases assume the ABC (or US) layout, and are off under any other.
@Suite("Key translation")
struct KeyTranslationTests {
    nonisolated static let latin: Bool = {
        let id = UserDefaults(suiteName: "com.apple.HIToolbox")?.string(forKey: "AppleCurrentKeyboardLayoutInputSourceID")
        return id == "com.apple.keylayout.ABC" || id == "com.apple.keylayout.US"
    }()

    /// NX_DEVICELALTKEYMASK and NX_DEVICERALTKEYMASK: which Option is down.
    static let leftOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
    static let rightOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)

    static func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown,
                    chars: String = "", plain: String = "") -> NSEvent
    {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: plain, isARepeat: false,
                         keyCode: code)!
    }

    @Test func everyModifierIsReportedAndNothingElse() {
        #expect(KeyTranslation.mods([]) == 0)
        #expect(KeyTranslation.mods([.shift, .control, .option, .command])
            == KeyInput.shift | KeyInput.ctrl | KeyInput.alt | KeyInput.super)
        #expect(KeyTranslation.mods([.capsLock, .function, .numericPad]) == 0, "locks and the fn key are not modifiers")
    }

    @Test(arguments: [
        (Preferences.OptionAsAlt.off, false, false), (.left, true, false), (.right, false, true), (.both, true, true),
    ])
    func optionIsAltOnTheSideTheSettingNames(pref: Preferences.OptionAsAlt, left: Bool, right: Bool) {
        #expect(KeyTranslation.optionIsAlt(Self.key(14, Self.leftOption), pref) == left)
        #expect(KeyTranslation.optionIsAlt(Self.key(14, Self.rightOption), pref) == right)
        #expect(!KeyTranslation.optionIsAlt(Self.key(14, [.shift]), pref), "no Option, no Alt")
    }

    @Test(.enabled(if: latin)) func controlLeavesTheLetterForTheHostToEncode() {
        // ⌃C reaches the far shell as ETX because the host's encoder applies Control to "c".
        let e = Self.key(8, .control)
        #expect(KeyTranslation.text(e, optionAsAlt: false) == "c")
        let k = KeyTranslation.input(e, action: .press, text: "c", optionAsAlt: false)
        #expect(k.key == VTKeys.mac(8) && k.mods == KeyInput.ctrl && k.consumedMods == 0 && k.unshifted == 0x63)
    }

    @Test(.enabled(if: latin)) func shiftIsConsumedByTheCapitalItMade() {
        let e = Self.key(0, .shift)
        #expect(KeyTranslation.text(e, optionAsAlt: false) == "A")
        let k = KeyTranslation.input(e, action: .press, text: "A", optionAsAlt: false)
        #expect(k.mods == KeyInput.shift && k.consumedMods == KeyInput.shift, "else ⇧A would arrive as shift+A")
        #expect(k.unshifted == 0x61, "the key's own letter, for the Kitty protocol")
    }

    @Test(.enabled(if: latin)) func optionAsAltSendsTheLetterAndOptionOtherwiseMakesItsCharacter() {
        let e = Self.key(17, Self.leftOption)  // ⌥T
        #expect(KeyTranslation.text(e, optionAsAlt: true) == "t", "Alt-t, for readline's transpose-words")
        let alt = KeyTranslation.input(e, action: .press, text: "t", optionAsAlt: true)
        #expect(alt.mods == KeyInput.alt && alt.consumedMods == 0)
        let made = KeyTranslation.text(e, optionAsAlt: false)
        #expect(made == "†", "the layout's ⌥T")
        let typed = KeyTranslation.input(e, action: .press, text: made, optionAsAlt: false)
        #expect(typed.consumedMods == KeyInput.alt, "Option made the character: not Alt as well")
    }

    @Test(.enabled(if: latin)) func commandNeverReachesTheText() {
        #expect(KeyTranslation.text(Self.key(9, .command), optionAsAlt: false) == "v")
    }

    @Test func arrowsAndFunctionKeysCarryNoText() {
        for code: UInt16 in [123, 124, 125, 126, 122, 115, 119] {  // ← → ↓ ↑ F1 Home End
            let e = Self.key(code, .function)
            #expect(KeyTranslation.text(e, optionAsAlt: false) == "", "key \(code)")
            #expect(KeyTranslation.unshifted(e) == 0, "key \(code)")
        }
        #expect(KeyTranslation.text(Self.key(0, type: .keyUp), optionAsAlt: false) == "", "a release types nothing")
        #expect(KeyTranslation.unshifted(Self.key(51, [])) == 0, "⌫'s layout character is a control code, not a key's letter")
    }

    @Test func controlCharactersAndPrivateUseAreNotText() {
        #expect(KeyTranslation.printable("\u{3}") == "")
        #expect(KeyTranslation.printable("\u{7F}") == "")
        #expect(KeyTranslation.printable("\u{F700}") == "", "AppKit's up arrow")
        #expect(KeyTranslation.printable("é") == "é")
        #expect(KeyTranslation.printable("👩‍💻") == "👩‍💻")
        #expect(KeyTranslation.printable("\r\n") == "\r\n", "more than one scalar is text as it came")
    }

    @Test func aModifierKeySaysWhetherItWentDownOrUp() {
        let down = Self.key(56, .shift, type: .flagsChanged), up = Self.key(56, [], type: .flagsChanged)
        #expect(KeyTranslation.modifierAction(down) == .press)
        #expect(KeyTranslation.modifierAction(up) == .release)
        #expect(KeyTranslation.modifierAction(Self.key(61, .option, type: .flagsChanged)) == .press, "right Option")
        #expect(KeyTranslation.modifierAction(Self.key(0, type: .flagsChanged)) == nil)
    }
}

/// The whole way: a key pressed here, as the bytes the far program reads, in the legacy
/// encoding and with every Kitty keyboard flag on. These are the keys shells and editors bind.
@Suite("Keys as bytes")
struct KeyBytesTests {
    static func bytes(_ code: UInt16, _ flags: NSEvent.ModifierFlags, kitty: Bool) throws -> String {
        let t = try VTTerminal(cols: 80, rows: 24)
        if kitty { t.write("\u{1b}[>31u") }
        let e = KeyTranslationTests.key(code, flags)
        let text = KeyTranslation.text(e, optionAsAlt: true)
        let k = KeyTranslation.input(e, action: .press, text: text, optionAsAlt: true)
        let out = VTInputEncoder(terminal: t).key(action: .press, key: k.key, mods: k.mods, consumedMods: k.consumedMods,
                                                  text: k.text, unshifted: k.unshifted, composing: false)
        return String(decoding: out, as: UTF8.self)
    }

    struct Press: Sendable, CustomStringConvertible {
        let name: String, code: UInt16, flags: UInt, legacy: String, kitty: String
        var description: String { name }
    }

    nonisolated static let presses = [
        Press(name: "←", code: 123, flags: NSEvent.ModifierFlags.function.rawValue, legacy: "\u{1b}[D", kitty: "\u{1b}[1;1:1D"),
        Press(name: "⌃← (back a word)", code: 123, flags: NSEvent.ModifierFlags([.function, .control]).rawValue,
              legacy: "\u{1b}[1;5D", kitty: "\u{1b}[1;5:1D"),
        Press(name: "⌥→ as Alt", code: 124, flags: NSEvent.ModifierFlags([.function, .option]).rawValue,
              legacy: "\u{1b}[1;3C", kitty: "\u{1b}[1;3:1C"),
        Press(name: "⌃C", code: 8, flags: NSEvent.ModifierFlags.control.rawValue, legacy: "\u{3}", kitty: "\u{1b}[99;5u"),
        Press(name: "⌃⌫", code: 51, flags: NSEvent.ModifierFlags.control.rawValue, legacy: "\u{8}", kitty: "\u{1b}[127;5u"),
    ]

    @Test(.enabled(if: KeyTranslationTests.latin), arguments: presses)
    func aKeyArrivesAsTheSequenceProgramsBind(_ p: Press) throws {
        let flags = NSEvent.ModifierFlags(rawValue: p.flags)
        #expect(try Self.bytes(p.code, flags, kitty: false) == p.legacy)
        #expect(try Self.bytes(p.code, flags, kitty: true) == p.kitty)
    }
}
