import Foundation
import CoreGraphics

// MARK: - Look settings (persisted per project; last used values seed new projects)

/// Straight RGBA in 0…1, sRGB.
nonisolated struct VideoRGBA: Codable, Equatable, Hashable, Sendable {
    var r: Double, g: Double, b: Double, a: Double
    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    static let white = VideoRGBA(1, 1, 1)
    static let black = VideoRGBA(0, 0, 0)
    static let clickDefault = VideoRGBA(1, 1, 1, 0.9)

    private enum CodingKeys: String, CodingKey { case r, g, b, a }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func channel(_ key: CodingKeys, _ fallback: Double) -> Double {
            let value = c.decode(key, or: fallback)
            return value.isFinite ? min(1, max(0, value)) : fallback
        }
        r = channel(.r, 0); g = channel(.g, 0); b = channel(.b, 0); a = channel(.a, 1)
    }
}

nonisolated enum VideoAspectRatio: String, Codable, CaseIterable, Sendable {
    case auto, wide16x9, vertical9x16, square, classic4x3, portrait3x4, portrait4x5, wide16x10

    /// Width ÷ height, or nil to follow the (cropped) recording.
    var ratio: CGFloat? {
        switch self {
        case .auto: return nil
        case .wide16x9: return 16.0 / 9.0
        case .vertical9x16: return 9.0 / 16.0
        case .square: return 1
        case .classic4x3: return 4.0 / 3.0
        case .portrait3x4: return 3.0 / 4.0
        case .portrait4x5: return 4.0 / 5.0
        case .wide16x10: return 16.0 / 10.0
        }
    }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .wide16x9: return "16:9"
        case .vertical9x16: return "9:16"
        case .square: return "1:1"
        case .classic4x3: return "4:3"
        case .portrait3x4: return "3:4"
        case .portrait4x5: return "4:5"
        case .wide16x10: return "16:10"
        }
    }
}

nonisolated struct VideoBackgroundStyle: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case gradient, color, image, wallpaper }
    var kind: Kind = .gradient
    /// Stable gradient identity ("mesh-3" or "linear-7") so a project written
    /// on macOS 15 (with mesh styles) still resolves sensibly on macOS 14.
    var gradientID: String = "linear-0"
    var color: VideoRGBA = VideoRGBA(0.11, 0.11, 0.13)
    /// Custom image copied into the project folder (file name only), or an
    /// absolute path to a system wallpaper.
    var imageName: String?
    /// 0…1, scaled to a radius relative to the canvas.
    var blur: Double = 0

    init() {}

    private enum CodingKeys: String, CodingKey { case kind, gradientID, color, imageName, blur }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.decode(.kind, or: .gradient)
        gradientID = c.decode(.gradientID, or: "linear-0")
        color = c.decode(.color, or: VideoRGBA(0.11, 0.11, 0.13))
        imageName = c.decodeOptional(.imageName)
        blur = VideoProjectLimits.unit(c.decode(.blur, or: 0))
    }
}

nonisolated struct VideoFrameStyle: Codable, Equatable, Sendable {
    /// Background, padding, rounded corners and shadow around the recording.
    var enabled = false
    var background = VideoBackgroundStyle()
    var aspect: VideoAspectRatio = .auto
    /// Margin around the recording as a fraction of its shorter side.
    var padding: Double = 0.08
    /// Corner radius in points at a 1080-pixel reference height.
    var cornerRadius: Double = 14
    /// 0…1 shadow strength.
    var shadow: Double = 0.6
    /// Hairline light border that gives dark recordings an edge.
    var border = false

    static let paddingRange: ClosedRange<Double> = 0...0.35
    static let radiusRange: ClosedRange<Double> = 0...64

    init() {}

    /// The frame (background) is visible when enabled, and also whenever a
    /// fixed aspect ratio adds space around the recording.
    var drawsBackground: Bool { enabled || aspect != .auto }

    private enum CodingKeys: String, CodingKey { case enabled, background, aspect, padding, cornerRadius, shadow, border }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.decode(.enabled, or: false)
        background = c.decode(.background, or: VideoBackgroundStyle())
        aspect = c.decode(.aspect, or: .auto)
        padding = VideoProjectLimits.clamp(c.decode(.padding, or: 0.08), Self.paddingRange, 0.08)
        cornerRadius = VideoProjectLimits.clamp(c.decode(.cornerRadius, or: 14), Self.radiusRange, 14)
        shadow = VideoProjectLimits.unit(c.decode(.shadow, or: 0.6))
        border = c.decode(.border, or: false)
    }
}

