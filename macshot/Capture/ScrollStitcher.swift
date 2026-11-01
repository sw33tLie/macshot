import CoreGraphics
import Foundation

/// Builds the tall image of a scroll capture from successive frames.
///
/// Each frame is aligned with the last one stitched from (`ScrollFrameMatcher`)
/// and only the rows it shows for the first time are appended, taken from just
/// above anything pinned at the bottom. What doesn't scroll appears once:
/// a header in the first frame at the top, fixed sidebars in the first frame
/// only (filled with their background below it), and a pinned bottom banner
/// at the very end. A region that changes on its own (a playing video, an
/// animation) is pasted whole from one frame once fully visible, instead of
/// being assembled from strips taken at different moments. Scrolling back up
/// is tracked, so those rows aren't added twice when the page comes down
/// again.
///
/// Free of capture and timing so it can be driven by synthetic frames in tests.
final class ScrollStitcher {

    enum Outcome: Equatable {
        /// New rows were added to the image.
        case appended
        /// The frame shows exactly what the reference showed.
        case noMovement
        /// Moved, but nothing new to add yet (too small, or scrolled back up).
        case pending
        /// The frame couldn't be aligned with the reference.
        case noMatch
    }

    /// The stitched image so far, without the held-back bottom banner.
    private(set) var image: CGImage
    /// Strips appended after the first frame.
    private(set) var appendedStrips = 0

    /// When false ("Detect sticky headers" off), every frame is stitched as
    /// captured: no sidebar filling and no held-back banner.
    private let handlesPinnedContent: Bool

    private var reference: CGImage
    private var referenceSamples: ScrollFrameMatcher.Samples?

    // Fixed by the first downward match, so every strip lines up.
    private var geometryDecided = false
    private var bottomRows = 0
    /// A larger pinned bottom seen in the previous pair; adopted when the next
    /// pair agrees (a consent panel can settle after the first frames).
    private var pendingBottomRows = 0
    /// Regions that change on their own (videos, animations), in image
    /// coordinates (top-left origin). Grown as more of a video is seen, and
    /// pasted whole from the latest frame that shows them completely.
    private var dynamicRegions: [CGRect] = []
    /// Per pixel column, a running vote between "a fixed sidebar" (positive)
    /// and "content that scrolls" (negative). One frame pair can misjudge a
    /// column (a gutter of line numbers that happened to look still, or a
    /// stretch of a file tree with no text in the rows that pair looked at);
    /// the history decides.
    private var sideScores: [Float] = []
    private var finished = false

    /// Rows scrolled back up that must come down again before anything new.
    private var rowsToRevisit = 0
    private var lastShift = 0
    private var consecutiveFailures = 0
    /// A reference that can't be matched for this many frames was outrun;
    /// start again from the current frame (leaving a gap).
    static let reanchorAfterFailures = 8

    init(firstFrame: CGImage, handlesPinnedContent: Bool = true) {
        image = firstFrame
        reference = firstFrame
        referenceSamples = ScrollFrameMatcher.samples(of: firstFrame)
        self.handlesPinnedContent = handlesPinnedContent
    }

