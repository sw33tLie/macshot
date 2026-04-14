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
    private static var displayConfigChanged = true

    /// Register for display reconfiguration notifications to invalidate cache
    /// only when monitors are connected/disconnected. Called once at app launch.
    static func registerDisplayChangeHandler() {
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, nil)
    }

    private static let displayReconfigCallback: CGDisplayReconfigurationCallBack = { displayID, flags, _ in
        if flags.contains(.addFlag) || flags.contains(.removeFlag) ||
           flags.contains(.enabledFlag) || flags.contains(.disabledFlag) {
            ScreenCaptureManager.displayConfigChanged = true
            ScreenCaptureManager.cachedContent = nil
        }
    }

    /// In-flight fetch task — shared so concurrent callers (prewarm + capture)
    /// await the same XPC call instead of making duplicate requests.
    private static var fetchTask: Task<SCShareableContent, Error>?

    /// Fetch shareable content, using a persistent cache that only invalidates
    /// when display configuration changes (monitor connect/disconnect).
    /// The cached data is only used to resolve displays for the capture filter —
    /// actual screenshot pixels are always fresh from SCScreenshotManager.
    /// If a fetch is already in flight (e.g. from prewarm), callers join it
    /// instead of starting a second XPC call.
    private static func shareableContent() async throws -> SCShareableContent {
        if let cached = cachedContent, !displayConfigChanged {
            return cached
        }
        // Join in-flight fetch if one exists (prevents duplicate XPC calls
        // when prewarm and capture race on first launch)
        if let existing = fetchTask {
            return try await existing.value
        }
        let task = Task {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            cachedContent = content
            displayConfigChanged = false
            fetchTask = nil
            return content
        }
        fetchTask = task
        return try await task.value
    }

    /// Pre-warm the shareable content cache so the first capture is instant.
    static func prewarm() {
        Task {
            _ = try? await shareableContent()
        }
    }

    static func captureAllScreens(excludingWindowNumbers: [CGWindowID] = [], completion: @escaping ([ScreenCapture]) -> Void) {
        Task {
            do {
                let content = try await shareableContent()
                let displays = content.displays
                let screens = NSScreen.screens

                // Resolve window numbers to SCWindow objects for exclusion
                let excludedSCWindows: [SCWindow] = excludingWindowNumbers.compactMap { wid in
                    content.windows.first(where: { CGWindowID($0.windowID) == wid })
                }

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
                            if #available(macOS 14.0, *) {
                                // SCScreenshotManager: single-shot API, no stream overhead
                                let filter = SCContentFilter(display: display, excludingWindows: excludedSCWindows)
                                let config = SCStreamConfiguration()
                                let scale = Int(screen.backingScaleFactor)
                                config.width = display.width * scale
                                config.height = display.height * scale
                                config.showsCursor = UserDefaults.standard.bool(forKey: "captureCursor")
                                config.captureResolution = .best

                                guard let image = try? await SCScreenshotManager.captureImage(
                                    contentFilter: filter, configuration: config
                                ) else { return nil }
                                // SCScreenshotManager returns ARGB16F (GPU-native). Convert to
                                // 8-bit BGRA here on the background thread so the first draw()
                                // on the main thread is instant (no vImage pixel conversion).
                                let cpuImage = Self.copyTo8BitBGRA(image) ?? image
                                return ScreenCapture(screen: screen, image: cpuImage)
                            } else {
                                let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
                                let cgRect = CGRect(
                                    x: screen.frame.origin.x,
                                    y: mainHeight - screen.frame.origin.y - screen.frame.height,
                                    width: screen.frame.width,
                                    height: screen.frame.height)
                                guard let image = CGWindowListCreateImage(
                                    cgRect, .optionAll, kCGNullWindowID, .bestResolution
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
    /// On macOS 14+, uses `desktopIndependentWindow` filter for clean transparent background.
    /// On macOS 12–13, uses `CGWindowListCreateImage` targeting the specific window.
    static func captureWindow(windowID: CGWindowID, screen: NSScreen) async -> CGImage? {
        if #available(macOS 14.0, *) {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
            guard let scWindow = content.windows.first(where: { CGWindowID($0.windowID) == windowID }) else { return nil }

            let filter: SCContentFilter
            if #available(macOS 14.2, *) {
                filter = SCContentFilter(desktopIndependentWindow: scWindow)
            } else {
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
            config.captureResolution = .best

            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            ) else { return nil }
            return copyTo8BitBGRA(image) ?? image
        } else {
            // macOS 12.3–13.x: CGWindowListCreateImage targeting the specific window
            return CGWindowListCreateImage(
                .null, .optionIncludingWindow, windowID, .bestResolution)
        }
    }
}
