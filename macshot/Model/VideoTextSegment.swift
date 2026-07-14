import Foundation
import CoreGraphics

/// A timeline region that overlays text on the video. Mirrors the temporal
/// model used by `VideoCensorSegment`: `startTime`/`endTime` are seconds on
/// the source-asset clock and `rect` is normalized to the natural-image
/// bounds (origin top-left).
///
/// Style is intentionally simpler than the screenshot text tool: one system
/// font, weight (regular/bold), italic toggle, color, optional background
/// fill, alignment, fade in/out. Per-character formatting is deliberately
/// not supported — video labels are visually consistent strings.
final class VideoTextSegment: Codable {

    static let minDuration: Double = 0.3
    static let defaultFade: Double = 0.25

    enum BackgroundStyle: String, Codable {
        case none      // text only (with optional shadow)
        case solid     // filled rectangle behind text
        case rounded   // pill — filled rounded rectangle behind text
    }

    enum Alignment: String, Codable {
        case left, center, right
    }

    /// RGBA in 0...1. Stored as four Doubles so encode/decode is plain JSON
    /// without NSColor secure-coding overhead. Same shape as the Codable
    /// pattern used for screenshot annotations (`AnnotationCodable`).
    struct RGBA: Codable, Hashable {
        var r: Double
        var g: Double
        var b: Double
        var a: Double

        static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
        static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
        static let blackTransparent = RGBA(r: 0, g: 0, b: 0, a: 0.7)
    }

    var id: UUID
    var startTime: Double
    var endTime: Double
    var rect: CGRect

    var text: String

    /// Logical font size in *points at 1080p reference height*. The
    /// rasterizer scales it to the actual render-pixel height when drawing
    /// so 48pt looks the same on a 720p export and a 4K export.
    var fontSize: CGFloat
    var bold: Bool
    var italic: Bool

    /// Font family name. The sentinel "System" selects the system UI font;
    /// anything else is resolved by name at raster time (with a system-font
    /// fallback when the family is not installed).
    var fontFamily: String

    var textColor: RGBA
    var bgStyle: BackgroundStyle
    var bgColor: RGBA

    /// Per-glyph outline stroked behind the text fill. `outlineWidth` is in
    /// points at the same 1080p reference scale as `fontSize`.
    var outlineEnabled: Bool
    var outlineColor: RGBA
    var outlineWidth: CGFloat

    var alignment: Alignment

    var fadeIn: Double
    var fadeOut: Double

    init(id: UUID = UUID(),
         startTime: Double,
         endTime: Double,
         rect: CGRect = CGRect(x: 0.1, y: 0.78, width: 0.8, height: 0.14),
         text: String = "Text",
         fontSize: CGFloat = 48,
         bold: Bool = true,
         italic: Bool = false,
         fontFamily: String = "System",
         textColor: RGBA = .white,
         bgStyle: BackgroundStyle = .rounded,
         bgColor: RGBA = .blackTransparent,
         outlineEnabled: Bool = false,
         outlineColor: RGBA = .black,
         outlineWidth: CGFloat = 2,
         alignment: Alignment = .center,
         fadeIn: Double = defaultFade,
         fadeOut: Double = defaultFade) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.rect = VideoTextSegment.clampedRect(rect)
        self.text = text
        self.fontSize = fontSize
        self.bold = bold
        self.italic = italic
        self.fontFamily = fontFamily
        self.textColor = textColor
        self.bgStyle = bgStyle
        self.bgColor = bgColor
        self.outlineEnabled = outlineEnabled
        self.outlineColor = outlineColor
        self.outlineWidth = outlineWidth
        self.alignment = alignment
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    // MARK: - Codable
    //
    // Explicit implementation (instead of the synthesized one) so segments
    // serialized by older versions — which lack the font-family and outline
    // keys — keep decoding: the new keys use `decodeIfPresent` + defaults.
    // All pre-existing keys and their encoded shapes are unchanged.

