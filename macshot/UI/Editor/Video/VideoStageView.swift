import AVFoundation
import AppKit

/// The preview surface: the rendered canvas centered on a dark stage, with a
/// direct-manipulation overlay for zoom windows, text boxes, blur regions
/// and cropping.
final class VideoStageView: NSView {
    private let document: VideoEditorDocument
    private let playback: VideoEditorPlayback
    private let canvasView = NSView()
    private let playerLayer: AVPlayerLayer
    let overlay: VideoStageOverlay
    private var observerID: UUID?
    private var lastCanvasAspect: CGFloat = 0

    /// Crop editing mode shows the full recording and a crop box.
    var isCropping = false {
        didSet {
            guard isCropping != oldValue else { return }
            var options = playback.options
            options.showUncropped = isCropping
            playback.options = options
            overlay.mode = isCropping ? .crop : .selection
            needsLayout = true
        }
    }

    init(document: VideoEditorDocument, playback: VideoEditorPlayback) {
        self.document = document
        self.playback = playback
        playerLayer = AVPlayerLayer(player: playback.player)
        overlay = VideoStageOverlay(document: document)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = VideoEditorStyle.stage.cgColor

        canvasView.wantsLayer = true
        canvasView.layer?.backgroundColor = NSColor.black.cgColor
        canvasView.layer?.cornerRadius = 3
        canvasView.layer?.masksToBounds = true
        playerLayer.videoGravity = .resize
        playerLayer.frame = canvasView.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        canvasView.layer?.addSublayer(playerLayer)
        addSubview(canvasView)
        overlay.stage = self
        addSubview(overlay)

        observerID = document.observe { [weak self] change in
            guard let self else { return }
            if change.contains(.render) || change.contains(.selection) || change.contains(.segments) {
                self.needsLayout = true
                self.overlay.needsDisplay = true
                self.updateCameraSuspension()
            }
        }
        updateCameraSuspension()
    }

    required init?(coder: NSCoder) { fatalError() }

    func tearDown() {
        if let observerID { document.removeObserver(observerID) }
        overlay.endTextEditing(commit: true)
    }

    /// Canvas aspect for the current mode (uncropped while cropping).
    var layoutForDisplay: VideoSceneLayout? {
        playback.planner.layout(for: document.project, showUncropped: isCropping)
    }

    override func layout() {
        super.layout()
        guard let layout = layoutForDisplay else { return }
        let canvas = layout.canvasSize
        let inset: CGFloat = 28
        let available = bounds.insetBy(dx: inset, dy: inset)
        guard available.width > 10, available.height > 10, canvas.width > 0 else { return }
        let fit = min(available.width / canvas.width, available.height / canvas.height)
        let size = NSSize(width: floor(canvas.width * fit), height: floor(canvas.height * fit))
        let frame = NSRect(x: floor(bounds.midX - size.width / 2), y: floor(bounds.midY - size.height / 2),
                           width: size.width, height: size.height)
        if canvasView.frame != frame {
            canvasView.frame = frame
            overlay.frame = frame.insetBy(dx: -14, dy: -14)
        }
        // Render the preview at the canvas's on-screen pixel size.
        let backing = window?.backingScaleFactor ?? 2
        let scale = min(1, max(0.1, size.width * backing / canvas.width))
        let rounded = (scale * 20).rounded(.up) / 20
        if abs(playback.previewScale - rounded) > 0.001 { playback.previewScale = rounded }
        overlay.needsDisplay = true
    }

    /// Playback always shows the final result; editing aids appear only while
    /// paused (the convention in Screen Studio, Final Cut and CapCut).
    var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            updateCameraSuspension()
            overlay.needsDisplay = true
        }
    }

    /// Paused spatial edits show the whole canvas: the camera would move the
    /// content out from under the handles.
    private func updateCameraSuspension() {
        let spatial: Bool
        switch document.selection {
        case .zoom?, .censor?, .text?: spatial = true
        default: spatial = false
        }
        let suspend = (spatial && !isPlaying) || isCropping
        if playback.options.suspendCamera != suspend {
            var options = playback.options
            options.suspendCamera = suspend
            playback.options = options
        }
    }

    /// Canvas rect within the overlay's coordinate space.
    var canvasRectInOverlay: NSRect {
        convert(canvasView.frame, to: overlay)
    }

    override func mouseDown(with event: NSEvent) {
        // While playing, a click pauses: editing happens on a still frame.
        if isPlaying, !isCropping { playback.pause(); return }
        // Clicking the empty stage clears the selection.
        overlay.endTextEditing(commit: true)
        if !isCropping { document.select(nil) }
    }
}

/// Handles and hit-testing for spatial items. Coordinates are normalized to
/// the canvas (top-left origin).
final class VideoStageOverlay: NSView {
    enum Mode { case selection, crop }

