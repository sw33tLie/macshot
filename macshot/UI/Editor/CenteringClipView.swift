import Cocoa

/// NSClipView subclass that centers the document view when it is smaller than the clip view.
/// Also forwards scroll/magnify/mouse events to the document view when the cursor is over the
/// gray background area (outside the document frame), so zoom and drawing work at all zoom levels.
class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        guard let documentView = documentView else {
            return super.constrainBoundsRect(proposedBounds)
        }
        let docFrame = documentView.frame
        var rect = super.constrainBoundsRect(proposedBounds)

        if docFrame.width < rect.width {
            rect.origin.x = (docFrame.width - rect.width) / 2
        }
        if docFrame.height < rect.height {
            rect.origin.y = (docFrame.height - rect.height) / 2
        }
        return rect
    }

    // Route all events to the document view (EditorView) even when cursor is
    // outside the document frame (gray background area when zoomed out).
    // This is needed because NSScrollView magnification shrinks the document view's
    // frame, so AppKit's default hit testing won't route events to it.

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        // If hit test returned the clip view itself (gray background area when zoomed out),
        // route to document view — but only if the point is over the actual image area
        // (not the toolbar/top bar chrome regions outside the scroll view's visible area).
        if result === self, let doc = documentView {
            // Convert point to document view coordinates and check if it's within the image
            let docPoint = doc.convert(point, from: self)
            if doc.bounds.contains(docPoint) {
                return doc
            }
        }
        return result
    }

    override func scrollWheel(with event: NSEvent) {
        let isTrackpad = event.phase != [] || event.momentumPhase != []

        if !isTrackpad {
            // Mouse wheel: scroll vertically if there's scrollable content, otherwise do nothing
            guard let sv = enclosingScrollView else { return }
            let docFrame = documentView?.frame ?? .zero
            let canScrollV = docFrame.height > bounds.height + 1
            if canScrollV {
                let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1.0 : 10.0)
                var newOrigin = bounds.origin
                newOrigin.y -= delta
                scroll(newOrigin)
            }
            return
        }

        // Trackpad: check if document exceeds clip bounds before forwarding
        if let sv = enclosingScrollView {
            let docFrame = documentView?.frame ?? .zero
            let canScrollH = docFrame.width > bounds.width + 1
            let canScrollV = docFrame.height > bounds.height + 1
            if !canScrollH && !canScrollV {
                return  // swallow — no scrollable content, no bounce
            }
            sv.horizontalScrollElasticity = canScrollH ? .allowed : .none
            sv.verticalScrollElasticity = canScrollV ? .allowed : .none
        }
        super.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        if let editorView = documentView as? OverlayView, editorView.isInsideScrollView {
            editorView.magnify(with: event)
            return
        }
        super.magnify(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
