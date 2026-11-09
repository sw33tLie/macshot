// Isolated encoder probe; creates synthetic pixels and removes its own output.
// Build: swiftc -O -parse-as-library macshot/Capture/GIFEncoder.swift scripts/benchmark-gif-encoding.swift -o /tmp/macshot-gif-benchmark
// Run: /tmp/macshot-gif-benchmark 300 640 360 changing
// Patterns: static, cursor, changing. A fifth argument copies the generated GIF
// to that path for independent decoding; an existing file is never replaced.
// Define BASELINE and supply the previous encoder source to compare its memory
// and time using identical synthetic input. This does not measure end-to-end UI.
import Foundation
import CoreVideo
import CoreMedia
import Darwin

@main
struct GIFEncodingBenchmark {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let frames = min(10_000, max(1, args.first.flatMap(Int.init) ?? 300))
        let width = min(3840, max(8, args.count > 1 ? Int(args[1]) ?? 640 : 640))
        let height = min(2160, max(8, args.count > 2 ? Int(args[2]) ?? 360 : 360))
        let pattern = args.count > 3 ? args[3] : "static"
        let changing = pattern != "static"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macshot-gif-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("probe.gif")
        var optionalPixels: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &optionalPixels) == kCVReturnSuccess,
              let pixels = optionalPixels else { throw CocoaError(.coderValueNotFound) }
        #if BASELINE
        let encoder = GIFEncoder(url: url, fps: 30, sourceFPS: 30)
        #else
        let encoder = try GIFEncoder(url: url)
        #endif
        var samples: [[String: UInt64]] = [["frame": 0, "residentBytes": residentBytes()]]
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<frames {
            try autoreleasepool { () throws -> Void in
                if changing || index == 0 {
                    CVPixelBufferLockBaseAddress(pixels, [])
                    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
                    for y in 0..<height {
                        for x in 0..<width {
                            let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                            let phase = pattern == "changing" ? index : 0
                            base[offset] = UInt8(truncatingIfNeeded: x ^ y ^ phase)
                            base[offset + 1] = UInt8(truncatingIfNeeded: y + phase)
                            base[offset + 2] = UInt8(truncatingIfNeeded: x + phase)
                            base[offset + 3] = 255
                        }
                    }
                    if pattern == "cursor" {
                        let left = (index * 3) % max(1, width - 16)
                        for y in (height / 2)..<min(height, height / 2 + 16) {
                            for x in left..<min(width, left + 16) {
                                let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                                base[offset] = 0; base[offset + 1] = 0; base[offset + 2] = 255
                            }
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(pixels, [])
                }
                #if BASELINE
                encoder.addFrame(pixels)
                #else
                try encoder.addFrame(pixels, at: CMTime(value: Int64(index), timescale: 30))
                #endif
            }
            if (index + 1).isMultiple(of: 30) || index == frames - 1 {
                samples.append(["frame": UInt64(index + 1), "residentBytes": residentBytes()])
            }
        }
        let beforeFinish = ProcessInfo.processInfo.systemUptime
        #if BASELINE
        encoder.finish()
        #else
        try encoder.finish(at: CMTime(value: Int64(frames), timescale: 30))
        #endif
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        if args.count > 4 { try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: args[4])) }
        let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 ?? 0
        let result: [String: Any] = ["frames": frames, "width": width, "height": height,
            "pattern": pattern, "seconds": elapsed, "finalizeSeconds": elapsed - (beforeFinish - start),
            "fileBytes": bytes, "residentSamples": samples]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: json, as: UTF8.self))
    }
}
