import Foundation
import CoreGraphics

/// A timeline region where a rectangular area of the video is hidden/obscured.
/// Supports three styles: solid black fill, pixelation, or gaussian blur.
///
/// - `startTime` / `endTime` are in seconds, relative to the full (untrimmed)
///   source asset. Export code clips these to the active trim range.
/// - `rect` is normalized to the video's natural (orientation-applied) bounds:
///   `(0, 0)` = top-left, `(1, 1)` = bottom-right. Origin follows the image
///   convention (y=0 at top).
/// - `style` controls how the rect is obscured.
/// - `fadeIn` / `fadeOut` auto-scale with duration (same curve as zoom) so very
///   short censors still read as a ramp rather than a hard cut.
final class VideoCensorSegment: Codable {

    static let minDuration: Double = 0.3
    static let defaultFade: Double = 0.25

    enum Style: String, Codable {
        case solid
        case pixelate
        case blur

        /// Intensity baked in at build time — we deliberately avoid exposing
        /// tuning knobs for a simpler UX.
        static let pixelateBlockSize: CGFloat = 20
        static let blurRadius: CGFloat = 15
    }

    var id: UUID
    var startTime: Double
    var endTime: Double
    var rect: CGRect
    var style: Style
    var fadeIn: Double
    var fadeOut: Double

    init(id: UUID = UUID(),
         startTime: Double,
         endTime: Double,
         rect: CGRect = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3),
         style: Style = .blur,
         fadeIn: Double = defaultFade,
         fadeOut: Double = defaultFade) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.rect = VideoCensorSegment.clampedRect(rect)
        self.style = style
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    var duration: Double { max(0, endTime - startTime) }

    /// See `VideoZoomSegment.autoFade(for:)` — same formula for consistency.
    static func autoFade(for duration: Double) -> Double {
        let capByDuration = max(0.05, duration * 0.20)
        return min(defaultFade, capByDuration)
    }

    /// Effective fade durations — honors the user's fadeIn/fadeOut, clamped
    /// to half the segment so there's always a plateau frame between ramps.
    var effectiveFadeIn: Double {
        let cap = max(0, duration / 2 - 0.001)
        return min(max(fadeIn, 0), cap)
    }
    var effectiveFadeOut: Double {
        let cap = max(0, duration / 2 - 0.001)
        return min(max(fadeOut, 0), cap)
    }

    /// Opacity of the censor effect at time `t` (source-asset clock).
    /// Returns 0 outside the segment, 1 during plateau, eased 0→1 and 1→0 on
    /// the fade edges. Useful for cross-fading solids/blurs in and out so the
    /// hide doesn't pop harshly.
    func opacity(at t: Double) -> CGFloat {
        guard t >= startTime, t <= endTime, duration > 0 else { return 0 }
        let fIn = effectiveFadeIn
        let fOut = effectiveFadeOut
        let into = t - startTime
        let toEnd = endTime - t

        if into < fIn, fIn > 0 {
            return easeInOut(CGFloat(into / fIn))
        } else if toEnd < fOut, fOut > 0 {
            return easeInOut(CGFloat(toEnd / fOut))
        } else {
            return 1.0
        }
    }

    private func easeInOut(_ x: CGFloat) -> CGFloat {
        let c = max(0, min(1, x))
        return c * c * (3 - 2 * c)
    }

    /// Keep the rect fully inside the normalized video bounds and prevent
    /// zero-area rectangles that would make the popover picker unusable.
    static func clampedRect(_ r: CGRect) -> CGRect {
        let minSize: CGFloat = 0.02
        var x = max(0, min(1 - minSize, r.origin.x))
        var y = max(0, min(1 - minSize, r.origin.y))
        var w = max(minSize, min(1 - x, r.size.width))
        var h = max(minSize, min(1 - y, r.size.height))
        // Re-clamp in case width/height forced a shift
        if x + w > 1 { x = 1 - w }
        if y + h > 1 { y = 1 - h }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Whether this segment's time range overlaps another censor or zoom.
    /// Touching endpoints do not count as overlap.
    func overlaps(startTime other_start: Double, endTime other_end: Double) -> Bool {
        return startTime < other_end && endTime > other_start
    }
}
