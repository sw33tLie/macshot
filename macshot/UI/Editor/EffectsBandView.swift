import Cocoa

/// The effects band — the horizontal strip below the trim timeline that
/// hosts zoom and censor pills, stacked across multiple rows when segments
/// overlap in time. Owns its own state, drawing, hit testing and input.
/// Communicates mutations back to the parent editor via its delegate.
@MainActor
protocol EffectsBandViewDelegate: AnyObject {
    /// Segment data (contents OR selection) changed; caller should rebuild
    /// the video composition, invalidate saved-URL state, etc.
    func effectsBandDidMutate(_ view: EffectsBandView)
    /// Selection changed; caller should update the preview overlay and
    /// optionally seek the player to a time that makes editing intuitive.
    func effectsBand(_ view: EffectsBandView, didSelectSegment segmentID: UUID?)
    /// Number of visible rows changed; caller should resize the scroll-view
    /// host / window. Called AFTER the band's intrinsicContentSize updates.
    func effectsBand(_ view: EffectsBandView, didChangeRowCount rowCount: Int)
    /// Convenience hook for "please show this status string" — mirrors the
    /// editor's in-view status banner so we don't duplicate that machinery.
    func effectsBand(_ view: EffectsBandView, showStatus message: String, isError: Bool)
}

@MainActor
final class EffectsBandView: NSView {

    // MARK: - Public state (owned by this view, read by the parent)

    weak var delegate: EffectsBandViewDelegate?

    /// Total source-asset duration in seconds. Parent must keep this updated
    /// (e.g. after the asset finishes loading).
    var duration: Double = 0 {
        didSet { if duration != oldValue { needsLayout = true; needsDisplay = true } }
    }

    private(set) var zoomSegments: [VideoZoomSegment] = []
    private(set) var censorSegments: [VideoCensorSegment] = []
    /// Cuts are temporal — frames in their range never reach the output.
    /// They render as a dimmed "deleted film" pill distinct from zoom/censor.
    private(set) var cutSegments: [VideoCutSegment] = []
    /// Speed segments retime a source range. Non-overlapping with each
    /// other (enforced at drag time). Shown as a teal pill with the
    /// factor text (e.g. "2×").
    private(set) var speedSegments: [VideoSpeedSegment] = []
    private(set) var selectedSegmentID: UUID? {
        didSet {
            if oldValue != selectedSegmentID {
                delegate?.effectsBand(self, didSelectSegment: selectedSegmentID)
                needsDisplay = true
            }
        }
    }

    // MARK: - Layout constants

    private let rowH: CGFloat = 22
    private let rowGap: CGFloat = 2
    private var rowStride: CGFloat { rowH + rowGap }
    /// The enclosing scroll view is already inset horizontally to match the
    /// trim timeline above — don't double-inset here, otherwise our pills
    /// would be narrower than the thumbnails above them.
    private let horizontalInset: CGFloat = 0
    /// Vertical padding around the stack so the topmost row's upper handle
    /// (and bottommost row's lower handle) don't get clipped by the scroll
    /// view's content bounds.
    private let verticalInset: CGFloat = 4
    /// Visible rows above this count scroll via the enclosing scroll view.
    static let maxVisibleRows: Int = 4

    // MARK: - Private state

    private var effectRowAssignment: [UUID: Int] = [:]
    private var effectRowCount: Int = 1

    private enum SegmentDragKind { case move, resizeStart, resizeEnd }
    private var draggingSegmentID: UUID?
    private var draggingSegmentKind: SegmentDragKind?
    private var draggingSegmentAnchor: Double = 0

