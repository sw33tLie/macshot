import Cocoa

@MainActor
class FloatingThumbnailController: NSObject, NSDraggingSource {

    private var window: NSPanel?
    private var dismissTask: DispatchWorkItem?
    private let image: NSImage
    private var thumbnailView: ThumbnailView?
    var onDismiss: (() -> Void)?

    // Action callbacks
    var onCopy:   (() -> Void)?
    var onSave:   (() -> Void)?
    var onPin:    (() -> Void)?
    var onEdit:   (() -> Void)?
    var onUpload: (() -> Void)?

    init(image: NSImage) {
        self.image = image
        super.init()
    }

    // MARK: - Show

    func show(atY y: CGFloat) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame

        // Fit image within max bounds preserving aspect ratio, then enforce
        // a minimum window size so hover buttons always fit (letterbox if needed).
        let maxWidth: CGFloat = 320
        let minWinWidth: CGFloat = 200
        let minWinHeight: CGFloat = 120
        let padding: CGFloat = 16
        let maxHeight: CGFloat = screenFrame.height - padding * 2

        let imgW = image.size.width
        let imgH = image.size.height
        guard imgW > 0 && imgH > 0 else { return }
        let aspect = imgW / imgH

        // Scale image to fit within maxWidth x maxHeight
        var imgDrawW = min(imgW, maxWidth)
        var imgDrawH = imgDrawW / aspect
        if imgDrawH > maxHeight {
            imgDrawH = maxHeight
            imgDrawW = imgDrawH * aspect
        }

        // Window is at least minWinWidth x minWinHeight, or image size — whichever is larger
        let thumbSize = NSSize(
            width:  ceil(max(minWinWidth, imgDrawW)),
            height: ceil(max(minWinHeight, imgDrawH))
        )

        // Clamp Y so the thumbnail always fits within the visible screen
        let clampedY = min(y, screenFrame.maxY - thumbSize.height - padding)
        let finalY   = max(screenFrame.minY + padding, clampedY)

        let finalX = screenFrame.maxX - thumbSize.width - padding
        let startX = screenFrame.maxX + 10

        let panel = NSPanel(
            contentRect: NSRect(x: startX, y: finalY, width: thumbSize.width, height: thumbSize.height),
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
        panel.acceptsMouseMovedEvents = true

        let view = ThumbnailView(image: image, thumbSize: thumbSize)
        view.frame = NSRect(origin: .zero, size: thumbSize)
        view.autoresizingMask = [.width, .height]

        view.onDragStarted = { [weak self] event in self?.startDrag(event: event) }
        view.onClose  = { [weak self] in self?.dismiss() }
        view.onCopy   = { [weak self] in self?.onCopy?();   self?.dismiss() }
        view.onSave   = { [weak self] in self?.onSave?();   self?.dismiss() }
        view.onPin    = { [weak self] in self?.onPin?();    self?.dismiss() }
        view.onEdit   = { [weak self] in self?.onEdit?();   self?.dismiss() }
        view.onUpload = { [weak self] in self?.onUpload?(); self?.dismiss() }

        panel.contentView = view
        self.window = panel
        self.thumbnailView = view

        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(
                NSRect(x: finalX, y: finalY, width: thumbSize.width, height: thumbSize.height),
                display: true
            )
        })

        scheduleAutoDismiss()
    }

    private func scheduleAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        let seconds = UserDefaults.standard.object(forKey: "thumbnailAutoDismiss") as? Int ?? 5
        guard seconds > 0 else { return }
        let task = DispatchWorkItem { [weak self] in self?.animateOut() }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds), execute: task)
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        thumbnailView = nil
        onDismiss?()
        onDismiss = nil
    }

    var windowFrame: NSRect { window?.frame ?? .zero }

    /// Animate this thumbnail to a new Y position (used when a lower thumbnail is dismissed).
    func moveTo(y: CGFloat) {
        guard let window = window else { return }
        let f = window.frame
        guard f.minY != y else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(
                NSRect(x: f.minX, y: y, width: f.width, height: f.height),
                display: true
            )
        }
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
        guard let encodedData = ImageEncoder.encode(image) else { return }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macshot_\(OverlayWindowController.formattedTimestamp()).\(ImageEncoder.fileExtension)")
        do { try encodedData.write(to: tempURL) } catch { return }

        let draggingItem = NSDraggingItem(pasteboardWriter: tempURL as NSURL)
        draggingItem.setDraggingFrame(view.bounds, contents: image)
        view.beginDraggingSession(with: [draggingItem], event: event, source: self)
        dismissTask?.cancel()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dismiss() }
}