nonisolated struct VideoCursorStyle: Codable, Equatable, Sendable {
    enum Appearance: String, Codable, CaseIterable, Sendable { case system, dot, ring }
    enum ClickEffect: String, Codable, CaseIterable, Sendable { case none, ripple, spotlight, ring }

    var show = true
    var appearance: Appearance = .system
    /// Size multiplier relative to the real pointer.
    var size: Double = 1.4
    /// 0 = raw movement, 1 = very floaty.
    var smoothing: Double = 0.5
    var hideWhenIdle = false
    var idleDelay: Double = 2.0
    var hideWhileTyping = false
    var clickEffect: ClickEffect = .ripple
    var clickColor: VideoRGBA = .clickDefault
    var pressBounce = true
    /// 0…1 motion blur on fast pointer movement.
    var motionBlur: Double = 0.35
    /// Glide back to the starting position at the end (seamless GIF loops).
    var loopToStart = false
    /// 0…1: the pointer tilts in the direction it moves, like a real hand.
    var sway: Double = 0

    static let sizeRange: ClosedRange<Double> = 0.5...4

    init() {}

    private enum CodingKeys: String, CodingKey {
        case show, appearance, size, smoothing, hideWhenIdle, idleDelay, hideWhileTyping
        case clickEffect, clickColor, pressBounce, motionBlur, loopToStart, sway
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        show = c.decode(.show, or: true)
        appearance = c.decode(.appearance, or: .system)
        size = VideoProjectLimits.clamp(c.decode(.size, or: 1.4), Self.sizeRange, 1.4)
        smoothing = VideoProjectLimits.unit(c.decode(.smoothing, or: 0.5))
        hideWhenIdle = c.decode(.hideWhenIdle, or: false)
        idleDelay = VideoProjectLimits.clamp(c.decode(.idleDelay, or: 2), 0.5...10, 2)
        hideWhileTyping = c.decode(.hideWhileTyping, or: false)
        clickEffect = c.decode(.clickEffect, or: .ripple)
        clickColor = c.decode(.clickColor, or: .clickDefault)
        pressBounce = c.decode(.pressBounce, or: true)
        motionBlur = VideoProjectLimits.unit(c.decode(.motionBlur, or: 0.35))
        loopToStart = c.decode(.loopToStart, or: false)
        sway = VideoProjectLimits.unit(c.decode(.sway, or: 0))
    }
}

nonisolated struct VideoZoomStyle: Codable, Equatable, Sendable {
    enum Transition: String, Codable, CaseIterable, Sendable {
        case gentle, smooth, snappy
        /// Ramp duration (seconds) applied to new zooms.
        var duration: Double {
            switch self {
            case .gentle: return 1.2
            case .smooth: return 0.85
            case .snappy: return 0.5
            }
        }
    }

    var defaultLevel: Double = 1.8
    var transition: Transition = .smooth
    /// Pan directly between zooms separated by a short gap instead of
    /// zooming out and back in.
    var connectZooms = true
    /// 0…1 motion blur while the camera moves.
    var motionBlur: Double = 0.5
    /// How far the pointer may drift from the center before a following
    /// zoom recenters, as a fraction of the visible half-width.
    var followDeadZone: Double = 0.45

    static let connectGap: Double = 1.2

    init() {}

    private enum CodingKeys: String, CodingKey { case defaultLevel, transition, connectZooms, motionBlur, followDeadZone }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultLevel = VideoProjectLimits.clamp(c.decode(.defaultLevel, or: 1.8), 1.2...5.0, 1.8)
        transition = c.decode(.transition, or: .smooth)
        connectZooms = c.decode(.connectZooms, or: true)
        motionBlur = VideoProjectLimits.unit(c.decode(.motionBlur, or: 0.5))
        followDeadZone = VideoProjectLimits.clamp(c.decode(.followDeadZone, or: 0.45), 0.1...0.9, 0.45)
    }
}

