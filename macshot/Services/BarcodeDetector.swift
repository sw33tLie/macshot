import Cocoa
import Vision

/// Detects barcodes/QR codes in a screenshot region and provides UI for the result.
/// Manages its own state — OverlayView just calls scan(), draw(), hitTest(), and reset().
class BarcodeDetector {

    private(set) var payload: String?
    private(set) var actionRects: [NSRect] = []  // [0] = primary action, [1] = dismiss
    private var scanTask: DispatchWorkItem?

    /// Scan the given region for barcodes. Calls completion on main thread when done.
    func scan(image: NSImage, selectionRect: NSRect, captureDrawRect: NSRect, completion: @escaping () -> Void) {
        cancel()

        guard selectionRect.width > 20, selectionRect.height > 20 else { return }

        let task = DispatchWorkItem { [weak self] in
            let regionImage = NSImage(size: selectionRect.size, flipped: false) { _ in
                image.draw(in: NSRect(x: -selectionRect.origin.x, y: -selectionRect.origin.y,
                                      width: captureDrawRect.width, height: captureDrawRect.height),
                           from: .zero, operation: .copy, fraction: 1.0)
                return true
            }

            guard let tiffData = regionImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let cgImage = bitmap.cgImage else { return }

            let request = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            let result = (request.results ?? [])
                .compactMap { $0.payloadStringValue }
                .first(where: { !$0.isEmpty })

            DispatchQueue.main.async { [weak self] in
                self?.payload = result
                completion()
            }
        }
        scanTask = task
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3, execute: task)
    }

    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        payload = nil
        actionRects = []
    }

    /// Draw the barcode badge. Returns true if something was drawn.
    func draw(selectionRect: NSRect, bottomBarRect: NSRect, viewBounds: NSRect) {
        guard let payload = payload else { return }
        let isURL = payload.hasPrefix("http://") || payload.hasPrefix("https://")

        let barH: CGFloat = 36
        let gap: CGFloat = 6
        let barW: CGFloat = max(320, min(selectionRect.width - 16, 420))
        let barX = max(viewBounds.minX + 4, min(selectionRect.midX - barW / 2, viewBounds.maxX - barW - 4))

        let belowY = selectionRect.minY - barH - gap
        let aboveY = selectionRect.maxY + gap
        let insideY = selectionRect.maxY - barH - gap

        let bottomBarOccupied = bottomBarRect != .zero
        let belowClear = belowY >= viewBounds.minY + 4 &&
            !(bottomBarOccupied && NSRect(x: barX, y: belowY, width: barW, height: barH).intersects(bottomBarRect))
        let aboveClear = aboveY + barH <= viewBounds.maxY - 4

        let finalBarY: CGFloat
        if belowClear { finalBarY = belowY }
        else if aboveClear { finalBarY = aboveY }
        else { finalBarY = insideY }

        let barRect = NSRect(x: barX, y: finalBarY, width: barW, height: barH)

        // Background pill
        NSColor(white: 0.12, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 10, yRadius: 10).fill()

        // QR icon + label
        let icon = isURL ? "🔗" : "📋"
        let shortPayload = payload.count > 45 ? String(payload.prefix(42)) + "…" : payload
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let labelStr = "\(icon)  \(shortPayload)" as NSString
        let labelSize = labelStr.size(withAttributes: labelAttrs)
        labelStr.draw(at: NSPoint(x: barRect.minX + 10, y: barRect.midY - labelSize.height / 2), withAttributes: labelAttrs)

        // Action button
        let btnTitle = isURL ? "Open" : "Copy"
        let btnAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let btnSize = (btnTitle as NSString).size(withAttributes: btnAttrs)
        let btnW = btnSize.width + 20
        let dismissW: CGFloat = 22

        let dismissRect = NSRect(x: barRect.maxX - dismissW - 4, y: barRect.minY + 4, width: dismissW, height: barH - 8)
        let actionRect = NSRect(x: dismissRect.minX - btnW - 6, y: barRect.minY + 4, width: btnW, height: barH - 8)

        NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: actionRect, xRadius: 6, yRadius: 6).fill()
        (btnTitle as NSString).draw(
            at: NSPoint(x: actionRect.midX - btnSize.width / 2, y: actionRect.midY - btnSize.height / 2),
            withAttributes: btnAttrs)

        let xAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 0.6, alpha: 1),
        ]
        let xStr = "✕" as NSString
        let xSize = xStr.size(withAttributes: xAttrs)
        xStr.draw(at: NSPoint(x: dismissRect.midX - xSize.width / 2, y: dismissRect.midY - xSize.height / 2),
                  withAttributes: xAttrs)

        actionRects = [actionRect, dismissRect]
    }

    /// Handle a click. Returns the action if hit, nil if not on the badge.
    enum Action { case open(String), copy(String), dismiss }

    func hitTest(point: NSPoint) -> Action? {
        guard let payload = payload, actionRects.count == 2 else { return nil }
        if actionRects[1].contains(point) { return .dismiss }
        if actionRects[0].contains(point) {
            let isURL = payload.hasPrefix("http://") || payload.hasPrefix("https://")
            return isURL ? .open(payload) : .copy(payload)
        }
        return nil
    }
}
