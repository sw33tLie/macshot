import CoreGraphics
import Foundation

/// Measures how far a page scrolled between two frames of a scroll capture,
/// and which parts of the frame don't scroll at all.
///
/// Real pages are full of things that stay put while the content moves:
/// translucent navbars whose blur changes as content passes under them,
/// sidebars that stay fixed beside a feed (x.com), fixed gradient
/// backgrounds, cookie banners pinned to the bottom. Registering the whole
/// frame lets those pull the answer toward "nothing moved". This matcher
/// compares only the columns that scroll, normalizes each row to its own
/// background level so a fixed gradient cancels out, and scores candidate
/// shifts on the rows that follow the scroll, leaving out the bands at the
/// top and bottom that don't.
///
/// Pure arithmetic on pixels; `ScrollCaptureController` owns the decisions.
enum ScrollFrameMatcher {

    // MARK: - Samples

    /// Grayscale samples of a frame: every row, at evenly spaced columns.
    struct Samples {
        /// Pixel x of each sampled column.
        let columns: [Int]
        let width: Int
        let height: Int
        /// Row-major luma, 0…255.
        let values: [Float]

        var columnCount: Int { columns.count }
        func value(_ row: Int, _ column: Int) -> Float { values[row * columns.count + column] }
    }

    static let maximumSampledColumns = 320

    static func samples(of image: CGImage, maximumColumns: Int = maximumSampledColumns) -> Samples? {
        guard let frame = ScrollFrameAnalyzer.frame(for: image) else { return nil }
        let count = max(1, min(maximumColumns, frame.width))
        let columns = (0..<count).map { min(frame.width - 1, Int((Double($0) + 0.5) * Double(frame.width) / Double(count))) }
        var values = [Float](repeating: 0, count: frame.height * count)
        values.withUnsafeMutableBufferPointer { out in
            for row in 0..<frame.height {
                let base = row * frame.bytesPerRow
                for (index, x) in columns.enumerated() {
                    let offset = base + x * 4
                    let red = Float(frame.bytes[offset + frame.redOffset])
                    let green = Float(frame.bytes[offset + frame.greenOffset])
                    let blue = Float(frame.bytes[offset + frame.blueOffset])
                    out[row * count + index] = 0.299 * red + 0.587 * green + 0.114 * blue
                }
            }
        }
        return Samples(columns: columns, width: frame.width, height: frame.height, values: values)
    }

    // MARK: - Match

    struct Match: Equatable {
        /// Pixels the content moved up: positive when the page scrolled down,
        /// negative when it scrolled back up, zero when nothing moved.
        let shift: Int
        /// Sampled columns that scroll.
        let band: ClosedRange<Int>
        /// Rows at the bottom that stayed put while the content moved (a
        /// pinned banner). Zero unless the content moved down.
        let staticBottomRows: Int
        /// Pixel columns beside the scrolling content that hold fixed content
        /// (sidebars, a pinned button): they belong in the first frame only.
        var fixedSides: [Range<Int>]
        /// Regions of the current frame (top-left pixel coordinates) that
        /// changed in a way no scroll explains, such as a playing video or an
        /// animation, fully inside the frame. Stitching strips of them would
        /// mix moments; the stitcher pastes each one whole instead.
        var dynamicRects: [CGRect] = []
        /// Frame rows that follow the scroll: below a navbar band at the top
        /// and above anything pinned at the bottom of the overlap.
        var followingRows: Range<Int> = 0..<0
        /// Pixel columns of `band`: the content seen scrolling in this pair.
        var bandPixels: Range<Int> = 0..<0
        /// The part of `fixedSides` that moved, but not with the scroll (a
        /// sidebar catching up or coming to a stop): strong evidence, unlike
        /// a column that merely looked still in this pair.
        var divergentSides: [Range<Int>] = []
    }

    /// Below this mean per-sample difference a column or row counts as unchanged.
    static let unchangedThreshold: Float = 1.5

