import AVFoundation

enum VideoCompositionRendering {
    enum RenderError: LocalizedError {
        case invalidGeometry
        var errorDescription: String? { "The source recording has invalid video dimensions or orientation." }
    }

    static func effectsComposition(asset: AVAsset, track: AVAssetTrack,
                                   layout: VideoRenderGeometry.Layout, frameDuration: CMTime,
                                   timeMap: [EffectsCompositionInstruction.TimeMapEntry],
                                   zoomSegments: [VideoZoomSnapshot], censorSegments: [VideoCensorSnapshot],
                                   textSnapshots: [EffectsCompositionInstruction.TextSnapshot] = []) -> AVMutableVideoComposition {
        // Keep the asset's exact rational endpoint. Converting through seconds
        // can shorten it by less than a nanosecond, leaving an uncovered tail
        // that AVFoundation rejects for both preview and export (-11841).
        let instruction = EffectsCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: asset.duration),
            videoTrackID: track.trackID,
            naturalSize: layout.uprightSize, renderSize: layout.renderSize,
            baseTransform: layout.coreImageTransform, timeMap: timeMap,
            zoomSegments: zoomSegments, censorSegments: censorSegments, textSnapshots: textSnapshots)
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = EffectsVideoCompositor.self
        composition.instructions = [instruction]
        composition.renderSize = layout.renderSize
        composition.frameDuration = frameDuration
        return composition
    }

    /// Framed-scene composition. The instruction carries the upright
    /// (unscaled) source transform; the scene decides the canvas.
    static func sceneComposition(asset: AVAsset, track: AVAssetTrack, frameDuration: CMTime,
                                 timeMap: [EffectsCompositionInstruction.TimeMapEntry],
                                 scene: VideoSceneSnapshot, censorSegments: [VideoCensorSnapshot],
                                 textSnapshots: [EffectsCompositionInstruction.TextSnapshot]) throws -> AVMutableVideoComposition {
        guard let upright = VideoRenderGeometry.layout(sourceSize: track.naturalSize,
                                                       preferredTransform: track.preferredTransform) else {
            throw RenderError.invalidGeometry
        }
        let instruction = EffectsCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: asset.duration),
            videoTrackID: track.trackID,
            naturalSize: upright.uprightSize, renderSize: scene.layout.canvasSize,
            baseTransform: upright.coreImageTransform, timeMap: timeMap,
            zoomSegments: [], censorSegments: censorSegments, textSnapshots: textSnapshots, scene: scene)
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = EffectsVideoCompositor.self
        composition.instructions = [instruction]
        composition.renderSize = scene.layout.canvasSize
        composition.frameDuration = frameDuration
        return composition
    }

    static func scaleComposition(track: AVAssetTrack, renderSize: CGSize, duration: CMTime,
                                  frameDuration: CMTime? = nil) throws -> AVMutableVideoComposition {
        guard let layout = VideoRenderGeometry.layout(sourceSize: track.naturalSize,
            preferredTransform: track.preferredTransform, renderSize: renderSize), duration.isNumeric,
            duration.value > 0 else { throw RenderError.invalidGeometry }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(layout.layerTransform, at: .zero)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = renderSize
        composition.frameDuration = frameDuration ?? VideoFrameCadence.Inspection(track: track).duration()
        return composition
    }
}
