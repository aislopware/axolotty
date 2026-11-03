import AppKit
import AxModel

/// App lifecycle: menus, the local server, windows, appearance and attention.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let model = AppModel.shared
    private var windows: [MainWindowController] = []
    private var settings: SettingsWindowController?
    private var attention: AttentionCenter?
    private var appearanceObservation: NSKeyValueObservation?
    private var lastKey: MainWindowController?
    private var accessibilityObserver: (any NSObjectProtocol)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Layers made before a window exists render for the sharpest screen.
        LayerScale.current = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        Axo.Font.registerBundled()
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.build()
        UserDefaults.standard.register(defaults: ["NSWindowRestoresWorkspaceAtLaunch": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] app, _ in
            MainActor.assumeIsolated {
                self?.model.updateSystemAppearance(dark: app.effectiveAppearance.isDark)
            }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.fontChanged.emit() }
        }
        attention = AttentionCenter(model: model) { [weak self] in self?.keyMainWindow }
        model.startLocal()
        model.startRemotes()
        newWindow(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Sessions keep running in the server; only this client leaves.
        for h in model.hosts { h.stop() }
    }

    var keyMainWindow: MainWindowController? {
        (NSApp.keyWindow?.windowController as? MainWindowController) ?? lastKey ?? windows.last
    }

    func windowBecameKey(_ w: MainWindowController) { lastKey = w }

    func windowClosed(_ w: MainWindowController) {
        windows.removeAll { $0 === w }
        if lastKey === w { lastKey = nil }
    }

    @objc func newWindow(_ sender: Any?) {
        let w = MainWindowController(model: model, autosave: windows.isEmpty)
        windows.append(w)
        if let other = keyMainWindow?.window, other !== w.window {
            w.window?.setFrameTopLeftPoint(NSPoint(x: other.frame.minX + 24, y: other.frame.maxY - 24))
        }
        w.showWindow(nil)
        // A new window starts on the same host's current session, or the first one.
        for h in model.hosts where h.phase == .connected {
            if let s = keyMainWindow?.selection, s.host === h {
                w.show(h, s.session)
            } else if let first = h.state?.orderedSessions.first {
                w.show(h, first)
            }
            break
        }
    }

    @objc func showSettings(_ sender: Any?) {
        let s = settings ?? SettingsWindowController(model: model)
        settings = s
        s.showWindow(nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { true }
}
