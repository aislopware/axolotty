internal import AxFrame
internal import GhosttyVT
public import AxVT
import CoreGraphics
import Foundation
public import Metal
public import QuartzCore

/// How the cursor should look this frame (the UI animates glide, blink and focus).
public struct CursorStyle: Sendable, Equatable {
    public enum Shape: Sendable { case block, bar, underline, hollow }
    public var shape: Shape?
    /// Cell position, fractional while gliding. nil: wherever the terminal says.
    public var position: (x: Double, y: Double)?
    /// 0…1 (blink dims rather than hides).
    public var opacity: Double = 1
    /// Entrance pop scale.
    public var scale: Double = 1
    public var color: UInt32?

    public init() {}

    public static func == (a: CursorStyle, b: CursorStyle) -> Bool {
        a.shape == b.shape && a.opacity == b.opacity && a.scale == b.scale && a.color == b.color
            && a.position?.x == b.position?.x && a.position?.y == b.position?.y
    }
}

/// What the terminal reported about its cursor in the last build.
public struct CursorInfo: Sendable, Equatable {
    public var visible: Bool
    public var x: Int
    public var y: Int
    public var wide: Bool
    public var blinking: Bool
    /// What the program asked for (DECSCUSR); nil when it is the terminal's
    /// initial steady block, i.e. the program expressed no preference.
    public var requested: CursorStyle.Shape?
}

/// Per-pane GPU state: a render state copy, the frame builder, and triple-buffered uploads.
public final class TerminalFrame {
    let state: VTRenderState
    let frame: OpaquePointer
    private(set) var info = ax_frame_info()
    private var builtEpoch = -1
    fileprivate var buffers: [Buffers] = []
    fileprivate var slot = 0
    fileprivate let inFlight = DispatchSemaphore(value: 3)

    fileprivate struct Buffers {
        var bg: (any MTLBuffer)?
        var glyphs: (any MTLBuffer)?
        var rects: (any MTLBuffer)?
        var overlay: (any MTLBuffer)?
    }

    public init() throws {
        state = try VTRenderState()
        guard let f = ax_frame_new() else { throw RenderError.noTexture }
        frame = f
        buffers = Array(repeating: Buffers(), count: 3)
    }

    deinit {
        // Wait for in-flight GPU work that may still read our buffers.
        for _ in 0 ..< 3 { inFlight.wait() }
        for _ in 0 ..< 3 { inFlight.signal() }
        ax_frame_free(frame)
    }

    public var cols: Int { Int(info.cols) }
    public var rows: Int { Int(info.rows) }
    public var background: UInt32 { info.background }
    public var foreground: UInt32 { info.foreground }
    public var cursor: CursorInfo {
        let shape: CursorStyle.Shape? = switch info.cursor_style {
        case 0: .bar
        case 1: info.cursor_blinking ? .block : nil
        case 2: .underline
        case 3: .hollow
        default: nil
        }
        return CursorInfo(visible: info.cursor_visible, x: Int(info.cursor_x), y: Int(info.cursor_y),
                          wide: info.cursor_wide, blinking: info.cursor_blinking, requested: shape)
    }

    /// Copies the terminal's state. Call while holding the terminal (e.g. inside `MirrorTerminal.withTerminal`).
    public func update(from terminal: VTTerminal) {
        state.update(from: terminal)
    }

    /// Forces the next build to rebuild every row.
    public func invalidate() { ax_frame_invalidate(frame) }

    /// A run of cells on one viewport row painted with `color` (RGBA8, R lowest), under the text.
    public struct Highlight: Equatable, Sendable {
        public var row: Int, from: Int, to: Int  // `to` inclusive
        public var color: UInt32
        public init(row: Int, from: Int, to: Int, color: UInt32) {
            self.row = row
            self.from = from
            self.to = to
            self.color = color
        }
    }

