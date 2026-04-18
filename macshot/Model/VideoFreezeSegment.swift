import Foundation

/// A point-in-time "freeze" — pauses the video on a single source frame for
/// `holdDuration` seconds of composition time before resuming playback.
///
/// Unlike zoom / censor (pixel transforms) or cuts (frames removed) or
/// speed (time scaling over a range), a freeze is essentially "time stops
/// at this moment for N seconds." Semantically it's a speed piece with
/// `factor ≈ 0` applied at a zero-width source range, but the time-map
/// math works out more naturally by treating it as its own piece type:
///
///   - Source range covered: a tiny slice at `atTime` (one frame's worth)
///     so `AVMutableCompositionTrack.insertTimeRange` actually inserts
///     something we can scale.
///   - Composition duration: `holdDuration` (independent of source).
///   - Audio: silent (we skip audio inserts on freeze pieces).
///
/// Times are stored in source-asset seconds (pre-trim, pre-cut). The UI
/// prevents two freezes from sharing exactly the same `atTime`, and the
/// export pipeline silently skips freezes that fall inside a cut.
final class VideoFreezeSegment: Codable {

    /// Lower bound on how long a freeze can last (composition time).
    /// Shorter than this and it's visually indistinguishable from no
    /// freeze at all.
    static let minHoldDuration: Double = 0.1
    /// Upper bound. Past this it's a still image, not an edit.
    static let maxHoldDuration: Double = 30.0

    /// Presets surfaced in the right-click menu.
    static let presetDurations: [Double] = [0.25, 0.5, 1.0, 2.0, 3.0, 5.0]
    static let defaultDuration: Double = 1.0

    var id: UUID
    /// Source-asset time of the frozen frame.
    var atTime: Double
    /// Composition-clock duration of the hold.
    var holdDuration: Double

    init(id: UUID = UUID(), atTime: Double, holdDuration: Double = defaultDuration) {
        self.id = id
        self.atTime = atTime
        self.holdDuration = VideoFreezeSegment.clampDuration(holdDuration)
    }

    static func clampDuration(_ d: Double) -> Double {
        return max(minHoldDuration, min(maxHoldDuration, d))
    }

    /// The "width" a freeze occupies on the effects band. Source time is
    /// a single point, but for drag/drop purposes the visible pill spans
    /// its composition duration mapped back into the band's source-time
    /// axis. We don't actually expose this directly — the band computes
    /// it when laying out pills. See `EffectsBandView.freezePillRect`.
    func compositionWidth() -> Double { holdDuration }
}
