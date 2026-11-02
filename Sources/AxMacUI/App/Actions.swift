import AppKit

/// Every user action, as responder-chain selectors. Menus, the command palette and
/// key bindings all send these with a nil target, so the nearest responder that
/// implements one handles it (terminal → pane container → window controller → app).
@objc protocol AxActions {
    // App
    @objc optional func showCommandPalette(_ sender: Any?)
    @objc optional func showJumpToAgent(_ sender: Any?)
    @objc optional func showConnectToHost(_ sender: Any?)
    @objc optional func showSettings(_ sender: Any?)

    // Window
    @objc optional func newWindow(_ sender: Any?)
    /// Not `toggleSidebar:`: NSWindow implements that itself (for split view
    /// controllers) and would swallow the action before it reaches us.
    @objc optional func toggleSessionSidebar(_ sender: Any?)

    // Workspace and session
    @objc optional func newSession(_ sender: Any?)
    @objc optional func openFolder(_ sender: Any?)
    @objc optional func reopenClosedSession(_ sender: Any?)
    @objc optional func renameSession(_ sender: Any?)
    @objc optional func closeSession(_ sender: Any?)
    @objc optional func selectSessionByNumber(_ sender: Any?)
    @objc optional func selectPreviousSession(_ sender: Any?)
    @objc optional func selectNextSession(_ sender: Any?)
    @objc optional func selectNextAttention(_ sender: Any?)

    // Pane
    @objc optional func splitRight(_ sender: Any?)
    @objc optional func splitDown(_ sender: Any?)
    @objc optional func closePane(_ sender: Any?)
    @objc optional func focusPreviousPane(_ sender: Any?)
    @objc optional func focusNextPane(_ sender: Any?)
    @objc optional func focusPaneLeft(_ sender: Any?)
    @objc optional func focusPaneRight(_ sender: Any?)
    @objc optional func focusPaneUp(_ sender: Any?)
    @objc optional func focusPaneDown(_ sender: Any?)
    @objc optional func resizePaneLeft(_ sender: Any?)
    @objc optional func resizePaneRight(_ sender: Any?)
    @objc optional func resizePaneUp(_ sender: Any?)
    @objc optional func resizePaneDown(_ sender: Any?)
    @objc optional func toggleZoom(_ sender: Any?)
    @objc optional func equalizePanes(_ sender: Any?)

    // Terminal
    @objc optional func clearBuffer(_ sender: Any?)
    @objc optional func scrollToTopOfBuffer(_ sender: Any?)
    @objc optional func scrollToBottomOfBuffer(_ sender: Any?)
    @objc optional func increaseFontSize(_ sender: Any?)
    @objc optional func decreaseFontSize(_ sender: Any?)
    @objc optional func resetFontSize(_ sender: Any?)
    @objc optional func openInEditor(_ sender: Any?)
    @objc optional func newWorktreeSession(_ sender: Any?)
    @objc optional func removeWorktreeSession(_ sender: Any?)
    @objc optional func previousPrompt(_ sender: Any?)
    @objc optional func nextPrompt(_ sender: Any?)
    @objc optional func showFind(_ sender: Any?)
    @objc optional func findNext(_ sender: Any?)
    @objc optional func findPrevious(_ sender: Any?)
}

/// One command: its title, where it lives, its default chord, and its selector.
/// The main menu and the palette are both built from `Command.all`.
struct Command: Identifiable {
    enum Menu: String, CaseIterable { case app, file, edit, view, session, pane, window }

    let id: String
    let title: String
    let menu: Menu
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let action: Selector
    /// Shown in the command palette.
    var inPalette = true
    var tag = 0
    /// Starts a new group in its menu.
    var separatorBefore = false

    /// "⌃⌥⇧⌘K"-style chord for keycaps.
    var chord: String {
        guard !key.isEmpty else { return "" }
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.keyName(key)
    }

