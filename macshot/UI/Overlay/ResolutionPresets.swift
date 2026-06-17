import Foundation

/// Preset choices for the selection resolution box: aspect ratios (which lock the
/// selection's proportions) and common pixel resolutions (exact sizes).
enum ResolutionPreset {
    /// Freeform — clears any locked aspect ratio.
    case freeform
    /// Lock to an aspect ratio (width : height).
    case ratio(label: String, value: CGFloat)
    /// Set an exact pixel resolution.
    case resolution(label: String, w: Int, h: Int)

    var label: String {
        switch self {
        case .freeform: return L("Freeform")
        case .ratio(let label, _): return label
        case .resolution(let label, _, _): return label
        }
    }

    /// Aspect ratio (w/h) for ratio presets; nil otherwise.
    var aspectValue: CGFloat? {
        if case .ratio(_, let v) = self { return v }
        return nil
    }
}

enum ResolutionPresetCatalog {
    /// Aspect-ratio presets (the section that locks proportions).
    static let ratios: [ResolutionPreset] = [
        .freeform,
        .ratio(label: "1 : 1", value: 1.0 / 1.0),
        .ratio(label: "4 : 3", value: 4.0 / 3.0),
        .ratio(label: "3 : 2", value: 3.0 / 2.0),
        .ratio(label: "16 : 10", value: 16.0 / 10.0),
        .ratio(label: "16 : 9", value: 16.0 / 9.0),
        .ratio(label: "21 : 9", value: 21.0 / 9.0),
        .ratio(label: "5 : 1", value: 5.0 / 1.0),
        .ratio(label: "3 : 4", value: 3.0 / 4.0),
        .ratio(label: "9 : 16", value: 9.0 / 16.0),
    ]

    /// Common exact pixel resolutions.
    static let resolutions: [ResolutionPreset] = [
        .resolution(label: "1920 × 1080", w: 1920, h: 1080),
        .resolution(label: "1920 × 384", w: 1920, h: 384),
        .resolution(label: "1280 × 720", w: 1280, h: 720),
        .resolution(label: "1080 × 1080", w: 1080, h: 1080),
        .resolution(label: "1080 × 1920", w: 1080, h: 1920),
        .resolution(label: "800 × 600", w: 800, h: 600),
        .resolution(label: "640 × 480", w: 640, h: 480),
    ]
}
