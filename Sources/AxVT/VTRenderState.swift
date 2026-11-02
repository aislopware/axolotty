package import GhosttyVT

/// A renderer's private copy of what a terminal shows. Updating it is the only
/// moment the renderer touches the terminal (under the caller's lock); building
/// the frame afterwards reads only this copy.
public final class VTRenderState {
    package let handle: GhosttyRenderState

    public init() throws(VTError) {
        var rs: GhosttyRenderState?
        try check(ghostty_render_state_new(nil, &rs))
        guard let rs else { throw .outOfMemory }
        handle = rs
    }

    deinit { ghostty_render_state_free(handle) }

    /// Copies the terminal's visible state. Cheap when little changed.
    public func update(from terminal: VTTerminal) {
        _ = ghostty_render_state_update(handle, terminal.handle)
    }
}

extension VTTerminal {
    /// Sets the default colours (what OSC 104/110/111/112 reset to). Colours a
    /// program set with OSC 4/10/11/12 stay until it resets them.
    public func setDefaultColors(foreground: (UInt8, UInt8, UInt8), background: (UInt8, UInt8, UInt8),
                                 cursor: (UInt8, UInt8, UInt8)?, palette: [(UInt8, UInt8, UInt8)])
    {
        var fg = GhosttyColorRgb(r: foreground.0, g: foreground.1, b: foreground.2)
        var bg = GhosttyColorRgb(r: background.0, g: background.1, b: background.2)
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        if let cursor {
            var c = GhosttyColorRgb(r: cursor.0, g: cursor.1, b: cursor.2)
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &c)
        }
        guard palette.count >= 256 else { return }
        var p = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        for i in 0 ..< 256 { p[i] = GhosttyColorRgb(r: palette[i].0, g: palette[i].1, b: palette[i].2) }
        p.withUnsafeBufferPointer { _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, $0.baseAddress) }
    }
}