    static func keyName(_ key: String) -> String {
        switch key {
        case "\r": "↩"
        case "\u{1b}": "⎋"
        case "\t": "⇥"
        case " ": "Space"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): "→"
        case String(UnicodeScalar(NSHomeFunctionKey)!): "↖"
        case String(UnicodeScalar(NSEndFunctionKey)!): "↘"
        default: key.uppercased()
        }
    }

    private static func fn(_ k: Int) -> String { String(UnicodeScalar(k)!) }

    static let all: [Command] = {
        let cmd: NSEvent.ModifierFlags = .command
        let cs: NSEvent.ModifierFlags = [.command, .shift]
        let co: NSEvent.ModifierFlags = [.command, .option]
        let cc: NSEvent.ModifierFlags = [.command, .control]
        let up = fn(NSUpArrowFunctionKey), down = fn(NSDownArrowFunctionKey)
        let left = fn(NSLeftArrowFunctionKey), right = fn(NSRightArrowFunctionKey)
        var list: [Command] = [
            Command(id: "palette", title: "Command Palette…", menu: .view, key: "p", modifiers: cs,
                    action: #selector((any AxActions).showCommandPalette(_:)), inPalette: false),

            Command(id: "new-session", title: "New Session", menu: .file, key: "t", modifiers: cmd,
                    action: #selector((any AxActions).newSession(_:))),
            Command(id: "new-worktree", title: "New Session in Worktree…", menu: .file, key: "t", modifiers: co,
                    action: #selector((any AxActions).newWorktreeSession(_:))),
            Command(id: "new-window", title: "New Window", menu: .file, key: "n", modifiers: cmd,
                    action: #selector((any AxActions).newWindow(_:))),
            Command(id: "open-folder", title: "Open Folder…", menu: .file, key: "o", modifiers: cmd,
                    action: #selector((any AxActions).openFolder(_:))),
            Command(id: "reopen", title: "Reopen Closed Session", menu: .file, key: "t", modifiers: cs,
                    action: #selector((any AxActions).reopenClosedSession(_:))),
            Command(id: "connect-host", title: "Connect to Host…", menu: .file, key: "k", modifiers: cs,
                    action: #selector((any AxActions).showConnectToHost(_:)), separatorBefore: true),
            Command(id: "close-pane", title: "Close Pane", menu: .file, key: "w", modifiers: cmd,
                    action: #selector((any AxActions).closePane(_:)), separatorBefore: true),
            Command(id: "close-session", title: "Close Session", menu: .file, key: "w", modifiers: [.command, .option],
                    action: #selector((any AxActions).closeSession(_:))),
            Command(id: "close-window", title: "Close Window", menu: .file, key: "w", modifiers: cs,
                    action: #selector(NSWindow.performClose(_:)), inPalette: false),

            Command(id: "clear", title: "Clear Buffer", menu: .edit, key: "k", modifiers: cmd,
                    action: #selector((any AxActions).clearBuffer(_:)), separatorBefore: true),
            Command(id: "find", title: "Find…", menu: .edit, key: "f", modifiers: cmd,
                    action: #selector((any AxActions).showFind(_:)), separatorBefore: true),
            Command(id: "find-next", title: "Find Next", menu: .edit, key: "g", modifiers: cmd,
                    action: #selector((any AxActions).findNext(_:))),
            Command(id: "find-previous", title: "Find Previous", menu: .edit, key: "g", modifiers: cs,
                    action: #selector((any AxActions).findPrevious(_:))),

            Command(id: "toggle-sidebar", title: "Toggle Sidebar", menu: .view, key: "s", modifiers: cc,
                    action: #selector((any AxActions).toggleSessionSidebar(_:)), separatorBefore: true),
            Command(id: "font-bigger", title: "Bigger", menu: .view, key: "+", modifiers: cmd,
                    action: #selector((any AxActions).increaseFontSize(_:)), separatorBefore: true),
            Command(id: "font-smaller", title: "Smaller", menu: .view, key: "-", modifiers: cmd,
                    action: #selector((any AxActions).decreaseFontSize(_:))),
            Command(id: "font-reset", title: "Actual Size", menu: .view, key: "0", modifiers: cmd,
                    action: #selector((any AxActions).resetFontSize(_:))),
            Command(id: "top", title: "Scroll to Top", menu: .view, key: fn(NSHomeFunctionKey), modifiers: cmd,
                    action: #selector((any AxActions).scrollToTopOfBuffer(_:)), separatorBefore: true),
            Command(id: "bottom", title: "Scroll to Bottom", menu: .view, key: fn(NSEndFunctionKey), modifiers: cmd,
                    action: #selector((any AxActions).scrollToBottomOfBuffer(_:))),
            Command(id: "prev-prompt", title: "Previous Prompt", menu: .view, key: up, modifiers: cmd,
                    action: #selector((any AxActions).previousPrompt(_:))),
            Command(id: "next-prompt", title: "Next Prompt", menu: .view, key: down, modifiers: cmd,
                    action: #selector((any AxActions).nextPrompt(_:))),
            Command(id: "fullscreen", title: "Enter Full Screen", menu: .view, key: "f", modifiers: cc,
                    action: #selector(NSWindow.toggleFullScreen(_:)), separatorBefore: true),

            Command(id: "prev-session", title: "Previous Session", menu: .session, key: "[", modifiers: cs,
                    action: #selector((any AxActions).selectPreviousSession(_:))),
            Command(id: "next-session", title: "Next Session", menu: .session, key: "]", modifiers: cs,
                    action: #selector((any AxActions).selectNextSession(_:))),
            Command(id: "jump-agent", title: "Go to Session…", menu: .session, key: "j", modifiers: cmd,
                    action: #selector((any AxActions).showJumpToAgent(_:)), inPalette: false, separatorBefore: true),
            Command(id: "next-attention", title: "Next Waiting Agent", menu: .session, key: "u", modifiers: cs,
                    action: #selector((any AxActions).selectNextAttention(_:))),
            Command(id: "open-editor", title: "Open in Editor", menu: .session, key: "o", modifiers: co,
                    action: #selector((any AxActions).openInEditor(_:)), separatorBefore: true),
            Command(id: "remove-worktree", title: "Remove Worktree…", menu: .session, key: "", modifiers: [],
                    action: #selector((any AxActions).removeWorktreeSession(_:))),
            Command(id: "rename-session", title: "Rename Session…", menu: .session, key: "", modifiers: [],
                    action: #selector((any AxActions).renameSession(_:)), separatorBefore: true),

            Command(id: "split-right", title: "Split Right", menu: .pane, key: "d", modifiers: cmd,
                    action: #selector((any AxActions).splitRight(_:))),
            Command(id: "split-down", title: "Split Down", menu: .pane, key: "d", modifiers: cs,
                    action: #selector((any AxActions).splitDown(_:))),
            Command(id: "prev-pane", title: "Focus Previous Pane", menu: .pane, key: "[", modifiers: cmd,
                    action: #selector((any AxActions).focusPreviousPane(_:)), separatorBefore: true),
            Command(id: "next-pane", title: "Focus Next Pane", menu: .pane, key: "]", modifiers: cmd,
                    action: #selector((any AxActions).focusNextPane(_:))),
            Command(id: "focus-left", title: "Focus Pane Left", menu: .pane, key: left, modifiers: co,
                    action: #selector((any AxActions).focusPaneLeft(_:))),
            Command(id: "focus-right", title: "Focus Pane Right", menu: .pane, key: right, modifiers: co,
                    action: #selector((any AxActions).focusPaneRight(_:))),
            Command(id: "focus-up", title: "Focus Pane Above", menu: .pane, key: up, modifiers: co,
                    action: #selector((any AxActions).focusPaneUp(_:))),
            Command(id: "focus-down", title: "Focus Pane Below", menu: .pane, key: down, modifiers: co,
                    action: #selector((any AxActions).focusPaneDown(_:))),
            Command(id: "resize-left", title: "Move Divider Left", menu: .pane, key: left, modifiers: cc,
                    action: #selector((any AxActions).resizePaneLeft(_:)), separatorBefore: true),
            Command(id: "resize-right", title: "Move Divider Right", menu: .pane, key: right, modifiers: cc,
                    action: #selector((any AxActions).resizePaneRight(_:))),
            Command(id: "resize-up", title: "Move Divider Up", menu: .pane, key: up, modifiers: cc,
                    action: #selector((any AxActions).resizePaneUp(_:))),
            Command(id: "resize-down", title: "Move Divider Down", menu: .pane, key: down, modifiers: cc,
                    action: #selector((any AxActions).resizePaneDown(_:))),
            Command(id: "zoom", title: "Zoom Pane", menu: .pane, key: "\r", modifiers: cs,
                    action: #selector((any AxActions).toggleZoom(_:)), separatorBefore: true),
            Command(id: "equalize", title: "Equalize Panes", menu: .pane, key: "=", modifiers: cc,
                    action: #selector((any AxActions).equalizePanes(_:))),
        ]
        for i in 1 ... 9 {
            list.append(Command(id: "session-\(i)", title: i == 9 ? "Select Last Session" : "Select Session \(i)",
                                menu: .session, key: "\(i)", modifiers: cmd,
                                action: #selector((any AxActions).selectSessionByNumber(_:)), inPalette: false, tag: i,
                                separatorBefore: i == 1))
        }
        return list
    }()
}
