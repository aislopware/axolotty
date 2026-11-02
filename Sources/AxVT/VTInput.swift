import GhosttyVT

/// Encodes input against the terminal's *current* modes (DECCKM, Kitty keyboard
/// flags, mouse tracking and format, bracketed paste, focus reporting).
///
/// Only the authoritative (server) terminal encodes input, so clients never
/// race mode changes. Every call refreshes the encoders from the terminal.
public final class VTInputEncoder {
    private let terminal: VTTerminal
    private var key: GhosttyKeyEncoder?
    private var keyEvent: GhosttyKeyEvent?
    private var mouse: GhosttyMouseEncoder?
    private var mouseEvent: GhosttyMouseEvent?
    private var anyButtonPressed = false

    public init(terminal: VTTerminal) {
        self.terminal = terminal
        _ = ghostty_key_encoder_new(nil, &key)
        _ = ghostty_key_event_new(nil, &keyEvent)
        _ = ghostty_mouse_encoder_new(nil, &mouse)
        _ = ghostty_mouse_event_new(nil, &mouseEvent)
    }

    deinit {
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(key)
        ghostty_mouse_event_free(mouseEvent)
        ghostty_mouse_encoder_free(mouse)
    }

    public enum KeyAction: UInt8, Sendable { case release = 0, press = 1, `repeat` = 2 }

    /// `key` is a `GhosttyKey` value; `mods`/`consumedMods` are `GHOSTTY_MODS_*` bits;
    /// `text` is what the keyboard layout produced, without Control applied.
    public func key(action: KeyAction, key code: UInt16, mods: UInt16, consumedMods: UInt16, text: String,
                    unshifted: UInt32, composing: Bool, optionAsAlt: Bool = true) -> [UInt8]
    {
        guard let key, let keyEvent else { return [] }
        ghostty_key_encoder_setopt_from_terminal(key, terminal.handle)
        var alt = optionAsAlt ? GHOSTTY_OPTION_AS_ALT_TRUE : GHOSTTY_OPTION_AS_ALT_FALSE
        ghostty_key_encoder_setopt(key, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &alt)
        ghostty_key_event_set_action(keyEvent, GhosttyKeyAction(rawValue: GhosttyKeyAction.RawValue(action.rawValue)))
        ghostty_key_event_set_key(keyEvent, GhosttyKey(rawValue: GhosttyKey.RawValue(code)))
        ghostty_key_event_set_mods(keyEvent, mods)
        ghostty_key_event_set_consumed_mods(keyEvent, consumedMods)
        ghostty_key_event_set_composing(keyEvent, composing)
        ghostty_key_event_set_unshifted_codepoint(keyEvent, unshifted)
        var utf8 = Array(text.utf8)
        return utf8.withUnsafeMutableBufferPointer { t in
            t.withMemoryRebound(to: CChar.self) { c in
                ghostty_key_event_set_utf8(keyEvent, c.baseAddress, c.count)
                return encode { ghostty_key_encoder_encode(key, keyEvent, $0, $1, $2) }
            }
        }
    }

    public enum MouseAction: UInt8, Sendable { case press = 0, release = 1, motion = 2 }

    /// Position in surface pixels relative to the grid's top-left. Returns no bytes
    /// when the program does not track the mouse.
    public func mouse(action: MouseAction, button: UInt8, mods: UInt16, x: Double, y: Double,
                      cellWidth: UInt32, cellHeight: UInt32) -> [UInt8]
    {
        guard let mouse, let mouseEvent, cellWidth > 0, cellHeight > 0 else { return [] }
        ghostty_mouse_encoder_setopt_from_terminal(mouse, terminal.handle)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.cell_width = cellWidth
        size.cell_height = cellHeight
        size.screen_width = UInt32(terminal.cols) * cellWidth
        size.screen_height = UInt32(terminal.rows) * cellHeight
        ghostty_mouse_encoder_setopt(mouse, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        if action == .press, button != 0, button < 4 { anyButtonPressed = true }
        if action == .release { anyButtonPressed = false }
        var pressed = anyButtonPressed
        ghostty_mouse_encoder_setopt(mouse, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)
        var track = true
        ghostty_mouse_encoder_setopt(mouse, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &track)
        ghostty_mouse_event_set_action(mouseEvent, GhosttyMouseAction(rawValue: GhosttyMouseAction.RawValue(action.rawValue)))
        if button == 0 {
            ghostty_mouse_event_clear_button(mouseEvent)
        } else {
            ghostty_mouse_event_set_button(mouseEvent, GhosttyMouseButton(rawValue: GhosttyMouseButton.RawValue(button)))
        }
        ghostty_mouse_event_set_mods(mouseEvent, mods)
        ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(x: Float(x), y: Float(y)))
        return encode { ghostty_mouse_encoder_encode(mouse, mouseEvent, $0, $1, $2) }
    }

    /// Paste text framed per the terminal's bracketed-paste mode, with unsafe
    /// control bytes neutralised.
    public func paste(_ text: String) -> [UInt8] {
        var data = Array(text.utf8)
        let bracketed = terminal.mode(2004)
        return data.withUnsafeMutableBufferPointer { d in
            d.withMemoryRebound(to: CChar.self) { c in
                encode { ghostty_paste_encode(c.baseAddress, c.count, bracketed, $0, $1, $2) }
            }
        }
    }

    /// True when pasting `text` unbracketed could run commands.
    public static func pasteIsUnsafe(_ text: String) -> Bool {
        var t = Array(text.utf8)
        return t.withUnsafeMutableBufferPointer { b in
            b.withMemoryRebound(to: CChar.self) { !ghostty_paste_is_safe($0.baseAddress, $0.count) }
        }
    }

    /// Focus in/out report, only when the program enabled mode 1004.
    public func focus(_ gained: Bool) -> [UInt8] {
        guard terminal.mode(1004) else { return [] }
        return encode { ghostty_focus_encode(gained ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST, $0, $1, $2) }
    }

    /// Runs a ghostty `(buf, cap, &len)` encoder, growing the buffer once if needed.
    private func encode(_ body: (UnsafeMutablePointer<CChar>?, Int, UnsafeMutablePointer<Int>) -> GhosttyResult) -> [UInt8] {
        var cap = 128
        for _ in 0 ..< 2 {
            var out = [CChar](repeating: 0, count: cap)
            var len = 0
            let r = out.withUnsafeMutableBufferPointer { body($0.baseAddress, $0.count, &len) }
            if r == GHOSTTY_SUCCESS { return out.prefix(len).map { UInt8(bitPattern: $0) } }
            if r != GHOSTTY_OUT_OF_SPACE { return [] }
            cap = len
        }
        return []
    }
}

extension VTTerminal {
    /// A DEC private mode (`ansi: false`) or ANSI mode value.
    public func mode(_ number: UInt16, ansi: Bool = false) -> Bool {
        var cfg = GhosttyTerminalModeConfig()
        cfg.mode = GhosttyMode(number & 0x7FFF | (ansi ? 0x8000 : 0))
        guard ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MODE, &cfg) == GHOSTTY_SUCCESS else { return false }
        return cfg.value
    }
}
