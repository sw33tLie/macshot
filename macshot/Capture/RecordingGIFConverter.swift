import AVFoundation

/// Turns a finished recording into a looping GIF for the Record GIF hotkey,
/// through the same `GIFExporter` the video editor's GIF export uses.
enum RecordingGIFConverter {
    /// `scale` shrinks the take before encoding: pass `1 / backingScaleFactor`
    /// so a Retina recording becomes a GIF at its on-screen point size.
    static func convert(source: URL, to output: URL, fps: Int, scale: CGFloat,
                        cancellation: MediaExportCancellation,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw GIFExporter.ExportError.invalidSetup
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let upright = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized.size
        let factor = min(1, max(0.1, scale))
        let renderSize = CGSize(width: max(2, (upright.width * factor).rounded()),
                                height: max(2, (upright.height * factor).rounded()))
        let cadence = CMTime(value: 1, timescale: CMTimeScale(min(30, max(5, fps))))
        let composition = try VideoCompositionRendering.scaleComposition(
            track: track, renderSize: renderSize, duration: duration, frameDuration: cadence)
        let request = GIFExporter.Request(
            asset: asset, videoTrack: track, composition: composition,
            timeRange: CMTimeRange(start: .zero, duration: duration),
            outputURL: output, sourceLease: nil)
        try await GIFExporter.export(request, cancellation: cancellation, progress: progress)
    }
}
