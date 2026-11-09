import Foundation

// Build from the repository root:
// swiftc -O -swift-version 5 -parse-as-library \
//   macshot/Services/AtomicMediaSave.swift macshot/Services/MediaExportCoordinator.swift \
//   macshot/Services/VideoSourceSnapshot.swift macshot/Capture/RecordingSessionStore.swift \
//   macshot/Services/FilenameSanitizer.swift \
//   scripts/benchmark-video-source.swift -o /tmp/macshot-source-benchmark
// /usr/bin/time -l /tmp/macshot-source-benchmark
// Measures preparation of a 256 MiB synthetic source, not full-editor loading
// or network/external-volume throughput. Each run owns and removes its files.
@main struct VideoSourceBenchmark {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("macshot-source-benchmark-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let source = directory.appendingPathComponent("input.mp4")
        fm.createFile(atPath: source.path, contents: nil)
        let writer = try FileHandle(forWritingTo: source)
        var random: UInt64 = 1
        let chunk = Data((0..<(1024 * 1024)).map { _ in
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: random >> 32)
        })
        for _ in 0..<256 { try writer.write(contentsOf: chunk) }
        try writer.synchronize()
        try writer.close()
        let cleanup = DispatchQueue(label: "macshot.source-benchmark.cleanup")
        var results: [[String: Any]] = []
        for clone in [true, false] {
            for iteration in 1...3 {
                let start = ProcessInfo.processInfo.systemUptime
                var snapshot: VideoSourceSnapshot? = try VideoSourceSnapshot.prepare(url: source, deleteOnClose: false,
                    workspaceRoot: directory.appendingPathComponent("working"), allowClone: clone, cleanupQueue: cleanup)
                let seconds = ProcessInfo.processInfo.systemUptime - start
                let size = try snapshot!.mediaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                let input = try FileHandle(forReadingFrom: snapshot!.mediaURL)
                guard size == 256 * 1024 * 1024, try input.read(upToCount: chunk.count) == chunk else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try input.seek(toOffset: UInt64(size - chunk.count))
                guard try input.read(upToCount: chunk.count) == chunk else { throw CocoaError(.fileReadCorruptFile) }
                try input.close()
                results.append(["allow_clone": clone, "iteration": iteration, "bytes": size, "prepare_ms": seconds * 1000])
                snapshot = nil
                cleanup.sync {}
            }
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
