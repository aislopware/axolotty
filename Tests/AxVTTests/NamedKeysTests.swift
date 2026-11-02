import AxProtocol
import AxVT
import GhosttyVT
import Testing

@Suite struct NamedKeysTests {
    @Test func numbersMatchTheLibrary() throws {
        let pairs: [(String, GhosttyKey)] = [
            ("a", GHOSTTY_KEY_A), ("z", GHOSTTY_KEY_Z), ("0", GHOSTTY_KEY_DIGIT_0), ("9", GHOSTTY_KEY_DIGIT_9),
            ("enter", GHOSTTY_KEY_ENTER), ("esc", GHOSTTY_KEY_ESCAPE), ("tab", GHOSTTY_KEY_TAB),
            ("space", GHOSTTY_KEY_SPACE), ("backspace", GHOSTTY_KEY_BACKSPACE), ("delete", GHOSTTY_KEY_DELETE),
            ("up", GHOSTTY_KEY_ARROW_UP), ("down", GHOSTTY_KEY_ARROW_DOWN), ("left", GHOSTTY_KEY_ARROW_LEFT),
            ("right", GHOSTTY_KEY_ARROW_RIGHT), ("home", GHOSTTY_KEY_HOME), ("end", GHOSTTY_KEY_END),
            ("pageup", GHOSTTY_KEY_PAGE_UP), ("pagedown", GHOSTTY_KEY_PAGE_DOWN), ("f1", GHOSTTY_KEY_F1),
            ("f12", GHOSTTY_KEY_F12),
        ]
        for (name, key) in pairs {
            #expect(NamedKeys.parse(name)?.key == UInt16(key.rawValue), "\(name)")
        }
    }

    @Test func chords() throws {
        let c = try #require(NamedKeys.parse("ctrl+c"))
        #expect(c.mods == KeyInput.ctrl)
        #expect(c.text == "c")
        #expect(NamedKeys.parse("shift+tab")?.mods == KeyInput.shift)
        #expect(NamedKeys.parse("hyper+x") == nil)
        #expect(NamedKeys.parseList("ctrl+c, enter") .map { $0.count } == .success(2))
        #expect(NamedKeys.parseList("ctrl+c,bogus") == .failure(NamedKeys.BadChord(chord: "bogus")))
    }
}
