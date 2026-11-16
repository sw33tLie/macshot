import Cocoa

/// Standalone editor view — subclass of OverlayView for the editor window.
/// When inside an NSScrollView, coordinate transforms are identity (view coords = canvas coords).
/// NSScrollView handles zoom, pan, centering, momentum — no manual math needed.
class EditorView: OverlayView {

    override var isEditorMode: Bool { true }
    override var isInsideScrollView: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // Ensure the view redraws fully on magnification changes instead of
        // scaling the stale layer contents (which causes blurry regions).
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    // MARK: - Background drawing (simple — NSScrollView handles centering/zoom)

    override func drawEditorBackground(context: NSGraphicsContext) {
        // NSScrollView.backgroundColor handles the dark background.
        // CenteringClipView handles centering. Magnification handles zoom.
        guard !beautifyEnabled else { return }

        // Fast path: if we have a cached composite (screenshot + all committed annotations)
        // and nothing is actively being drawn, draw the single cached image.
        // This avoids re-rendering the screenshot + iterating all annotations every frame.
        if !isActivelyDrawing, let cached = cachedCompositedImage {
            cached.draw(in: selectionRect, from: .zero, operation: .copy, fraction: 1.0)
            drewFromCompositeCache = true
            return
        }

        drewFromCompositeCache = false
        if let image = screenshotImage {
            image.draw(in: selectionRect, from: .zero, operation: .copy, fraction: 1.0)
        }
    }

    /// Set during drawEditorBackground to signal the base draw() to skip annotation loops.
    var drewFromCompositeCache: Bool = false

    // MARK: - Selection chrome (disabled in editor)

    override func shouldClipSelectionImage() -> Bool { false }
    override func shouldDrawSelectionBorder() -> Bool { false }
    override func shouldShowResolutionBox() -> Bool { false }

    // MARK: - Coordinate transforms (identity — scroll view handles everything)

    override func adjustPointForEditor(_ p: NSPoint) -> NSPoint { p }
    override func applyEditorTransform(to context: NSGraphicsContext) {}

    // MARK: - Cursor (arrow outside image, tool cursor inside)

    override func resetCursorRects() {
        // Arrow cursor for the full document view (image plus margin);
        // updateCursorForPoint overrides it over the image and annotation controls.
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // The base also clears drawing/stamp previews once the pointer leaves
        // the image, so it always runs; the empty margin keeps a plain arrow
        // unless an annotation's controls or body are under the pointer.
        super.mouseMoved(with: event)
        if !selectionRect.contains(point) && !pointHitsAnnotationInteraction(point) {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Selection interaction (disabled in editor)

    override func shouldAllowSelectionResize() -> Bool { false }
    override func shouldAllowNewSelection() -> Bool { false }
    override func shouldAllowDetach() -> Bool { false }

    // MARK: - Zoom (handled by NSScrollView magnification, not OverlayView)

    // MARK: - Export

    override var captureDrawRect: NSRect { selectionRect }

    // Top bar is handled by EditorTopBarView (real NSView in the container)
}
