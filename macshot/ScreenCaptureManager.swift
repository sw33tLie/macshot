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
                                return ScreenCapture(screen: screen, image: image)
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
                NSLog("macshot: screen capture error: \(error.localizedDescription)")
                await MainActor.run { completion([]) }
            }
        }
    }
}
