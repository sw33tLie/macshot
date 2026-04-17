import Cocoa
import AVFoundation

/// Popover for editing a `VideoZoomSegment` — mini thumbnail with a draggable
/// zoom-center crosshair plus an in-thumbnail 3x3 snap grid, zoom-level slider,
/// and delete. The caller supplies callbacks for live updates and deletion.
@MainActor
final class VideoZoomSegmentPopoverController: NSViewController {

    private let segment: VideoZoomSegment
    private let thumbnail: NSImage
    private let onChange: () -> Void
    private let onDelete: () -> Void

    private var pickerView: ZoomCenterPickerView!
    private var zoomSlider: NSSlider!
    private var zoomLabel: NSTextField!

    init(segment: VideoZoomSegment, thumbnail: NSImage, onChange: @escaping () -> Void, onDelete: @escaping () -> Void) {
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
        let sliderH: CGFloat = 26
        let footerH: CGFloat = 32
        let pad: CGFloat = 12
        let contentW: CGFloat = thumbW + pad * 2
        let contentH: CGFloat = pad + thumbH + pad + sliderH + pad + footerH + pad

        let root = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))
        root.appearance = NSAppearance(named: .darkAqua)

        // Thumbnail + crosshair + 3x3 snap grid overlay
        let picker = ZoomCenterPickerView(frame: NSRect(
            x: pad,
            y: contentH - pad - thumbH,
            width: thumbW, height: thumbH
        ))
        picker.image = thumbnail
        picker.center = segment.center
        picker.onChange = { [weak self] newCenter in
            guard let self = self else { return }
            self.segment.center = newCenter
            self.onChange()
        }
        root.addSubview(picker)
        self.pickerView = picker

        // Zoom slider + readout
        let sliderContainer = NSView(frame: NSRect(
            x: pad,
            y: picker.frame.minY - pad - sliderH,
            width: thumbW, height: sliderH
        ))
        root.addSubview(sliderContainer)

        let zoomIcon = NSImageView(frame: NSRect(x: 0, y: (sliderH - 14) / 2, width: 14, height: 14))
        zoomIcon.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil)
        zoomIcon.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        sliderContainer.addSubview(zoomIcon)

        let slider = NSSlider(value: Double(segment.zoomLevel),
                              minValue: Double(VideoZoomSegment.minZoom),
                              maxValue: Double(VideoZoomSegment.maxZoom),
                              target: self, action: #selector(sliderChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 20, y: 3, width: thumbW - 20 - 48, height: sliderH - 6)
        sliderContainer.addSubview(slider)
        self.zoomSlider = slider

        let label = NSTextField(labelWithString: formatZoom(segment.zoomLevel))
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.frame = NSRect(x: thumbW - 44, y: 2, width: 44, height: sliderH - 4)
        label.alignment = .right
        sliderContainer.addSubview(label)
        self.zoomLabel = label

        // Footer: hint on the left, delete on the right
        let footer = NSView(frame: NSRect(
            x: pad,
            y: sliderContainer.frame.minY - pad - footerH,
            width: thumbW, height: footerH
        ))
        root.addSubview(footer)

        let delBtn = NSButton(title: L("Delete zoom"),
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

        let hint = NSTextField(labelWithString: L("Click a zone or drag to set zoom center"))
        hint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        hint.textColor = NSColor.white.withAlphaComponent(0.5)
        hint.frame = NSRect(x: 0, y: (footerH - 16) / 2, width: thumbW - dr.width - 8, height: 16)
        footer.addSubview(hint)

        self.view = root
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        segment.zoomLevel = CGFloat(sender.doubleValue)
        zoomLabel.stringValue = formatZoom(segment.zoomLevel)
        onChange()
    }

    @objc private func deleteClicked() {
        onDelete()
    }

    private func formatZoom(_ level: CGFloat) -> String {
        if abs(level.rounded() - level) < 0.01 {
            return "\(Int(level.rounded()))x"
        }
        return String(format: "%.1fx", level)
    }
}

// MARK: - Thumbnail view: crosshair + 3x3 snap grid overlay

private final class ZoomCenterPickerView: NSView {

    var image: NSImage?
    /// Normalized point (0..1) in image-local coords. (0,0) = top-left.
    var center: CGPoint = CGPoint(x: 0.5, y: 0.5) {
        didSet { needsDisplay = true }
    }
    var onChange: ((CGPoint) -> Void)?