    /// Compares `current` with `previous`. Returns nil when the frames can't be
    /// aligned with confidence: blank content, too little overlap, or no shift
    /// that explains the change.
    /// - Parameter hint: the shift expected from the recent motion (0 if
    ///   unknown): breaks near-ties on repetitive content and makes a jump far
    ///   from it need clearer evidence.
    /// - Parameter pinnedBottom: rows at the bottom the caller already treats as
    ///   pinned; sidebars are judged above them even when this pair sees less.
    static func match(previous: Samples, current: Samples, hint: Int = 0, pinnedBottom: Int = 0) -> Match? {
        guard previous.width == current.width, previous.height == current.height,
              previous.columns == current.columns, current.height >= 16 else { return nil }
        let change = columnChange(previous, current)
        guard let band = movingBand(change: change) else {
            // Nothing scrolls anywhere: the frames are the same picture.
            let all = 0...(current.columnCount - 1)
            return Match(shift: 0, band: all, staticBottomRows: 0, fixedSides: [])
        }
        // Only columns with something in them: on a sparse page (a line of
        // text, then whitespace) blank columns would drown every difference.
        let (prev, cur, kept) = informative(features(previous, band: band), features(current, band: band))
        let level = texture(cur)
        guard level >= 0.3 else { return nil }

        let height = current.height
        let maximumShift = height * 4 / 5
        // Scrolling back up by more than half a frame between two grabs is
        // implausible; such "matches" come from look-alike content across a
        // thin overlap and would swallow the rows that follow.
        let maximumBackShift = height / 2
        let candidates = coarseCandidates(prev: prev, cur: cur, maximumShift: maximumShift,
                                          maximumBackShift: maximumBackShift, level: level)
        var best: (shift: Int, cost: Float)?
        var scored: [(shift: Int, cost: Float)] = []
        for candidate in candidates {
            for shift in max(-maximumBackShift, candidate - 6)...min(maximumShift, candidate + 6) {
                guard let cost = bodyCost(prev: prev, cur: cur, shift: shift, rowStep: 1, level: level) else { continue }
                scored.append((shift, cost))
                if best == nil || cost < best!.cost { best = (shift, cost) }
            }
        }
        guard var chosen = best else { return nil }

        // Final choice on the parts of the frame that some candidate explains.
        // A playing video, an animation or an overlay changes no matter how the
        // frames are aligned; left in, it can make a wrong shift look best.
        let groups = columnGroups(width: cur.width)
        var centers = [chosen.shift]
        for entry in scored.sorted(by: { $0.cost < $1.cost }) where centers.allSatisfy({ abs($0 - entry.shift) > 3 }) {
            centers.append(entry.shift)
            if centers.count == 5 { break }
        }
        if !centers.contains(0) { centers.append(0) }
        if (-maximumBackShift...maximumShift).contains(hint), centers.allSatisfy({ abs($0 - hint) > 3 }) { centers.append(hint) }
        let (unexplained, mismatch) = unexplainedBlocks(prev: prev, cur: cur, centers: centers, groups: groups, level: level)
        var masked: [(shift: Int, cost: Float)] = []
        for center in centers {
            for shift in max(-maximumBackShift, center - 2)...min(maximumShift, center + 2) where !masked.contains(where: { $0.shift == shift }) {
                if let cost = maskedCost(prev: prev, cur: cur, shift: shift, groups: groups, excluding: unexplained, level: level) {
                    masked.append((shift, cost))
                }
            }
        }
        if let robust = masked.min(by: { $0.cost < $1.cost }) {
            chosen = robust
            scored = masked
        }
        // A jump far beyond the recent motion across a thin overlap is how a
        // full-width playing video or look-alike content fools the search
        // (Reddit: +1420 px between two 50 ms grabs). If a shift in line with
        // the recent motion explains the frames nearly as well, keep to it. A
        // genuine fling still wins: small shifts then explain it badly.
        // Jumping back by much of a frame while scrolling down is no more
        // plausible (x.com: -899 px between two grabs, whose new rows were
        // then skipped as already seen). Either keeps to the steady motion if
        // that explains the frames nearly as well; otherwise a jump back is
        // refused, and a jump ahead must match clearly.
        if hint > 0 {
            let plausible = 2 * hint + height / 6
            if chosen.shift > plausible || chosen.shift < -height / 6 {
                if let steady = scored.filter({ (0...plausible).contains($0.shift) }).min(by: { $0.cost < $1.cost }),
                   steady.cost <= chosen.cost * 1.6 + 0.05 * level {
                    chosen = steady
                } else if chosen.shift < 0 || chosen.cost > 0.25 * level {
                    return nil
                }
            }
        }
        // Thresholds scale with how much there is to align on: sparse text and
        // dense photos produce very different absolute differences.
        if chosen.cost > 0.45 * level,
           let narrowed = withoutDivergentSides(prev: prev, cur: cur, chosen: chosen, groups: groups,
                                                unexplained: unexplained, mismatch: mismatch, level: level) {
            // A side of the band moving at its own rate (GitHub's file tree
            // still sliding up to stick while the code scrolls) mismatches at
            // every shift. Judged without it, the content matches; the side
            // is then filled like any sidebar that diverges.
            chosen = narrowed
        }
        guard chosen.cost <= 0.45 * level else { return nil }
        // Repetitive content (identical list rows) can score several shifts
        // almost equally; prefer the one that continues the current motion.
        let tolerance = max(0.02 * level, chosen.cost * 0.08)
        let ties = scored.filter { $0.cost <= chosen.cost + tolerance && abs($0.shift - chosen.shift) > 3 }
        if !ties.isEmpty {
            let all = ties + [chosen]
            chosen = all.min { abs($0.shift - hint) < abs($1.shift - hint) }!
        }
        if chosen.shift != 0,
           let still = scored.first(where: { $0.shift == 0 })?.cost
                ?? bodyCost(prev: prev, cur: cur, shift: 0, rowStep: 1, level: level),
           still < chosen.cost + 0.1 * level {
            // Not moving explains the frames about as well: don't invent a scroll.
            return Match(shift: 0, band: band, staticBottomRows: 0, fixedSides: [])
        }
        let bottom = chosen.shift > 0 ? pinnedBottomRows(previous, current, band: band, shift: chosen.shift) : 0
        let atShift = blockCosts(prev: prev, cur: cur, shift: chosen.shift, groups: groups)
        let edges = edgeBands(atShift, groups: groups.count, level: level)
        // Sidebars are judged on the rows that follow the scroll: a sticky
        // header at the top (GitHub's file header) stays put in every column
        // and would make a plain gutter beside the code look like a sidebar.
        let sideBottom = height - min(height * 65 / 100, max(bottom, pinnedBottom))
        let sideTop = chosen.shift > 0 ? min(edges.top * blockRows, sideBottom / 2) : 0
        var result = Match(shift: chosen.shift, band: band, staticBottomRows: bottom,
                           fixedSides: fixedSides(previous, current, band: band, change: change, shift: chosen.shift,
                                                  rows: sideTop..<sideBottom))
        let step = Double(current.width) / Double(current.columnCount)
        result.bandPixels = Int(Double(band.lowerBound) * step)..<min(current.width, Int((Double(band.upperBound + 1) * step).rounded(.up)))
        if chosen.shift > 0 {
            let overlapRows = height - chosen.shift
            let lastBlock = (overlapRows - 1) / blockRows
            result.followingRows = min(overlapRows, edges.top * blockRows)
                ..< max(min(overlapRows, edges.top * blockRows), min(overlapRows, (lastBlock + 1 - edges.bottom) * blockRows))
            let sampleWidth = Double(current.width) / Double(current.columnCount)
            let pixelColumn = { (index: Int) in current.columns[band.lowerBound + kept[index]] }
            // Columns at the side of the scrolling area that mostly don't
            // follow this scroll (a sidebar that scrolls slower, then sticks):
            // stitching them would garble them, so they're filled like a
            // fixed sidebar instead.
            let divergent = divergentGroups(atShift, groups: groups.count, shift: chosen.shift, height: height,
                                            edges: edges, threshold: mismatch)
            let bandLeft = Int(Double(band.lowerBound) * sampleWidth)
            let bandRight = Int((Double(band.upperBound + 1) * sampleWidth).rounded(.up))
            // Groups are coarse: the side usually ends inside the next group
            // (GitHub's file tree beside the line numbers). Follow it column
            // by column while columns still don't follow the scroll, so the
            // fill doesn't stop mid-word.
            let bodyRows = min(overlapRows, edges.top * blockRows)
                ..< max(min(overlapRows, edges.top * blockRows), min(overlapRows, (lastBlock + 1 - edges.bottom) * blockRows))
            func diverges(_ column: Int) -> Bool {
                guard !bodyRows.isEmpty else { return false }
                var sum: Float = 0
                for row in bodyRows {
                    sum += abs(cur.values[row * cur.width + column] - prev.values[(row + chosen.shift) * cur.width + column])
                }
                return sum / Float(bodyRows.count) > mismatch
            }
            func extend(from start: Int, by step: Int, limit: Int) -> Int {
                var edge = start, column = start + step, matching = 0
                while column >= 0, column < cur.width, abs(column - start) <= limit {
                    if diverges(column) { edge = column; matching = 0 } else { matching += 1; if matching >= 3 { break } }
                    column += step
                }
                return edge
            }
            let reach = cur.width / 4
            if let inner = divergent.left {
                let last = extend(from: groups[inner].upperBound - 1, by: 1, limit: reach)
                let right = Int((Double(pixelColumn(last)) + sampleWidth / 2).rounded(.up))
                if right > bandLeft {
                    result.fixedSides.append(bandLeft..<min(right, current.width))
                    result.divergentSides.append(bandLeft..<min(right, current.width))
                }
            }
            if let inner = divergent.right {
                let first = extend(from: groups[inner].lowerBound, by: -1, limit: reach)
                let left = max(0, Int(Double(pixelColumn(first)) - sampleWidth / 2))
                if bandRight > left {
                    result.fixedSides.append(left..<bandRight)
                    result.divergentSides.append(left..<bandRight)
                }
            }
            let excludedGroups = Set((divergent.left.map { Array(0...$0) } ?? [])
                                     + (divergent.right.map { Array($0..<groups.count) } ?? []))
            result.dynamicRects = dynamicRects(unexplained, shift: chosen.shift, height: height, groups: groups,
                                               edges: edges, excludedGroups: excludedGroups,
                                               pixelColumn: pixelColumn, sampleWidth: sampleWidth)
        }
        return result
    }

