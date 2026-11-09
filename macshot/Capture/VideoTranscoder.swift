import AVFoundation

enum VideoTranscoder {
    nonisolated static let audioBitrate = 128_000
    /// The caller owns these media objects exclusively after constructing the
    /// request. Editor preferences and effects must already be snapshotted.
    struct Request: @unchecked Sendable {
        nonisolated(unsafe) let asset: AVAsset
        nonisolated(unsafe) let videoTrack: AVAssetTrack
        nonisolated(unsafe) let audioTracks: [AVAssetTrack]
        let composition: AVVideoComposition?
        let timeRange: CMTimeRange
        let outputURL: URL
        nonisolated(unsafe) let videoSettings: [String: Any]
        let decodedSize: CGSize?
        let outputTransform: CGAffineTransform
        var sourceFrameDuration: CMTime? = nil
        /// Extra video tracks the composition reads (a separately recorded camera).
        nonisolated(unsafe) var additionalVideoTracks: [AVAssetTrack] = []

        nonisolated func writing(to url: URL) -> Request {
            var copy = Request(asset: asset, videoTrack: videoTrack, audioTracks: audioTracks,
                               composition: composition, timeRange: timeRange, outputURL: url,
                               videoSettings: videoSettings, decodedSize: decodedSize, outputTransform: outputTransform,
                               sourceFrameDuration: sourceFrameDuration)
            copy.additionalVideoTracks = additionalVideoTracks
            return copy
        }
    }

    nonisolated static func export(_ request: Request,
                                  progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        let pump: MediaExportPump = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try prepare(request, progress: progress) })
            }
        }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await pump.run()
        }, onCancel: { pump.cancel() })
    }

    nonisolated private static func prepare(_ request: Request,
                                            progress: @escaping @Sendable (Double) -> Void) throws -> MediaExportPump {
        let reader = try AVAssetReader(asset: request.asset)
        reader.timeRange = request.timeRange
        let writer = try AVAssetWriter(outputURL: request.outputURL, fileType: .mp4)
        // Fast start: the index goes before the media, so an uploaded or
        // linked export starts playing before it has fully downloaded (#452).
        writer.shouldOptimizeForNetworkUse = true
        let cadence = request.composition?.frameDuration ?? request.sourceFrameDuration
            ?? VideoFrameCadence.declaredDuration(in: request.asset.metadata)
            ?? VideoFrameCadence.Inspection(track: request.videoTrack).duration()
        writer.metadata = VideoFrameCadence.metadata(for: cadence)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: request.videoSettings)
        videoInput.mediaTimeScale = VideoFrameCadence.mediaTimeScale(
            frameDuration: cadence,
            duration: request.timeRange.duration)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = request.outputTransform
        let videoOutput: AVAssetReaderOutput
        if let composition = request.composition {
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: [request.videoTrack] + request.additionalVideoTracks, videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            output.videoComposition = composition
            videoOutput = output
        } else {
            var settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            if let size = request.decodedSize {
                settings[kCVPixelBufferWidthKey as String] = Int(size.width)
                settings[kCVPixelBufferHeightKey as String] = Int(size.height)
            }
            videoOutput = AVAssetReaderTrackOutput(track: request.videoTrack, outputSettings: settings)
        }
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else {
            throw MediaExportPump.ExportError.invalidSetup
        }
        reader.add(videoOutput)
        writer.add(videoInput)
        var tracks = [MediaExportPump.Track(output: videoOutput, input: videoInput, requiresSamples: true)]
        for track in request.audioTracks {
            let formats = track.formatDescriptions as? [CMAudioFormatDescription] ?? []
            let channelCounts = formats.compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
            // Keep a mono microphone mono. Stereo/mixed-format sources retain
            // the existing stereo export policy instead of guessing a layout.
            let channels = !channelCounts.isEmpty && channelCounts.allSatisfy { $0 == 1 } ? 1 : 2
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            // Add a matched pair or fail; independently skipping input/output
            // used to pair different tracks and could leave one unconsumed.
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw MediaExportPump.ExportError.invalidSetup
            }
            reader.add(output)
            writer.add(input)
            tracks.append(.init(output: output, input: input, requiresSamples: false))
        }
        // startSession(atSourceTime:) makes the selected range start at zero in
        // the resulting file, preserving sample durations and decode timing.
        return MediaExportPump(reader: reader, writer: writer, tracks: tracks,
                               timeRange: request.timeRange, progress: progress)
    }
}
