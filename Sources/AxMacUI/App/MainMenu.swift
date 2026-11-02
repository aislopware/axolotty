import AppKit

/// The menu bar, built from `Command.all` so menus, palette and shortcuts never drift.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        func top(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            main.addItem(item)
            return menu
        }
        func add(_ menu: NSMenu, _ c: Command) {
            if c.separatorBefore, !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: c.title, action: c.action, keyEquivalent: c.key)
            item.keyEquivalentModifierMask = c.modifiers
            item.tag = c.tag
            menu.addItem(item)
            if c.id == "font-bigger" {
                // ⌘= as well as ⌘+ (the unshifted key on most layouts).
                let alt = NSMenuItem(title: c.title, action: c.action, keyEquivalent: "=")
                alt.keyEquivalentModifierMask = .command
                alt.isHidden = true
                alt.allowsKeyEquivalentWhenHidden = true
                menu.addItem(alt)
            }
        }
        func commands(_ m: Command.Menu, into menu: NSMenu) {
            for c in Command.all where c.menu == m { add(menu, c) }
        }

        let app = top("Axolotty")
        app.addItem(withTitle: "About Axolotty", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector((any AxActions).showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Axolotty", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                                 keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Axolotty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        commands(.file, into: top("File"))

        let edit = top("Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        commands(.edit, into: edit)

        commands(.view, into: top("View"))
        commands(.session, into: top("Session"))
        commands(.pane, into: top("Pane"))

        let window = top("Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        let help = top("Help")
        NSApp.helpMenu = help
        return main
    }
}