    // MARK: - Blocks

    /// Rows per block when looking for regions that change on their own.
    static let blockRows = 16

    /// Up to eight column groups across the compared columns.
    static func columnGroups(width: Int) -> [Range<Int>] {
        let count = min(8, max(1, width / 8))
        return (0..<count).map { ($0 * width / count)..<(($0 + 1) * width / count) }
    }

    /// Mean difference per block (16 rows × one column group) of the current
    /// frame against the previous one shifted by `shift`; nil where the block
    /// has no overlapping rows.
    static func blockCosts(prev: Features, cur: Features, shift: Int, groups: [Range<Int>]) -> [Float?] {
        let blockRowCount = (cur.height + blockRows - 1) / blockRows
        var sums = [Float](repeating: 0, count: blockRowCount * groups.count)
        var counts = [Int](repeating: 0, count: blockRowCount * groups.count)
        let first = max(0, -shift), last = min(cur.height, cur.height - shift)
        guard last > first else { return Array(repeating: nil, count: sums.count) }
        let width = cur.width
        cur.values.withUnsafeBufferPointer { c in
            prev.values.withUnsafeBufferPointer { p in
                for row in first..<last {
                    let curBase = row * width, prevBase = (row + shift) * width
                    let block = (row / blockRows) * groups.count
                    for (index, group) in groups.enumerated() {
                        var sum: Float = 0
                        for column in group { sum += abs(c[curBase + column] - p[prevBase + column]) }
                        sums[block + index] += sum
                        counts[block + index] += group.count
                    }
                }
            }
        }
        return zip(sums, counts).map { $1 > 0 ? $0 / Float($1) : nil }
    }

