import Cocoa

extension OverlayView {

    /// Result of window snap detection: the rect and optional window ID.
    struct WindowSnapResult {
        let rect: NSRect
        let windowID: CGWindowID
    }

    struct WindowSnapWindow {
        let appKitRect: NSRect
        let windowID: CGWindowID
    }

    /// Returns the frontmost visible window rect (in view coordinates) that contains `screenPoint`.
    /// `screenPoint` is in AppKit screen coordinates (origin bottom-left of main screen).
    static func windowRectOnBackground(
        screenPoint: NSPoint,
        overlayWindowNumber: Int,
        windowOrigin: NSPoint,
        viewBounds: NSRect,
        screenH: CGFloat
    ) -> WindowSnapResult? {
        let windows = enumerateSnapWindows(
            overlayWindowNumber: overlayWindowNumber,
            screenH: screenH)
        return windowSnapResult(
            at: screenPoint,
            windows: windows,
            windowOrigin: windowOrigin,
            viewBounds: viewBounds)
    }

    static func enumerateSnapWindows(
        overlayWindowNumber: Int,
        screenH: CGFloat
    ) -> [WindowSnapWindow] {
        guard
            let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var windows: [WindowSnapWindow] = []
        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                let winNum = info[kCGWindowNumber as String] as? Int,
                winNum != overlayWindowNumber
            else { continue }

            let cgX = boundsDict["X"] ?? 0
            let cgY = boundsDict["Y"] ?? 0
            let cgW = boundsDict["Width"] ?? 0
            let cgH = boundsDict["Height"] ?? 0
            guard cgW > 10 && cgH > 10 else { continue }

            let appKitRect = NSRect(x: cgX, y: screenH - cgY - cgH, width: cgW, height: cgH)
            windows.append(WindowSnapWindow(appKitRect: appKitRect, windowID: CGWindowID(winNum)))
        }
        return windows
    }

    static func windowSnapResult(
        at screenPoint: NSPoint,
        windows: [WindowSnapWindow],
        windowOrigin: NSPoint,
        viewBounds: NSRect
    ) -> WindowSnapResult? {
        for window in windows {
            if window.appKitRect.contains(screenPoint) {
                let viewRect = NSRect(
                    x: window.appKitRect.origin.x - windowOrigin.x,
                    y: window.appKitRect.origin.y - windowOrigin.y,
                    width: window.appKitRect.width,
                    height: window.appKitRect.height
                )
                return WindowSnapResult(
                    rect: viewRect.intersection(viewBounds),
                    windowID: window.windowID
                )
            }
        }
        return nil
    }

    func drawWindowSnapHighlight() {
        guard state == .idle, windowSnapEnabled, let rect = hoveredWindowRect, !rect.isEmpty else {
            return
        }

        NSColor.systemBlue.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        let border = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        border.lineWidth = 2
        NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
        border.stroke()
    }
}
