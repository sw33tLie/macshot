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

    private enum CodingKeys: String, CodingKey { case id, startTime, endTime, speedFactor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, or: UUID())
        startTime = c.decode(.startTime, or: 0)
        endTime = c.decode(.endTime, or: 0)
        let factor = c.decode(.speedFactor, or: 2.0)
        speedFactor = VideoSpeedSegment.clampFactor(factor.isFinite ? factor : 2)
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

    /// Immutable source-to-output mapping. A freeze consumes no source time;
    /// the composition builder separately locates the frame to repeat.
    struct Piece: Sendable {
        enum Kind: Int, Sendable { case normal, speed, freeze }
        let kind: Kind
        let srcStart: Double
        let srcEnd: Double
        let compositionDuration: Double

        nonisolated var factor: Double {
            guard compositionDuration > 0 else { return 1 }
            return (srcEnd - srcStart) / compositionDuration
        }
        nonisolated var sourceDuration: Double { max(0, srcEnd - srcStart) }
    }

    /// Kept ranges use half-open source intervals. Freezes at the start are
    /// included; those inside cuts or at the exclusive end are omitted.
    /// Later-starting speed segments take precedence during overlaps, then
    /// the earlier speed resumes. Equal starts use the later input entry.
    static func pieces(keptRanges: [(Double, Double)],
                       speeds: [VideoSpeedSegment],
                       freezes: [VideoFreezeSegment] = []) -> [Piece] {
        let normalizedSpeeds = speeds.enumerated()
            .filter { $0.element.startTime.isFinite && $0.element.endTime.isFinite &&
                $0.element.endTime > $0.element.startTime && $0.element.speedFactor.isFinite &&
                $0.element.speedFactor > 0 }
            .sorted { lhs, rhs in
                lhs.element.startTime == rhs.element.startTime ? lhs.offset < rhs.offset
                    : lhs.element.startTime < rhs.element.startTime
            }.map(\.element)
        let normalizedFreezes = freezes.enumerated()
            .filter { $0.element.atTime.isFinite && $0.element.holdDuration.isFinite && $0.element.holdDuration > 0 }
            .sorted { lhs, rhs in
                lhs.element.atTime == rhs.element.atTime ? lhs.offset < rhs.offset
                    : lhs.element.atTime < rhs.element.atTime
            }.map(\.element)
        var result: [Piece] = []
        for (start, end) in keptRanges {
            guard start.isFinite, end.isFinite, start >= 0, end > start else { continue }
            let activeSpeeds = normalizedSpeeds.filter { $0.startTime < end && $0.endTime > start }
            let activeFreezes = normalizedFreezes.filter { $0.atTime >= start && $0.atTime < end }
            var boundaries: Set<Double> = [start, end]
            for speed in activeSpeeds {
                boundaries.insert(max(start, speed.startTime))
                boundaries.insert(min(end, speed.endTime))
            }
            for freeze in activeFreezes { boundaries.insert(freeze.atTime) }
            let points = boundaries.sorted()
            for (left, right) in zip(points, points.dropFirst()) {
                for freeze in activeFreezes where freeze.atTime == left {
                    result.append(Piece(kind: .freeze, srcStart: left, srcEnd: left,
                        compositionDuration: VideoFreezeSegment.clampDuration(freeze.holdDuration)))
                }
                let speed = activeSpeeds.last { $0.startTime <= left && $0.endTime >= right }
                let factor = speed.map { VideoSpeedSegment.clampFactor($0.speedFactor) } ?? 1
                result.append(Piece(kind: factor == 1 ? .normal : .speed, srcStart: left, srcEnd: right,
                                    compositionDuration: (right - left) / factor))
            }
        }
        return result
    }

    /// Total composition-clock duration covered by the pieces.
    static func totalCompositionDuration(_ pieces: [Piece]) -> Double {
        return pieces.reduce(0) { $0 + $1.compositionDuration }
    }
}