    /// Blocks that mismatch at every candidate shift: they change on their own.
    /// One threshold for all candidates, set by the best-fitting one: a wrong
    /// candidate mismatches almost everywhere, so its own typical cost would
    /// excuse anything.
    static func unexplainedBlocks(prev: Features, cur: Features, centers: [Int], groups: [Range<Int>],
                                  level: Float) -> (mask: [Bool], threshold: Float) {
        let perCenter = centers.map { blockCosts(prev: prev, cur: cur, shift: $0, groups: groups) }
        // The lower quartile, not the median: a video may cover half the frame.
        let quartiles = perCenter.compactMap { costs -> Float? in
            let defined = costs.compactMap { $0 }.sorted()
            return defined.count >= 4 ? defined[defined.count / 4] : nil
        }
        let threshold = max(0.15 * level, (quartiles.min() ?? 0) * 3)
        let count = perCenter.first?.count ?? 0
        let mask = (0..<count).map { block -> Bool in
            var defined = 0
            for costs in perCenter {
                guard let cost = costs[block] else { continue }
                if cost <= threshold { return false }
                defined += 1
            }
            return defined >= 2
        }
        return (mask, threshold)
    }

    /// Mean block difference at `shift`, leaving out blocks that change on
    /// their own and, like `bodyCost`, a mismatching band at the top or
    /// bottom of the overlap (a navbar, a pinned banner explained by "no
    /// scroll" but not by this shift). Nil when too little is left to judge.
    static func maskedCost(prev: Features, cur: Features, shift: Int, groups: [Range<Int>],
                           excluding unexplained: [Bool], level: Float) -> Float? {
        let height = cur.height
        guard min(height, height - shift) - max(0, -shift) >= max(4, height / 5) else { return nil }
        let costs = blockCosts(prev: prev, cur: cur, shift: shift, groups: groups)
        // Per block row: mean over the blocks that a scroll can explain.
        var rowCosts: [Float] = []
        var defined = 0
        for row in 0..<(costs.count / groups.count) {
            var sum: Float = 0, used = 0, any = false
            for group in groups.indices {
                let block = row * groups.count + group
                guard let cost = costs[block] else { continue }
                any = true
                defined += 1
                guard !unexplained[block] else { continue }
                sum += cost
                used += 1
            }
            if any { rowCosts.append(used > 0 ? sum / Float(used) : -1) }
        }
        let sorted = rowCosts.filter { $0 >= 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let threshold = max(0.08 * level, sorted[sorted.count / 2] * 3)
        let cap = rowCosts.count * 35 / 100
        let bridge = max(1, 40 / blockRows)
        func edgeBand<S: Sequence>(_ indices: S) -> Int where S.Element == Int {
            var lastBad = -1
            for (position, index) in indices.enumerated() {
                guard position < cap else { break }
                if rowCosts[index] > threshold { lastBad = position } else if position - lastBad > bridge { break }
            }
            return lastBad + 1
        }
        let top = edgeBand(rowCosts.indices)
        let bottom = min(edgeBand(rowCosts.indices.reversed()), rowCosts.count - top)
        let body = rowCosts[top..<(rowCosts.count - bottom)].filter { $0 >= 0 }
        guard body.count >= max(2, rowCosts.count / 3), body.count * groups.count >= max(4, defined * 3 / 10) / 2 else { return nil }
        return body.reduce(0, +) / Float(body.count)
    }

    /// Outermost column groups on each side that mismatch at the chosen shift
    /// over most of the overlap (outside the edge bands): content moving at a
    /// different rate, such as a sidebar catching up before it sticks. Nil on
    /// a side with none, and nothing when half the groups or more would
    /// qualify (then it's the rows, not the columns, that disagree).
    /// The best shift near `chosen`, costed without the column groups at the
    /// sides of the band that don't follow it; nil when no side diverges.
    static func withoutDivergentSides(prev: Features, cur: Features, chosen: (shift: Int, cost: Float),
                                      groups: [Range<Int>], unexplained: [Bool], mismatch: Float,
                                      level: Float) -> (shift: Int, cost: Float)? {
        guard chosen.shift > 0 else { return nil }
        let atShift = blockCosts(prev: prev, cur: cur, shift: chosen.shift, groups: groups)
        let edges = edgeBands(atShift, groups: groups.count, level: level)
        let divergent = divergentGroups(atShift, groups: groups.count, shift: chosen.shift, height: cur.height,
                                        edges: edges, threshold: mismatch)
        let sides = Set((divergent.left.map { Array(0...$0) } ?? [])
                        + (divergent.right.map { Array($0..<groups.count) } ?? []))
        guard !sides.isEmpty else { return nil }
        let excluding = unexplained.indices.map { unexplained[$0] || sides.contains($0 % groups.count) }
        var best: (shift: Int, cost: Float)?
        for shift in (chosen.shift - 2)...(chosen.shift + 2) {
            guard let cost = maskedCost(prev: prev, cur: cur, shift: shift, groups: groups,
                                        excluding: excluding, level: level) else { continue }
            if best == nil || cost < best!.cost { best = (shift, cost) }
        }
        return best
    }

    static func divergentGroups(_ costs: [Float?], groups: Int, shift: Int, height: Int,
                                edges: (top: Int, bottom: Int), threshold: Float) -> (left: Int?, right: Int?) {
        let lastRow = (height - shift - 1) / blockRows
        let rows = Array(stride(from: edges.top, through: lastRow - edges.bottom, by: 1))
        guard rows.count >= 4, groups >= 4 else { return (nil, nil) }
        func diverges(_ group: Int) -> Bool {
            var high = 0, defined = 0
            for row in rows {
                guard let cost = costs[row * groups + group] else { continue }
                defined += 1
                if cost > threshold { high += 1 }
            }
            return defined >= 4 && high * 10 > defined * 6
        }
        var left: Int?, right: Int?
        var group = 0
        while group < groups, diverges(group) { left = group; group += 1 }
        group = groups - 1
        while group >= 0, group > (left ?? -1), diverges(group) { right = group; group -= 1 }
        let count = (left.map { $0 + 1 } ?? 0) + (right.map { groups - $0 } ?? 0)
        guard count * 2 < groups else { return (nil, nil) }
        return (left, right)
    }

    /// Block rows at the top and bottom of the overlap that mismatch at
    /// `costs`' shift (navbars, pinned banners), with the same bridging as
    /// `bodyCost`, plus one row of margin.
    static func edgeBands(_ costs: [Float?], groups: Int, level: Float) -> (top: Int, bottom: Int) {
        var rows: [Float] = []
        for row in 0..<(costs.count / groups) {
            let defined = costs[(row * groups)..<((row + 1) * groups)].compactMap { $0 }
            if !defined.isEmpty { rows.append(defined.reduce(0, +) / Float(defined.count)) }
        }
        guard !rows.isEmpty else { return (0, 0) }
        let median = rows.sorted()[rows.count / 2]
        let threshold = max(0.08 * level, median * 3)
        let cap = rows.count * 35 / 100, bridge = max(1, 40 / blockRows)
        func band<S: Sequence>(_ indices: S) -> Int where S.Element == Int {
            var lastBad = -1
            for (position, index) in indices.enumerated() {
                guard position < cap else { break }
                if rows[index] > threshold { lastBad = position } else if position - lastBad > bridge { break }
            }
            return lastBad + 1
        }
        let top = band(rows.indices)
        return (top > 0 ? top + 1 : 0, { let b = band(rows.indices.reversed()); return b > 0 ? b + 1 : 0 }())
    }

    /// Regions of unexplained blocks that lie fully inside the overlap, as
    /// pixel rectangles of the current frame. Anything touching the top or
    /// bottom of the overlap (a navbar, a pinned banner, content cut off by
    /// the edge) is left alone.
    static func dynamicRects(_ unexplained: [Bool], shift: Int, height: Int, groups: [Range<Int>],
                             edges: (top: Int, bottom: Int) = (0, 0), excludedGroups: Set<Int> = [],
                             pixelColumn: (Int) -> Int, sampleWidth: Double) -> [CGRect] {
        let columns = groups.count
        let rows = unexplained.count / max(1, columns)
        let lastRow = (height - shift - 1) / blockRows
        var seen = [Bool](repeating: false, count: unexplained.count)
        var rects: [CGRect] = []
        for start in unexplained.indices where unexplained[start] && !seen[start] {
            var stack = [start], minRow = Int.max, maxRow = 0, minGroup = Int.max, maxGroup = 0, size = 0
            seen[start] = true
            while let block = stack.popLast() {
                let row = block / columns, group = block % columns
                minRow = min(minRow, row); maxRow = max(maxRow, row)
                minGroup = min(minGroup, group); maxGroup = max(maxGroup, group)
                size += 1
                for (dr, dg) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let r = row + dr, g = group + dg
                    guard r >= 0, r < rows, g >= 0, g < columns else { continue }
                    let neighbour = r * columns + g
                    if unexplained[neighbour], !seen[neighbour] { seen[neighbour] = true; stack.append(neighbour) }
                }
            }
            // Clear of the bands at the top and bottom that don't follow the
            // scroll: a translucent navbar's first row can match by chance,
            // and pasting it would drop a navbar into the middle of the image.
            guard minRow > edges.top, maxRow < lastRow - edges.bottom, size >= 2,
                  !(minGroup...maxGroup).contains(where: excludedGroups.contains) else { continue }
            let left = max(0, Int(Double(pixelColumn(groups[minGroup].lowerBound)) - sampleWidth / 2))
            let right = Int((Double(pixelColumn(groups[maxGroup].upperBound - 1)) + sampleWidth / 2).rounded(.up))
            let top = minRow * blockRows, bottom = min(height - shift, (maxRow + 1) * blockRows)
            rects.append(CGRect(x: left, y: top, width: right - left, height: bottom - top))
        }
        return rects
    }