    /// Replaces the highlighted runs (find matches); rows rebuild only when they change.
    public func setHighlights(_ spans: [Highlight]) {
        let c = spans.prefix(1024).map {
            ax_highlight(row: UInt16(clamping: $0.row), x0: UInt16(clamping: $0.from), x1: UInt16(clamping: $0.to), bg: $0.color)
        }
        _ = c.withUnsafeBufferPointer { ax_frame_set_highlights(frame, $0.baseAddress, $0.count) }
    }

    fileprivate func build(_ store: GlyphStore, style: inout ax_frame_style) -> Bool {
        if builtEpoch != store.epoch {
            ax_frame_invalidate(frame)
            builtEpoch = store.epoch
        }
        var i = ax_frame_info()
        _ = ax_frame_build(frame, state.handle, store.cache, &style, &i)
        if store.needsReset {
            // An atlas filled up mid-build: start a fresh atlas and rebuild everything once.
            store.needsReset = false
            store.reset()
            builtEpoch = store.epoch
            ax_frame_invalidate(frame)
            _ = ax_frame_build(frame, state.handle, store.cache, &style, &i)
        }
        info = i
        return i.any_dirty
    }
}

/// Parameters for drawing one pane.
public struct DrawParams: Sendable {
    /// Grid origin inside the drawable, in pixels (padding).
    public var origin: (x: Float, y: Float) = (0, 0)
    public var cursor = CursorStyle()
    public var cursorTextColor: UInt32 = 0xFF00_0000
    public var accent: UInt32 = 0xFFCF_7BDE
    public var selectionBackground: UInt32 = 0
    public var blinkVisible = true
    public var clearColor: UInt32?

    public init() {}
}

/// The Metal renderer shared by every pane (one device, queue and pipeline set).
public final class TerminalRenderer {
    public let device: any MTLDevice
    public let store: GlyphStore
    private let queue: any MTLCommandQueue
    private let bgPipeline: any MTLRenderPipelineState
    private let rectPipeline: any MTLRenderPipelineState
    private let glyphPipeline: any MTLRenderPipelineState
    public static let pixelFormat = MTLPixelFormat.bgra8Unorm

