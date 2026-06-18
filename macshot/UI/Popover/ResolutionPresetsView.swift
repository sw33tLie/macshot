import Cocoa

/// Popover content for the resolution-box presets, laid out in TWO COLUMNS
/// (aspect ratios | pixel resolutions) so the popover stays compact, with a
/// footer: a "keep ratio for next captures" toggle and a px/pt unit selector.
final class ResolutionPresetsView: NSView {

    struct Row {
        let title: String
        let isSelected: Bool
        let action: () -> Void
    }

    var ratioRows: [Row] = []
    var resolutionRows: [Row] = []
    var keepRatioOn = false
    var onToggleKeepRatio: ((Bool) -> Void)?
    var showsKeepRatioToggle = true
    var showsUnitSelector = true
    /// 0 = pixels, 1 = points.
    var unitIndex = 0
    var onPickUnit: ((Int) -> Void)?

    private let rowH: CGFloat = 26
    private let colW: CGFloat = 116
    private let headerH: CGFloat = 22
    private let vPad: CGFloat = 8
    private let fullFooterH: CGFloat = 78
    private let keepRatioFooterH: CGFloat = 44
    private let midGap: CGFloat = 1  // vertical divider column

    func build() {
        subviews.forEach { $0.removeFromSuperview() }

        let rows = max(ratioRows.count, resolutionRows.count)
        let colsH = headerH + CGFloat(rows) * rowH
        let totalW = colW * 2 + midGap
        let activeFooterH = footerHeight
        let totalH = vPad + colsH + activeFooterH + vPad
        frame.size = NSSize(width: totalW, height: totalH)

        // Column headers + rows (top-to-bottom).
        addColumn(rows: ratioRows, x: 0, header: L("Aspect ratio"), colsH: colsH, totalH: totalH)
        addColumn(rows: resolutionRows, x: colW + midGap, header: L("Resolution"), colsH: colsH, totalH: totalH)

        // Vertical divider between columns.
        let divX = colW + midGap / 2
        let div = NSView(frame: NSRect(x: divX, y: totalH - vPad - colsH, width: 1, height: colsH))
        div.wantsLayer = true
        div.layer?.backgroundColor = ToolbarLayout.iconColor.withAlphaComponent(0.12).cgColor
        addSubview(div)

        if activeFooterH > 0 {
            // Horizontal separator above the footer.
            let sepY = activeFooterH + vPad
            let hsep = NSView(frame: NSRect(x: 12, y: sepY, width: totalW - 24, height: 1))
            hsep.wantsLayer = true
            hsep.layer?.backgroundColor = ToolbarLayout.iconColor.withAlphaComponent(0.12).cgColor
            addSubview(hsep)

            buildFooter(width: totalW, height: activeFooterH)
        }
    }

    private func addColumn(rows: [Row], x: CGFloat, header: String, colsH: CGFloat, totalH: CGFloat) {
        var y = totalH - vPad - headerH
        let head = NSTextField(labelWithString: header.uppercased())
        head.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        head.textColor = ToolbarLayout.iconColor.withAlphaComponent(0.5)
        head.frame = NSRect(x: x + 14, y: y, width: colW - 16, height: headerH)
        addSubview(head)

        for row in rows {
            y -= rowH
            let rv = ResolutionPresetRow(frame: NSRect(x: x, y: y, width: colW, height: rowH))
            rv.title = row.title
            rv.isItemSelected = row.isSelected
            rv.onClick = row.action
            addSubview(rv)
        }
    }

    private var footerHeight: CGFloat {
        if showsKeepRatioToggle && showsUnitSelector { return fullFooterH }
        if showsKeepRatioToggle { return keepRatioFooterH }
        if showsUnitSelector { return keepRatioFooterH }
        return 0
    }

    private func buildFooter(width: CGFloat, height: CGFloat) {
        // Toggle row.
        if showsKeepRatioToggle {
            let toggleY = height - 30
            let label = NSTextField(labelWithString: L("Keep ratio for next captures"))
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = ToolbarLayout.iconColor
            label.frame = NSRect(x: 14, y: toggleY, width: width - 70, height: 18)
            addSubview(label)

            let toggle = NSSwitch()
            toggle.state = keepRatioOn ? .on : .off
            toggle.target = self
            toggle.action = #selector(keepRatioChanged(_:))
            let sw = toggle.intrinsicContentSize
            toggle.frame = NSRect(x: width - sw.width - 12, y: toggleY - 2, width: sw.width, height: sw.height)
            addSubview(toggle)
        }

        // Unit selector (px | pt).
        if showsUnitSelector {
            let unitY: CGFloat = showsKeepRatioToggle ? 10 : height - 32
            let unitLabel = NSTextField(labelWithString: L("Units"))
            unitLabel.font = NSFont.systemFont(ofSize: 11)
            unitLabel.textColor = ToolbarLayout.iconColor
            unitLabel.frame = NSRect(x: 14, y: unitY + 2, width: 60, height: 18)
            addSubview(unitLabel)

            let seg = NSSegmentedControl(labels: ["px", "pt"], trackingMode: .selectOne, target: self, action: #selector(unitChanged(_:)))
            seg.selectedSegment = unitIndex
            seg.segmentDistribution = .fillEqually
            let segW: CGFloat = 80
            seg.frame = NSRect(x: width - segW - 12, y: unitY, width: segW, height: 22)
            addSubview(seg)
        }
    }

    var preferredSize: NSSize { frame.size }

    @objc private func keepRatioChanged(_ sender: NSSwitch) { onToggleKeepRatio?(sender.state == .on) }
    @objc private func unitChanged(_ sender: NSSegmentedControl) { onPickUnit?(sender.selectedSegment) }
}

/// A single selectable preset row (checkmark + hover bg).
private final class ResolutionPresetRow: NSView {
    var title: String = ""
    var isItemSelected = false
    var onClick: (() -> Void)?
    private var hovered = false
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            ToolbarLayout.iconColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isItemSelected ? .semibold : .regular),
            .foregroundColor: ToolbarLayout.iconColor,
        ]
        let ts = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: 26, y: (bounds.height - ts.height) / 2), withAttributes: attrs)
        if isItemSelected {
            let check = "\u{2713}"
            let cattrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.systemGreen,
            ]
            let cs = (check as NSString).size(withAttributes: cattrs)
            (check as NSString).draw(at: NSPoint(x: 9, y: (bounds.height - cs.height) / 2), withAttributes: cattrs)
        }
    }
}
