import Cocoa

/// Emoji grid picker with category tabs, for use inside an NSPopover.
class EmojiPickerView: NSView {

    var onSelectEmoji: ((String) -> Void)?
    private var categoryIndex: Int = 0

    private let cols = 8
    private let cellSize: CGFloat = 32
    private let padding: CGFloat = 8
    private let tabH: CGFloat = 30

    private var categories: [(String, [String])] { StampEmojis.categories }

    init() {
        super.init(frame: .zero)
        updateSize()
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredSize: NSSize { frame.size }

    private func updateSize() {
        let emojis = categories[categoryIndex].1
        let rows = (emojis.count + cols - 1) / cols
        let w = padding * 2 + CGFloat(cols) * cellSize
        let h = padding + tabH + 4 + CGFloat(rows) * cellSize + padding
        frame.size = NSSize(width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let cats = categories
        guard categoryIndex < cats.count else { return }
        let emojis = cats[categoryIndex].1

        // Category tabs
        let tabW = (bounds.width - padding * 2) / CGFloat(cats.count)
        let tabY = bounds.maxY - padding - tabH
        for (i, cat) in cats.enumerated() {
            let tabRect = NSRect(x: padding + CGFloat(i) * tabW, y: tabY, width: tabW, height: tabH)
            if i == categoryIndex {
                ToolbarLayout.accentColor.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: tabRect.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
            }
            let tabStr = cat.0 as NSString
            let tabAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16)]
            let tabSize = tabStr.size(withAttributes: tabAttrs)
            tabStr.draw(at: NSPoint(x: tabRect.midX - tabSize.width / 2, y: tabRect.midY - tabSize.height / 2), withAttributes: tabAttrs)
        }

        // Separator
        ToolbarLayout.iconColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: NSRect(x: padding, y: tabY - 1, width: bounds.width - padding * 2, height: 0.5)).fill()

        // Emoji grid
        for (i, emoji) in emojis.enumerated() {
            let col = i % cols
            let row = i / cols
            let cx = padding + CGFloat(col) * cellSize
            let cy = tabY - 4 - cellSize - CGFloat(row) * cellSize
            let cellRect = NSRect(x: cx, y: cy, width: cellSize, height: cellSize)
            let str = emoji as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22)]
            let size = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: cellRect.midX - size.width / 2, y: cellRect.midY - size.height / 2), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let cats = categories
        let emojis = cats[categoryIndex].1

        // Check category tab clicks
        let tabW = (bounds.width - padding * 2) / CGFloat(cats.count)
        let tabY = bounds.maxY - padding - tabH
        for i in 0..<cats.count {
            let tabRect = NSRect(x: padding + CGFloat(i) * tabW, y: tabY, width: tabW, height: tabH)
            if tabRect.contains(pt) {
                categoryIndex = i
                updateSize()
                // Resize the popover
                if let popover = window?.value(forKey: "_popover") as? NSPopover {
                    popover.contentSize = frame.size
                }
                needsDisplay = true
                return
            }
        }

        // Check emoji cell clicks
        for (i, emoji) in emojis.enumerated() {
            let col = i % cols
            let row = i / cols
            let cx = padding + CGFloat(col) * cellSize
            let cy = tabY - 4 - cellSize - CGFloat(row) * cellSize
            let cellRect = NSRect(x: cx, y: cy, width: cellSize, height: cellSize)
            if cellRect.contains(pt) {
                onSelectEmoji?(emoji)
                PopoverHelper.dismiss()
                return
            }
        }
    }
}
