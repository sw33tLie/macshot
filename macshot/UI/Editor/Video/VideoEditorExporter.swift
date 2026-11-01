import AVFoundation

/// Export preferences. Persisted across sessions (existing keys).
struct VideoExportSettings: Equatable {
    enum Format: String { case mp4, gif }
    var format: Format = .mp4
    /// Output scale relative to the native canvas, 0 < scale ≤ 1.
    var scale: CGFloat = 1
    var quality: VideoQuality = .high
    var gifFPS: Int = 15

    static let scaleKey = "lastExportScale"
    static let qualityKey = "lastExportQuality"
    static let gifFPSKey = "gifExportFPS"
    static let formatKey = "videoEditorExportFormat"

    static func load(defaults: UserDefaults = .standard) -> VideoExportSettings {
        var settings = VideoExportSettings()
        let scale = defaults.object(forKey: scaleKey) as? Double ?? 1
        settings.scale = scale.isFinite && scale > 0 && scale <= 1 ? CGFloat(scale) : 1
        if let raw = defaults.string(forKey: qualityKey), let quality = VideoQuality(rawValue: raw) {
            settings.quality = quality
        }
        let fps = defaults.integer(forKey: gifFPSKey)
        settings.gifFPS = fps == 0 ? 15 : min(30, max(5, fps))
        if let raw = defaults.string(forKey: formatKey), let format = Format(rawValue: raw) { settings.format = format }
        return settings
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(Double(scale), forKey: Self.scaleKey)
        defaults.set(quality.rawValue, forKey: Self.qualityKey)
        defaults.set(gifFPS, forKey: Self.gifFPSKey)
        defaults.set(format.rawValue, forKey: Self.formatKey)
    }
}

/// Builds export jobs from an immutable copy of the project, so edits made
/// while an export runs never leak into it.
@MainActor
final class VideoEditorExporter {
    enum ExportError: LocalizedError {
        case invalidSetup
        var errorDescription: String? { "The video could not be prepared for export." }
    }

    private let document: VideoEditorDocument

    init(document: VideoEditorDocument) {
        self.document = document
    }

    /// Whether saving must render (otherwise the source file is copied as is).
    func needsRender(_ settings: VideoExportSettings) -> Bool {
        let project = document.project
        return settings.format == .gif || settings.scale < 0.999 || settings.quality != .high
            || project.hasEdits || document.cursorIsEditable || document.cameraURL != nil
            || (document.overlaysAreEditable && document.hasKeystrokes)
    }

    /// Canvas size the export will have.
    func outputSize(_ settings: VideoExportSettings) -> CGSize? {
        VideoRenderPlanner(document: document).layout(for: document.project, scale: settings.scale)?.canvasSize
    }

    /// Native canvas size at scale 1.
    var nativeCanvasSize: CGSize? {
        VideoRenderPlanner(document: document).layout(for: document.project)?.canvasSize
    }

    private struct Prepared {
        let project: VideoProject
        let planner: VideoRenderPlanner
        let processed: VideoCompositionBuilder.Result
        let composition: AVMutableVideoComposition
    }

    private func prepare(_ settings: VideoExportSettings, includeAudio: Bool, frameDuration: CMTime? = nil) throws -> Prepared {
        guard let project = document.project.copy() else { throw ExportError.invalidSetup }
        // Exports render at full quality with their own caches.
        let planner = VideoRenderPlanner(document: document)
        let processed = try planner.processed(project: project, from: project.trimStart, to: project.trimEnd,
                                              includeAudio: includeAudio)
        var options = VideoRenderPlanner.Options()
        options.scale = settings.scale
        options.exactPointer = true
        let composition = try planner.videoComposition(project: project, processed: processed, options: options,
                                                       frameDuration: frameDuration)
        return Prepared(project: project, planner: planner, processed: processed, composition: composition)
    }

