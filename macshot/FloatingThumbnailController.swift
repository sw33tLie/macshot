import Cocoa

class FloatingThumbnailController: NSObject, NSDraggingSource {

    private var window: NSPanel?
    private var dismissTask: DispatchWorkItem?
    private let image: NSImage
    private var thumbnailView: ThumbnailView?

    init(image: NSImage) {
        self.image = image
        super.init()
    }

    func show() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame

        // Thumbnail size: max 160px wide, maintain aspect ratio
        let maxWidth: CGFloat = 160
        let scale = min(1.0, maxWidth / image.size.width)
        let thumbSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let padding: CGFloat = 16

        // Start offscreen to the right, animate in
        let finalX = screenFrame.maxX - thumbSize.width - padding
        let startX = screenFrame.maxX + 10
        let y = screenFrame.minY + padding

        let panel = NSPanel(
            contentRect: NSRect(x: startX, y: y, width: thumbSize.width, height: thumbSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let view = ThumbnailView(image: image)
        view.frame = NSRect(origin: .zero, size: thumbSize)
        view.autoresizingMask = [.width, .height]
        view.onClick = { [weak self] in
            self?.dismiss()
        }
        view.onDragStarted = { [weak self] event in
            self?.startDrag(event: event)
        }

        panel.contentView = view
        self.window = panel
        self.thumbnailView = view

        panel.orderFrontRegardless()

        // Animate slide in
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(
                NSRect(x: finalX, y: y, width: thumbSize.width, height: thumbSize.height),
                display: true
            )
        })

        // Auto-dismiss after 5 seconds
        let task = DispatchWorkItem { [weak self] in
            self?.animateOut()
        }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        thumbnailView = nil
    }

    private func animateOut() {
        guard let window = window else { return }
        let frame = window.frame
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let offscreenX = screen.visibleFrame.maxX + 10

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(
                NSRect(x: offscreenX, y: frame.minY, width: frame.width, height: frame.height),
                display: true
            )
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.dismiss()
        })
    }

    // MARK: - Drag as file

    private func startDrag(event: NSEvent) {
        guard let view = thumbnailView else { return }

        // Write temp PNG
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macshot_\(OverlayWindowController.formattedTimestamp()).png")
        do {
            try pngData.write(to: tempURL)
        } catch {
            return
        }

        let draggingItem = NSDraggingItem(pasteboardWriter: tempURL as NSURL)
        draggingItem.setDraggingFrame(view.bounds, contents: image)

        view.beginDraggingSession(with: [draggingItem], event: event, source: self)

        // Cancel auto-dismiss during drag
        dismissTask?.cancel()
    }

    // NSDraggingSource
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? .copy : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dismiss()
    }
}

// MARK: - Thumbnail View

private class ThumbnailView: NSView {

    var onClick: (() -> Void)?
    var onDragStarted: ((NSEvent) -> Void)?

    private let image: NSImage
    private var dragStartPoint: NSPoint?

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        path.addClip()
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)

        // Border
        NSColor.white.withAlphaComponent(0.4).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        border.lineWidth = 1.5
        border.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let current = event.locationInWindow
        let distance = hypot(current.x - start.x, current.y - start.y)
        if distance > 4 {
            dragStartPoint = nil
            onDragStarted?(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        // If we didn't drag, it's a click — dismiss
        if dragStartPoint != nil {
            dragStartPoint = nil
            onClick?()
        }
    }
}