    private enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, rect, text
        case fontSize, bold, italic, fontFamily
        case textColor, bgStyle, bgColor
        case outlineEnabled, outlineColor, outlineWidth
        case alignment, fadeIn, fadeOut
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startTime = try c.decode(Double.self, forKey: .startTime)
        endTime = try c.decode(Double.self, forKey: .endTime)
        rect = try c.decode(CGRect.self, forKey: .rect)
        text = try c.decode(String.self, forKey: .text)
        fontSize = try c.decode(CGFloat.self, forKey: .fontSize)
        bold = try c.decode(Bool.self, forKey: .bold)
        italic = try c.decode(Bool.self, forKey: .italic)
        textColor = try c.decode(RGBA.self, forKey: .textColor)
        bgStyle = try c.decode(BackgroundStyle.self, forKey: .bgStyle)
        bgColor = try c.decode(RGBA.self, forKey: .bgColor)
        alignment = try c.decode(Alignment.self, forKey: .alignment)
        fadeIn = try c.decode(Double.self, forKey: .fadeIn)
        fadeOut = try c.decode(Double.self, forKey: .fadeOut)
        // Added later — absent in old archives, so fall back to defaults.
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? "System"
        outlineEnabled = try c.decodeIfPresent(Bool.self, forKey: .outlineEnabled) ?? false
        outlineColor = try c.decodeIfPresent(RGBA.self, forKey: .outlineColor) ?? .black
        outlineWidth = try c.decodeIfPresent(CGFloat.self, forKey: .outlineWidth) ?? 2
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startTime, forKey: .startTime)
        try c.encode(endTime, forKey: .endTime)
        try c.encode(rect, forKey: .rect)
        try c.encode(text, forKey: .text)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(bold, forKey: .bold)
        try c.encode(italic, forKey: .italic)
        try c.encode(fontFamily, forKey: .fontFamily)
        try c.encode(textColor, forKey: .textColor)
        try c.encode(bgStyle, forKey: .bgStyle)
        try c.encode(bgColor, forKey: .bgColor)
        try c.encode(outlineEnabled, forKey: .outlineEnabled)
        try c.encode(outlineColor, forKey: .outlineColor)
        try c.encode(outlineWidth, forKey: .outlineWidth)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(fadeIn, forKey: .fadeIn)
        try c.encode(fadeOut, forKey: .fadeOut)
    }

    var duration: Double { max(0, endTime - startTime) }

    /// See `VideoCensorSegment.autoFade(for:)` — same formula for consistency.
    static func autoFade(for duration: Double) -> Double {
        let capByDuration = max(0.05, duration * 0.20)
        return min(defaultFade, capByDuration)
    }

    var effectiveFadeIn: Double {
        let cap = max(0, duration / 2 - 0.001)
        return min(max(fadeIn, 0), cap)
    }
    var effectiveFadeOut: Double {
        let cap = max(0, duration / 2 - 0.001)
        return min(max(fadeOut, 0), cap)
    }

    /// Opacity at time `t` (source-asset clock). Eased ramp on the fade
    /// edges, plateau at 1.0, zero outside the segment. Same curve as
    /// `VideoCensorSegment.opacity(at:)` so multiple fading effects share
    /// a consistent visual rhythm.
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
    /// degenerate sizes that would crash the rasterizer with a zero-pixel
    /// canvas.
    static func clampedRect(_ r: CGRect) -> CGRect {
        let minSize: CGFloat = 0.04
        var x = max(0, min(1 - minSize, r.origin.x))
        var y = max(0, min(1 - minSize, r.origin.y))
        var w = max(minSize, min(1 - x, r.size.width))
        var h = max(minSize, min(1 - y, r.size.height))
        if x + w > 1 { x = 1 - w }
        if y + h > 1 { y = 1 - h }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}


// MARK: - Last-used style memory

extension VideoTextSegment {
    private static let lastStyleKey = "videoTextLastUsedStyle"

    /// A new segment that starts with the style of the last edited text
    /// segment (color, background, font family/size, bold/italic, outline,
    /// alignment), so users don't have to re-apply the same styling for
    /// every new segment.
    static func withLastUsedStyle(startTime: Double, endTime: Double) -> VideoTextSegment {
        let seg = VideoTextSegment(startTime: startTime, endTime: endTime)
        guard let data = UserDefaults.standard.data(forKey: lastStyleKey),
              let saved = try? JSONDecoder().decode(VideoTextSegment.self, from: data) else {
            return seg
        }
        seg.fontSize = saved.fontSize
        seg.bold = saved.bold
        seg.italic = saved.italic
        seg.fontFamily = saved.fontFamily
        seg.textColor = saved.textColor
        seg.bgStyle = saved.bgStyle
        seg.bgColor = saved.bgColor
        seg.outlineEnabled = saved.outlineEnabled
        seg.outlineColor = saved.outlineColor
        seg.outlineWidth = saved.outlineWidth
        seg.alignment = saved.alignment
        return seg
    }

    /// Persist this segment's style as the default for future segments.
    func rememberStyle() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.lastStyleKey)
        }
    }
}
