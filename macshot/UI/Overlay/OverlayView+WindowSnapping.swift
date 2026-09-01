import Cocoa

extension OverlayView {

    static let browserElementSnapEnabledKey = "browserElementSnapEnabled"
    private static let browserAccessibilityLock = NSLock()
    private static var browserAccessibilitySessionToken = 0
    private static var browserAccessibilityPreviousValues: [Int: BrowserAccessibilityValues] = [:]

    private struct BrowserAccessibilityValues {
        let application: AXUIElement
        let manualAccessibility: CFTypeRef?
    }

    enum SnapMode: Int {
        case window
        case element
        case off

        var next: SnapMode {
            switch self {
            case .window: return .element
            case .element: return .off
            case .off: return .window
            }
        }
    }

    /// Window metadata used by both window and accessibility-element snapping.
    struct WindowSnapResult {
        let rect: NSRect
        let windowID: CGWindowID
        let ownerPID: Int
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

        return WindowSnapResult(
            rect: best.rect,
            windowID: best.windowID,
            ownerPID: best.ownerPID)
    }

    /// Returns the accessibility element under the pointer, clipped to the
    /// visible window and converted into overlay-view coordinates. Apps that
    /// do not expose a usable element fall back to their window rect.
    static func elementSnapResult(
        screenPoint: NSPoint,
        windowResult: WindowSnapResult,
        windowOrigin: NSPoint,
        viewBounds: NSRect,
        screenH: CGFloat,
        accessibilitySessionToken: Int
    ) -> (result: WindowSnapResult, didPrepareBrowserAccessibility: Bool) {
        guard AXIsProcessTrusted(), windowResult.ownerPID > 0 else {
            return (windowResult, false)
        }

        let application = AXUIElementCreateApplication(pid_t(windowResult.ownerPID))
        AXUIElementSetMessagingTimeout(application, 0.2)
        let didPrepareBrowserAccessibility = prepareBrowserAccessibilityIfNeeded(
            application: application,
            ownerPID: windowResult.ownerPID,
            sessionToken: accessibilitySessionToken)

        var hitElement: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            application,
            Float(screenPoint.x),
            Float(screenH - screenPoint.y),
            &hitElement)
        guard error == .success, let hitElement,
              let axRect = deepestAccessibilityRect(
                at: NSPoint(x: screenPoint.x, y: screenH - screenPoint.y),
                from: hitElement)
        else { return (windowResult, didPrepareBrowserAccessibility) }

        let appKitRect = NSRect(
            x: axRect.origin.x,
            y: screenH - axRect.origin.y - axRect.height,
            width: axRect.width,
            height: axRect.height)
        let viewRect = NSRect(
            x: appKitRect.origin.x - windowOrigin.x,
            y: appKitRect.origin.y - windowOrigin.y,
            width: appKitRect.width,
            height: appKitRect.height)
            .intersection(windowResult.rect)
            .intersection(viewBounds)
        guard viewRect.width > 2, viewRect.height > 2 else {
            return (windowResult, didPrepareBrowserAccessibility)
        }