nonisolated enum VideoOverlayPosition: String, Codable, CaseIterable, Sendable {
    case topLeft, topCenter, topRight, middleLeft, center, middleRight, bottomLeft, bottomCenter, bottomRight

    /// Normalized anchor (top-left origin).
    var anchor: CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: 0, y: 0)
        case .topCenter: return CGPoint(x: 0.5, y: 0)
        case .topRight: return CGPoint(x: 1, y: 0)
        case .middleLeft: return CGPoint(x: 0, y: 0.5)
        case .center: return CGPoint(x: 0.5, y: 0.5)
        case .middleRight: return CGPoint(x: 1, y: 0.5)
        case .bottomLeft: return CGPoint(x: 0, y: 1)
        case .bottomCenter: return CGPoint(x: 0.5, y: 1)
        case .bottomRight: return CGPoint(x: 1, y: 1)
        }
    }
}

nonisolated struct VideoKeystrokeStyle: Codable, Equatable, Sendable {
    var show = true
    var shortcutsOnly = false
    var position: VideoOverlayPosition = .bottomCenter
    /// Size multiplier.
    var size: Double = 1
    var lightAppearance = false

    init() {}

    private enum CodingKeys: String, CodingKey { case show, shortcutsOnly, position, size, lightAppearance }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        show = c.decode(.show, or: true)
        shortcutsOnly = c.decode(.shortcutsOnly, or: false)
        position = c.decode(.position, or: .bottomCenter)
        size = VideoProjectLimits.clamp(c.decode(.size, or: 1), 0.5...2.5, 1)
        lightAppearance = c.decode(.lightAppearance, or: false)
    }
}

nonisolated struct VideoCameraStyle: Codable, Equatable, Sendable {
    enum Shape: String, Codable, CaseIterable, Sendable { case circle, roundedSquare, roundedRect, vertical }

    var show = true
    var shape: Shape = .circle
    /// Diameter / height as a fraction of the canvas's shorter side.
    var size: Double = 0.24
    var position: VideoOverlayPosition = .bottomRight
    var mirror = true
    var shrinkOnZoom = true
    var shadow = true
    /// Replays where the bubble was during recording, including moves and
    /// resizes made while recording, instead of `position` and `size`.
    /// Only takes with a recorded placement track use it.
    var followsRecording = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case show, shape, size, position, mirror, shrinkOnZoom, shadow, followsRecording
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        show = c.decode(.show, or: true)
        shape = c.decode(.shape, or: .circle)
        size = VideoProjectLimits.clamp(c.decode(.size, or: 0.24), 0.08...0.6, 0.24)
        position = c.decode(.position, or: .bottomRight)
        mirror = c.decode(.mirror, or: true)
        shrinkOnZoom = c.decode(.shrinkOnZoom, or: true)
        shadow = c.decode(.shadow, or: true)
        followsRecording = c.decode(.followsRecording, or: false)
    }
}

nonisolated struct VideoCaptionStyle: Codable, Equatable, Sendable {
    var show = true
    /// Font size in points at a 1080-pixel reference height.
    var fontSize: Double = 44
    var position: VideoOverlayPosition = .bottomCenter
    var background = true
    var maxWords = 7

    init() {}

    private enum CodingKeys: String, CodingKey { case show, fontSize, position, background, maxWords }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        show = c.decode(.show, or: true)
        fontSize = VideoProjectLimits.clamp(c.decode(.fontSize, or: 44), 16...120, 44)
        position = c.decode(.position, or: .bottomCenter)
        background = c.decode(.background, or: true)
        maxWords = min(20, max(2, c.decode(.maxWords, or: 7)))
    }
}

