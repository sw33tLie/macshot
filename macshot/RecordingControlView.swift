import Cocoa

/// Borderless window that can become key (needed to receive ESC key events).
final class RecordingControlWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// A small transparent window view that sits over the right bar during recording
/// (when the main overlay has ignoresMouseEvents = true). Draws the right bar buttons
/// and forwards clicks to the overlay view's toolbar handler.
final class RecordingControlView: NSView {

    weak var overlayView: OverlayView?
    private var hoveredIndex: Int = -1

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    private func localButtons() -> [ToolbarButton] {
        guard let ov = overlayView, ov.rightBarRect != .zero else { return [] }
        let offset = ov.rightBarRect.origin
        var buttons = ov.rightButtons
        for i in buttons.indices {
            buttons[i].rect = NSRect(
                x: buttons[i].rect.origin.x - offset.x,
                y: buttons[i].rect.origin.y - offset.y,
                width: buttons[i].rect.width,
                height: buttons[i].rect.height
            )
            buttons[i].isHovered = (i == hoveredIndex)
        }
        return buttons
    }

    override func draw(_ dirtyRect: NSRect) {
        let buttons = localButtons()
        guard !buttons.isEmpty else { return }
        let barRect = NSRect(origin: .zero, size: bounds.size)
        ToolbarLayout.drawToolbar(barRect: barRect, buttons: buttons, selectionSize: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let buttons = localButtons()
        let newHovered = buttons.firstIndex(where: { $0.rect.contains(point) }) ?? -1
        if newHovered != hoveredIndex {
            hoveredIndex = newHovered
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredIndex != -1 {
            hoveredIndex = -1
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let ov = overlayView else { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        let offset = ov.rightBarRect.origin
        let ovPoint = NSPoint(x: localPoint.x + offset.x, y: localPoint.y + offset.y)

        if let action = ToolbarLayout.hitTest(point: ovPoint, buttons: ov.rightButtons) {
            ov.handleToolbarAction(action, mousePoint: ovPoint)
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            guard let ov = overlayView else { return }
            // Block ESC when actually capturing; allow when just in recording mode
            guard !ov.isCapturingVideo else { return }
            ov.overlayDelegate?.overlayViewDidCancel()
        }
    }

    override var isFlipped: Bool { false }
}
