import Cocoa

/// Lightweight helper for showing NSPopovers in both overlay and editor modes.
/// In overlay mode, popovers anchor to an invisible view positioned at the button rect.
/// In editor mode, popovers anchor to the real ToolbarButtonView.
enum PopoverHelper {

    private static var activePopover: NSPopover?
    private static var anchorView: NSView?

    /// Show a popover with the given content view, anchored relative to a rect in the given parent view.
    static func show(_ contentView: NSView, size: NSSize, relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge = .minY) {
        dismiss()

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = size
        popover.animates = true
        popover.appearance = ToolbarLayout.appearance

        let vc = NSViewController()
        vc.view = cursorWrapped(contentView)
        popover.contentViewController = vc
        popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)

        // Ensure popover appears above high-level overlay windows
        if let popoverWindow = popover.contentViewController?.view.window {
            let parentLevel = view.window?.level ?? .normal
            if parentLevel.rawValue > NSWindow.Level.normal.rawValue {
                popoverWindow.level = NSWindow.Level(parentLevel.rawValue + 1)
            }
        }
        activePopover = popover
    }

    /// Show a popover anchored to a specific point in a view (for overlay mode where buttons aren't real views).

    static func showAtPoint(_ contentView: NSView, size: NSSize, at point: NSPoint, in parentView: NSView, preferredEdge: NSRectEdge = .minY) {
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

        // Ensure popover appears above high-level overlay windows
        if let popoverWindow = popover.contentViewController?.view.window {
            let parentLevel = parentView.window?.level ?? .normal
            if parentLevel.rawValue > NSWindow.Level.normal.rawValue {
                popoverWindow.level = NSWindow.Level(parentLevel.rawValue + 1)
            }
        }
        activePopover = popover
    }

    static func dismiss() {
        activePopover?.close()
        activePopover = nil
        anchorView?.removeFromSuperview()
        anchorView = nil
    }

    static var isVisible: Bool { activePopover?.isShown == true }

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
        wrapper.addSubview(contentView)
        contentView.frame.origin = .zero
        return wrapper
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