    // MARK: - Columns

    /// Mean difference of each sampled column between the frames, at the same position.
    static func columnChange(_ a: Samples, _ b: Samples) -> [Float] {
        let count = a.columnCount
        var sums = [Float](repeating: 0, count: count)
        var rows = 0
        for row in stride(from: 0, to: a.height, by: 2) {
            let base = row * count
            for column in 0..<count { sums[column] += abs(a.values[base + column] - b.values[base + column]) }
            rows += 1
        }
        return sums.map { $0 / Float(max(1, rows)) }
    }

    /// The sampled columns that scroll: the largest run of changing columns,
    /// bridging small static gaps (whitespace inside the content) and leaving
    /// out a thin strip at the right edge (an overlay scrollbar).
    static func movingBand(change: [Float]) -> ClosedRange<Int>? {
        let count = change.count
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for column in 0..<count {
            let moving = change[column] > unchangedThreshold
            if moving, start == nil { start = column }
            if !moving, let begin = start { runs.append(begin...(column - 1)); start = nil }
        }
        if let begin = start { runs.append(begin...(count - 1)) }
        guard !runs.isEmpty else { return nil }
        let gap = max(2, count * 6 / 100)
        var merged: [ClosedRange<Int>] = []
        for run in runs {
            if let last = merged.last, run.lowerBound - last.upperBound - 1 <= gap {
                merged[merged.count - 1] = last.lowerBound...run.upperBound
            } else {
                merged.append(run)
            }
        }
        let edge = max(1, count * 3 / 100)
        let candidates = merged.count > 1
            ? merged.filter { !($0.upperBound == count - 1 && $0.count <= edge) }
            : merged
        func movingCount(_ run: ClosedRange<Int>) -> Int { run.filter { change[$0] > unchangedThreshold }.count }
        return (candidates.isEmpty ? merged : candidates).max { movingCount($0) < movingCount($1) }
    }

