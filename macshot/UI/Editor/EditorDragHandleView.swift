import Cocoa

/// Top-bar handle that drags the edited image out of the editor as a file
/// (Finder, Mail, Messages, chat apps), without saving it first (#514).
/// Unlike the floating thumbnail it stays available for the whole editing
/// session and always carries the current annotations and effects.
/// A plain click copies, like the Recent Captures panel.
final class EditorDragHandleView: NSView, NSDraggingSource {

    /// The image exactly as Copy/Save would produce it, built when a drag starts.
    var imageProvider: (() -> NSImage?)?
    /// Called once the drag session ends. `true` when a destination accepted the drop.
    var onDragEnded: ((Bool) -> Void)?
    /// Called for a click without a drag.
    var onClick: (() -> Void)?

    /// Movement (in points) before a press turns into a drag rather than a click.
    static let dragThreshold: CGFloat = 3
    /// Longest side of the drag preview, in points.
    static let previewMaxSide: CGFloat = 140

    private var mouseDownEvent: NSEvent?
    private var dragStarted = false
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    private var hoverTrackingArea: NSTrackingArea?

    private let icon: NSImage? = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = L("Click to copy · Drag to app")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("Click to copy · Drag to app"))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 22) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if isHovered || isPressed {
            let hover: NSColor = ToolbarLayout.usesLightPalette ? .black : .white
            hover.withAlphaComponent(isPressed ? 0.16 : 0.09).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }

        let tint = ToolbarLayout.iconColor.withAlphaComponent(0.85)
        // Grip dots on both sides signal "this can be picked up".
        let dotColor = ToolbarLayout.iconColor.withAlphaComponent(0.4)
        dotColor.setFill()
        let dot: CGFloat = 2
        let gap: CGFloat = 2
        let gripHeight = dot * 3 + gap * 2
        let gripY = bounds.midY - gripHeight / 2
        for x in [bounds.minX + 4, bounds.maxX - 4 - dot * 2 - gap] {
            for column in 0..<2 {
                for row in 0..<3 {
                    let rect = NSRect(x: x + CGFloat(column) * (dot + gap),
                                      y: gripY + CGFloat(row) * (dot + gap),
                                      width: dot, height: dot)
                    NSBezierPath(ovalIn: rect).fill()
                }
            }
        }

        guard let icon else { return }
        let tinted = NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let iconRect = NSRect(x: (bounds.width - icon.size.width) / 2,
                              y: (bounds.height - icon.size.height) / 2,
                              width: icon.size.width, height: icon.size.height).integral
        tinted.draw(in: iconRect)
    }

    // MARK: - Hover + cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    // MARK: - Click / drag

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragStarted = false
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) >= Self.dragThreshold else { return }
        dragStarted = true
        if !beginDrag(with: down) {
            isPressed = false
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownEvent = nil
            isPressed = false
        }
        guard !dragStarted else { return }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onClick?() }
    }

    /// Writes the current image to a private temp file and starts dragging it.
    /// File URLs are what Finder, Messages, WhatsApp, Telegram and Slack accept;
    /// the drop grants the destination read access to the sandboxed temp file.
    @discardableResult
    private func beginDrag(with event: NSEvent) -> Bool {
        guard let image = imageProvider?(),
              let fileURL = Self.writeDragFile(for: image) else {
            onDragEnded?(false)
            return false
        }

        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let previewSize = Self.previewSize(for: image.size)
        let location = convert(event.locationInWindow, from: nil)
        let frame = NSRect(x: location.x - previewSize.width / 2,
                           y: location.y - previewSize.height / 2,
                           width: previewSize.width, height: previewSize.height)
        item.setDraggingFrame(frame, contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        return true
    }

    /// Encodes `image` in the user's configured format into its own temp folder,
    /// named with the user's filename template. Returns nil if encoding fails.
    static func writeDragFile(for image: NSImage) -> URL? {
        guard let data = ImageEncoder.encode(image) else { return nil }
        let url = TmpScratchDirectory.makeURL(filename: FilenameFormatter.defaultImageFilename())
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// The drag preview keeps the image's aspect ratio within `previewMaxSide`.
    static func previewSize(for imageSize: NSSize) -> NSSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return NSSize(width: previewMaxSide, height: previewMaxSide)
        }
        let scale = min(1, previewMaxSide / max(imageSize.width, imageSize.height))
        return NSSize(width: max(1, (imageSize.width * scale).rounded()),
                      height: max(1, (imageSize.height * scale).rounded()))
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Dropping back onto the editor itself does nothing useful.
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragStarted = false
        mouseDownEvent = nil
        isPressed = false
        onDragEnded?(operation != [])
    }
}