nonisolated struct VideoCaptionSegment: Codable, Equatable, Sendable {
    var id = UUID()
    var startTime: Double
    var endTime: Double
    var text: String

    init(startTime: Double, endTime: Double, text: String) {
        self.startTime = startTime; self.endTime = endTime; self.text = text
    }

    private enum CodingKeys: String, CodingKey { case id, startTime, endTime, text }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(.id, or: UUID())
        startTime = c.decode(.startTime, or: 0)
        endTime = c.decode(.endTime, or: 0)
        text = c.decode(.text, or: "")
    }
}

/// Everything about a project's appearance that carries over to the next
/// recording ("remember my look").
nonisolated struct VideoLook: Codable, Equatable, Sendable {
    var frame = VideoFrameStyle()
    var cursor = VideoCursorStyle()
    var zoom = VideoZoomStyle()
    var keystrokes = VideoKeystrokeStyle()
    var camera = VideoCameraStyle()
    var captions = VideoCaptionStyle()

    init() {}

    private enum CodingKeys: String, CodingKey { case frame, cursor, zoom, keystrokes, camera, captions }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frame = c.decode(.frame, or: VideoFrameStyle())
        cursor = c.decode(.cursor, or: VideoCursorStyle())
        zoom = c.decode(.zoom, or: VideoZoomStyle())
        keystrokes = c.decode(.keystrokes, or: VideoKeystrokeStyle())
        camera = c.decode(.camera, or: VideoCameraStyle())
        captions = c.decode(.captions, or: VideoCaptionStyle())
    }

    static let defaultsKey = "videoEditorLook"

    /// First-run look for macshot recordings: a framed, zoom-ready scene.
    static var recordingDefault: VideoLook {
        var look = VideoLook()
        look.frame.enabled = true
        return look
    }

    static func remembered(defaults: UserDefaults = .standard) -> VideoLook? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(VideoLook.self, from: data)
    }

    func remember(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

nonisolated enum VideoProjectLimits {
    static func unit(_ value: Double) -> Double { clamp(value, 0...1, 0) }
    static func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
    static func normalizedRect(_ rect: CGRect) -> CGRect {
        let values = [rect.minX, rect.minY, rect.width, rect.height]
        guard values.allSatisfy({ $0.isFinite }) else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let minSize: CGFloat = 0.05
        let x = min(1 - minSize, max(0, rect.minX)), y = min(1 - minSize, max(0, rect.minY))
        let w = min(1 - x, max(minSize, rect.width)), h = min(1 - y, max(minSize, rect.height))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Project

/// The editable state of one video: timeline edits plus the look. Persisted
/// next to a recording (or in the app's project store for other files) and
/// autosaved, so closing the editor never loses work.
///
/// Segments stay reference types because the timeline edits them in place;
/// undo snapshots and persistence go through `encoded()`, which deep-copies.
final class VideoProject: Codable {
    static let currentVersion = 1

    var version = VideoProject.currentVersion
    /// Source duration when the project was saved; a different source length
    /// means the file changed and the project no longer applies.
    var sourceDuration: Double
    var trimStart: Double
    var trimEnd: Double
    var muted = false
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var look: VideoLook

    var zooms: [VideoZoomSegment] = []
    var censors: [VideoCensorSegment] = []
    var texts: [VideoTextSegment] = []
    var cuts: [VideoCutSegment] = []
    var speeds: [VideoSpeedSegment] = []
    var freezes: [VideoFreezeSegment] = []
    var captions: [VideoCaptionSegment] = []

    init(sourceDuration: Double, look: VideoLook) {
        self.sourceDuration = sourceDuration
        self.trimStart = 0
        self.trimEnd = sourceDuration
        self.look = look
    }

    private enum CodingKeys: String, CodingKey {
        case version, sourceDuration, trimStart, trimEnd, muted, crop, look
        case zooms, censors, texts, cuts, speeds, freezes, captions
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.decode(.version, or: VideoProject.currentVersion)
        let duration = c.decode(.sourceDuration, or: 0.0)
        sourceDuration = duration.isFinite && duration > 0 ? duration : 0
        let start = c.decode(.trimStart, or: 0.0), end = c.decode(.trimEnd, or: sourceDuration)
        trimStart = start.isFinite ? min(max(0, start), sourceDuration) : 0
        trimEnd = end.isFinite ? min(max(trimStart, end), sourceDuration) : sourceDuration
        if trimEnd - trimStart < 0.1 { trimStart = 0; trimEnd = sourceDuration }
        muted = c.decode(.muted, or: false)
        crop = VideoProjectLimits.normalizedRect(c.decode(.crop, or: CGRect(x: 0, y: 0, width: 1, height: 1)))
        look = c.decode(.look, or: VideoLook())
        zooms = Self.lenientArray(c, .zooms)
        censors = Self.lenientArray(c, .censors)
        texts = Self.lenientArray(c, .texts)
        cuts = Self.lenientArray(c, .cuts)
        speeds = Self.lenientArray(c, .speeds)
        freezes = Self.lenientArray(c, .freezes)
        captions = Self.lenientArray(c, .captions)
        sanitizeSegments()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(sourceDuration, forKey: .sourceDuration)
        try c.encode(trimStart, forKey: .trimStart)
        try c.encode(trimEnd, forKey: .trimEnd)
        try c.encode(muted, forKey: .muted)
        try c.encode(crop, forKey: .crop)
        try c.encode(look, forKey: .look)
        try c.encode(zooms, forKey: .zooms)
        try c.encode(censors, forKey: .censors)
        try c.encode(texts, forKey: .texts)
        try c.encode(cuts, forKey: .cuts)
        try c.encode(speeds, forKey: .speeds)
        try c.encode(freezes, forKey: .freezes)
        try c.encode(captions, forKey: .captions)
    }

    /// One corrupt segment costs that segment, not the project.
    private static func lenientArray<T: Decodable>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [T] {
        guard var list = try? c.nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [T] = []
        while !list.isAtEnd {
            if let value = try? list.decode(T.self) { result.append(value) }
            else if (try? list.decode(DiscardedValue.self)) == nil { break }
        }
        return result
    }

    private struct DiscardedValue: Decodable { init(from decoder: Decoder) throws {} }

    /// Drops segments that fall outside the source or have invalid ranges.
    func sanitizeSegments() {
        let d = sourceDuration
        func valid(_ s: Double, _ e: Double) -> Bool { s.isFinite && e.isFinite && s >= 0 && e > s && s < d }
        zooms = zooms.filter { valid($0.startTime, $0.endTime) }
        for z in zooms { z.endTime = min(z.endTime, d) }
        censors = censors.filter { valid($0.startTime, $0.endTime) }
        for s in censors { s.endTime = min(s.endTime, d) }
        texts = texts.filter { valid($0.startTime, $0.endTime) }
        for s in texts { s.endTime = min(s.endTime, d) }
        cuts = cuts.filter { valid($0.startTime, $0.endTime) }
        for s in cuts { s.endTime = min(s.endTime, d) }
        speeds = speeds.filter { valid($0.startTime, $0.endTime) }
        for s in speeds { s.endTime = min(s.endTime, d) }
        freezes = freezes.filter { $0.atTime.isFinite && $0.atTime >= 0 && $0.atTime < d }
        captions = captions.filter { valid($0.startTime, $0.endTime) }
    }

    // MARK: Snapshots

    func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    static func decode(_ data: Data) -> VideoProject? {
        guard let project = try? JSONDecoder().decode(VideoProject.self, from: data),
              project.sourceDuration > 0 else { return nil }
        return project
    }

    /// Deep copy (segments included).
    func copy() -> VideoProject? { VideoProject.decode(encoded()) }

    /// Whether the project changes the output relative to the source file.
    var hasEdits: Bool {
        trimStart > 0.01 || sourceDuration - trimEnd > 0.01 || muted
            || crop != CGRect(x: 0, y: 0, width: 1, height: 1)
            || look.frame.drawsBackground
            || !zooms.isEmpty || !censors.isEmpty || !texts.isEmpty || !cuts.isEmpty
            || !speeds.isEmpty || !freezes.isEmpty || !captions.isEmpty
    }
}
