import Cocoa

/// Image-edge index for "boundary snap" — snapping the capture selection's
/// dragged edges to strong color boundaries (UI lines, window borders, table
/// rows, etc.) in the captured screenshot, like CleanShot X + PixelSnap.
///
/// Built ONCE per screenshot (off the main thread). During a resize drag the
/// lookup is a cheap scan over a small ±radius window, scored only across the
/// selection's perpendicular span so it snaps to edges that actually run along
/// the dragged side — not unrelated lines elsewhere on screen.
///
/// All "boundary" indices are between-pixel positions: vertical boundary `b`
/// (0…width) sits between pixel columns `b-1` and `b`; horizontal boundary `b`
/// (0…height) sits between rows `b-1` and `b`. Boundary 0 and width/height are
/// the image edges (no diff), so the usable range is 1…dim-1.
struct BoundarySnapIndex {
    let width: Int
    let height: Int
    /// drawRect the screenshot was drawn into (overlay-space). Used to map
    /// view points ↔ image pixels.
    let drawRect: NSRect

    /// Per-pixel vertical edge strength: difference between column x-1 and x.
    /// Indexed `[y * (width + 1) + xBoundary]`, xBoundary in 1…width-1.
    private let verticalDiff: [Float]
    /// Per-pixel horizontal edge strength: difference between row y-1 and y.
    /// Indexed `[yBoundary * width + x]`, yBoundary in 1…height-1.
    private let horizontalDiff: [Float]

    /// A qualifying snap target.
    struct Hit {
        let viewPosition: CGFloat   // overlay-space coordinate to snap the edge to
        let pixelBoundary: Int
        let strength: Float
    }

    // Tuning. An edge qualifies when its mean color difference along the
    // selection span clears `minMeanDiff` AND it's covered along a good fraction
    // of that span (so a single stray high-contrast pixel doesn't count).
    private static let minMeanDiff: Float = 28      // 0…~441 (RGB euclidean)
    private static let minSupportFraction: Float = 0.55

    // MARK: - Build