    /// Aligns `frame` with the reference and appends the rows it reveals.
    @discardableResult
    func add(_ frame: CGImage) -> Outcome {
        guard !finished else { return .pending }
        guard let referenceSamples, frame.width == reference.width, frame.height == reference.height,
              let samples = ScrollFrameMatcher.samples(of: frame) else {
            reference = frame
            self.referenceSamples = ScrollFrameMatcher.samples(of: frame)
            return .noMatch
        }
        guard let match = ScrollFrameMatcher.match(previous: referenceSamples, current: samples, hint: lastShift, pinnedBottom: bottomRows) else {
            // Keep the reference: a transient mismatch (an animation, a blank
            // stretch) usually resolves on a later frame.
            consecutiveFailures += 1
            if consecutiveFailures >= Self.reanchorAfterFailures {
                consecutiveFailures = 0
                reference = frame
                self.referenceSamples = samples
            }
            return .noMatch
        }
        consecutiveFailures = 0
        if match.shift == 0 { return .noMovement }
        // Let small moves accumulate against the same reference: fewer seams,
        // and one exact large shift beats many small ones.
        guard abs(match.shift) >= max(6, frame.height / 24) else { return .pending }

        lastShift = match.shift
        reference = frame
        self.referenceSamples = samples
        if match.shift < 0 {
            rowsToRevisit += -match.shift
            return .pending
        }
        if !geometryDecided { decideGeometry(match) } else { growPinnedBottom(match) }
        let revisited = min(rowsToRevisit, match.shift)
        rowsToRevisit -= revisited
        let newRows = min(match.shift - revisited, frame.height - bottomRows)
        guard newRows > 0,
              let strip = frame.cropping(to: CGRect(x: 0, y: frame.height - bottomRows - newRows,
                                                    width: frame.width, height: newRows)) else { return .pending }
        let sides = handlesPinnedContent ? sideFill(for: match, width: frame.width).compactMap { columns in
            Self.backgroundColor(of: frame, columns: columns, rows: 0..<(frame.height - bottomRows)).map { (columns, $0) }
        } : []
        // After this append, the frame's row (height - bottomRows) is the bottom
        // of the image, which places every visible row of the frame. Pasting
        // needs that exact mapping, so skip it while revisiting.
        let frameBottom = frame.height - bottomRows
        let frameTop = image.height + newRows - frameBottom
        var pastes: [CGRect] = []
        if revisited == 0 {
            for rect in match.dynamicRects where rect.maxY <= CGFloat(frameBottom) {
                trackRegion(rect.offsetBy(dx: 0, dy: CGFloat(frameTop)))
            }
            // Never in the top eighth of the frame either: a translucent navbar
            // over a dark page can match by chance, so it isn't always in the
            // detected edge band, and a paste there drops it mid-image.
            let topGuard = max(match.followingRows.lowerBound, frameBottom / 8)
            let following = CGFloat(topGuard)...CGFloat(min(match.followingRows.upperBound, frameBottom))
            pastes = dynamicRegions.compactMap { region in
                let inFrame = region.offsetBy(dx: 0, dy: CGFloat(-frameTop))
                guard following.contains(inFrame.minY), following.contains(inFrame.maxY),
                      // Never into columns this strip treats as a fixed sidebar.
                      !match.fixedSides.contains(where: { CGFloat($0.lowerBound) < inFrame.maxX && CGFloat($0.upperBound) > inFrame.minX })
                else { return nil }
                return inFrame
            }
        }
        append(strip, sides: sides, pastes: pastes, from: frame, frameBottom: frameBottom,
               followingRows: max(frameBottom / 8, match.followingRows.lowerBound)..<min(frameBottom, match.followingRows.upperBound))
        appendedStrips += 1
        return .appended
    }

    /// The finished image: adds the held-back bottom banner, once.
    func finish() -> CGImage {
        if !finished, geometryDecided, bottomRows > 0,
           let strip = reference.cropping(to: CGRect(x: 0, y: reference.height - bottomRows,
                                                     width: reference.width, height: bottomRows)) {
            append(strip, sides: [], pastes: [], from: reference, frameBottom: 0, followingRows: 0..<0)
        }
        finished = true
        return image
    }

    /// Columns to plain-fill in this strip: those this pair judges fixed,
    /// unless their recent history says they scroll (a gutter of line numbers
    /// that looked still for one pair). Every pair votes on every column, so
    /// an early misjudgement (a consent panel before it was recognised as
    /// pinned) fades instead of filling that strip for the rest of the capture.
    private func sideFill(for match: ScrollFrameMatcher.Match, width: Int) -> [Range<Int>] {
        if sideScores.count != width { sideScores = Array(repeating: 0, count: width) }
        var fixedNow = [Bool](repeating: false, count: width)
        for range in match.fixedSides {
            for x in max(0, range.lowerBound)..<min(width, range.upperBound) { fixedNow[x] = true }
        }
        var fill = [Bool](repeating: false, count: width)
        for x in 0..<width {
            let previous = sideScores[x]
            sideScores[x] = 0.5 * previous + (fixedNow[x] ? 0.5 : -0.5)
            fill[x] = fixedNow[x] && previous > -0.6
        }
        var ranges: [Range<Int>] = []
        var start: Int?
        for x in 0...width {
            if x < width, fill[x] {
                if start == nil { start = x }
            } else if let first = start {
                ranges.append(first..<x)
                start = nil
            }
        }
        return ranges
    }

    /// Adds a dynamic region, merging it with any it overlaps or nearly touches.
    private func trackRegion(_ rect: CGRect) {
        var merged = rect
        var others: [CGRect] = []
        for region in dynamicRegions {
            if region.insetBy(dx: -16, dy: -16).intersects(merged) { merged = merged.union(region) } else { others.append(region) }
        }
        dynamicRegions = others + [merged]
    }

