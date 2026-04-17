import Foundation
import CoreGraphics

/// A timeline region where the rendered video zooms into a chosen point.
///
/// - `startTime` / `endTime` are in seconds, relative to the full (untrimmed)
///   source asset. Export code clips these to the active trim range.
/// - `zoomLevel` is a multiplier: 1.0 = no zoom, 2.0 = 2x magnification.
/// - `center` is normalized to the source video's natural (non-transformed)
///   bounds: (0, 0) = top-left, (1, 1) = bottom-right. The current UI keeps it
///   at (0.5, 0.5) and the transform clamps to valid translations.
/// - `fadeIn` / `fadeOut` are the transition ramp durations at each edge.
///   Clamped so they never exceed half the segment.
final class VideoZoomSegment: Codable {

    static let minDuration: Double = 0.3
    /// Target fade duration for a generously long segment. For shorter
    /// segments we auto-scale down so the plateau always dominates.
    static let defaultFade: Double = 0.35
    static let minZoom: CGFloat = 1.2
    static let maxZoom: CGFloat = 5.0

    /// Returns the fade duration auto-scaled so the combined in+out fades
    /// never exceed ~40 % of the segment, preserving a visible plateau.
    static func autoFade(for duration: Double) -> Double {
        // One fade (in or out) max length: 20 % of total, capped at defaultFade.
        let capByDuration = max(0.05, duration * 0.20)
        return min(defaultFade, capByDuration)
    }

    var id: UUID
    var startTime: Double
    var endTime: Double
    var zoomLevel: CGFloat
    var center: CGPoint
    var fadeIn: Double
    var fadeOut: Double

    init(id: UUID = UUID(),
         startTime: Double,
         endTime: Double,
         zoomLevel: CGFloat = 2.0,
         center: CGPoint = CGPoint(x: 0.5, y: 0.5),
         fadeIn: Double = defaultFade,
         fadeOut: Double = defaultFade) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.zoomLevel = zoomLevel
        self.center = center
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    var duration: Double { max(0, endTime - startTime) }

    /// Effective fade duration — auto-scales to keep the plateau dominant
    /// when segments are short. If the caller has explicitly shortened `fadeIn`
    /// below the auto-fade, that explicit value wins (user intent is preserved).
    var effectiveFadeIn: Double {
        let auto = Self.autoFade(for: duration)
        let target = min(fadeIn, auto)
        let cap = max(0, duration / 2 - 0.001)
        return min(max(target, 0), cap)
    }
    var effectiveFadeOut: Double {
        let auto = Self.autoFade(for: duration)
        let target = min(fadeOut, auto)
        let cap = max(0, duration / 2 - 0.001)
        return min(max(target, 0), cap)
    }

    /// Interpolated zoom level at time `t` (in seconds, source-asset clock).
    /// Returns 1.0 outside the segment.
    func zoomLevel(at t: Double) -> CGFloat {
        guard t >= startTime, t <= endTime, duration > 0 else { return 1.0 }
        let fIn = effectiveFadeIn
        let fOut = effectiveFadeOut
        let into = t - startTime
        let toEnd = endTime - t

        if into < fIn, fIn > 0 {
            let p = into / fIn
            return 1.0 + (zoomLevel - 1.0) * easeInOut(CGFloat(p))
        } else if toEnd < fOut, fOut > 0 {
            let p = toEnd / fOut
            return 1.0 + (zoomLevel - 1.0) * easeInOut(CGFloat(p))
        } else {
            return zoomLevel
        }
    }

    /// Smoothstep / cubic ease for zoom ramps. Input and output on [0, 1].
    private func easeInOut(_ x: CGFloat) -> CGFloat {
        let c = max(0, min(1, x))
        return c * c * (3 - 2 * c)
    }

    /// Translation (in video-pixel space) that places `center` at the visible
    /// center when applying `scale(zoom).translate(tx, ty)` to a frame of
    /// `videoSize`. Clamped so the zoom window never shows area outside the
    /// video's bounds (no black bars at edges from over-pan).
    func translation(zoom: CGFloat, videoSize: CGSize) -> CGPoint {
        guard zoom > 1.0001 else { return .zero }
        // Pixel coords of the chosen center
        let cx = center.x * videoSize.width
        let cy = center.y * videoSize.height
        // Amount to shift so that (cx, cy) lands at the center of the output
        let rawTx = videoSize.width / 2 - cx
        let rawTy = videoSize.height / 2 - cy
        // After zoom, max allowed translation is the distance from center to
        // the edge of the scaled content minus half the output.
        let maxTx = (zoom - 1) * videoSize.width / (2 * zoom)
        let maxTy = (zoom - 1) * videoSize.height / (2 * zoom)
        let clampedTx = min(max(rawTx / zoom, -maxTx), maxTx)
        let clampedTy = min(max(rawTy / zoom, -maxTy), maxTy)
        return CGPoint(x: clampedTx, y: clampedTy)
    }

    /// Whether this segment's time range overlaps another. Touching endpoints
    /// do not count as overlap.
    func overlaps(_ other: VideoZoomSegment) -> Bool {
        return startTime < other.endTime && endTime > other.startTime
    }
}
