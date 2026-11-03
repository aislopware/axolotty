import AppKit
import QuartzCore

/// A list that runs on under a bar fades out over 20 pt instead of being cut
/// at the bar's edge: the sidebar under its footer, and under the title bar's
/// band once it is scrolled. Only an edge with content past it fades, so a
/// list that fits looks exactly as drawn. (AppKit's own scroll edge effect
/// serves titlebar and split-item accessories; the footer is neither.)
@MainActor
final class ScrollFade {
    static let depth: CGFloat = 20

    private let mask = CAGradientLayer()
    private weak var scroll: NSScrollView?
    private var observers: [any NSObjectProtocol] = []

    init(_ scroll: NSScrollView) {
        self.scroll = scroll
        scroll.wantsLayer = true
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.postsFrameChangedNotifications = true
        scroll.documentView?.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        var watched: [(Notification.Name, NSView)] = [(NSView.boundsDidChangeNotification, scroll.contentView),
                                                      (NSView.frameDidChangeNotification, scroll)]
        // Rows added, removed or folded change the document's height.
        if let doc = scroll.documentView { watched.append((NSView.frameDidChangeNotification, doc)) }
        for (name, object) in watched {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        update()
    }

    func update() {
        guard let s = scroll, let layer = s.layer else { return }
        let h = s.bounds.height
        guard h > Self.depth * 2 else { return }
        let clip = s.contentView.bounds
        let insetTop = s.contentView.contentInsets.top
        let docHeight = s.documentView?.frame.height ?? 0
        let above = clip.minY > -insetTop + 0.5
        let below = docHeight - clip.maxY > 0.5
        let t = insetTop / h, d = Self.depth / h
        let clear = CGColor(gray: 0, alpha: 0), solid = CGColor(gray: 0, alpha: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = layer.bounds
        // From the top edge down, in whichever way up the backing layer is.
        let flipped = layer.contentsAreFlipped()
        mask.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
        mask.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
        mask.colors = [above ? clear : solid, above ? clear : solid, solid, solid, below ? clear : solid]
        mask.locations = [0, t, min(1, t + d), max(0, 1 - d), 1].map { NSNumber(value: Double($0)) }
        if layer.mask !== mask { layer.mask = mask }
        CATransaction.commit()
    }
}
