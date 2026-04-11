import Cocoa

/// Floating recording control bar with stop, pause/resume, timer, and drag handle.
/// Sits at `.statusBar + 2` so it's above all recording overlays but not captured by SCStream.
class RecordingHUDPanel: NSPanel {

    var onStopRecording: (() -> Void)?
    var onPauseRecording: (() -> Void)?
    var onResumeRecording: (() -> Void)?

    private let timeLabel = NSTextField(labelWithString: "00:00")
    private let recordDot = NSTextField(labelWithString: "●")
    private let stopButton = NSButton()
    private let pauseButton = NSButton()
    private let dragHandle = NSImageView()
    private let containerView = HUDContainerView()
    private(set) var isPaused = false
    fileprivate(set) var userHasDragged = false

    private let hudHeight: CGFloat = 32
    private let cornerRadius: CGFloat = 10

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 164, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar + 2
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = ToolbarLayout.bgColor.withAlphaComponent(0.94).cgColor
        containerView.layer?.cornerRadius = cornerRadius
        containerView.layer?.borderWidth = 0.5
        containerView.layer?.borderColor = ToolbarLayout.iconColor.withAlphaComponent(0.1).cgColor
        containerView.panel = self
        contentView = containerView

        setupStopButton()
        setupPauseButton()
        setupTimeLabel()
        setupDragHandle()
    }

    // MARK: - Setup

    private func setupStopButton() {
        stopButton.bezelStyle = .regularSquare
        stopButton.isBordered = false
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
        stopButton.contentTintColor = ToolbarLayout.iconColor
        stopButton.imageScaling = .scaleProportionallyDown
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.toolTip = L("Stop Recording")
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        stopButton.image = stopButton.image?.withSymbolConfiguration(cfg)
        containerView.addSubview(stopButton)
    }

    private func setupPauseButton() {
        pauseButton.bezelStyle = .regularSquare
        pauseButton.isBordered = false
        pauseButton.contentTintColor = ToolbarLayout.iconColor
        pauseButton.imageScaling = .scaleProportionallyDown
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        pauseButton.toolTip = L("Pause")
        updatePauseIcon()
        containerView.addSubview(pauseButton)
    }

    private func setupTimeLabel() {
        recordDot.font = .systemFont(ofSize: 11, weight: .bold)
        recordDot.textColor = .systemRed
        recordDot.isBezeled = false
        recordDot.drawsBackground = false
        recordDot.isEditable = false
        containerView.addSubview(recordDot)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = ToolbarLayout.iconColor
        timeLabel.isBezeled = false
        timeLabel.drawsBackground = false
        timeLabel.isEditable = false
        containerView.addSubview(timeLabel)
    }

    private func setupDragHandle() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        dragHandle.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag")?
            .withSymbolConfiguration(cfg)
        dragHandle.contentTintColor = ToolbarLayout.iconColor.withAlphaComponent(0.35)
        dragHandle.imageScaling = .scaleProportionallyDown
        containerView.addSubview(dragHandle)
    }

    // MARK: - Layout

    private func layoutControls() {
        let h = hudHeight
        let btnSize: CGFloat = 24
        let pad: CGFloat = 6

        // Stop button (left)
        stopButton.frame = NSRect(x: pad, y: (h - btnSize) / 2, width: btnSize, height: btnSize)

        // Pause button
        let pauseX = stopButton.frame.maxX + 2
        pauseButton.frame = NSRect(x: pauseX, y: (h - btnSize) / 2, width: btnSize, height: btnSize)

        // Record dot + time label
        recordDot.sizeToFit()
        timeLabel.sizeToFit()
        let dotX = pauseButton.frame.maxX + 6
        recordDot.frame.origin = NSPoint(x: dotX, y: (h - recordDot.frame.height) / 2)
        let timeLabelX = recordDot.frame.maxX + 3
        timeLabel.frame.origin = NSPoint(x: timeLabelX, y: (h - timeLabel.frame.height) / 2)

        // Drag handle (right side)
        let handleW: CGFloat = 20
        // Fixed width so the panel never resizes during recording (prevents origin jumps)
        let totalW: CGFloat = 164
        dragHandle.frame = NSRect(x: totalW - handleW - pad, y: (h - 16) / 2, width: handleW, height: 16)

        // Only set frame size once (first layout), not on every timer tick
        if frame.width != totalW {
            var f = frame
            f.size = NSSize(width: totalW, height: h)
            setFrame(f, display: true)
            contentView?.frame.size = f.size
        }
    }

    // MARK: - Public API

    func update(elapsedSeconds: Int) {
        let mins = elapsedSeconds / 60
        let secs = elapsedSeconds % 60
        timeLabel.stringValue = String(format: "%02d:%02d", mins, secs)
        layoutControls()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        updatePauseIcon()
        recordDot.textColor = paused ? .systemOrange : .systemRed
        pauseButton.toolTip = paused ? L("Resume") : L("Pause")
    }

    /// Position relative to a screen-space rect. Tries above the rect first,
    /// falls back to below if it would go off screen.
    func positionOnScreen(relativeTo screenRect: NSRect, screen: NSScreen?) {
        let w = frame.width
        let h = frame.height
        let gap: CGFloat = 8

        var pillX = screenRect.maxX - w - gap
        var pillY = screenRect.maxY + gap  // above selection

        if let screen = screen {
            let vis = screen.visibleFrame
            // If above would be off screen, place below
            if pillY + h > vis.maxY {
                pillY = screenRect.minY - h - gap
            }
            // Clamp horizontal
            pillX = max(vis.minX + 4, min(pillX, vis.maxX - w - 4))
            // Clamp vertical
            pillY = max(vis.minY + 4, min(pillY, vis.maxY - h - 4))
        }

        setFrameOrigin(NSPoint(x: pillX, y: pillY))
    }

    // MARK: - Actions

    @objc private func stopClicked() { onStopRecording?() }

    @objc private func pauseClicked() {
        if isPaused {
            onResumeRecording?()
        } else {
            onPauseRecording?()
        }
    }

    private func updatePauseIcon() {
        let name = isPaused ? "play.fill" : "pause.fill"
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        pauseButton.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    override var canBecomeKey: Bool { false }
}

