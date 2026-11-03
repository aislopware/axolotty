import AppKit
@testable import AxMacUI
import Foundation
import Testing

/// A view drawn offscreen, the way the screen would show it: its layer tree rendered into a
/// bitmap on the Axolotty backdrop, at a scale of 1 or 2, in the dark appearance.
///
/// `render(in:)` is not the compositor: it rounds every corner of a layer that masks some
/// (`maskedCorners`) and skips masks and filters, so a picture of such a view is checked for
/// its copy, colour and layout, not its outline.
enum Snapshot {
    /// `view` at `size`, inside `margin` of backdrop so its shadow and ring show.
    static func render(_ view: NSView, size: NSSize, scale: CGFloat = 1, margin: CGFloat = 16,
                       on backdrop: NSColor = Axo.Color.ground) -> CGImage {
        var image: CGImage?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            image = draw(view, size: size, scale: scale, margin: margin, backdrop: backdrop)
        }
        return image!
    }

    private static func draw(_ view: NSView, size: NSSize, scale: CGFloat, margin: CGFloat, backdrop: NSColor) -> CGImage {
        let canvas = NSSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        Axo.Font.registerBundled()
        // A window that is never ordered in: AppKit builds the layer tree only for a view in
        // a window, and this one is never shown and never takes focus.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvas), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSView(frame: NSRect(origin: .zero, size: canvas))
        host.wantsLayer = true
        host.layer?.backgroundColor = backdrop.cgColor
        window.contentView = host
        view.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        host.addSubview(view)
        setScale(host.layer!, scale)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        let w = Int(canvas.width * scale), h = Int(canvas.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        host.layer!.render(in: ctx)
        window.contentView = nil
        return ctx.makeImage()!
    }

    private static func setScale(_ l: CALayer, _ s: CGFloat) {
        l.contentsScale = s
        l.setNeedsDisplay()
        for c in l.sublayers ?? [] { setScale(c, s) }
    }

    static func png(_ image: CGImage) -> Data {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    }

    /// RGBA bytes in one fixed layout, whatever the image's own.
    static func pixels(_ image: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        out.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return out
    }

    /// How two images differ: pixels with any channel off by more than `tolerance`, and a
    /// picture of them (red on a dimmed copy of `b`). Different sizes differ everywhere.
    static func difference(_ a: CGImage, _ b: CGImage, tolerance: Int = 2) -> (pixels: Int, diff: CGImage?) {
        guard a.width == b.width, a.height == b.height else { return (max(a.width * a.height, b.width * b.height), nil) }
        let pa = pixels(a), pb = pixels(b)
        // The usual answer, "the same", in one memcmp: the loop below is slow unoptimised.
        let same = pa.withUnsafeBytes { x in pb.withUnsafeBytes { y in memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0 } }
        if same { return (0, nil) }
        var marked = pb, n = 0
        for i in stride(from: 0, to: pa.count, by: 4) {
            var off = false
            for c in 0 ..< 4 where abs(Int(pa[i + c]) - Int(pb[i + c])) > tolerance { off = true }
            if off {
                n += 1
                marked[i] = 255; marked[i + 1] = 0; marked[i + 2] = 0; marked[i + 3] = 255
            } else {
                for c in 0 ..< 3 { marked[i + c] /= 3 }
            }
        }
        let diff = marked.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: b.width, height: b.height, bitsPerComponent: 8, bytesPerRow: b.width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        return (n, diff)
    }

    /// Where references live: `Snapshots/<name>.png` beside the tests.
    static func reference(_ name: String, file: String = #filePath) -> URL {
        URL(filePath: file).deletingLastPathComponent().appending(path: "Snapshots/\(name).png")
    }

    /// Whether to write references instead of checking them (`AXSNAPSHOT_RECORD=1`).
    nonisolated static let recording = ProcessInfo.processInfo.environment["AXSNAPSHOT_RECORD"] == "1"

    /// Checks `image` against its reference. A missing reference, or a recording run, writes
    /// it and fails, so a new picture is always looked at before it is trusted. A mismatch
    /// leaves the picture, the reference and their difference in `$TMPDIR/axolotty-snapshots`.
    static func expect(_ image: CGImage, named name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let ref = reference(name)
        guard !recording, let data = try? Data(contentsOf: ref),
              let old = NSBitmapImageRep(data: data)?.cgImage
        else {
            try FileManager.default.createDirectory(at: ref.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png(image).write(to: ref)
            Issue.record("recorded \(ref.path): look at it, then run again", sourceLocation: sourceLocation)
            return
        }
        let (n, diff) = difference(image, old)
        guard n > 0 else { return }
        let dir = FileManager.default.temporaryDirectory.appending(path: "axolotty-snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png(image).write(to: dir.appending(path: "\(name).png"))
        try data.write(to: dir.appending(path: "\(name).reference.png"))
        if let diff { try png(diff).write(to: dir.appending(path: "\(name).diff.png")) }
        Issue.record("\(name): \(n) pixels differ from the reference; see \(dir.path)", sourceLocation: sourceLocation)
    }
}

/// Views stacked top to bottom, each at its own fitting size, for one picture of a set.
final class Sheet: NSView {
    private let gap: CGFloat
    private let items: [(view: NSView, size: NSSize)]

    init(gap: CGFloat = 12, _ views: [(NSView, NSSize?)]) {
        self.gap = gap
        items = views.map { v, s in (v, s ?? v.fittingSize) }
        super.init(frame: .zero)
        for i in items { addSubview(i.view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var size: NSSize {
        NSSize(width: ceil(items.map(\.size.width).max() ?? 0),
               height: ceil(items.map(\.size.height).reduce(0, +) + gap * CGFloat(max(0, items.count - 1))))
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        for i in items {
            i.view.frame = NSRect(x: 0, y: y, width: i.size.width, height: i.size.height)
            y += i.size.height + gap
        }
    }
}
