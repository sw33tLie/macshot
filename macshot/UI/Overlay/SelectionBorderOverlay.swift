import Cocoa

/// Transparent fullscreen overlay that draws a selection border rectangle during recording.
/// Shows the user which area is being captured. Click-through (ignoresMouseEvents).
class SelectionBorderOverlay: NSPanel {

    private let borderView: SelectionBorderView

    init(screen: NSScreen) {
        borderView = SelectionBorderView()
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 1
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        borderView.frame = NSRect(origin: .zero, size: screen.frame.size)
        borderView.autoresizingMask = [.width, .height]
        contentView = borderView
    }

    /// Set the selection rect in screen coordinates.
    func setSelectionRect(_ screenRect: NSRect) {
        // Convert screen coords to window-local coords
        let localRect = convertFromScreen(screenRect)
        borderView.selectionRect = localRect
        borderView.needsDisplay = true
    }
}

private class SelectionBorderView: NSView {

    var selectionRect: NSRect = .zero

    override func draw(_ dirtyRect: NSRect) {
        guard selectionRect.width > 0, selectionRect.height > 0 else { return }

        let borderColor = NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.85, alpha: 0.8)
        borderColor.setStroke()
        let path = NSBezierPath(rect: selectionRect)
        path.lineWidth = 1.5
        path.stroke()
    }
}
