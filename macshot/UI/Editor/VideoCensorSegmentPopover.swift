import Cocoa

/// Popover for editing a `VideoCensorSegment` — mini thumbnail with a
/// draggable + resizable rectangle defining the censored region, a style
/// segmented control (Solid / Pixelate / Blur), and delete.
@MainActor
final class VideoCensorSegmentPopoverController: NSViewController {

    private let segment: VideoCensorSegment
    private let thumbnail: NSImage
    private let onChange: () -> Void
    private let onDelete: () -> Void

    private var pickerView: CensorRectPickerView!
    private var styleControl: NSSegmentedControl!

    init(segment: VideoCensorSegment, thumbnail: NSImage, onChange: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.segment = segment
        self.thumbnail = thumbnail
        self.onChange = onChange
        self.onDelete = onDelete
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let thumbAspect: CGFloat = {
            guard thumbnail.size.width > 0, thumbnail.size.height > 0 else { return 16.0 / 9.0 }
            return thumbnail.size.width / thumbnail.size.height
        }()
        let thumbW: CGFloat = 300
        let thumbH: CGFloat = round(thumbW / thumbAspect)
        let styleH: CGFloat = 28
        let footerH: CGFloat = 32
        let pad: CGFloat = 12
        let contentW = thumbW + pad * 2
        let contentH = pad + thumbH + pad + styleH + pad + footerH + pad

        let root = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))
        root.appearance = NSAppearance(named: .darkAqua)

        // Thumbnail + rect picker
        let picker = CensorRectPickerView(frame: NSRect(
            x: pad,
            y: contentH - pad - thumbH,
            width: thumbW, height: thumbH
        ))
        picker.image = thumbnail
        picker.normalizedRect = segment.rect
        picker.onChange = { [weak self] newRect in
            guard let self = self else { return }
            self.segment.rect = VideoCensorSegment.clampedRect(newRect)
            self.onChange()
        }
        root.addSubview(picker)
        self.pickerView = picker

        // Style segmented control
        let styleWrap = NSView(frame: NSRect(
            x: pad,
            y: picker.frame.minY - pad - styleH,
            width: thumbW, height: styleH
        ))
        root.addSubview(styleWrap)

        let control = NSSegmentedControl(labels: [L("Solid"), L("Pixelate"), L("Blur")],
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(styleChanged(_:)))
        control.controlSize = .regular
        control.segmentStyle = .texturedSquare
        switch segment.style {
        case .solid:    control.selectedSegment = 0
        case .pixelate: control.selectedSegment = 1
        case .blur:     control.selectedSegment = 2
        }
        control.frame = NSRect(x: 0, y: 0, width: thumbW, height: styleH)
        styleWrap.addSubview(control)
        self.styleControl = control

        // Footer: hint + delete
        let footer = NSView(frame: NSRect(
            x: pad,
            y: styleWrap.frame.minY - pad - footerH,
            width: thumbW, height: footerH
        ))
        root.addSubview(footer)

        let delBtn = NSButton(title: L("Delete"),
                              target: self, action: #selector(deleteClicked))
        delBtn.bezelStyle = .rounded
        delBtn.controlSize = .small
        delBtn.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        delBtn.imagePosition = .imageLeading
        delBtn.sizeToFit()
        var dr = delBtn.frame
        dr.origin = NSPoint(x: thumbW - dr.width, y: (footerH - dr.height) / 2)
        delBtn.frame = dr
        footer.addSubview(delBtn)

        let hint = NSTextField(labelWithString: L("Drag on the preview to set the censored region"))
        hint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        hint.textColor = NSColor.white.withAlphaComponent(0.5)
        hint.frame = NSRect(x: 0, y: (footerH - 16) / 2, width: thumbW - dr.width - 8, height: 16)
        footer.addSubview(hint)

        self.view = root
    }

    @objc private func styleChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: segment.style = .solid
        case 1: segment.style = .pixelate
        default: segment.style = .blur
        }
        onChange()
    }

    @objc private func deleteClicked() {
        onDelete()
    }
}

// MARK: - Rect picker

/// Thumbnail view with a draggable/resizable rectangle overlaid. Rectangle is
/// stored in normalized image coords (origin top-left, y=0 at top).
private final class CensorRectPickerView: NSView {

