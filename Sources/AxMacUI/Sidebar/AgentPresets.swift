import AppKit
import AxModel
import AxRender

/// What the project's "+" offers: a shell, then each agent this host can run.
///
/// On the local host an agent is offered only when its executable is on the
/// person's PATH (the app's own PATH is launchd's, so the usual install
/// directories are searched too). A remote host cannot be probed from here,
/// so it offers the three agents with first-class marks.
enum AgentPresets {
    static let order: [AgentKind] = [.claude, .codex, .gemini, .opencode, .amp, .cursor, .copilot, .aider, .goose, .qwen,
                                     .crush, .droid, .kimi, .kiro, .auggie, .pi]

    static func available(local: Bool) -> [AgentKind] {
        guard local else { return [.claude, .codex, .gemini] }
        let found = installed
        return order.filter { found.contains($0) }
    }

    /// Probed once per launch: a menu must open instantly.
    private static let installed: Set<AgentKind> = {
        let home = NSHomeDirectory()
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin",
                 "\(home)/.cargo/bin", "\(home)/go/bin", "\(home)/.volta/bin"]
        let fm = FileManager.default
        return Set(order.filter { a in dirs.contains { fm.isExecutableFile(atPath: "\($0)/\(a.executable)") } })
    }()

    /// The line typed into a new session's shell to start `agent`, with
    /// `args` (already quoted). A local Claude Code gets Axolotty's MCP tools
    /// (the file is Axolotty's own; the agent's config is never written).
    static func launchLine(_ agent: AgentKind, args: String = "", local: Bool) -> String {
        var line = agent.executable
        if agent == .claude {
            if local { line += " --mcp-config \"$AXOLOTTY_MCP\"" }
        }
        if !args.isEmpty { line += " " + args }
        return line
    }

    /// The "+" menu as Axolotty's own opaque menu (`PopMenu`): Shell, a
    /// rule, then each agent. Keys match the empty state's tiles: 1 is Shell,
    /// 2–9 the agents in order. `pick(nil)` is a plain shell.
    static func items(local: Bool, pick: @escaping (AgentKind?) -> Void) -> [PopMenu.Item?] {
        var out: [PopMenu.Item?] = [PopMenu.Item(title: "Shell", image: ProgramIdentity.shell.image(), key: "1") { pick(nil) }]
        let agents = available(local: local)
        if !agents.isEmpty { out.append(nil) }
        for (i, a) in agents.enumerated() {
            let id = ProgramIdentity.of(a)
            out.append(PopMenu.Item(title: a.displayName, image: id.image(), key: i < 8 ? "\(i + 2)" : nil) { pick(a) })
        }
        return out
    }
}

extension ProgramIdentity {
    /// The icon as an image (16 pt for menus, 24 for launch tiles): the
    /// vendor's own mark at side − 2, or the SF Symbol as a template (so the
    /// host view tints it).
    func image(side: CGFloat = 16) -> NSImage? {
        guard let mark, let path = mark.path else {
            // Drawn into a fixed square: symbols differ in width (terminal is
            // 19 wide, curlybraces 16), and a menu lines its titles up after
            // its images; a template so the menu inks it, highlight included.
            // 12 pt in a 16 slot; the same optical ratio at any side.
            let cfg = NSImage.SymbolConfiguration(pointSize: (side * 0.75).rounded(), weight: .medium)
            guard let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            else { return nil }
            let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
                let s = sym.size
                let f = min(1, r.width / max(s.width, s.height))
                let w = s.width * f, h = s.height * f
                sym.draw(in: NSRect(x: (r.width - w) / 2, y: (r.height - h) / 2, width: w, height: h))
                return true
            }
            img.isTemplate = true
            return img
        }
        let inner = side - 2
        let img = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: 1, y: 1)
            ctx.scaleBy(x: inner / 24, y: inner / 24)
            let rule: CGPathFillRule = mark.evenOdd ? .evenOdd : .winding
            for fill in mark.fills {
                ctx.saveGState()
                ctx.addPath(path)
                switch fill {
                case let .solid(c):
                    ctx.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a))
                    ctx.fillPath(using: rule)
                case let .linear(from, to, stops):
                    ctx.clip(using: rule)
                    let colors = stops.map { CGColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: $0.a) } as CFArray
                    if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                          locations: stops.map(\.offset)) {
                        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                    }
                }
                ctx.restoreGState()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
