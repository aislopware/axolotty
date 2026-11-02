import AxModel
import Testing

@Suite("Ghostty themes")
struct ThemeTests {
    @Test func aGhosttyThemeIsRead() throws {
        let text = """
            # a comment
            palette = 0=#21222c
            palette = 1=#ff5555
            palette = 15 = #ffffff
            background = #282a36
            foreground = #f8f8f2
            cursor-color = #f8f8f2
            cursor-text = #282a36
            selection-background = #44475a
            selection-foreground = #ffffff
            """
        let t = try #require(TerminalTheme.ghostty(name: "Dracula", text: text))
        #expect(t.name == "Dracula")
        #expect(t.background == RGB(hex: "#282a36"))
        #expect(t.isDark)
        #expect(t.ansi.count == 16)
        #expect(t.ansi[1] == RGB(hex: "#ff5555"))
        #expect(t.ansi[15] == RGB(hex: "#ffffff"))
        // Missing entries come from the built-in theme of the same lightness.
        #expect(t.ansi[2] == TerminalTheme.night.ansi[2])
        #expect(t.selectionForeground == RGB(hex: "#ffffff"))
    }

    @Test func aFileWithoutColoursIsNotATheme() {
        #expect(TerminalTheme.ghostty(name: "x", text: "font-size = 13\n") == nil)
    }
}