    /// Pixel ranges beside the scrolling band that hold content which never
    /// moves (sidebars, a pinned Post button), so it isn't repeated down the
    /// stitched image. Evaluated per frame pair: a sidebar that scrolls at
    /// first and then sticks (x.com) is covered once it sticks, and one that
    /// moves at a different rate meanwhile is covered too. Columns of a single
    /// colour (a plain margin, a vertical border line) are left alone.
    static func fixedSides(_ previous: Samples, _ current: Samples, band: ClosedRange<Int>,
                           change fullChange: [Float], shift: Int = 0, rows: Range<Int>? = nil) -> [Range<Int>] {
        let count = current.columnCount
        // Judged above any pinned bottom box: a tall cookie panel over part of
        // the content columns must not make those columns look static.
        let rows = rows ?? 0..<current.height
        let change: [Float]
        if rows == 0..<current.height {
            change = fullChange
        } else {
            change = (0..<count).map { column in
                var sum: Float = 0, n = 0
                for row in Swift.stride(from: rows.lowerBound, to: rows.upperBound, by: 2) {
                    sum += abs(current.value(row, column) - previous.value(row, column)); n += 1
                }
                return n > 0 ? sum / Float(n) : fullChange[column]
            }
        }
        let first = max(rows.lowerBound, -shift), last = min(rows.upperBound, current.height - shift)
        func isFixed(_ column: Int) -> Bool {
            // Content, not a plain margin or a single-colour border line.
            var low: Float = 255, high: Float = 0
            for row in Swift.stride(from: rows.lowerBound, to: rows.upperBound, by: 2) {
                let value = current.value(row, column)
                low = min(low, value); high = max(high, value)
            }
            guard high - low >= 8 else { return false }
            if shift == 0 || last - first < 8 { return change[column] <= unchangedThreshold }
            // Does following the scroll explain this column? A sidebar (static,
            // or moving at its own rate) doesn't; a nearly blank column of the
            // page (a code box's padding) does, even if it barely changes.
            var atShift: Float = 0
            for row in Swift.stride(from: first, to: last, by: 2) {
                atShift += abs(current.value(row, column) - previous.value(row + shift, column))
            }
            atShift /= Float((last - first + 1) / 2)
            return atShift > max(1, change[column] * 0.3) && atShift > change[column] + 0.5
                || (change[column] > unchangedThreshold && atShift > max(2, change[column] * 0.3))
        }
        let step = Double(current.width) / Double(count)
        let bandLeft = Int(Double(band.lowerBound) * step), bandRight = Int((Double(band.upperBound + 1) * step).rounded(.up))
        var ranges: [Range<Int>] = []
        func collect(_ columns: Range<Int>, clampLow: Int, clampHigh: Int, innerIsHigh: Bool) {
            var start: Int?
            for column in columns.lowerBound...columns.upperBound {
                if column < columns.upperBound, isFixed(column) {
                    if start == nil { start = column }
                } else if let first = start {
                    // One sample of margin (content can begin between samples):
                    // always on the outer side, and on the side toward the
                    // scrolling content only if that column is still too (a
                    // card's border), never into one that moves (line numbers).
                    // Toward the content, reach up to five more still samples
                    // when the rows this pair reveals didn't change there: a
                    // card's thin border can fall between samples and would
                    // otherwise repeat down the image (x.com's right column).
                    // "Still" is a mean over the frame, so a line of new text
                    // beside the column barely moves it; checking the
                    // revealed rows keeps the fill off that text (Stack
                    // Overflow's "25 Answers" beside the sticky vote buttons).
                    func still(_ c: Int) -> Bool { c >= 0 && c < count && change[c] <= unchangedThreshold }
                    func unchangedInRevealedRows(_ c: Int) -> Bool {
                        let top = max(rows.lowerBound, rows.upperBound - max(shift, 0) - 8)
                        for row in top..<rows.upperBound
                        where abs(current.value(row, c) - previous.value(row, c)) > 24 { return false }
                        return true
                    }
                    func extends(_ c: Int, beyondFirst: Bool) -> Bool {
                        still(c) && (!beyondFirst || unchangedInRevealedRows(c))
                    }
                    var lowSample = first, highSample = column
                    if innerIsHigh {
                        lowSample = first - 1
                        while highSample < column + 6, extends(highSample, beyondFirst: highSample > column) { highSample += 1 }
                    } else {
                        highSample = column + 1
                        while lowSample > first - 6, extends(lowSample - 1, beyondFirst: lowSample < first) { lowSample -= 1 }
                    }
                    let low = max(clampLow, Int(Double(lowSample) * step))
                    let high = min(clampHigh, Int((Double(highSample) * step).rounded(.up)))
                    if high > low { ranges.append(low..<high) }
                    start = nil
                }
            }
        }
        if band.lowerBound > 0 { collect(0..<band.lowerBound, clampLow: 0, clampHigh: bandLeft, innerIsHigh: true) }
        if band.upperBound < count - 1 {
            collect((band.upperBound + 1)..<count, clampLow: bandRight, clampHigh: current.width, innerIsHigh: false)
        }
        return ranges
    }

    // MARK: - Rows