    func mp4Job(_ settings: VideoExportSettings, outputURL: URL) throws -> VideoExportJob {
        let includeAudio = !document.project.muted
        let prepared = try prepare(settings, includeAudio: includeAudio)
        let lease = document.source.lease
        if settings.quality == .high {
            guard let session = AVAssetExportSession(asset: prepared.processed.composition,
                                                     presetName: AVAssetExportPresetHighestQuality) else {
                throw ExportError.invalidSetup
            }
            session.metadata = VideoFrameCadence.metadata(for: document.frameDuration)
            session.outputURL = outputURL
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true   // fast start (#452)
            session.videoComposition = prepared.composition
            if !includeAudio { session.audioMix = nil }
            return VideoExportJob(session: session, sourceLease: lease)
        }
        let canvas = prepared.composition.renderSize
        guard let plan = encodingPlan(settings, canvas: canvas, project: prepared.project) else {
            throw ExportError.invalidSetup
        }
        var request = VideoTranscoder.Request(
            asset: prepared.processed.composition, videoTrack: prepared.processed.videoTrack,
            audioTracks: includeAudio ? prepared.processed.audioTracks : [], composition: prepared.composition,
            timeRange: CMTimeRange(start: .zero, duration: prepared.processed.composition.duration),
            outputURL: outputURL, videoSettings: plan.outputSettings, decodedSize: nil,
            outputTransform: .identity, sourceFrameDuration: document.frameDuration)
        request.additionalVideoTracks = prepared.processed.cameraTrack.map { [$0] } ?? []
        return VideoExportJob(request: request, sourceLease: lease)
    }

    func gifRequest(_ settings: VideoExportSettings, outputURL: URL) throws -> GIFExporter.Request {
        let cadence = CMTime(value: 1, timescale: CMTimeScale(min(30, max(5, settings.gifFPS))))
        let prepared = try prepare(settings, includeAudio: false, frameDuration: cadence)
        var request = GIFExporter.Request(asset: prepared.processed.composition, videoTrack: prepared.processed.videoTrack,
            composition: prepared.composition,
            timeRange: CMTimeRange(start: .zero, duration: prepared.processed.composition.duration),
            outputURL: outputURL, sourceLease: document.source.lease)
        request.additionalVideoTracks = prepared.processed.cameraTrack.map { [$0] } ?? []
        return request
    }

    private func encodingPlan(_ settings: VideoExportSettings, canvas: CGSize, project: VideoProject) -> VideoExportEncodingPlan? {
        let pieces = VideoRenderPlanner.pieces(project: project, from: project.trimStart, to: project.trimEnd)
        let outputDuration = pieces.reduce(0) { $0 + $1.compositionDuration }
        let consumed = max(0.001, pieces.reduce(0) { $0 + $1.sourceDuration })
        var source = document.encodingSource ?? VideoExportEncodingPlan.Source(
            size: canvas, averageBitrate: 0, codec: nil, nominalFPS: 1 / document.frameDuration.seconds,
            minimumFrameDuration: document.frameDuration.seconds)
        // The plan sizes output from its source; the canvas is the source here.
        source = VideoExportEncodingPlan.Source(size: canvas, averageBitrate: source.averageBitrate, codec: source.codec,
            nominalFPS: source.nominalFPS, minimumFrameDuration: source.minimumFrameDuration,
            frameDuration: source.frameDuration)
        return VideoExportEncodingPlan.make(source: source, scale: 1, quality: settings.quality,
                                            sourceDuration: consumed, outputDuration: max(0.001, outputDuration))
    }

    /// Estimated MP4 size, when a meaningful estimate exists.
    func estimatedBytes(_ settings: VideoExportSettings) -> Int64? {
        guard settings.format == .mp4, settings.quality != .high,
              let canvas = outputSize(settings),
              let plan = encodingPlan(settings, canvas: canvas, project: document.project) else { return nil }
        let duration = VideoRenderPlanner.outputDuration(project: document.project)
        return plan.estimatedBytes(duration: duration, audioTrackCount: document.project.muted ? 0 : document.audioTrackCount,
                                   audioBitrate: VideoTranscoder.audioBitrate)
    }

    /// SubRip captions on the edited clock.
    func captionsSRT() -> String {
        let project = document.project
        let pieces = VideoRenderPlanner.pieces(project: project, from: project.trimStart, to: project.trimEnd)
        return CaptionTimeline.srt(project.captions) { t in
            var elapsed = 0.0
            for piece in pieces {
                if piece.kind == .freeze { if t > piece.srcStart { elapsed += piece.compositionDuration }; continue }
                if t >= piece.srcEnd { elapsed += piece.compositionDuration; continue }
                if t > piece.srcStart { elapsed += (t - piece.srcStart) / max(piece.factor, 0.0001) }
                break
            }
            return elapsed
        }
    }
}
