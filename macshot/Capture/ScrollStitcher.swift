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
    /// Height of the first frame in the image; repairs never reach into it.
    private var firstFrameRows = 0
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
    /// The first frame as captured, and the pixel columns where pastes landed
    /// in its rows. A region pasted there before its columns were known to be
    /// a sidebar (Wikipedia's contents collapsing a section while the header
    /// scrolls away) is put back as first seen once they are.
    private let firstFrame: CGImage
    private var pastedFirstFrameColumns: [Range<Int>] = []
    /// Where the mouse pointer was appended with a strip (image coordinates).
    /// The page scrolls out from under the pointer, so a later frame shows
    /// that content uncovered and it is copied over the pointer from there.
    private var pointerHoles: [CGRect] = []
    private var firstFramePointerChecked = false
    private var finished = false

    /// Rows scrolled back up that must come down again before anything new.
    private var rowsToRevisit = 0
    private var lastShift = 0
    /// Frames compared with the current reference so far: the expected shift
    /// grows with them while small moves accumulate or frames fail to match.
    private var framesSinceReference = 0
    private var consecutiveFailures = 0
    /// A reference that can't be matched for this many frames was outrun;
    /// start again from the current frame (leaving a gap).
    static let reanchorAfterFailures = 8

    init(firstFrame: CGImage, handlesPinnedContent: Bool = true) {
        image = firstFrame
        self.firstFrame = firstFrame
        firstFrameRows = firstFrame.height
        reference = firstFrame
        referenceSamples = ScrollFrameMatcher.samples(of: firstFrame)
        self.handlesPinnedContent = handlesPinnedContent
    }

    /// Aligns `frame` with the reference and appends the rows it reveals.
    @discardableResult
    /// - Parameter pointer: where the mouse pointer is in `frame` (pixels,
    ///   top-left origin), if the frames include it. It stays put while the
    ///   page scrolls under it, so it looks like a small changing region; it
    ///   must not be pasted into the image as one.
    func add(_ frame: CGImage, pointer: CGRect? = nil) -> Outcome {
        guard !finished else { return .pending }
        guard let referenceSamples, frame.width == reference.width, frame.height == reference.height,
              let samples = ScrollFrameMatcher.samples(of: frame) else {
            reference = frame
            self.referenceSamples = ScrollFrameMatcher.samples(of: frame)
            return .noMatch
        }
        framesSinceReference += 1
        let hint = lastShift > 0 ? lastShift * min(framesSinceReference, Self.reanchorAfterFailures) : lastShift
        guard let match = ScrollFrameMatcher.match(previous: referenceSamples, current: samples, hint: hint, pinnedBottom: bottomRows) else {
            // Keep the reference: a transient mismatch (an animation, a blank
            // stretch) usually resolves on a later frame.
            consecutiveFailures += 1
            if consecutiveFailures >= Self.reanchorAfterFailures {
                consecutiveFailures = 0
                reference = frame
                self.referenceSamples = samples
                framesSinceReference = 0
            }
            return .noMatch
        }
        consecutiveFailures = 0
        if match.shift == 0 { return .noMovement }
        // Let small moves accumulate against the same reference: fewer seams,
        // and one exact large shift beats many small ones.
        guard abs(match.shift) >= max(6, frame.height / 24) else { return .pending }

        lastShift = match.shift / max(1, framesSinceReference)
        if match.shift > 0, lastShift == 0 { lastShift = 1 }
        let previousFrame = reference
        reference = frame
        self.referenceSamples = samples
        framesSinceReference = 0
        if match.shift < 0 {
            rowsToRevisit += -match.shift
            return .pending
        }
        var grown = 0
        if !geometryDecided { decideGeometry(match) } else { grown = pinnedGrowth(match) }
        let revisited = min(rowsToRevisit, match.shift)
        rowsToRevisit -= revisited
        let newRows = min(match.shift - revisited, frame.height - bottomRows)
        guard newRows > 0,
              let strip = frame.cropping(to: CGRect(x: 0, y: frame.height - bottomRows - newRows,
                                                    width: frame.width, height: newRows)) else {
            if grown > 0 { rowsToRevisit += grown - bottomRows; bottomRows = grown }
            return .pending
        }
        let stripRows = (frame.height - bottomRows - newRows)..<(frame.height - bottomRows)
        let fill = handlesPinnedContent ? sideFill(for: match, width: frame.width, frameHeight: frame.height)
            : (judged: [], carried: [])
        let sides = handlesPinnedContent ? (fill.judged
            // Under a tall pinned panel sides are misjudged more easily; there,
            // fill only what stayed put. A side moving at its own rate (x.com's
            // right column catching up) must still be filled, as it is
            // elsewhere.
            .flatMap { columns in
                bottomRows * 2 > frame.height && !match.divergentSides.contains(where: { $0.overlaps(columns) })
                    ? Self.staticColumns(columns, rows: stripRows, frame: frame, previous: previousFrame) : [columns]
            }
            // A long-standing sidebar this pair missed is filled only if the
            // strip stayed put across it; content scrolling into those
            // columns (a footer once the sidebar ends, GitHub's file tree
            // growing) moved, and a partial fill would cut through its text.
            + fill.carried.filter { columns in
                // Under a tall panel, only a whole sidebar (Stack Overflow's
                // right column sticking at its end), never a sliver such as
                // a code box's edge, whose border column is still too.
                guard bottomRows * 2 <= frame.height || columns.count * 8 >= frame.width else { return false }
                let still = Self.staticColumns(columns, rows: stripRows, frame: frame, previous: previousFrame)
                return still.reduce(0) { $0 + $1.count } * 10 >= columns.count * 9
            })
            .compactMap { columns in
                Self.backgroundColor(of: frame, columns: columns, rows: 0..<(frame.height - bottomRows)).map { (columns, $0) }
            } : []
        // After this append, the frame's row (height - bottomRows) is the bottom
        // of the image, which places every visible row of the frame. Pasting
        // needs that exact mapping, so skip it while revisiting.
        let frameBottom = frame.height - bottomRows
        let frameTop = image.height + newRows - frameBottom
        var pastes: [CGRect] = [], patches: [CGRect] = []
        if revisited == 0 {
            // A change inside a sidebar that has stayed put (Wikipedia's
            // contents moving its highlight) is not a video in the page: a
            // region there would be pasted into the content further down.
            func mostlySticky(_ rect: CGRect) -> Bool {
                let low = max(0, Int(rect.minX)), high = min(sideScores.count, Int(rect.maxX.rounded(.up)))
                guard high > low else { return false }
                return sideScores[low..<high].filter { $0 > 0.2 }.count * 2 >= high - low
            }
            for rect in match.dynamicRects where rect.maxY <= CGFloat(frameBottom)
                && !mostlySticky(rect)
                && !(pointer.map { rect.intersects($0) && rect.width * rect.height < 4 * $0.width * $0.height } ?? false) {
                trackRegion(rect.offsetBy(dx: 0, dy: CGFloat(frameTop)))
            }
            // Never in the top eighth of the frame either: a translucent navbar
            // over a dark page can match by chance, so it isn't always in the
            // detected edge band, and a paste there drops it mid-image.
            let topGuard = max(match.followingRows.lowerBound, frameBottom / 8)
            let following = Self.clampedRows(topGuard, min(match.followingRows.upperBound, frameBottom))
            pastes = dynamicRegions.compactMap { region in
                let inFrame = region.offsetBy(dx: 0, dy: CGFloat(-frameTop))
                guard following.contains(inFrame.minY), following.contains(inFrame.maxY),
                      // Never a region holding the pointer: it would be stamped
                      // into the image again at every paste.
                      !(pointer.map { inFrame.intersects($0) } ?? false),
                      // Never into columns this strip treats as a fixed sidebar.
                      !match.fixedSides.contains(where: { CGFloat($0.lowerBound) < inFrame.maxX && CGFloat($0.upperBound) > inFrame.minX }),
                      !sides.contains(where: { CGFloat($0.0.lowerBound) < inFrame.maxX && CGFloat($0.0.upperBound) > inFrame.minX }),
                      !mostlySticky(inFrame)
                else { return nil }
                return inFrame
            }
        }
        if revisited == 0 {
            // Only over content that scrolls: a patch copies the frame at the
            // content's new position, which for a sidebar is something else.
            func recordHole(_ hit: CGRect, imageTop: Int) {
                guard !hit.isNull, hit.height >= 1 else { return }
                let band = match.bandPixels
                let low = max(Int(hit.minX), band.lowerBound), high = min(Int(hit.maxX.rounded(.up)), band.upperBound)
                guard low < high else { return }
                var segments = [low..<high]
                for side in sides.map(\.0) + match.fixedSides {
                    segments = segments.flatMap { segment -> [Range<Int>] in
                        guard segment.overlaps(side) else { return [segment] }
                        return [segment.lowerBound..<max(segment.lowerBound, side.lowerBound),
                                min(segment.upperBound, side.upperBound)..<segment.upperBound].filter { !$0.isEmpty }
                    }
                }
                for segment in segments {
                    pointerHoles.append(CGRect(x: CGFloat(segment.lowerBound), y: hit.minY + CGFloat(imageTop),
                                               width: CGFloat(segment.count), height: hit.height))
                }
            }
            // The first frame shows the pointer too.
            if !firstFramePointerChecked {
                firstFramePointerChecked = true
                if let pointer {
                    recordHole(pointer.intersection(CGRect(x: 0, y: 0, width: frame.width, height: firstFrameRows)), imageTop: 0)
                }
            }
            let usable = Self.clampedRows(max(frameBottom / 8, match.followingRows.lowerBound),
                                          min(frameBottom - newRows, match.followingRows.upperBound))
            pointerHoles.removeAll { hole in
                let inFrame = hole.offsetBy(dx: 0, dy: CGFloat(-frameTop))
                guard usable.contains(inFrame.minY), usable.contains(inFrame.maxY),
                      !(pointer.map { inFrame.intersects($0) } ?? false) else { return false }
                patches.append(inFrame)
                return true
            }
            if let pointer {
                recordHole(pointer.intersection(CGRect(x: 0, y: frameBottom - newRows, width: frame.width, height: newRows)),
                           imageTop: frameTop)
            }
        }
        append(strip, sides: sides, pastes: pastes, patches: patches, pointer: pointer, from: frame, frameBottom: frameBottom,
               followingRows: Self.clampedRange(max(frameBottom / 8, match.followingRows.lowerBound),
                                                min(frameBottom, match.followingRows.upperBound)))
        appendedStrips += 1
        for paste in pastes where CGFloat(frameTop) + paste.minY < CGFloat(firstFrameRows) {
            pastedFirstFrameColumns.append(Self.clampedRange(max(0, Int(paste.minX)), min(frame.width, Int(paste.maxX.rounded(.up)))))
        }
        restoreFirstFrameSidebars()
        if grown > 0 {
            if revisited == 0 {
                repairAfterGrowth(to: grown, frame: frame, match: match, sides: sides)
            } else {
                rowsToRevisit += grown - bottomRows
                bottomRows = grown
            }
        }
        return .appended
    }

    /// The pinned bottom turned out taller than assumed: a box that slid or
    /// faded in after the capture started (Figma's cookie box) left slices of
    /// itself in the strips taken while it grew. The image bottom shows frame
    /// row (height - bottomRows) of `frame`, so the rows that now sit under
    /// the box are cut off, and the recent rows above it are copied again
    /// from this frame, where that content is visible and the box isn't.
    private func repairAfterGrowth(to grown: Int, frame: CGImage, match: ScrollFrameMatcher.Match,
                                   sides: [(columns: Range<Int>, color: CGColor)]) {
        let cut = grown - bottomRows
        // Never into the first frame: it holds the header and sidebars as seen.
        let stripRows = image.height - firstFrameRows
        guard cut > 0, stripRows > cut,
              let kept = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: image.height - cut)) else {
            rowsToRevisit += max(0, cut)
            bottomRows = grown
            return
        }
        image = kept
        bottomRows = grown
        let top = max(frame.height / 8, match.followingRows.lowerBound)
        let rows = min(frame.height - grown - top, stripRows - cut)
        guard rows > 0,
              let fresh = frame.cropping(to: CGRect(x: 0, y: frame.height - grown - rows, width: frame.width, height: rows))
        else { return }
        replaceBottom(with: fresh, sides: sides)
    }

    /// Puts the first frame back where a paste reached into it, in columns
    /// that have since proved to be a sidebar.
    private func restoreFirstFrameSidebars() {
        guard !pastedFirstFrameColumns.isEmpty, sideScores.count == image.width,
              firstFrame.width == image.width else { return }
        var runs: [Range<Int>] = [], remaining: [Range<Int>] = []
        for pasted in pastedFirstFrameColumns {
            var start: Int?, kept = false
            for x in pasted.lowerBound...pasted.upperBound {
                if x < pasted.upperBound, sideScores[x] > 0.7 {
                    if start == nil { start = x }
                } else if let first = start {
                    runs.append(first..<x)
                    start = nil
                }
                if x < pasted.upperBound, sideScores[x] <= 0.7 { kept = true }
            }
            // Columns not yet decided stay pending; whole sidebar runs are done.
            if kept { remaining.append(pasted) }
        }
        pastedFirstFrameColumns = remaining
        let rows = min(firstFrameRows, firstFrame.height, image.height)
        guard !runs.isEmpty, rows > 0 else { return }
        let existing = image
        let colorSpace = existing.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: existing.width, height: existing.height, bitsPerComponent: 8,
                                      bytesPerRow: existing.width * 4, space: colorSpace, bitmapInfo: bitmapInfo) else { return }
        context.draw(existing, in: CGRect(x: 0, y: 0, width: existing.width, height: existing.height))
        for run in runs {
            guard let piece = firstFrame.cropping(to: CGRect(x: run.lowerBound, y: 0, width: run.count, height: rows)) else { continue }
            context.draw(piece, in: CGRect(x: run.lowerBound, y: existing.height - rows, width: run.count, height: rows))
        }
        if let merged = context.makeImage() { image = merged }
    }

    /// `low..<high`, or an empty range at `low` when `high` is below it: under
    /// a tall held-back panel the frame's bottom can end above where the
    /// rows following the scroll begin (nature.com's consent banner).
    static func clampedRange(_ low: Int, _ high: Int) -> Range<Int> { low..<max(low, high) }

    /// `low...high` as frame rows, collapsed to `low` when `high` is below it.
    static func clampedRows(_ low: Int, _ high: Int) -> ClosedRange<CGFloat> { CGFloat(low)...CGFloat(max(low, high)) }

    /// Draws `rows` over the bottom of the image, plain-filling `sides`.
    private func replaceBottom(with rows: CGImage, sides: [(columns: Range<Int>, color: CGColor)]) {
        let existing = image
        guard existing.width == rows.width, existing.height >= rows.height else { return }
        let colorSpace = existing.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: existing.width, height: existing.height, bitsPerComponent: 8,
                                      bytesPerRow: existing.width * 4, space: colorSpace, bitmapInfo: bitmapInfo) else { return }
        context.draw(existing, in: CGRect(x: 0, y: 0, width: existing.width, height: existing.height))
        context.draw(rows, in: CGRect(x: 0, y: 0, width: rows.width, height: rows.height))
        for side in sides {
            context.setFillColor(side.color)
            context.fill(CGRect(x: side.columns.lowerBound, y: 0, width: side.columns.count, height: rows.height))
        }
        if let merged = context.makeImage() { image = merged }
    }

    /// The finished image: adds the held-back bottom banner, once.
    func finish() -> CGImage {
        if !finished, geometryDecided, bottomRows > 0,
           let strip = reference.cropping(to: CGRect(x: 0, y: reference.height - bottomRows,
                                                     width: reference.width, height: bottomRows)) {
            append(strip, sides: [], pastes: [], patches: [], pointer: nil, from: reference, frameBottom: 0, followingRows: 0..<0)
        }
        finished = true
        return image
    }

    /// Columns to plain-fill in this strip: those this pair judges fixed,
    /// unless their recent history says they scroll (a gutter of line numbers
    /// that looked still for one pair). Every pair votes on every column, so
    /// an early misjudgement (a consent panel before it was recognised as
    /// pinned) fades instead of filling that strip for the rest of the capture.
    /// Columns the vote is unsure of are returned as `carried`, for the caller
    /// to fill only if the strip stayed put across them: one judged fixed for
    /// several pairs in a row and missed by this one (Wikipedia's sticky
    /// contents moves its highlight to the section scrolling in, and that
    /// pair sees it as scrolling content), or one that just turned fixed.
    private func sideFill(for match: ScrollFrameMatcher.Match, width: Int,
                          frameHeight: Int) -> (judged: [Range<Int>], carried: [Range<Int>]) {
        if sideScores.count != width { sideScores = Array(repeating: 0, count: width) }
        var fixedNow = [Bool](repeating: false, count: width)
        for range in match.fixedSides {
            for x in max(0, range.lowerBound)..<min(width, range.upperBound) { fixedNow[x] = true }
        }
        // A side that moved but not with the scroll is filled whatever its
        // history: stitched, its rows repeat (Stack Overflow's right column
        // and x.com's coming to a stop at their ends).
        var diverging = [Bool](repeating: false, count: width)
        for range in match.divergentSides {
            for x in max(0, range.lowerBound)..<min(width, range.upperBound) { diverging[x] = true }
        }
        // Under a tall pinned panel, sidebars are judged on only the top part
        // of the frame, too little to tell a sidebar from content (Stack
        // Overflow: the left edge of a code block). Then a column must be
        // judged fixed twice in a row before it is filled.
        let strict = bottomRows * 2 > frameHeight
        var fill = [Bool](repeating: false, count: width), carry = [Bool](repeating: false, count: width)
        for x in 0..<width {
            let previous = sideScores[x]
            sideScores[x] = 0.5 * previous + (fixedNow[x] ? 0.5 : -0.5)
            fill[x] = fixedNow[x] && (diverging[x] || (strict ? previous > 0.2 : previous > -0.6))
            // Long a sidebar but missed by this pair, or judged fixed now
            // against a history of scrolling (x.com's right column the moment
            // it sticks, its footer at the bottom of the frame): filled only
            // where the strip proves it stayed put.
            carry[x] = fixedNow[x] ? !fill[x] : (!strict && previous > 0.7)
        }
        func runs(_ flags: [Bool]) -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            var start: Int?
            for x in 0...width {
                if x < width, flags[x] {
                    if start == nil { start = x }
                } else if let first = start {
                    ranges.append(first..<x)
                    start = nil
                }
            }
            return ranges
        }
        return (runs(fill), runs(carry))
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

    /// The held-back bottom to grow to, when two consecutive pairs see more
    /// pinned rows than assumed; 0 otherwise. Never shrinks: a banner that
    /// disappears just costs a little of each strip.
    private func pinnedGrowth(_ match: ScrollFrameMatcher.Match) -> Int {
        guard handlesPinnedContent else { return 0 }
        let seen = Self.heldRows(match.staticBottomRows, height: reference.height)
        defer { pendingBottomRows = seen > bottomRows ? seen : 0 }
        guard seen > bottomRows, pendingBottomRows > bottomRows else { return 0 }
        return min(seen, pendingBottomRows)
    }

    /// Rows to hold back for a pinned bottom of `staticRows`: a little more,
    /// for the soft shadow above a floating panel. It changes with the
    /// content behind it, so it isn't detected as pinned, and left in, it
    /// cuts across the first frame and lies faintly over every strip (Stack
    /// Overflow's and Booking.com's cookie panels).
    static func heldRows(_ staticRows: Int, height: Int) -> Int {
        guard staticRows > 0 else { return 0 }
        return min(height * 3 / 4, staticRows + max(4, height / 60))
    }

    private func decideGeometry(_ match: ScrollFrameMatcher.Match) {
        geometryDecided = true
        guard handlesPinnedContent else { return }
        let first = image
        bottomRows = Self.heldRows(match.staticBottomRows, height: first.height)
        // The first frame's own banner is replaced by the final frame's at the end.
        if bottomRows > 0,
           let trimmed = first.cropping(to: CGRect(x: 0, y: 0, width: first.width, height: first.height - bottomRows)) {
            image = trimmed
            firstFrameRows = trimmed.height
        }
    }

    /// The parts of `columns` that stayed put over `rows` between `previous`
    /// and `frame`. Newly revealed rows can't be compared with where the scroll
    /// came from (they weren't on screen), but in place a real sidebar is
    /// unchanged, while content that scrolled in (the start of a code line
    /// next to a misjudged side) differs. Only those columns are filled.
    static func staticColumns(_ columns: Range<Int>, rows: Range<Int>, frame: CGImage, previous: CGImage) -> [Range<Int>] {
        guard frame.width == previous.width, frame.height == previous.height, !rows.isEmpty, !columns.isEmpty,
              let a = ScrollFrameAnalyzer.frame(for: frame), let b = ScrollFrameAnalyzer.frame(for: previous)
        else { return [columns] }
        func luma(_ f: ScrollFrameAnalyzer.Frame, _ x: Int, _ y: Int) -> Int? {
            guard let o = f.offset(x: x, y: y) else { return nil }
            return (Int(f.bytes[o + f.redOffset]) * 299 + Int(f.bytes[o + f.greenOffset]) * 587
                    + Int(f.bytes[o + f.blueOffset]) * 114) / 1000
        }
        let step = 2, rowStep = max(1, rows.count / 48)
        var still: [Bool] = []
        for x in Swift.stride(from: columns.lowerBound, to: columns.upperBound, by: step) {
            var changed = 0, samples = 0
            for y in Swift.stride(from: rows.lowerBound, to: rows.upperBound, by: rowStep) {
                guard let p = luma(a, x, y), let q = luma(b, x, y) else { continue }
                samples += 1
                if abs(p - q) > 8 { changed += 1 }
            }
            still.append(samples == 0 || changed * 20 <= samples)   // at most 5% of samples differ
        }
        var ranges: [Range<Int>] = []
        var start: Int?
        for (index, isStill) in (still + [false]).enumerated() {
            let x = columns.lowerBound + index * step
            if isStill, start == nil { start = x }
            if !isStill, let first = start {
                ranges.append(first..<min(columns.upperBound, x))
                start = nil
            }
        }
        return ranges.filter { $0.count >= 2 }
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
                        pastes: [CGRect], patches: [CGRect], pointer: CGRect?,
                        from frame: CGImage, frameBottom: Int, followingRows: Range<Int>) {
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
            // Grown to the whole video, a region can reach the pointer; it is
            // pasted from a later frame instead, once the page has moved on.
            let grown = pastes.compactMap { consistentRegion($0, following: followingRows) }
            let accepted = grown.filter { rect in !(pointer.map { rect.intersects($0) } ?? false) }
            for rect in accepted {
                guard let piece = frame.cropping(to: rect) else { continue }
                let top = frameTop + Int(rect.minY)
                context.draw(piece, in: CGRect(x: rect.minX, y: CGFloat(totalHeight - top) - rect.height,
                                               width: rect.width, height: rect.height))
            }
        }
        // Exact copies of content the pointer covered when it was appended.
        if frameTop >= 0 {
            for rect in patches {
                guard let piece = frame.cropping(to: rect) else { continue }
                let top = frameTop + Int(rect.minY)
                context.draw(piece, in: CGRect(x: rect.minX, y: CGFloat(totalHeight - top) - rect.height,
                                               width: rect.width, height: rect.height))
            }
        }
        if let merged = context.makeImage() { image = merged }
    }
}
