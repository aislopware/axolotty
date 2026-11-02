import AppKit
import AxRender
import CoreText

/// One renderer (device, pipelines, glyph atlases) per backing scale and font
/// size, shared by every pane on displays of that scale.
final class RenderPool {
    static let shared = RenderPool()

    private struct Key: Hashable {
        var scale: CGFloat
        var size: CGFloat
        var family: String
    }

    private var renderers: [Key: TerminalRenderer] = [:]
    private(set) var failure: String?

    func renderer(scale: CGFloat, size: CGFloat, family: String = "") -> TerminalRenderer? {
        let key = Key(scale: scale, size: size, family: family)
        if let r = renderers[key] { return r }
        let regular = Axo.Font.terminal(size: size, family: family) as CTFont
        let bold = Axo.Font.terminalBold(size: size, family: family) as CTFont
        do {
            let r = try TerminalRenderer(font: TerminalFont(regular: regular, bold: bold, scale: scale),
                                         device: renderers.values.first?.device)
            // Atlases are large; keep only the sizes in use.
            renderers = renderers.filter { $0.key.size == size && $0.key.family == family }
            renderers[key] = r
            return r
        } catch {
            failure = "\(error)"
            return nil
        }
    }
}
