import AVFoundation
import CoreImage

/// Turns a project into AVFoundation compositions. Preview and every export
/// use the same planner, so what plays is what saves.
@MainActor
final class VideoRenderPlanner {
    struct Options {
        /// Output scale relative to the native canvas (preview uses < 1).
        var scale: CGFloat = 1
        /// Show the whole canvas with no camera motion (editing spatial items).
        var suspendCamera = false
        /// Crop editing: show the full uncropped recording without a frame.
        var showUncropped = false
        /// Text segment currently being typed inline, hidden from the render.
        var hiddenTextID: UUID?
        /// Exports wait for the exact pointer track instead of showing the
        /// previous one while a long take recomputes.
        var exactPointer = false
    }

    private let document: VideoEditorDocument
    private let art = VideoSceneArtCache()
    private lazy var assets = VideoSceneBuilder.makeAssets(recording: document.recording)
    private var textCache: [UUID: (spec: VideoTextRasterizer.Spec, image: CIImage)] = [:]
    private var cameraAsset: AVAsset?

    init(document: VideoEditorDocument) {
        self.document = document
        if let url = document.cameraURL { cameraAsset = AVURLAsset(url: url) }
    }

    var hasCamera: Bool { cameraAsset != nil }

    /// Scene layout of `project` at an output scale.
    func layout(for project: VideoProject, scale: CGFloat = 1, showUncropped: Bool = false) -> VideoSceneLayout? {
        var frame = project.look.frame
        var crop = project.crop
        if showUncropped {
            frame = VideoFrameStyle()
            crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return VideoSceneGeometry.layout(contentSize: document.contentSize, crop: crop, frame: frame, scale: scale)
    }

    /// Kept source ranges → timeline pieces for a trim range.
    static func pieces(project: VideoProject, from start: Double, to end: Double) -> [VideoSpeeds.Piece] {
        let kept = VideoCuts.keptRanges(trimStart: start, trimEnd: end, cuts: project.cuts)
        return VideoSpeeds.pieces(keptRanges: kept, speeds: project.speeds, freezes: project.freezes)
    }

    func processed(project: VideoProject, from start: Double, to end: Double,
                   includeAudio: Bool) throws -> VideoCompositionBuilder.Result {
        try VideoCompositionBuilder.build(asset: document.asset, pieces: Self.pieces(project: project, from: start, to: end),
                                          includeAudio: includeAudio, sourceFrameDuration: document.frameDuration,
                                          camera: cameraAsset)
    }

    /// Complete video composition for a processed timeline.
    func videoComposition(project: VideoProject, processed: VideoCompositionBuilder.Result,
                          options: Options, frameDuration: CMTime? = nil,
                          onTrackReady: @escaping () -> Void = {}) throws -> AVMutableVideoComposition {
        guard let layout = layout(for: project, scale: options.scale, showUncropped: options.showUncropped) else {
            throw VideoCompositionRendering.RenderError.invalidGeometry
        }
        let scene = snapshot(project: project, layout: layout, options: options,
                             webcamTrackID: processed.cameraTrack?.trackID, onTrackReady: onTrackReady)
        let censors = project.censors.filter { $0.endTime > $0.startTime }.sorted { $0.startTime < $1.startTime }
            .map(VideoCensorSnapshot.init)
        let texts = textSnapshots(project: project, layout: layout, hidden: options.hiddenTextID)
        return try VideoCompositionRendering.sceneComposition(asset: processed.composition, track: processed.videoTrack,
            frameDuration: frameDuration ?? document.frameDuration, timeMap: processed.timeMap, scene: scene,
            censorSegments: censors, textSnapshots: texts)
    }

    /// Composition over the untouched source asset (no timeline edits).
    func sourceComposition(project: VideoProject, track: AVAssetTrack,
                           timeMap: [EffectsCompositionInstruction.TimeMapEntry], options: Options,
                           onTrackReady: @escaping () -> Void = {}) throws -> AVMutableVideoComposition {
        guard let layout = layout(for: project, scale: options.scale, showUncropped: options.showUncropped) else {
            throw VideoCompositionRendering.RenderError.invalidGeometry
        }
        let scene = snapshot(project: project, layout: layout, options: options, webcamTrackID: nil,
                             onTrackReady: onTrackReady)
        let censors = project.censors.filter { $0.endTime > $0.startTime }.sorted { $0.startTime < $1.startTime }
            .map(VideoCensorSnapshot.init)
        let texts = textSnapshots(project: project, layout: layout, hidden: options.hiddenTextID)
        return try VideoCompositionRendering.sceneComposition(asset: document.asset, track: track,
            frameDuration: document.frameDuration, timeMap: timeMap, scene: scene,
            censorSegments: censors, textSnapshots: texts)
    }

    func snapshot(project: VideoProject, layout: VideoSceneLayout, options: Options,
                  webcamTrackID: CMPersistentTrackID?, onTrackReady: @escaping () -> Void = {}) -> VideoSceneSnapshot {
        let track = options.exactPointer ? document.cursorTrackForExport() : document.cursorTrack(onReady: onTrackReady)
        var webcam: VideoWebcamLayer?
        if let id = webcamTrackID, let cameraTrack = cameraAsset?.tracks(withMediaType: .video).first,
           let upright = VideoRenderGeometry.layout(sourceSize: cameraTrack.naturalSize,
                                                     preferredTransform: cameraTrack.preferredTransform) {
            webcam = VideoWebcamLayer(trackID: id, style: project.look.camera,
                                      uprightTransform: upright.coreImageTransform, uprightSize: upright.uprightSize,
                                      placement: document.cameraPlacement)
        }
        return VideoSceneBuilder.snapshot(project: project, layout: layout, recording: document.recording, track: track,
                                          assets: assets, art: art, directory: document.projectDirectory,
                                          drawsCursor: document.cursorIsEditable && !options.showUncropped,
                                          rendersOverlays: document.overlaysAreEditable,
                                          suspendCamera: options.suspendCamera || options.showUncropped,
                                          webcam: webcam)
    }

    /// Text boxes rasterized at their output pixel size (cached per spec).
    func textSnapshots(project: VideoProject, layout: VideoSceneLayout,
                       hidden: UUID?) -> [EffectsCompositionInstruction.TextSnapshot] {
        var result: [EffectsCompositionInstruction.TextSnapshot] = []
        var live = Set<UUID>()
        let referenceHeight = Int((layout.videoRect.height / max(layout.crop.height, 0.01)).rounded())
        for segment in project.texts where segment.endTime > segment.startTime && segment.id != hidden {
            let rect = layout.canvasRect(forContent: segment.rect)
            let spec = VideoTextRasterizer.spec(for: segment, pixelWidth: max(2, Int(rect.width.rounded())),
                                                pixelHeight: max(2, Int(rect.height.rounded())),
                                                renderHeight: max(2, referenceHeight))
            live.insert(segment.id)
            let image: CIImage
            if let cached = textCache[segment.id], cached.spec == spec {
                image = cached.image
            } else {
                guard let cg = VideoTextRasterizer.render(spec) else { continue }
                image = CIImage(cgImage: cg)
                textCache[segment.id] = (spec, image)
            }
            result.append(.init(id: segment.id, startTime: segment.startTime, endTime: segment.endTime,
                                rect: segment.rect, fadeIn: segment.fadeIn, fadeOut: segment.fadeOut, image: image))
        }
        for key in Array(textCache.keys) where !live.contains(key) { textCache.removeValue(forKey: key) }
        return result
    }

    /// Timeline duration after cuts, speed and freezes within the trim.
    static func outputDuration(project: VideoProject) -> Double {
        VideoSpeeds.totalCompositionDuration(pieces(project: project, from: project.trimStart, to: project.trimEnd))
    }
}
