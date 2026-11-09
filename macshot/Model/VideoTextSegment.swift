import Foundation
import CoreGraphics

/// A timeline region that overlays text on the video. Mirrors the temporal
/// model used by `VideoCensorSegment`: `startTime`/`endTime` are seconds on
/// the source-asset clock and `rect` is normalized to the natural-image
/// bounds (origin top-left).
///
/// Style is intentionally simpler than the screenshot text tool: one font
/// family, weight (regular/bold), italic toggle, color, optional background
/// fill and outline, alignment, fade in/out. Per-character formatting is
/// deliberately not supported — video labels are visually consistent strings.
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
        // Projects persist these segments: a missing or damaged field falls
        // back to its default rather than discarding the caption.
        id = c.decode(.id, or: UUID())
        startTime = c.decode(.startTime, or: 0)
        endTime = c.decode(.endTime, or: 0)
        rect = VideoTextSegment.clampedRect(c.decode(.rect, or: CGRect(x: 0.1, y: 0.78, width: 0.8, height: 0.14)))
        text = c.decode(.text, or: "")
        let size = c.decode(.fontSize, or: CGFloat(48))
        fontSize = size.isFinite ? min(400, max(6, size)) : 48
        bold = c.decode(.bold, or: false)
        italic = c.decode(.italic, or: false)
        textColor = c.decode(.textColor, or: .white)
        bgStyle = c.decode(.bgStyle, or: .none)
        bgColor = c.decode(.bgColor, or: .blackTransparent)
        alignment = c.decode(.alignment, or: .center)
        fadeIn = c.decode(.fadeIn, or: Self.defaultFade)
        fadeOut = c.decode(.fadeOut, or: Self.defaultFade)
        fontFamily = c.decode(.fontFamily, or: "System")
        outlineEnabled = c.decode(.outlineEnabled, or: false)
        outlineColor = c.decode(.outlineColor, or: .black)
        let outline = c.decode(.outlineWidth, or: CGFloat(2))
        outlineWidth = outline.isFinite ? min(40, max(0, outline)) : 2
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

    /// Keep the text fade ramps short enough to leave a visible plateau.
    static func autoFade(for duration: Double) -> Double {
        let capByDuration = max(0.05, duration * 0.20)
        return min(defaultFade, capByDuration)
    }

    var effectiveFadeIn: Double { VideoEffectTiming.effectiveFade(fadeIn, duration: duration) }
    var effectiveFadeOut: Double { VideoEffectTiming.effectiveFade(fadeOut, duration: duration) }

    func opacity(at t: Double) -> CGFloat {
        VideoEffectTiming.opacity(at: t, start: startTime, end: endTime,
                                  fadeIn: fadeIn, fadeOut: fadeOut)
    }

    /// Keep the rect fully inside the normalized video bounds and prevent
    /// degenerate sizes that would crash the rasterizer with a zero-pixel
    /// canvas.
    static func clampedRect(_ r: CGRect) -> CGRect {
        let minSize: CGFloat = 0.04
        var x = max(0, min(1 - minSize, r.origin.x))
        var y = max(0, min(1 - minSize, r.origin.y))
        let w = max(minSize, min(1 - x, r.size.width))
        let h = max(minSize, min(1 - y, r.size.height))
        if x + w > 1 { x = 1 - w }
        if y + h > 1 { y = 1 - h }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}


// MARK: - Last-used style memory

extension VideoTextSegment {
    private static let lastStyleKey = "videoTextLastUsedStyle"
    private static var cachedStyle: RememberedStyle?
    private static var pendingStyleWrite: Task<Void, Never>?

    /// Only visual defaults belong in preferences. Encoding a whole segment
    /// would unnecessarily persist the user's caption text, timing, UUID and
    /// position when all a future segment needs is its reusable appearance.
    private struct RememberedStyle: Codable {
        let fontSize: CGFloat
        let bold: Bool
        let italic: Bool
        let fontFamily: String
        let textColor: RGBA
        let bgStyle: BackgroundStyle
        let bgColor: RGBA
        let outlineEnabled: Bool
        let outlineColor: RGBA
        let outlineWidth: CGFloat
        let alignment: Alignment

        init(_ segment: VideoTextSegment) {
            fontSize = segment.fontSize
            bold = segment.bold
            italic = segment.italic
            fontFamily = segment.fontFamily
            textColor = segment.textColor
            bgStyle = segment.bgStyle
            bgColor = segment.bgColor
            outlineEnabled = segment.outlineEnabled
            outlineColor = segment.outlineColor
            outlineWidth = segment.outlineWidth
            alignment = segment.alignment
        }

        func apply(to segment: VideoTextSegment) {
            segment.fontSize = fontSize
            segment.bold = bold
            segment.italic = italic
            segment.fontFamily = fontFamily
            segment.textColor = textColor
            segment.bgStyle = bgStyle
            segment.bgColor = bgColor
            segment.outlineEnabled = outlineEnabled
            segment.outlineColor = outlineColor
            segment.outlineWidth = outlineWidth
            segment.alignment = alignment
        }
    }

    /// A new segment that starts with the style of the last edited text
    /// segment (color, background, font family/size, bold/italic, outline,
    /// alignment), so users don't have to re-apply the same styling for
    /// every new segment.
    static func withLastUsedStyle(startTime: Double, endTime: Double) -> VideoTextSegment {
        let seg = VideoTextSegment(startTime: startTime, endTime: endTime)
        if let cachedStyle {
            cachedStyle.apply(to: seg)
            return seg
        }
        guard let data = UserDefaults.standard.data(forKey: lastStyleKey),
              let saved = try? JSONDecoder().decode(RememberedStyle.self, from: data) else {
            return seg
        }
        cachedStyle = saved
        // JSONDecoder ignores unknown keys, so this also migrates payloads
        // written by the early implementation that encoded the full segment.
        saved.apply(to: seg)
        if let styleOnlyData = try? JSONEncoder().encode(saved), styleOnlyData != data {
            UserDefaults.standard.set(styleOnlyData, forKey: lastStyleKey)
        }
        return seg
    }

    /// Persist this segment's style as the default for future segments.
    func rememberStyle() {
        let style = RememberedStyle(self)
        Self.cachedStyle = style
        Self.pendingStyleWrite?.cancel()
        // Sliders emit many continuous changes. Keep the latest style in
        // memory immediately so newly-added captions inherit it, but coalesce
        // preference encoding/writes until the interaction settles.
        Self.pendingStyleWrite = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled,
                  let data = try? JSONEncoder().encode(style) else { return }
            UserDefaults.standard.set(data, forKey: Self.lastStyleKey)
        }
    }
}
