import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreVideo

/// Accumulates CVPixelBuffer frames and writes them as an animated GIF.
/// Each frame's pixel data is copied immediately so the pixel buffer can be
/// safely recycled (alwaysCopiesSampleData=false).
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

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            return
        }

        // Wrap the pixel buffer in a CGContext to get a CGImage reference,
        // then copy into an owned context so the image survives after unlock.
        // CGImageDestinationFinalize reads all frames later — each CGImage
        // must own its pixel data independently.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let srcCtx = CGContext(
            data: baseAddress,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ), let srcImage = srcCtx.makeImage() else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            return
        }

        guard let ownedCtx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            return
        }
        ownedCtx.draw(srcImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        guard let cgImage = ownedCtx.makeImage() else { return }
        CGImageDestinationAddImage(dest, cgImage, frameProperties as CFDictionary)
        frameCount += 1
    }

    func finish() {
        guard let dest = destination, frameCount > 0 else { return }
        CGImageDestinationFinalize(dest)
        destination = nil
    }
}
