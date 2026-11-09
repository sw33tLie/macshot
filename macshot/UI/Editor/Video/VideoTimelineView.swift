import AVFoundation
import AppKit

@MainActor
protocol VideoTimelineDelegate: AnyObject {
    func timeline(_ timeline: VideoTimelineView, seekTo sourceTime: Double)
    func timelineDidBeginScrub(_ timeline: VideoTimelineView)
    func timelineDidEndScrub(_ timeline: VideoTimelineView)
    func timeline(_ timeline: VideoTimelineView, add kind: VideoTimelineView.Lane, at time: Double)
    func timelineDidRequestTextEdit(_ timeline: VideoTimelineView, id: UUID)
    func timelineCurrentTime(_ timeline: VideoTimelineView) -> Double
}

/// Multi-lane editing timeline. Lanes: clip (thumbnails, waveform, trim,
/// cuts, speed), zoom, edits (cuts, speed, freezes), overlays (text, blur)
/// and captions. Times are source seconds; the playhead is a separate layer
/// so playback never redraws the lanes.
final class VideoTimelineView: NSView {
    enum Lane: Int, CaseIterable { case clip, zoom, edits, overlays, captions }

    struct Item {
        var selection: VideoSelection
        var lane: Lane
        var row: Int
        var start: Double
        var end: Double
        var title: String
        var subtitle: String?
        var color: NSColor
        var symbol: String?
        var isPoint = false
    }

    weak var delegate: VideoTimelineDelegate?
    private let document: VideoEditorDocument

    // Geometry
    static let leadingInset: CGFloat = 14
    static let trailingInset: CGFloat = 24
    static let rulerHeight: CGFloat = 26
    static let clipHeight: CGFloat = 58
    static let laneHeight: CGFloat = 30
    static let laneGap: CGFloat = 6
    /// Points per second; 0 means fit to the visible width.
    var pointsPerSecond: CGFloat = 0 { didSet { invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true } }
    var fitWidth: CGFloat = 800 { didSet { if pointsPerSecond == 0 { invalidateIntrinsicContentSize(); needsDisplay = true } } }

    private(set) var items: [Item] = []
    private var overlayRows = 1
    private var thumbnails: [(time: Double, image: CGImage)] = []
    private var thumbnailGenerator: AVAssetImageGenerator?
    private var thumbnailDensity = 0
    private var waveform: [Float] = []
    private var waveformTask: Task<Void, Never>?

    private let playheadLayer = CALayer()
    private let playheadKnob = CAShapeLayer()
    private let hoverLayer = CALayer()
    private var observerID: UUID?

    // Interaction
    private enum Drag {
        case scrub
        case trimStart, trimEnd
        /// Tracked by identity: items re-sort while dragging, so an index
        /// could start pointing at a different overlay mid-drag.
        case item(selection: VideoSelection, edge: Edge, grab: Double, originalStart: Double, originalEnd: Double)
    }
    enum Edge { case start, end, body }
    private var drag: Drag?
    private var hoverX: CGFloat?
    private var tracking: NSTrackingArea?