    private var cursorOnBand: NSPoint? {
        didSet { if oldValue != cursorOnBand { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    // MARK: - Public API for mutation from the parent

    /// Replace all segments. Used at init time.
    func setSegments(zoom: [VideoZoomSegment],
                     censor: [VideoCensorSegment],
                     cut: [VideoCutSegment] = [],
                     speed: [VideoSpeedSegment] = []) {
        self.zoomSegments = zoom
        self.censorSegments = censor
        self.cutSegments = cut
        self.speedSegments = speed
        relayoutAndNotify()
    }

    /// Remove segment by id regardless of type.
    func removeSegment(id: UUID) {
        zoomSegments.removeAll { $0.id == id }
        censorSegments.removeAll { $0.id == id }
        cutSegments.removeAll { $0.id == id }
        speedSegments.removeAll { $0.id == id }
        if selectedSegmentID == id { selectedSegmentID = nil }
        relayoutAndNotify()
    }

    /// Commit a change the parent made to a segment's properties (e.g. the
    /// preview overlay resized a zoom rect). Triggers a re-layout + redraw
    /// without re-sending a mutation signal (caller already knows).
    func refreshAfterParentEdit() {
        layoutRows()
        needsDisplay = true
    }

    /// Clear the current selection. Safe to call when no segment is selected.
    func clearSelection() {
        if selectedSegmentID != nil {
            selectedSegmentID = nil
        }
    }

    // MARK: - Geometry helpers

    /// The track rect where row 0 sits — the bottom row of the stack, offset
    /// up by `verticalInset` so the bottom row's lower handle has room.
    private var row0Rect: NSRect {
        let x = horizontalInset
        let y: CGFloat = verticalInset
        let w = max(0, bounds.width - horizontalInset * 2)
        return NSRect(x: x, y: y, width: w, height: rowH)
    }

    /// Pill rect for a segment at its assigned row. Row 0 is the bottom row;
    /// higher row indices stack upward.
    private func pillRect(id: UUID, startTime: Double, endTime: Double) -> NSRect {
        let row0 = row0Rect
        guard duration > 0, row0.width > 0 else { return .zero }
        let row = effectRowAssignment[id] ?? 0
        let y = row0.minY + CGFloat(row) * rowStride
        let x0 = row0.minX + CGFloat(startTime / duration) * row0.width
        let x1 = row0.minX + CGFloat(endTime / duration) * row0.width
        return NSRect(x: x0, y: y, width: max(2, x1 - x0), height: row0.height)
    }

    private func zoomPillRect(for segment: VideoZoomSegment) -> NSRect {
        pillRect(id: segment.id, startTime: segment.startTime, endTime: segment.endTime)
    }

    private func censorPillRect(for segment: VideoCensorSegment) -> NSRect {
        pillRect(id: segment.id, startTime: segment.startTime, endTime: segment.endTime)
    }

    private func cutPillRect(for segment: VideoCutSegment) -> NSRect {
        pillRect(id: segment.id, startTime: segment.startTime, endTime: segment.endTime)
    }

    private func speedPillRect(for segment: VideoSpeedSegment) -> NSRect {
        pillRect(id: segment.id, startTime: segment.startTime, endTime: segment.endTime)
    }

    // MARK: - Layout

    /// The band's natural height, driven by the current row count. The
    /// enclosing scroll view reads this as the document view's height and
    /// enables vertical scrolling once it exceeds the clip view's bounds.
    override var intrinsicContentSize: NSSize {
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: CGFloat(effectRowCount) * rowStride - rowGap + verticalInset * 2)
    }

    override var isFlipped: Bool {
        // Keep AppKit default (y grows upward) so our rect math matches the
        // rest of the editor's drawing.
        return false
    }

    /// Greedy interval-graph coloring: each segment gets the lowest row index
    /// that doesn't collide with any segment already placed in that row.
    private func layoutRows() {
        effectRowAssignment.removeAll(keepingCapacity: true)
        struct Item { let id: UUID; let start: Double; let end: Double }
        var items: [Item] = []
        for z in zoomSegments where z.endTime > z.startTime {
            items.append(Item(id: z.id, start: z.startTime, end: z.endTime))
        }
        for c in censorSegments where c.endTime > c.startTime {
            items.append(Item(id: c.id, start: c.startTime, end: c.endTime))
        }
        for k in cutSegments where k.endTime > k.startTime {
            items.append(Item(id: k.id, start: k.startTime, end: k.endTime))
        }
        for s in speedSegments where s.endTime > s.startTime {
            items.append(Item(id: s.id, start: s.startTime, end: s.endTime))
        }
        items.sort { $0.start < $1.start }

        var rows: [[ClosedRange<Double>]] = [[]]
        for item in items {
            var assigned = -1
            for (idx, ranges) in rows.enumerated() {
                let clashes = ranges.contains { r in
                    item.start < r.upperBound && item.end > r.lowerBound
                        && !(item.start >= r.upperBound || item.end <= r.lowerBound)
                }
                if !clashes { assigned = idx; break }
            }
            if assigned < 0 {
                rows.append([])
                assigned = rows.count - 1
            }
            rows[assigned].append(item.start...item.end)
            effectRowAssignment[item.id] = assigned
        }
        let newRowCount = max(1, rows.count)
        if newRowCount != effectRowCount {
            effectRowCount = newRowCount
            invalidateIntrinsicContentSize()
            delegate?.effectsBand(self, didChangeRowCount: effectRowCount)
        } else {
            effectRowCount = newRowCount
        }
    }

    private func relayoutAndNotify() {
        layoutRows()
        delegate?.effectsBandDidMutate(self)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        layoutRows()

        guard duration > 0, bounds.width > horizontalInset * 2 else { return }

        let row0 = row0Rect

        // Background across every row (continuous rounded strip).
        let bandRect = NSRect(
            x: row0.minX,
            y: row0.minY,
            width: row0.width,
            height: CGFloat(effectRowCount) * rowStride - rowGap
        )
        let bgPath = NSBezierPath(roundedRect: bandRect, xRadius: 5, yRadius: 5)
        ToolbarLayout.iconColor.withAlphaComponent(0.06).setFill()
        bgPath.fill()

        // Separator lines between stacked rows.
        if effectRowCount >= 2 {
            NSColor.white.withAlphaComponent(0.10).setFill()
            for i in 1..<effectRowCount {
                let y = row0.minY + CGFloat(i) * rowStride - 1
                NSBezierPath(rect: NSRect(x: row0.minX, y: y, width: row0.width, height: 1)).fill()
            }
        }

        // Pills.
        for seg in zoomSegments {
            let rect = zoomPillRect(for: seg)
            guard rect.width > 0 else { continue }
            drawEffectPill(
                rect: rect,
                isSelected: seg.id == selectedSegmentID,
                baseFillColor: NSColor(calibratedRed: 0.25, green: 0.55, blue: 1.0, alpha: 1.0),
                fadeInFrac: seg.effectiveFadeIn / max(seg.duration, 0.001),
                fadeOutFrac: seg.effectiveFadeOut / max(seg.duration, 0.001),
                iconSymbol: "plus.magnifyingglass",
                label: formatZoom(seg.zoomLevel)
            )
        }
        for seg in censorSegments {
            let rect = censorPillRect(for: seg)
            guard rect.width > 0 else { continue }
            let styleIcon: String
            let styleLabel: String
            switch seg.style {
            case .solid:    styleIcon = "square.fill";           styleLabel = L("Solid")
            case .pixelate: styleIcon = "squareshape.split.2x2"; styleLabel = L("Pixelate")
            case .blur:     styleIcon = "drop.fill";             styleLabel = L("Blur")
            }
            drawEffectPill(
                rect: rect,
                isSelected: seg.id == selectedSegmentID,
                baseFillColor: NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.35, alpha: 1.0),
                fadeInFrac: seg.effectiveFadeIn / max(seg.duration, 0.001),
                fadeOutFrac: seg.effectiveFadeOut / max(seg.duration, 0.001),
                iconSymbol: styleIcon,
                label: styleLabel
            )
        }
        // Speed — drawn before cuts but after zoom/censor. Teal pill with
        // factor text.
        for seg in speedSegments {
            let rect = speedPillRect(for: seg)
            guard rect.width > 0 else { continue }
            // tortoise.fill is wider + has more trailing whitespace than
            // forward.fill, so it needs an even bigger gap to not kiss the
            // factor text.
            let isSlow = seg.speedFactor < 1.0
            drawEffectPill(
                rect: rect,
                isSelected: seg.id == selectedSegmentID,
                baseFillColor: NSColor(calibratedRed: 0.20, green: 0.65, blue: 0.60, alpha: 1.0),
                fadeInFrac: 0,
                fadeOutFrac: 0,
                iconSymbol: isSlow ? "tortoise.fill" : "forward.fill",
                label: formatSpeedLabel(seg.speedFactor),
                iconLabelGap: isSlow ? 11 : 8
            )
        }
        // Cuts — drawn last so they sit visually above other pills in their
        // row. Distinct striped/dark look signals that the range is removed.
        for seg in cutSegments {
            let rect = cutPillRect(for: seg)
            guard rect.width > 0 else { continue }
            drawCutPill(rect: rect,
                         isSelected: seg.id == selectedSegmentID,
                         label: formatCutLabel(duration: seg.duration))
        }

        // Empty-state hint.
        if zoomSegments.isEmpty && censorSegments.isEmpty && cutSegments.isEmpty && speedSegments.isEmpty {
            let hint = L("Click to add effects") as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.55),
            ]
            let size = hint.size(withAttributes: attrs)
            hint.draw(at: NSPoint(x: bandRect.midX - size.width / 2,
                                   y: bandRect.midY - size.height / 2),
                       withAttributes: attrs)
        }

