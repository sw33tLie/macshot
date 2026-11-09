import AVFoundation
import Darwin

// Read only the supplied synthetic movie; outputs require a new directory.
// swiftc -O -swift-version 5 -default-isolation MainActor -parse-as-library macshot/Capture/{VideoEncodingSettings,VideoFrameCadence,VideoCompositionRendering,VideoRenderGeometry,VideoTranscoder,MediaExportPump}.swift scripts/benchmark-video-cadence.swift -o /tmp/macshot-cadence-benchmark
// /tmp/macshot-cadence-benchmark /absolute/input.mp4 /new/output-directory
func L(_ key: String) -> String { key }

@main
struct VideoCadenceBenchmark {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
        let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let tracks = try await asset.load(.tracks)
        guard let video = tracks.first(where: { $0.mediaType == .video }) else { throw CocoaError(.fileReadCorruptFile) }
        let duration = try await asset.load(.duration)
        let minimum = try await video.load(.minFrameDuration)
        let nominal = try await video.load(.nominalFrameRate)
        let size = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        guard let layout = VideoRenderGeometry.layout(sourceSize: size, preferredTransform: transform) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let inferred = VideoFrameCadence.Inspection(track: video).duration()
        let inspectionSeconds = ProcessInfo.processInfo.systemUptime - started
        let metadata = try await asset.load(.metadata)
        let cadence = VideoFrameCadence.declaredDuration(in: metadata) ?? inferred
        let legacy = VideoFrameCadence.duration(minimum: minimum, nominalRate: nominal)
        let range = CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, CMTime(value: 10, timescale: 1)))
        let (width, height) = VideoEncodingSettings.evenDimensions(
            width: layout.uprightSize.width / 2, height: layout.uprightSize.height / 2)
        // Same bitrate, size and all audio tracks; isolate the render cadence.
        let settings = VideoEncodingSettings.outputSettings(width: width, height: height,
            fps: 30, codec: .h264, quality: .medium)
        var results: [[String: Any]] = []
        let modes = [("legacy-minimum", legacy), ("resolved", cadence)]
        for iteration in 1...3 {
            for (name, interval) in iteration.isMultiple(of: 2) ? Array(modes.reversed()) : modes {
                let composition = try VideoCompositionRendering.scaleComposition(track: video,
                    renderSize: CGSize(width: width, height: height), duration: range.duration, frameDuration: interval)
                guard let instruction = composition.instructions.first as? AVVideoCompositionInstruction,
                      let layer = instruction.layerInstructions.first as? AVMutableVideoCompositionLayerInstruction else {
                    throw CocoaError(.featureUnsupported)
                }
                layer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0.5, timeRange: range)
                let url = directory.appendingPathComponent("\(iteration)-\(name).mp4")
                let start = ProcessInfo.processInfo.systemUptime
                try await VideoTranscoder.export(.init(asset: asset, videoTrack: video,
                    audioTracks: tracks.filter { $0.mediaType == .audio }, composition: composition,
                    timeRange: range, outputURL: url, videoSettings: settings, decodedSize: nil,
                    outputTransform: .identity, sourceFrameDuration: cadence))
                results.append(["iteration": iteration, "name": name,
                    "seconds": ProcessInfo.processInfo.systemUptime - start,
                    "bytes": try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0])
            }
        }
        let report: [String: Any] = ["effect": "opacity ramp", "source_duration": duration.seconds,
            "source_nominal_fps": nominal, "source_minimum_frame_duration": minimum.seconds,
            "legacy_render_fps": 1 / legacy.seconds, "resolved_render_fps": 1 / cadence.seconds,
            "inferred_render_fps": 1 / inferred.seconds, "inspection_seconds": inspectionSeconds,
            "export_duration": range.duration.seconds, "results": results]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]),
                     as: UTF8.self))
    }
}