    /// Grows the held-back bottom when two consecutive pairs see more pinned
    /// rows than assumed. Never shrinks: a banner that disappears just costs
    /// a little of each strip. The rows between the old and new cutoff are
    /// already in the image, so they are revisited rather than added again.
    private func growPinnedBottom(_ match: ScrollFrameMatcher.Match) {
        guard handlesPinnedContent else { return }
        let seen = match.staticBottomRows
        defer { pendingBottomRows = seen > bottomRows ? seen : 0 }
        guard seen > bottomRows, pendingBottomRows > bottomRows else { return }
        let grown = min(seen, pendingBottomRows)
        rowsToRevisit += grown - bottomRows
        bottomRows = grown
    }

    private func decideGeometry(_ match: ScrollFrameMatcher.Match) {
        geometryDecided = true
        guard handlesPinnedContent else { return }
        let first = image
        bottomRows = match.staticBottomRows
        // The first frame's own banner is replaced by the final frame's at the end.
        if bottomRows > 0,
           let trimmed = first.cropping(to: CGRect(x: 0, y: 0, width: first.width, height: first.height - bottomRows)) {
            image = trimmed
        }
    }

    /// The most common colour in `columns` of `image`: a sidebar's background.
    /// Colours are bucketed to find the mode, then averaged within it so a
    /// plain white or black background is reproduced exactly.
    static func backgroundColor(of image: CGImage, columns: Range<Int>, rows: Range<Int>? = nil) -> CGColor? {
        guard let frame = ScrollFrameAnalyzer.frame(for: image), !columns.isEmpty else { return nil }
        let rows = rows.flatMap { $0.isEmpty ? nil : $0 } ?? 0..<image.height
        var buckets: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        let columnStep = max(1, columns.count / 24), rowStep = max(1, rows.count / 64)
        for y in stride(from: rows.lowerBound, to: rows.upperBound, by: rowStep) {
            for x in stride(from: columns.lowerBound, to: min(columns.upperBound, image.width), by: columnStep) {
                guard let offset = frame.offset(x: x, y: y) else { continue }
                let red = Int(frame.bytes[offset + frame.redOffset])
                let green = Int(frame.bytes[offset + frame.greenOffset])
                let blue = Int(frame.bytes[offset + frame.blueOffset])
                let key = ((red >> 3) << 10) | ((green >> 3) << 5) | (blue >> 3)
                let sum = buckets[key] ?? (0, 0, 0, 0)
                buckets[key] = (sum.count + 1, sum.red + red, sum.green + green, sum.blue + blue)
            }
        }
        guard let mode = buckets.values.max(by: { $0.count < $1.count }) else { return nil }
        func channel(_ total: Int) -> CGFloat { CGFloat((Double(total) / Double(mode.count)).rounded()) / 255 }
        return CGColor(srgbRed: channel(mode.red), green: channel(mode.green), blue: channel(mode.blue), alpha: 1)
    }

