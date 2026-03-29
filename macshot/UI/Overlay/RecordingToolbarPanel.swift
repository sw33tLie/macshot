import Cocoa

/// Floating panel for recording controls. Lives in its own window so it receives
/// mouse events even when the overlay has ignoresMouseEvents = true.
class RecordingToolbarPanel: NSPanel {

    let stripView = ToolbarStripView(orientation: .vertical)

    /// Callback when a button is clicked.
    var onClick: ((ToolbarButtonAction) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 48, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 2  // above the overlay window
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        contentView = NSView()
        contentView?.addSubview(stripView)

        stripView.onClick = { [weak self] action in
            self?.onClick?(action)
        }
    }

    /// Update the strip buttons and resize the panel to fit.
    func updateButtons(_ buttons: [ToolbarButton]) {
        stripView.setButtons(buttons)
        let stripSize = stripView.frame.size
        let panelSize = NSSize(width: stripSize.width, height: stripSize.height)
        contentView?.frame.size = panelSize
        setContentSize(panelSize)
    }

    /// Position the panel relative to the selection rect in screen coordinates.
    func position(relativeTo selectionRect: NSRect, in overlayWindow: NSWindow) {
        let selScreen = overlayWindow.convertToScreen(selectionRect)
        let panelSize = frame.size

        // Right side of selection, top-aligned
        var px = selScreen.maxX + 6
        if let screen = overlayWindow.screen {
            if px + panelSize.width > screen.visibleFrame.maxX - 4 {
                px = selScreen.minX - panelSize.width - 6
            }
            px = max(screen.visibleFrame.minX + 4, min(px, screen.visibleFrame.maxX - panelSize.width - 4))
        }
        let py = selScreen.maxY - panelSize.height

        setFrameOrigin(NSPoint(x: px, y: py))
    }
}
