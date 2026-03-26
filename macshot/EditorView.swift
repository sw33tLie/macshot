import Cocoa

/// Standalone editor view — subclass of OverlayView that provides editor-specific behavior.
/// All annotation tools, toolbar drawing, color picker, and undo/redo are inherited.
/// EditorView overrides coordinate handling, background drawing, toolbar positioning,
/// and disables overlay-only features (selection resize, new selection, recording, etc.).
class EditorView: OverlayView {

    // MARK: - Editor mode flag

    override var isEditorMode: Bool { true }

    // MARK: - Zoom

    override var zoomMin: CGFloat { 0.1 }

    // MARK: - Background drawing

    override func drawEditorBackground(context: NSGraphicsContext) {
        // Only recalculate the centering offset at 1x with no pan.
        // When zoomed/panned, the zoom anchor system handles positioning —
        // recalculating the offset would fight with it and cause jumps.
        let isDefaultView = (zoomLevel == 1.0 && zoomAnchorCanvas == .zero && zoomAnchorView == .zero)
        if isDefaultView || editorCanvasOffset == .zero {
            let padLeft:   CGFloat = 8
            let padRight:  CGFloat = 52
            let optionsRowExtra: CGFloat = toolHasOptionsRow ? 36 : 0
            let padBottom: CGFloat = 56 + optionsRowExtra
            let editorTopBarH: CGFloat = 32
            let padTop:    CGFloat = editorTopBarH + 4
            let availW = bounds.width  - padLeft - padRight
            let availH = bounds.height - padBottom - padTop
            let imgW = selectionRect.width
            let imgH = selectionRect.height
            let cx = padLeft + max(0, (availW - imgW) / 2)
            let cy = padBottom + max(0, (availH - imgH) / 2)
            editorCanvasOffset = NSPoint(x: cx, y: cy)
        }

        NSColor(white: 0.15, alpha: 1.0).setFill()
        NSBezierPath(rect: bounds).fill()

        // Skip drawing the raw screenshot when beautify is active —
        // the beautify preview will draw it with gradient/frame instead.
        if !beautifyEnabled {
            context.saveGraphicsState()
            context.cgContext.translateBy(x: editorCanvasOffset.x, y: editorCanvasOffset.y)
            applyZoomTransform(to: context)
            if let image = screenshotImage {
                image.draw(in: selectionRect, from: .zero, operation: .copy, fraction: 1.0)
            }
            context.restoreGraphicsState()
        }
    }

    // MARK: - Selection chrome (disabled in editor)

    override func shouldClipSelectionImage() -> Bool { false }
    override func shouldDrawSelectionBorder() -> Bool { false }
    override func shouldDrawSizeLabel() -> Bool { false }

    // MARK: - Top bar

    override func drawTopChrome() {
        drawEditorTopBar()
    }

    // MARK: - Coordinate transforms

    override func adjustPointForEditor(_ p: NSPoint) -> NSPoint {
        return NSPoint(x: p.x - editorCanvasOffset.x, y: p.y - editorCanvasOffset.y)
    }

    override func applyEditorTransform(to context: NSGraphicsContext) {
        context.cgContext.translateBy(x: editorCanvasOffset.x, y: editorCanvasOffset.y)
    }

    // MARK: - Selection interaction (disabled in editor)

    override func shouldAllowSelectionResize() -> Bool { false }
    override func shouldAllowNewSelection() -> Bool { false }
    override func shouldAllowDetach() -> Bool { false }

    // MARK: - Zoom/pan behavior

    override func canPanAtOneX() -> Bool {
        return selectionRect.height > bounds.height || selectionRect.width > bounds.width
    }

    override func clampZoomAnchorForEditor(r: NSRect, z: CGFloat, ac: NSPoint, av: inout NSPoint) {
        let viewW = bounds.width
        let viewH = bounds.height
        let imgH = r.height * z
        let imgW = r.width * z

        if imgH > viewH {
            let maxAVy = r.minY - (r.minY - ac.y) * z + viewH * 0.1
            let minAVy = r.maxY - (r.maxY - ac.y) * z - viewH * 0.1
            av.y = max(minAVy, min(maxAVy, av.y))
        }
        if imgW > viewW {
            let maxAVx = r.minX - (r.minX - ac.x) * z + viewW * 0.1
            let minAVx = r.maxX - (r.maxX - ac.x) * z - viewW * 0.1
            av.x = max(minAVx, min(maxAVx, av.x))
        }
    }

    // MARK: - Export

    override var captureDrawRect: NSRect { selectionRect }

    // MARK: - Top bar interaction

    override func handleTopChromeClick(at point: NSPoint) -> Bool {
        guard editorTopBarRect.contains(point) else { return false }
        if editorCropBtnRect.contains(point) {
            if currentTool == .crop {
                currentTool = .arrow
            } else {
                currentTool = .crop
            }
            needsDisplay = true
            return true
        }
        if editorFlipHBtnRect.contains(point) {
            flipImageHorizontally()
            return true
        }
        if editorFlipVBtnRect.contains(point) {
            flipImageVertically()
            return true
        }
        if editorResetZoomBtnRect.contains(point) {
            zoomLevel = 1.0
            zoomAnchorCanvas = .zero
            zoomAnchorView = .zero
            editorCanvasOffset = .zero  // force recenter
            needsDisplay = true
            return true
        }
        return true // consumed by top bar, don't fall through
    }

    // MARK: - Cursor

    override func updateCursorForChrome(at point: NSPoint) -> Bool {
        if editorTopBarRect.contains(point) {
            NSCursor.arrow.set()
            return true
        }
        return false
    }

}
