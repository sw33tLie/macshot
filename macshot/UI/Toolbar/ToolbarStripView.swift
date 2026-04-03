import Cocoa

/// Real NSView container for a row (horizontal) or column (vertical) of ToolbarButtonViews.
/// Dark rounded background matching the existing toolbar look.
class ToolbarStripView: NSView {

    enum Orientation { case horizontal, vertical }

    let orientation: Orientation
    private(set) var buttonViews: [ToolbarButtonView] = []
    /// Set to true in editor mode so gap clicks pass through to the image beneath.
    var passesThrough = false

    var onClick: ((ToolbarButtonAction) -> Void)?
    var onMouseDown: ((ToolbarButtonAction) -> Void)?
    var onRightClick: ((ToolbarButtonAction, NSView) -> Void)?
    var onHover: ((ToolbarButtonAction, Bool) -> Void)?

    private let padding: CGFloat = 4
    private let spacing: CGFloat = 2

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuild buttons from ToolbarButton data.
    func setButtons(_ buttons: [ToolbarButton]) {
        for bv in buttonViews { bv.removeFromSuperview() }
        buttonViews.removeAll()

        for data in buttons {
            let bv = ToolbarButtonView(action: data.action, sfSymbol: data.sfSymbol, tooltip: data.tooltip)
            bv.isOn = data.isSelected
            bv.tintColor = data.tintColor
            bv.swatchColor = data.bgColor
            bv.hasContextMenu = data.hasContextMenu
            bv.onClick = { [weak self] action in self?.onClick?(action) }
            bv.onRightClick = { [weak self] action, view in self?.onRightClick?(action, view) }
            bv.onHover = { [weak self] action, hovered in self?.onHover?(action, hovered) }
            addSubview(bv)
            buttonViews.append(bv)
        }
        layoutButtons()
    }

    /// Update visual state without rebuilding.
    func updateState(from buttons: [ToolbarButton]) {
        for (i, data) in buttons.enumerated() where i < buttonViews.count {
            buttonViews[i].isOn = data.isSelected
            buttonViews[i].tintColor = data.tintColor
            buttonViews[i].swatchColor = data.bgColor
            buttonViews[i].sfSymbol = data.sfSymbol
            buttonViews[i].needsDisplay = true
        }
    }

    private func layoutButtons() {
        let btnSize = ToolbarButtonView.size
        let count = CGFloat(buttonViews.count)
        guard count > 0 else { frame.size = .zero; return }

        switch orientation {
        case .horizontal:
            let w = count * btnSize + max(0, count - 1) * spacing + padding * 2
            let h = btnSize + padding * 2
            frame.size = NSSize(width: w, height: h)
            // Left-align buttons
            for (i, bv) in buttonViews.enumerated() {
                bv.frame.origin = NSPoint(x: padding + CGFloat(i) * (btnSize + spacing), y: padding)
            }
        case .vertical:
            let w = btnSize + padding * 2
            let h = count * btnSize + max(0, count - 1) * spacing + padding * 2
            frame.size = NSSize(width: w, height: h)
            for (i, bv) in buttonViews.enumerated() {
                // First button at top
                bv.frame.origin = NSPoint(x: padding, y: h - padding - btnSize - CGFloat(i) * (btnSize + spacing))
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    // Consume clicks on gaps between buttons so they don't fall through to OverlayView.
    // In editor mode (passesThrough), let gap clicks pass through so drawing works
    // over the toolbar area.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let result = super.hitTest(point), result !== self { return result }
        if passesThrough { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
