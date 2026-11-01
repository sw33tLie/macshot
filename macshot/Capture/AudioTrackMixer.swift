import AVFoundation

enum AudioTrackMixer {
    enum MixError: LocalizedError {
        case invalidTracksOrVolumes, originalWouldBeOverwritten
        var errorDescription: String? {
            switch self {
            case .invalidTracksOrVolumes: return "The recording's audio tracks or mix volumes are invalid."
            case .originalWouldBeOverwritten: return "An audio mix must be saved separately from the original recording."
            }
        }
    }

    private struct Prepared: @unchecked Sendable {
        let save: AtomicMediaSave
        let pump: MediaExportPump
    }

    /// Decode/mix only audio. Compressed video samples and orientation pass
    /// through unchanged, avoiding a second video encode for a long recording.
    /// Volumes share headroom when their sum exceeds unity to prevent clipping.
    nonisolated static func export(source: URL, destination: URL, volumes: [Float],
                                  cancellation: MediaExportCancellation = MediaExportCancellation(),
                                  progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        try cancellation.check()
        guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else {
            throw MixError.originalWouldBeOverwritten
        }
        let prepared: Prepared = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try prepare(source: source, destination: destination,
                                                               volumes: volumes, progress: progress) })
            }
        }
        try await withTaskCancellationHandler(operation: {
            try cancellation.check()
            try await prepared.pump.run()
            try await MediaExportIO.perform {
                try prepared.save.commit(overwritingExisting: false, beforePublish: cancellation.beginPublication)
            }
        }, onCancel: {
            cancellation.cancel()
            prepared.pump.cancel()
        })
    }

    nonisolated private static func prepare(source: URL, destination: URL, volumes: [Float],
                                            progress: @escaping @Sendable (Double) -> Void) throws -> Prepared {
        let asset = AVAsset(url: source)
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard audioTracks.count >= 2, volumes.count == audioTracks.count,
              volumes.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              let video = asset.tracks(withMediaType: .video).first,
              let formats = video.formatDescriptions as? [CMFormatDescription], let format = formats.first,
              asset.duration.isNumeric, CMTimeCompare(asset.duration, .zero) > 0 else {
            throw MixError.invalidTracksOrVolumes
        }
        let save = try AtomicMediaSave(destinationURL: destination)
        let reader = try AVAssetReader(asset: asset)
        let range = CMTimeRange(start: .zero, duration: asset.duration)
        reader.timeRange = range
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        audioOutput.alwaysCopiesSampleData = false
        let mix = AVMutableAudioMix()
        let divisor = max(1, volumes.reduce(0, +))
        mix.inputParameters = zip(audioTracks, volumes).map { track, volume in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(volume / divisor, at: .zero)
            return parameters
        }
        audioOutput.audioMix = mix
        guard reader.canAdd(videoOutput), reader.canAdd(audioOutput) else { throw MediaExportPump.ExportError.invalidSetup }
        reader.add(videoOutput)
        reader.add(audioOutput)

        let writer = try AVAssetWriter(outputURL: save.stagingURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true   // fast start (#452)
        if let cadence = VideoFrameCadence.declaredDuration(in: asset.metadata) {
            writer.metadata = VideoFrameCadence.metadata(for: cadence)
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        videoInput.mediaTimeScale = video.naturalTimeScale > 0 ? video.naturalTimeScale : VideoFrameCadence.captureTimeScale
        videoInput.transform = video.preferredTransform
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
        ])
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { throw MediaExportPump.ExportError.invalidSetup }
        writer.add(videoInput)
        writer.add(audioInput)
        let pump = MediaExportPump(reader: reader, writer: writer, tracks: [
            .init(output: videoOutput, input: videoInput, requiresSamples: true),
            .init(output: audioOutput, input: audioInput, requiresSamples: true),
        ], timeRange: range, progress: progress)
        return Prepared(save: save, pump: pump)
    }
}
