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

/// Helpers that combine cuts + speed + freezes into the unified time map
/// the compositor uses. Speed and freeze segments are intersected with the
/// kept ranges produced by `VideoCuts.keptRanges`, so anything overlapping
/// a cut is silently dropped.
enum VideoSpeeds {

    /// One contiguous composition-clock segment describing what the user
    /// sees in that time window.
    ///
    /// The compositor maps composition-time → source-time via
    ///     `sourceTime = srcStart + (compTime - compStart) * factor`
    /// This single formula handles all three cases:
    ///   - `.normal`: factor = 1, comp duration = source duration.
    ///   - `.speed(factor)`: factor = user-chosen speed. Comp duration =
    ///     sourceDuration / factor.
    ///   - `.freeze`: `srcEnd = srcStart + tinyFreezeSlice`, factor is
    ///     effectively zero (slice / holdDuration), so the source time
    ///     barely advances within the frame and the compositor renders
    ///     the same frame for the whole hold.
    struct Piece {
        enum Kind { case normal, speed, freeze }

        let kind: Kind
        /// Source-asset range this piece covers. For freezes this is
        /// `[freezePoint, freezePoint + freezeSourceSlice]` — a tiny
        /// slice so `AVMutableCompositionTrack.insertTimeRange` actually
        /// inserts something we can then scaleTimeRange-stretch.
        let srcStart: Double
        let srcEnd: Double
        /// Composition-clock duration of this piece. Stored explicitly
        /// (not derived) so freezes can decouple it from source width.
        let compositionDuration: Double

        /// Factor passed to the compositor's time-map entry. Derived.
        var factor: Double {
            guard compositionDuration > 0 else { return 1.0 }
            return (srcEnd - srcStart) / compositionDuration
        }

        var sourceDuration: Double { max(0, srcEnd - srcStart) }

        /// Thin slice of source time used to back a freeze. Small enough
        /// that the compositor reads the same underlying frame during
        /// the entire hold, but non-zero so `insertTimeRange` actually
        /// inserts a usable range before we scale it up.
        static let freezeSourceSlice: Double = 1.0 / 600.0
    }

    /// Build the piece list from kept ranges + speed segments + freeze
    /// segments. Pieces are laid out in composition order (normal → speed
    /// → freeze → normal → …). Freezes are inserted AT their `atTime`
    /// and split the surrounding normal/speed piece in two.
    ///
    /// Defensive against bad input: freezes inside cuts are dropped,
    /// overlapping speeds are truncated (later one wins), and a freeze
    /// whose `atTime` falls outside all kept ranges is dropped.
    static func pieces(keptRanges: [(Double, Double)],
                       speeds: [VideoSpeedSegment],
                       freezes: [VideoFreezeSegment] = []) -> [Piece] {
        // Normalize + clamp speeds.
        let normalizedSpeeds = speeds
            .filter { $0.endTime > $0.startTime && $0.speedFactor > 0 }
            .sorted { $0.startTime < $1.startTime }

        var cleanSpeeds: [(Double, Double, Double)] = []
        for s in normalizedSpeeds {
            if let last = cleanSpeeds.last, s.startTime < last.1 {
                cleanSpeeds[cleanSpeeds.count - 1] = (last.0, max(last.0, s.startTime), last.2)
            }
            if s.endTime > s.startTime {
                cleanSpeeds.append((s.startTime, s.endTime, s.speedFactor))
            }
        }

        // Build the set of freeze points, sorted by atTime. Multiple
        // freezes at the same atTime are kept in input order — the
        // effects band UI prevents this in practice but we still emit
        // all of them if it happens.
        let sortedFreezes = freezes
            .filter { $0.holdDuration > 0 }
            .sorted { $0.atTime < $1.atTime }

        var result: [Piece] = []
        for (rStart, rEnd) in keptRanges {
            guard rEnd > rStart else { continue }
            // Freezes falling inside this kept range, in order.
            let rangeFreezes = sortedFreezes.filter { $0.atTime > rStart && $0.atTime < rEnd }

            // Walk the kept range, emitting normal/speed pieces split by
            // any freeze points that fall inside.
            var cursor = rStart
            var freezeIdx = 0

            // Helper: emit normal/speed pieces covering [cursor, until],
            // split further by speed segment boundaries.
            func emitSpeedSliced(until: Double) {
                guard until > cursor else { return }
                for (sStart, sEnd, factor) in cleanSpeeds {
                    if sEnd <= cursor { continue }
                    if sStart >= until { break }
                    let speedStart = max(sStart, cursor)
                    let speedEnd = min(sEnd, until)
                    if speedStart > cursor {
                        let src = cursor
                        let end = speedStart
                        result.append(Piece(kind: .normal, srcStart: src, srcEnd: end,
                                             compositionDuration: end - src))
                    }
                    if speedEnd > speedStart {
                        let src = speedStart
                        let end = speedEnd
                        result.append(Piece(kind: .speed, srcStart: src, srcEnd: end,
                                             compositionDuration: (end - src) / factor))
                        cursor = end
                    }
                }
                if cursor < until {
                    let src = cursor
                    let end = until
                    result.append(Piece(kind: .normal, srcStart: src, srcEnd: end,
                                         compositionDuration: end - src))
                    cursor = end
                }
            }

            while freezeIdx < rangeFreezes.count {
                let freeze = rangeFreezes[freezeIdx]
                // Emit everything up to the freeze point — but only if
                // cursor hasn't already passed `atTime` due to a
                // previous freeze's source slice overrunning it.
                if freeze.atTime > cursor {
                    emitSpeedSliced(until: freeze.atTime)
                }
                // Insert the freeze piece. Source slice is tiny; scaled
                // up to holdDuration by the composition-insertion layer.
                // `src = max(atTime, cursor)` preserves monotonicity
                // when two freezes stack at (or very near) the same
                // atTime — rare, but handled gracefully.
                let src = max(freeze.atTime, cursor)
                let end = min(rEnd, src + Piece.freezeSourceSlice)
                if end > src {
                    result.append(Piece(kind: .freeze, srcStart: src, srcEnd: end,
                                         compositionDuration: freeze.holdDuration))
                    cursor = end
                }
                freezeIdx += 1
            }

            // Tail after the last freeze.
            emitSpeedSliced(until: rEnd)
        }
        return result
    }

    /// Total composition-clock duration covered by the pieces.
    static func totalCompositionDuration(_ pieces: [Piece]) -> Double {
        return pieces.reduce(0) { $0 + $1.compositionDuration }
    }
}
