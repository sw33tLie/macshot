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
/// - New censors cover the entire selected interval without fading. Existing
///   or explicitly chosen fades are retained.
final class VideoCensorSegment: Codable {

    static let minDuration: Double = 0.3
    static let defaultFade: Double = 0

    enum Style: String, Codable, Sendable {
        case solid
        case pixelate
        case blur

        /// Intensity baked in at build time — we deliberately avoid exposing
        /// tuning knobs for a simpler UX.
        nonisolated static let pixelateBlockSize: CGFloat = 20
        // Blur is a visual effect; use solid fill for opaque redaction.
        nonisolated static let blurRadius: CGFloat = 30
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

    private enum CodingKeys: String, CodingKey { case id, startTime, endTime, rect, style, fadeIn, fadeOut }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, or: UUID())
        startTime = c.decode(.startTime, or: 0)
        endTime = c.decode(.endTime, or: 0)
        rect = VideoCensorSegment.clampedRect(c.decode(.rect, or: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)))
        style = c.decode(.style, or: .blur)
        fadeIn = c.decode(.fadeIn, or: Self.defaultFade)
        fadeOut = c.decode(.fadeOut, or: Self.defaultFade)
    }

    var duration: Double { max(0, endTime - startTime) }

    static func autoFade(for duration: Double) -> Double { defaultFade }

    var effectiveFadeIn: Double { VideoEffectTiming.effectiveFade(fadeIn, duration: duration) }
    var effectiveFadeOut: Double { VideoEffectTiming.effectiveFade(fadeOut, duration: duration) }

    func opacity(at t: Double) -> CGFloat {
        VideoEffectTiming.opacity(at: t, start: startTime, end: endTime,
                                  fadeIn: fadeIn, fadeOut: fadeOut)
    }

    /// Keep the rect fully inside the normalized video bounds and prevent
    /// zero-area rectangles that would make the popover picker unusable.
    static func clampedRect(_ r: CGRect) -> CGRect {
        let minSize: CGFloat = 0.02
        var x = max(0, min(1 - minSize, r.origin.x))
        var y = max(0, min(1 - minSize, r.origin.y))
        let w = max(minSize, min(1 - x, r.size.width))
        let h = max(minSize, min(1 - y, r.size.height))
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
