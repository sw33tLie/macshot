import Foundation

/// A point-in-time "freeze" — pauses the video on a single source frame for
/// `holdDuration` seconds of composition time before resuming playback.
///
/// A freeze consumes no original footage. It adds exactly `holdDuration` to
/// the edited timeline, holds source time constant, and inserts silence in
/// every audio track. The composition builder locates the actual source frame
/// independently of the edit's source-to-output time mapping.
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

    private enum CodingKeys: String, CodingKey { case id, atTime, holdDuration }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, or: UUID())
        atTime = c.decode(.atTime, or: 0)
        let hold = c.decode(.holdDuration, or: Self.defaultDuration)
        holdDuration = VideoFreezeSegment.clampDuration(hold.isFinite ? hold : Self.defaultDuration)
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
