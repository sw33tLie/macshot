import Cocoa
import ScreenCaptureKit

struct ScreenCapture {
    let screen: NSScreen
    let image: CGImage
}

class ScreenCaptureManager {

    static func captureAllScreens(completion: @escaping ([ScreenCapture]) -> Void) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                let displays = content.displays
                let screens = NSScreen.screens

                // Build display-screen pairs
                var pairs: [(SCDisplay, NSScreen)] = []
                for display in displays {
                    if let screen = screens.first(where: { nsScreen in
                        let screenNumber = nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                        return screenNumber == display.displayID
                    }) {
                        pairs.append((display, screen))
                    }
                }

                // Capture all displays concurrently
                let captures = await withTaskGroup(of: ScreenCapture?.self, returning: [ScreenCapture].self) { group in
                    for (display, screen) in pairs {
                        group.addTask {
                            let filter = SCContentFilter(display: display, excludingWindows: [])
                            let config = SCStreamConfiguration()
                            let scale = Int(screen.backingScaleFactor)
                            config.width = display.width * scale
                            config.height = display.height * scale
                            config.showsCursor = UserDefaults.standard.bool(forKey: "captureCursor")
                            if #available(macOS 14.0, *) {
                                config.captureResolution = .best
                            }
                            guard let image = try? await Self.captureSingleFrame(filter: filter, config: config) else {
                                return nil
                            }
                            // Blit into a CPU-backed bitmap now, while we're already on a
                            // background thread, so the first draw and tiffRepresentation calls
                            // at confirm-time are instant instead of stalling the main thread
                            // with a ~1 s GPU→CPU readback.
                            let cpuImage = Self.copyToCPUBacked(image) ?? image
                            return ScreenCapture(screen: screen, image: cpuImage)
                        }
                    }
                    var results: [ScreenCapture] = []
                    for await capture in group {
                        if let capture = capture {
                            results.append(capture)
                        }
                    }
                    return results
                }

                await MainActor.run { completion(captures) }
            } catch {
                #if DEBUG
                NSLog("macshot: screen capture error: \(error.localizedDescription)")
                #endif
                await MainActor.run { completion([]) }
            }
        }
    }

    // MARK: - SCStream single-frame capture (works on macOS 12.3+)

    /// Start an SCStream, grab the first frame, then stop.
    /// This replaces SCScreenshotManager.captureImage() which requires macOS 14+.
    private static func captureSingleFrame(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> CGImage? {
        let handler = SingleFrameHandler()
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: DispatchQueue(label: "macshot.singleframe"))
        try await stream.startCapture()

        // Wait for frame with a timeout to prevent hanging if no frame arrives
        let image = await withTaskGroup(of: CGImage?.self) { group -> CGImage? in
            group.addTask { await handler.waitForFrame() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 second timeout
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }

        try? await stream.stopCapture()
        return image
    }

    /// Blit an IOSurface-backed CGImage into a plain CPU-backed bitmap.
    /// This forces the GPU→CPU readback on the calling (background) thread so it
    /// never blocks the main thread later when the image is first drawn or encoded.
    private static func copyToCPUBacked(_ src: CGImage) -> CGImage? {
        let w = src.width
        let h = src.height
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

// MARK: - Single-frame stream output handler

/// Receives exactly one frame from an SCStream and exposes it via async/await.
private final class SingleFrameHandler: NSObject, SCStreamOutput, @unchecked Sendable {
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var capturedImage: CGImage?
    private var delivered = false
    private let lock = NSLock()

    func waitForFrame() async -> CGImage? {
        await withCheckedContinuation { cont in
            lock.lock()
            if delivered {
                // Frame already arrived before we started waiting
                let image = capturedImage
                lock.unlock()
                cont.resume(returning: image)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        // Skip frames without valid image data (blank, idle, suspended)
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        let cgImage = context.createCGImage(ciImage, from: ciImage.extent)

        lock.lock()
        guard !delivered else { lock.unlock(); return }
        delivered = true
        capturedImage = cgImage
        let cont = continuation
        continuation = nil
        lock.unlock()

        cont?.resume(returning: cgImage)
    }
}
