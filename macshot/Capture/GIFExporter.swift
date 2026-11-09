import AVFoundation

/// Exports a prepared timeline at the video composition's explicit cadence.
/// The reader supplies real presentation times; neither nominal source FPS nor
/// source frame counts determine animation timing. Work and memory stay bounded
/// to the reader and the encoder's current/previous frame.
enum GIFExporter {
    struct Request: @unchecked Sendable {
        nonisolated(unsafe) let asset: AVAsset
        nonisolated(unsafe) let videoTrack: AVAssetTrack
        let composition: AVVideoComposition
        let timeRange: CMTimeRange
        let outputURL: URL
        let sourceLease: TemporaryMediaLease?
        /// Extra video tracks the composition reads (a separately recorded camera).
        nonisolated(unsafe) var additionalVideoTracks: [AVAssetTrack] = []
    }

    enum ExportError: LocalizedError {
        case invalidSetup, incompleteRead
        nonisolated var errorDescription: String? {
            switch self {
            case .invalidSetup: return "The recording cannot be prepared for GIF export."
            case .incompleteRead: return "The recording could not be read completely."
            }
        }
    }

    nonisolated static func export(_ request: Request,
                                  cancellation: MediaExportCancellation = MediaExportCancellation(),
                                  progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try run(request, cancellation: cancellation, progress: progress) })
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    nonisolated private static func run(_ request: Request, cancellation: MediaExportCancellation,
                                        progress: @escaping @Sendable (Double) -> Void) throws {
        defer { withExtendedLifetime(request.sourceLease) {} }
        try cancellation.check()
        guard request.timeRange.isValid, request.timeRange.start.isNumeric,
              request.timeRange.duration.isNumeric, request.timeRange.duration.value > 0,
              request.timeRange.duration.seconds < 9_000_000_000,
              request.composition.frameDuration.isNumeric,
              request.composition.frameDuration.seconds >= 1.0 / 30 else {
            throw ExportError.invalidSetup
        }
        let save = try AtomicMediaSave(destinationURL: request.outputURL)
        let encoder = try GIFEncoder(url: save.stagingURL)
        let reader = try AVAssetReader(asset: request.asset)
        reader.timeRange = request.timeRange
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [request.videoTrack] + request.additionalVideoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.videoComposition = request.composition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ExportError.invalidSetup }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ExportError.incompleteRead }
        defer { reader.cancelReading() }
        var lastPercent = -1
        while true {
            try cancellation.check()
            let time: CMTime? = try autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return nil }
                guard let pixels = sample.imageBuffer else { throw GIFEncoder.EncodingError.invalidFrame }
                let relative = CMTimeSubtract(sample.presentationTimeStamp, request.timeRange.start)
                try encoder.addFrame(pixels, at: relative)
                return relative
            }
            guard let time else { break }
            let fraction = min(0.99, max(0, time.seconds / request.timeRange.duration.seconds))
            let percent = Int(fraction * 100)
            if percent != lastPercent {
                lastPercent = percent
                progress(Double(percent) / 100)
            }
        }
        try cancellation.check()
        guard reader.status == .completed else { throw reader.error ?? ExportError.incompleteRead }
        try encoder.finish(at: request.timeRange.duration)
        try cancellation.check()
        try save.commit(beforePublish: { try cancellation.beginPublication() })
        progress(1)
    }

}