    var image: NSImage?
    var normalizedRect: CGRect = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3) {
        didSet { needsDisplay = true }
    }
    var onChange: ((CGRect) -> Void)?

    private enum DragMode {
        case createNew(anchor: NSPoint)
        case moveBody(grabOffset: NSPoint)  // offset from rect origin to grab point
        case resize(corner: Corner)
    }
    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right }

    private var dragMode: DragMode?
    private var rectAtDragStart: CGRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if let img = image {
            img.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            NSColor(white: 0.12, alpha: 1).setFill()
            NSBezierPath(rect: bounds).fill()
        }
        // Slight dim so the rectangle reads
        NSColor.black.withAlphaComponent(0.18).setFill()
        NSBezierPath(rect: bounds).fill()

        let rectInView = viewRect(from: normalizedRect)
        if rectInView.width > 1 && rectInView.height > 1 {
            // Fill the rect area with a distinct tint so users see what's covered
            NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.35, alpha: 0.3).setFill()
            NSBezierPath(rect: rectInView).fill()

            // Outer border
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: rectInView.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1.5
            border.stroke()

            // 8 resize handles
            let handleR: CGFloat = 3
            let handlePositions: [NSPoint] = [
                NSPoint(x: rectInView.minX, y: rectInView.minY),
                NSPoint(x: rectInView.midX, y: rectInView.minY),
                NSPoint(x: rectInView.maxX, y: rectInView.minY),
                NSPoint(x: rectInView.maxX, y: rectInView.midY),
                NSPoint(x: rectInView.maxX, y: rectInView.maxY),
                NSPoint(x: rectInView.midX, y: rectInView.maxY),
                NSPoint(x: rectInView.minX, y: rectInView.maxY),
                NSPoint(x: rectInView.minX, y: rectInView.midY),
            ]
            NSColor.white.setFill()
            for p in handlePositions {
                NSBezierPath(ovalIn: NSRect(x: p.x - handleR, y: p.y - handleR,
                                             width: handleR * 2, height: handleR * 2)).fill()
            }
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        rectAtDragStart = normalizedRect
        let rectInView = viewRect(from: normalizedRect)

        // Hit-test against handles / edges / body; otherwise start a new rect
        if let corner = hitCorner(point: p, in: rectInView) {
            dragMode = .resize(corner: corner)
        } else if rectInView.contains(p) {
            dragMode = .moveBody(grabOffset: NSPoint(x: p.x - rectInView.minX, y: p.y - rectInView.minY))
        } else {
            dragMode = .createNew(anchor: p)
            // Collapse the rect to the anchor so drag begins as a new zero-area rect
            normalizedRect = normalize(CGRect(origin: p, size: .zero))
            onChange?(normalizedRect)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mode = dragMode else { return }
        let p = convert(event.locationInWindow, from: nil)
        let rectInView = viewRect(from: rectAtDragStart)

        var newRect: NSRect
        switch mode {
        case .createNew(let anchor):
            let minX = min(anchor.x, p.x)
            let minY = min(anchor.y, p.y)
            let w = abs(p.x - anchor.x)
            let h = abs(p.y - anchor.y)
            newRect = NSRect(x: minX, y: minY, width: w, height: h)

        case .moveBody(let grabOffset):
            var newX = p.x - grabOffset.x
            var newY = p.y - grabOffset.y
            newX = max(0, min(bounds.width - rectInView.width, newX))
            newY = max(0, min(bounds.height - rectInView.height, newY))
            newRect = NSRect(x: newX, y: newY, width: rectInView.width, height: rectInView.height)

        case .resize(let corner):
            newRect = resizedRect(from: rectInView, corner: corner, to: p)
        }
        normalizedRect = normalize(newRect)
        onChange?(normalizedRect)
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = nil
    }

    // MARK: - Hit testing

    private func hitCorner(point p: NSPoint, in rect: NSRect) -> Corner? {
        let edgeT: CGFloat = 8
        let nearLeft = abs(p.x - rect.minX) < edgeT
        let nearRight = abs(p.x - rect.maxX) < edgeT
        let nearTop = abs(p.y - rect.maxY) < edgeT
        let nearBottom = abs(p.y - rect.minY) < edgeT
        // Must be inside (or very near) the rect vertically for horizontal edges and vice versa
        let withinX = p.x >= rect.minX - edgeT && p.x <= rect.maxX + edgeT
        let withinY = p.y >= rect.minY - edgeT && p.y <= rect.maxY + edgeT
        if nearLeft && nearTop && withinX && withinY { return .topLeft }
        if nearRight && nearTop && withinX && withinY { return .topRight }
        if nearLeft && nearBottom && withinX && withinY { return .bottomLeft }
        if nearRight && nearBottom && withinX && withinY { return .bottomRight }
        if nearTop && withinX { return .top }
        if nearBottom && withinX { return .bottom }
        if nearLeft && withinY { return .left }
        if nearRight && withinY { return .right }
        return nil
    }

    private func resizedRect(from original: NSRect, corner: Corner, to p: NSPoint) -> NSRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        switch corner {
        case .topLeft:     minX = p.x; maxY = p.y
        case .top:         maxY = p.y
        case .topRight:    maxX = p.x; maxY = p.y
        case .right:       maxX = p.x
        case .bottomRight: maxX = p.x; minY = p.y
        case .bottom:      minY = p.y
        case .bottomLeft:  minX = p.x; minY = p.y
        case .left:        minX = p.x
        }
        // Normalize: swap if flipped (support dragging a handle past its opposite edge)
        let xLo = min(minX, maxX), xHi = max(minX, maxX)
        let yLo = min(minY, maxY), yHi = max(minY, maxY)
        return NSRect(x: xLo, y: yLo, width: xHi - xLo, height: yHi - yLo)
    }

    // MARK: - Coordinate conversions

    /// View-space rect (AppKit y-bottom) → normalized image rect (y-top).
    private func normalize(_ rect: NSRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        // Clamp into view first
        let clippedX = max(0, min(bounds.width, rect.minX))
        let clippedY = max(0, min(bounds.height, rect.minY))
        let clippedMaxX = max(0, min(bounds.width, rect.maxX))
        let clippedMaxY = max(0, min(bounds.height, rect.maxY))
        let w = max(0, clippedMaxX - clippedX)
        let h = max(0, clippedMaxY - clippedY)

        let nx = clippedX / bounds.width
        let ny = 1 - (clippedY + h) / bounds.height
        let nw = w / bounds.width
        let nh = h / bounds.height
        return CGRect(x: nx, y: ny, width: nw, height: nh)
    }

    /// Normalized image rect (y-top) → view-space rect (y-bottom).
    private func viewRect(from n: CGRect) -> NSRect {
        let x = n.origin.x * bounds.width
        let y = bounds.height - (n.origin.y + n.size.height) * bounds.height
        let w = n.size.width * bounds.width
        let h = n.size.height * bounds.height
        return NSRect(x: x, y: y, width: w, height: h)
    }
}
