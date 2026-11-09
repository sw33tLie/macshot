import AVFoundation
import Darwin

// Production preparation and full-length Medium export of an upright synthetic
// recording. No capture permissions or user history. The output directory must
// be new; the input is read-only and the published result remains for decoding.
// Build from the repository root:
// swiftc -O -swift-version 5 -default-isolation MainActor -parse-as-library \
//   macshot/Services/{AtomicMediaSave,MediaExportCoordinator,VideoSourceSnapshot,FilenameSanitizer}.swift \
//   macshot/Capture/{RecordingSessionStore,PreparedVideoSource,VideoRenderGeometry,VideoEncodingSettings,VideoExportEncodingPlan,SafeNumerics,VideoFrameCadence,VideoTranscoder,MediaExportPump}.swift \
//   scripts/probe-long-video-export.swift -o /tmp/macshot-long-export
// /tmp/macshot-long-export /synthetic/recording.mp4 /new/output-directory > /tmp/export.jsonl
// Measures service stages, not full editor responsiveness or effects rendering.
nonisolated func L(_ key: String) -> String { key }

@main
struct LongVideoExportProbe {
    nonisolated static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    @MainActor static func emit(_ record: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "macshot.longexport", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Usage: macshot-long-export /absolute/synthetic-input.mp4 /new/output-directory"])
        }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                            reason: "Synthetic long-video export verification")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let started = ProcessInfo.processInfo.systemUptime
        let snapshot = try await MediaExportIO.perform {
            try VideoSourceSnapshot.prepare(url: input, deleteOnClose: false,
                workspaceRoot: directory.appendingPathComponent("working"))
        }
        let copied = ProcessInfo.processInfo.systemUptime
        let prepared = try await PreparedVideoSource.load(snapshot)
        let loaded = ProcessInfo.processInfo.systemUptime
        guard let asset = prepared.asset, let source = prepared.encodingSource,
              let plan = VideoExportEncodingPlan.make(source: source, scale: 1, quality: .medium,
                sourceDuration: prepared.duration, outputDuration: prepared.duration) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let tracks = try await asset.load(.tracks)
        guard let video = tracks.first(where: { $0.mediaType == .video }),
              try await video.load(.preferredTransform) == .identity else { throw CocoaError(.featureUnsupported) }
        let range = try await video.load(.timeRange)
        let output = directory.appendingPathComponent("medium.mp4")
        let transaction = try await MediaExportIO.perform { try AtomicMediaSave(destinationURL: output) }
        try emit(["event": "prepared", "source": input.path, "output": output.path,
            "duration": prepared.duration, "sourceBytes": prepared.fileSize,
            "snapshotSeconds": copied - started, "metadataSeconds": loaded - copied,
            "frameDuration": source.frameDuration.seconds, "targetFPS": plan.fps,
            "targetVideoBitrate": plan.videoBitrate, "audioTracks": prepared.audioTrackCount,
            "residentBytes": residentBytes()])
        let encodingStarted = ProcessInfo.processInfo.systemUptime
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try Task.checkCancellation()
                try emit(["event": "sample", "encodingSeconds": ProcessInfo.processInfo.systemUptime - encodingStarted,
                    "residentBytes": residentBytes()])
            }
        }
        defer { sampler.cancel() }
        try await VideoTranscoder.export(.init(asset: asset, videoTrack: video,
            audioTracks: tracks.filter { $0.mediaType == .audio }, composition: nil, timeRange: range,
            outputURL: transaction.stagingURL, videoSettings: plan.outputSettings, decodedSize: nil,
            outputTransform: .identity, sourceFrameDuration: source.frameDuration))
        let encoded = ProcessInfo.processInfo.systemUptime
        try await MediaExportIO.perform { try transaction.commit() }
        let finished = ProcessInfo.processInfo.systemUptime
        let bytes = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try emit(["event": "complete", "output": output.path, "bytes": bytes,
            "encodingSeconds": encoded - encodingStarted, "publicationSeconds": finished - encoded,
            "totalSeconds": finished - started, "residentBytes": residentBytes()])
        withExtendedLifetime(prepared) {}
    }
}
