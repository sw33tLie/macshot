import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Streams video frames to the gifski encoder (github.com/ImageOptim/gifski).
///
/// Why: ImageIO's CGImageDestination GIF writer is single-threaded and keeps
/// every frame in memory until finalize — a 1-minute Retina recording is ~900
/// frames / tens of GB, which crashes (SIGBUS in ColorQuantization::hist3d)
/// and takes minutes on one core. gifski is multi-threaded (uses all
/// performance cores), streams frames from disk, produces smaller and
/// better-looking GIFs.
enum GifskiExporter {

    /// Bundled binary first, then Homebrew locations.
    static func locateBinary() -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("gifski"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/gifski"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/gifski"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    enum ExportError: LocalizedError {
        case noFrames
        case frameWriteFailed
        case gifskiFailed(Int32, String)

        var errorDescription: String? {
            switch self {
            case .noFrames: return "No frames were read from the recording"
            case .frameWriteFailed: return "Failed to write intermediate frames"
            case .gifskiFailed(let code, let msg): return "gifski exited with code \(code): \(msg)"
            }
        }
    }

    /// Reads all frames from `readerOutput` (decimated to `fps`), writes them
    /// as PNGs encoded in parallel, then runs gifski over the frame files.
    /// Reports progress 0.0–1.0 (0–0.5 reading frames, 0.5–1.0 encoding).
    static func export(
        binary: URL,
        reader: AVAssetReader,
        readerOutput: AVAssetReaderOutput,
        fps: Int,
        sourceFPS: Int,
        estimatedFrames: Int,
        to destURL: URL,
        progress: @escaping (Double) -> Void
    ) throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("gifski-" + UUID().uuidString)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // --- Phase 1 (0-50%): read, decimate, encode PNGs in parallel ---
        let gifFPS = max(1, min(fps, 50))
        let effSourceFPS = max(sourceFPS, gifFPS)
        let encodeQueue = DispatchQueue(label: "macshot.gifski.png", qos: .userInitiated, attributes: .concurrent)
        let group = DispatchGroup()
        // Bound in-flight owned frame copies so memory stays flat on long clips.
        let inFlight = DispatchSemaphore(value: 12)
        let writeFailed = LockedFlag()

        var inputIndex = 0
        var framePaths: [String] = []

        reader.startReading()
        while reader.status == .reading {
            autoreleasepool {
                guard let sampleBuffer = readerOutput.copyNextSampleBuffer(),
                      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                inputIndex += 1
                // Fractional decimation: keep a frame whenever the target
                // timeline advances (exact for any fps pair, e.g. 60 -> 24).
                let prevTargetIndex = (inputIndex - 1) * gifFPS / effSourceFPS
                let targetIndex = inputIndex * gifFPS / effSourceFPS
                guard targetIndex > prevTargetIndex else { return }
                // Own the pixels before the reader recycles the buffer
                // (alwaysCopiesSampleData = false).
                guard let image = copyImage(from: pixelBuffer) else { return }
                let path = workDir.appendingPathComponent(String(format: "frame_%06d.png", framePaths.count)).path
                framePaths.append(path)
                inFlight.wait()
                encodeQueue.async(group: group) {
                    defer { inFlight.signal() }
                    if !writePNG(image, toPath: path) { writeFailed.set() }
                }
                if estimatedFrames > 0 {
                    progress(min(0.5, Double(inputIndex) / Double(estimatedFrames) * 0.5))
                }
            }
        }
        group.wait()

        guard !framePaths.isEmpty else { throw ExportError.noFrames }
        guard !writeFailed.isSet else { throw ExportError.frameWriteFailed }

        // --- Phase 2 (50-100%): gifski across all cores ---
        progress(0.5)
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["--fps", String(gifFPS), "--quality", "90", "-o", destURL.path] + framePaths
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        let stderrBox = LockedData()
        let totalFrames = framePaths.count
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrBox.append(data)
            // gifski progress lines look like "123/900" (updated with \r)
            if let text = String(data: data, encoding: .utf8),
               let done = lastProgressCount(in: text), totalFrames > 0 {
                progress(0.5 + 0.5 * min(1.0, Double(done) / Double(totalFrames)))
            }
        }

        try proc.run()
        proc.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil

        guard proc.terminationStatus == 0 else {
            let msg = String(data: stderrBox.data, encoding: .utf8)?
                .split(separator: "\n").suffix(3).joined(separator: " ") ?? ""
            throw ExportError.gifskiFailed(proc.terminationStatus, msg)
        }
        progress(1.0)
    }

    // MARK: - Helpers

    /// Copies a 32BGRA pixel buffer into an independently-owned CGImage.
    private static func copyImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ), let dst = ctx.data else { return nil }

        let dstBytesPerRow = ctx.bytesPerRow
        let copyBytes = min(width * 4, min(bytesPerRow, dstBytesPerRow))
        for row in 0..<height {
            memcpy(dst + row * dstBytesPerRow, baseAddress + row * bytesPerRow, copyBytes)
        }
        return ctx.makeImage()
    }

    private static func writePNG(_ image: CGImage, toPath path: String) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Extracts the last "N/M" pair from gifski's progress output.
    private static func lastProgressCount(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "(\\d+)\\s*/\\s*\\d+") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }
}

// MARK: - Tiny thread-safe boxes (readabilityHandler runs on its own thread)

private final class LockedFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

private final class LockedData {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ d: Data) { lock.lock(); storage.append(d); lock.unlock() }
}
