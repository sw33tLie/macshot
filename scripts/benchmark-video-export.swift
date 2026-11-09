import AVFoundation
import Darwin

// Compile from the repository root:
// swiftc -O -swift-version 5 -parse-as-library macshot/Capture/{VideoEncodingSettings,VideoExportEncodingPlan,SafeNumerics,VideoFrameCadence,VideoTranscoder,MediaExportPump}.swift scripts/benchmark-video-export.swift -o /tmp/macshot-export-benchmark
// /tmp/macshot-export-benchmark /absolute/synthetic-input.mp4 /new/output-directory
//
// Read-only input, exclusive output directory. Compare the old live-capture
// targets, new offline targets, and the existing High preset on upright MP4s.
// Outputs remain for independent decoding/quality comparison. This measures
// encoding only, not capture, editor startup, atomic saving or external disks.
func L(_ key: String) -> String { key }

@main
struct VideoExportBenchmark {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "macshot.exportbenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Usage: macshot-export-benchmark /absolute/synthetic-input.mp4 /new/output-directory"])
        }
        let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let asset = AVURLAsset(url: inputURL)
        let tracks = try await asset.load(.tracks)
        guard let video = tracks.first(where: { $0.mediaType == .video }) else { throw CocoaError(.fileReadCorruptFile) }
        let size = try await video.load(.naturalSize)
        guard try await video.load(.preferredTransform) == .identity else { throw CocoaError(.featureUnsupported) }
        let range = try await video.load(.timeRange)
        let rate = try await video.load(.estimatedDataRate)
        let fps = try await video.load(.nominalFrameRate)
        let period = try await video.load(.minFrameDuration)
        let formats = try await video.load(.formatDescriptions)
        let audio = tracks.filter { $0.mediaType == .audio }
        let cadence = VideoFrameCadence.declaredDuration(in: try await asset.load(.metadata))
            ?? VideoFrameCadence.Inspection(track: video).duration()
        let source = VideoExportEncodingPlan.Source(size: size, averageBitrate: Double(rate),
            codec: formats.first.map { CMFormatDescriptionGetMediaSubType($0) },
            nominalFPS: Double(fps), minimumFrameDuration: period.seconds, frameDuration: cadence)
        var results: [[String: Any]] = []
        let modes: [(String, VideoQuality, Bool)] = [
            ("legacy-medium", VideoQuality.medium, true), ("medium", .medium, false),
            ("legacy-low", .low, true), ("low", .low, false), ("high", .high, false),
        ]
        for iteration in 1...3 {
            // Reverse alternate runs so the old path does not always pay startup.
            for (name, quality, legacy) in iteration.isMultiple(of: 2) ? Array(modes.reversed()) : modes {
                guard let plan = VideoExportEncodingPlan.make(source: source, scale: 1, quality: quality,
                    sourceDuration: range.duration.seconds, outputDuration: range.duration.seconds) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let settings = legacy ? VideoEncodingSettings.outputSettings(width: plan.width, height: plan.height,
                    fps: plan.fps, codec: .h264, quality: quality) : plan.outputSettings
                let outputURL = directory.appendingPathComponent("\(iteration)-\(name).mp4")
                let started = ProcessInfo.processInfo.systemUptime
                if quality == .high {
                    // As in the editor's full-range composition, explicitly
                    // insert every audio track. A direct-asset export may choose
                    // only the default track, making size comparisons unequal.
                    let composition = AVMutableComposition()
                    for track in [video] + audio {
                        guard let destination = composition.addMutableTrack(withMediaType: track.mediaType,
                            preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CocoaError(.featureUnsupported) }
                        destination.naturalTimeScale = 1_000_000_000
                        let overlap = CMTimeRangeGetIntersection(range, otherRange: track.timeRange)
                        if overlap.duration.isNumeric, overlap.duration.value > 0 {
                            try destination.insertTimeRange(overlap, of: track,
                                at: CMTimeSubtract(overlap.start, range.start))
                        }
                    }
                    guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                        throw CocoaError(.featureUnsupported)
                    }
                    session.outputFileType = .mp4
                    session.outputURL = outputURL
                    session.timeRange = CMTimeRange(start: .zero, duration: range.duration)
                    await session.export()
                    guard session.status == .completed else { throw session.error ?? CocoaError(.fileWriteUnknown) }
                } else {
                    try await VideoTranscoder.export(.init(asset: asset, videoTrack: video, audioTracks: audio,
                        composition: nil, timeRange: range, outputURL: outputURL, videoSettings: settings,
                        decodedSize: nil, outputTransform: .identity, sourceFrameDuration: cadence))
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let resultAsset = AVURLAsset(url: outputURL)
                let resultTracks = try await resultAsset.load(.tracks)
                guard resultTracks.filter({ $0.mediaType == .audio }).count == audio.count else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let bytes = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                var result: [String: Any] = ["iteration": iteration, "name": name, "seconds": elapsed, "bytes": bytes]
                if quality != .high {
                    let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
                    result["target_video_bps"] = compression?[AVVideoAverageBitRateKey]
                    if !legacy {
                        result["estimated_bytes"] = plan.estimatedBytes(duration: range.duration.seconds,
                            audioTrackCount: audio.count, audioBitrate: VideoTranscoder.audioBitrate)
                    }
                }
                results.append(result)
            }
        }
        let report: [String: Any] = ["source_video_bps": rate, "source_fps": fps,
            "source_minimum_frame_duration": period.seconds, "duration": range.duration.seconds,
            "results": results]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}
