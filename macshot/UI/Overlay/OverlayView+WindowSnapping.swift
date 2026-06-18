import Cocoa

extension OverlayView {

    /// Result of window snap detection: the rect and optional window ID.
    struct WindowSnapResult {
        let rect: NSRect
        let windowID: CGWindowID
    }

    private struct WindowSnapCandidate {
        let rect: NSRect
        let windowID: CGWindowID
        let owner: String
        let ownerPID: Int
        let name: String
        let area: CGFloat
    }

    private static func isQuickLookWindow(_ info: [String: Any]) -> Bool {
        let owner = ((info[kCGWindowOwnerName as String] as? String) ?? "").lowercased()
        let name = ((info[kCGWindowName as String] as? String) ?? "").lowercased()
        return owner.contains("quicklook")
            || owner.contains("quick look")
            || name.contains("quicklook")
            || name.contains("quick look")
    }

    private static func isWindowSnapCandidate(_ info: [String: Any]) -> Bool {
        guard let layer = info[kCGWindowLayer as String] as? Int else { return false }
        if layer == 0 { return true }

        // Finder's Spacebar preview is rendered by a Quick Look helper/panel,
        // not always as a regular layer-0 app window. Keep the broad nonzero
        // layer filter for menus/tooltips, but allow this specific visible
        // preview window through so it can be snapped like a normal window.
        return isQuickLookWindow(info)
    }

    private static func isLikelyFinderQuickLookPreview(
        _ candidate: WindowSnapCandidate,
        frontmost: WindowSnapCandidate
    ) -> Bool {
        let owner = candidate.owner.lowercased()
        if owner.contains("quicklook") || owner.contains("quick look") { return true }
        guard owner == "finder", candidate.windowID != frontmost.windowID else { return false }

        // Finder's Spacebar preview is commonly exposed as an untitled Finder
        // window that is significantly tighter than the real Finder browser.
        // Keep this narrow so normal same-app overlapping windows still respect
        // z-order instead of snapping to covered smaller windows.
        let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            && candidate.area < frontmost.area * 0.85
            && candidate.rect.width >= 80
            && candidate.rect.height >= 80
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
        guard
            let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        var frontmost: WindowSnapCandidate?
        var sameOwnerCandidates: [WindowSnapCandidate] = []

        for info in windowList {
            guard isWindowSnapCandidate(info),
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
            if appKitRect.contains(screenPoint) {
                let viewRect = NSRect(
                    x: appKitRect.origin.x - windowOrigin.x,
                    y: appKitRect.origin.y - windowOrigin.y,
                    width: appKitRect.width,
                    height: appKitRect.height
                )
                let candidate = WindowSnapCandidate(
                    rect: viewRect.intersection(viewBounds),
                    windowID: CGWindowID(winNum),
                    owner: (info[kCGWindowOwnerName as String] as? String) ?? "",
                    ownerPID: (info[kCGWindowOwnerPID as String] as? Int) ?? 0,
                    name: (info[kCGWindowName as String] as? String) ?? "",
                    area: cgW * cgH,
                )

                if let frontmost {
                    // CG's list is z-ordered, so never let a lower/covered
                    // window from another app win just because it is smaller.
                    // Finder Quick Look is the exception: Spacebar previews can
                    // be reported as another Finder-owned layer-0 window, and
                    // choosing the tighter same-owner rect matches the visible
                    // preview without regressing normal inter-app overlap.
                    if candidate.ownerPID == frontmost.ownerPID {
                        sameOwnerCandidates.append(candidate)
                    }
                } else {
                    frontmost = candidate
                    sameOwnerCandidates = [candidate]
                }
            }
        }
        guard let frontmost else { return nil }

        let owner = frontmost.owner.lowercased()
        let best: WindowSnapCandidate
        if owner == "finder" || owner.contains("quicklook") || owner.contains("quick look") {
            best = sameOwnerCandidates
                .filter { isLikelyFinderQuickLookPreview($0, frontmost: frontmost) }
                .min(by: { $0.area < $1.area })
                ?? frontmost
        } else {
            best = frontmost
        }

        return WindowSnapResult(rect: best.rect, windowID: best.windowID)
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
