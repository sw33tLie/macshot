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
                            config.width = display.width * 2
                            config.height = display.height * 2
                            config.showsCursor = false
                            config.captureResolution = .best
                            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                                // SCScreenshotManager returns an IOSurface-backed CGImage (GPU memory).
                                // Blit it into a CPU-backed bitmap now, while we're already on a
                                // background thread, so the first draw and tiffRepresentation calls
                                // at confirm-time are instant instead of stalling the main thread
                                // with a ~1 s GPU→CPU readback.
                                let cpuImage = Self.copyToCPUBacked(image) ?? image
                                return ScreenCapture(screen: screen, image: cpuImage)
                            }
                            return nil
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
