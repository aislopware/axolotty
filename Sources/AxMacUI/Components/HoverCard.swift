import AppKit
import AxModel
import AxProtocol

/// A row's hover card: a title, then one fact per line, each led by a mark.
///
///     Fix the login bug
///     ●  Working · 4m
///     ⌘  Needs approval: run cargo test
///     ▢  ~/code/app
///     ⑂  main  ↑2 ↓1   +120 −34
///     ◎  localhost:5173 · 8080
///
/// Marks sit in a 14 pt column in tertiary ink (the state's circle alone, the
/// row's own mark at 10 pt, takes its status colour); facts are caption type in secondary ink, one line each.
/// Only facts that exist are shown: a card for an idle shell can be a title,
/// a folder and a branch.
struct HoverCard: Equatable {
    enum Mark: Equatable {
        case symbol(String)
        case state(Activity, StatusRecord.Need?)
    }

    struct Fact: Equatable {
        var mark: Mark
        var text: NSAttributedString
        /// Paths lose their middle; prose loses its end.
        var truncation: NSLineBreakMode = .byTruncatingTail

        init(_ mark: Mark, _ text: String, truncation: NSLineBreakMode = .byTruncatingTail) {
            self.mark = mark
            self.text = NSAttributedString(string: text, attributes: HoverCard.factAttributes)
            self.truncation = truncation
        }

        init(_ mark: Mark, attributed: NSAttributedString, truncation: NSLineBreakMode = .byTruncatingTail) {
            self.mark = mark
            text = attributed
            self.truncation = truncation
        }
    }

    var title: String
    var facts: [Fact] = []

    static let factAttributes: [NSAttributedString.Key: Any] = [
        .font: Axo.Font.caption, .foregroundColor: Axo.Color.textSecondary,
    ]

    /// "main  ↑2 ↓1   +120 −34": the counts tabular, the diff in its chip colours.
    static func branchLine(_ branch: String?, changes: GitChanges?) -> NSAttributedString? {
        let s = NSMutableAttributedString()
        let meta: [NSAttributedString.Key: Any] = [.font: Axo.Font.meta, .foregroundColor: Axo.Color.textSecondary]
        if let branch { s.append(NSAttributedString(string: branch, attributes: factAttributes)) }
        if let c = changes {
            var sync: [String] = []
            if let a = c.ahead, a > 0 { sync.append("↑\(a)") }
            if let b = c.behind, b > 0 { sync.append("↓\(b)") }
            if !sync.isEmpty {
                if s.length > 0 { s.append(NSAttributedString(string: "  ", attributes: meta)) }
                s.append(NSAttributedString(string: sync.joined(separator: " "), attributes: meta))
            }
            if !c.isEmpty {
                if s.length > 0 { s.append(NSAttributedString(string: "   ", attributes: meta)) }
                s.append(NSAttributedString(string: "+\(c.added)", attributes: [
                    .font: Axo.Font.meta, .foregroundColor: Axo.Color.status(.done),
                ]))
                s.append(NSAttributedString(string: " ", attributes: meta))
                s.append(NSAttributedString(string: "−\(c.removed)", attributes: [
                    .font: Axo.Font.meta, .foregroundColor: Axo.Color.status(.error),
                ]))
            }
        }
        return s.length > 0 ? s : nil
    }
}

/// The card's body, drawn by `Tooltip` in the window's overlay layer.
final class HoverCardView: Surface {
    private let title = Label("", font: Axo.Font.captionTitle, color: Axo.Color.text)
    private var rows: [(mark: NSView, text: Label)] = []
    private static let maxWidth: CGFloat = 320
    private static let padX: CGFloat = Axo.Space.md + 2
    private static let padY: CGFloat = Axo.Space.md
    private static let markColumn: CGFloat = 14
    private static let rowHeight: CGFloat = 16
    private static let rowGap: CGFloat = 2

    init(_ card: HoverCard) {
        super.init(elevation: .float, radius: Axo.Radius.md)
        title.stringValue = card.title
        title.lineBreakMode = .byTruncatingTail
        content.addSubview(title)
        for f in card.facts {
            let mark: NSView
            switch f.mark {
            case let .symbol(name):
                mark = Symbol(name, size: 10, weight: .medium, color: Axo.Color.textTertiary)
            case let .state(a, need):
                mark = Symbol(StatusGlyphView.symbol(a, need) ?? "circle", size: 10, weight: .medium, color: Axo.Color.status(a))
            }
            let l = Label("", font: Axo.Font.caption, color: Axo.Color.textSecondary)
            l.attributedStringValue = f.text
            l.lineBreakMode = f.truncation
            content.addSubview(mark)
            content.addSubview(l)
            rows.append((mark, l))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        let textW = max(ceil(title.intrinsicContentSize.width),
                        rows.map { Self.markColumn + 6 + ceil($0.text.intrinsicContentSize.width) }.max() ?? 0)
        let w = min(Self.maxWidth, textW + Self.padX * 2)
        let h = Self.padY * 2 + ceil(title.intrinsicContentSize.height)
            + CGFloat(rows.count) * (Self.rowHeight + Self.rowGap) + (rows.isEmpty ? 0 : 2)
        return NSSize(width: w, height: h)
    }

    override func layout() {
        super.layout()
        content.frame = bounds
        let w = bounds.width - Self.padX * 2
        let th = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: Self.padX, y: Self.padY, width: w, height: th)
        var y = title.frame.maxY + 2 + Self.rowGap
        for r in rows {
            r.mark.frame = NSRect(x: Self.padX, y: y + 1, width: Self.markColumn, height: Self.rowHeight - 2)
            let x = Self.padX + Self.markColumn + 6
            let lh = ceil(r.text.intrinsicContentSize.height)
            r.text.frame = NSRect(x: x, y: (y + (Self.rowHeight - lh) / 2).rounded(), width: bounds.width - Self.padX - x, height: lh)
            y += Self.rowHeight + Self.rowGap
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