    /// Appends `strip`, plain-filling fixed `sides` in it, then pastes the
    /// `pastes` rectangles of `frame` over the image where the frame row
    /// `frameBottom` lands at the new bottom. A paste is first grown until the
    /// rows and columns around it match the image (a real video sits in
    /// content that already lines up); anything that can't be closed off that
    /// way (content moving at another rate) isn't pasted.
    private func append(_ strip: CGImage, sides: [(columns: Range<Int>, color: CGColor)],
                        pastes: [CGRect], from frame: CGImage, frameBottom: Int, followingRows: Range<Int>) {
        let existing = image
        guard existing.width == strip.width else { return }
        let width = existing.width
        let totalHeight = existing.height + strip.height
        let colorSpace = existing.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: totalHeight, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo) else { return }
        // CGContext has a bottom-left origin: the existing image goes on top.
        context.draw(existing, in: CGRect(x: 0, y: strip.height, width: width, height: existing.height))
        context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: strip.height))
        for side in sides {
            context.setFillColor(side.color)
            context.fill(CGRect(x: side.columns.lowerBound, y: 0, width: side.columns.count, height: strip.height))
        }
        // Frame row r sits at image row (totalHeight - frameBottom + r).
        let frameTop = totalHeight - frameBottom
        if !pastes.isEmpty, frameTop >= 0, let pixels = ScrollFrameAnalyzer.frame(for: frame),
           let canvas = context.data?.assumingMemoryBound(to: UInt8.self) {
            let stride = context.bytesPerRow
            // The canvas is BGRA in memory, rows from the top.
            func luma(canvasRow: Int, x: Int) -> Int {
                let o = canvasRow * stride + x * 4
                return (Int(canvas[o + 2]) * 299 + Int(canvas[o + 1]) * 587 + Int(canvas[o]) * 114) / 1000
            }
            func luma(frameRow: Int, x: Int) -> Int? {
                guard let o = pixels.offset(x: x, y: frameRow) else { return nil }
                return (Int(pixels.bytes[o + pixels.redOffset]) * 299 + Int(pixels.bytes[o + pixels.greenOffset]) * 587
                        + Int(pixels.bytes[o + pixels.blueOffset]) * 114) / 1000
            }
            /// Mean difference between the frame and the image over a band of
            /// frame rows/columns, or nil if it falls outside both.
            func mismatch(rows: Range<Int>, columns: Range<Int>) -> Bool? {
                let rowStep = max(1, rows.count / 8), columnStep = max(1, columns.count / 64)
                var difference = 0, samples = 0
                for row in Swift.stride(from: rows.lowerBound, to: rows.upperBound, by: rowStep) {
                    guard row >= 0, row < frameBottom, frameTop + row < totalHeight else { continue }
                    for x in Swift.stride(from: columns.lowerBound, to: columns.upperBound, by: columnStep)
                        where x >= 0 && x < width {
                        guard let value = luma(frameRow: row, x: x) else { continue }
                        difference += abs(value - luma(canvasRow: frameTop + row, x: x))
                        samples += 1
                    }
                }
                guard samples >= 8 else { return nil }
                return difference > samples * 3
            }
            /// Whether a band of frame rows holds text or edges, not plain colour.
            func hasDetail(rows: Range<Int>, columns: Range<Int>) -> Bool {
                let columnStep = max(1, columns.count / 96)
                for row in rows where row >= 0 && row < frameBottom {
                    var low = 255, high = 0
                    for x in Swift.stride(from: columns.lowerBound, to: columns.upperBound, by: columnStep) {
                        guard let value = luma(frameRow: row, x: x) else { continue }
                        low = min(low, value); high = max(high, value)
                    }
                    if high - low > 40 { return true }
                }
                return false
            }
            /// Grows `rect` until the rows and columns just outside it match the
            /// image: a region seen only partly changing (a slow talking-head
            /// video) is widened to the whole video. Nil if that takes more than
            /// `limit` in any direction, or leaves the frame's following rows.
            func consistentRegion(_ rect: CGRect, following: Range<Int>) -> CGRect? {
                var top = Int(rect.minY), bottom = Int(rect.maxY), left = Int(rect.minX), right = Int(rect.maxX)
                // Up to half the frame each way: a portrait video can be most
                // of the frame tall, while only part of it changed.
                let limit = max(480, frameBottom / 2), step = 8, band = 6
                let start = (top, bottom, left, right)
                for _ in 0..<(limit / step) {
                    var grew = false
                    if mismatch(rows: (top - band)..<top, columns: left..<right) ?? false { top -= step; grew = true }
                    if mismatch(rows: bottom..<(bottom + band), columns: left..<right) ?? false { bottom += step; grew = true }
                    if mismatch(rows: top..<bottom, columns: (left - band)..<left) ?? false { left -= step; grew = true }
                    if mismatch(rows: top..<bottom, columns: right..<(right + band)) ?? false { right += step; grew = true }
                    if !grew { break }
                    guard top >= following.lowerBound, bottom <= following.upperBound, left >= 0, right <= width,
                          start.0 - top <= limit, bottom - start.1 <= limit,
                          start.2 - left <= limit, right - start.3 <= limit else { return nil }
                }
                // Still mismatched at the limit: not a self-contained region.
                if mismatch(rows: (top - band)..<top, columns: left..<right) ?? true { return nil }
                if mismatch(rows: bottom..<(bottom + band), columns: left..<right) ?? true { return nil }
                // Anchored to content: matching plain background above and below
                // proves nothing about where the region belongs.
                guard hasDetail(rows: (top - 2 * band)..<top, columns: left..<right)
                        || hasDetail(rows: bottom..<(bottom + 2 * band), columns: left..<right) else { return nil }
                return CGRect(x: left, y: top, width: right - left, height: bottom - top)
            }
            let accepted = pastes.compactMap { consistentRegion($0, following: followingRows) }
            for rect in accepted {
                guard let piece = frame.cropping(to: rect) else { continue }
                let top = frameTop + Int(rect.minY)
                context.draw(piece, in: CGRect(x: rect.minX, y: CGFloat(totalHeight - top) - rect.height,
                                               width: rect.width, height: rect.height))
            }
        }
        if let merged = context.makeImage() { image = merged }
    }
}
