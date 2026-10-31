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
        /// (sidebars): they belong in the first frame only.
        let fixedSides: [Range<Int>]
    }

    /// Below this mean per-sample difference a column or row counts as unchanged.
    static let unchangedThreshold: Float = 1.5

    /// Compares `current` with `previous`. Returns nil when the frames can't be
    /// aligned with confidence: blank content, too little overlap, or no shift
    /// that explains the change.
    /// - Parameter hint: the shift seen last time, used only to break near-ties
    ///   on repetitive content.
    static func match(previous: Samples, current: Samples, hint: Int = 0) -> Match? {
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
        let (prev, cur) = informative(features(previous, band: band), features(current, band: band))
        let level = texture(cur)
        guard level >= 0.3 else { return nil }

        let height = current.height
        let maximumShift = height * 4 / 5
        let candidates = coarseCandidates(prev: prev, cur: cur, maximumShift: maximumShift, level: level)
        var best: (shift: Int, cost: Float)?
        var scored: [(shift: Int, cost: Float)] = []
        for candidate in candidates {
            for shift in max(-maximumShift, candidate - 6)...min(maximumShift, candidate + 6) {
                guard let cost = bodyCost(prev: prev, cur: cur, shift: shift, rowStep: 1, level: level) else { continue }
                scored.append((shift, cost))
                if best == nil || cost < best!.cost { best = (shift, cost) }
            }
        }
        // Thresholds scale with how much there is to align on: sparse text and
        // dense photos produce very different absolute differences.
        guard var chosen = best, chosen.cost <= 0.45 * level else { return nil }
        // Repetitive content (identical list rows) can score several shifts
        // almost equally; prefer the one that continues the current motion.
        let tolerance = max(0.02 * level, chosen.cost * 0.08)
        let ties = scored.filter { $0.cost <= chosen.cost + tolerance && abs($0.shift - chosen.shift) > 3 }
        if !ties.isEmpty {
            let all = ties + [chosen]
            chosen = all.min { abs($0.shift - hint) < abs($1.shift - hint) }!
        }
        if chosen.shift != 0, let still = bodyCost(prev: prev, cur: cur, shift: 0, rowStep: 1, level: level),
           still < chosen.cost + 0.1 * level {
            // Not moving explains the frames about as well: don't invent a scroll.
            return Match(shift: 0, band: band, staticBottomRows: 0, fixedSides: [])
        }
        let bottom = chosen.shift > 0 ? pinnedBottomRows(previous, current, band: band) : 0
        return Match(shift: chosen.shift, band: band, staticBottomRows: bottom,
                     fixedSides: fixedSides(previous, current, band: band, change: change))
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
    /// moves (sidebars), so it isn't repeated down the stitched image. A plain
    /// margin, or a smooth fixed background, isn't a sidebar.
    static func fixedSides(_ previous: Samples, _ current: Samples, band: ClosedRange<Int>,
                           change: [Float]) -> [Range<Int>] {
        func isFixedContent(_ column: Int) -> Bool {
            guard change[column] <= unchangedThreshold else { return false }
            // Row-to-row detail: text and icons have it, a gradient doesn't.
            var detail: Float = 0
            for row in 1..<current.height { detail += abs(current.value(row, column) - current.value(row - 1, column)) }
            return detail / Float(max(1, current.height - 1)) > 1.5
        }
        // Cover only as far as the sidebar's own content reaches (plus one
        // sample): the gap before the scrolling column may hold content that
        // simply hadn't scrolled into view yet.
        let count = current.columnCount
        var sides: [Range<Int>] = []
        if band.lowerBound > 0, let inner = (0..<band.lowerBound).last(where: isFixedContent) {
            sides.append(0..<current.columns[min(inner + 1, band.lowerBound - 1)] + 1)
        }
        if band.upperBound < count - 1, let inner = ((band.upperBound + 1)..<count).first(where: isFixedContent) {
            sides.append(current.columns[max(inner - 1, band.upperBound + 1)]..<current.width)
        }
        return sides
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
    static func informative(_ prev: Features, _ cur: Features) -> (Features, Features) {
        var keep: [Int] = []
        for column in 0..<cur.width {
            var detail: Float = 0
            for row in stride(from: 0, to: cur.height, by: 2) {
                detail += abs(cur.values[row * cur.width + column]) + abs(prev.values[row * prev.width + column])
            }
            if detail / Float(cur.height) > 1 { keep.append(column) }
        }
        guard keep.count >= 8, keep.count < cur.width else { return (prev, cur) }
        func select(_ f: Features) -> Features {
            var values = [Float](repeating: 0, count: f.height * keep.count)
            for row in 0..<f.height {
                for (index, column) in keep.enumerated() { values[row * keep.count + index] = f.values[row * f.width + column] }
            }
            return Features(width: keep.count, height: f.height, values: values)
        }
        return (select(prev), select(cur))
    }

    /// Coarse search on 4×-reduced rows; returns a few promising shifts.
    static func coarseCandidates(prev: Features, cur: Features, maximumShift: Int, level: Float) -> [Int] {
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
        let limit = maximumShift / factor
        var costs: [(shift: Int, cost: Float)] = []
        for shift in -limit...limit {
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
    static func pinnedBottomRows(_ previous: Samples, _ current: Samples, band: ClosedRange<Int>) -> Int {
        let cap = current.height * 35 / 100
        let minimumRun = max(4, band.count * 8 / 100)
        func unchanged(_ row: Int, _ column: Int) -> Bool {
            abs(current.value(row, column) - previous.value(row, column)) < unchangedThreshold
        }
        var highest = -1                       // rows from the bottom to the highest pinned row
        var pinnedColumns: ClosedRange<Int>?   // where that row's pinned stretch is
        for offset in 0..<cap {
            let row = current.height - 1 - offset
            var start = band.lowerBound, low: Float = 255, high: Float = 0
            for column in band {
                let value = current.value(row, column)
                if unchanged(row, column) {
                    low = min(low, value); high = max(high, value)
                    if column - start + 1 >= minimumRun, high - low > 24 {
                        highest = offset
                        // Extend the stretch to its full unchanged width.
                        var end = column
                        while end < band.upperBound, unchanged(row, end + 1) { end += 1 }
                        pinnedColumns = start...end
                        break
                    }
                } else {
                    start = column + 1; low = 255; high = 0
                }
            }
            // A banner's own padding rows have no detail; allow a gap, but
            // stop once well past the top of anything pinned.
            if highest >= 0, offset - highest > 48 { break }
        }
        guard highest >= 0, let columns = pinnedColumns else { return 0 }
        // Above its highest line of content a banner usually has plain padding:
        // still pinned, just without detail. Follow the same columns up while
        // they stay unchanged.
        while highest + 1 < cap,
              columns.allSatisfy({ unchanged(current.height - 2 - highest, $0) }) { highest += 1 }
        return min(cap, highest + 1 + 4)
    }
}
