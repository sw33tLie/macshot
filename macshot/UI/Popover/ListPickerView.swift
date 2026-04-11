import Cocoa

/// A simple list picker for use inside an NSPopover.
/// Displays rows of items, highlights the selected one, and calls back on selection.
class ListPickerView: NSView {

    struct Item {
        let title: String
        let isSelected: Bool
        var icon: NSImage? = nil
        var isEnabled: Bool = true
        var subtitle: String? = nil
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

        let width: CGFloat = max(frame.width, 140)
        var y = CGFloat(items.count) * rowHeight + padding  // start from top

        for (i, item) in items.enumerated() {
            y -= rowHeight
            let rv = ListPickerRowView(frame: NSRect(x: 0, y: y, width: width, height: rowHeight))
            rv.title = item.title
            rv.isItemSelected = item.isSelected
            rv.icon = item.icon
            rv.isEnabled = item.isEnabled
            rv.subtitle = item.subtitle
            rv.index = i
            rv.onSelect = { [weak self] idx in self?.onSelect?(idx) }
            addSubview(rv)
            rowViews.append(rv)
        }

        let totalH = CGFloat(items.count) * rowHeight + padding * 2
        frame.size = NSSize(width: width, height: totalH)
    }

    /// Preferred size for the popover, computed from content.
    var preferredSize: NSSize {
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let checkW: CGFloat = 24  // space for checkmark + padding
        let hPad: CGFloat = 20   // horizontal padding
        var maxTextW: CGFloat = 100
        for item in items {
            let textW = (item.title as NSString).size(withAttributes: [.font: font]).width
            maxTextW = max(maxTextW, textW)
        }
        let w = ceil(maxTextW + checkW + hPad)
        let h = CGFloat(items.count) * rowHeight + padding * 2
        return NSSize(width: w, height: h)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrollDidChange),
                name: NSView.boundsDidChangeNotification, object: enclosingScrollView?.contentView)
            enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        } else {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        }
    }

    @objc private func scrollDidChange(_ notification: Notification) {
        guard let mouseLocation = window?.mouseLocationOutsideOfEventStream else { return }
        for rv in rowViews {
            let local = rv.convert(mouseLocation, from: nil)
            let inside = rv.bounds.contains(local)
            if rv.isHovered != inside {
                rv.isHovered = inside
                rv.needsDisplay = true
            }
        }
    }

    /// Scroll the enclosing scroll view so the selected item is visible.
    func scrollToSelected() {
        guard let scrollView = enclosingScrollView else { return }
        for rv in rowViews where rv.isItemSelected {
            scrollView.contentView.scrollToVisible(rv.frame.insetBy(dx: 0, dy: -rowHeight))
            return
        }
    }

    /// Update row widths when placed in a scroll view that's wider.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        for rv in rowViews {
            rv.frame.size.width = newSize.width
        }
    }
}

// MARK: - Row View

private class ListPickerRowView: NSView {
    var title: String = ""
    var isItemSelected: Bool = false
    var icon: NSImage?
    var isEnabled: Bool = true
    var subtitle: String?
    var index: Int = 0
    var onSelect: ((Int) -> Void)?

    fileprivate var isHovered: Bool = false
    private var trackingArea: NSTrackingArea?

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1.0 : 0.35

        if isHovered && isEnabled {
            ToolbarLayout.iconColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 1), xRadius: 4, yRadius: 4).fill()
        }

        // Checkmark for selected items
        let checkX: CGFloat = 8
        if isItemSelected {
            let checkAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: ToolbarLayout.accentColor.withAlphaComponent(alpha),
            ]
            ("✓" as NSString).draw(at: NSPoint(x: checkX, y: bounds.midY - 7), withAttributes: checkAttrs)
        }

        let titleAlpha: CGFloat = (isItemSelected ? 1.0 : 0.7) * alpha
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(titleAlpha),
        ]
        let str = title as NSString
        let strSize = str.size(withAttributes: attrs)

        if let subtitle = subtitle {
            // Title + subtitle side by side
            str.draw(at: NSPoint(x: 24, y: bounds.midY - strSize.height / 2), withAttributes: attrs)
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.35 * alpha),
            ]
            let subStr = subtitle as NSString
            subStr.draw(at: NSPoint(x: 24 + strSize.width + 4, y: bounds.midY - strSize.height / 2 + 1), withAttributes: subAttrs)
        } else {
            str.draw(at: NSPoint(x: 24, y: bounds.midY - strSize.height / 2), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onSelect?(index)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

}