// MARK: - Thumbnail View

private class ThumbnailView: NSView {

    var onDragStarted: ((NSEvent) -> Void)?
    var onClose:  (() -> Void)?
    var onCopy:   (() -> Void)?
    var onSave:   (() -> Void)?
    var onPin:    (() -> Void)?
    var onEdit:   (() -> Void)?
    var onUpload: (() -> Void)?

    private let image: NSImage
    private let thumbSize: NSSize
    private var dragStartPoint: NSPoint?
    private var isHovering: Bool = false
    private var trackingArea: NSTrackingArea?

    // Corner button hit rects (in view coords, updated in draw)
    private var closeBtnRect:  NSRect = .zero
    private var pinBtnRect:    NSRect = .zero
    private var editBtnRect:   NSRect = .zero
    private var uploadBtnRect: NSRect = .zero
    private var copyBtnRect:   NSRect = .zero
    private var saveBtnRect:   NSRect = .zero

    private var hoveredRect: NSRect = .zero

    private let cornerR: CGFloat = 28   // corner button circle radius
    private let centerBtnW: CGFloat = 110
    private let centerBtnH: CGFloat = 32

    init(image: NSImage, thumbSize: NSSize) {
        self.image = image
        self.thumbSize = thumbSize
        super.init(frame: .zero)
        updateTrackingArea()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
        // Pause auto-dismiss while hovering — cancel timer; it resumes on exit
        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        hoveredRect = .zero
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let rects = [closeBtnRect, pinBtnRect, editBtnRect, uploadBtnRect, copyBtnRect, saveBtnRect]
        let hit = rects.first { $0.contains(p) } ?? .zero
        if hit != hoveredRect {
            hoveredRect = hit
            needsDisplay = true
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let cr: CGFloat = 12

        // Rounded clip for entire thumbnail
        let path = NSBezierPath(roundedRect: r, xRadius: cr, yRadius: cr)
        path.addClip()

        // Dark background (visible as letterbox bars for extreme aspect ratios)
        NSColor(white: 0.12, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: r, xRadius: cr, yRadius: cr).fill()

        // Draw image centered, preserving aspect ratio (letterboxed)
        let imgAspect = image.size.width / image.size.height
        var drawW = r.width
        var drawH = drawW / imgAspect
        if drawH > r.height {
            drawH = r.height
            drawW = drawH * imgAspect
        }
        let drawRect = NSRect(
            x: r.midX - drawW / 2,
            y: r.midY - drawH / 2,
            width: drawW,
            height: drawH
        )
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)

        // White border
        NSColor.white.withAlphaComponent(0.4).setStroke()
        let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: cr, yRadius: cr)
        border.lineWidth = 1.5
        border.stroke()

        guard isHovering else { return }

