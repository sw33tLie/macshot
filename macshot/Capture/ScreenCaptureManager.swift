import Cocoa
import ScreenCaptureKit

struct ScreenCapture {
    let screen: NSScreen
    let image: CGImage
}

class ScreenCaptureManager {

    struct ImmediateCaptureContext {
        let screens: [NSScreen]
        let mainHeight: CGFloat
        let mouseLocation: NSPoint
        let cursor: CursorCapture?
    }

    struct CursorCapture {
        let image: CGImage
        let size: NSSize
        let hotSpot: NSPoint
    }

    // MARK: - SCShareableContent cache

    /// Cached shareable content to avoid repeated (slow) enumeration.
    private static var cachedContent: SCShareableContent?
    private static var cachedContentTime: Date = .distantPast
    /// Cache is valid for 2 seconds — long enough to survive the hotkey→capture gap,
    /// short enough that display changes are picked up.
    private static let cacheTTL: TimeInterval = 2.0
    private static let immediatePrewarmQueue = DispatchQueue(label: "macshot.immediate-capture-prewarm", qos: .utility)
    private static var didPrewarmImmediateCapture = false

    /// Fetch shareable content, using a short-lived cache to avoid redundant enumeration.
    private static func shareableContent() async throws -> SCShareableContent {
        if let cached = cachedContent, Date().timeIntervalSince(cachedContentTime) < cacheTTL {
            return cached
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
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

    /// Warm the CGWindowList screenshot path used by zero-delay global hotkeys.
    /// The real capture still happens at hotkey time so transient UI is current,
    /// but this pays the first WindowServer/privacy/capture setup cost while idle.
    static func prewarmImmediateCapture() {
        let screens = NSScreen.screens
        guard let screen = NSScreen.main ?? screens.first else { return }
        let mainHeight = screens.first?.frame.height ?? screen.frame.height
        let rect = CGRect(
            x: screen.frame.midX,
            y: mainHeight - screen.frame.midY,
            width: 1,
            height: 1)

        immediatePrewarmQueue.async {
            guard !didPrewarmImmediateCapture else { return }
            didPrewarmImmediateCapture = true
            _ = CGWindowListCreateImage(rect, .optionAll, kCGNullWindowID, .bestResolution)
        }
    }

    /// Synchronous WindowServer snapshot used by global hotkeys before macshot
    /// activates. This preserves transient UI such as menu extras, app menus,
    /// Raycast/Spotlight-style panels, and other windows that disappear as soon
    /// as focus changes.
    static func makeImmediateCaptureContext(timing: (@Sendable (String) -> Void)? = nil) -> ImmediateCaptureContext {
        timing?("makeImmediateCaptureContext NSScreen.screens begin")
        let screens = NSScreen.screens
        timing?("makeImmediateCaptureContext NSScreen.screens end count=\(screens.count)")
        let mainHeight = screens.first?.frame.height ?? 0
        let mouseLocation = NSEvent.mouseLocation
        let includeCursor = UserDefaults.standard.bool(forKey: "captureCursor")
        let cursor: CursorCapture?
        if includeCursor {
            timing?("makeImmediateCaptureContext cursor capture begin")
            let current = NSCursor.current
            let image = current.image
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                cursor = CursorCapture(image: cgImage, size: image.size, hotSpot: current.hotSpot)
            } else {
                cursor = nil
            }
            timing?("makeImmediateCaptureContext cursor capture end captured=\(cursor != nil)")
        } else {
            cursor = nil
        }

        return ImmediateCaptureContext(
            screens: screens,
            mainHeight: mainHeight,
            mouseLocation: mouseLocation,
            cursor: cursor)
    }

    static func captureAllScreensImmediately(
        context: ImmediateCaptureContext,
        timing: (@Sendable (String) -> Void)? = nil
    ) -> [ScreenCapture] {
        timing?("captureAllScreensImmediately screens=\(context.screens.count)")
        return context.screens.enumerated().compactMap { index, screen in
            let cgRect = CGRect(
                x: screen.frame.origin.x,
                y: context.mainHeight - screen.frame.origin.y - screen.frame.height,
                width: screen.frame.width,
                height: screen.frame.height)
            timing?("CGWindowListCreateImage begin screen=\(index)")
            guard
                let image = CGWindowListCreateImage(
                    cgRect, .optionAll, kCGNullWindowID, .bestResolution
                )
            else {
                timing?("CGWindowListCreateImage failed screen=\(index)")
                return nil
            }
            timing?("CGWindowListCreateImage end screen=\(index) pixels=\(image.width)x\(image.height)")
            let finalImage: CGImage
            if let cursor = context.cursor {
                timing?("draw cursor begin screen=\(index)")
                finalImage = imageByDrawingCursor(
                    cursor, onto: image, screen: screen, mouseLocation: context.mouseLocation)
                timing?("draw cursor end screen=\(index)")
            } else {
                finalImage = image
            }
            return ScreenCapture(screen: screen, image: finalImage)
        }
    }

    static func makeDisplayPreviewImage(from image: CGImage, maxPixelDimension: Int = 1400) -> CGImage {
        let maxDimension = max(image.width, image.height)
        guard maxDimension > maxPixelDimension else { return image }

        let scale = CGFloat(maxPixelDimension) / CGFloat(maxDimension)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func imageByDrawingCursor(
        _ cursor: CursorCapture, onto image: CGImage, screen: NSScreen, mouseLocation: NSPoint
    ) -> CGImage {
        guard screen.frame.contains(mouseLocation) else { return image }

        guard
            let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }

        let imageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: imageRect)

        let scaleX = CGFloat(image.width) / screen.frame.width
        let scaleY = CGFloat(image.height) / screen.frame.height

        let localMouse = NSPoint(
            x: mouseLocation.x - screen.frame.minX,
            y: mouseLocation.y - screen.frame.minY)
        let cursorRect = CGRect(
            x: (localMouse.x - cursor.hotSpot.x) * scaleX,
            y: (localMouse.y - cursor.hotSpot.y) * scaleY,
            width: cursor.size.width * scaleX,
            height: cursor.size.height * scaleY)
        context.draw(cursor.image, in: cursorRect)

        return context.makeImage() ?? image
    }

