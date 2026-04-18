import Foundation

/// A source-asset range that plays back at a non-1× speed.
///
/// Unlike zoom / censor (pixel transforms) or cuts (frames removed), a speed
/// segment is a *time scaling*: the composition-clock duration of the range
/// is `(srcEnd - srcStart) / speedFactor`. `speedFactor > 1` makes the range
/// play faster; `speedFactor < 1` slower. A factor of exactly 1 is a no-op
/// and is not allowed — callers should delete the segment instead.
///
/// Semantics are deliberately kept simple to match existing segment types:
///   - Times are stored in source-asset seconds (pre-trim, pre-cut).
///   - Speed segments never overlap each other. The UI enforces this.
///   - Speed segments should not overlap cut ranges. The export pipeline
///     clips them to the kept ranges; the UI prevents new overlaps.
///   - Audio scales along with video. On macOS the standard
///     `AVMutableCompositionTrack.scaleTimeRange` re-pitches audio (no
///     pitch preservation). That matches iMovie's default behavior and
///     keeps the pipeline simple.
final class VideoSpeedSegment: Codable {

    /// Floor on the *composition* duration of a speed segment — keeps very
    /// short / very fast ramps from becoming zero-length. `src_duration /
    /// speedFactor >= minCompDuration`.
    static let minCompDuration: Double = 0.1
    /// Allowed factor range. 0.25× is plenty slow for tutorials; 10× is the
    /// upper bound (past that, short segments collapse below the composition
    /// duration floor and frame duplication becomes unhelpful).
    static let minFactor: Double = 0.25
    static let maxFactor: Double = 10.0

    /// Presets surfaced in the right-click menu. 1× is intentionally absent
    /// (use "Delete Speed" instead).
    static let presetFactors: [Double] = [0.25, 0.5, 0.75, 2.0, 3.0, 5.0, 10.0]

    var id: UUID
    var startTime: Double
    var endTime: Double
    var speedFactor: Double

    init(id: UUID = UUID(), startTime: Double, endTime: Double, speedFactor: Double) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.speedFactor = VideoSpeedSegment.clampFactor(speedFactor)
    }

    /// Source-asset duration of the segment (before speed scaling).
    var sourceDuration: Double { max(0, endTime - startTime) }

    /// Composition-clock duration (after speed scaling).
    var compositionDuration: Double {
        guard speedFactor > 0 else { return sourceDuration }
        return sourceDuration / speedFactor
    }

    static func clampFactor(_ f: Double) -> Double {
        return max(minFactor, min(maxFactor, f))
    }

    /// Two speed segments overlap if their source ranges intersect.
    /// Touching endpoints don't count (same convention as zoom/censor).
    func overlaps(startTime s: Double, endTime e: Double) -> Bool {
        return startTime < e && endTime > s
    }
}

/// Helpers that combine cuts + speed into the unified time map the
/// compositor uses. Speed segments are intersected with the kept ranges
/// produced by `VideoCuts.keptRanges`, so a speed range overlapping a cut
/// is silently trimmed to the surviving portion.
enum VideoSpeeds {

    /// A segment of a kept range, tagged with the speed it should play at.
    struct Piece {
        /// Source-asset range this piece covers.
        let srcStart: Double
        let srcEnd: Double
        /// Speed factor applied to this piece (1.0 when no segment covers it).
        let factor: Double

        var sourceDuration: Double { max(0, srcEnd - srcStart) }
        var compositionDuration: Double {
            guard factor > 0 else { return sourceDuration }
            return sourceDuration / factor
        }
    }

    /// Break `keptRanges` into pieces tagged with their speed factor. Each
    /// kept range is sliced at every speed-segment boundary it overlaps;
    /// gaps get factor = 1.
    ///
    /// Speed segments are sorted + de-overlapped defensively even though
    /// the UI already enforces non-overlap, so a bad input produces
    /// sensible output instead of undefined behavior.
    static func pieces(keptRanges: [(Double, Double)],
                       speeds: [VideoSpeedSegment]) -> [Piece] {
        // Normalize + clamp speeds to positive factor, drop zero-length.
        let normalized = speeds
            .filter { $0.endTime > $0.startTime && $0.speedFactor > 0 }
            .sorted { $0.startTime < $1.startTime }

        // De-overlap greedily — later segment wins if its range intrudes.
        // In practice the UI prevents this; this is a guard against bad
        // user input or future model changes.
        var clean: [(Double, Double, Double)] = []
        for s in normalized {
            if let last = clean.last, s.startTime < last.1 {
                // Overlap: truncate the previous piece at s.startTime.
                clean[clean.count - 1] = (last.0, max(last.0, s.startTime), last.2)
            }
            if s.endTime > s.startTime {
                clean.append((s.startTime, s.endTime, s.speedFactor))
            }
        }

        var result: [Piece] = []
        for (rStart, rEnd) in keptRanges {
            guard rEnd > rStart else { continue }
            var cursor = rStart
            for (sStart, sEnd, factor) in clean {
                // Fast skip: segment ends before our cursor.
                if sEnd <= cursor { continue }
                // Stop once we're past the kept range.
                if sStart >= rEnd { break }

                // Gap at 1× before the speed segment.
                let speedStart = max(sStart, cursor)
                let speedEnd = min(sEnd, rEnd)
                if speedStart > cursor {
                    result.append(Piece(srcStart: cursor, srcEnd: speedStart, factor: 1.0))
                }
                if speedEnd > speedStart {
                    result.append(Piece(srcStart: speedStart, srcEnd: speedEnd, factor: factor))
                    cursor = speedEnd
                }
            }
            if cursor < rEnd {
                result.append(Piece(srcStart: cursor, srcEnd: rEnd, factor: 1.0))
            }
        }
        return result
    }

    /// Total composition-clock duration covered by the pieces.
    static func totalCompositionDuration(_ pieces: [Piece]) -> Double {
        return pieces.reduce(0) { $0 + $1.compositionDuration }
    }
}