        // Cursor-follow + icon.
        drawCursorFollowPlus(bandRect: bandRect)
    }

    private func drawCursorFollowPlus(bandRect: NSRect) {
        guard let p = cursorOnBand,
              draggingSegmentID == nil,
              !pointIsOverAnyPill(p) else { return }
        let accent = NSColor(calibratedRed: 0.5, green: 0.75, blue: 1.0, alpha: 0.9)
        let iconSize: CGFloat = 14
        let drawRect = NSRect(x: p.x + 10, y: p.y - 10, width: iconSize, height: iconSize)
        guard let icon = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: iconSize, weight: .semibold)) else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        let tinted = NSImage(size: icon.size, flipped: false) { r in
            icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            accent.setFill()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: drawRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawEffectPill(rect: NSRect,
                                 isSelected: Bool,
                                 baseFillColor: NSColor,
                                 fadeInFrac: Double,
                                 fadeOutFrac: Double,
                                 iconSymbol: String,
                                 label: String,
                                 iconLabelGap: CGFloat = 4) {
        let fillColor = baseFillColor.withAlphaComponent(isSelected ? 1.0 : 0.88)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        fillColor.setFill()
        path.fill()

        let fadeColor = NSColor.black.withAlphaComponent(0.18)
        let fadeInW = CGFloat(fadeInFrac) * rect.width
        let fadeOutW = CGFloat(fadeOutFrac) * rect.width
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        fadeColor.setFill()
        if fadeInW > 1 {
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: fadeInW, height: rect.height)).fill()
        }
        if fadeOutW > 1 {
            NSBezierPath(rect: NSRect(x: rect.maxX - fadeOutW, y: rect.minY, width: fadeOutW, height: rect.height)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let labelNS = label as NSString
        let labelSize = labelNS.size(withAttributes: labelAttrs)
        let iconSize: CGFloat = 11
        let contentW = iconSize + iconLabelGap + labelSize.width
        if rect.width > contentW + 6 {
            let startX = rect.midX - contentW / 2
            if let icon = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: iconSize, weight: .semibold)) {
                let tinted = NSImage(size: icon.size, flipped: false) { r in
                    icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    NSColor.white.setFill()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: startX, y: rect.midY - icon.size.height / 2,
                                        width: icon.size.width, height: icon.size.height))
            }
            labelNS.draw(at: NSPoint(x: startX + iconSize + iconLabelGap, y: rect.midY - labelSize.height / 2),
                          withAttributes: labelAttrs)
        } else if rect.width > iconSize + 4 {
            if let icon = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: iconSize, weight: .semibold)) {
                let tinted = NSImage(size: icon.size, flipped: false) { r in
                    icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    NSColor.white.setFill()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: rect.midX - icon.size.width / 2,
                                        y: rect.midY - icon.size.height / 2,
                                        width: icon.size.width, height: icon.size.height))
            }
        }

        if isSelected {
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 6, yRadius: 6)
            border.lineWidth = 1.5
            border.stroke()
        }

        let handleW: CGFloat = 6
        let handleH: CGFloat = rect.height + 6
        let handleY = rect.minY - 3
        let handleColor = NSColor.white.withAlphaComponent(isSelected ? 1.0 : 0.9)
        let left = NSRect(x: rect.minX - handleW / 2 + 1, y: handleY, width: handleW, height: handleH)
        handleColor.setFill()
        NSBezierPath(roundedRect: left, xRadius: 2, yRadius: 2).fill()
        drawHandleGrip(in: left)
        let right = NSRect(x: rect.maxX - handleW / 2 - 1, y: handleY, width: handleW, height: handleH)
        handleColor.setFill()
        NSBezierPath(roundedRect: right, xRadius: 2, yRadius: 2).fill()
        drawHandleGrip(in: right)
    }

    /// Draw a cut pill. Distinct visual from zoom/censor: dark-red base with
    /// diagonal hatching to signal "this span is being removed."
    private func drawCutPill(rect: NSRect, isSelected: Bool, label: String) {
        let base = NSColor(calibratedRed: 0.35, green: 0.08, blue: 0.10, alpha: isSelected ? 1.0 : 0.95)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        base.setFill()
        path.fill()

        // Diagonal stripes inside the pill — film-strip deletion cue.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        let stripe = NSBezierPath()
        stripe.lineWidth = 1
        let step: CGFloat = 6
        var x = rect.minX - rect.height
        while x < rect.maxX + rect.height {
            stripe.move(to: NSPoint(x: x, y: rect.minY))
            stripe.line(to: NSPoint(x: x + rect.height, y: rect.maxY))
            x += step
        }
        stripe.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let labelNS = label as NSString
        let labelSize = labelNS.size(withAttributes: labelAttrs)
        let iconSize: CGFloat = 11
        // Scissors glyph is narrower than "+" / drop / square so its trailing
        // whitespace looks smaller against the label — bump the gap explicitly.
        let iconLabelGap: CGFloat = 7
        let contentW = iconSize + iconLabelGap + labelSize.width
        if rect.width > contentW + 6,
           let icon = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: iconSize, weight: .semibold)) {
            let startX = rect.midX - contentW / 2
            let tinted = NSImage(size: icon.size, flipped: false) { r in
                icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                NSColor.white.setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: startX, y: rect.midY - icon.size.height / 2,
                                    width: icon.size.width, height: icon.size.height))
            labelNS.draw(at: NSPoint(x: startX + iconSize + iconLabelGap, y: rect.midY - labelSize.height / 2),
                          withAttributes: labelAttrs)
        } else if rect.width > iconSize + 4,
                  let icon = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: iconSize, weight: .semibold)) {
            let tinted = NSImage(size: icon.size, flipped: false) { r in
                icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                NSColor.white.setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: rect.midX - icon.size.width / 2,
                                    y: rect.midY - icon.size.height / 2,
                                    width: icon.size.width, height: icon.size.height))
        }

        if isSelected {
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 6, yRadius: 6)
            border.lineWidth = 1.5
            border.stroke()
        }

        // Same grab handles as other pills so drag-to-resize feels uniform.
        let handleW: CGFloat = 6
        let handleH: CGFloat = rect.height + 6
        let handleY = rect.minY - 3
        let handleColor = NSColor.white.withAlphaComponent(isSelected ? 1.0 : 0.9)
        let left = NSRect(x: rect.minX - handleW / 2 + 1, y: handleY, width: handleW, height: handleH)
        handleColor.setFill()
        NSBezierPath(roundedRect: left, xRadius: 2, yRadius: 2).fill()
        drawHandleGrip(in: left)
        let right = NSRect(x: rect.maxX - handleW / 2 - 1, y: handleY, width: handleW, height: handleH)
        handleColor.setFill()
        NSBezierPath(roundedRect: right, xRadius: 2, yRadius: 2).fill()
        drawHandleGrip(in: right)
    }

    private func formatCutLabel(duration: Double) -> String {
        if duration < 1 { return String(format: "%.1fs", duration) }
        return String(format: "%.1fs", duration)
    }

    private func formatSpeedLabel(_ factor: Double) -> String {
        // Round to 2 decimals but drop trailing zeros ("2×" not "2.00×").
        let rounded = (factor * 100).rounded() / 100
        if abs(rounded - rounded.rounded()) < 0.01 {
            return "\(Int(rounded.rounded()))×"
        }
        return String(format: "%g×", rounded)
    }

    private func drawHandleGrip(in rect: NSRect) {
        NSColor(calibratedRed: 0.18, green: 0.45, blue: 0.85, alpha: 0.85).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let midY = rect.midY
        for dy in stride(from: -2.5 as CGFloat, through: 2.5, by: 2.5) {
            path.move(to: NSPoint(x: rect.midX - 1.2, y: midY + dy))
            path.line(to: NSPoint(x: rect.midX + 1.2, y: midY + dy))
        }
        path.stroke()
    }

    private func formatZoom(_ level: CGFloat) -> String {
        if abs(level.rounded() - level) < 0.01 { return "\(Int(level.rounded()))x" }
        return String(format: "%.1fx", level)
    }

    // MARK: - Hit testing helpers

    private func pointIsOverAnyPill(_ p: NSPoint) -> Bool {
        let slop: CGFloat = 6
        for seg in zoomSegments {
            if zoomPillRect(for: seg).insetBy(dx: -slop, dy: -5).contains(p) { return true }
        }
        for seg in censorSegments {
            if censorPillRect(for: seg).insetBy(dx: -slop, dy: -5).contains(p) { return true }
        }
        for seg in cutSegments {
            if cutPillRect(for: seg).insetBy(dx: -slop, dy: -5).contains(p) { return true }
        }
        for seg in speedSegments {
            if speedPillRect(for: seg).insetBy(dx: -slop, dy: -5).contains(p) { return true }
        }
        return false
    }

    // MARK: - Mouse

    override var acceptsFirstResponder: Bool { true }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        cursorOnBand = bounds.contains(p) ? p : nil
    }

    override func mouseExited(with event: NSEvent) {
        cursorOnBand = nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let edgeHitW: CGFloat = 9
        let clickTime = Double((p.x - row0Rect.minX) / max(row0Rect.width, 1)) * duration

        // Cuts first so they remain clickable even when visually stacked on
        // top of zoom/censor pills that share their time range.
        for seg in cutSegments.reversed() {
            let pill = cutPillRect(for: seg)
            if pill.insetBy(dx: -edgeHitW, dy: -5).contains(p) {
                beginSegmentDrag(id: seg.id,
                                  edge: edgeHitForX(p.x, pill: pill, hitW: edgeHitW),
                                  clickTime: clickTime,
                                  segStart: seg.startTime,
                                  segEnd: seg.endTime)
                return
            }
        }
        for seg in speedSegments.reversed() {
            let pill = speedPillRect(for: seg)
            if pill.insetBy(dx: -edgeHitW, dy: -5).contains(p) {
                beginSegmentDrag(id: seg.id,
                                  edge: edgeHitForX(p.x, pill: pill, hitW: edgeHitW),
                                  clickTime: clickTime,
                                  segStart: seg.startTime,
                                  segEnd: seg.endTime)
                return
            }
        }
        // Zooms (iterate reverse so the latest-drawn wins on overlap).
        for seg in zoomSegments.reversed() {
            let pill = zoomPillRect(for: seg)
            if pill.insetBy(dx: -edgeHitW, dy: -5).contains(p) {
                beginSegmentDrag(id: seg.id,
                                  edge: edgeHitForX(p.x, pill: pill, hitW: edgeHitW),
                                  clickTime: clickTime,
                                  segStart: seg.startTime,
                                  segEnd: seg.endTime)
                return
            }
        }
        for seg in censorSegments.reversed() {
            let pill = censorPillRect(for: seg)
            if pill.insetBy(dx: -edgeHitW, dy: -5).contains(p) {
                beginSegmentDrag(id: seg.id,
                                  edge: edgeHitForX(p.x, pill: pill, hitW: edgeHitW),
                                  clickTime: clickTime,
                                  segStart: seg.startTime,
                                  segEnd: seg.endTime)
                return
            }
        }
        // Empty band — open add menu at click point.
        showAddEffectMenu(at: p, clickTime: clickTime)
    }

    private func edgeHitForX(_ x: CGFloat, pill: NSRect, hitW: CGFloat) -> SegmentDragKind {
        if abs(x - pill.minX) < hitW { return .resizeStart }
        if abs(x - pill.maxX) < hitW { return .resizeEnd }
        return .move
    }

    private func beginSegmentDrag(id: UUID, edge: SegmentDragKind, clickTime: Double, segStart: Double, segEnd: Double) {
        selectedSegmentID = id
        draggingSegmentID = id
        draggingSegmentKind = edge
        switch edge {
        case .resizeStart: draggingSegmentAnchor = clickTime - segStart
        case .resizeEnd:   draggingSegmentAnchor = clickTime - segEnd
        case .move:        draggingSegmentAnchor = clickTime - segStart
        }
        delegate?.effectsBandDidMutate(self)   // selection is a kind of mutation for composition purposes
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let id = draggingSegmentID, let kind = draggingSegmentKind else { return }
        let p = convert(event.locationInWindow, from: nil)
        let t = max(0, min(duration, Double((p.x - row0Rect.minX) / max(row0Rect.width, 1)) * duration))
        if let seg = zoomSegments.first(where: { $0.id == id }) {
            dragZoomSegment(seg, kind: kind, time: t)
        } else if let seg = censorSegments.first(where: { $0.id == id }) {
            dragCensorSegment(seg, kind: kind, time: t)
        } else if let seg = cutSegments.first(where: { $0.id == id }) {
            dragCutSegment(seg, kind: kind, time: t)
        } else if let seg = speedSegments.first(where: { $0.id == id }) {
            dragSpeedSegment(seg, kind: kind, time: t)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = draggingSegmentID != nil
        draggingSegmentID = nil
        draggingSegmentKind = nil
        if wasDragging {
            delegate?.effectsBandDidMutate(self)
        }
    }

    private func dragZoomSegment(_ seg: VideoZoomSegment, kind: SegmentDragKind, time t: Double) {
        let others = zoomSegments.filter { $0.id != seg.id }.map { (start: $0.startTime, end: $0.endTime) }
        switch kind {
        case .move:
            let (newStart, newEnd) = resolveMove(segment: (seg.startTime, seg.endTime),
                                                  to: t - draggingSegmentAnchor,
                                                  others: others)
            seg.startTime = max(0, newStart); seg.endTime = min(duration, newEnd)
        case .resizeStart:
            let minEnd = seg.endTime - VideoZoomSegment.minDuration
            var newStart = max(0, min(minEnd, t - draggingSegmentAnchor))
            let lowerBound = others.filter { $0.end <= seg.endTime }.map(\.end).max() ?? 0
            newStart = max(lowerBound, newStart)
            seg.startTime = newStart
        case .resizeEnd:
            let minStart = seg.startTime + VideoZoomSegment.minDuration
            var newEnd = max(minStart, min(duration, t - draggingSegmentAnchor))
            let upperBound = others.filter { $0.start >= seg.startTime }.map(\.start).min() ?? duration
            newEnd = min(upperBound, newEnd)
            seg.endTime = newEnd
        }
        layoutRows()
        needsDisplay = true
    }

    private func dragSpeedSegment(_ seg: VideoSpeedSegment, kind: SegmentDragKind, time t: Double) {
        // Speed segments can't overlap each other — enforce via neighbour
        // clamping. They're allowed to overlap cuts (they'll be silently
        // clipped to the kept range on export).
        let others = speedSegments.filter { $0.id != seg.id }.map { (start: $0.startTime, end: $0.endTime) }
        // Min source duration so composition duration stays >= minCompDuration.
        let minSrcDuration = VideoSpeedSegment.minCompDuration * seg.speedFactor
        switch kind {
        case .move:
            let (newStart, newEnd) = resolveMove(segment: (seg.startTime, seg.endTime),
                                                  to: t - draggingSegmentAnchor,
                                                  others: others)
            seg.startTime = max(0, newStart); seg.endTime = min(duration, newEnd)
        case .resizeStart:
            let minEnd = seg.endTime - minSrcDuration
            var newStart = max(0, min(minEnd, t - draggingSegmentAnchor))
            let lowerBound = others.filter { $0.end <= seg.endTime }.map(\.end).max() ?? 0
            newStart = max(lowerBound, newStart)
            seg.startTime = newStart
        case .resizeEnd:
            let minStart = seg.startTime + minSrcDuration
            var newEnd = max(minStart, min(duration, t - draggingSegmentAnchor))
            let upperBound = others.filter { $0.start >= seg.startTime }.map(\.start).min() ?? duration
            newEnd = min(upperBound, newEnd)
            seg.endTime = newEnd
        }
        layoutRows()
        needsDisplay = true
    }

    private func dragCutSegment(_ seg: VideoCutSegment, kind: SegmentDragKind, time t: Double) {
        // Cuts can overlap freely — the export pipeline merges overlapping
        // cut ranges, so no need for neighbour-based clamping.
        switch kind {
        case .move:
            let (newStart, newEnd) = resolveMove(segment: (seg.startTime, seg.endTime),
                                                  to: t - draggingSegmentAnchor,
                                                  others: [])
            seg.startTime = max(0, newStart); seg.endTime = min(duration, newEnd)
        case .resizeStart:
            let minEnd = seg.endTime - VideoCutSegment.minDuration
            seg.startTime = max(0, min(minEnd, t - draggingSegmentAnchor))
        case .resizeEnd:
            let minStart = seg.startTime + VideoCutSegment.minDuration
            seg.endTime = max(minStart, min(duration, t - draggingSegmentAnchor))
        }
        layoutRows()
        needsDisplay = true
    }

    private func dragCensorSegment(_ seg: VideoCensorSegment, kind: SegmentDragKind, time t: Double) {
        // Censors can overlap each other freely — empty others list.
        switch kind {
        case .move:
            let (newStart, newEnd) = resolveMove(segment: (seg.startTime, seg.endTime),
                                                  to: t - draggingSegmentAnchor,
                                                  others: [])
            seg.startTime = max(0, newStart); seg.endTime = min(duration, newEnd)
        case .resizeStart:
            let minEnd = seg.endTime - VideoCensorSegment.minDuration
            seg.startTime = max(0, min(minEnd, t - draggingSegmentAnchor))
        case .resizeEnd:
            let minStart = seg.startTime + VideoCensorSegment.minDuration
            seg.endTime = max(minStart, min(duration, t - draggingSegmentAnchor))
        }
        layoutRows()
        needsDisplay = true
    }

    private func resolveMove(segment: (Double, Double),
                              to desiredStart: Double,
                              others: [(start: Double, end: Double)]) -> (Double, Double) {
        let segDuration = segment.1 - segment.0
        var newStart = max(0, min(duration - segDuration, desiredStart))
        var newEnd = newStart + segDuration
        let currentStart = segment.0
        for other in others.sorted(by: { $0.start < $1.start }) {
            if newStart < other.end && newEnd > other.start {
                if currentStart < other.start {
                    newEnd = other.start; newStart = newEnd - segDuration
                } else {
                    newStart = other.end;  newEnd = newStart + segDuration
                }
            }
        }
        return (newStart, newEnd)
    }

    // MARK: - Right-click menus

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let edgeSlop: CGFloat = 6
        for seg in cutSegments.reversed() {
            let pill = cutPillRect(for: seg)
            if pill.insetBy(dx: -edgeSlop, dy: -5).contains(p) {
                selectedSegmentID = seg.id
                needsDisplay = true
                showCutPillContextMenu(for: seg, at: event)
                return
            }
        }
        for seg in speedSegments.reversed() {
            let pill = speedPillRect(for: seg)
            if pill.insetBy(dx: -edgeSlop, dy: -5).contains(p) {
                selectedSegmentID = seg.id
                needsDisplay = true
                showSpeedPillContextMenu(for: seg, at: event)
                return
            }
        }
        for seg in zoomSegments.reversed() {
            let pill = zoomPillRect(for: seg)
            if pill.insetBy(dx: -edgeSlop, dy: -5).contains(p) {
                selectedSegmentID = seg.id
                needsDisplay = true
                showZoomPillContextMenu(for: seg, at: event)
                return
            }
        }
        for seg in censorSegments.reversed() {
            let pill = censorPillRect(for: seg)
            if pill.insetBy(dx: -edgeSlop, dy: -5).contains(p) {
                selectedSegmentID = seg.id
                needsDisplay = true
                showCensorPillContextMenu(for: seg, at: event)
                return
            }
        }
        let clickTime = Double((p.x - row0Rect.minX) / max(row0Rect.width, 1)) * duration
        showAddEffectMenu(at: p, clickTime: clickTime)
    }

    private func showCutPillContextMenu(for seg: VideoCutSegment, at event: NSEvent) {
        let menu = NSMenu()
        attachAddEffectSubmenu(to: menu, event: event)
        menu.addItem(.separator())
        let del = NSMenuItem(title: L("Delete Cut"),
                              action: #selector(handleDeleteSelectedFromMenu),
                              keyEquivalent: "")
        del.target = self
        menu.addItem(del)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func showSpeedPillContextMenu(for seg: VideoSpeedSegment, at event: NSEvent) {
        let menu = NSMenu()
        for factor in VideoSpeedSegment.presetFactors {
            let item = NSMenuItem(title: "\(formatSpeedLabel(factor))",
                                  action: #selector(handleSetSpeedFactorFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = SpeedFactorMenuContext(segmentID: seg.id, factor: factor)
            item.state = (abs(seg.speedFactor - factor) < 0.001) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        attachAddEffectSubmenu(to: menu, event: event)
        menu.addItem(.separator())
        let del = NSMenuItem(title: L("Delete Speed"),
                              action: #selector(handleDeleteSelectedFromMenu),
                              keyEquivalent: "")
        del.target = self
        menu.addItem(del)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func showZoomPillContextMenu(for seg: VideoZoomSegment, at event: NSEvent) {
        let menu = NSMenu()
        attachFadeSubmenu(to: menu, segmentID: seg.id, currentFade: seg.fadeIn)
        menu.addItem(.separator())
        attachAddEffectSubmenu(to: menu, event: event)
        menu.addItem(.separator())
        let del = NSMenuItem(title: L("Delete Zoom"),
                              action: #selector(handleDeleteSelectedFromMenu),
                              keyEquivalent: "")
        del.target = self
        menu.addItem(del)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func showCensorPillContextMenu(for seg: VideoCensorSegment, at event: NSEvent) {
        let menu = NSMenu()
        let styles: [(String, VideoCensorSegment.Style)] = [
            (L("Solid"),    .solid),
            (L("Pixelate"), .pixelate),
            (L("Blur"),     .blur),
        ]
        for (title, style) in styles {
            let item = NSMenuItem(title: title,
                                  action: #selector(handleSetCensorStyleFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = CensorStyleMenuContext(segmentID: seg.id, style: style)
            item.state = (seg.style == style) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        attachFadeSubmenu(to: menu, segmentID: seg.id, currentFade: seg.fadeIn)
        menu.addItem(.separator())
        attachAddEffectSubmenu(to: menu, event: event)
        menu.addItem(.separator())
        let del = NSMenuItem(title: L("Delete Censor"),
                              action: #selector(handleDeleteSelectedFromMenu),
                              keyEquivalent: "")
        del.target = self
        menu.addItem(del)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Adds a "Fade" submenu to `menu` listing a few preset durations. The
    /// same value is applied to both fade-in and fade-out since exposing two
    /// knobs is overkill for this UI.
    private func attachFadeSubmenu(to menu: NSMenu, segmentID: UUID, currentFade: Double) {
        let parent = NSMenuItem(title: L("Fade"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        // Presets in seconds. 0 = hard cut. Matching tolerance of 0.02s for the
        // checkmark comparison so drift from prior auto-fade values still shows
        // the "right" item as active.
        let presets: [Double] = [0, 0.15, 0.35, 0.5, 1.0]
        for seconds in presets {
            let title: String = (seconds == 0)
                ? L("None")
                : (seconds == 1.0 ? "1s" : String(format: "%.2fs", seconds))
            let item = NSMenuItem(title: title,
                                  action: #selector(handleSetFadeFromMenu(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = FadeMenuContext(segmentID: segmentID, seconds: seconds)
            item.state = (abs(currentFade - seconds) < 0.02) ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        menu.addItem(parent)
    }

    private func showAddEffectMenu(at point: NSPoint, clickTime: Double) {
        let menu = NSMenu()
        let zoomItem = NSMenuItem(title: L("Add Zoom"),
                                  action: #selector(handleAddZoomFromMenu(_:)),
                                  keyEquivalent: "")
        zoomItem.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: nil)
        zoomItem.target = self
        if let g = zoomGapAtClickTime(clickTime) {
            zoomItem.representedObject = AddEffectContext(clickTime: clickTime, gapStart: g.0, gapEnd: g.1)
            zoomItem.isEnabled = true
        } else {
            zoomItem.isEnabled = false
        }
        menu.addItem(zoomItem)

        let censorItem = NSMenuItem(title: L("Add Censor"),
                                    action: #selector(handleAddCensorFromMenu(_:)),
                                    keyEquivalent: "")
        censorItem.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        censorItem.target = self
        censorItem.representedObject = AddEffectContext(clickTime: clickTime, gapStart: 0, gapEnd: duration)
        menu.addItem(censorItem)

        let cutItem = NSMenuItem(title: L("Add Cut"),
                                 action: #selector(handleAddCutFromMenu(_:)),
                                 keyEquivalent: "")
        cutItem.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)
        cutItem.target = self
        cutItem.representedObject = AddEffectContext(clickTime: clickTime, gapStart: 0, gapEnd: duration)
        menu.addItem(cutItem)

        let speedItem = NSMenuItem(title: L("Add Speed"),
                                    action: #selector(handleAddSpeedFromMenu(_:)),
                                    keyEquivalent: "")
        speedItem.image = NSImage(systemSymbolName: "forward.fill", accessibilityDescription: nil)
        speedItem.target = self
        if let g = speedGapAtClickTime(clickTime) {
            speedItem.representedObject = AddEffectContext(clickTime: clickTime, gapStart: g.0, gapEnd: g.1)
            speedItem.isEnabled = true
        } else {
            speedItem.isEnabled = false
        }
        menu.addItem(speedItem)

        menu.popUp(positioning: nil, at: point, in: self)
    }

    private func attachAddEffectSubmenu(to menu: NSMenu, event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let clickTime = Double((p.x - row0Rect.minX) / max(row0Rect.width, 1)) * duration
        let parent = NSMenuItem(title: L("Add effect"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let zoomGap = zoomGapAtClickTime(clickTime)
        let zoomItem = NSMenuItem(title: L("Add Zoom"),
                                  action: #selector(handleAddZoomFromMenu(_:)),
                                  keyEquivalent: "")
        zoomItem.target = self
        if let g = zoomGap {
            zoomItem.representedObject = AddEffectContext(clickTime: clickTime, gapStart: g.0, gapEnd: g.1)
            zoomItem.isEnabled = true
        } else {
            zoomItem.isEnabled = false
        }
        sub.addItem(zoomItem)
        let censorItem = NSMenuItem(title: L("Add Censor"),
                                    action: #selector(handleAddCensorFromMenu(_:)),
                                    keyEquivalent: "")
        censorItem.target = self
        censorItem.representedObject = AddEffectContext(clickTime: clickTime, gapStart: 0, gapEnd: duration)
        sub.addItem(censorItem)
        let cutItem = NSMenuItem(title: L("Add Cut"),
                                 action: #selector(handleAddCutFromMenu(_:)),
                                 keyEquivalent: "")
        cutItem.target = self
        cutItem.representedObject = AddEffectContext(clickTime: clickTime, gapStart: 0, gapEnd: duration)
        sub.addItem(cutItem)
        let speedItem = NSMenuItem(title: L("Add Speed"),
                                    action: #selector(handleAddSpeedFromMenu(_:)),
                                    keyEquivalent: "")
        speedItem.target = self
        if let g = speedGapAtClickTime(clickTime) {
            speedItem.representedObject = AddEffectContext(clickTime: clickTime, gapStart: g.0, gapEnd: g.1)
            speedItem.isEnabled = true
        } else {
            speedItem.isEnabled = false
        }
        sub.addItem(speedItem)
        parent.submenu = sub
        menu.addItem(parent)
    }

    /// Returns the (start, end) of the speed-free interval containing `t`,
    /// or nil if `t` is inside an existing speed segment. Same logic as
    /// `zoomGapAtClickTime` so the UI refuses to place overlapping speeds.
    private func speedGapAtClickTime(_ t: Double) -> (Double, Double)? {
        guard duration > 0 else { return nil }
        let speeds = speedSegments
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
        var cursor: Double = 0
        for s in speeds {
            if s.startTime > cursor + 0.001 {
                if t >= cursor && t <= s.startTime
                    && (s.startTime - cursor) >= 0.3 {
                    return (cursor, s.startTime)
                }
            }
            cursor = max(cursor, s.endTime)
        }
        if cursor < duration - 0.001 && t >= cursor && t <= duration
            && (duration - cursor) >= 0.3 {
            return (cursor, duration)
        }
        return nil
    }

    /// Returns the (start, end) of the zoom-free interval containing `t`, or
    /// nil if `t` is inside a zoom segment.
    private func zoomGapAtClickTime(_ t: Double) -> (Double, Double)? {
        guard duration > 0 else { return nil }
        let zooms = zoomSegments
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
        var cursor: Double = 0
        for z in zooms {
            if z.startTime > cursor + 0.001 {
                if t >= cursor && t <= z.startTime
                    && (z.startTime - cursor) >= VideoZoomSegment.minDuration {
                    return (cursor, z.startTime)
                }
            }
            cursor = max(cursor, z.endTime)
        }
        if cursor < duration - 0.001 && t >= cursor && t <= duration
            && (duration - cursor) >= VideoZoomSegment.minDuration {
            return (cursor, duration)
        }
        return nil
    }

    // MARK: - Menu callbacks

    @objc private func handleDeleteSelectedFromMenu() {
        guard let id = selectedSegmentID else { return }
        removeSegment(id: id)
    }

    @objc private func handleSetCensorStyleFromMenu(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? CensorStyleMenuContext,
              let seg = censorSegments.first(where: { $0.id == ctx.segmentID }) else { return }
        seg.style = ctx.style
        delegate?.effectsBandDidMutate(self)
        needsDisplay = true
    }

    @objc private func handleSetFadeFromMenu(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? FadeMenuContext else { return }
        if let seg = zoomSegments.first(where: { $0.id == ctx.segmentID }) {
            seg.fadeIn = ctx.seconds
            seg.fadeOut = ctx.seconds
        } else if let seg = censorSegments.first(where: { $0.id == ctx.segmentID }) {
            seg.fadeIn = ctx.seconds
            seg.fadeOut = ctx.seconds
        } else {
            return
        }
        delegate?.effectsBandDidMutate(self)
        needsDisplay = true
    }

    @objc private func handleAddZoomFromMenu(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? AddEffectContext else { return }
        addZoomSegment(clickTime: ctx.clickTime, gapStart: ctx.gapStart, gapEnd: ctx.gapEnd)
    }

    @objc private func handleAddCensorFromMenu(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? AddEffectContext else { return }
        addCensorSegment(clickTime: ctx.clickTime)
    }

    @objc private func handleAddCutFromMenu(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? AddEffectContext else { return }
        addCutSegment(clickTime: ctx.clickTime)
    }

    @objc private func handleAddSpeedFromMenu(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? AddEffectContext else { return }
        addSpeedSegment(clickTime: ctx.clickTime, gapStart: ctx.gapStart, gapEnd: ctx.gapEnd)
    }

    @objc private func handleSetSpeedFactorFromMenu(_ sender: NSMenuItem) {
        guard let ctx = sender.representedObject as? SpeedFactorMenuContext,
              let seg = speedSegments.first(where: { $0.id == ctx.segmentID }) else { return }
        let newFactor = VideoSpeedSegment.clampFactor(ctx.factor)
        // Respect the composition-duration floor. If the new factor would
        // shrink the piece below min, shorten the source range so comp
        // duration stays at the floor.
        let minSrcDur = VideoSpeedSegment.minCompDuration * newFactor
        if seg.sourceDuration < minSrcDur {
            seg.endTime = min(duration, seg.startTime + minSrcDur)
        }
        seg.speedFactor = newFactor
        delegate?.effectsBandDidMutate(self)
        needsDisplay = true
    }

    private func addZoomSegment(clickTime: Double, gapStart: Double, gapEnd: Double) {
        guard duration > 0 else { return }
        let gapDuration = gapEnd - gapStart
        guard gapDuration >= VideoZoomSegment.minDuration else {
            delegate?.effectsBand(self, showStatus: L("Not enough room here"), isError: true)
            return
        }
        let segDuration = min(2.0, gapDuration)
        var start = clickTime - segDuration / 2
        start = max(gapStart, min(gapEnd - segDuration, start))
        let seg = VideoZoomSegment(startTime: start, endTime: start + segDuration,
                                    zoomLevel: 2.0, center: CGPoint(x: 0.5, y: 0.5))
        zoomSegments.append(seg)
        selectedSegmentID = seg.id
        relayoutAndNotify()
    }

    private func addCensorSegment(clickTime: Double) {
        guard duration > 0 else { return }
        let segDuration = min(2.0, max(VideoCensorSegment.minDuration, duration))
        var start = clickTime - segDuration / 2
        start = max(0, min(duration - segDuration, start))
        let seg = VideoCensorSegment(startTime: start, endTime: start + segDuration, style: .blur)
        censorSegments.append(seg)
        selectedSegmentID = seg.id
        relayoutAndNotify()
    }

    private func addCutSegment(clickTime: Double) {
        guard duration > 0 else { return }
        let segDuration = min(1.0, max(VideoCutSegment.minDuration, duration))
        var start = clickTime - segDuration / 2
        start = max(0, min(duration - segDuration, start))
        let seg = VideoCutSegment(startTime: start, endTime: start + segDuration)
        cutSegments.append(seg)
        selectedSegmentID = seg.id
        relayoutAndNotify()
    }

    private func addSpeedSegment(clickTime: Double, gapStart: Double, gapEnd: Double) {
        guard duration > 0 else { return }
        let gapDuration = gapEnd - gapStart
        let defaultFactor: Double = 2.0
        let minSrcDur = VideoSpeedSegment.minCompDuration * defaultFactor
        guard gapDuration >= minSrcDur else {
            delegate?.effectsBand(self, showStatus: L("Not enough room here"), isError: true)
            return
        }
        // Default: 2s of source at 2× (so the pill takes up 2s visually on
        // the timeline but plays in 1s). Clamp to gap.
        let segDuration = min(2.0, gapDuration)
        var start = clickTime - segDuration / 2
        start = max(gapStart, min(gapEnd - segDuration, start))
        let seg = VideoSpeedSegment(startTime: start, endTime: start + segDuration, speedFactor: defaultFactor)
        speedSegments.append(seg)
        selectedSegmentID = seg.id
        relayoutAndNotify()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // Delete / Forward-Delete
            if let id = selectedSegmentID {
                removeSegment(id: id)
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Menu context carriers

    private final class AddEffectContext: NSObject {
        let clickTime: Double
        let gapStart: Double
        let gapEnd: Double
        init(clickTime: Double, gapStart: Double, gapEnd: Double) {
            self.clickTime = clickTime
            self.gapStart = gapStart
            self.gapEnd = gapEnd
        }
    }

    private final class CensorStyleMenuContext: NSObject {
        let segmentID: UUID
        let style: VideoCensorSegment.Style
        init(segmentID: UUID, style: VideoCensorSegment.Style) {
            self.segmentID = segmentID
            self.style = style
        }
    }

    private final class FadeMenuContext: NSObject {
        let segmentID: UUID
        let seconds: Double
        init(segmentID: UUID, seconds: Double) {
            self.segmentID = segmentID
            self.seconds = seconds
        }
    }

    private final class SpeedFactorMenuContext: NSObject {
        let segmentID: UUID
        let factor: Double
        init(segmentID: UUID, factor: Double) {
            self.segmentID = segmentID
            self.factor = factor
        }
    }
}
