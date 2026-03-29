import Cocoa

/// Floating red pill showing elapsed recording time.
/// Uses its own NSPanel so it floats above the overlay independently.
/// Click the pill to stop recording.
class RecordingHUDPanel: NSPanel {

    private let timeLabel = NSTextField(labelWithString: "● 00:00")
    var onStopRecording: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 2
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = RecordingHUDContentView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 14
        container.panel = self
        contentView = container

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.isBezeled = false
        timeLabel.drawsBackground = false
        timeLabel.isEditable = false
        timeLabel.alignment = .center
        container.addSubview(timeLabel)
    }

    func update(elapsedSeconds: Int) {
        let mins = elapsedSeconds / 60
        let secs = elapsedSeconds % 60
        timeLabel.stringValue = "● \(String(format: "%02d:%02d", mins, secs))"
        timeLabel.sizeToFit()

        let pillW = timeLabel.frame.width + 24
        let pillH: CGFloat = 28
        timeLabel.frame.origin = NSPoint(x: 12, y: (pillH - timeLabel.frame.height) / 2)
        contentView?.frame.size = NSSize(width: pillW, height: pillH)

        // Resize window to fit
        var f = frame
        f.size = NSSize(width: pillW, height: pillH)
        setFrame(f, display: true)
    }

    /// Position relative to an overlay window's selection rect.
    func position(relativeTo selectionRect: NSRect, in overlayWindow: NSWindow) {
        let selScreen = overlayWindow.convertToScreen(selectionRect)
        positionOnScreen(relativeTo: selScreen, screen: overlayWindow.screen)
    }

    /// Position relative to a screen-space rect (used after overlay is dismissed).
    func positionOnScreen(relativeTo screenRect: NSRect, screen: NSScreen?) {
        let pillW = frame.width
        let pillH = frame.height

        var pillX = screenRect.maxX - pillW - 8
        var pillY = screenRect.maxY + 8

        if let screen = screen {
            pillX = max(screen.visibleFrame.minX + 4, min(pillX, screen.visibleFrame.maxX - pillW - 4))
            pillY = min(pillY, screen.visibleFrame.maxY - pillH - 4)
        }

        setFrameOrigin(NSPoint(x: pillX, y: pillY))
    }

    override var canBecomeKey: Bool { false }
}

/// Content view that handles click events on the HUD pill.
private class RecordingHUDContentView: NSView {
    weak var panel: RecordingHUDPanel?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        panel?.onStopRecording?()
    }
}
