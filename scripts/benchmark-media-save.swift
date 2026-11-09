import Foundation

// Run manually from the repository root:
// xcrun swiftc -O -swift-version 5 macshot/Services/AtomicMediaSave.swift scripts/benchmark-media-save.swift -o /tmp/macshot-save-benchmark
// /tmp/macshot-save-benchmark
//
// Measures local same-volume saving only, with a 256 MiB synthetic file in a
// private temporary directory. This does not measure media encoding, network
// volumes, external disks, or end-to-end UI latency. The old remove/copy path
// is included solely as a benchmark baseline inside that private directory.
@main
struct MediaSaveBenchmark {
    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("macshot-save-benchmark-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        fm.createFile(atPath: source.path, contents: nil)
        let writer = try FileHandle(forWritingTo: source)
        var random: UInt64 = 1
        let bytes = Data((0..<(1024 * 1024)).map { _ in
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: random >> 32)
        })
        for _ in 0..<256 { try writer.write(contentsOf: bytes) }
        try writer.synchronize()
        try writer.close()
        var results: [[String: Any]] = []
        for iteration in 1...3 {
            let oldDestination = directory.appendingPathComponent("old-\(iteration).mp4")
            try Data("old file".utf8).write(to: oldDestination)
            let oldStart = ProcessInfo.processInfo.systemUptime
            try fm.removeItem(at: oldDestination)
            try fm.copyItem(at: source, to: oldDestination)
            let oldSeconds = ProcessInfo.processInfo.systemUptime - oldStart
            let destination = directory.appendingPathComponent("atomic-\(iteration).mp4")
            try Data("old file".utf8).write(to: destination)
            let newStart = ProcessInfo.processInfo.systemUptime
            let transaction = try AtomicMediaSave(destinationURL: destination)
            let setupSeconds = ProcessInfo.processInfo.systemUptime - newStart
            try transaction.copySource(source)
            let copied = ProcessInfo.processInfo.systemUptime
            try transaction.commit()
            let finished = ProcessInfo.processInfo.systemUptime
            let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size == 256 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            results.append(["iteration": iteration, "bytes": size, "old_remove_copy_ms": oldSeconds * 1000,
                            "atomic_setup_ms": setupSeconds * 1000,
                            "atomic_clone_ms": (copied - newStart - setupSeconds) * 1000,
                            "atomic_commit_ms": (finished - copied) * 1000,
                            "atomic_total_ms": (finished - newStart) * 1000])
            try fm.removeItem(at: oldDestination)
            try fm.removeItem(at: destination)
        }
        let json = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}