        return (
            WindowSnapResult(
                rect: viewRect,
                windowID: windowResult.windowID,
                ownerPID: windowResult.ownerPID),
            didPrepareBrowserAccessibility)
    }

    private struct AccessibilityNodeInfo {
        let rect: NSRect?
        let isHidden: Bool
        let children: [AXUIElement]
    }

    /// Refine the direct AX hit by following only descendants whose frames
    /// contain the pointer. The limits keep custom or malformed AX trees from
    /// turning mouse movement into an unbounded traversal.
    private static func deepestAccessibilityRect(
        at axPoint: NSPoint,
        from root: AXUIElement
    ) -> NSRect? {
        let deadline = CFAbsoluteTimeGetCurrent() + 0.035
        let maxDepth = 8
        let maxVisited = 48
        let maxChildrenPerNode = 64
        var pending: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var visited = Set<CFHashCode>()
        var bestRect: NSRect?
        var bestArea = CGFloat.greatestFiniteMagnitude

        while let current = pending.popLast(), visited.count < maxVisited {
            let remainingTime = deadline - CFAbsoluteTimeGetCurrent()
            if current.depth > 0 && remainingTime <= 0 { break }
            let identity = CFHash(current.element)
            guard visited.insert(identity).inserted,
                  let info = accessibilityNodeInfo(
                    of: current.element,
                    messagingTimeout: Float(max(0.001, remainingTime)),
                    maxChildren: maxChildrenPerNode),
                  !info.isHidden
            else { continue }

            let containsPoint = info.rect?.contains(axPoint) ?? true
            if let rect = info.rect, containsPoint {
                let area = rect.width * rect.height
                if area < bestArea {
                    bestRect = rect
                    bestArea = area
                }
            }

            guard containsPoint,
                  current.depth < maxDepth,
                  CFAbsoluteTimeGetCurrent() < deadline
            else { continue }

            for child in info.children.reversed() {
                pending.append((child, current.depth + 1))
            }
        }

        return bestRect
    }

    /// Chromium/Electron may lazily omit web-content AX nodes until an assistive
    /// client requests manual or enhanced accessibility. Unsupported native apps
    /// ignore the attributes. Attempt them once per target PID per capture session.
    private static func prepareBrowserAccessibilityIfNeeded(
        application: AXUIElement,
        ownerPID: Int,
        sessionToken: Int
    ) -> Bool {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: browserElementSnapEnabledKey) as? Bool ?? true
        guard enabled else { return false }

        browserAccessibilityLock.lock()
        guard sessionToken == browserAccessibilitySessionToken else {
            browserAccessibilityLock.unlock()
            return false
        }
        guard browserAccessibilityPreviousValues[ownerPID] == nil else {
            browserAccessibilityLock.unlock()
            return false
        }

        browserAccessibilityPreviousValues[ownerPID] = BrowserAccessibilityValues(
            application: application,
            manualAccessibility: accessibilityAttributeValue(
                "AXManualAccessibility" as CFString,
                of: application))

        // Chromium/Electron builds may report errors even when these values
        // successfully materialize the web-content accessibility tree.
        AXUIElementSetAttributeValue(
            application,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue)
        AXUIElementSetAttributeValue(
            application,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue)
        browserAccessibilityLock.unlock()
        return true
    }

    static func currentBrowserAccessibilitySessionToken() -> Int {
        browserAccessibilityLock.lock()
        defer { browserAccessibilityLock.unlock() }
        return browserAccessibilitySessionToken
    }

    static func resetBrowserAccessibilityPreparation() {
        browserAccessibilityLock.lock()
        browserAccessibilitySessionToken &+= 1
        let previousValues = Array(browserAccessibilityPreviousValues.values)
        browserAccessibilityPreviousValues.removeAll()

        for values in previousValues {
            AXUIElementSetAttributeValue(
                values.application,
                "AXManualAccessibility" as CFString,
                values.manualAccessibility ?? kCFBooleanFalse)
            // Chromium counts Enhanced UI enable/disable requests. A matching
            // false removes only our request and preserves requests from other
            // assistive clients; re-sending a previously observed true would
            // add another request instead of restoring the prior state.
            AXUIElementSetAttributeValue(
                values.application,
                "AXEnhancedUserInterface" as CFString,
                kCFBooleanFalse)
        }
        browserAccessibilityLock.unlock()
    }

    private static func accessibilityAttributeValue(
        _ attribute: CFString,
        of element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    /// Fetch geometry and the common AX child collections in one IPC round trip.
    /// Some frameworks populate only one of these collections.
    private static func accessibilityNodeInfo(
        of element: AXUIElement,
        messagingTimeout: Float,
        maxChildren: Int
    ) -> AccessibilityNodeInfo? {
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        let attributes: [CFString] = [
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
            kAXHiddenAttribute as CFString,
            kAXVisibleChildrenAttribute as CFString,
            "AXChildrenInNavigationOrder" as CFString,
            kAXChildrenAttribute as CFString,
            kAXContentsAttribute as CFString,
        ]
        var copiedValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
                element, attributes as CFArray, [], &copiedValues) == .success,
              let values = copiedValues as? [Any], values.count == attributes.count
        else { return nil }

        let rect = accessibilityRect(positionValue: values[0], sizeValue: values[1])
        let isHidden = values[2] as? Bool ?? false
        let visibleChildren = values[3] as? [AXUIElement]
        let childCollections: [[AXUIElement]]
        if let visibleChildren, !visibleChildren.isEmpty {
            childCollections = [visibleChildren]
        } else {
            childCollections = values.dropFirst(4).compactMap { $0 as? [AXUIElement] }
        }

        var children: [AXUIElement] = []
        var childIdentities = Set<CFHashCode>()
        collectionLoop: for elements in childCollections {
            for child in elements.prefix(maxChildren) {
                guard childIdentities.insert(CFHash(child)).inserted else { continue }
                children.append(child)
                if children.count == maxChildren { break collectionLoop }
            }
        }
        return AccessibilityNodeInfo(rect: rect, isHidden: isHidden, children: children)
    }

    private static func accessibilityRect(positionValue: Any, sizeValue: Any) -> NSRect? {
        let positionRef = positionValue as CFTypeRef
        let sizeRef = sizeValue as CFTypeRef
        guard CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              size.width > 2, size.height > 2
        else { return nil }

        return NSRect(origin: position, size: size)
    }

    func drawSnapHighlight() {
        guard state == .idle, snapMode != .off, let rect = hoveredSnapRect, !rect.isEmpty else {
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
