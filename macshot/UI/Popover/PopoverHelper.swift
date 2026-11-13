import Cocoa

/// Lightweight helper for showing NSPopovers in both overlay and editor modes.
/// In overlay mode, popovers anchor to an invisible view positioned at the button rect.
/// In editor mode, popovers anchor to the real ToolbarButtonView.
enum PopoverHelper {

    private static var activePopover: NSPopover?
    private static var anchorView: NSView?
    /// Created on the first popover so an open popover can follow a later HUD appearance change.
    private static let hudColorObserver: NSObjectProtocol = {
        NotificationCenter.default.addObserver(
            forName: .toolbarColorsDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                refreshAppearanceIfNeeded()
            }
        }
    }()
    private static var localMouseDownMonitor: Any?
    private static var globalMouseDownMonitor: Any?

    /// Show a popover with the given content view, anchored relative to a rect in the given parent view.
    static func show(_ contentView: NSView, size: NSSize, relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge = .minY) {
        _ = hudColorObserver
        dismiss()

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = size
        popover.animates = true
        popover.appearance = ToolbarLayout.appearance

        let vc = NSViewController()
        vc.view = cursorWrapped(contentView)
        popover.contentViewController = vc
        popover.delegate = AnchorCleanupDelegate.shared
        popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
        configureShownPopover(popover, parentWindow: view.window)
        activePopover = popover
        installOutsideClickMonitors()
    }

    /// Show a popover anchored to a specific point in a view (for overlay mode where buttons aren't real views).

    static func showAtPoint(_ contentView: NSView, size: NSSize, at point: NSPoint, in parentView: NSView, preferredEdge: NSRectEdge = .minY) {
        _ = hudColorObserver
        dismiss()

        // Create a tiny invisible anchor view at the point
        let anchor = NSView(frame: NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2))
        parentView.addSubview(anchor)
        anchorView = anchor

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = size
        popover.animates = true
        popover.appearance = ToolbarLayout.appearance

        let vc = NSViewController()
        vc.view = cursorWrapped(contentView)
        popover.contentViewController = vc
        popover.delegate = AnchorCleanupDelegate.shared
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
        configureShownPopover(popover, parentWindow: parentView.window)
        activePopover = popover
        installOutsideClickMonitors()
    }

    /// Time the most recent popover was dismissed — used to implement
    /// click-the-anchor-to-toggle-closed (the outside click auto-dismisses a
    /// semitransient popover before the button handler runs, so the handler
    /// checks "was one just dismissed?" instead of "is one visible?").
    private(set) static var lastDismissedAt: Date = .distantPast

    static func dismiss() {
        if activePopover?.isShown == true { lastDismissedAt = Date() }
        activePopover?.close()
        activePopover = nil
        removeOutsideClickMonitors()
        anchorView?.removeFromSuperview()
        anchorView = nil
    }

    /// True if a popover was dismissed within the last `seconds` (default 0.25s).
    static func wasRecentlyDismissed(within seconds: TimeInterval = 0.25) -> Bool {
        Date().timeIntervalSince(lastDismissedAt) < seconds
    }

    /// Toggle helper for anchor buttons that open a popover. Clicking the same
    /// button that opened a popover should CLOSE it (and not reopen).
    ///
    /// The catch: a semitransient popover's outside-click monitor fires on the
    /// same mouseDown and dismisses it BEFORE the button's action runs, so by the
    /// time the handler checks `isVisible` it's already false and the handler
    /// would reopen. So we also treat "a popover was just dismissed" as
    /// already-handled. Returns true if the click closed an open/just-closed
    /// popover — callers should `return` early when it does.
    static func toggleClosedIfOpen() -> Bool {
        if isVisible || wasRecentlyDismissed() {
            dismiss()
            return true
        }
        return false
    }

    static var isVisible: Bool { activePopover?.isShown == true }

    /// Repaint an open popover after the HUD appearance changes.
    static func refreshAppearanceIfNeeded() {
        guard let popover = activePopover, popover.isShown,
              let content = popover.contentViewController?.view else { return }
        let appearance = ToolbarLayout.appearance
        popover.appearance = appearance
        content.appearance = appearance
        markNeedsDisplay(content)
    }

    private static func markNeedsDisplay(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews {
            markNeedsDisplay(subview)
        }
    }

    static var isMouseInsidePopover: Bool {
        guard let popover = activePopover, popover.isShown,
              let popoverWindow = popover.contentViewController?.view.window else { return false }
        return popoverWindow.frame.contains(NSEvent.mouseLocation)
    }

    /// Wrap content view so the popover always shows an arrow cursor regardless of active tool.
    /// Sets appearance to match toolbar background brightness.
    private static func cursorWrapped(_ contentView: NSView) -> NSView {
        let wrapper = ArrowCursorView(frame: contentView.frame)
        wrapper.appearance = ToolbarLayout.appearance
        contentView.frame.origin = .zero
        wrapper.addSubview(contentView)
        return wrapper
    }

    /// Finish window-level setup after AppKit has created the private popover
    /// window. Overlay popovers may be opened from non-key Liquid Glass chrome
    /// panels while macshot itself remains inactive; without an explicit key
    /// handoff, AppKit leaves the popover visible but the first click only
    /// focuses it. Making the popover window key preserves the non-activating
    /// overlay/chrome topology and keeps semitransient dismissal unchanged.
    private static func configureShownPopover(_ popover: NSPopover, parentWindow: NSWindow?) {
        func configure() {
            guard popover.isShown,
                  let popoverWindow = popover.contentViewController?.view.window else { return }

            let parentLevel = parentWindow?.level ?? .normal
            if parentLevel.rawValue > NSWindow.Level.normal.rawValue {
                popoverWindow.level = NSWindow.Level(parentLevel.rawValue + 1)
            }

            if let parentWindow {
                popoverWindow.collectionBehavior.formUnion(
                    parentWindow.collectionBehavior.intersection([.canJoinAllSpaces, .fullScreenAuxiliary]))
            }

            popoverWindow.makeKey()
        }

        configure()
        DispatchQueue.main.async {
            configure()
        }
    }

    private static func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            if shouldDismiss(forMouseDownAt: NSEvent.mouseLocation) {
                dismiss()
            }
            return event
        }
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in
            DispatchQueue.main.async {
                if shouldDismiss(forMouseDownAt: NSEvent.mouseLocation) {
                    dismiss()
                }
            }
        }
    }

    private static func removeOutsideClickMonitors() {
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
    }

    private static func shouldDismiss(forMouseDownAt screenPoint: NSPoint) -> Bool {
        guard let popover = activePopover, popover.isShown else { return false }
        guard let popoverWindow = popover.contentViewController?.view.window else { return true }
        return !popoverWindow.frame.contains(screenPoint)
    }
}

/// NSView that forces the arrow cursor over its entire bounds.
private class ArrowCursorView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

// Cleans up the invisible anchor view when the popover closes
private class AnchorCleanupDelegate: NSObject, NSPopoverDelegate {
    static let shared = AnchorCleanupDelegate()
    func popoverDidClose(_ notification: Notification) {
        PopoverHelper.dismiss()
    }
}