// MARK: - Container view (drag handle + hover effects)

private class HUDContainerView: NSView {
    weak var panel: RecordingHUDPanel?
    private var dragOffset: NSPoint = .zero  // offset from panel origin to mouse at drag start
    private var isDragging = false
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func cursorUpdate(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if isInDragZone(localPoint) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if isInDragZone(localPoint) {
            isDragging = true
            // Store offset from mouse to panel origin — used for absolute positioning
            let mouseScreen = NSEvent.mouseLocation
            let panelOrigin = panel?.frame.origin ?? .zero
            dragOffset = NSPoint(x: mouseScreen.x - panelOrigin.x, y: mouseScreen.y - panelOrigin.y)
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let panel = panel else { return }
        panel.userHasDragged = true
        // Absolute positioning from screen coords — no delta accumulation, no drift
        let mouseScreen = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: mouseScreen.x - dragOffset.x, y: mouseScreen.y - dragOffset.y))
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            let localPoint = convert(event.locationInWindow, from: nil)
            if isInDragZone(localPoint) {
                NSCursor.openHand.set()
            }
        }
    }

    /// The rightmost 28pt is the drag zone.
    private func isInDragZone(_ localPoint: NSPoint) -> Bool {
        localPoint.x >= bounds.width - 28
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Draw a subtle separator before the drag handle
        let sepX = bounds.width - 30
        ToolbarLayout.iconColor.withAlphaComponent(0.12).setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: sepX, y: 6))
        sep.line(to: NSPoint(x: sepX, y: bounds.height - 6))
        sep.lineWidth = 0.5
        sep.stroke()
    }
}
