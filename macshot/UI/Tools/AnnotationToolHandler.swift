import Cocoa

/// Protocol that OverlayView conforms to, exposing the shared state that tool handlers need.
/// This avoids passing the entire OverlayView to handlers — they only see what they need.
@MainActor
protocol AnnotationCanvas: AnyObject {
    // Current drawing state
    var currentColor: NSColor { get }
    var currentStrokeWidth: CGFloat { get }
    var currentMarkerSize: CGFloat { get }
    var currentLineStyle: LineStyle { get }
    var currentArrowStyle: ArrowStyle { get }
    var currentRectFillStyle: RectFillStyle { get }
    var currentRectCornerRadius: CGFloat { get }
    var currentMeasureInPoints: Bool { get }
    var currentLoupeSize: CGFloat { get }
    var pencilSmoothEnabled: Bool { get }
    var smartMarkerEnabled: Bool { get }

    // Number tool
    var currentNumberSize: CGFloat { get }
    var numberCounter: Int { get set }
    var numberStartAt: Int { get }
    var currentNumberFormat: NumberFormat { get }

    // Stamp tool
    var currentStampImage: NSImage? { get set }
    var currentStampEmoji: String? { get set }

    /// currentColor with tool-appropriate opacity applied.
    func opacityAppliedColor(for tool: AnnotationTool) -> NSColor

    // Annotation storage
    var annotations: [Annotation] { get set }
    var undoStack: [UndoEntry] { get set }
    var redoStack: [UndoEntry] { get set }

    /// The annotation currently being drawn (nil when idle).
    var activeAnnotation: Annotation? { get set }

    // Canvas geometry
    var selectionRect: NSRect { get }
    var captureDrawRect: NSRect { get }

    /// The original screenshot image.
    var screenshotImage: NSImage? { get }

    /// Composited image of screenshot + committed annotations (for pixelate/blur source).
    func compositedImage() -> NSImage?

    // Display
    func setNeedsDisplay()

    // Snap guides (for tools that use alignment snapping)
    var snapGuideX: CGFloat? { get set }
    var snapGuideY: CGFloat? { get set }
    func snapPoint(_ point: NSPoint, excluding: Annotation?) -> NSPoint

    /// Marker cursor preview position (canvas space). Set after marker finish so preview doesn't jump.
    var markerCursorPoint: NSPoint { get set }
}

/// Protocol for extracted annotation tool logic.
/// Each tool handler encapsulates its mouseDown/drag/up behavior and any tool-specific state.
@MainActor
protocol AnnotationToolHandler {
    /// The tool this handler manages.
    var tool: AnnotationTool { get }

    /// Called when the user clicks to start drawing. Point is in canvas space.
    /// Return the new Annotation, or nil if this click doesn't create one (e.g. color sampler).
    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation?

    /// Called on mouseDragged. Update the in-progress annotation.
    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas)

    /// Called on mouseUp. Finalize the annotation (smooth, bake, commit to canvas).
    func finish(canvas: AnnotationCanvas)

    /// The cursor to show when this tool is active. Nil means use default crosshair.
    var cursor: NSCursor? { get }

    /// State-aware cursor — override when the cursor depends on canvas state (e.g. smart marker toggle).
    func cursorForCanvas(_ canvas: AnnotationCanvas) -> NSCursor?
}

/// Default implementations for common patterns.
extension AnnotationToolHandler {
    var cursor: NSCursor? { nil }

    func cursorForCanvas(_ canvas: AnnotationCanvas) -> NSCursor? { cursor }

    /// Commit the active annotation to the canvas annotations array + undo stack.
    func commitAnnotation(_ annotation: Annotation, canvas: AnnotationCanvas) {
        annotation.bakePixelate()
        canvas.annotations.append(annotation)
        canvas.undoStack.append(.added(annotation))
        canvas.redoStack.removeAll()
        canvas.activeAnnotation = nil
        canvas.snapGuideX = nil
        canvas.snapGuideY = nil
        canvas.setNeedsDisplay()
    }
}

/// Snap a point to the nearest 45° angle from a reference point.
func snap45(_ point: NSPoint, from ref: NSPoint) -> NSPoint {
    let dx = point.x - ref.x
    let dy = point.y - ref.y
    let angle = atan2(dy, dx)
    let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
    let distance = hypot(dx, dy)
    return NSPoint(
        x: ref.x + distance * cos(snapped),
        y: ref.y + distance * sin(snapped)
    )
}

/// Shift-constrain a point to a square relative to a reference (equal width/height).
func snapSquare(_ point: NSPoint, from ref: NSPoint) -> NSPoint {
    let dx = point.x - ref.x
    let dy = point.y - ref.y
    let side = max(abs(dx), abs(dy))
    return NSPoint(
        x: ref.x + side * (dx >= 0 ? 1 : -1),
        y: ref.y + side * (dy >= 0 ? 1 : -1)
    )
}
