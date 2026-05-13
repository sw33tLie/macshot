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

    /// Synchronous WindowServer snapshot used by global hotkeys before macshot
    /// activates. This preserves transient UI such as menu extras, app menus,
    /// Raycast/Spotlight-style panels, and other windows that disappear as soon
    /// as focus changes.
    static func makeImmediateCaptureContext() -> ImmediateCaptureContext {
        let screens = NSScreen.screens
        let mainHeight = screens.first?.frame.height ?? 0
        let mouseLocation = NSEvent.mouseLocation
        let includeCursor = UserDefaults.standard.bool(forKey: "captureCursor")
        let cursor: CursorCapture?
        if includeCursor {
            let current = NSCursor.current
            let image = current.image
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                cursor = CursorCapture(image: cgImage, size: image.size, hotSpot: current.hotSpot)
            } else {
                cursor = nil
            }
        } else {
            cursor = nil
        }

        return ImmediateCaptureContext(
            screens: screens,
            mainHeight: mainHeight,
            mouseLocation: mouseLocation,
            cursor: cursor)
    }

    static func captureAllScreensImmediately(context: ImmediateCaptureContext) -> [ScreenCapture] {
        return context.screens.compactMap { screen in
            let cgRect = CGRect(
                x: screen.frame.origin.x,
                y: context.mainHeight - screen.frame.origin.y - screen.frame.height,
                width: screen.frame.width,
                height: screen.frame.height)
            guard
                let image = CGWindowListCreateImage(
                    cgRect, .optionAll, kCGNullWindowID, .bestResolution
                )
            else { return nil }
            let finalImage: CGImage
            if let cursor = context.cursor {
                finalImage = imageByDrawingCursor(
                    cursor, onto: image, screen: screen, mouseLocation: context.mouseLocation)
            } else {
                finalImage = image
            }
            return ScreenCapture(screen: screen, image: finalImage)
        }
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
        excludingWindowNumbers: [CGWindowID] = [], completion: @escaping ([ScreenCapture]) -> Void
    ) {
        Task {
            do {
                // When excluding windows, fetch fresh content so newly-created
                // windows (e.g. thumbnails spawned after the cache was built) are
                // present in the window list and can actually be excluded.
                let content: SCShareableContent
                if !excludingWindowNumbers.isEmpty {
                    content = try await SCShareableContent.excludingDesktopWindows(
                        true, onScreenWindowsOnly: true)
                } else {
                    content = try await shareableContent()
                }
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
                        let screenNumber =
                            nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? CGDirectDisplayID
                        return screenNumber == display.displayID
                    }) {
                        pairs.append((display, screen))
                    }
                }

                // Capture all displays concurrently
                let captures = await withTaskGroup(
                    of: ScreenCapture?.self, returning: [ScreenCapture].self
                ) { group in
                    for (display, screen) in pairs {
                        group.addTask {
                            if #available(macOS 14.0, *) {
                                // SCScreenshotManager: single-shot API, no stream overhead
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
                                else { return nil }
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
                                guard
                                    let image = CGWindowListCreateImage(
                                        cgRect, .optionAll, kCGNullWindowID, .bestResolution
                                    )
                                else { return nil }
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