    /// Build the index from a screenshot CGImage drawn into `drawRect`.
    /// Returns nil for degenerate images. Safe to call off the main thread.
    static func build(from cgImage: CGImage, drawRect: NSRect) -> BoundarySnapIndex? {
        let w = cgImage.width
        let h = cgImage.height
        guard w >= 2, h >= 2, drawRect.width > 0, drawRect.height > 0 else { return nil }
        // Cap work on huge displays (e.g. 6K) — downscaling isn't needed; the
        // arrays are O(pixels) which is fine up to ~20MP. Bail only if absurd.
        guard w * h <= 40_000_000 else { return nil }

        // Render into a known RGBA8 buffer so component access is predictable.
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = pixels.withUnsafeMutableBytes({ ptr -> CGContext? in
            CGContext(
                data: ptr.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        var vDiff = [Float](repeating: 0, count: h * (w + 1))
        var hDiff = [Float](repeating: 0, count: (h) * w)

        pixels.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            // Vertical boundaries: |column x - column x-1| per row.
            for y in 0..<h {
                let row = y * bytesPerRow
                let vBase = y * (w + 1)
                for x in 1..<w {
                    let a = row + (x - 1) * 4
                    let b = row + x * 4
                    vDiff[vBase + x] = colorDist(p, a, b)
                }
            }
            // Horizontal boundaries: |row y - row y-1| per column.
            for y in 1..<h {
                let rowA = (y - 1) * bytesPerRow
                let rowB = y * bytesPerRow
                let hBase = y * w
                for x in 0..<w {
                    let a = rowA + x * 4
                    let b = rowB + x * 4
                    hDiff[hBase + x] = colorDist(p, a, b)
                }
            }
        }

        return BoundarySnapIndex(
            width: w, height: h, drawRect: drawRect,
            verticalDiff: vDiff, horizontalDiff: hDiff)
    }

    @inline(__always)
    private static func colorDist(_ p: UnsafePointer<UInt8>, _ a: Int, _ b: Int) -> Float {
        let dr = Float(Int(p[a]) - Int(p[b]))
        let dg = Float(Int(p[a + 1]) - Int(p[b + 1]))
        let db = Float(Int(p[a + 2]) - Int(p[b + 2]))
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    // MARK: - Coordinate mapping

    private var scaleX: CGFloat { CGFloat(width) / drawRect.width }
    private var scaleY: CGFloat { CGFloat(height) / drawRect.height }

    /// overlay-space X → pixel boundary (rounded, clamped to 0…width).
    private func pixelX(_ viewX: CGFloat) -> Int {
        max(0, min(width, Int((((viewX - drawRect.minX) * scaleX)).rounded())))
    }
    /// overlay-space Y → pixel boundary (Y flipped; rounded, clamped 0…height).
    private func pixelY(_ viewY: CGFloat) -> Int {
        max(0, min(height, Int((((drawRect.maxY - viewY) * scaleY)).rounded())))
    }
    private func viewXOf(boundary b: Int) -> CGFloat { drawRect.minX + CGFloat(b) / scaleX }
    private func viewYOf(boundary b: Int) -> CGFloat { drawRect.maxY - CGFloat(b) / scaleY }

    // MARK: - Lookup

    /// Find the nearest strong VERTICAL image boundary to `viewX`, scoring edge
    /// strength along the selection's [yMinView, yMaxView] span. `radiusPoints`
    /// is the snap radius in overlay points.
    func nearestVertical(toViewX viewX: CGFloat, yMinView: CGFloat, yMaxView: CGFloat,
                         radiusPoints: CGFloat) -> Hit? {
        let center = pixelX(viewX)
        let radiusPx = max(1, Int((radiusPoints * scaleX).rounded()))
        var y0 = pixelY(max(yMinView, yMaxView))   // larger view-Y → smaller pixel-Y
        var y1 = pixelY(min(yMinView, yMaxView))
        if y0 > y1 { swap(&y0, &y1) }
        y0 = max(0, y0); y1 = min(height - 1, y1)
        guard y1 >= y0 else { return nil }
        let span = y1 - y0 + 1

        var best: Hit?
        var bestDist = Int.max
        let lo = max(1, center - radiusPx)
        let hi = min(width - 1, center + radiusPx)
        guard lo <= hi else { return nil }
        for b in lo...hi {
            var sum: Float = 0
            var support = 0
            for y in y0...y1 {
                let d = verticalDiff[y * (width + 1) + b]
                sum += d
                if d >= Self.minMeanDiff { support += 1 }
            }
            let mean = sum / Float(span)
            let supportFrac = Float(support) / Float(span)
            guard mean >= Self.minMeanDiff, supportFrac >= Self.minSupportFraction else { continue }
            // Prefer a true local maximum (sharper than its neighbours).
            let dist = abs(b - center)
            if dist < bestDist {
                bestDist = dist
                best = Hit(viewPosition: viewXOf(boundary: b), pixelBoundary: b, strength: mean)
            }
        }
        return best
    }

    /// Find the nearest strong HORIZONTAL image boundary to `viewY`, scoring edge
    /// strength along the selection's [xMinView, xMaxView] span.
    func nearestHorizontal(toViewY viewY: CGFloat, xMinView: CGFloat, xMaxView: CGFloat,
                           radiusPoints: CGFloat) -> Hit? {
        let center = pixelY(viewY)
        let radiusPx = max(1, Int((radiusPoints * scaleY).rounded()))
        var x0 = pixelX(min(xMinView, xMaxView))
        var x1 = pixelX(max(xMinView, xMaxView))
        x0 = max(0, x0); x1 = min(width - 1, x1)
        guard x1 >= x0 else { return nil }
        let span = x1 - x0 + 1

        var best: Hit?
        var bestDist = Int.max
        let lo = max(1, center - radiusPx)
        let hi = min(height - 1, center + radiusPx)
        guard lo <= hi else { return nil }
        for b in lo...hi {
            var sum: Float = 0
            var support = 0
            let base = b * width
            for x in x0...x1 {
                let d = horizontalDiff[base + x]
                sum += d
                if d >= Self.minMeanDiff { support += 1 }
            }
            let mean = sum / Float(span)
            let supportFrac = Float(support) / Float(span)
            guard mean >= Self.minMeanDiff, supportFrac >= Self.minSupportFraction else { continue }
            let dist = abs(b - center)
            if dist < bestDist {
                bestDist = dist
                best = Hit(viewPosition: viewYOf(boundary: b), pixelBoundary: b, strength: mean)
            }
        }
        return best
    }
}