    init(document: VideoEditorDocument) {
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        playheadLayer.backgroundColor = NSColor.white.cgColor
        playheadLayer.zPosition = 10
        playheadLayer.shadowColor = NSColor.black.cgColor
        playheadLayer.shadowOpacity = 0.5
        playheadLayer.shadowRadius = 2
        playheadLayer.shadowOffset = .zero
        playheadKnob.fillColor = NSColor.white.cgColor
        playheadKnob.zPosition = 11
        hoverLayer.backgroundColor = NSColor(white: 1, alpha: 0.28).cgColor
        hoverLayer.zPosition = 9
        hoverLayer.isHidden = true
        layer?.addSublayer(hoverLayer)
        layer?.addSublayer(playheadLayer)
        layer?.addSublayer(playheadKnob)
        observerID = document.observe { [weak self] change in
            guard let self else { return }
            if change.contains(.segments) || change.contains(.timing) || change.contains(.render)
                || change.contains(.selection) {
                self.rebuildItems()
            }
        }
        rebuildItems()
        loadWaveform()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { waveformTask?.cancel() }

    func tearDown() {
        if let observerID { document.removeObserver(observerID) }
        thumbnailGenerator?.cancelAllCGImageGeneration()
        waveformTask?.cancel()
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Clicks act immediately even when the editor window is inactive.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Layout

    var effectivePointsPerSecond: CGFloat {
        if pointsPerSecond > 0 { return pointsPerSecond }
        let usable = max(100, fitWidth - Self.leadingInset - Self.trailingInset)
        return usable / CGFloat(max(document.duration, 0.1))
    }

    var fitPointsPerSecond: CGFloat {
        max(1, fitWidth - Self.leadingInset - Self.trailingInset) / CGFloat(max(document.duration, 0.1))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.leadingInset + CGFloat(document.duration) * effectivePointsPerSecond + Self.trailingInset,
               height: contentHeight)
    }

    var contentHeight: CGFloat {
        var h = Self.rulerHeight + 6 + Self.clipHeight + Self.laneGap
        h += (Self.laneHeight + Self.laneGap) * 2
        h += (Self.laneHeight + Self.laneGap) * CGFloat(overlayRows)
        if !document.project.captions.isEmpty { h += Self.laneHeight + Self.laneGap }
        return h + 8
    }

    func x(for time: Double) -> CGFloat { Self.leadingInset + CGFloat(time) * effectivePointsPerSecond }
    func time(for x: CGFloat) -> Double { Double((x - Self.leadingInset) / effectivePointsPerSecond) }

    /// Vertical span of a lane row.
    func laneRect(_ lane: Lane, row: Int = 0) -> NSRect {
        var y = Self.rulerHeight + 6
        let width = bounds.width
        if lane == .clip { return NSRect(x: 0, y: y, width: width, height: Self.clipHeight) }
        y += Self.clipHeight + Self.laneGap
        if lane == .zoom { return NSRect(x: 0, y: y, width: width, height: Self.laneHeight) }
        y += Self.laneHeight + Self.laneGap
        if lane == .edits { return NSRect(x: 0, y: y, width: width, height: Self.laneHeight) }
        y += Self.laneHeight + Self.laneGap
        if lane == .overlays { return NSRect(x: 0, y: y + CGFloat(row) * (Self.laneHeight + Self.laneGap),
                                             width: width, height: Self.laneHeight) }
        y += CGFloat(overlayRows) * (Self.laneHeight + Self.laneGap)
        return NSRect(x: 0, y: y, width: width, height: Self.laneHeight)
    }

    /// Lanes visible to the gutter, with their vertical rects.
    var laneLayout: [(Lane, NSRect)] {
        var result: [(Lane, NSRect)] = [(.clip, laneRect(.clip)), (.zoom, laneRect(.zoom)), (.edits, laneRect(.edits))]
        let first = laneRect(.overlays, row: 0), last = laneRect(.overlays, row: overlayRows - 1)
        result.append((.overlays, NSRect(x: 0, y: first.minY, width: first.width, height: last.maxY - first.minY)))
        if !document.project.captions.isEmpty { result.append((.captions, laneRect(.captions))) }
        return result
    }

    override func layout() {
        super.layout()
        updatePlayhead(time: delegate?.timelineCurrentTime(self) ?? 0)
        requestThumbnailsIfNeeded()
    }

    // MARK: Items

    func rebuildItems() {
        let p = document.project
        var result: [Item] = []
        for z in p.zooms {
            let mode = z.followsCursor ? L("Follow") : L("Fixed")
            result.append(Item(selection: .zoom(z.id), lane: .zoom, row: 0, start: z.startTime, end: z.endTime,
                               title: String(format: "%.1f×", z.zoomLevel), subtitle: z.isAutomatic ? L("Auto") : mode,
                               color: VideoEditorStyle.zoom, symbol: "plus.magnifyingglass"))
        }
        for c in p.cuts {
            result.append(Item(selection: .cut(c.id), lane: .edits, row: 0, start: c.startTime, end: c.endTime,
                               title: L("Cut"), color: VideoEditorStyle.cut, symbol: "scissors"))
        }
        for s in p.speeds {
            result.append(Item(selection: .speed(s.id), lane: .edits, row: 0, start: s.startTime, end: s.endTime,
                               title: Self.speedLabel(s.speedFactor), color: VideoEditorStyle.speed, symbol: "gauge.with.dots.needle.67percent"))
        }
        for f in p.freezes {
            result.append(Item(selection: .freeze(f.id), lane: .edits, row: 0, start: f.atTime,
                               end: f.atTime + f.holdDuration, title: String(format: "%.1fs", f.holdDuration),
                               color: VideoEditorStyle.freeze, symbol: "snowflake", isPoint: true))
        }
        // Overlays stack into rows when they overlap in time.
        var overlays: [Item] = p.texts.map { t in
            Item(selection: .text(t.id), lane: .overlays, row: 0, start: t.startTime, end: t.endTime,
                 title: t.text.isEmpty ? L("Text") : t.text.replacingOccurrences(of: "\n", with: " "),
                 color: VideoEditorStyle.text, symbol: "textformat")
        }
        overlays += p.censors.map { c in
            let label: String
            switch c.style {
            case .blur: label = L("Blur")
            case .pixelate: label = L("Pixelate")
            case .solid: label = L("Solid")
            }
            return Item(selection: .censor(c.id), lane: .overlays, row: 0, start: c.startTime, end: c.endTime,
                        title: label, color: VideoEditorStyle.censor, symbol: "eye.slash")
        }
        overlays.sort { $0.start < $1.start }
        var rowEnds: [Double] = []
        for i in overlays.indices {
            if let row = rowEnds.firstIndex(where: { $0 <= overlays[i].start + 0.0001 }) {
                overlays[i].row = row
                rowEnds[row] = overlays[i].end
            } else {
                overlays[i].row = rowEnds.count
                rowEnds.append(overlays[i].end)
            }
        }
        result += overlays
        for c in p.captions {
            result.append(Item(selection: .caption(c.id), lane: .captions, row: 0, start: c.startTime, end: c.endTime,
                               title: c.text, color: VideoEditorStyle.caption, symbol: nil))
        }
        let rows = max(1, rowEnds.count)
        let heightChanged = rows != overlayRows
        overlayRows = rows
        items = result
        if heightChanged { invalidateIntrinsicContentSize() }
        invalidateIntrinsicContentSize()
        needsDisplay = true
        onLayoutChange?()
    }

    /// Fired when lane geometry may have changed (for the gutter).
    var onLayoutChange: (() -> Void)?

    static func speedLabel(_ factor: Double) -> String {
        factor >= 1 ? String(format: factor.rounded() == factor ? "%.0f×" : "%.1f×", factor)
            : String(format: "%.2g×", factor)
    }

    func itemRect(_ item: Item) -> NSRect {
        let lane = laneRect(item.lane, row: item.row)
        if item.isPoint {
            let x = x(for: item.start)
            let width = max(22, CGFloat(item.end - item.start) * effectivePointsPerSecond)
            return NSRect(x: x - 1, y: lane.minY + 2, width: width, height: lane.height - 4)
        }
        let x0 = x(for: item.start), x1 = x(for: item.end)
        return NSRect(x: x0, y: lane.minY + 2, width: max(6, x1 - x0), height: lane.height - 4)
    }

    // MARK: Playhead

    func updatePlayhead(time: Double) {
        let x = round(x(for: time)) + 0.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadLayer.frame = CGRect(x: x - 1, y: 12, width: 2, height: bounds.height - 12)
        let knob = CGMutablePath()
        let top: CGFloat = 4
        knob.move(to: CGPoint(x: x - 6, y: top))
        knob.addLine(to: CGPoint(x: x + 6, y: top))
        knob.addLine(to: CGPoint(x: x + 6, y: top + 8))
        knob.addLine(to: CGPoint(x: x, y: top + 14))
        knob.addLine(to: CGPoint(x: x - 6, y: top + 8))
        knob.closeSubpath()
        playheadKnob.path = knob
        playheadKnob.frame = bounds
        CATransaction.commit()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        VideoEditorStyle.panel.setFill()
        dirtyRect.fill()
        drawRuler(dirtyRect)
        drawLaneBackgrounds(dirtyRect)
        drawClip(dirtyRect)
        let selection = document.selection
        for item in items {
            let rect = itemRect(item)
            guard rect.intersects(dirtyRect.insetBy(dx: -8, dy: -2)) else { continue }
            drawItem(item, rect: rect, selected: item.selection == selection)
        }
    }

    private func drawRuler(_ dirty: NSRect) {
        let ruler = NSRect(x: dirty.minX, y: 0, width: dirty.width, height: Self.rulerHeight)
        guard ruler.intersects(dirty) else { return }
        let pps = effectivePointsPerSecond
        // Pick a label step that keeps labels ~90pt apart.
        let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let step = steps.first { CGFloat($0) * pps >= 80 } ?? 3600
        let minor = step / 5
        let first = max(0, Int(floor(time(for: dirty.minX) / minor)))
        let last = Int(ceil(min(document.duration, time(for: dirty.maxX) + minor) / minor))
        let attrs: [NSAttributedString.Key: Any] = [.font: VideoEditorStyle.mono(10, .medium),
                                                    .foregroundColor: VideoEditorStyle.textTertiary]
        let path = NSBezierPath()
        let minorPerMajor = 5
        guard first <= last else { return }
        for index in first...last {
            let t = Double(index) * minor
            guard t <= document.duration + 0.0001 else { break }
            let x = round(x(for: t)) + 0.5
            let isMajor = index % minorPerMajor == 0
            path.move(to: NSPoint(x: x, y: Self.rulerHeight - (isMajor ? 8 : 4)))
            path.line(to: NSPoint(x: x, y: Self.rulerHeight))
            if isMajor {
                let label = Self.formatRuler(t + 0.0005, step: step) as NSString
                let width = label.size(withAttributes: attrs).width
                // The end label would clip past the view edge; put it left of its tick.
                let labelX = x + 4 + width > bounds.maxX - 2 ? x - 4 - width : x + 4
                label.draw(at: NSPoint(x: labelX, y: 4), withAttributes: attrs)
            }
        }
        NSColor(white: 1, alpha: 0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    static func formatRuler(_ t: Double, step: Double) -> String {
        let total = Int(t.rounded(.down))
        let m = total / 60, s = total % 60
        if step < 1 { return String(format: "%d:%02d.%d", m, s, Int(((t - Double(total)) * 10).rounded(.down))) }
        if m >= 60 { return String(format: "%d:%02d:%02d", m / 60, m % 60, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func drawLaneBackgrounds(_ dirty: NSRect) {
        let content = NSRect(x: x(for: 0), y: 0, width: CGFloat(document.duration) * effectivePointsPerSecond, height: 0)
        for (lane, rect) in laneLayout where lane != .clip {
            let r = NSRect(x: content.minX, y: rect.minY, width: content.width, height: rect.height)
            guard r.intersects(dirty) else { continue }
            NSColor(white: 1, alpha: 0.028).setFill()
            NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
        }
        // Hint for empty lanes.
        let hints: [(Lane, String)] = [(.zoom, document.hasPointerData ? L("Double-click to add a zoom, or use Auto Zoom")
                                                                         : L("Double-click to add a zoom")),
                                       (.edits, L("Cuts, speed and freeze frames")),
                                       (.overlays, L("Text and blur"))]
        let attrs: [NSAttributedString.Key: Any] = [.font: VideoEditorStyle.font(10.5), .foregroundColor: VideoEditorStyle.textTertiary]
        for (lane, hint) in hints where !items.contains(where: { $0.lane == lane }) {
            let rect = laneRect(lane)
            guard rect.intersects(dirty) else { continue }
            (hint as NSString).draw(at: NSPoint(x: content.minX + 10, y: rect.midY - 7), withAttributes: attrs)
        }
    }

    private func drawClip(_ dirty: NSRect) {
        let lane = laneRect(.clip)
        guard lane.intersects(dirty) else { return }
        let x0 = x(for: 0), x1 = x(for: document.duration)
        let clip = NSRect(x: x0, y: lane.minY, width: x1 - x0, height: lane.height)
        let path = NSBezierPath(roundedRect: clip, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor(white: 0.16, alpha: 1).setFill()
        clip.fill()
        drawThumbnails(in: clip, dirty: dirty)
        drawWaveform(in: clip, dirty: dirty)
        let p = document.project
        // Speed regions and cuts over the thumbnails.
        for s in p.speeds {
            let r = NSRect(x: x(for: s.startTime), y: clip.minY, width: x(for: s.endTime) - x(for: s.startTime), height: clip.height)
            VideoEditorStyle.speed.withAlphaComponent(0.22).setFill()
            r.fill(using: .sourceOver)
        }
        for c in p.cuts {
            let r = NSRect(x: x(for: c.startTime), y: clip.minY, width: max(1, x(for: c.endTime) - x(for: c.startTime)),
                           height: clip.height)
            NSColor(white: 0, alpha: 0.62).setFill()
            r.fill(using: .sourceOver)
            Self.hatch(r, color: VideoEditorStyle.cut.withAlphaComponent(0.55))
        }
        // Outside the trim: dimmed.
        NSColor(white: 0, alpha: 0.64).setFill()
        let trimStartX = x(for: p.trimStart), trimEndX = x(for: p.trimEnd)
        if trimStartX > clip.minX { NSRect(x: clip.minX, y: clip.minY, width: trimStartX - clip.minX, height: clip.height).fill(using: .sourceOver) }
        if trimEndX < clip.maxX { NSRect(x: trimEndX, y: clip.minY, width: clip.maxX - trimEndX, height: clip.height).fill(using: .sourceOver) }
        NSGraphicsContext.restoreGraphicsState()

        // Trim frame with handles.
        let trim = NSRect(x: trimStartX, y: clip.minY, width: trimEndX - trimStartX, height: clip.height)
        let accent = VideoEditorStyle.accent
        let frame = NSBezierPath(roundedRect: trim.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        frame.lineWidth = 2
        accent.setStroke()
        frame.stroke()
        for edgeX in [trimStartX, trimEndX] {
            let handle = NSRect(x: edgeX - (edgeX == trimStartX ? 0 : 10), y: clip.minY, width: 10, height: clip.height)
            let handlePath = NSBezierPath(roundedRect: handle, xRadius: 4, yRadius: 4)
            accent.setFill()
            handlePath.fill()
            NSColor(white: 1, alpha: 0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: handle.midX - 1, y: handle.midY - 8, width: 2, height: 16), xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawThumbnails(in clip: NSRect, dirty: NSRect) {
        guard !thumbnails.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let aspect = document.contentSize.width / max(document.contentSize.height, 1)
        let thumbHeight = clip.height
        let thumbWidth = max(20, thumbHeight * aspect)
        var x = clip.minX + floor((max(dirty.minX, clip.minX) - clip.minX) / thumbWidth) * thumbWidth
        context.saveGState()
        context.interpolationQuality = .medium
        while x < min(dirty.maxX, clip.maxX) {
            let t = time(for: x + thumbWidth / 2)
            if let image = nearestThumbnail(to: t) {
                // Flipped view: draw with a local flip so images stay upright.
                let rect = CGRect(x: x, y: clip.minY, width: thumbWidth, height: thumbHeight)
                context.saveGState()
                context.translateBy(x: 0, y: rect.maxY + rect.minY)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: rect)
                context.restoreGState()
            }
            x += thumbWidth
        }
        context.restoreGState()
        // Soften thumbnails so chips and handles read clearly.
        NSColor(white: 0, alpha: 0.18).setFill()
        clip.fill(using: .sourceOver)
    }

    private func nearestThumbnail(to t: Double) -> CGImage? {
        guard !thumbnails.isEmpty else { return nil }
        var lo = 0, hi = thumbnails.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if thumbnails[mid].time < t { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(thumbnails[lo - 1].time - t) < abs(thumbnails[lo].time - t) { return thumbnails[lo - 1].image }
        return thumbnails[lo].image
    }

    private func drawWaveform(in clip: NSRect, dirty: NSRect) {
        guard !waveform.isEmpty, !document.project.muted else { return }
        let height: CGFloat = 16
        let baseline = clip.maxY - 3
        let startX = max(dirty.minX, clip.minX), endX = min(dirty.maxX, clip.maxX)
        guard endX > startX else { return }
        let path = NSBezierPath()
        let buckets = waveform.count
        var x = startX
        path.move(to: NSPoint(x: x, y: baseline))
        while x <= endX {
            let t = time(for: x) / max(document.duration, 0.001)
            let i = min(buckets - 1, max(0, Int(t * Double(buckets))))
            path.line(to: NSPoint(x: x, y: baseline - CGFloat(waveform[i]) * height))
            x += 1.5
        }
        path.line(to: NSPoint(x: endX, y: baseline))
        path.close()
        NSColor(white: 1, alpha: 0.38).setFill()
        path.fill()
    }

    static func hatch(_ rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        color.setStroke()
        let stripes = NSBezierPath()
        stripes.lineWidth = 1.5
        var x = rect.minX - rect.height
        while x < rect.maxX {
            stripes.move(to: NSPoint(x: x, y: rect.maxY))
            stripes.line(to: NSPoint(x: x + rect.height, y: rect.minY))
            x += 7
        }
        stripes.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawItem(_ item: Item, rect: NSRect, selected: Bool) {
        let radius: CGFloat = 6
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let base = item.color
        (selected ? base.withAlphaComponent(0.92) : base.withAlphaComponent(0.34)).setFill()
        path.fill()
        if item.selection == .cut(item.selection.id), case .cut = item.selection {
            Self.hatch(rect.insetBy(dx: 2, dy: 2), color: NSColor(white: 1, alpha: 0.18))
        }
        (selected ? NSColor.white.withAlphaComponent(0.9) : base.withAlphaComponent(0.85)).setStroke()
        path.lineWidth = selected ? 1.5 : 1
        let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        inner.lineWidth = path.lineWidth
        inner.stroke()

        // Label.
        let textColor = selected ? NSColor.white : NSColor.white.withAlphaComponent(0.9)
        // Keep the label visible when the chip starts left of the viewport.
        var x = max(rect.minX, min(visibleRect.minX, rect.maxX - 60)) + 7
        if let symbol = item.symbol, rect.width > 30, let image = VideoEditorStyle.symbol(symbol, size: 10, weight: .semibold) {
            let tinted = image.tinted(textColor)
            let size = tinted.size
            tinted.draw(in: NSRect(x: x, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            x += size.width + 4
        }
        let available = rect.maxX - x - 6
        guard available > 12 else { return }
        let title = NSMutableAttributedString(string: item.title, attributes: [
            .font: VideoEditorStyle.font(11, .semibold), .foregroundColor: textColor,
        ])
        if let subtitle = item.subtitle {
            title.append(NSAttributedString(string: "  " + subtitle, attributes: [
                .font: VideoEditorStyle.font(10, .medium), .foregroundColor: textColor.withAlphaComponent(0.7),
            ]))
        }
        let size = title.size()
        title.draw(with: NSRect(x: x, y: rect.midY - size.height / 2, width: available, height: size.height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        if selected && !item.isPoint {
            for edgeX in [rect.minX + 3, rect.maxX - 5] {
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: edgeX, y: rect.midY - 6, width: 2, height: 12), xRadius: 1, yRadius: 1).fill()
            }
        }
    }

    // MARK: Thumbnails and waveform

    func requestThumbnailsIfNeeded() {
        guard document.duration > 0 else { return }
        let aspect = document.contentSize.width / max(document.contentSize.height, 1)
        let thumbWidth = max(20, Self.clipHeight * aspect)
        let width = CGFloat(document.duration) * effectivePointsPerSecond
        let needed = min(400, max(4, Int(ceil(width / thumbWidth)) + 1))
        guard needed > thumbnailDensity * 3 / 2 || thumbnailDensity == 0 else { return }
        thumbnailDensity = needed
        thumbnailGenerator?.cancelAllCGImageGeneration()
        let generator = AVAssetImageGenerator(asset: document.asset)
        generator.appliesPreferredTrackTransform = true
        let scale = window?.backingScaleFactor ?? 2
        generator.maximumSize = CGSize(width: thumbWidth * scale, height: Self.clipHeight * scale)
        let tolerance = CMTime(seconds: max(0.05, document.duration / Double(needed) / 2), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        thumbnailGenerator = generator
        let times = (0..<needed).map { i in
            NSValue(time: CMTime(seconds: document.duration * (Double(i) + 0.5) / Double(needed), preferredTimescale: 600))
        }
        let lease = document.source.lease
        let collector = TimelineThumbnailCollector(count: needed)
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self] requested, image, _, _, _ in
            withExtendedLifetime(lease) {}
            guard let image else { return }
            let t = requested.seconds
            let batch = collector.add(time: t, image: image)
            DispatchQueue.main.async {
                guard let self, self.thumbnailGenerator === generator, let batch else { return }
                self.thumbnails = batch
                self.needsDisplay = true
            }
        }
    }

    private func loadWaveform() {
        let asset = document.asset
        let duration = document.duration
        let lease = document.source.lease
        let reader = WaveformInput(asset: asset)
        waveformTask = Task { [weak self] in
            let peaks = await Task.detached(priority: .utility) {
                defer { withExtendedLifetime(lease) {} }
                return VideoWaveform.peaks(asset: reader.asset, duration: duration, buckets: 2400)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.waveform = peaks
            self.needsDisplay = true
        }
    }

    // MARK: Hit testing

    private func hitItem(at p: NSPoint) -> (Int, Edge)? {
        let selection = document.selection
        // Selected item first so its handles win over neighbors.
        let order = items.indices.sorted { a, b in (items[a].selection == selection ? 0 : 1) < (items[b].selection == selection ? 0 : 1) }
        for i in order {
            let rect = itemRect(items[i])
            guard rect.insetBy(dx: -4, dy: 0).contains(p) else { continue }
            if items[i].isPoint { return (i, .body) }
            if abs(p.x - rect.minX) <= 6 { return (i, .start) }
            if abs(p.x - rect.maxX) <= 6 { return (i, .end) }
            if rect.contains(p) { return (i, .body) }
        }
        return nil
    }

    private func lane(at p: NSPoint) -> Lane? {
        for (lane, rect) in laneLayout where rect.contains(NSPoint(x: rect.midX, y: p.y)) { return lane }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        showHover(at: p.x)
        updateCursor(at: p)
    }

    override func mouseExited(with event: NSEvent) {
        hoverLayer.isHidden = true
        NSCursor.arrow.set()
    }

    private func showHover(at x: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer.isHidden = x < self.x(for: 0) || x > self.x(for: document.duration)
        hoverLayer.frame = CGRect(x: round(x), y: 0, width: 1, height: bounds.height)
        CATransaction.commit()
    }

    private func updateCursor(at p: NSPoint) {
        let clip = laneRect(.clip)
        if clip.contains(p) {
            let s = x(for: document.project.trimStart), e = x(for: document.project.trimEnd)
            if abs(p.x - s) < 8 || abs(p.x - e) < 8 { NSCursor.resizeLeftRight.set(); return }
        }
        if let (_, edge) = hitItem(at: p), edge != .body { NSCursor.resizeLeftRight.set(); return }
        if hitItem(at: p) != nil { NSCursor.openHand.set(); return }
        NSCursor.arrow.set()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let project = document.project
        if event.clickCount == 2 {
            if let (index, _) = hitItem(at: p) {
                if case .text(let id) = items[index].selection { delegate?.timelineDidRequestTextEdit(self, id: id) }
                return
            }
            if let lane = lane(at: p), lane != .clip, lane != .captions {
                delegate?.timeline(self, add: lane, at: clampTime(time(for: p.x)))
            }
            return
        }
        // Trim handles.
        let clip = laneRect(.clip)
        if clip.insetBy(dx: 0, dy: -4).contains(p) {
            let s = x(for: project.trimStart), e = x(for: project.trimEnd)
            if abs(p.x - e) < 9 { beginDrag(.trimEnd); return }
            if abs(p.x - s) < 9 { beginDrag(.trimStart); return }
        }
        if let (index, edge) = hitItem(at: p) {
            let item = items[index]
            document.select(item.selection)
            beginDrag(.item(selection: item.selection, edge: edge, grab: time(for: p.x) - item.start,
                            originalStart: item.start, originalEnd: item.end))
            if edge == .body { NSCursor.closedHand.set() }
            return
        }
        document.select(nil)
        beginDrag(.scrub)
        delegate?.timeline(self, seekTo: clampTime(time(for: p.x)))
    }

    private func beginDrag(_ newDrag: Drag) {
        drag = newDrag
        switch newDrag {
        case .scrub: delegate?.timelineDidBeginScrub(self)
        default: document.beginGesture()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        showHover(at: p.x)
        let t = clampTime(time(for: p.x))
        guard let drag else { return }
        switch drag {
        case .scrub:
            delegate?.timeline(self, seekTo: t)
        case .trimStart:
            let snapped = snap(t, excluding: nil)
            document.edit([.timing, .render]) { project in
                project.trimStart = min(max(0, snapped), project.trimEnd - 0.1)
            }
            delegate?.timeline(self, seekTo: document.project.trimStart)
        case .trimEnd:
            let snapped = snap(t, excluding: nil)
            document.edit([.timing, .render]) { project in
                project.trimEnd = max(min(document.duration, snapped), project.trimStart + 0.1)
            }
            delegate?.timeline(self, seekTo: document.project.trimEnd)
        case let .item(selection, edge, grab, originalStart, originalEnd):
            var start = originalStart, end = originalEnd
            switch edge {
            case .body:
                let length = originalEnd - originalStart
                start = snap(t - grab, excluding: selection)
                let snappedEnd = snap(start + length, excluding: selection)
                if abs(snappedEnd - (start + length)) > 0.0001, abs(snappedEnd - (start + length)) < abs(start - (t - grab)) + 0.0001 {
                    start = snappedEnd - length
                }
                start = min(max(0, start), document.duration - length)
                end = start + length
            case .start:
                start = min(snap(t, excluding: selection), end - 0.2)
            case .end:
                end = max(snap(t, excluding: selection), start + 0.2)
            }
            apply(selection: selection, start: max(0, start), end: min(document.duration, end), edge: edge)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        self.drag = nil
        switch drag {
        case .scrub: delegate?.timelineDidEndScrub(self)
        default: document.endGesture()
        }
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func clampTime(_ t: Double) -> Double { min(max(0, t), document.duration) }

    /// Snaps to the playhead, trim edges and other item edges within 7 pt.
    private func snap(_ t: Double, excluding: VideoSelection?) -> Double {
        let threshold = Double(7 / effectivePointsPerSecond)
        var candidates = [delegate?.timelineCurrentTime(self) ?? -1, document.project.trimStart, document.project.trimEnd,
                          0, document.duration]
        for item in items where item.selection != excluding {
            candidates.append(item.start)
            candidates.append(item.end)
        }
        var best = t
        var bestDistance = threshold
        for c in candidates where abs(c - t) < bestDistance {
            best = c
            bestDistance = abs(c - t)
        }
        return best
    }

    /// Writes a dragged range back to the model, preventing overlaps where
    /// the renderer requires exclusivity (zooms, speeds).
    private func apply(selection: VideoSelection, start: Double, end: Double, edge: Edge) {
        document.edit([.segments, .render, .timing]) { project in
            switch selection {
            case .zoom(let id):
                guard let z = project.zooms.first(where: { $0.id == id }) else { return }
                let others = project.zooms.filter { $0.id != id }.map { ($0.startTime, $0.endTime) }
                let (s, e) = Self.resolve(start: start, end: end, edge: edge, others: others,
                                          fallback: (z.startTime, z.endTime))
                z.startTime = s; z.endTime = e
            case .speed(let id):
                guard let seg = project.speeds.first(where: { $0.id == id }) else { return }
                let others = project.speeds.filter { $0.id != id }.map { ($0.startTime, $0.endTime) }
                let (s, e) = Self.resolve(start: start, end: end, edge: edge, others: others,
                                          fallback: (seg.startTime, seg.endTime))
                seg.startTime = s; seg.endTime = e
            case .cut(let id):
                guard let seg = project.cuts.first(where: { $0.id == id }) else { return }
                seg.startTime = start; seg.endTime = end
            case .freeze(let id):
                guard let seg = project.freezes.first(where: { $0.id == id }) else { return }
                if edge == .body { seg.atTime = min(max(0, start), document.duration - 0.01) }
            case .censor(let id):
                guard let seg = project.censors.first(where: { $0.id == id }) else { return }
                seg.startTime = start; seg.endTime = end
            case .text(let id):
                guard let seg = project.texts.first(where: { $0.id == id }) else { return }
                seg.startTime = start; seg.endTime = end
            case .caption(let id):
                guard let i = project.captions.firstIndex(where: { $0.id == id }) else { return }
                project.captions[i].startTime = start; project.captions[i].endTime = end
            }
        }
    }

    /// Keeps a range from overlapping `others`: moves stop at neighbors,
    /// resizes stop at the nearest boundary.
    static func resolve(start: Double, end: Double, edge: Edge, others: [(Double, Double)],
                        fallback: (Double, Double)) -> (Double, Double) {
        let overlaps = { (s: Double, e: Double) in others.contains { $0.0 < e - 0.0001 && $0.1 > s + 0.0001 } }
        guard overlaps(start, end) else { return (start, end) }
        switch edge {
        case .start:
            let limit = others.filter { $0.1 <= fallback.1 + 0.0001 && $0.1 <= end }.map(\.1).filter { $0 <= end }.max() ?? start
            return (max(start, limit), end)
        case .end:
            let limit = others.filter { $0.0 >= fallback.0 - 0.0001 }.map(\.0).filter { $0 >= start }.min() ?? end
            return (start, min(end, limit))
        case .body:
            return fallback
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        if let (index, _) = hitItem(at: p) {
            document.select(items[index].selection)
            return (window?.windowController as? VideoEditorWindowController)?.menu(for: items[index].selection)
        }
        let t = clampTime(time(for: p.x))
        let menu = NSMenu()
        let entries: [(String, Lane, String)] = [
            (L("Add Zoom Here"), .zoom, "plus.magnifyingglass"),
            (L("Add Cut Here"), .edits, "scissors"),
            (L("Add Text Here"), .overlays, "textformat"),
        ]
        for (title, lane, symbol) in entries {
            let item = NSMenuItem(title: title, action: #selector(addFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.image = VideoEditorStyle.symbol(symbol, size: 12)
            item.representedObject = [lane.rawValue, t] as [Any]
            menu.addItem(item)
        }
        return menu
    }

    @objc private func addFromMenu(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [Any], let raw = values.first as? Int,
              let lane = Lane(rawValue: raw), let t = values.last as? Double else { return }
        delegate?.timeline(self, add: lane, at: t)
    }

    // MARK: Keyboard and zoom

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            document.deleteSelection()
        default:
            nextResponder?.keyDown(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil).x)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let factor = 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
            zoom(by: factor, around: convert(event.locationInWindow, from: nil).x)
            return
        }
        super.scrollWheel(with: event)
    }

    /// Changes horizontal zoom, keeping the time under `anchorX` in place.
    func zoom(by factor: CGFloat, around anchorX: CGFloat) {
        guard let scroll = enclosingScrollView else { return }
        let anchorTime = time(for: anchorX)
        let visibleOffset = anchorX - scroll.contentView.bounds.minX
        let fit = fitPointsPerSecond
        let current = effectivePointsPerSecond
        let next = min(400, max(fit, current * factor))
        pointsPerSecond = next <= fit * 1.001 ? 0 : next
        // Resize the scrollable document before scrolling to the anchor.
        onZoomChange?()
        let newX = x(for: anchorTime) - visibleOffset
        scroll.contentView.scroll(to: NSPoint(x: max(0, newX), y: scroll.contentView.bounds.minY))
        scroll.reflectScrolledClipView(scroll.contentView)
        requestThumbnailsIfNeeded()
    }

    var onZoomChange: (() -> Void)?

    /// Keeps the playhead visible while playing.
    func revealPlayhead(time: Double) {
        guard let scroll = enclosingScrollView, pointsPerSecond > 0 else { return }
        let x = x(for: time)
        let visible = scroll.contentView.bounds
        if x > visible.maxX - 40 || x < visible.minX {
            scroll.contentView.scroll(to: NSPoint(x: max(0, x - 60), y: visible.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

// MARK: - Lane gutter

/// Fixed icons at the left of each lane.
final class VideoTimelineGutter: NSView {
    weak var timeline: VideoTimelineView?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        VideoEditorStyle.panel.setFill()
        bounds.fill()
        guard let timeline else { return }
        let offset = (timeline.enclosingScrollView?.contentView.bounds.minY ?? 0)
        let symbols: [VideoTimelineView.Lane: String] = [.clip: "film", .zoom: "plus.magnifyingglass",
            .edits: "scissors", .overlays: "textformat", .captions: "captions.bubble"]
        let names: [VideoTimelineView.Lane: String] = [.clip: L("Clip"), .zoom: L("Zoom"), .edits: L("Edits"),
            .overlays: L("Overlays"), .captions: L("Captions")]
        for (lane, rect) in timeline.laneLayout {
            guard let name = symbols[lane], let image = VideoEditorStyle.symbol(name, size: 12)?.tinted(VideoEditorStyle.textTertiary) else { continue }
            let y = rect.minY - offset + min(rect.height, VideoTimelineView.laneHeight) / 2
            image.draw(in: NSRect(x: (bounds.width - image.size.width) / 2, y: y - image.size.height / 2,
                                  width: image.size.width, height: image.size.height))
            _ = names[lane]
        }
    }
}

// MARK: - Helpers

private final class TimelineThumbnailCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [(time: Double, image: CGImage)] = []
    private let count: Int
    private var lastPublished = 0

    init(count: Int) { self.count = count }

    /// Returns a sorted batch periodically (progressive loading).
    func add(time: Double, image: CGImage) -> [(time: Double, image: CGImage)]? {
        lock.lock()
        defer { lock.unlock() }
        images.append((time, image))
        guard images.count - lastPublished >= max(1, count / 8) || images.count == count else { return nil }
        lastPublished = images.count
        return images.sorted { $0.time < $1.time }
    }
}

/// The asset is only read by the detached waveform worker.
private struct WaveformInput: @unchecked Sendable {
    nonisolated(unsafe) let asset: AVAsset
}

enum VideoWaveform {
    /// Peak amplitudes (0…1) of the first audio track in `buckets` buckets.
    nonisolated static func peaks(asset: AVAsset, duration: Double, buckets: Int) -> [Float] {
        guard duration > 0, let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        // Low sample rate: a waveform needs peaks, not fidelity.
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                       AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var peaks = [Float](repeating: 0, count: buckets)
        let samplesPerBucket = max(1.0, duration * 8000 / Double(buckets))
        var index = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return [] }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr, let pointer else { continue }
            let count = length / 2
            pointer.withMemoryRebound(to: Int16.self, capacity: count) { samples in
                for i in 0..<count {
                    let bucket = min(buckets - 1, Int(index / samplesPerBucket))
                    let value = Float(abs(Int32(samples[i]))) / 32768
                    if value > peaks[bucket] { peaks[bucket] = value }
                    index += 1
                }
            }
        }
        // Perceptual scaling so quiet speech still shows.
        let maxPeak = max(0.05, peaks.max() ?? 1)
        return peaks.map { sqrt(min(1, $0 / maxPeak)) }
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}
