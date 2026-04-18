import Foundation

/// A segment of the source asset to REMOVE from the exported video.
/// Unlike zoom / censor segments (which transform or overlay pixels), a cut
/// is temporal: the frames in its range never make it to the output.
///
/// Stored in source-asset time (seconds). The editor converts a trim range
/// plus a set of cuts into "kept ranges" that get inserted sequentially into
/// the composition that feeds both preview and export.
final class VideoCutSegment: Codable {

    static let minDuration: Double = 0.1

    var id: UUID
    var startTime: Double
    var endTime: Double

    init(id: UUID = UUID(), startTime: Double, endTime: Double) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
    }

    var duration: Double { max(0, endTime - startTime) }

    /// Two cuts overlap if their ranges intersect. Touching endpoints don't
    /// count (same convention as zoom/censor).
    func overlaps(startTime s: Double, endTime e: Double) -> Bool {
        return startTime < e && endTime > s
    }
}

/// Helper: given a trim range and a set of cuts, return the list of source
/// time ranges that survive (sorted, non-overlapping, all inside [trimStart,
/// trimEnd]). Each `(source.start, source.end)` becomes one insert into the
/// composition.
///
/// Cuts outside the trim range are ignored. Cuts that partially overlap the
/// trim edges are clipped to the trim.
enum VideoCuts {
    static func keptRanges(trimStart: Double,
                            trimEnd: Double,
                            cuts: [VideoCutSegment]) -> [(Double, Double)] {
        guard trimEnd > trimStart else { return [] }

        // Normalize + clip cuts to the trim range, drop zero-length results.
        var clipped: [(Double, Double)] = cuts
            .filter { $0.endTime > $0.startTime }
            .map { c in
                (max(trimStart, c.startTime), min(trimEnd, c.endTime))
            }
            .filter { $0.0 < $0.1 }
            .sorted { $0.0 < $1.0 }

        // Merge overlapping / touching cuts.
        var merged: [(Double, Double)] = []
        for c in clipped {
            if let last = merged.last, c.0 <= last.1 + 0.001 {
                merged[merged.count - 1] = (last.0, max(last.1, c.1))
            } else {
                merged.append(c)
            }
        }
        clipped = merged

        // Walk the trim range and emit the complement of the cuts.
        var kept: [(Double, Double)] = []
        var cursor = trimStart
        for (cs, ce) in clipped {
            if cs > cursor + 0.001 {
                kept.append((cursor, cs))
            }
            cursor = max(cursor, ce)
        }
        if cursor < trimEnd - 0.001 {
            kept.append((cursor, trimEnd))
        }
        return kept
    }

    /// Convert the kept ranges into a time-map that the custom compositor
    /// uses to look up source-asset time from composition-clock time.
    /// Each entry: `(compStart, compEnd, sourceOffset)` where
    /// `sourceTime = compTime + sourceOffset` when `compStart <= compTime < compEnd`.
    static func timeMap(for keptRanges: [(Double, Double)]) -> [(Double, Double, Double)] {
        var map: [(Double, Double, Double)] = []
        var cursor: Double = 0
        for (srcStart, srcEnd) in keptRanges {
            let len = srcEnd - srcStart
            guard len > 0 else { continue }
            let offset = srcStart - cursor  // sourceTime = compTime + offset
            map.append((cursor, cursor + len, offset))
            cursor += len
        }
        return map
    }

    /// Total duration of the composition output for a set of kept ranges.
    static func totalDuration(for keptRanges: [(Double, Double)]) -> Double {
        return keptRanges.reduce(0) { $0 + ($1.1 - $1.0) }
    }
}