    /// Band samples with each row's median removed: a background that doesn't
    /// scroll (a fixed gradient, a tinted overlay) shifts whole rows evenly and
    /// cancels out, while text and edges remain.
    struct Features {
        let width: Int
        let height: Int
        let values: [Float]
    }

    static func features(_ samples: Samples, band: ClosedRange<Int>) -> Features {
        let width = band.count
        var values = [Float](repeating: 0, count: samples.height * width)
        var histogram = [Int](repeating: 0, count: 256)
        for row in 0..<samples.height {
            for index in 0..<256 { histogram[index] = 0 }
            let base = row * samples.columnCount
            for column in band { histogram[min(255, max(0, Int(samples.values[base + column])))] += 1 }
            var seen = 0, median = 0
            for (level, count) in histogram.enumerated() {
                seen += count
                if seen * 2 >= width { median = level; break }
            }
            for (index, column) in band.enumerated() {
                values[row * width + index] = samples.values[base + column] - Float(median)
            }
        }
        return Features(width: width, height: samples.height, values: values)
    }

    /// Mean magnitude of the features: how much there is to align on.
    static func texture(_ features: Features) -> Float {
        guard !features.values.isEmpty else { return 0 }
        var sum: Float = 0
        for (index, value) in features.values.enumerated() where index % 3 == 0 { sum += abs(value) }
        return sum / Float((features.values.count + 2) / 3)
    }

    /// Keeps the columns that carry detail in either frame. Falls back to all
    /// of them when too few do.
    static func informative(_ prev: Features, _ cur: Features) -> (Features, Features, [Int]) {
        var keep: [Int] = []
        for column in 0..<cur.width {
            var detail: Float = 0
            for row in stride(from: 0, to: cur.height, by: 2) {
                detail += abs(cur.values[row * cur.width + column]) + abs(prev.values[row * prev.width + column])
            }
            if detail / Float(cur.height) > 1 { keep.append(column) }
        }
        guard keep.count >= 8, keep.count < cur.width else { return (prev, cur, Array(0..<cur.width)) }
        func select(_ f: Features) -> Features {
            var values = [Float](repeating: 0, count: f.height * keep.count)
            for row in 0..<f.height {
                for (index, column) in keep.enumerated() { values[row * keep.count + index] = f.values[row * f.width + column] }
            }
            return Features(width: keep.count, height: f.height, values: values)
        }
        return (select(prev), select(cur), keep)
    }

    /// Coarse search on 4×-reduced rows; returns a few promising shifts.
    static func coarseCandidates(prev: Features, cur: Features, maximumShift: Int, maximumBackShift: Int,
                                 level: Float) -> [Int] {
        let factor = 4
        let columnStep = max(1, cur.width / 96)
        let rows = cur.height / factor
        guard rows >= 4 else { return [0] }
        func reduce(_ f: Features) -> [Float] {
            var out = [Float](repeating: 0, count: rows * ((f.width + columnStep - 1) / columnStep))
            let width = (f.width + columnStep - 1) / columnStep
            for row in 0..<rows {
                for (index, column) in stride(from: 0, to: f.width, by: columnStep).enumerated() {
                    var sum: Float = 0
                    for k in 0..<factor { sum += f.values[(row * factor + k) * f.width + column] }
                    out[row * width + index] = sum / Float(factor)
                }
            }
            return out
        }
        let width = (cur.width + columnStep - 1) / columnStep
        let a = Features(width: width, height: rows, values: reduce(prev))
        let b = Features(width: width, height: rows, values: reduce(cur))
        let limit = maximumShift / factor, backLimit = maximumBackShift / factor
        var costs: [(shift: Int, cost: Float)] = []
        for shift in -backLimit...limit {
            guard let cost = bodyCost(prev: a, cur: b, shift: shift, rowStep: 1, level: level, rowScale: factor) else { continue }
            costs.append((shift * factor, cost))
        }
        // Local minima, lowest first, at least 3 coarse steps apart.
        let sorted = costs.sorted { $0.cost < $1.cost }
        var picks: [Int] = []
        for entry in sorted where picks.allSatisfy({ abs($0 - entry.shift) > 3 * factor }) {
            picks.append(entry.shift)
            if picks.count == 4 { break }
        }
        if !picks.contains(0) { picks.append(0) }
        return picks
    }

