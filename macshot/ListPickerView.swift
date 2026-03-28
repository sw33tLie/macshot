import Cocoa

/// A simple list picker for use inside an NSPopover.
/// Displays rows of items, highlights the selected one, and calls back on selection.
class ListPickerView: NSView {

    struct Item {
        let title: String
        let isSelected: Bool
        var icon: NSImage? = nil
    }

    var items: [Item] = [] { didSet { rebuildRows() } }
    var onSelect: ((Int) -> Void)?

    private let rowHeight: CGFloat = 28
    private let padding: CGFloat = 6
    private var rowViews: [ListPickerRowView] = []

    init() {
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuildRows() {
        for rv in rowViews { rv.removeFromSuperview() }
        rowViews.removeAll()

        let width: CGFloat = frame.width > 0 ? frame.width : 140
        var y = CGFloat(items.count) * rowHeight + padding  // start from top

        for (i, item) in items.enumerated() {
            y -= rowHeight
            let rv = ListPickerRowView(frame: NSRect(x: 0, y: y, width: width, height: rowHeight))
            rv.title = item.title
            rv.isItemSelected = item.isSelected
            rv.icon = item.icon
            rv.index = i
            rv.onSelect = { [weak self] idx in self?.onSelect?(idx) }
            addSubview(rv)
            rowViews.append(rv)
        }

        let totalH = CGFloat(items.count) * rowHeight + padding * 2
        frame.size = NSSize(width: width, height: totalH)
    }

    /// Preferred size for the popover.
    var preferredSize: NSSize {
        let w: CGFloat = 140
        let h = CGFloat(items.count) * rowHeight + padding * 2
        return NSSize(width: w, height: h)
    }
}

// MARK: - Row View

private class ListPickerRowView: NSView {
    var title: String = ""
    var isItemSelected: Bool = false
    var icon: NSImage?
    var index: Int = 0
    var onSelect: ((Int) -> Void)?

    private var isHovered: Bool = false
    private var trackingArea: NSTrackingArea?

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.white.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 4, yRadius: 4).fill()
        }

        // Checkmark for selected items
        let checkX: CGFloat = 8
        if isItemSelected {
            let checkAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: ToolbarLayout.accentColor,
            ]
            ("✓" as NSString).draw(at: NSPoint(x: checkX, y: bounds.midY - 7), withAttributes: checkAttrs)
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(isItemSelected ? 1.0 : 0.7),
        ]
        let str = title as NSString
        let strSize = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: 24, y: bounds.midY - strSize.height / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(index)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
}