        // Semi-transparent dark overlay
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: r, xRadius: cr, yRadius: cr).fill()

        let pad: CGFloat = 10   // distance from corner to circle center

        // Corner button definitions: (center, symbol, keyPath to write rect)
        let cornerDefs: [(NSPoint, String)] = [
            (NSPoint(x: r.minX + pad + cornerR/2, y: r.maxY - pad - cornerR/2), "xmark"),
            (NSPoint(x: r.maxX - pad - cornerR/2, y: r.maxY - pad - cornerR/2), "pin.fill"),
            (NSPoint(x: r.minX + pad + cornerR/2, y: r.minY + pad + cornerR/2), "pencil"),
            (NSPoint(x: r.maxX - pad - cornerR/2, y: r.minY + pad + cornerR/2), "icloud.and.arrow.up"),
        ]

        var cornerRects: [NSRect] = []
        for (center, symbol) in cornerDefs {
            let circleRect = NSRect(x: center.x - cornerR/2, y: center.y - cornerR/2, width: cornerR, height: cornerR)
            cornerRects.append(circleRect)
            let isHit = circleRect == hoveredRect

            let circlePath = NSBezierPath(ovalIn: circleRect)
            (isHit ? NSColor.white.withAlphaComponent(0.35) : NSColor.white.withAlphaComponent(0.18)).setFill()
            circlePath.fill()
            NSColor.white.withAlphaComponent(0.5).setStroke()
            circlePath.lineWidth = 1
            circlePath.stroke()

            if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                let colored = sym.withSymbolConfiguration(cfg) ?? sym
                let tinted = tintedWhite(colored)
                let iconSize = NSSize(width: 13, height: 13)
                let iconRect = NSRect(x: center.x - iconSize.width/2, y: center.y - iconSize.height/2,
                                     width: iconSize.width, height: iconSize.height)
                tinted.draw(in: iconRect, from: NSRect.zero, operation: .sourceOver, fraction: 1.0)
            }
        }
        if cornerRects.count == 4 {
            closeBtnRect  = cornerRects[0]
            pinBtnRect    = cornerRects[1]
            editBtnRect   = cornerRects[2]
            uploadBtnRect = cornerRects[3]
        }

        // Center action buttons: Copy + Save
        let totalH = centerBtnH * 2 + 8
        let btnsY = r.midY - totalH/2

        let copyRect = NSRect(x: r.midX - centerBtnW/2, y: btnsY + centerBtnH + 8, width: centerBtnW, height: centerBtnH)
        let saveRect = NSRect(x: r.midX - centerBtnW/2, y: btnsY,                  width: centerBtnW, height: centerBtnH)
        copyBtnRect = copyRect
        saveBtnRect = saveRect

        for (rect, title) in [(copyRect, "Copy"), (saveRect, "Save")] {
            let isHit = rect == hoveredRect
            let bg = NSBezierPath(roundedRect: rect, xRadius: centerBtnH/2, yRadius: centerBtnH/2)
            if isHit {
                NSColor.white.withAlphaComponent(0.95).setFill()
            } else {
                NSColor.white.withAlphaComponent(0.85).setFill()
            }
            bg.fill()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: isHit ? NSColor.black : NSColor(white: 0.1, alpha: 1),
            ]
            let str = title as NSString
            let strSize = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: rect.midX - strSize.width/2, y: rect.midY - strSize.height/2), withAttributes: attrs)
        }
    }

    private func tintedWhite(_ img: NSImage) -> NSImage {
        let result = NSImage(size: img.size)
        result.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: img.size).fill()
        img.draw(in: NSRect(origin: .zero, size: img.size), from: .zero, operation: .destinationIn, fraction: 1.0)
        result.unlockFocus()
        return result
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let current = event.locationInWindow
        if hypot(current.x - start.x, current.y - start.y) > 4 {
            dragStartPoint = nil
            onDragStarted?(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartPoint != nil else { return }
        dragStartPoint = nil
        let p = convert(event.locationInWindow, from: nil)

        if closeBtnRect.contains(p)  { onClose?();  return }
        if pinBtnRect.contains(p)    { onPin?();    return }
        if editBtnRect.contains(p)   { onEdit?();   return }
        if uploadBtnRect.contains(p) { onUpload?(); return }
        if copyBtnRect.contains(p)   { onCopy?();   return }
        if saveBtnRect.contains(p)   { onSave?();   return }

        // Click anywhere else on thumbnail — dismiss
        if isHovering { onClose?() }
    }
}
