import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreVideo

/// Accumulates CVPixelBuffer frames and writes them as an animated GIF.
final class GIFEncoder {

    private let url: URL
    private let delayTime: Float   // seconds per frame
    private var destination: CGImageDestination?
    private let frameProperties: [CFString: Any]
    private let gifProperties: [CFString: Any]
    private var frameCount = 0
    private let lock = NSLock()

    // Throttle: only keep every Nth frame to stay at target fps
    private let targetFPS: Int
    private var inputFrameCount = 0
    private let sourceEstimatedFPS: Int

    init(url: URL, fps: Int, sourceFPS: Int) {
        self.url = url
        self.sourceEstimatedFPS = max(sourceFPS, fps)
        // Cap GIF at 15fps for reasonable file size
        let gifFPS = min(fps, 15)
        self.targetFPS = gifFPS
        self.delayTime = 1.0 / Float(gifFPS)

        frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delayTime,
                kCGImagePropertyGIFLoopCount: 0,  // 0 = infinite
            ] as [CFString: Any]
        ]
        gifProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0,
            ] as [CFString: Any]
        ]

        destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, Int.max, nil)
        if let dest = destination {
            CGImageDestinationSetProperties(dest, gifProperties as CFDictionary)
        }
    }

    /// Add a frame. Called from background thread — thread safe via lock.
    func addFrame(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        defer { lock.unlock() }

        // Throttle to target fps
        let keepEvery = max(1, sourceEstimatedFPS / targetFPS)
        inputFrameCount += 1
        guard inputFrameCount % keepEvery == 0 else { return }

        guard let dest = destination else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let cgImage = ctx.makeImage() else { return }

        CGImageDestinationAddImage(dest, cgImage, frameProperties as CFDictionary)
        frameCount += 1
    }

    func finish() {
        guard let dest = destination, frameCount > 0 else { return }
        CGImageDestinationFinalize(dest)
        destination = nil
    }
}