    static func captureAllScreens(
        excludingWindowNumbers: [CGWindowID] = [],
        timing: (@Sendable (String) -> Void)? = nil,
        completion: @escaping ([ScreenCapture]) -> Void
    ) {
        Task {
            do {
                timing?("captureAllScreens Task entered")
                // When excluding windows, fetch fresh content so newly-created
                // windows (e.g. thumbnails spawned after the cache was built) are
                // present in the window list and can actually be excluded.
                let content: SCShareableContent
                if !excludingWindowNumbers.isEmpty {
                    timing?("SCShareableContent fresh begin")
                    content = try await SCShareableContent.excludingDesktopWindows(
                        true, onScreenWindowsOnly: true)
                    timing?("SCShareableContent fresh end displays=\(content.displays.count) windows=\(content.windows.count)")
                } else {
                    timing?("SCShareableContent cached begin")
                    content = try await shareableContent()
                    timing?("SCShareableContent cached end displays=\(content.displays.count) windows=\(content.windows.count)")
                }
                let displays = content.displays
                timing?("captureAllScreens NSScreen.screens begin")
                let screens = NSScreen.screens
                timing?("captureAllScreens NSScreen.screens end count=\(screens.count)")

                // Resolve window numbers to SCWindow objects for exclusion
                timing?("resolve excluded windows begin count=\(excludingWindowNumbers.count)")
                let excludedSCWindows: [SCWindow] = excludingWindowNumbers.compactMap { wid in
                    content.windows.first(where: { CGWindowID($0.windowID) == wid })
                }
                timing?("resolve excluded windows end matched=\(excludedSCWindows.count)")

                // Build display-screen pairs
                timing?("build display-screen pairs begin displays=\(displays.count)")
                var pairs: [(SCDisplay, NSScreen)] = []
                for display in displays {
                    if let screen = screens.first(where: { nsScreen in
                        let screenNumber =
                            nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? CGDirectDisplayID
                        return screenNumber == display.displayID
                    }) {
                        pairs.append((display, screen))
                    }
                }
                timing?("build display-screen pairs end pairs=\(pairs.count)")

                // Capture all displays concurrently
                timing?("SCScreenshot capture group begin pairs=\(pairs.count)")
                let captures = await withTaskGroup(
                    of: ScreenCapture?.self, returning: [ScreenCapture].self
                ) { group in
                    for (index, pair) in pairs.enumerated() {
                        let (display, screen) = pair
                        group.addTask {
                            if #available(macOS 14.0, *) {
                                // SCScreenshotManager: single-shot API, no stream overhead
                                timing?("SCScreenshotManager capture begin display=\(index)")
                                let filter = SCContentFilter(
                                    display: display, excludingWindows: excludedSCWindows)
                                let config = SCStreamConfiguration()
                                let scale = Int(screen.backingScaleFactor)
                                config.width = display.width * scale
                                config.height = display.height * scale
                                config.showsCursor = UserDefaults.standard.bool(
                                    forKey: "captureCursor")
                                config.captureResolution = .best

                                guard
                                    let image = try? await SCScreenshotManager.captureImage(
                                        contentFilter: filter, configuration: config
                                    )
                                else {
                                    timing?("SCScreenshotManager capture failed display=\(index)")
                                    return nil
                                }
                                timing?("SCScreenshotManager capture end display=\(index) pixels=\(image.width)x\(image.height)")
                                return ScreenCapture(screen: screen, image: image)
                            } else {
                                // macOS 12.3–13.x: use CGWindowListCreateImage which returns
                                // a CGImage directly — no pixel buffer format ambiguity.
                                // Convert the AppKit screen frame (bottom-left origin) to the
                                // CGDisplay coordinate space (top-left origin) for the capture rect.
                                let mainHeight =
                                    NSScreen.screens.first?.frame.height ?? screen.frame.height
                                let cgRect = CGRect(
                                    x: screen.frame.origin.x,
                                    y: mainHeight - screen.frame.origin.y - screen.frame.height,
                                    width: screen.frame.width,
                                    height: screen.frame.height)
                                timing?("fallback CGWindowListCreateImage begin display=\(index)")
                                guard
                                    let image = CGWindowListCreateImage(
                                        cgRect, .optionAll, kCGNullWindowID, .bestResolution
                                    )
                                else {
                                    timing?("fallback CGWindowListCreateImage failed display=\(index)")
                                    return nil
                                }
                                timing?("fallback CGWindowListCreateImage end display=\(index) pixels=\(image.width)x\(image.height)")
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
                timing?("SCScreenshot capture group end captures=\(captures.count)")

                await MainActor.run { completion(captures) }
            } catch {
                timing?("captureAllScreens error \(error.localizedDescription)")
                #if DEBUG
                    NSLog("macshot: screen capture error: \(error.localizedDescription)")
                #endif
                await MainActor.run { completion([]) }
            }
        }
    }

    // MARK: - Single window capture (with transparency)

    /// Captures a single window by its CGWindowID, returning an image with transparent corners.
    /// On macOS 14+, uses `desktopIndependentWindow` filter for clean transparent background.
    /// On macOS 12–13, uses `CGWindowListCreateImage` targeting the specific window.
    static func captureWindow(windowID: CGWindowID, screen: NSScreen) async -> CGImage? {
        if #available(macOS 14.0, *) {
            guard
                let content = try? await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
            else { return nil }
            guard
                let scWindow = content.windows.first(where: { CGWindowID($0.windowID) == windowID })
            else { return nil }

            let filter: SCContentFilter
            if #available(macOS 14.2, *) {
                filter = SCContentFilter(desktopIndependentWindow: scWindow)
            } else {
                guard
                    let display = content.displays.first(where: {
                        let screenID =
                            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? CGDirectDisplayID
                        return screenID != nil && $0.displayID == screenID!
                    }) ?? content.displays.first
                else { return nil }
                let otherWindows = content.windows.filter { CGWindowID($0.windowID) != windowID }
                filter = SCContentFilter(display: display, excludingWindows: otherWindows)
            }

            let config = SCStreamConfiguration()
            let scale = Int(screen.backingScaleFactor)
            config.width = Int(scWindow.frame.width) * scale
            config.height = Int(scWindow.frame.height) * scale
            config.showsCursor = false
            config.captureResolution = .best

            guard
                let image = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                )
            else { return nil }
            return image
        } else {
            // macOS 12.3–13.x: CGWindowListCreateImage targeting the specific window
            return CGWindowListCreateImage(
                .null, .optionIncludingWindow, windowID, .bestResolution)
        }
    }
}
