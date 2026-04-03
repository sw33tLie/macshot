import Cocoa
import ScreenCaptureKit

struct ScreenCapture {
    let screen: NSScreen
    let image: CGImage
}

class ScreenCaptureManager {

    // MARK: - SCShareableContent cache

    /// Cached shareable content to avoid repeated (slow) enumeration.
    private static var cachedContent: SCShareableContent?
    private static var cachedContentTime: Date = .distantPast
    /// Cache is valid for 2 seconds — long enough to survive the hotkey→capture gap,
    /// short enough that display changes are picked up.
    private static let cacheTTL: TimeInterval = 2.0

    /// Fetch shareable content, using a short-lived cache to avoid redundant enumeration.
    private static func shareableContent() async throws -> SCShareableContent {
        if let cached = cachedContent, Date().timeIntervalSince(cachedContentTime) < cacheTTL {
            return cached
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        cachedContent = content
        cachedContentTime = Date()
        return content
    }

    /// Pre-warm the shareable content cache so the next capture is instant.
    /// Call this when the menu bar opens or a hotkey is pressed — before the actual capture starts.
    static func prewarm() {
        Task {
            _ = try? await shareableContent()
        }
    }

    static func captureAllScreens(completion: @escaping ([ScreenCapture]) -> Void) {
        Task {
            do {
                let content = try await shareableContent()
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

                            if #available(macOS 14.0, *) {
                                // SCScreenshotManager: single-shot API, no stream overhead
                                guard let image = try? await SCScreenshotManager.captureImage(
                                    contentFilter: filter, configuration: config
                                ) else { return nil }
                                // SCScreenshotManager returns ARGB16F (GPU-native). Convert to
                                // 8-bit BGRA here on the background thread so the first draw()
                                // on the main thread is instant (no vImage pixel conversion).
                                let cpuImage = Self.copyTo8BitBGRA(image) ?? image
                                return ScreenCapture(screen: screen, image: cpuImage)
                            } else {
                                // macOS 12.3–13.x: SCStream single-frame fallback
                                // (already returns 8-bit from createCGImage(from:))
                                guard let image = try? await Self.captureSingleFrame(
                                    filter: filter, config: config
                                ) else { return nil }
                                return ScreenCapture(screen: screen, image: image)
                            }
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

    // MARK: - SCStream single-frame capture (macOS 12.3–13.x only)

    /// Start an SCStream, grab the first frame, then stop.
    /// Only used on macOS 12.3–13.x where SCScreenshotManager is unavailable.
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

    /// Convert a CGImage (potentially ARGB16F or other GPU format) into an 8-bit BGRA bitmap.
    /// This forces the pixel format conversion on the current (background) thread so it
    /// doesn't stall the main thread when the image is first drawn.
    private static func copyTo8BitBGRA(_ src: CGImage) -> CGImage? {
        let w = src.width
        let h = src.height
        // Use the source image's color space (typically display P3 on modern Macs) so
        // CoreGraphics doesn't need a color space conversion when drawing to screen.
        let cs = src.colorSpace ?? CGColorSpaceCreateDeviceRGB()
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
        guard let result = ctx.makeImage() else { return nil }
        // Force pixel data to materialize now (not lazily on first draw).
        // Accessing the data provider triggers any deferred rendering.
        _ = result.dataProvider?.data
        return result
    }
    // MARK: - Single window capture (with transparency)

    /// Captures a single window by its CGWindowID, returning an image with transparent corners.
    /// Uses `desktopIndependentWindow` filter so the window is rendered without the desktop behind it.
    static func captureWindow(windowID: CGWindowID, screen: NSScreen) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        guard let scWindow = content.windows.first(where: { CGWindowID($0.windowID) == windowID }) else { return nil }

        let filter: SCContentFilter
        if #available(macOS 14.2, *) {
            filter = SCContentFilter(desktopIndependentWindow: scWindow)
        } else {
            // Fallback: capture display excluding all other windows
            guard let display = content.displays.first(where: {
                let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                return screenID != nil && $0.displayID == screenID!
            }) ?? content.displays.first else { return nil }
            let otherWindows = content.windows.filter { CGWindowID($0.windowID) != windowID }
            filter = SCContentFilter(display: display, excludingWindows: otherWindows)
        }

        let config = SCStreamConfiguration()
        let scale = Int(screen.backingScaleFactor)
        config.width = Int(scWindow.frame.width) * scale
        config.height = Int(scWindow.frame.height) * scale
        config.showsCursor = false
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
        }

        if #available(macOS 14.0, *) {
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            ) else { return nil }
            return copyTo8BitBGRA(image) ?? image
        } else {
            return try? await captureSingleFrame(filter: filter, config: config)
        }
    }
}

// MARK: - Single-frame stream output handler

/// Receives exactly one frame from an SCStream and exposes it via async/await.
/// Only used on macOS 12.3–13.x.
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
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        // Extract a CPU-backed CGImage directly from the pixel buffer — no CIImage/CIContext overhead.
        let image = Self.createCGImage(from: pixelBuffer)

        lock.lock()
        guard !delivered else { lock.unlock(); return }
        delivered = true
        capturedImage = image
        let cont = continuation
        continuation = nil
        lock.unlock()

        cont?.resume(returning: image)
    }

    /// Create a CGImage from a CVPixelBuffer by blitting into a CPU-backed bitmap context.
    /// This avoids the CIImage → CIContext.createCGImage() GPU render pass and produces
    /// a fully CPU-resident image in a single copy.
    private static func createCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

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

        guard let dstBase = ctx.data else { return nil }
        let dstBytesPerRow = ctx.bytesPerRow

        // Fast row-by-row copy (src may have padding bytes per row)
        if srcBytesPerRow == dstBytesPerRow {
            memcpy(dstBase, srcBase, h * srcBytesPerRow)
        } else {
            let copyBytes = min(srcBytesPerRow, dstBytesPerRow)
            for y in 0..<h {
                memcpy(dstBase + y * dstBytesPerRow, srcBase + y * srcBytesPerRow, copyBytes)
            }
        }

        return ctx.makeImage()
    }
}