    private var isDragging = false
    private var didDragDuringPress = false
    private var hoverCell: (Int, Int)? {  // (col, row)
        didSet { if oldValue.map({ "\($0)" }) != hoverCell.map({ "\($0)" }) { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let opts: NSTrackingArea.Options = [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        if let img = image {
            img.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            NSColor(white: 0.1, alpha: 1).setFill()
            NSBezierPath(rect: bounds).fill()
        }

        // Dim overlay so grid + crosshair stay legible
        NSColor.black.withAlphaComponent(0.18).setFill()
        NSBezierPath(rect: bounds).fill()

        // Highlighted cell (hover) — rendered behind grid lines
        if let cell = hoverCell {
            let (col, row) = cell
            let cellRect = gridCellRect(col: col, row: row)
            NSColor(calibratedRed: 0.25, green: 0.55, blue: 1.0, alpha: 0.22).setFill()
            NSBezierPath(rect: cellRect).fill()
            NSColor.white.withAlphaComponent(0.5).setStroke()
            let bp = NSBezierPath(rect: cellRect.insetBy(dx: 1, dy: 1))
            bp.lineWidth = 1
            bp.stroke()
        }

        // Rule-of-thirds grid
        NSColor.white.withAlphaComponent(0.22).setStroke()
        let gridPath = NSBezierPath()
        gridPath.lineWidth = 1
        for i in 1...2 {
            let x = bounds.minX + bounds.width * CGFloat(i) / 3
            gridPath.move(to: NSPoint(x: x, y: bounds.minY))
            gridPath.line(to: NSPoint(x: x, y: bounds.maxY))
            let y = bounds.minY + bounds.height * CGFloat(i) / 3
            gridPath.move(to: NSPoint(x: bounds.minX, y: y))
            gridPath.line(to: NSPoint(x: bounds.maxX, y: y))
        }
        gridPath.stroke()

        // Crosshair
        let cx = bounds.minX + center.x * bounds.width
        let cy = bounds.minY + (1 - center.y) * bounds.height

        NSColor.white.withAlphaComponent(0.7).setStroke()
        let axes = NSBezierPath()
        axes.lineWidth = 1
        axes.move(to: NSPoint(x: bounds.minX, y: cy))
        axes.line(to: NSPoint(x: bounds.maxX, y: cy))
        axes.move(to: NSPoint(x: cx, y: bounds.minY))
        axes.line(to: NSPoint(x: cx, y: bounds.maxY))
        axes.stroke()

        let ringR: CGFloat = 10
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let ringShadow = NSBezierPath(ovalIn: NSRect(x: cx - ringR - 0.5, y: cy - ringR - 0.5,
                                                      width: ringR * 2 + 1, height: ringR * 2 + 1))
        ringShadow.lineWidth = 2
        ringShadow.stroke()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: cx - ringR, y: cy - ringR,
                                                width: ringR * 2, height: ringR * 2))
        ring.lineWidth = 1.5
        ring.stroke()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - 2, y: cy - 2, width: 4, height: 4)).fill()
    }

    // MARK: - Mouse

    override func mouseEntered(with event: NSEvent) {
        updateHover(for: convert(event.locationInWindow, from: nil))
    }
    override func mouseMoved(with event: NSEvent) {
        updateHover(for: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        hoverCell = nil
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        didDragDuringPress = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        didDragDuringPress = true
        updateCenter(for: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { isDragging = false; didDragDuringPress = false }
        let p = convert(event.locationInWindow, from: nil)
        // Treat a press-without-drag as a "snap to clicked zone" click.
        if !didDragDuringPress, let (col, row) = cellAt(point: p) {
            let snap = CGPoint(x: (CGFloat(col) + 0.5) / 3.0,
                                y: (CGFloat(row) + 0.5) / 3.0)
            center = snap
            onChange?(center)
        }
    }

    // MARK: - Helpers

    private func updateHover(for point: NSPoint) {
        hoverCell = cellAt(point: point)
    }

    /// Returns the 3x3 cell that contains `point`, or nil if outside.
    /// Coordinates: col 0..2 = left..right, row 0..2 = TOP..BOTTOM
    /// (normalized image space; AppKit y flipped).
    private func cellAt(point: NSPoint) -> (Int, Int)? {
        guard bounds.contains(point) else { return nil }
        let nx = (point.x - bounds.minX) / bounds.width
        let nyFlipped = 1 - (point.y - bounds.minY) / bounds.height
        let col = min(2, max(0, Int(nx * 3)))
        let row = min(2, max(0, Int(nyFlipped * 3)))
        return (col, row)
    }

    private func gridCellRect(col: Int, row: Int) -> NSRect {
        let cellW = bounds.width / 3
        let cellH = bounds.height / 3
        // row 0 = top of image → y near bounds.maxY
        return NSRect(
            x: bounds.minX + CGFloat(col) * cellW,
            y: bounds.maxY - CGFloat(row + 1) * cellH,
            width: cellW, height: cellH
        )
    }

    private func updateCenter(for point: NSPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let nx = max(0.05, min(0.95, (point.x - bounds.minX) / bounds.width))
        let ny = max(0.05, min(0.95, 1 - (point.y - bounds.minY) / bounds.height))
        center = CGPoint(x: nx, y: ny)
        onChange?(center)
    }
}
