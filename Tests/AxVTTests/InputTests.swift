import AxVT
import GhosttyVT
import Testing

/// Input is encoded against the authoritative terminal's live modes.
@Suite struct InputTests {
    private func make() throws -> (VTTerminal, VTInputEncoder) {
        let t = try VTTerminal(cols: 80, rows: 24)
        return (t, VTInputEncoder(terminal: t))
    }

    private func key(_ e: VTInputEncoder, _ k: GhosttyKey, text: String = "", mods: UInt16 = 0) -> String {
        String(decoding: e.key(action: .press, key: UInt16(k.rawValue), mods: mods, consumedMods: 0, text: text,
                               unshifted: text.unicodeScalars.first.map(\.value) ?? 0, composing: false),
               as: UTF8.self)
    }

    @Test func plainKeysAndControl() throws {
        let (_, e) = try make()
        #expect(key(e, GHOSTTY_KEY_ENTER) == "\r")
        #expect(key(e, GHOSTTY_KEY_BACKSPACE) == "\u{7F}")
        #expect(key(e, GHOSTTY_KEY_TAB) == "\t")
        #expect(key(e, GHOSTTY_KEY_ESCAPE) == "\u{1B}")
        #expect(key(e, GHOSTTY_KEY_UNIDENTIFIED, text: "é") == "é")
    }

    @Test func cursorKeysFollowDECCKM() throws {
        let (t, e) = try make()
        #expect(key(e, GHOSTTY_KEY_ARROW_UP) == "\u{1B}[A")
        _ = t.write("\u{1B}[?1h")
        #expect(key(e, GHOSTTY_KEY_ARROW_UP) == "\u{1B}OA")
    }

    @Test func kittyKeyboardFlagsAreHonoured() throws {
        let (t, e) = try make()
        _ = t.write("\u{1B}[>1u")  // disambiguate escape codes
        #expect(key(e, GHOSTTY_KEY_ESCAPE) == "\u{1B}[27u")
    }

    @Test func pasteIsBracketedOnlyWhenAsked() throws {
        let (t, e) = try make()
        #expect(String(decoding: e.paste("a\nb"), as: UTF8.self) == "a\rb")
        _ = t.write("\u{1B}[?2004h")
        #expect(String(decoding: e.paste("a\nb"), as: UTF8.self) == "\u{1B}[200~a\nb\u{1B}[201~")
        #expect(VTInputEncoder.pasteIsUnsafe("rm -rf /\n"))
        #expect(!VTInputEncoder.pasteIsUnsafe("ls"))
    }

    @Test func focusReportsNeedMode1004() throws {
        let (t, e) = try make()
        #expect(e.focus(true).isEmpty)
        _ = t.write("\u{1B}[?1004h")
        #expect(String(decoding: e.focus(true), as: UTF8.self) == "\u{1B}[I")
        #expect(String(decoding: e.focus(false), as: UTF8.self) == "\u{1B}[O")
    }

    @Test func mouseNeedsTrackingAndUsesSGR() throws {
        let (t, e) = try make()
        #expect(e.mouse(action: .press, button: 1, mods: 0, x: 25, y: 35, cellWidth: 10, cellHeight: 20).isEmpty)
        _ = t.write("\u{1B}[?1000h\u{1B}[?1006h")
        let press = e.mouse(action: .press, button: 1, mods: 0, x: 25, y: 35, cellWidth: 10, cellHeight: 20)
        #expect(String(decoding: press, as: UTF8.self) == "\u{1B}[<0;3;2M")
        let release = e.mouse(action: .release, button: 1, mods: 0, x: 25, y: 35, cellWidth: 10, cellHeight: 20)
        #expect(String(decoding: release, as: UTF8.self) == "\u{1B}[<0;3;2m")
    }
}

/// Why the Mac client never forwards ⌘ chords: the encoder has no legacy form
/// for Super, so Ctrl+Super+S comes out as CSI 115;5u (Super dropped) even
/// with no keyboard protocol enabled, and a shell prints it as "15;5u".
@Suite struct SuperChordTests {
    @Test func ctrlSuperFallsBackToCSIu() throws {
        let t = try VTTerminal(cols: 80, rows: 24)
        let e = VTInputEncoder(terminal: t)
        let s = UInt16(GHOSTTY_KEY_S.rawValue)
        let ctrl = e.key(action: .press, key: s, mods: 1 << 1, consumedMods: 0, text: "s", unshifted: 115, composing: false)
        #expect(ctrl == [0x13])
        let ctrlSuper = e.key(action: .press, key: s, mods: 1 << 1 | 1 << 3, consumedMods: 0, text: "s", unshifted: 115,
                              composing: false)
        #expect(String(decoding: ctrlSuper, as: UTF8.self) == "\u{1B}[115;5u")
    }
}
