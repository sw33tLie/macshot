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

        // Match the pre-recording selection chrome: use the user's configured
        // accent color at the same alpha the hardcoded purple used.
        ToolbarLayout.accentColor.withAlphaComponent(0.8).setStroke()
        // Inset by -lineWidth so the stroke is entirely OUTSIDE the selection rect.
        // This prevents the border from appearing in the recording even if the
        // overlay window is captured (SCStream crops to the selection rect).
        let lineW: CGFloat = 1.5
        let path = NSBezierPath(rect: selectionRect.insetBy(dx: -lineW, dy: -lineW))
        path.lineWidth = lineW
        path.stroke()
    }
}