    weak var stage: VideoStageView?
    private let document: VideoEditorDocument
    var mode: Mode = .selection { didSet { needsDisplay = true } }

    private enum Handle { case body, n, s, e, w, ne, nw, se, sw }
    private var drag: (handle: Handle, startRect: CGRect, startPoint: NSPoint)?
    private var textEditor: InlineVideoTextView?
    private var textEditorScroll: NSScrollView?
    private var editingTextID: UUID?

    init(document: VideoEditorDocument) {
        self.document = document
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// Clicks act immediately even when the editor window is inactive.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private var layout: VideoSceneLayout? { stage?.layoutForDisplay }
    private var canvasRect: NSRect { stage?.canvasRectInOverlay ?? bounds }

    private func viewRect(normalized r: CGRect) -> NSRect {
        let c = canvasRect
        return NSRect(x: c.minX + r.minX * c.width, y: c.minY + r.minY * c.height,
                      width: r.width * c.width, height: r.height * c.height)
    }

    private func normalized(viewRect r: NSRect) -> CGRect {
        let c = canvasRect
        return CGRect(x: (r.minX - c.minX) / c.width, y: (r.minY - c.minY) / c.height,
                      width: r.width / c.width, height: r.height / c.height)
    }

    /// The edited item's rect in normalized canvas coordinates.
    private func currentRect() -> (CGRect, NSColor, String)? {
        guard let layout else { return nil }
        let canvas = layout.canvasSize
        func sceneRect(forContent r: CGRect) -> CGRect {
            let pixels = layout.canvasRect(forContent: r)
            return CGRect(x: pixels.minX / canvas.width, y: pixels.minY / canvas.height,
                          width: pixels.width / canvas.width, height: pixels.height / canvas.height)
        }
        if mode == .crop {
            return (document.project.crop, VideoEditorStyle.accent, L("Crop"))
        }
        let p = document.project
        switch document.selection {
        case .zoom(let id)?:
            guard let z = p.zooms.first(where: { $0.id == id }) else { return nil }
            let f = CameraState.clampedFocus(layout.sceneNormalized(forContent: z.center), zoom: z.zoomLevel)
            let side = 1 / z.zoomLevel
            let label = z.followsCursor ? String(format: L("%.1f× · follows pointer"), z.zoomLevel)
                                        : String(format: "%.1f×", z.zoomLevel)
            return (CGRect(x: f.x - side / 2, y: f.y - side / 2, width: side, height: side), VideoEditorStyle.zoom, label)
        case .censor(let id)?:
            guard let c = p.censors.first(where: { $0.id == id }) else { return nil }
            return (sceneRect(forContent: c.rect), VideoEditorStyle.censor, "")
        case .text(let id)?:
            guard let t = p.texts.first(where: { $0.id == id }) else { return nil }
            return (sceneRect(forContent: t.rect), VideoEditorStyle.text, "")
        default:
            return nil
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !hidesForPlayback, let (rect, color, label) = currentRect() else { return }
        let r = viewRect(normalized: rect)
        if mode == .crop || (document.selection.map { if case .zoom = $0 { return true }; return false } ?? false) {
            // Dim everything outside the box.
            let outside = NSBezierPath(rect: canvasRect)
            outside.append(NSBezierPath(rect: r).reversed)
            NSColor(white: 0, alpha: 0.45).setFill()
            outside.fill()
        }
        let border = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 2
        color.setStroke()
        border.stroke()
        if mode == .crop {
            // Rule-of-thirds guides.
            let guides = NSBezierPath()
            for i in 1...2 {
                let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                guides.move(to: NSPoint(x: x, y: r.minY)); guides.line(to: NSPoint(x: x, y: r.maxY))
                guides.move(to: NSPoint(x: r.minX, y: y)); guides.line(to: NSPoint(x: r.maxX, y: y))
            }
            NSColor(white: 1, alpha: 0.3).setStroke()
            guides.lineWidth = 1
            guides.stroke()
        }
        for (_, point) in handles(for: r) {
            let knob = NSRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knob).fill()
            color.setStroke()
            let ring = NSBezierPath(ovalIn: knob)
            ring.lineWidth = 1.5
            ring.stroke()
        }
        if !label.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: VideoEditorStyle.font(11, .semibold), .foregroundColor: NSColor.white]
            let size = (label as NSString).size(withAttributes: attrs)
            let badge = NSRect(x: r.minX, y: max(canvasRect.minY, r.minY - size.height - 10), width: size.width + 14, height: size.height + 6)
            color.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
            (label as NSString).draw(at: NSPoint(x: badge.minX + 7, y: badge.minY + 3), withAttributes: attrs)
        }
    }

    private func handles(for r: NSRect) -> [(Handle, NSPoint)] {
        var result: [(Handle, NSPoint)] = [(.nw, NSPoint(x: r.minX, y: r.minY)), (.ne, NSPoint(x: r.maxX, y: r.minY)),
                                           (.sw, NSPoint(x: r.minX, y: r.maxY)), (.se, NSPoint(x: r.maxX, y: r.maxY))]
        if !isZoomSelected {
            result += [(.n, NSPoint(x: r.midX, y: r.minY)), (.s, NSPoint(x: r.midX, y: r.maxY)),
                       (.w, NSPoint(x: r.minX, y: r.midY)), (.e, NSPoint(x: r.maxX, y: r.midY))]
        }
        return result
    }

    private var isZoomSelected: Bool {
        guard mode == .selection, case .zoom? = document.selection else { return false }
        return true
    }

    // MARK: Input

    /// Handles are hidden during playback, where the camera moves the content.
    private var hidesForPlayback: Bool { mode == .selection && stage?.isPlaying == true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if hidesForPlayback { return nil }
        let local = convert(point, from: superview)
        if let textEditorScroll, textEditorScroll.frame.contains(local) { return super.hitTest(point) }
        guard let (rect, _, _) = currentRect() else { return nil }
        let r = viewRect(normalized: rect).insetBy(dx: -8, dy: -8)
        return r.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (rect, _, _) = currentRect() else { return }
        let r = viewRect(normalized: rect)
        if event.clickCount == 2, case .text(let id)? = document.selection {
            beginTextEditing(id: id)
            return
        }
        let handle = handles(for: r).first { hypot($0.1.x - p.x, $0.1.y - p.y) < 9 }?.0 ?? .body
        drag = (handle, rect, p)
        document.beginGesture()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        let c = canvasRect
        let dx = (p.x - drag.startPoint.x) / c.width, dy = (p.y - drag.startPoint.y) / c.height
        var r = drag.startRect
        switch drag.handle {
        case .body:
            r.origin.x += dx; r.origin.y += dy
            r.origin.x = min(max(0, r.origin.x), 1 - r.width)
            r.origin.y = min(max(0, r.origin.y), 1 - r.height)
        default:
            r = resized(drag.startRect, handle: drag.handle, dx: dx, dy: dy)
        }
        apply(r, moved: drag.handle == .body)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil
        document.endGesture()
    }

    private func resized(_ start: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = start.minX, minY = start.minY, maxX = start.maxX, maxY = start.maxY
        switch handle {
        case .n: minY += dy
        case .s: maxY += dy
        case .w: minX += dx
        case .e: maxX += dx
        case .nw: minX += dx; minY += dy
        case .ne: maxX += dx; minY += dy
        case .sw: minX += dx; maxY += dy
        case .se: maxX += dx; maxY += dy
        case .body: break
        }
        if isZoomSelected {
            // Zoom windows keep the canvas aspect: resize uniformly about the
            // opposite corner.
            let side = max(maxX - minX, maxY - minY)
            switch handle {
            case .nw: minX = maxX - side; minY = maxY - side
            case .ne: maxX = minX + side; minY = maxY - side
            case .sw: minX = maxX - side; maxY = minY + side
            default: maxX = minX + side; maxY = minY + side
            }
        }
        let minSize: CGFloat = 0.03
        minX = max(0, min(minX, maxX - minSize)); minY = max(0, min(minY, maxY - minSize))
        maxX = min(1, max(maxX, minX + minSize)); maxY = min(1, max(maxY, minY + minSize))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Writes a normalized canvas rect back to the selected item.
    private func apply(_ rect: CGRect, moved: Bool = false) {
        guard let layout else { return }
        let canvas = layout.canvasSize
        func contentRect(_ r: CGRect) -> CGRect {
            let a = layout.contentNormalized(forScene: CGPoint(x: r.minX, y: r.minY))
            let b = layout.contentNormalized(forScene: CGPoint(x: r.maxX, y: r.maxY))
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }
        _ = canvas
        if mode == .crop {
            document.edit([.render]) { $0.crop = VideoProjectLimits.normalizedRect(rect) }
            return
        }
        switch document.selection {
        case .zoom(let id)?:
            document.edit([.render, .segments]) { project in
                guard let z = project.zooms.first(where: { $0.id == id }) else { return }
                let side = max(rect.width, rect.height, 0.0001)
                z.zoomLevel = min(VideoZoomSegment.maxZoom, max(VideoZoomSegment.minZoom, 1 / side))
                let f = CameraState.clampedFocus(CGPoint(x: rect.midX, y: rect.midY), zoom: z.zoomLevel)
                let c = layout.contentNormalized(forScene: f)
                z.center = CGPoint(x: min(1, max(0, c.x)), y: min(1, max(0, c.y)))
                // Moving the frame means "look here": pin it.
                if moved { z.followsCursor = false; z.isAutomatic = false }
            }
        case .censor(let id)?:
            document.edit([.render]) { project in
                project.censors.first { $0.id == id }?.rect = VideoCensorSegment.clampedRect(contentRect(rect))
            }
        case .text(let id)?:
            document.edit([.render]) { project in
                project.texts.first { $0.id == id }?.rect = VideoTextSegment.clampedRect(contentRect(rect))
            }
        default:
            break
        }
    }

    // MARK: Inline text editing

    func beginTextEditing(id: UUID) {
        endTextEditing(commit: true)
        guard let segment = document.project.texts.first(where: { $0.id == id }),
              let (rect, _, _) = currentRect(), let layout else { return }
        let frame = viewRect(normalized: rect)
        let displayedVideoHeight = canvasRect.height * (layout.videoRect.height / max(layout.crop.height, 0.01))
            / layout.canvasSize.height
        let fontSize = max(8, min(segment.fontSize * displayedVideoHeight / 1080, frame.height * 0.78))
        let font = VideoTextRasterizer.font(family: segment.fontFamily, size: fontSize, bold: segment.bold, italic: segment.italic)
        let paragraph = NSMutableParagraphStyle()
        switch segment.alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        let color = NSColor(srgbRed: segment.textColor.r, green: segment.textColor.g, blue: segment.textColor.b,
                            alpha: segment.textColor.a)
        let scroll = NSScrollView(frame: frame)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.borderColor = VideoEditorStyle.text.cgColor
        scroll.layer?.borderWidth = 1.5
        scroll.layer?.cornerRadius = 4
        scroll.contentView.drawsBackground = false
        let textView = InlineVideoTextView(frame: NSRect(origin: .zero, size: frame.size))
        textView.isRichText = false
        textView.allowsUndo = true
        // Match the rendered box; without one, a translucent backing keeps
        // light text readable over any content while typing.
        textView.drawsBackground = true
        textView.backgroundColor = segment.bgStyle != .none
            ? NSColor(srgbRed: segment.bgColor.r, green: segment.bgColor.g, blue: segment.bgColor.b,
                      alpha: max(0.55, segment.bgColor.a))
            : NSColor(white: 0, alpha: 0.45)
        textView.font = font
        textView.textColor = color
        textView.alignment = paragraph.alignment
        textView.insertionPointColor = VideoEditorStyle.text
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        textView.string = segment.text
        textView.horizontalTextInset = max(2, fontSize * 0.18)
        textView.onCommit = { [weak self] in self?.endTextEditing(commit: true) }
        textView.onCancel = { [weak self] in self?.endTextEditing(commit: false) }
        textView.selectAll(nil)
        scroll.documentView = textView
        addSubview(scroll)
        textEditor = textView
        textEditorScroll = scroll
        editingTextID = id
        if var options = stageOptions {
            options.hiddenTextID = id
            setStageOptions(options)
        }
        window?.makeFirstResponder(textView)
    }

    private var stageOptions: VideoRenderPlanner.Options? { stagePlayback?.options }
    private var stagePlayback: VideoEditorPlayback? { (window?.windowController as? VideoEditorWindowController)?.playback }
    private func setStageOptions(_ options: VideoRenderPlanner.Options) { stagePlayback?.options = options }

    func endTextEditing(commit: Bool) {
        guard let id = editingTextID, let textView = textEditor else { return }
        let text = textView.string
        editingTextID = nil
        textView.discardUndoHistory()
        textEditorScroll?.removeFromSuperview()
        textEditor = nil
        textEditorScroll = nil
        if var options = stageOptions {
            options.hiddenTextID = nil
            setStageOptions(options)
        }
        if commit, document.project.texts.first(where: { $0.id == id })?.text != text {
            document.edit([.render, .segments]) { project in
                project.texts.first { $0.id == id }?.text = text
            }
        }
        window?.makeFirstResponder(window?.contentView)
    }
}

/// Inline editor for text overlays. Return commits (Shift-Return inserts a
/// newline), Escape cancels.
final class InlineVideoTextView: ScopedUndoTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var horizontalTextInset: CGFloat = 0 { didSet { centerTextVertically() } }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        centerTextVertically()
    }

    override func didChangeText() {
        super.didChangeText()
        centerTextVertically()
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)), !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) {
            onCommit?()
            return
        }
        if selector == #selector(cancelOperation(_:)) {
            onCancel?()
            return
        }
        super.doCommand(by: selector)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.onCommit?() } }
        return result
    }

    func centerTextVertically() {
        guard let container = textContainer, let manager = layoutManager else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        textContainerInset = NSSize(width: horizontalTextInset, height: max(0, floor((bounds.height - used) / 2)))
    }
}