    /// Mean row difference for `shift`, over the rows that follow the scroll:
    /// a run of badly matching rows at the top or bottom of the overlap (a
    /// navbar, translucent or not, or a pinned banner) is left out, but
    /// mismatches inside the content count in full.
    static func bodyCost(prev: Features, cur: Features, shift: Int, rowStep: Int, level: Float,
                         rowScale: Int = 1) -> Float? {
        let height = cur.height
        let first = max(0, -shift), last = min(height, height - shift)
        guard last - first >= max(4, height / 5) else { return nil }
        let width = cur.width
        var costs: [Float] = []
        var detail: [Float] = []
        costs.reserveCapacity((last - first) / rowStep + 1)
        detail.reserveCapacity((last - first) / rowStep + 1)
        cur.values.withUnsafeBufferPointer { c in
            prev.values.withUnsafeBufferPointer { p in
                for row in stride(from: first, to: last, by: rowStep) {
                    let curBase = row * width, prevBase = (row + shift) * width
                    var sum: Float = 0, magnitude: Float = 0
                    for column in 0..<width {
                        sum += abs(c[curBase + column] - p[prevBase + column])
                        magnitude += abs(c[curBase + column]) + abs(p[prevBase + column])
                    }
                    costs.append(sum / Float(width))
                    detail.append(magnitude / Float(2 * width))
                }
            }
        }
        let sorted = costs.sorted()
        let median = sorted[sorted.count / 2]
        // Relative to how well the body matches: at the true shift the body
        // is near zero, so even a band that mismatches over half its width
        // (a floating box) stands out and is left out.
        let threshold = max(0.08 * level, median * 3)
        let cap = costs.count * 35 / 100
        // Length of the mismatching band from one edge. Matching rows are
        // bridged, both inside the band (a plain strip within a navbar) and
        // before it: a floating box sits a margin away from the edge, and the
        // rows below it match again.
        let bridge = max(2, 40 / rowScale)
        func edgeBand<S: Sequence>(_ indices: S) -> Int where S.Element == Int {
            var lastBad = -1
            for (position, index) in indices.enumerated() {
                guard position < cap else { break }
                if costs[index] > threshold { lastBad = position } else if position - lastBad > bridge { break }
            }
            return lastBad + 1
        }
        let top = edgeBand(costs.indices)
        let bottom = min(edgeBand(costs.indices.reversed()), costs.count - top)
        let range = top..<(costs.count - bottom)
        guard range.count >= max(4, costs.count / 3) else { return nil }
        // Blank rows match blank rows perfectly. A shift whose overlap is
        // mostly whitespace proves nothing, however low its cost.
        let bodyDetail = detail[range].reduce(0, +) / Float(range.count)
        guard bodyDetail >= 0.35 * level else { return nil }
        return costs[range].reduce(0, +) / Float(range.count)
    }

    /// Rows at the bottom holding something pinned while the content scrolled:
    /// a full-width banner, or a floating box such as a cookie prompt. A row
    /// qualifies when a stretch of it with real content stayed exactly put.
    /// Over-estimating is harmless (new rows are just taken from higher up),
    /// missing one repeats the box down the whole image, so this errs wide.
    static func pinnedBottomRows(_ previous: Samples, _ current: Samples, band: ClosedRange<Int>, shift: Int = 0) -> Int {
        // Consent panels can be most of the window tall (Stack Overflow's
        // covers about 60%). Over-estimating only moves where new rows are taken
        // from; at 50 ms between grabs the top third still covers any scroll.
        let cap = current.height * 65 / 100
        let minimumRun = max(4, band.count * 5 / 100)
        // Panels have plain stretches (padding, short bullet lines) between
        // lines of text; bridge up to a twelfth of the frame.
        let gap = max(48, current.height / 12)
        func unchanged(_ row: Int, _ column: Int) -> Bool {
            abs(current.value(row, column) - previous.value(row, column)) < unchangedThreshold
        }
        // A pinned box sits over content that scrolls: only columns that move
        // in the top third of the frame count. A sticky sidebar is still
        // everywhere and must not look like a banner (x.com: it claimed most of
        // the frame and starved the stitch).
        let topRows = max(1, current.height / 3)
        let movesAbove: [Bool] = (0..<current.columnCount).map { column in
            var sum: Float = 0
            for row in Swift.stride(from: 0, to: topRows, by: 2) {
                sum += abs(current.value(row, column) - previous.value(row, column))
            }
            return sum / Float((topRows + 1) / 2) > unchangedThreshold
        }
        var highest = -1                       // rows from the bottom to the highest pinned row
        var hits = 0                           // rows that qualified
        var pinnedColumns: ClosedRange<Int>?   // where that row's pinned stretch is
        for offset in 0..<cap {
            let row = current.height - 1 - offset
            var start = band.lowerBound, low: Float = 255, high: Float = 0, evidence = 0
            for column in band {
                let value = current.value(row, column)
                if movesAbove[column], unchanged(row, column) {
                    low = min(low, value); high = max(high, value)
                    // Evidence of pinning: the same here, but not what scrolling
                    // would have brought. Flat colour (a big purple graphic after
                    // a small scroll) is the same both ways and proves nothing.
                    // Rows within one shift of the bottom show content that came
                    // from below the previous frame; matching in place there is
                    // evidence by itself.
                    if shift > 0, row + shift >= current.height
                        || abs(value - previous.value(row + shift, column)) > 4 { evidence += 1 }
                    if column - start + 1 >= minimumRun, high - low > 24, shift == 0 || evidence >= max(2, minimumRun / 4) {
                        highest = offset
                        hits += 1
                        // Extend the stretch to its full unchanged width.
                        var end = column
                        while end < band.upperBound, unchanged(row, end + 1) { end += 1 }
                        pinnedColumns = start...end
                        break
                    }
                } else {
                    start = column + 1; low = 255; high = 0; evidence = 0
                }
            }
            // A banner's own padding rows have no detail; allow a gap, but
            // stop once well past the top of anything pinned. Pinned content
            // starts at or near the bottom edge: nothing there, nothing pinned
            // (one stray match far up a scrolling feed is not a banner).
            if offset - max(highest, 0) > gap { break }
        }
        guard highest >= 0, hits >= 3, let columns = pinnedColumns else { return 0 }
        // Above its highest line of content a banner usually has plain padding:
        // still pinned, just without detail. Follow the same columns up while
        // they stay unchanged.
        // Bounded: plain unchanged columns (a dark gutter) would otherwise
        // climb all the way to the cap.
        let paddingLimit = min(cap, highest + 1 + max(48, current.height / 8))
        while highest + 1 < paddingLimit,
              columns.allSatisfy({ unchanged(current.height - 2 - highest, $0) }) { highest += 1 }
        return min(cap, highest + 1 + 4)
    }
}