    public init(font: TerminalFont, device: (any MTLDevice)? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.noDevice
        }
        self.device = device
        self.queue = queue
        store = try GlyphStore(device: device, font: font)
        let library: any MTLLibrary
        do { library = try device.makeLibrary(source: Shaders.source, options: nil) } catch {
            throw RenderError.shader("\(error)")
        }
        func pipeline(_ v: String, _ f: String) throws -> any MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            let a = d.colorAttachments[0]!
            a.pixelFormat = Self.pixelFormat
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do { return try device.makeRenderPipelineState(descriptor: d) } catch {
                throw RenderError.pipeline("\(v): \(error)")
            }
        }
        bgPipeline = try pipeline("bg_vertex", "bg_fragment")
        rectPipeline = try pipeline("rect_vertex", "rect_fragment")
        glyphPipeline = try pipeline("glyph_vertex", "glyph_fragment")
    }

    public var font: TerminalFont { store.font }

    public func setFont(_ f: TerminalFont) { store.setFont(f) }

    /// Configures a layer for this renderer.
    public func configure(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = Self.pixelFormat
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = false
    }

    /// Text keeps at least this WCAG ratio over its own ground (programs paint
    /// truecolor the theme cannot remap: a pale cyan prompt on a light ground).
    /// 3:1 is the large-text floor: it rescues unreadable pairs and leaves a
    /// theme's deliberate mid-tones alone. 1 turns it off.
    public var minimumContrast: Float = 3

    /// Rebuilds dirty rows. Returns true when anything changed since the last build.
    @discardableResult
    public func prepare(_ frame: TerminalFrame, selectionBackground: UInt32 = 0) -> Bool {
        var style = self.style(selectionBackground: selectionBackground)
        return frame.build(store, style: &style)
    }

    private func style(selectionBackground: UInt32) -> ax_frame_style {
        let f = store.font
        return ax_frame_style(
            cell_width: Float(f.cellWidth), cell_height: Float(f.cellHeight),
            underline_y: f.underlineY, underline_thickness: f.underlineThickness,
            strike_y: f.strikeY, strike_thickness: f.strikeThickness,
            selection_bg: selectionBackground, selection_fg: 0, bold_is_bright: false, faint_alpha: 0.55,
            min_contrast: minimumContrast)
    }

    /// Encodes one pane into `target` (a drawable's texture or an offscreen texture).
    public func draw(_ frame: TerminalFrame, to target: any MTLTexture, params: DrawParams,
                     present drawable: (any CAMetalDrawable)? = nil, completion: (@Sendable () -> Void)? = nil)
    {
        frame.inFlight.wait()
        frame.slot = (frame.slot + 1) % 3
        let slot = frame.slot
        let f = store.font

        // Uploads.
        var bgCount = 0, glyphCount = 0, rectCount = 0
        let bgPtr = ax_frame_bg(frame.frame, &bgCount)
        let glyphPtr = ax_frame_glyphs(frame.frame, &glyphCount)
        let rectPtr = ax_frame_rects(frame.frame, &rectCount)
        upload(&frame.buffers[slot].bg, bgPtr, bgCount * 4)
        upload(&frame.buffers[slot].glyphs, glyphPtr, glyphCount * MemoryLayout<ax_glyph_instance>.stride)
        upload(&frame.buffers[slot].rects, rectPtr, rectCount * MemoryLayout<ax_rect_instance>.stride)

        // Cursor geometry.
        let info = frame.info
        var under: [ax_rect_instance] = []
        var over: [ax_rect_instance] = []
        var blockCol: Int32 = -1, blockRow: Int32 = -1
        if let shape = params.cursor.shape, info.cursor_visible || params.cursor.position != nil,
           params.cursor.opacity > 0
        {
            let cx = params.cursor.position?.x ?? Double(info.cursor_x)
            let cy = params.cursor.position?.y ?? Double(info.cursor_y)
            let cw = Float(f.cellWidth) * (info.cursor_wide ? 2 : 1)
            let ch = Float(f.cellHeight)
            let x = Float(cx) * Float(f.cellWidth), y = Float(cy) * Float(f.cellHeight)
            let alpha = UInt32(max(0, min(1, params.cursor.opacity)) * 255)
            let color = (params.cursor.color ?? info.cursor_color.nonZero ?? params.accent) & 0x00FF_FFFF | alpha << 24
            let s = Float(params.cursor.scale)
            let thin = max(1, Float(f.scale).rounded())
            switch shape {
            case .block:
                let w = cw * s, h = ch * s
                under.append(rect(x - (w - cw) / 2, y - (h - ch) / 2, w, h, color))
                if params.cursor.opacity > 0.5, cx == cx.rounded(), cy == cy.rounded() {
                    blockCol = Int32(cx)
                    blockRow = Int32(cy)
                }
            case .bar:
                let w = 2 * thin, h = ch * (1 + (s - 1) * 0.4)
                over.append(rect(x, y - (h - ch) / 2, w, h, color))
            case .underline:
                let w = cw * (1 + (s - 1) * 0.4), h = 2 * thin
                over.append(rect(x - (w - cw) / 2, y + ch - h, w, h, color))
            case .hollow:
                over += [rect(x, y, cw, thin, color), rect(x, y + ch - thin, cw, thin, color),
                         rect(x, y, thin, ch, color), rect(x + cw - thin, y, thin, ch, color)]
            }
        }
        let overlay = under + over
        overlay.withUnsafeBytes { upload(&frame.buffers[slot].overlay, $0.baseAddress, $0.count) }

        var u = Uniforms(
            viewport: (Float(target.width), Float(target.height)),
            origin: (params.origin.x, params.origin.y),
            cell: (Float(f.cellWidth), Float(f.cellHeight)),
            cols: UInt32(info.cols), rows: UInt32(info.rows),
            cursorCol: blockCol, cursorRow: blockRow, cursorText: params.cursorTextColor,
            blinkVisible: params.blinkVisible ? 1 : 0, faintAlpha: 0.55, pad0: 0)

        guard let cmd = queue.makeCommandBuffer() else {
            frame.inFlight.signal()
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let clear = params.clearColor ?? info.background
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(clear & 0xFF) / 255, green: Double(clear >> 8 & 0xFF) / 255,
            blue: Double(clear >> 16 & 0xFF) / 255, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            frame.inFlight.signal()
            return
        }
        let b = frame.buffers[slot]
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        if info.cols > 0, info.rows > 0, bgCount > 0, let bg = b.bg {
            enc.setRenderPipelineState(bgPipeline)
            enc.setFragmentBuffer(bg, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if !under.isEmpty, let o = b.overlay {
            enc.setRenderPipelineState(rectPipeline)
            enc.setVertexBuffer(o, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: under.count)
        }
        if glyphCount > 0, let g = b.glyphs {
            enc.setRenderPipelineState(glyphPipeline)
            enc.setVertexBuffer(g, offset: 0, index: 1)
            enc.setFragmentTexture(store.gray, index: 0)
            enc.setFragmentTexture(store.color, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: glyphCount)
        }
        if rectCount > 0, let r = b.rects {
            enc.setRenderPipelineState(rectPipeline)
            enc.setVertexBuffer(r, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: rectCount)
        }
        if !over.isEmpty, let o = b.overlay {
            enc.setRenderPipelineState(rectPipeline)
            enc.setVertexBuffer(o, offset: under.count * MemoryLayout<ax_rect_instance>.stride, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: over.count)
        }
        enc.endEncoding()
        let sem = frame.inFlight
        cmd.addCompletedHandler { _ in
            sem.signal()
            completion?()
        }
        if let drawable {
            // Live resize: present inside the window's transaction so content and frame move together.
            if drawable.layer.presentsWithTransaction {
                cmd.commit()
                cmd.waitUntilScheduled()
                drawable.present()
                return
            }
            cmd.present(drawable)
        }
        cmd.commit()
    }

    /// Renders offscreen and returns BGRA pixels (tests, thumbnails, tab peek).
    public func snapshot(_ frame: TerminalFrame, width: Int, height: Int, params: DrawParams) -> [UInt8]? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height,
                                                         mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        let done = DispatchSemaphore(value: 0)
        draw(frame, to: tex, params: params) { done.signal() }
        done.wait()
        var out = [UInt8](repeating: 0, count: width * height * 4)
        tex.getBytes(&out, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return out
    }

    private func upload(_ buffer: inout (any MTLBuffer)?, _ ptr: UnsafeRawPointer?, _ length: Int) {
        guard let ptr, length > 0 else { return }
        if buffer == nil || buffer!.length < length {
            buffer = device.makeBuffer(length: max(length * 3 / 2, 4096), options: .storageModeShared)
        }
        buffer?.contents().copyMemory(from: ptr, byteCount: length)
    }

    private func rect(_ x: Float, _ y: Float, _ w: Float, _ h: Float, _ color: UInt32) -> ax_rect_instance {
        ax_rect_instance(x: x, y: y, w: w, h: h, color: color, kind: UInt8(AX_RECT_SOLID), reserved: (0, 0, 0))
    }
}

/// Mirrors the MSL `Uniforms` struct.
struct Uniforms {
    var viewport: (Float, Float)
    var origin: (Float, Float)
    var cell: (Float, Float)
    var cols: UInt32
    var rows: UInt32
    var cursorCol: Int32
    var cursorRow: Int32
    var cursorText: UInt32
    var blinkVisible: Float
    var faintAlpha: Float
    var pad0: Float
}

extension UInt32 {
    fileprivate var nonZero: UInt32? { self == 0 ? nil : self }
}

/// Sizes the shader relies on (checked by tests).
enum RenderLayout {
    static let glyphInstanceSize = MemoryLayout<ax_glyph_instance>.size
    static let rectInstanceSize = MemoryLayout<ax_rect_instance>.size
}
