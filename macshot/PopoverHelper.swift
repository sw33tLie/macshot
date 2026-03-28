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
        popover.behavior = .transient
        popover.contentSize = size
        popover.animates = true

        let vc = NSViewController()
        vc.view = contentView
        popover.contentViewController = vc
        popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
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
        popover.behavior = .transient
        popover.contentSize = size
        popover.animates = true

        let vc = NSViewController()
        vc.view = contentView
        popover.contentViewController = vc
        popover.delegate = AnchorCleanupDelegate.shared
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
        activePopover = popover
    }

    static func dismiss() {
        activePopover?.close()
        activePopover = nil
        anchorView?.removeFromSuperview()
        anchorView = nil
    }

    static var isVisible: Bool { activePopover?.isShown == true }
}

// Cleans up the invisible anchor view when the popover closes
private class AnchorCleanupDelegate: NSObject, NSPopoverDelegate {
    static let shared = AnchorCleanupDelegate()
    func popoverDidClose(_ notification: Notification) {
        PopoverHelper.dismiss()
    }
}
