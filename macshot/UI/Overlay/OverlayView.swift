import AVFoundation
import Cocoa
import UniformTypeIdentifiers

@MainActor
protocol OverlayViewDelegate: AnyObject {
    func overlayViewDidFinishSelection(_ rect: NSRect)
    func overlayViewSelectionDidChange(_ rect: NSRect)
    func overlayViewDidCancel()
    func overlayViewDidConfirm()
    func overlayViewDidRequestSave()
    func overlayViewDidRequestPin()
    func overlayViewDidRequestOCR()
    func overlayViewDidRequestQuickSave()
    func overlayViewDidRequestUpload()
    func overlayViewDidRequestShare(anchorView: NSView?)
    @available(macOS 14.0, *)
    func overlayViewDidRequestRemoveBackground()
    func overlayViewDidRequestEnterRecordingMode()
    func overlayViewDidRequestStartRecording(rect: NSRect)
    func overlayViewDidRequestStopRecording()
    func overlayViewDidRequestDetach()
    func overlayViewDidRequestScrollCapture(rect: NSRect)
    func overlayViewDidRequestStopScrollCapture()
    func overlayViewDidBeginSelection()
}

/// An entry in the undo/redo history.
enum UndoEntry {
    case added(Annotation)  // annotation was added; undo removes it
    case deleted(Annotation, Int)  // annotation was deleted at index; undo re-inserts it
    /// Image transform (crop/flip): stores the previous image and annotation offsets to restore.
    case imageTransform(previousImage: NSImage, annotationOffsets: [(Annotation, CGFloat, CGFloat)])

    var annotation: Annotation {
        switch self {
        case .added(let a), .deleted(let a, _): return a
        case .imageTransform:
            return Annotation(
                tool: .measure, startPoint: .zero, endPoint: .zero, color: .clear, strokeWidth: 0)  // dummy
        }
    }
}

/// Snapshot of the mutable editor state.
struct OverlayEditorState {
    var screenshotImage: NSImage?
    var selectionRect: NSRect
    var annotations: [Annotation]
    var undoStack: [UndoEntry]
    var redoStack: [UndoEntry]
    var currentTool: AnnotationTool
    var currentColor: NSColor
    var currentStrokeWidth: CGFloat
    var currentMarkerSize: CGFloat
    var currentNumberSize: CGFloat
    var numberCounter: Int
    var beautifyEnabled: Bool
    var beautifyStyleIndex: Int
}

class OverlayView: NSView {

    // MARK: - Properties

    weak var overlayDelegate: OverlayViewDelegate?

    /// When true, hides overlay-only toolbar buttons (record, delay, cancel, move, scroll capture).
    /// Override point for subclasses. EditorView returns true.
    var isEditorMode: Bool { false }
    /// When true, NSScrollView handles zoom/pan/centering. Coordinate transforms become identity.
    var isInsideScrollView: Bool { false }
    /// When in scroll view mode, toolbar strips are added to this view (window content) instead of self.
    weak var chromeParentView: NSView?

    var screenshotImage: NSImage? {
        didSet { needsDisplay = true }
    }

    // State
    enum State {
        case idle
        case selecting
        case selected
    }

    private(set) var state: State = .idle

    // Zoom
    var zoomLevel: CGFloat = 1.0
    // The canvas point that stays pinned to zoomAnchorView on screen.
    // Both default to selection center; updated on each scroll/pinch to be the cursor position.
    var zoomAnchorCanvas: NSPoint = .zero
    var zoomAnchorView: NSPoint = .zero
    private var zoomFadingOut: Bool = false
    private var zoomLabelOpacity: CGFloat = 0.0
    private var zoomFadeTimer: Timer?
    var zoomMin: CGFloat { 1.0 }
    private let zoomMax: CGFloat = 8.0

    // Selection
    private(set) var selectionRect: NSRect = .zero
    /// Selection rect from another overlay (in this view's local coords), drawn during cross-screen drag.
    var remoteSelectionRect: NSRect = .zero
    private var selectionStart: NSPoint = .zero
    private var isDraggingSelection: Bool = false
    private var isResizingSelection: Bool = false
    private var resizeHandle: ResizeHandle = .none
    private var dragOffset: NSPoint = .zero
    private var lastDragPoint: NSPoint?  // for shift constraint on flagsChanged
    private var spaceRepositioning: Bool = false  // Space held during drag to reposition
    private var spaceRepositionLast: NSPoint = .zero  // last mouse position when space reposition started

    // Annotations
    var annotations: [Annotation] = [] {
        didSet {
            cachedCompositedImage = nil
            // Update move button enabled state when annotations change
            if showToolbars { rebuildToolbarLayout() }
        }
    }
    var undoStack: [UndoEntry] = []
    var redoStack: [UndoEntry] = []
    private var currentAnnotation: Annotation?

    // MARK: - Tool handlers
    private lazy var toolHandlers: [AnnotationTool: AnnotationToolHandler] = {
        let handlers: [AnnotationToolHandler] = [
            PencilToolHandler(),
            MarkerToolHandler(),
            LineToolHandler(),
            ArrowToolHandler(),
            RectangleToolHandler(),
            FilledRectangleToolHandler(),
            EllipseToolHandler(),
            PixelateToolHandler(),
            BlurToolHandler(),
            LoupeToolHandler(),
            MeasureToolHandler(),
            NumberToolHandler(),
            StampToolHandler(),
        ]
        return Dictionary(uniqueKeysWithValues: handlers.map { ($0.tool, $0) })
    }()
    /// Last tool the user explicitly picked — shared across overlay instances within one app session.
    private static var lastUsedTool: AnnotationTool = .arrow
    var currentTool: AnnotationTool = OverlayView.lastUsedTool {
        didSet {
            // Persist drawing tool choices; skip transient/mode tools
            if currentTool != .select && currentTool != .loupe {
                OverlayView.lastUsedTool = currentTool
            }
        }
    }
    var currentColor: NSColor = .systemRed
    /// currentColor with opacity applied — used for all tools except marker, loupe, measure, pixelate, blur
    private var annotationColor: NSColor { currentColor.withAlphaComponent(currentColorOpacity) }
    var currentStrokeWidth: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "currentStrokeWidth") as? Double
        return saved != nil ? CGFloat(saved!) : 3.0
    }()
    var currentNumberSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "numberStrokeWidth") as? Double
        return saved != nil ? CGFloat(saved!) : 3.0
    }()
    var currentMarkerSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "markerStrokeWidth") as? Double
        return saved != nil ? CGFloat(saved!) : 3.0
    }()
    var numberCounter: Int = 0
    var numberStartAt: Int = {
        UserDefaults.standard.object(forKey: "numberStartAt") as? Int ?? 1
    }()
    var currentNumberFormat: NumberFormat = {
        NumberFormat(rawValue: UserDefaults.standard.integer(forKey: "numberFormat")) ?? .decimal
    }()

    // Select/move mode
    private var selectedAnnotation: Annotation?
    private var isDraggingAnnotation: Bool = false
    private var annotationDragStart: NSPoint = .zero
    /// Annotation under the cursor when using a non-select drawing tool — enables on-the-fly move without switching tools.
    private var hoveredAnnotation: Annotation?
    /// Delays clearing hoveredAnnotation so the cursor can travel to handles/buttons that sit outside the hit area.
    private var hoveredAnnotationClearTimer: Timer?

    // Text editing — state managed by TextEditingController
    let textEditor = TextEditingController()
    var textEditView: NSTextView? { textEditor.textView }

    // Text box resize state (stays here — tied to mouse drag handling)
    private var isResizingTextBox: Bool = false
    private var textBoxResizeHandle: ResizeHandle = .none
    private var textBoxResizeStart: NSPoint = .zero
    private var textBoxOrigFrame: NSRect = .zero

    // Toolbars (drawn inline)
    var bottomButtons: [ToolbarButton] = []
    var rightButtons: [ToolbarButton] = []
    var bottomBarRect: NSRect = .zero
    var rightBarRect: NSRect = .zero
    var showToolbars: Bool = false {
        didSet {
            if showToolbars && !oldValue {
                rebuildToolbarLayout()
            } else if !showToolbars && oldValue {
                bottomStripView?.isHidden = true
                rightStripView?.isHidden = true
                toolOptionsRowView?.isHidden = true
            }
        }
    }
    private var bottomStripView: ToolbarStripView?
    private var rightStripView: ToolbarStripView?
    private var toolOptionsRowView: ToolOptionsRowView?

    // Size label
    private var sizeLabelRect: NSRect = .zero
    private var sizeInputField: NSTextField?

    // Zoom label
    private var zoomLabelRect: NSRect = .zero
    private var zoomInputField: NSTextField?

    // Beautify
    var beautifyEnabled: Bool = UserDefaults.standard.bool(forKey: "beautifyEnabled")
    var beautifyStyleIndex: Int = UserDefaults.standard.integer(
        forKey: "beautifyStyleIndex")
    var beautifyMode: BeautifyMode =
        BeautifyMode(rawValue: UserDefaults.standard.integer(forKey: "beautifyMode")) ?? .window
    var beautifyPadding: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "beautifyPadding") as? Double
        return v != nil ? CGFloat(v!) : 48
    }()
    var beautifyCornerRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "beautifyCornerRadius") as? Double
        return v != nil ? CGFloat(v!) : 10
    }()
    var beautifyShadowRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "beautifyShadowRadius") as? Double
        return v != nil ? CGFloat(v!) : 20
    }()
    private(set) var beautifyBgRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "beautifyBgRadius") as? Double
        return v != nil ? CGFloat(v!) : 8
    }()

    var beautifyConfig: BeautifyConfig {
        BeautifyConfig(
            mode: beautifyMode,
            styleIndex: beautifyStyleIndex,
            padding: beautifyPadding,
            cornerRadius: beautifyCornerRadius,
            shadowRadius: beautifyShadowRadius,
            bgRadius: 0
        )
    }

    var showBeautifyInOptionsRow: Bool = false

    // Color picker target
    enum ColorPickerTarget { case drawColor, textBg, textOutline }
    private var colorPickerTarget: ColorPickerTarget = .drawColor

    // Beautify toolbar animation
    private var beautifyToolbarAnimProgress: CGFloat = 1.0  // 0..1, 1 = fully settled
    private var beautifyToolbarAnimTimer: Timer?
    private var beautifyToolbarAnimTarget: Bool = false  // target beautify state

    // Tool options row (second row below bottom bar)
    var currentMeasureInPoints: Bool = UserDefaults.standard.bool(forKey: "measureInPoints")
    var currentLineStyle: LineStyle =
        LineStyle(rawValue: UserDefaults.standard.integer(forKey: "currentLineStyle")) ?? .solid
    var currentArrowStyle: ArrowStyle =
        ArrowStyle(rawValue: UserDefaults.standard.integer(forKey: "currentArrowStyle")) ?? .single
    var currentRectFillStyle: RectFillStyle =
        RectFillStyle(rawValue: UserDefaults.standard.integer(forKey: "currentRectFillStyle"))
        ?? .stroke
    var currentStampImage: NSImage?  // selected emoji/image for stamp tool
    var currentStampEmoji: String?  // emoji string for highlight tracking
    private var stampPreviewPoint: NSPoint?  // mouse position for stamp cursor preview
    var currentRectCornerRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "currentRectCornerRadius") as? Double
        return v != nil ? CGFloat(v!) : 0
    }()

    // Stroke width picker popover

    var pencilSmoothEnabled: Bool =
        UserDefaults.standard.object(forKey: "pencilSmoothEnabled") as? Bool ?? true
    private var roundedRectEnabled: Bool =
        UserDefaults.standard.object(forKey: "roundedRectEnabled") as? Bool ?? false

    var currentLoupeSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "loupeSize") as? Double
        return saved != nil ? CGFloat(saved!) : 120.0
    }()
    private var loupeCursorPoint: NSPoint = .zero
    var markerCursorPoint: NSPoint = .zero
    private var colorSamplerPoint: NSPoint = .zero  // canvas space, for color picker tool
    private var colorSamplerBitmap: NSBitmapImageRep?  // cached bitmap for fast pixel sampling
    // Auto-measure preview (live while holding 1 or 2 key)
    private var autoMeasurePreview: Annotation?  // temporary, drawn but not in annotations[]
    private var autoMeasureVertical: Bool = true  // true = "1" key, false = "2" key
    // Snap/alignment guides
    var snapGuideX: CGFloat? = nil  // vertical guide line X
    var snapGuideY: CGFloat? = nil  // horizontal guide line Y
    private let snapThreshold: CGFloat = 5
    private var snapGuidesEnabled: Bool {
        UserDefaults.standard.object(forKey: "snapGuidesEnabled") as? Bool ?? true
    }

    var cachedCompositedImage: NSImage? = nil  // invalidated when annotations change

    var isTranslating: Bool = false
    var translateEnabled: Bool = false

    // Crop tool state
    private var isCropDragging: Bool = false
    private var cropDragStart: NSPoint = .zero
    private var cropDragRect: NSRect = .zero

    // Annotation selection/resize controls
    private var isResizingAnnotation: Bool = false
    private var annotationResizeHandle: ResizeHandle = .none
    private var annotationResizeAnchorIndex: Int = -1  // index into anchorPoints for multi-anchor drag
    private var isRotatingAnnotation: Bool = false
    private var rotationStartAngle: CGFloat = 0
    private var rotationOriginal: CGFloat = 0
    private var annotationRotateHandleRect: NSRect = .zero
    private var annotationResizeOrigStart: NSPoint = .zero
    private var annotationResizeOrigEnd: NSPoint = .zero
    private var annotationResizeOrigTextOrigin: NSPoint = .zero
    private var annotationResizeOrigControlPoint: NSPoint = .zero
    private var annotationResizeMouseStart: NSPoint = .zero
    private var annotationDeleteButtonRect: NSRect = .zero
    private var annotationEditButtonRect: NSRect = .zero
    private var annotationResizeHandleRects: [(ResizeHandle, NSRect)] = []

    // Overlay error message
    private var overlayErrorMessage: String? = nil

    // Instant tooltip for hovered toolbar button
    private var hoveredTooltip: String?
    private var hoveredTooltipButtonView: ToolbarButtonView?
    private var overlayErrorTimer: Timer? = nil

    // Barcode / QR detection
    private let barcodeDetector = BarcodeDetector()

    // Recording state
    var isRecording: Bool = false {  // true when recording toolbar is shown (mode entered)
        didSet {
            if isRecording {
                if recordingHUDPanel == nil {
                    let panel = RecordingHUDPanel()
                    panel.update(elapsedSeconds: recordingElapsedSeconds)
                    if let win = window {
                        panel.position(relativeTo: selectionRect, in: win)
                    }
                    panel.orderFront(nil)
                    recordingHUDPanel = panel
                }
                showRecordingToolbar()
            } else {
                recordingHUDPanel?.close()
                recordingHUDPanel = nil
                recordingToolbarPanel?.close()
                recordingToolbarPanel = nil
            }
        }
    }
    var isCapturingVideo: Bool = false  // true when SCStream is actually capturing
    var recordingElapsedSeconds: Int = 0 {
        didSet { updateRecordingHUD() }
    }
    private var recordingHUDPanel: RecordingHUDPanel?
    private var recordingToolbarPanel: RecordingToolbarPanel?
    var autoEnterRecordingMode: Bool = false  // set by "Record Screen" menu — enters recording mode after selection
    var autoOCRMode: Bool = false  // set by "Capture OCR" menu — triggers OCR immediately after selection
    var autoQuickSaveMode: Bool = false  // set by "Quick Capture" menu — quick-saves immediately after selection
    // Recording overlay features
    var mouseHighlightPoints: [(point: NSPoint, time: Date)] = []
    var globalMouseMonitor: Any?

    // Scroll capture state
    var isScrollCapturing: Bool = false
    var scrollCaptureStripCount: Int = 0
    var scrollCapturePixelSize: CGSize = .zero
    private var scrollCaptureHUDPanel: ScrollCaptureHUDPanel?
    private var annotationModeEverUsed: Bool = false  // once true, never show frozen screenshot again
    /// Activate the app visible under the selection rect so the user doesn't need a warmup click.
    private func activateAppUnderSelection() {
        guard selectionRect.width > 0, let win = window else { return }
        // Convert selection center to global screen coords
        let centerLocal = NSPoint(x: selectionRect.midX, y: selectionRect.midY)
        let centerScreen = win.convertToScreen(NSRect(origin: centerLocal, size: .zero)).origin

        guard
            let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]
        else { return }

        let overlayWindowNumber = win.windowNumber
        let screenH = NSScreen.screens.first?.frame.height ?? 0

        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                let winNum = info[kCGWindowNumber as String] as? Int,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                winNum != overlayWindowNumber
            else { continue }

            let cgX = boundsDict["X"] ?? 0
            let cgY = boundsDict["Y"] ?? 0
            let cgW = boundsDict["Width"] ?? 0
            let cgH = boundsDict["Height"] ?? 0
            let appKitRect = NSRect(x: cgX, y: screenH - cgY - cgH, width: cgW, height: cgH)

            if appKitRect.contains(centerScreen) {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [])
                return
            }
        }
    }

    /// Call once when recording begins to activate pass-through without needing a didSet transition.
    func startPassThroughMode() {
        annotationModeEverUsed = true  // suppress frozen screenshot from the start
        activateAppUnderSelection()
        window?.ignoresMouseEvents = true

        needsDisplay = true
    }

    func startScrollCaptureMode() {
        isScrollCapturing = true
        scrollCaptureStripCount = 0
        scrollCapturePixelSize = .zero

        activateAppUnderSelection()
        window?.ignoresMouseEvents = true

        // Show real NSPanel-based HUD (receives clicks independently of overlay window)
        let panel = ScrollCaptureHUDPanel()
        panel.hudView.onStop = { [weak self] in
            self?.overlayDelegate?.overlayViewDidRequestStopScrollCapture()
        }
        panel.hudView.update(
            stripCount: 0, pixelSize: .zero,
            backingScale: window?.backingScaleFactor ?? 2)
        if let win = window {
            panel.position(relativeTo: selectionRect, in: win)
        }
        panel.orderFront(nil)
        scrollCaptureHUDPanel = panel

        needsDisplay = true
    }

    func stopScrollCaptureMode() {
        isScrollCapturing = false
        scrollCaptureStripCount = 0
        scrollCapturePixelSize = .zero

        scrollCaptureHUDPanel?.close()
        scrollCaptureHUDPanel = nil
        window?.ignoresMouseEvents = false

        needsDisplay = true
    }

    /// Update the scroll capture HUD with new strip count and pixel size.
    private func updateRecordingHUD() {
        recordingHUDPanel?.update(elapsedSeconds: recordingElapsedSeconds)
        if let win = window {
            recordingHUDPanel?.position(relativeTo: selectionRect, in: win)
        }
    }

    private func showRecordingToolbar() {
        let panel: RecordingToolbarPanel
        if let existing = recordingToolbarPanel {
            panel = existing
        } else {
            panel = RecordingToolbarPanel()
            panel.onClick = { [weak self] action in
                self?.handleToolbarAction(action)
            }
            recordingToolbarPanel = panel
        }
        let buttons = ToolbarLayout.rightButtons(
            beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex,
            hasAnnotations: false, translateEnabled: translateEnabled,
            isRecording: true, isCapturingVideo: isCapturingVideo,
            isAnnotating: isAnnotating, isEditorMode: false)
        panel.updateButtons(buttons)
        if let win = window {
            panel.position(relativeTo: selectionRect, in: win)
        }
        panel.orderFront(nil)
    }

    func updateScrollCaptureHUD() {
        scrollCaptureHUDPanel?.hudView.update(
            stripCount: scrollCaptureStripCount,
            pixelSize: scrollCapturePixelSize,
            backingScale: window?.backingScaleFactor ?? 2)
        if let win = window {
            scrollCaptureHUDPanel?.position(relativeTo: selectionRect, in: win)
        }
    }

    var onAnnotationModeChanged: ((Bool) -> Void)?

    var isAnnotating: Bool = false {
        didSet {
            guard isAnnotating != oldValue else { return }
            if isAnnotating { annotationModeEverUsed = true }
            window?.ignoresMouseEvents = !isAnnotating

            if isAnnotating {
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                window?.orderFrontRegardless()
                // Switching to pass-through — clear any hover state so annotations
                // don't show edit controls while the cursor roams freely underneath.
                hoveredAnnotationClearTimer?.invalidate()
                hoveredAnnotationClearTimer = nil
                hoveredAnnotation = nil
                selectedAnnotation = nil
            }
            onAnnotationModeChanged?(isAnnotating)
            needsDisplay = true
        }
    }

    // Window snapping
    var windowSnapEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "windowSnapEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "windowSnapEnabled") }
    }
    var hoveredWindowRect: NSRect? = nil
    private var windowSnapQueryInFlight: Bool = false
    private var customColors: [NSColor?] = Array(repeating: nil, count: 7)
    private var selectedColorSlot: Int = 0  // which custom slot is selected for saving colors
    private static var lastUsedOpacity: CGFloat = 1.0
    private var currentColorOpacity: CGFloat = OverlayView.lastUsedOpacity

    // Radial color wheel (right-click in drawing mode)
    private let colorWheel = ColorWheelRenderer()

    // Handle
    private let handleSize: CGFloat = 10

    enum ResizeHandle {
        case none
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
        case move
    }

    // MARK: - Setup

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Stamp cursor preview — track in view coords (same as annotations)
        if currentTool == .stamp && currentStampImage != nil && state == .selected && !isRecording
            && !showBeautifyInOptionsRow
        {
            let canvasStampPt = viewToCanvas(point)
            if stampPreviewPoint == nil
                || hypot(
                    canvasStampPt.x - (stampPreviewPoint?.x ?? 0),
                    canvasStampPt.y - (stampPreviewPoint?.y ?? 0)) > 0.5
            {
                stampPreviewPoint = canvasStampPt
                needsDisplay = true
            }
        } else if stampPreviewPoint != nil {
            stampPreviewPoint = nil
            needsDisplay = true
        }

        // Update cursor on every mouse move
        updateCursorForPoint(point)

        // Window snap: highlight hovered window in idle state.
        // CGWindowListCopyWindowInfo is expensive — run it on a background thread,
        // skipping new queries while one is already in flight.
        if state == .idle && windowSnapEnabled && !windowSnapQueryInFlight {
            guard
                let screenPoint = window.map({
                    NSPoint(x: $0.frame.origin.x + point.x, y: $0.frame.origin.y + point.y)
                }),
                let viewWindow = window
            else { return }
            let overlayWindowNumber = viewWindow.windowNumber
            let windowOrigin = viewWindow.frame.origin
            let viewBounds = bounds
            let screenH = NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
            windowSnapQueryInFlight = true
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                let newRect = Self.windowRectOnBackground(
                    screenPoint: screenPoint,
                    overlayWindowNumber: overlayWindowNumber,
                    windowOrigin: windowOrigin,
                    viewBounds: viewBounds,
                    screenH: screenH
                )
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.windowSnapQueryInFlight = false
                    if newRect != self.hoveredWindowRect {
                        self.hoveredWindowRect = newRect
                        self.needsDisplay = true
                    }
                }
            }
        }

        // Track cursor for loupe live preview (use canvas space for zoom correctness)
        if state == .selected && currentTool == .loupe && !showBeautifyInOptionsRow {
            let newPoint = viewToCanvas(convert(event.locationInWindow, from: nil))
            if newPoint != loupeCursorPoint {
                loupeCursorPoint = newPoint
                needsDisplay = true
            }
        }

        // Track cursor for marker size preview circle (canvas space so it scales with zoom)
        if state == .selected && currentTool == .marker {
            let canvasPoint = viewToCanvas(point)
            if canvasPoint != markerCursorPoint {
                markerCursorPoint = canvasPoint
                needsDisplay = true
            }
        } else if markerCursorPoint != .zero {
            markerCursorPoint = .zero
            needsDisplay = true
        }

        // Track cursor for color sampler tool (canvas space)
        if state == .selected && currentTool == .colorSampler {
            let canvasPoint = viewToCanvas(point)
            if canvasPoint != colorSamplerPoint {
                colorSamplerPoint = canvasPoint
                needsDisplay = true
            }
        } else if colorSamplerPoint != .zero {
            colorSamplerPoint = .zero
            colorSamplerBitmap = nil
            needsDisplay = true
        }

        // Toolbar hover handled by ToolbarButtonView (real NSView subviews)

        // Hover-to-move: only active for the core shape/drawing tools.
        let hoverMoveTools: Set<AnnotationTool> = [.arrow, .line, .rectangle, .ellipse]
        // Hover-to-move: when a drawing tool is active and the cursor is over a movable annotation,
        // temporarily show the open-hand cursor so the user can move it without switching tools.
        // Disabled entirely in pass-through mode (recording with annotation off).
        if isRecording && !isAnnotating {
            if hoveredAnnotation != nil {
                hoveredAnnotationClearTimer?.invalidate()
                hoveredAnnotationClearTimer = nil
                hoveredAnnotation = nil
                needsDisplay = true
            }
            return
        }
        if state == .selected && hoverMoveTools.contains(currentTool) && !isDraggingAnnotation
            && !isResizingAnnotation
        {
            let canvasPoint = viewToCanvas(point)
            let newHovered = annotations.reversed().first {
                $0.isMovable && $0.hitTest(point: canvasPoint)
            }

            if newHovered !== nil {
                // Cursor is directly over an annotation — show controls immediately.
                hoveredAnnotationClearTimer?.invalidate()
                hoveredAnnotationClearTimer = nil
                if newHovered !== hoveredAnnotation {
                    hoveredAnnotation = newHovered

                    needsDisplay = true
                }
            } else if hoveredAnnotation != nil {
                // Cursor left the annotation hit area. Check if it's within the extended controls
                // zone (handles + delete button sit outside the hit area) — if so, keep hoveredAnnotation.
                // Unrotate point for resize handle hit test (handles are drawn in rotated space)
                let unrotatedPoint: NSPoint
                if let ann = hoveredAnnotation, ann.rotation != 0 && ann.supportsRotation {
                    let center = NSPoint(x: ann.boundingRect.midX, y: ann.boundingRect.midY)
                    let cos_r = cos(-ann.rotation)
                    let sin_r = sin(-ann.rotation)
                    let dx = point.x - center.x
                    let dy = point.y - center.y
                    unrotatedPoint = NSPoint(
                        x: center.x + dx * cos_r - dy * sin_r,
                        y: center.y + dx * sin_r + dy * cos_r)
                } else {
                    unrotatedPoint = point
                }
                let controlsActive =
                    annotationDeleteButtonRect.contains(point)
                    || annotationResizeHandleRects.contains {
                        $0.1.insetBy(dx: -8, dy: -8).contains(unrotatedPoint)
                    }
                    || (annotationRotateHandleRect != .zero
                        && annotationRotateHandleRect.insetBy(dx: -8, dy: -8).contains(point))

                if controlsActive {
                    // Inside a control rect — cancel any pending clear and stay active.
                    hoveredAnnotationClearTimer?.invalidate()
                    hoveredAnnotationClearTimer = nil
                } else if hoveredAnnotationClearTimer == nil {
                    // Start a linger timer — gives the cursor time to travel to a nearby handle/button.
                    hoveredAnnotationClearTimer = Timer.scheduledTimer(
                        withTimeInterval: 0.45, repeats: false
                    ) { [weak self] _ in
                        guard let self = self else { return }
                        self.hoveredAnnotationClearTimer = nil
                        self.hoveredAnnotation = nil
                        self.needsDisplay = true
                    }
                }
            }
        } else if hoveredAnnotation != nil
            && (!hoverMoveTools.contains(currentTool) || isDraggingAnnotation
                || isResizingAnnotation)
        {
            hoveredAnnotationClearTimer?.invalidate()
            hoveredAnnotationClearTimer = nil
            hoveredAnnotation = nil

            needsDisplay = true
        }
    }

    // Custom cursors
    /// Render an SF Symbol as a cursor image: white icon with dark shadow for visibility on any background.
    private static func cursorFromSymbol(
        _ name: String, pointSize: CGFloat, hotSpot: NSPoint, canvasSize: CGFloat = 22
    ) -> NSCursor {
        let size = canvasSize
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            if let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                let colored = sym.withSymbolConfiguration(cfg) ?? sym
                let iconRect = NSRect(x: 1, y: 1, width: size - 2, height: size - 2)

                // Tint to white by drawing into a separate image
                let tinted = NSImage(size: colored.size, flipped: false) { rect in
                    NSColor.white.setFill()
                    rect.fill()
                    colored.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
                    return true
                }

                // Dark outline/shadow for contrast on light backgrounds
                let dark = NSImage(size: colored.size, flipped: false) { rect in
                    NSColor(white: 0, alpha: 0.6).setFill()
                    rect.fill()
                    colored.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
                    return true
                }

                // Draw dark shadow offset in multiple directions
                for dx: CGFloat in [-1, 0, 1] {
                    for dy: CGFloat in [-1, 0, 1] {
                        if dx == 0 && dy == 0 { continue }
                        dark.draw(
                            in: iconRect.offsetBy(dx: dx, dy: dy), from: .zero,
                            operation: .sourceOver, fraction: 1.0)
                    }
                }
                // Draw white icon on top
                tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        return NSCursor(image: image, hotSpot: hotSpot)
    }

    private static let moveCursor: NSCursor = cursorFromSymbol(
        "arrow.up.and.down.and.arrow.left.and.right", pointSize: 13, hotSpot: NSPoint(x: 11, y: 11))

    // Diagonal resize cursors (macOS doesn't provide these publicly)
    private static let nwseCursor: NSCursor = {
        // Top-left <-> Bottom-right (backslash direction)
        if let cursor = NSCursor.perform(
            NSSelectorFromString("_windowResizeNorthWestSouthEastCursor"))?.takeUnretainedValue()
            as? NSCursor
        {
            return cursor
        }
        return .crosshair
    }()

    private static let neswCursor: NSCursor = {
        // Top-right <-> Bottom-left (slash direction)
        if let cursor = NSCursor.perform(
            NSSelectorFromString("_windowResizeNorthEastSouthWestCursor"))?.takeUnretainedValue()
            as? NSCursor
        {
            return cursor
        }
        return .crosshair
    }()

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateCursorForPoint(point)
    }

    override func resetCursorRects() {
        // Handled by cursorUpdate via tracking area
    }

    /// Imperative cursor management. Called from mouseMoved and a 30fps timer.
    /// Simplified: arrow for chrome, resize cursors for handles, tool cursor for canvas.
    private func updateCursorForPoint(_ point: NSPoint) {
        // Non-interactive states — simple cursors
        if isRecording && !isAnnotating {
            NSCursor.arrow.set()
            return
        }
        if textEditView != nil {
            NSCursor.arrow.set()
            return
        }
        if state == .idle || state == .selecting {
            NSCursor.crosshair.set()
            return
        }
        guard state == .selected else { return }

        // Chrome areas — arrow
        if isPointOnChrome(point) {
            NSCursor.arrow.set()
            return
        }

        // Selection resize handles (overlay only)
        if !isEditorMode, let handleCursor = resizeHandleCursor(at: point) {
            handleCursor.set()
            return
        }

        // Hover-to-move over annotations
        if [.arrow, .line, .rectangle, .ellipse, .select].contains(currentTool) {
            if let hovered = hoveredAnnotation, hovered.hitTest(point: viewToCanvas(point)) {
                Self.moveCursor.set()
                return
            }
        }

        // Tool cursor — use handler's cursor if available, else legacy switch
        if let handler = toolHandlers[currentTool], let cursor = handler.cursor {
            cursor.set()
        } else {
            switch currentTool {
            case .select: NSCursor.arrow.set()
            default: NSCursor.crosshair.set()
            }
        }
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let real NSView subviews (toolbar strips, options row) handle their own events.
        // This prevents our mouseDown override from intercepting slider drags etc.
        let localPoint = convert(point, from: superview)
        if let strip = bottomStripView, !strip.isHidden, strip.frame.contains(localPoint) {
            return strip.hitTest(convert(point, to: strip.superview))
        }
        if let strip = rightStripView, !strip.isHidden, strip.frame.contains(localPoint) {
            return strip.hitTest(convert(point, to: strip.superview))
        }
        if let row = toolOptionsRowView, !row.isHidden, row.frame.contains(localPoint) {
            return row.hitTest(convert(point, to: row.superview))
        }
        return super.hitTest(point)
    }

    /// Returns true if the point is over any chrome element (toolbars, options row, popovers, labels).
    private func isPointOnChrome(_ point: NSPoint) -> Bool {
        if showToolbars {
            if let strip = bottomStripView, !strip.isHidden, strip.frame.contains(point) {
                return true
            }
            if let strip = rightStripView, !strip.isHidden, strip.frame.contains(point) {
                return true
            }
            if let row = toolOptionsRowView, !row.isHidden, row.frame.contains(point) {
                return true
            }
        }
        if updateCursorForChrome(at: point) { return true }
        if sizeLabelRect.contains(point) && sizeInputField == nil { return true }
        if zoomLabelRect.contains(point) && zoomLabelOpacity > 0 && zoomInputField == nil {
            return true
        }
        return false
    }

    /// Returns the appropriate resize cursor if the point is on a selection handle, nil otherwise.
    private func resizeHandleCursor(at point: NSPoint) -> NSCursor? {
        let r = selectionRect
        let hs = handleSize + 4
        let edgeT: CGFloat = 6
        // Corner handles
        if NSRect(x: r.minX - hs / 2, y: r.maxY - hs / 2, width: hs, height: hs).contains(point)
            || NSRect(x: r.maxX - hs / 2, y: r.minY - hs / 2, width: hs, height: hs).contains(point)
        {
            return Self.nwseCursor
        }
        if NSRect(x: r.maxX - hs / 2, y: r.maxY - hs / 2, width: hs, height: hs).contains(point)
            || NSRect(x: r.minX - hs / 2, y: r.minY - hs / 2, width: hs, height: hs).contains(point)
        {
            return Self.neswCursor
        }
        // Edge handles
        if NSRect(x: r.minX + hs / 2, y: r.maxY - edgeT / 2, width: r.width - hs, height: edgeT)
            .contains(point)
            || NSRect(x: r.minX + hs / 2, y: r.minY - edgeT / 2, width: r.width - hs, height: edgeT)
                .contains(point)
        {
            return .resizeUpDown
        }
        if NSRect(x: r.minX - edgeT / 2, y: r.minY + hs / 2, width: edgeT, height: r.height - hs)
            .contains(point)
            || NSRect(
                x: r.maxX - edgeT / 2, y: r.minY + hs / 2, width: edgeT, height: r.height - hs
            ).contains(point)
        {
            return .resizeLeftRight
        }
        return nil
    }

    // MARK: - Subclass override points

    /// Override to handle cursor for editor chrome (top bar). Base returns false.
    func updateCursorForChrome(at point: NSPoint) -> Bool { return false }

    /// Check if a view-space point is within the image/selection area.
    /// In overlay mode, compares directly. In editor mode, converts to canvas space first.
    func pointIsInSelection(_ viewPoint: NSPoint) -> Bool {
        if isEditorMode {
            let canvasPoint = viewToCanvas(viewPoint)
            return selectionRect.contains(canvasPoint)
        }
        return selectionRect.contains(viewPoint)
    }

    /// Override point for editor background drawing. Base does nothing (overlay has no editor background).
    func drawEditorBackground(context: NSGraphicsContext) {
    }

    /// Override to clip the selection image in overlay mode. Base returns true when not in editor mode.
    func shouldClipSelectionImage() -> Bool { !isEditorMode }

    /// Override to control selection border drawing. Base returns true when not in editor mode.
    func shouldDrawSelectionBorder() -> Bool { !isEditorMode }

    /// Override to control size label drawing. Base returns true when not recording/scrolling/editing.
    func shouldDrawSizeLabel() -> Bool { !isRecording && !isScrollCapturing && !isEditorMode }

    /// Override to draw top chrome (e.g. editor top bar). Base draws editor top bar when in editor mode.    /// Override to adjust a view-space point for editor canvas offset. Base returns point unchanged.
    func adjustPointForEditor(_ p: NSPoint) -> NSPoint { p }

    /// Override point for editor-specific graphics context transform. Base does nothing.
    func applyEditorTransform(to context: NSGraphicsContext) {}

    /// Override to control whether selection resize handles are active. Base returns true when not in editor mode.
    func shouldAllowSelectionResize() -> Bool { !isEditorMode }

    /// Override to control whether a new selection can be started. Base returns true when not recording and not in editor mode.
    func shouldAllowNewSelection() -> Bool { !isRecording && !isEditorMode }

    /// Override to allow panning at 1x zoom. Base returns false.
    func canPanAtOneX() -> Bool { false }

    /// Override point for editor-specific zoom clamping. Base does nothing.
    func clampZoomAnchorForEditor(r: NSRect, z: CGFloat, ac: NSPoint, av: inout NSPoint) {}

    /// Override to change the rect used when drawing the screenshot in `captureSelectedRegion`. Base returns bounds.
    var captureDrawRect: NSRect { isEditorMode ? selectionRect : bounds }

    /// Override to position toolbars for editor mode. Base pins bottom bar centered at bottom, right bar at top-right.    /// Override to control whether detach (open in editor) is allowed. Base returns true when not in editor mode.
    func shouldAllowDetach() -> Bool { !isEditorMode }

    /// Override to handle clicks on chrome areas. Base returns false.
    func handleTopChromeClick(at point: NSPoint) -> Bool { false }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current else { return }

        // In editor mode: dark background, draw image centered at natural size (no stretch).
        // selectionRect stays at (0, 0, imgW, imgH) — annotations always use image-relative coords.
        if isEditorMode {
            drawEditorBackground(context: context)
        } else if isScrollCapturing {
            // During scroll capture: make the entire window transparent so the user sees
            // live screen content everywhere (not just inside the selection).
            context.cgContext.clear(bounds)
        } else if !annotationModeEverUsed {
            // Draw screenshot
            if let image = screenshotImage {
                image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
            }

            // Draw dark overlay
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(rect: bounds).fill()
        }

        // Window snap highlight (drawn before helper text so text appears on top)
        drawWindowSnapHighlight()

        // Helper text
        if state == .idle {
            drawIdleHelperText()
        } else if state == .selecting {
            drawSelectingHelperText()
        }

        // Draw remote selection region (cross-screen drag from another overlay)
        if remoteSelectionRect.width >= 1 && remoteSelectionRect.height >= 1 {
            if shouldClipSelectionImage() {
                context.saveGraphicsState()
                NSBezierPath(rect: remoteSelectionRect).setClip()
                if let image = screenshotImage {
                    image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
                }
                context.restoreGraphicsState()
            }
            // Purple border for remote selection
            let remoteBorder = NSBezierPath(rect: remoteSelectionRect)
            remoteBorder.lineWidth = 2.0
            ToolbarLayout.accentColor.setStroke()
            remoteBorder.stroke()
        }

        // Draw clear selection region
        if state != .idle && selectionRect.width >= 1 && selectionRect.height >= 1 {
            // During scroll capture: punch a fully-transparent hole so the live screen
            // content underneath shows through the overlay window.
            if isScrollCapturing {
                context.saveGraphicsState()
                context.cgContext.clear(selectionRect)
                context.restoreGraphicsState()
            }

            // Draw screenshot clipped to selection (image never bleeds outside).
            // In editor mode this is already handled by the detached draw block above.
            if shouldClipSelectionImage() {
                context.saveGraphicsState()
                NSBezierPath(rect: selectionRect).setClip()
                applyZoomTransform(to: context)
                if !isScrollCapturing, !annotationModeEverUsed, let image = screenshotImage {
                    image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
                }
                context.restoreGraphicsState()
            }

            // Draw translate overlays clipped to selection (they must stay inside).
            context.saveGraphicsState()
            applyCanvasTransform(to: context)
            NSBezierPath(rect: selectionRect).setClip()
            for annotation in annotations where annotation.tool == .translateOverlay {
                annotation.draw(in: context)
            }
            context.restoreGraphicsState()

            // Draw user annotations unclipped — strokes can continue past the selection border.
            context.saveGraphicsState()
            applyCanvasTransform(to: context)
            for annotation in annotations where annotation.tool != .translateOverlay {
                annotation.draw(in: context)
            }
            currentAnnotation?.draw(in: context)
            autoMeasurePreview?.draw(in: context)

            // Crop selection rectangle preview
            if isCropDragging && cropDragRect.width > 1 && cropDragRect.height > 1 {
                drawCropPreview()

                // Crop border
                NSColor.white.setStroke()
                let cropBorder = NSBezierPath(rect: cropDragRect)
                cropBorder.lineWidth = 1.5
                cropBorder.stroke()

                // Rule of thirds grid
                NSColor.white.withAlphaComponent(0.3).setStroke()
                let thirdW = cropDragRect.width / 3
                let thirdH = cropDragRect.height / 3
                for i in 1...2 {
                    let gridLine = NSBezierPath()
                    gridLine.move(
                        to: NSPoint(
                            x: cropDragRect.minX + thirdW * CGFloat(i), y: cropDragRect.minY))
                    gridLine.line(
                        to: NSPoint(
                            x: cropDragRect.minX + thirdW * CGFloat(i), y: cropDragRect.maxY))
                    gridLine.lineWidth = 0.5
                    gridLine.stroke()
                    let hLine = NSBezierPath()
                    hLine.move(
                        to: NSPoint(
                            x: cropDragRect.minX, y: cropDragRect.minY + thirdH * CGFloat(i)))
                    hLine.line(
                        to: NSPoint(
                            x: cropDragRect.maxX, y: cropDragRect.minY + thirdH * CGFloat(i)))
                    hLine.lineWidth = 0.5
                    hLine.stroke()
                }
            }

            // Live loupe preview when loupe tool is active
            if currentTool == .loupe && selectionRect.contains(loupeCursorPoint)
                && loupeCursorPoint != .zero
            {
                drawLoupePreview(at: loupeCursorPoint)
            }
            if currentTool == .colorSampler && colorSamplerPoint != .zero {
                drawColorSamplerPreview(at: colorSamplerPoint)
            }

            // Draw selection highlight for selected annotation (or hovered annotation in drawing mode)
            // Suppressed in pass-through mode so annotations are purely visual overlays.
            if !(isRecording && !isAnnotating) {
                if let selected = selectedAnnotation, currentTool == .select {
                    drawAnnotationControls(for: selected)
                } else if let hovered = hoveredAnnotation,
                    [AnnotationTool.arrow, .line, .rectangle, .ellipse].contains(currentTool)
                {
                    drawAnnotationControls(for: hovered)
                }
            }

            // Marker cursor preview inside zoom transform so it scales with zoom
            if currentTool == .marker && markerCursorPoint != .zero && currentAnnotation == nil {
                drawMarkerCursorPreview(at: markerCursorPoint)
            }

            // Snap alignment guides
            drawSnapGuides()

            context.restoreGraphicsState()

            // Live beautify preview — draw gradient background, shadow, and rounded image around selection
            if beautifyEnabled && state == .selected && !isScrollCapturing && !isRecording {
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
                drawBeautifyPreview(context: context)
                context.restoreGraphicsState()

                // Re-draw annotation controls on top of the beautify preview so they stay visible.
                if !(isRecording && !isAnnotating) {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    if let selected = selectedAnnotation, currentTool == .select {
                        drawAnnotationControls(for: selected)
                    } else if let hovered = hoveredAnnotation,
                        [AnnotationTool.arrow, .line, .rectangle, .ellipse].contains(currentTool)
                    {
                        drawAnnotationControls(for: hovered)
                    }
                    context.restoreGraphicsState()
                }

                // Re-draw loupe preview on top of beautify so it stays visible
                if currentTool == .loupe && selectionRect.contains(loupeCursorPoint)
                    && loupeCursorPoint != .zero
                {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawLoupePreview(at: loupeCursorPoint)
                    context.restoreGraphicsState()
                }

                // Re-draw color sampler preview on top of beautify
                if currentTool == .colorSampler && colorSamplerPoint != .zero {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawColorSamplerPreview(at: colorSamplerPoint)
                    context.restoreGraphicsState()
                }

                // Re-draw snap guides on top of beautify
                if snapGuideX != nil || snapGuideY != nil {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawSnapGuides()
                    context.restoreGraphicsState()
                }

                // Re-draw marker cursor preview on top of beautify
                if currentTool == .marker && markerCursorPoint != .zero && currentAnnotation == nil
                {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawMarkerCursorPreview(at: markerCursorPoint)
                    context.restoreGraphicsState()
                }

                // Re-draw crop preview on top of beautify
                if isCropDragging && cropDragRect.width > 1 && cropDragRect.height > 1 {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawCropPreview()
                    NSColor.white.setStroke()
                    let cropBorder = NSBezierPath(rect: cropDragRect)
                    cropBorder.lineWidth = 1.5
                    cropBorder.stroke()
                    context.restoreGraphicsState()
                }
            }

            // Selection border — hidden in editor mode and when beautify preview is active,
            // red during scroll capture, purple otherwise
            if shouldDrawSelectionBorder()
                && !(beautifyEnabled && state == .selected && !isScrollCapturing && !isRecording)
            {
                let borderPath = NSBezierPath(rect: selectionRect)
                borderPath.lineWidth = isScrollCapturing ? 2.5 : 2.0
                (isScrollCapturing ? NSColor.systemRed : ToolbarLayout.accentColor).setStroke()
                borderPath.stroke()
            }

            if shouldDrawSizeLabel() {
                // Size label above/below selection
                drawSizeLabel()

                // Zoom label (fades in/out beside the size label)
                if zoomLabelOpacity > 0 {
                    drawZoomLabel()
                }

                // Resize handles
                if state == .selected {
                    drawResizeHandles()
                }
            }

            // Hide the text view when color picker is open for bg/outline (so picker isn't behind it)
            if let sv = textEditor.scrollView {
                let shouldHide = false
                sv.isHidden = shouldHide
            }

            // Live text box (bg/outline + resize handles)
            if let sv = textEditor.scrollView, textEditView != nil {
                let pad: CGFloat = 4
                let pillRect = sv.frame.insetBy(dx: -pad, dy: -pad)
                let cornerR: CGFloat = 4

                // Background fill
                if textEditor.bgEnabled {
                    textEditor.bgColor.setFill()
                    NSBezierPath(roundedRect: pillRect, xRadius: cornerR, yRadius: cornerR).fill()
                }

                // Text outline
                if textEditor.outlineEnabled {
                    textEditor.outlineColor.setStroke()
                    let outlinePath = NSBezierPath(
                        roundedRect: pillRect, xRadius: cornerR, yRadius: cornerR)
                    outlinePath.lineWidth = 2
                    outlinePath.stroke()
                }

                // Draw text content when scroll view is hidden (color picker open)
                if sv.isHidden, let tv = textEditView, let attrStr = tv.textStorage,
                    attrStr.length > 0
                {
                    let inset = tv.textContainerInset
                    let textRect = NSRect(
                        x: sv.frame.minX + inset.width, y: sv.frame.minY + inset.height,
                        width: sv.frame.width - inset.width * 2,
                        height: sv.frame.height - inset.height * 2)
                    context.saveGraphicsState()
                    let flipped = NSAffineTransform()
                    flipped.translateX(by: 0, yBy: sv.frame.maxY + sv.frame.minY)
                    flipped.scaleX(by: 1, yBy: -1)
                    flipped.concat()
                    attrStr.draw(in: textRect)
                    context.restoreGraphicsState()
                }

                // Box border (always visible while editing)
                NSColor.white.withAlphaComponent(0.4).setStroke()
                let borderPath = NSBezierPath(rect: sv.frame)
                borderPath.lineWidth = 1
                let pattern: [CGFloat] = [4, 3]
                borderPath.setLineDash(pattern, count: 2, phase: 0)
                borderPath.stroke()

                // Resize handles on the text box
                let hs: CGFloat = 6
                let handleColor = NSColor.white
                let handleRects = [
                    NSRect(
                        x: sv.frame.minX - hs / 2, y: sv.frame.minY - hs / 2, width: hs, height: hs),  // bottom-left
                    NSRect(
                        x: sv.frame.maxX - hs / 2, y: sv.frame.minY - hs / 2, width: hs, height: hs),  // bottom-right
                    NSRect(
                        x: sv.frame.minX - hs / 2, y: sv.frame.maxY - hs / 2, width: hs, height: hs),  // top-left
                    NSRect(
                        x: sv.frame.maxX - hs / 2, y: sv.frame.maxY - hs / 2, width: hs, height: hs),  // top-right
                    NSRect(
                        x: sv.frame.midX - hs / 2, y: sv.frame.minY - hs / 2, width: hs, height: hs),  // bottom
                    NSRect(
                        x: sv.frame.midX - hs / 2, y: sv.frame.maxY - hs / 2, width: hs, height: hs),  // top
                    NSRect(
                        x: sv.frame.minX - hs / 2, y: sv.frame.midY - hs / 2, width: hs, height: hs),  // left
                    NSRect(
                        x: sv.frame.maxX - hs / 2, y: sv.frame.midY - hs / 2, width: hs, height: hs),  // right
                ]
                for hr in handleRects {
                    handleColor.setFill()
                    NSBezierPath(roundedRect: hr, xRadius: 1, yRadius: 1).fill()
                    NSColor.black.withAlphaComponent(0.3).setStroke()
                    NSBezierPath(roundedRect: hr, xRadius: 1, yRadius: 1).stroke()
                }
            }

            // Stamp cursor preview
            if let previewPt = stampPreviewPoint, let img = currentStampImage,
                currentTool == .stamp, !isRecording
            {
                let stampSize: CGFloat = 64
                let aspect = img.size.width / max(img.size.height, 1)
                let w = aspect >= 1 ? stampSize : stampSize * aspect
                let h = aspect >= 1 ? stampSize / aspect : stampSize
                let previewRect = NSRect(
                    x: previewPt.x - w / 2, y: previewPt.y - h / 2, width: w, height: h)
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
                img.draw(
                    in: previewRect, from: .zero, operation: .sourceOver, fraction: 0.5,
                    respectFlipped: true, hints: nil)
                context.restoreGraphicsState()
            }

            // Toolbars
            if showToolbars && state == .selected && !isScrollCapturing {
                repositionToolbars()
                // Toolbars are real NSView subviews (ToolbarStripView) — no custom drawing needed.
                // Tool options row handled by ToolOptionsRowView (real NSView subview)
                if !toolHasOptionsRow || (isRecording && !isAnnotating) {
                    // options row rect managed by ToolOptionsRowView
                }

                // Color picker popover

                // Beautify style picker popover

                // Stroke width picker popover

                // Loupe size picker

                // Upload confirm picker

                // Redact type picker

            }

            // Radial color wheel
            if colorWheel.isVisible {
                colorWheel.draw(currentColor: currentColor)
            }
        }

        // Overlay error message
        if let errorMsg = overlayErrorMessage {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let str = errorMsg as NSString
            let strSize = str.size(withAttributes: attrs)
            let padding: CGFloat = 12
            let msgW = strSize.width + padding * 2
            let msgH = strSize.height + padding
            let msgX = bounds.midX - msgW / 2
            let msgY = bounds.maxY - msgH - 40
            let msgRect = NSRect(x: msgX, y: msgY, width: msgW, height: msgH)
            NSColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: msgRect, xRadius: 8, yRadius: 8).fill()
            str.draw(
                at: NSPoint(x: msgRect.minX + padding, y: msgRect.minY + padding / 2),
                withAttributes: attrs)
        }

        // Barcode / QR badge
        if state == .selected {
            barcodeDetector.draw(
                selectionRect: selectionRect, bottomBarRect: bottomBarRect, viewBounds: bounds)
        }

        // Mouse click highlights (animated canvas overlays — must stay in draw)
        if isRecording && UserDefaults.standard.bool(forKey: "recordMouseHighlight") {
            drawMouseHighlights()
        }

        // Instant tooltip for hovered toolbar button
        drawHoveredTooltip()

    }
    private func drawIdleHelperText() {
        let line1 =
            windowSnapEnabled
            ? "Click a window  ·  Drag for custom area  ·  F for full screen"
            : "Drag to select  ·  Click for full screen"
        let snapOn = windowSnapEnabled
        let line3prefix = "Window snap: "
        let line3state = snapOn ? "ON" : "OFF"
        let line3suffix = "  (Tab to toggle)"

        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let smallFont = NSFont.systemFont(ofSize: 12, weight: .regular)
        let textColor = NSColor.white
        let dimColor = NSColor.white.withAlphaComponent(0.7)
        let snapColor = snapOn ? NSColor.systemGreen : NSColor.systemOrange

        let attrs1: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let attrs2prefix: [NSAttributedString.Key: Any] = [
            .font: smallFont, .foregroundColor: dimColor,
        ]
        let attrs2state: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: snapColor,
        ]
        let attrs2suffix: [NSAttributedString.Key: Any] = [
            .font: smallFont, .foregroundColor: dimColor,
        ]

        let size1 = (line1 as NSString).size(withAttributes: attrs1)
        let size2pre = (line3prefix as NSString).size(withAttributes: attrs2prefix)
        let size2state = (line3state as NSString).size(withAttributes: attrs2state)
        let size2suf = (line3suffix as NSString).size(withAttributes: attrs2suffix)
        let size2total = CGSize(
            width: size2pre.width + size2state.width + size2suf.width,
            height: max(size2pre.height, size2state.height, size2suf.height))

        let lineSpacing: CGFloat = 6
        let padding: CGFloat = 14
        let totalTextHeight = size1.height + lineSpacing + size2total.height
        let bgWidth = max(size1.width, size2total.width) + padding * 2
        let bgHeight = totalTextHeight + padding * 2

        let bgX = bounds.midX - bgWidth / 2
        let bgY = bounds.midY - bgHeight / 2
        let bgRect = NSRect(x: bgX, y: bgY, width: bgWidth, height: bgHeight)

        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 8, yRadius: 8).fill()

        let textY1 = bgY + padding + size2total.height + lineSpacing
        let textY2 = bgY + padding

        (line1 as NSString).draw(
            at: NSPoint(x: bounds.midX - size1.width / 2, y: textY1), withAttributes: attrs1)

        // Draw snap line as three segments with different colors
        let line2startX = bounds.midX - size2total.width / 2
        let line2Y = textY2 + (size2total.height - size2pre.height) / 2
        (line3prefix as NSString).draw(
            at: NSPoint(x: line2startX, y: line2Y), withAttributes: attrs2prefix)
        (line3state as NSString).draw(
            at: NSPoint(x: line2startX + size2pre.width, y: line2Y), withAttributes: attrs2state)
        (line3suffix as NSString).draw(
            at: NSPoint(x: line2startX + size2pre.width + size2state.width, y: line2Y),
            withAttributes: attrs2suffix)
    }

    private func drawSelectingHelperText() {
        guard selectionRect.width >= 1, selectionRect.height >= 1 else { return }

        let text = "Release to annotate and edit"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 10
        let bgWidth = size.width + padding * 2
        let bgHeight = size.height + padding

        // Position below the selection, centered
        var labelX = selectionRect.midX - bgWidth / 2
        var labelY = selectionRect.minY - bgHeight - 8

        // If below screen, put above
        if labelY < bounds.minY + 4 {
            labelY = selectionRect.maxY + 8
        }
        // Clamp horizontal
        labelX = max(bounds.minX + 4, min(labelX, bounds.maxX - bgWidth - 4))

        let bgRect = NSRect(x: labelX, y: labelY, width: bgWidth, height: bgHeight)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6).fill()

        (text as NSString).draw(
            at: NSPoint(x: bgRect.minX + padding, y: bgRect.minY + padding / 2),
            withAttributes: attrs)
    }

    private func drawSizeLabel() {
        guard sizeInputField == nil else { return }  // don't draw while editing

        // Get pixel dimensions (account for Retina)
        let scale = window?.backingScaleFactor ?? 2.0
        let pixelW = Int(selectionRect.width * scale)
        let pixelH = Int(selectionRect.height * scale)
        let text = "\(pixelW) \u{00D7} \(pixelH)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 6
        let labelW = textSize.width + padding * 2
        let labelH = textSize.height + padding

        let labelX = selectionRect.midX - labelW / 2

        // Default: above selection. If toolbar is above (bottomBarRect is above selection), go below toolbar area.
        // If no room above, go below.
        let above = selectionRect.maxY + 4
        let below = selectionRect.minY - labelH - 4
        let labelY: CGFloat
        if above + labelH < bounds.maxY - 2 {
            labelY = above
        } else if below >= bounds.minY + 2 {
            labelY = below
        } else {
            labelY = above  // fallback
        }

        let rect = NSRect(x: labelX, y: labelY, width: labelW, height: labelH)
        sizeLabelRect = rect

        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(
            at: NSPoint(x: rect.minX + padding, y: rect.minY + padding / 2), withAttributes: attrs)
    }

    private func drawZoomLabel() {
        guard sizeLabelRect != .zero, zoomInputField == nil else { return }
        let zoom = zoomLevel
        let text: String
        if abs(zoom - 1.0) < 0.005 {
            text = "1×"
        } else if zoom >= 10 {
            text = String(format: "%.0f×", zoom)
        } else {
            text = String(format: "%.1f×", zoom).replacingOccurrences(of: ".0×", with: "×")
        }

        let alpha = zoomLabelOpacity
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 6
        let labelW = textSize.width + padding * 2
        let labelH = sizeLabelRect.height
        let gap: CGFloat = 6
        let labelX = sizeLabelRect.maxX + gap
        let labelY = sizeLabelRect.minY

        let rect = NSRect(x: labelX, y: labelY, width: labelW, height: labelH)
        zoomLabelRect = rect

        let bgColor = ToolbarLayout.bgColor.withAlphaComponent(alpha * 0.85)
        bgColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(
            at: NSPoint(x: labelX + padding, y: labelY + padding / 2), withAttributes: attrs)
    }

    private func showSizeInput() {
        let scale = window?.backingScaleFactor ?? 2.0
        let pixelW = Int(selectionRect.width * scale)
        let pixelH = Int(selectionRect.height * scale)

        let fieldWidth: CGFloat = 120
        let fieldHeight: CGFloat = 22
        let fieldX = sizeLabelRect.midX - fieldWidth / 2
        let fieldY = sizeLabelRect.minY + (sizeLabelRect.height - fieldHeight) / 2

        let field = NSTextField(
            frame: NSRect(x: fieldX, y: fieldY, width: fieldWidth, height: fieldHeight))
        field.stringValue = "\(pixelW) \u{00D7} \(pixelH)"
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        field.alignment = .center
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.backgroundColor = NSColor(white: 0.15, alpha: 0.95)
        field.textColor = .white
        field.focusRingType = .none
        field.delegate = self
        field.tag = 888

        addSubview(field)
        sizeInputField = field
        window?.makeFirstResponder(field)
        field.selectText(nil)
        needsDisplay = true
    }

    private func commitSizeInputIfNeeded() {
        guard let field = sizeInputField else { return }
        let input = field.stringValue.trimmingCharacters(in: .whitespaces)

        // Parse "W × H", "WxH", "W*H", "W H"
        let separators = CharacterSet(charactersIn: "\u{00D7}xX*").union(.whitespaces)
        let parts = input.components(separatedBy: separators).filter { !$0.isEmpty }

        if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 {
            let scale = window?.backingScaleFactor ?? 2.0
            let newW = CGFloat(w) / scale
            let newH = CGFloat(h) / scale

            // Resize from center of current selection
            let centerX = selectionRect.midX
            let centerY = selectionRect.midY
            selectionRect = NSRect(
                x: centerX - newW / 2,
                y: centerY - newH / 2,
                width: newW,
                height: newH
            )
        }

        field.removeFromSuperview()
        sizeInputField = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func showZoomInput() {
        guard zoomLabelRect != .zero else { return }
        // Show zoom as a plain number (e.g. "2" or "3.5") so user can type a new value
        let currentText: String
        if abs(zoomLevel - 1.0) < 0.005 {
            currentText = "1"
        } else {
            let rounded = (zoomLevel * 10).rounded() / 10
            currentText =
                rounded == rounded.rounded()
                ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
        }

        let fieldWidth: CGFloat = 70
        let fieldHeight: CGFloat = 22
        let fieldX = zoomLabelRect.midX - fieldWidth / 2
        let fieldY = zoomLabelRect.minY + (zoomLabelRect.height - fieldHeight) / 2

        let field = NSTextField(
            frame: NSRect(x: fieldX, y: fieldY, width: fieldWidth, height: fieldHeight))
        field.stringValue = currentText
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        field.alignment = .center
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.backgroundColor = NSColor(white: 0.15, alpha: 0.95)
        field.textColor = .white
        field.focusRingType = .none
        field.delegate = self
        field.tag = 889

        addSubview(field)
        zoomInputField = field
        window?.makeFirstResponder(field)
        field.selectText(nil)
        // Keep zoom label visible while editing
        zoomLabelOpacity = 1.0
        zoomFadeTimer?.invalidate()
        needsDisplay = true
    }

    private func commitZoomInputIfNeeded() {
        guard let field = zoomInputField else { return }
        let input = field.stringValue.trimmingCharacters(in: .whitespaces)
        // Strip trailing × if user typed it
        let cleaned = input.replacingOccurrences(of: "×", with: "").replacingOccurrences(
            of: "x", with: ""
        ).trimmingCharacters(in: .whitespaces)
        if let value = Double(cleaned), value > 0 {
            let newLevel = max(zoomMin, min(zoomMax, CGFloat(value)))
            // Zoom toward selection center when set via text
            let center = NSPoint(x: selectionRect.midX, y: selectionRect.midY)
            setZoom(newLevel, cursorView: center)
        }

        field.removeFromSuperview()
        zoomInputField = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func drawResizeHandles() {
        for (_, rect) in allHandleRects() {
            ToolbarLayout.handleColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
    /// Compare two colors by RGB components (ignoring minor floating point differences)    /// Convert NSColor to hex string like "FF3B30"
    private func colorToHexString(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "%02X%02X%02X", r, g, b)
    }


    // MARK: - Custom Color Persistence
    private func saveCustomColors() {
        let hexArray = customColors.map { color -> String in
            guard let c = color else { return "" }
            return colorToHexString(c)
        }
        UserDefaults.standard.set(hexArray, forKey: "customColors")
    }
    /// The expanded rect including beautify padding (for live preview).
    /// Returns selectionRect if beautify is off.
    var beautifyPreviewRect: NSRect {
        guard beautifyEnabled else { return selectionRect }
        let config = beautifyConfig
        let pad = config.padding
        let shadowBleed = config.shadowRadius + min(config.shadowRadius * 0.4, 10)
        let titleBarH: CGFloat = config.mode == .window ? 28 : 0
        return NSRect(
            x: selectionRect.minX - pad - shadowBleed,
            y: selectionRect.minY - pad - shadowBleed,
            width: selectionRect.width + pad * 2 + shadowBleed * 2,
            height: selectionRect.height + titleBarH + pad * 2 + shadowBleed * 2
        )
    }

    private func drawBeautifyPreview(context: NSGraphicsContext) {
        let config = beautifyConfig
        let pad = config.padding
        let cornerRadius = config.cornerRadius
        let shadowRadius = config.shadowRadius
        let shadowOffset = min(shadowRadius * 0.4, 10)

        // Compute the expanded frame around the selection.
        // Shadow extends downward (negative Y in AppKit), so expand the origin down.
        let shadowBleed = shadowRadius + shadowOffset
        let expandedRect: NSRect
        if config.mode == .window {
            let titleBarH: CGFloat = 28
            expandedRect = NSRect(
                x: selectionRect.minX - pad - shadowBleed,
                y: selectionRect.minY - pad - shadowBleed,
                width: selectionRect.width + pad * 2 + shadowBleed * 2,
                height: selectionRect.height + titleBarH + pad * 2 + shadowBleed * 2
            )
        } else {
            expandedRect = NSRect(
                x: selectionRect.minX - pad - shadowBleed,
                y: selectionRect.minY - pad - shadowBleed,
                width: selectionRect.width + pad * 2 + shadowBleed * 2,
                height: selectionRect.height + pad * 2 + shadowBleed * 2
            )
        }

        // Clear the dark overlay for the expanded area to make the preview visible
        context.saveGraphicsState()
        if !isEditorMode {
            // Overlay: re-draw the screenshot in the expanded area to erase the dark overlay,
            // then draw the dark overlay back so we have a clean base for the gradient.
            context.cgContext.saveGState()
            NSBezierPath(rect: expandedRect).addClip()
            if let image = screenshotImage {
                image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
            }
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(rect: expandedRect).fill()
            context.cgContext.restoreGState()
        }

        // Position the image/window centered within the expanded rect (not affected by shadow bleed)
        let innerX = selectionRect.minX - pad
        let innerY = selectionRect.minY - pad

        // Draw gradient background (inner rect without shadow bleed)
        let bgRect: NSRect
        if config.mode == .window {
            let titleBarH: CGFloat = 28
            bgRect = NSRect(
                x: innerX, y: innerY, width: selectionRect.width + pad * 2,
                height: selectionRect.height + titleBarH + pad * 2)
        } else {
            bgRect = NSRect(
                x: innerX, y: innerY, width: selectionRect.width + pad * 2,
                height: selectionRect.height + pad * 2)
        }
        context.cgContext.saveGState()
        let bgPath = NSBezierPath(
            roundedRect: bgRect, xRadius: config.bgRadius, yRadius: config.bgRadius)
        bgPath.addClip()
        BeautifyRenderer.drawGradientBackground(
            in: bgRect, config: config, context: context.cgContext)
        context.cgContext.restoreGState()

        // Compute the image rect inside the expanded frame
        let imageRect: NSRect
        let windowRect: NSRect

        if config.mode == .window {
            let titleBarH: CGFloat = 28
            let windowW = selectionRect.width
            let windowH = selectionRect.height + titleBarH
            windowRect = NSRect(
                x: innerX + pad,
                y: innerY + pad,
                width: windowW,
                height: windowH
            )
            imageRect = NSRect(
                x: windowRect.minX,
                y: windowRect.minY,
                width: windowW,
                height: windowH - titleBarH
            )
        } else {
            imageRect = NSRect(
                x: innerX + pad,
                y: innerY + pad,
                width: selectionRect.width,
                height: selectionRect.height
            )
            windowRect = imageRect
        }

        // Drop shadow
        if shadowRadius > 0 {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = shadowRadius
            shadow.shadowOffset = NSSize(width: 0, height: -shadowOffset)
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: windowRect, xRadius: cornerRadius, yRadius: cornerRadius)
                .fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        if config.mode == .window {
            // Draw window chrome
            let titleBarH: CGFloat = 28

            context.cgContext.saveGState()
            NSBezierPath(roundedRect: windowRect, xRadius: cornerRadius, yRadius: cornerRadius)
                .addClip()

            // Window background
            NSColor(white: 0.97, alpha: 1.0).setFill()
            NSBezierPath(rect: windowRect).fill()

            // Title bar
            let titleBarRect = NSRect(
                x: windowRect.minX, y: windowRect.maxY - titleBarH, width: windowRect.width,
                height: titleBarH)
            NSColor(white: 0.94, alpha: 1.0).setFill()
            NSBezierPath(rect: titleBarRect).fill()

            // Separator
            NSColor(white: 0.82, alpha: 1.0).setFill()
            NSBezierPath(
                rect: NSRect(
                    x: windowRect.minX, y: titleBarRect.minY - 0.5, width: windowRect.width,
                    height: 0.5)
            ).fill()

            // Traffic lights
            let buttonY = titleBarRect.midY
            let buttonRadius: CGFloat = 6
            let buttonStartX = windowRect.minX + 14
            let buttonSpacing: CGFloat = 20
            let trafficLights: [(NSColor, NSColor)] = [
                (
                    NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.35, alpha: 1.0),
                    NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.22, alpha: 1.0)
                ),
                (
                    NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.25, alpha: 1.0),
                    NSColor(calibratedRed: 0.85, green: 0.60, blue: 0.15, alpha: 1.0)
                ),
                (
                    NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.35, alpha: 1.0),
                    NSColor(calibratedRed: 0.20, green: 0.65, blue: 0.25, alpha: 1.0)
                ),
            ]
            for (i, (fill, ring)) in trafficLights.enumerated() {
                let cx = buttonStartX + CGFloat(i) * buttonSpacing
                let circleRect = NSRect(
                    x: cx - buttonRadius, y: buttonY - buttonRadius, width: buttonRadius * 2,
                    height: buttonRadius * 2)
                fill.setFill()
                NSBezierPath(ovalIn: circleRect).fill()
                ring.setStroke()
                let border = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 0.5
                border.stroke()
            }

            // Draw screenshot in content area (clipped to window shape)
            if let image = screenshotImage {
                image.draw(
                    in: imageRect, from: selectionRect, operation: .sourceOver, fraction: 1.0)
            }

            // Draw annotations shifted to the preview position (including current live annotation)
            let dx = imageRect.minX - selectionRect.minX
            let dy = imageRect.minY - selectionRect.minY
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: dx, y: dy)
            }
            for annotation in annotations {
                annotation.draw(in: context)
            }
            currentAnnotation?.draw(in: context)
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: -dx, y: -dy)
            }

            context.cgContext.restoreGState()
        } else {
            // Rounded mode — just rounded corners on the image
            context.cgContext.saveGState()
            NSBezierPath(roundedRect: imageRect, xRadius: cornerRadius, yRadius: cornerRadius)
                .addClip()

            if let image = screenshotImage {
                image.draw(in: imageRect, from: selectionRect, operation: .copy, fraction: 1.0)
            }

            // Draw annotations shifted to preview position (including current live annotation)
            let dx = imageRect.minX - selectionRect.minX
            let dy = imageRect.minY - selectionRect.minY
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: dx, y: dy)
            }
            for annotation in annotations {
                annotation.draw(in: context)
            }
            currentAnnotation?.draw(in: context)
            if dx != 0 || dy != 0 {
                context.cgContext.translateBy(x: -dx, y: -dy)
            }

            context.cgContext.restoreGState()
        }

        context.restoreGraphicsState()
    }

    /// Whether the current tool should show the options row
    var toolHasOptionsRow: Bool {
        switch currentTool {
        case .pencil, .line, .arrow, .rectangle, .ellipse, .marker, .number, .loupe, .measure,
            .pixelate, .blur, .stamp:
            return true
        case .text:
            return true
        default:
            return showBeautifyInOptionsRow
        }
    }

    private func startBeautifyToolbarAnimation() {
        beautifyToolbarAnimProgress = 0
        beautifyToolbarAnimTarget = beautifyEnabled
        beautifyToolbarAnimTimer?.invalidate()
        beautifyToolbarAnimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true)
        { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.beautifyToolbarAnimProgress += 0.08  // ~12 frames = 0.2s
            if self.beautifyToolbarAnimProgress >= 1.0 {
                self.beautifyToolbarAnimProgress = 1.0
                timer.invalidate()
                self.beautifyToolbarAnimTimer = nil
            }
            self.needsDisplay = true
        }
    }

    // MARK: - Color Sampler Preview

    /// Sample the pixel color at `canvasPoint` from the screenshot and draw a live preview.
    private func drawColorSamplerPreview(at canvasPoint: NSPoint) {
        guard let screenshot = screenshotImage else { return }
        guard let result = sampleColor(from: screenshot, at: canvasPoint) else { return }
        let sampledColor = result.color
        let hexStr = result.hex

        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let copyFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let hexAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
        ]
        let copyAttrs: [NSAttributedString.Key: Any] = [
            .font: copyFont, .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]

        let hexSize = (hexStr as NSString).size(withAttributes: hexAttrs)
        let copyText = "Right-click to copy"
        let copySize = (copyText as NSString).size(withAttributes: copyAttrs)

        let swatchSize: CGFloat = 16
        let padding: CGFloat = 8
        let gap: CGFloat = 6
        let labelW = padding + swatchSize + gap + max(hexSize.width, copySize.width) + padding
        let labelH = padding + hexSize.height + 2 + copySize.height + padding

        let labelX = canvasPoint.x + 16
        let labelY = canvasPoint.y - labelH - 8
        let labelRect = NSRect(x: labelX, y: labelY, width: labelW, height: labelH)

        // Background pill
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 6, yRadius: 6).fill()

        // Color swatch
        let swatchRect = NSRect(
            x: labelRect.minX + padding,
            y: labelRect.midY - swatchSize / 2,
            width: swatchSize, height: swatchSize)
        sampledColor.setFill()
        NSBezierPath(roundedRect: swatchRect, xRadius: 3, yRadius: 3).fill()
        NSColor.white.withAlphaComponent(0.4).setStroke()
        let swatchBorder = NSBezierPath(roundedRect: swatchRect, xRadius: 3, yRadius: 3)
        swatchBorder.lineWidth = 0.5
        swatchBorder.stroke()

        // Hex text + copy hint
        let textX = swatchRect.maxX + gap
        (hexStr as NSString).draw(
            at: NSPoint(x: textX, y: labelRect.maxY - padding - hexSize.height),
            withAttributes: hexAttrs)
        (copyText as NSString).draw(
            at: NSPoint(x: textX, y: labelRect.minY + padding), withAttributes: copyAttrs)

        context.restoreGraphicsState()
    }

    /// Sample a pixel color from the screenshot at the given canvas-space point.
    /// Returns (NSColor for display, hex string with raw sRGB values matching what other tools report).
    private func sampleColor(from image: NSImage, at canvasPoint: NSPoint) -> (
        color: NSColor, hex: String
    )? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let imgSize = image.size
        let drawRect = captureDrawRect

        let px = (canvasPoint.x - drawRect.origin.x) * imgSize.width / drawRect.width
        let py = (canvasPoint.y - drawRect.origin.y) * imgSize.height / drawRect.height
        guard px >= 0, py >= 0, px < imgSize.width, py < imgSize.height else { return nil }

        // Map to CGImage pixel coordinates.
        let scaleX = CGFloat(cgImage.width) / imgSize.width
        let scaleY = CGFloat(cgImage.height) / imgSize.height
        let cgX = Int(px * scaleX)
        let cgY = Int(CGFloat(cgImage.height) - 1 - py * scaleY)  // flip Y for CGImage (top-left origin)
        guard cgX >= 0, cgX < cgImage.width, cgY >= 0, cgY < cgImage.height else { return nil }

        // Render the single pixel into a known-format 1×1 sRGB bitmap to get correct raw values.
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let ctx = CGContext(
                data: nil, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(
            cgImage,
            in: CGRect(
                x: -CGFloat(cgX), y: -(CGFloat(cgImage.height) - 1 - CGFloat(cgY)),
                width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        guard let data = ctx.data else { return nil }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        let a = CGFloat(ptr[3]) / 255
        guard a > 0 else { return nil }
        // Undo premultiplication
        let r = UInt8(min(255, CGFloat(ptr[0]) / a))
        let g = UInt8(min(255, CGFloat(ptr[1]) / a))
        let b = UInt8(min(255, CGFloat(ptr[2]) / a))

        let hex = String(format: "#%02X%02X%02X", r, g, b)
        let color = NSColor(
            srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        return (color, hex)
    }

    // MARK: - Editor Image Transforms

    func flipImageHorizontally() {
        guard let original = screenshotImage,
            let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // Save state for undo
        let prevImage = original.copy() as! NSImage
        undoStack.append(.imageTransform(previousImage: prevImage, annotationOffsets: []))
        redoStack.removeAll()

        let w = cgImage.width
        let h = cgImage.height
        let cs = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: cgImage.bitsPerComponent,
                bytesPerRow: 0, space: cs,
                bitmapInfo: cgImage.bitmapInfo.rawValue)
        else { return }
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flipped = ctx.makeImage() else { return }

        screenshotImage = NSImage(cgImage: flipped, size: original.size)

        // Mirror annotation X coordinates around the image center
        let imgW = original.size.width
        for ann in annotations {
            ann.startPoint.x = selectionRect.minX + (selectionRect.maxX - ann.startPoint.x)
            ann.endPoint.x = selectionRect.minX + (selectionRect.maxX - ann.endPoint.x)
            if let cp = ann.controlPoint {
                ann.controlPoint = NSPoint(
                    x: selectionRect.minX + (selectionRect.maxX - cp.x), y: cp.y)
            }
            // Mirror freeform points
            if let pts = ann.points {
                ann.points = pts.map {
                    NSPoint(x: selectionRect.minX + (selectionRect.maxX - $0.x), y: $0.y)
                }
            }
        }

        cachedCompositedImage = nil
        needsDisplay = true
    }

    func flipImageVertically() {
        guard let original = screenshotImage,
            let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let prevImage = original.copy() as! NSImage
        undoStack.append(.imageTransform(previousImage: prevImage, annotationOffsets: []))
        redoStack.removeAll()

        let w = cgImage.width
        let h = cgImage.height
        let cs = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: cgImage.bitsPerComponent,
                bytesPerRow: 0, space: cs,
                bitmapInfo: cgImage.bitmapInfo.rawValue)
        else { return }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flipped = ctx.makeImage() else { return }

        screenshotImage = NSImage(cgImage: flipped, size: original.size)

        // Mirror annotation Y coordinates around the image center
        for ann in annotations {
            ann.startPoint.y = selectionRect.minY + (selectionRect.maxY - ann.startPoint.y)
            ann.endPoint.y = selectionRect.minY + (selectionRect.maxY - ann.endPoint.y)
            if let cp = ann.controlPoint {
                ann.controlPoint = NSPoint(
                    x: cp.x, y: selectionRect.minY + (selectionRect.maxY - cp.y))
            }
            if let pts = ann.points {
                ann.points = pts.map {
                    NSPoint(x: $0.x, y: selectionRect.minY + (selectionRect.maxY - $0.y))
                }
            }
        }

        cachedCompositedImage = nil
        needsDisplay = true
    }

    private func invertImageColors() {
        guard let original = screenshotImage,
            let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        let prevImage = original.copy() as! NSImage
        undoStack.append(.imageTransform(previousImage: prevImage, annotationOffsets: []))
        redoStack.removeAll()

        let ciImage = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIColorInvert") else { return }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return }

        let ciCtx = CIContext()
        guard let inverted = ciCtx.createCGImage(output, from: output.extent) else { return }

        screenshotImage = NSImage(cgImage: inverted, size: original.size)
        cachedCompositedImage = nil
        needsDisplay = true
    }

    // MARK: - Snap/Alignment Guides

    /// Collect all snap target X and Y values from the selection rect and existing annotations.
    private func collectSnapTargets(excluding: Annotation? = nil) -> (xs: [CGFloat], ys: [CGFloat])
    {
        var xs: [CGFloat] = []
        var ys: [CGFloat] = []

        // Selection rect edges and center
        xs += [selectionRect.minX, selectionRect.midX, selectionRect.maxX]
        ys += [selectionRect.minY, selectionRect.midY, selectionRect.maxY]

        // Existing annotation bounding rects
        for ann in annotations where ann !== excluding {
            let r = ann.boundingRect
            guard r.width > 0 || r.height > 0 else { continue }
            xs += [r.minX, r.midX, r.maxX]
            ys += [r.minY, r.midY, r.maxY]
        }

        return (xs, ys)
    }

    /// Snap a point's X and Y to the nearest target within threshold. Returns snapped point and sets guide lines.
    func snapPoint(_ point: NSPoint, excluding: Annotation? = nil) -> NSPoint {
        guard snapGuidesEnabled else {
            snapGuideX = nil
            snapGuideY = nil
            return point
        }

        let (xs, ys) = collectSnapTargets(excluding: excluding)
        var result = point
        snapGuideX = nil
        snapGuideY = nil

        // Snap X
        var bestDx: CGFloat = snapThreshold + 1
        for tx in xs {
            let d = abs(point.x - tx)
            if d < bestDx {
                bestDx = d
                result.x = tx
                snapGuideX = tx
            }
        }
        if bestDx > snapThreshold {
            snapGuideX = nil
            result.x = point.x
        }

        // Snap Y
        var bestDy: CGFloat = snapThreshold + 1
        for ty in ys {
            let d = abs(point.y - ty)
            if d < bestDy {
                bestDy = d
                result.y = ty
                snapGuideY = ty
            }
        }
        if bestDy > snapThreshold {
            snapGuideY = nil
            result.y = point.y
        }

        return result
    }

    /// Snap a rect (for move operations) — checks all edges and center against targets.
    /// Returns the delta adjustment needed.
    private func snapRectDelta(rect: NSRect, excluding: Annotation? = nil) -> (
        dx: CGFloat, dy: CGFloat
    ) {
        guard snapGuidesEnabled else {
            snapGuideX = nil
            snapGuideY = nil
            return (0, 0)
        }

        let (xs, ys) = collectSnapTargets(excluding: excluding)
        let edgesX = [rect.minX, rect.midX, rect.maxX]
        let edgesY = [rect.minY, rect.midY, rect.maxY]

        snapGuideX = nil
        snapGuideY = nil
        var bestDx: CGFloat = snapThreshold + 1
        var snapDx: CGFloat = 0
        var bestDy: CGFloat = snapThreshold + 1
        var snapDy: CGFloat = 0

        for ex in edgesX {
            for tx in xs {
                let d = abs(ex - tx)
                if d < bestDx {
                    bestDx = d
                    snapDx = tx - ex
                    snapGuideX = tx
                }
            }
        }
        if bestDx > snapThreshold {
            snapGuideX = nil
            snapDx = 0
        }

        for ey in edgesY {
            for ty in ys {
                let d = abs(ey - ty)
                if d < bestDy {
                    bestDy = d
                    snapDy = ty - ey
                    snapGuideY = ty
                }
            }
        }
        if bestDy > snapThreshold {
            snapGuideY = nil
            snapDy = 0
        }

        return (snapDx, snapDy)
    }

    /// Draw snap guide lines (called from draw after annotations, before toolbars).
    private func drawSnapGuides() {
        guard snapGuidesEnabled else { return }

        let guideColor = NSColor.systemCyan.withAlphaComponent(0.6)
        guideColor.setStroke()

        if let gx = snapGuideX {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: gx, y: selectionRect.minY))
            line.line(to: NSPoint(x: gx, y: selectionRect.maxY))
            line.lineWidth = 0.5
            let pattern: [CGFloat] = [4, 3]
            line.setLineDash(pattern, count: 2, phase: 0)
            line.stroke()
        }

        if let gy = snapGuideY {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: selectionRect.minX, y: gy))
            line.line(to: NSPoint(x: selectionRect.maxX, y: gy))
            line.lineWidth = 0.5
            let pattern: [CGFloat] = [4, 3]
            line.setLineDash(pattern, count: 2, phase: 0)
            line.stroke()
        }
    }

    // MARK: - Auto Measure

    /// Update the auto-measure live preview based on cursor position.
    /// Called on keyDown repeat and mouseMoved while key is held.
    private func updateAutoMeasurePreview() {
        let vertical = autoMeasureVertical
        autoMeasurePreview = computeAutoMeasure(vertical: vertical)
        needsDisplay = true
    }

    /// Compute an auto-measure annotation from the cursor position along a vertical or horizontal axis
    /// by scanning outward until the pixel color changes significantly.
    private func computeAutoMeasure(vertical: Bool) -> Annotation? {
        guard let screenshot = screenshotImage,
            let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        guard let window = window else { return nil }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let viewPoint = convert(windowPoint, from: nil)
        let canvasPoint = viewToCanvas(viewPoint)

        let drawRect = captureDrawRect
        let normX = (canvasPoint.x - drawRect.minX) / drawRect.width
        let normY = (canvasPoint.y - drawRect.minY) / drawRect.height

        let pixelX = Int(normX * CGFloat(cgImage.width))
        let pixelY = Int((1.0 - normY) * CGFloat(cgImage.height))

        guard pixelX >= 0, pixelX < cgImage.width, pixelY >= 0, pixelY < cgImage.height else {
            return nil
        }

        let w = cgImage.width
        let h = cgImage.height
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }

        let ptr = data.assumingMemoryBound(to: UInt8.self)

        func pixelAt(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let offset = (y * w + x) * 4
            return (ptr[offset], ptr[offset + 1], ptr[offset + 2])
        }

        func colorDiff(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8)) -> Int {
            abs(Int(a.0) - Int(b.0)) + abs(Int(a.1) - Int(b.1)) + abs(Int(a.2) - Int(b.2))
        }

        let refColor = pixelAt(pixelX, pixelY)
        let threshold = 30

        func toCanvas(px: Int, py: Int) -> NSPoint {
            let nx = CGFloat(px) / CGFloat(w)
            let ny = 1.0 - CGFloat(py) / CGFloat(h)
            return NSPoint(
                x: drawRect.minX + nx * drawRect.width,
                y: drawRect.minY + ny * drawRect.height)
        }

        var startPx: Int
        var endPx: Int

        if vertical {
            startPx = pixelY
            for py in stride(from: pixelY - 1, through: 0, by: -1) {
                if colorDiff(refColor, pixelAt(pixelX, py)) > threshold { break }
                startPx = py
            }
            endPx = pixelY
            for py in (pixelY + 1)..<h {
                if colorDiff(refColor, pixelAt(pixelX, py)) > threshold { break }
                endPx = py
            }
            let p1 = toCanvas(px: pixelX, py: startPx)
            let p2 = toCanvas(px: pixelX, py: endPx)
            let ann = Annotation(
                tool: .measure, startPoint: p1, endPoint: p2,
                color: annotationColor, strokeWidth: currentStrokeWidth)
            ann.measureInPoints = currentMeasureInPoints
            return ann
        } else {
            startPx = pixelX
            for px in stride(from: pixelX - 1, through: 0, by: -1) {
                if colorDiff(refColor, pixelAt(px, pixelY)) > threshold { break }
                startPx = px
            }
            endPx = pixelX
            for px in (pixelX + 1)..<w {
                if colorDiff(refColor, pixelAt(px, pixelY)) > threshold { break }
                endPx = px
            }
            let p1 = toCanvas(px: startPx, py: pixelY)
            let p2 = toCanvas(px: endPx, py: pixelY)
            let ann = Annotation(
                tool: .measure, startPoint: p1, endPoint: p2,
                color: annotationColor, strokeWidth: currentStrokeWidth)
            ann.measureInPoints = currentMeasureInPoints
            return ann
        }
    }

    // MARK: - Marker Cursor Preview

    private func drawCropPreview() {
        let dimColor = NSColor.black.withAlphaComponent(0.4)
        dimColor.setFill()
        NSBezierPath(
            rect: NSRect(
                x: selectionRect.minX, y: cropDragRect.maxY,
                width: selectionRect.width, height: selectionRect.maxY - cropDragRect.maxY)
        ).fill()
        NSBezierPath(
            rect: NSRect(
                x: selectionRect.minX, y: selectionRect.minY,
                width: selectionRect.width, height: cropDragRect.minY - selectionRect.minY)
        ).fill()
        NSBezierPath(
            rect: NSRect(
                x: selectionRect.minX, y: cropDragRect.minY,
                width: cropDragRect.minX - selectionRect.minX, height: cropDragRect.height)
        ).fill()
        NSBezierPath(
            rect: NSRect(
                x: cropDragRect.maxX, y: cropDragRect.minY,
                width: selectionRect.maxX - cropDragRect.maxX, height: cropDragRect.height)
        ).fill()
    }

    private func drawMarkerCursorPreview(at center: NSPoint) {
        let radius = (currentMarkerSize * 6) / 2
        let circleRect = NSRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let path = NSBezierPath(ovalIn: circleRect)
        // Fill with marker color at marker opacity
        currentColor.withAlphaComponent(0.35).setFill()
        path.fill()
        // Thin border so the circle is visible on any background
        currentColor.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 1.0
        path.stroke()
    }

    // MARK: - Loupe Preview

    private func drawLoupePreview(at center: NSPoint) {
        guard let screenshot = screenshotImage, let context = NSGraphicsContext.current else {
            return
        }
        let size = currentLoupeSize
        let squareRect = NSRect(
            x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        let magnification: CGFloat = 2.0

        context.saveGraphicsState()
        context.cgContext.setAlpha(0.75)

        // Clip to circle
        let path = NSBezierPath(ovalIn: squareRect)
        path.addClip()

        // Draw magnified region directly from screenshot (no intermediate image)
        let srcSize = size / magnification
        let srcRect = NSRect(
            x: center.x - srcSize / 2, y: center.y - srcSize / 2, width: srcSize, height: srcSize)
        let imgSize = screenshot.size
        let drawRect = captureDrawRect
        let scaleX = imgSize.width / drawRect.width
        let scaleY = imgSize.height / drawRect.height
        let fromRect = NSRect(
            x: (srcRect.origin.x - drawRect.origin.x) * scaleX,
            y: (srcRect.origin.y - drawRect.origin.y) * scaleY,
            width: srcRect.width * scaleX, height: srcRect.height * scaleY)
        screenshot.draw(in: squareRect, from: fromRect, operation: .copy, fraction: 1.0)

        // Simple border
        NSColor.white.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 3
        path.stroke()

        context.restoreGraphicsState()
    }

    // MARK: - Zoom helpers

    /// Convert a canvas-space point to view-space (reverse of viewToCanvas).
    func canvasToView(_ p: NSPoint) -> NSPoint {
        if isInsideScrollView { return p }
        var q = p
        // Apply zoom
        if zoomLevel != 1.0 || zoomAnchorCanvas != .zero || zoomAnchorView != .zero {
            q = NSPoint(
                x: zoomAnchorView.x + (p.x - zoomAnchorCanvas.x) * zoomLevel,
                y: zoomAnchorView.y + (p.y - zoomAnchorCanvas.y) * zoomLevel
            )
        }

        return q
    }

    /// Convert a point in view space to canvas (annotation) space by reversing the zoom transform.
    func viewToCanvas(_ p: NSPoint) -> NSPoint {
        if isInsideScrollView { return p }
        var q = adjustPointForEditor(p)
        if zoomLevel == 1.0 && zoomAnchorCanvas == .zero && zoomAnchorView == .zero { return q }
        guard zoomAnchorCanvas != .zero || zoomAnchorView != .zero else { return q }
        return NSPoint(
            x: zoomAnchorCanvas.x + (q.x - zoomAnchorView.x) / zoomLevel,
            y: zoomAnchorCanvas.y + (q.y - zoomAnchorView.y) / zoomLevel
        )
    }

    func applyZoomTransform(to context: NSGraphicsContext) {
        if isInsideScrollView { return }
        if zoomLevel == 1.0 && zoomAnchorCanvas == .zero && zoomAnchorView == .zero { return }
        guard zoomAnchorCanvas != .zero || zoomAnchorView != .zero else { return }
        let cgCtx = context.cgContext
        // screen = anchorView + (canvas - anchorCanvas) * zoom
        cgCtx.translateBy(
            x: zoomAnchorView.x - zoomAnchorCanvas.x * zoomLevel,
            y: zoomAnchorView.y - zoomAnchorCanvas.y * zoomLevel)
        cgCtx.scaleBy(x: zoomLevel, y: zoomLevel)
    }

    /// Apply editor canvas offset + zoom transform. Use this for all canvas-space drawing.
    private func applyCanvasTransform(to context: NSGraphicsContext) {
        applyEditorTransform(to: context)
        applyZoomTransform(to: context)
    }

    /// Set zoom level, pinning the given view-space cursor point in place.
    private func setZoom(_ level: CGFloat, cursorView: NSPoint) {
        // Canvas point currently under cursor (before zoom change)
        let canvasUnderCursor = viewToCanvas(cursorView)
        zoomLevel = max(zoomMin, min(zoomMax, level))
        // After zoom change, pin that canvas point to the cursor's view position.
        // because applyZoomTransform runs after the editor translate.
        zoomAnchorCanvas = canvasUnderCursor
        zoomAnchorView = cursorView
        clampZoomAnchor()
        showZoomLabel()
        needsDisplay = true
    }

    /// Reset zoom to 1× (no transform).
    private func resetZoom() {
        zoomLevel = 1.0
        zoomAnchorCanvas = .zero
        zoomAnchorView = .zero
    }

    /// Crop the screenshot to `viewRect` (view-space, within selectionRect),
    /// translate all annotations accordingly, and reset zoom.
    private func commitCrop(viewRect: NSRect) {
        guard let originalImage = screenshotImage,
            let cgOriginal = originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // viewRect is already in canvas space (cropDragRect uses canvas coords).
        let canvasRect = viewRect

        // Map canvas rect → CGImage pixel rect.
        // CGImage uses top-left origin; canvas uses bottom-left.
        let pointsW = originalImage.size.width
        let pointsH = originalImage.size.height
        let pixScale = CGFloat(cgOriginal.width) / pointsW

        let normX = (canvasRect.minX - selectionRect.minX) / selectionRect.width
        let normY = (canvasRect.minY - selectionRect.minY) / selectionRect.height
        let normW = canvasRect.width / selectionRect.width
        let normH = canvasRect.height / selectionRect.height

        let cgW = CGFloat(cgOriginal.width)
        let cgH = CGFloat(cgOriginal.height)
        let cgPixelRect = CGRect(
            x: max(0, normX * cgW),
            y: max(0, (1.0 - normY - normH) * cgH),  // flip Y for CGImage top-left origin
            width: min(normW * cgW, cgW - max(0, normX * cgW)),
            height: min(normH * cgH, cgH - max(0, (1.0 - normY - normH) * cgH))
        )

        guard cgPixelRect.width > 0, cgPixelRect.height > 0,
            let croppedCG = cgOriginal.cropping(to: cgPixelRect)
        else { return }

        // Save state for undo before modifying
        let prevImage = originalImage.copy() as! NSImage
        undoStack.append(.imageTransform(previousImage: prevImage, annotationOffsets: []))
        redoStack.removeAll()

        let dx = selectionRect.minX - canvasRect.minX
        let dy = selectionRect.minY - canvasRect.minY
        for ann in annotations { ann.move(dx: dx, dy: dy) }

        // Set NSImage size in points (not pixels) to preserve Retina scale
        let croppedPointSize = NSSize(
            width: CGFloat(croppedCG.width) / pixScale,
            height: CGFloat(croppedCG.height) / pixScale)
        screenshotImage = NSImage(cgImage: croppedCG, size: croppedPointSize)

        // Update selectionRect to match new image size
        selectionRect = NSRect(origin: .zero, size: croppedPointSize)

        cachedCompositedImage = nil

        // Resize view frame to match new image size (scroll view re-centers automatically)
        if isInsideScrollView {
            frame.size = croppedPointSize
            enclosingScrollView?.magnification = 1.0
            // Update top bar size label
            if let topBar = chromeParentView?.subviews.compactMap({ $0 as? EditorTopBarView }).first
            {
                topBar.updateSizeLabel(width: croppedCG.width, height: croppedCG.height)
                topBar.updateZoom(1.0)
            }
        } else {
            resetZoom()
        }
        currentTool = .arrow
        rebuildToolbarLayout()
        needsDisplay = true
    }

    /// Clamp zoomAnchorView.
    ///
    /// Transform: screenPos = zoomAnchorView + (canvasPos - zoomAnchorCanvas) * zoom
    ///
    /// zoom > 1×: keep all four image edges inside selectionRect (no empty border visible).
    /// zoom < 1×: allow free panning but keep at least `margin` screen-space pixels of the
    ///            image visible on each side, so the user never scrolls completely off canvas.
    private func clampZoomAnchor() {
        // At 1x, no clamping needed (image fills the view exactly)
        if zoomLevel == 1.0 { return }
        let r = selectionRect
        let z = zoomLevel
        let ac = zoomAnchorCanvas
        var av = zoomAnchorView

        if z > 1.0 {
            // Overlay zoom-in: edges must stay covered.
            let maxAVx = r.minX - (r.minX - ac.x) * z
            let minAVx = r.maxX - (r.maxX - ac.x) * z
            av.x = max(minAVx, min(maxAVx, av.x))

            let maxAVy = r.minY - (r.minY - ac.y) * z
            let minAVy = r.maxY - (r.maxY - ac.y) * z
            av.y = max(minAVy, min(maxAVy, av.y))
        }

        zoomAnchorView = av
    }

    private func showZoomLabel() {
        zoomLabelOpacity = 1.0
        zoomFadeTimer?.invalidate()
        zoomFadeTimer = nil
        if zoomLevel == 1.0 {
            // Back at 1× — fade out after a short pause
            zoomFadeTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) {
                [weak self] _ in
                self?.fadeOutZoomLabel()
            }
        }
        // While zoomed ≠ 1×: stay fully visible, no timer
    }

    private func fadeOutZoomLabel() {
        // Don't fade if we're zoomed (either direction)
        guard zoomLevel == 1.0 else { return }
        zoomFadingOut = true
        let step: CGFloat = 0.08
        Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] t in
            guard let self = self else {
                t.invalidate()
                return
            }
            // Abort fade if user zoomed during the animation
            if self.zoomLevel != 1.0 {
                self.zoomLabelOpacity = 1.0
                self.zoomFadingOut = false
                t.invalidate()
                self.needsDisplay = true
                return
            }
            self.zoomLabelOpacity -= step
            if self.zoomLabelOpacity <= 0 {
                self.zoomLabelOpacity = 0
                self.zoomFadingOut = false
                t.invalidate()
            }
            self.needsDisplay = true
        }
    }

    // MARK: - Annotation Controls

    private func drawAnnotationControls(for annotation: Annotation) {
        // Arrow, line, and measure: show only 2 endpoint handles, no bounding box
        if annotation.tool == .arrow || annotation.tool == .line || annotation.tool == .measure {
            let pts = annotation.waypoints
            let s: CGFloat = 10
            let sm: CGFloat = 8

            annotationResizeHandleRects = []

            // Draw guide path through all waypoints
            if pts.count > 2 {
                let guidePath = NSBezierPath()
                guidePath.lineWidth = 1
                guidePath.setLineDash([3, 4], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.35).setStroke()
                guidePath.move(to: pts[0])
                for i in 1..<pts.count { guidePath.line(to: pts[i]) }
                guidePath.stroke()
            } else if annotation.controlPoint != nil {
                let midPt = annotation.controlPoint!
                let guidePath = NSBezierPath()
                guidePath.lineWidth = 1
                guidePath.setLineDash([3, 4], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.35).setStroke()
                guidePath.move(to: annotation.startPoint)
                guidePath.line(to: midPt)
                guidePath.line(to: annotation.endPoint)
                guidePath.stroke()
            }

            // Endpoint handles (start = .bottomLeft, end = .topRight)
            let startRect = NSRect(
                x: pts.first!.x - s / 2, y: pts.first!.y - s / 2, width: s, height: s)
            let endRect = NSRect(
                x: pts.last!.x - s / 2, y: pts.last!.y - s / 2, width: s, height: s)
            annotationResizeHandleRects.append((.bottomLeft, startRect))
            annotationResizeHandleRects.append((.topRight, endRect))

            for rect in [startRect, endRect] {
                ToolbarLayout.accentColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1.5
                border.stroke()
            }

            // Intermediate anchor handles — use .none as handle ID since we identify
            // them by array index (annotationResizeAnchorIndex), not by ResizeHandle enum.
            if pts.count > 2 {
                for i in 1..<(pts.count - 1) {
                    let handleID: ResizeHandle = .none
                    let midRect = NSRect(
                        x: pts[i].x - sm / 2, y: pts[i].y - sm / 2, width: sm, height: sm)
                    annotationResizeHandleRects.append((handleID, midRect))
                    NSColor.white.withAlphaComponent(0.9).setFill()
                    NSBezierPath(ovalIn: midRect).fill()
                    ToolbarLayout.accentColor.setStroke()
                    let midBorder = NSBezierPath(ovalIn: midRect.insetBy(dx: 0.5, dy: 0.5))
                    midBorder.lineWidth = 1.5
                    midBorder.stroke()
                }
            } else {
                // Legacy single bend handle (or visual midpoint)
                let midPt =
                    annotation.controlPoint
                    ?? NSPoint(
                        x: (annotation.startPoint.x + annotation.endPoint.x) / 2,
                        y: (annotation.startPoint.y + annotation.endPoint.y) / 2
                    )
                let midRect = NSRect(
                    x: midPt.x - sm / 2, y: midPt.y - sm / 2, width: sm, height: sm)
                annotationResizeHandleRects.append((.top, midRect))
                NSColor.white.withAlphaComponent(0.9).setFill()
                NSBezierPath(ovalIn: midRect).fill()
                ToolbarLayout.accentColor.setStroke()
                let midBorder = NSBezierPath(ovalIn: midRect.insetBy(dx: 0.5, dy: 0.5))
                midBorder.lineWidth = 1.5
                midBorder.stroke()
            }

            // Delete button near endPoint
            let btnSize: CGFloat = 20
            let deleteRect = NSRect(
                x: annotation.endPoint.x + 8, y: annotation.endPoint.y + 2, width: btnSize,
                height: btnSize)
            annotationDeleteButtonRect = deleteRect
            NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: deleteRect).fill()
            let xAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: NSColor.white,
            ]
            let xStr = "×" as NSString
            let xSize = xStr.size(withAttributes: xAttrs)
            xStr.draw(
                at: NSPoint(
                    x: deleteRect.midX - xSize.width / 2, y: deleteRect.midY - xSize.height / 2),
                withAttributes: xAttrs)
            annotationEditButtonRect = .zero
            return
        }

        let baseRect: NSRect
        switch annotation.tool {
        case .pencil, .marker:
            guard let points = annotation.points, !points.isEmpty else { return }
            var minX = CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude
            for p in points {
                minX = min(minX, p.x)
                minY = min(minY, p.y)
                maxX = max(maxX, p.x)
                maxY = max(maxY, p.y)
            }
            // Expand by the actual painted stroke radius so the box matches the visible stroke
            let strokeRadius =
                (annotation.tool == .marker ? annotation.strokeWidth * 6 : annotation.strokeWidth)
                / 2
            baseRect = NSRect(
                x: minX - strokeRadius, y: minY - strokeRadius,
                width: maxX - minX + strokeRadius * 2, height: maxY - minY + strokeRadius * 2)
        case .text:
            // startPoint = top-left, endPoint = bottom-right (set at commit time)
            if annotation.endPoint != annotation.startPoint {
                baseRect = annotation.boundingRect
            } else {
                // Legacy: recompute from attributed string size
                let text =
                    annotation.attributedText
                    ?? annotation.text.map {
                        NSAttributedString(
                            string: $0,
                            attributes: [.font: NSFont.systemFont(ofSize: annotation.fontSize)])
                    }
                let size = text?.size() ?? NSSize(width: 50, height: 20)
                baseRect = NSRect(origin: annotation.startPoint, size: size)
            }
        case .number:
            let radius = 8 + annotation.strokeWidth * 3
            let circleRect = NSRect(
                x: annotation.startPoint.x - radius, y: annotation.startPoint.y - radius,
                width: radius * 2, height: radius * 2)
            baseRect = circleRect.union(
                NSRect(
                    x: annotation.endPoint.x - 2, y: annotation.endPoint.y - 2, width: 4, height: 4)
            )
        default:
            let strokePad = annotation.strokeWidth / 2
            baseRect = annotation.boundingRect.insetBy(dx: -strokePad, dy: -strokePad)
        }

        let padded = baseRect.insetBy(dx: -4, dy: -4)

        // Apply annotation rotation to controls
        if annotation.rotation != 0 && annotation.supportsRotation {
            let center = NSPoint(x: baseRect.midX, y: baseRect.midY)
            let xform = NSAffineTransform()
            xform.translateX(by: center.x, yBy: center.y)
            xform.rotate(byRadians: annotation.rotation)
            xform.translateX(by: -center.x, yBy: -center.y)
            NSGraphicsContext.current?.cgContext.saveGState()
            xform.concat()
        }

        // Draw dashed border
        let path = NSBezierPath(roundedRect: padded, xRadius: 3, yRadius: 3)
        path.lineWidth = 1.5
        path.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.8).setStroke()
        path.stroke()
        ToolbarLayout.accentColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: padded, xRadius: 3, yRadius: 3).fill()

        // Draw resize handles (8 positions) — loupe/pencil/marker don't support resize
        if annotation.tool != .loupe && annotation.tool != .pencil && annotation.tool != .marker {
            let handles = annotationAllHandleRects(for: padded)
            annotationResizeHandleRects = handles
            for (_, rect) in handles {
                ToolbarLayout.accentColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
                NSColor.white.withAlphaComponent(0.8).setStroke()
                let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1
                border.stroke()
            }
        } else {
            annotationResizeHandleRects = []
        }

        // Restore rotation transform before drawing rotation handle (in screen space)
        if annotation.rotation != 0 && annotation.supportsRotation {
            NSGraphicsContext.current?.cgContext.restoreGState()
        }

        // Rotation handle (above top-center)
        annotationRotateHandleRect = .zero
        if annotation.supportsRotation {
            let center = NSPoint(x: padded.midX, y: padded.midY)
            let handleDist: CGFloat = padded.height / 2 + 24
            // Rotate the handle position by the annotation's current rotation
            let handleX = center.x - handleDist * sin(annotation.rotation)
            let handleY = center.y + handleDist * cos(annotation.rotation)
            let hs: CGFloat = 14
            let rotRect = NSRect(x: handleX - hs / 2, y: handleY - hs / 2, width: hs, height: hs)
            annotationRotateHandleRect = rotRect

            // Connecting line from top-center of box to handle
            let topCenterX = center.x - (padded.height / 2 + 2) * sin(annotation.rotation)
            let topCenterY = center.y + (padded.height / 2 + 2) * cos(annotation.rotation)
            let connPath = NSBezierPath()
            connPath.lineWidth = 1
            connPath.setLineDash([3, 3], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.5).setStroke()
            connPath.move(to: NSPoint(x: topCenterX, y: topCenterY))
            connPath.line(to: NSPoint(x: handleX, y: handleY))
            connPath.stroke()

            // Draw rotate icon circle
            NSColor(white: 0.2, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: rotRect).fill()
            NSColor.white.withAlphaComponent(0.8).setStroke()
            NSBezierPath(ovalIn: rotRect.insetBy(dx: 0.5, dy: 0.5)).stroke()

            // Draw rotate arrow icon — draw into a fixed square centered in the circle
            let iconSize: CGFloat = 10
            let iconRect = NSRect(
                x: rotRect.midX - iconSize / 2, y: rotRect.midY - iconSize / 2,
                width: iconSize, height: iconSize)
            let cfg = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .bold)
            if let img = NSImage(
                systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90",
                accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            {
                let tinted = NSImage(size: img.size, flipped: false) { rect in
                    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                    NSColor.white.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(
                    in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                    respectFlipped: true, hints: nil)
            }
        }

        // Delete button (X) at top-right outside the box
        let btnSize: CGFloat = 20
        let deleteRect = NSRect(
            x: padded.maxX + 4, y: padded.maxY - btnSize, width: btnSize, height: btnSize)
        annotationDeleteButtonRect = deleteRect
        NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 0.9).setFill()
        NSBezierPath(ovalIn: deleteRect).fill()
        let xAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor.white,
        ]
        let xStr = "×" as NSString
        let xSize = xStr.size(withAttributes: xAttrs)
        xStr.draw(
            at: NSPoint(
                x: deleteRect.midX - xSize.width / 2, y: deleteRect.midY - xSize.height / 2),
            withAttributes: xAttrs)

        // Edit button (pencil) for text annotations
        if annotation.tool == .text {
            let editRect = NSRect(
                x: padded.maxX + 4, y: padded.maxY - btnSize * 2 - 4, width: btnSize,
                height: btnSize)
            annotationEditButtonRect = editRect
            NSColor(white: 0.3, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: editRect).fill()
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            if let img = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfig)
            {
                let tinted = NSImage(size: img.size, flipped: false) { rect in
                    img.draw(in: rect)
                    NSColor.white.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                let imgRect = NSRect(
                    x: editRect.midX - img.size.width / 2, y: editRect.midY - img.size.height / 2,
                    width: img.size.width, height: img.size.height)
                tinted.draw(in: imgRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        } else {
            annotationEditButtonRect = .zero
        }
    }

    private func annotationAllHandleRects(for rect: NSRect) -> [(ResizeHandle, NSRect)] {
        let s: CGFloat = 8
        let r = rect
        return [
            (.topLeft, NSRect(x: r.minX - s / 2, y: r.maxY - s / 2, width: s, height: s)),
            (.topRight, NSRect(x: r.maxX - s / 2, y: r.maxY - s / 2, width: s, height: s)),
            (.bottomLeft, NSRect(x: r.minX - s / 2, y: r.minY - s / 2, width: s, height: s)),
            (.bottomRight, NSRect(x: r.maxX - s / 2, y: r.minY - s / 2, width: s, height: s)),
            (.top, NSRect(x: r.midX - s / 2, y: r.maxY - s / 2, width: s, height: s)),
            (.bottom, NSRect(x: r.midX - s / 2, y: r.minY - s / 2, width: s, height: s)),
            (.left, NSRect(x: r.minX - s / 2, y: r.midY - s / 2, width: s, height: s)),
            (.right, NSRect(x: r.maxX - s / 2, y: r.midY - s / 2, width: s, height: s)),
        ]
    }

    // MARK: - Overlay Error

    func showOverlayError(_ message: String) {
        overlayErrorTimer?.invalidate()
        overlayErrorMessage = message
        needsDisplay = true
        overlayErrorTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) {
            [weak self] _ in
            self?.overlayErrorMessage = nil
            self?.needsDisplay = true
        }
    }


    // MARK: - Barcode / QR Detection

    func scheduleBarcodeDetection() {
        barcodeDetector.cancel()
        needsDisplay = true
        guard state == .selected, let screenshot = screenshotImage else { return }
        barcodeDetector.scan(
            image: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect
        ) { [weak self] in
            self?.needsDisplay = true
        }
    }


    // MARK: - Toolbar Layout

    /// Rebuild toolbar button content. Call when tool, color, or state changes — NOT on every draw.
    func rebuildToolbarLayout() {
        let movableAnnotations = annotations.contains { $0.isMovable }
        bottomButtons = ToolbarLayout.bottomButtons(
            selectedTool: currentTool, selectedColor: currentColor,
            beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex,
            hasAnnotations: movableAnnotations, isRecording: isRecording, isAnnotating: isAnnotating
        )
        if showBeautifyInOptionsRow {
            for i in bottomButtons.indices {
                if case .tool = bottomButtons[i].action {
                    bottomButtons[i].isSelected = false
                } else if case .beautify = bottomButtons[i].action {
                    bottomButtons[i].isSelected = true
                }
            }
        }
        rightButtons = ToolbarLayout.rightButtons(
            beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex,
            hasAnnotations: movableAnnotations, translateEnabled: translateEnabled,
            isRecording: isRecording, isCapturingVideo: isCapturingVideo,
            isAnnotating: isAnnotating, isEditorMode: isEditorMode)

        // Create strip views if needed — add to chrome parent (window content) when in scroll view
        let parent = chromeParentView ?? self
        if bottomStripView == nil {
            let strip = ToolbarStripView(orientation: .horizontal)
            parent.addSubview(strip)
            bottomStripView = strip
        }
        if rightStripView == nil {
            let strip = ToolbarStripView(orientation: .vertical)
            parent.addSubview(strip)
            rightStripView = strip
        }

        bottomStripView?.setButtons(bottomButtons)
        bottomStripView?.onClick = { [weak self] action in self?.handleToolbarAction(action) }
        bottomStripView?.onRightClick = { [weak self] action, view in
            self?.handleToolbarButtonRightClick(action, anchorView: view)
        }
        bottomStripView?.onHover = { [weak self] action, hovered in
            self?.handleToolbarButtonHover(action, hovered: hovered, strip: self?.bottomStripView)
        }
        rightStripView?.setButtons(rightButtons)
        rightStripView?.onClick = { [weak self] action in self?.handleToolbarAction(action) }
        // Move button needs onMouseDown for press-and-drag (synchronous tracking loop)
        for bv in rightStripView?.buttonViews ?? [] {
            if case .moveSelection = bv.action {
                bv.onMouseDown = { [weak self] _ in self?.handleToolbarAction(.moveSelection) }
            }
        }
        rightStripView?.onRightClick = { [weak self] action, view in
            self?.handleToolbarButtonRightClick(action, anchorView: view)
        }
        rightStripView?.onHover = { [weak self] action, hovered in
            self?.handleToolbarButtonHover(action, hovered: hovered, strip: self?.rightStripView)
        }

        // Rebuild options row content
        if toolHasOptionsRow {
            if toolOptionsRowView == nil {
                let row = ToolOptionsRowView()
                row.overlayView = self
                parent.addSubview(row)
                toolOptionsRowView = row
            }
            toolOptionsRowView?.rebuild(for: currentTool)
        }

        repositionToolbars()

        // Update recording toolbar panel if active
        if isRecording && recordingToolbarPanel != nil {
            showRecordingToolbar()
        }
    }

    /// Reposition toolbar strips based on current selection/bounds. Cheap — safe to call from draw().
    private func repositionToolbars() {
        guard let bottomStrip = bottomStripView, let rightStrip = rightStripView else { return }

        let visible = showToolbars && state == .selected && !isScrollCapturing
        let bottomHasButtons = bottomStrip.buttonViews.count > 0
        bottomStrip.isHidden = !visible || !bottomHasButtons
        // Right strip hidden during recording — RecordingToolbarPanel handles it
        rightStrip.isHidden = !visible || isRecording
        toolOptionsRowView?.isHidden = !visible || !toolHasOptionsRow || !bottomHasButtons
        guard visible else { return }

        // Anchor rect: beautify-expanded when active, selection otherwise
        let config = beautifyConfig
        let bPad = config.padding
        let titleBarH: CGFloat = config.mode == .window ? 28 : 0
        let expandedAnchor = NSRect(
            x: selectionRect.minX - bPad, y: selectionRect.minY - bPad,
            width: selectionRect.width + bPad * 2,
            height: selectionRect.height + titleBarH + bPad * 2)
        let anchorRect: NSRect
        if beautifyToolbarAnimProgress < 1.0 {
            let t = beautifyToolbarAnimProgress
            let eased = 1.0 - (1.0 - t) * (1.0 - t)
            let fromRect = beautifyToolbarAnimTarget ? selectionRect : expandedAnchor
            let toRect = beautifyToolbarAnimTarget ? expandedAnchor : selectionRect
            anchorRect = NSRect(
                x: fromRect.minX + (toRect.minX - fromRect.minX) * eased,
                y: fromRect.minY + (toRect.minY - fromRect.minY) * eased,
                width: fromRect.width + (toRect.width - fromRect.width) * eased,
                height: fromRect.height + (toRect.height - fromRect.height) * eased
            )
        } else if beautifyEnabled && !isScrollCapturing && !isRecording {
            anchorRect = expandedAnchor
        } else {
            anchorRect = selectionRect
        }

        let rightSize = rightStrip.frame.size

        let bottomSize = bottomStrip.frame.size

        if isEditorMode {
            let cb = chromeParentView?.bounds ?? bounds
            bottomStrip.frame.origin = NSPoint(x: cb.midX - bottomSize.width / 2, y: 6)
            bottomStrip.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
            rightStrip.frame.origin = NSPoint(
                x: cb.maxX - rightSize.width - 6, y: cb.maxY - rightSize.height - 36)
            rightStrip.autoresizingMask = [.minXMargin, .minYMargin]
        } else {
            // Total space needed below selection: bottom bar + gap + options row (always assumed present)
            let optionsRowH: CGFloat = 38  // rowHeight(34) + gap(4)
            let totalBelowH = bottomSize.height + optionsRowH + 6

            var bx = anchorRect.midX - bottomSize.width / 2

            // Check if the full stack (bar + options row) fits below the selection
            let belowY = anchorRect.minY - bottomSize.height - 6
            let belowFits = (belowY - optionsRowH) >= bounds.minY + 4

            // Check if the full stack fits above the selection
            let aboveY = anchorRect.maxY + optionsRowH + 6
            let aboveFits = (aboveY + bottomSize.height) <= bounds.maxY - 4

            var by: CGFloat
            if belowFits {
                by = belowY
            } else if aboveFits {
                by = aboveY
            } else {
                // Neither fits fully — place inside selection
                by = selectionRect.minY + optionsRowH + 6
                by = max(bounds.minY + optionsRowH + 4, min(by, bounds.maxY - bottomSize.height - 4))
            }

            bx = max(bounds.minX + 4, min(bx, bounds.maxX - bottomSize.width - 4))
            bottomStrip.frame.origin = NSPoint(x: bx, y: by)

            // Right: to the right of selection, flip to left if no room
            let rightMargin: CGFloat = 50
            let rightFitsRight = anchorRect.maxX < bounds.maxX - rightMargin
            let rightFitsLeft = anchorRect.minX > bounds.minX + rightMargin

            var rx: CGFloat
            if rightFitsRight {
                rx = anchorRect.maxX + 6
            } else if rightFitsLeft {
                rx = anchorRect.minX - rightSize.width - 6
            } else {
                // Inside: at the right edge of the selection
                rx = selectionRect.maxX - rightSize.width - 6
            }
            rx = max(bounds.minX + 4, min(rx, bounds.maxX - rightSize.width - 4))

            // Top-align with selection top
            var ry = anchorRect.maxY - rightSize.height
            ry = max(bounds.minY + 4, min(ry, bounds.maxY - rightSize.height - 4))

            // Avoid overlapping bottom bar — shift right bar horizontally if needed
            let bf = bottomStrip.frame
            if bf.width > 0 {
                let rightRect = NSRect(
                    x: rx, y: ry, width: rightSize.width, height: rightSize.height)
                if rightRect.intersects(bf) {
                    rx = bf.maxX + 4
                    rx = max(bounds.minX + 4, min(rx, bounds.maxX - rightSize.width - 4))
                }
            }
            rightStrip.frame.origin = NSPoint(x: rx, y: ry)
        }

        bottomBarRect = bottomStrip.frame
        rightBarRect = rightStrip.frame

        // Position options row — above bottom bar in editor, below in overlay
        if let row = toolOptionsRowView, !row.isHidden {
            row.frame.size.width = bottomBarRect.width
            let rowX = bottomBarRect.minX
            let rowY: CGFloat
            if isEditorMode {
                rowY = bottomBarRect.maxY + 2
            } else {
                rowY = bottomBarRect.minY - row.frame.height - 2
            }
            row.frame.origin = NSPoint(x: rowX, y: rowY)
            if isEditorMode { row.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin] }
        }
    }

    // MARK: - Handle hit testing

    private func allHandleRects() -> [(ResizeHandle, NSRect)] {
        let r = selectionRect
        let s = handleSize
        return [
            (.topLeft, NSRect(x: r.minX - s / 2, y: r.maxY - s / 2, width: s, height: s)),
            (.topRight, NSRect(x: r.maxX - s / 2, y: r.maxY - s / 2, width: s, height: s)),
            (.bottomLeft, NSRect(x: r.minX - s / 2, y: r.minY - s / 2, width: s, height: s)),
            (.bottomRight, NSRect(x: r.maxX - s / 2, y: r.minY - s / 2, width: s, height: s)),
            (.top, NSRect(x: r.midX - s / 2, y: r.maxY - s / 2, width: s, height: s)),
            (.bottom, NSRect(x: r.midX - s / 2, y: r.minY - s / 2, width: s, height: s)),
            (.left, NSRect(x: r.minX - s / 2, y: r.midY - s / 2, width: s, height: s)),
            (.right, NSRect(x: r.maxX - s / 2, y: r.midY - s / 2, width: s, height: s)),
        ]
    }

    private func hitTestHandle(at point: NSPoint) -> ResizeHandle {
        // Use the same hit area as resizeHandleCursor so cursor and click zones match
        let hitPad: CGFloat = 2  // handle rect is already handleSize; expand by 2 to match cursor zone
        // Check corner handles first (they take priority over edges)
        for (handle, rect) in allHandleRects() {
            switch handle {
            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                if rect.insetBy(dx: -hitPad, dy: -hitPad).contains(point) {
                    return handle
                }
            default:
                break
            }
        }

        // Check full edges/borders (not just the handle dots)
        let edgeThickness: CGFloat = 6  // match resizeHandleCursor's edgeT
        let r = selectionRect
        // Top edge
        if NSRect(x: r.minX, y: r.maxY - edgeThickness / 2, width: r.width, height: edgeThickness)
            .contains(point)
        {
            return .top
        }
        // Bottom edge
        if NSRect(x: r.minX, y: r.minY - edgeThickness / 2, width: r.width, height: edgeThickness)
            .contains(point)
        {
            return .bottom
        }
        // Left edge
        if NSRect(x: r.minX - edgeThickness / 2, y: r.minY, width: edgeThickness, height: r.height)
            .contains(point)
        {
            return .left
        }
        // Right edge
        if NSRect(x: r.maxX - edgeThickness / 2, y: r.minY, width: edgeThickness, height: r.height)
            .contains(point)
        {
            return .right
        }

        return .none
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)


        // Note: toolbar strips and options row are routed by hitTest() — they never reach here

        // Control-click = right-click for color sampler (supports BetterTouchTool and other tools
        // that simulate right-click via control-click instead of rightMouseDown)
        if event.modifierFlags.contains(.control) && state == .selected
            && currentTool == .colorSampler
        {
            if let screenshot = screenshotImage,
                let result = sampleColor(from: screenshot, at: viewToCanvas(point))
            {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.hex, forType: .string)
                showOverlayError("Copied \(result.hex)")
                needsDisplay = true
            }
            return
        }

        // Control-click on line/arrow: add anchor point (same as right-click)
        if event.modifierFlags.contains(.control) && state == .selected {
            if let ann = selectedAnnotation ?? hoveredAnnotation,
                ann.tool == .arrow || ann.tool == .line || ann.tool == .measure
            {
                let canvasPoint = viewToCanvas(point)
                if ann.hitTest(point: canvasPoint) {
                    addAnchorPoint(to: ann, at: canvasPoint)
                    cachedCompositedImage = nil
                    needsDisplay = true
                    return
                }
            }
        }

        // Barcode bar button hit-test
        if let action = barcodeDetector.hitTest(point: point) {
            switch action {
            case .dismiss:
                barcodeDetector.cancel()
                needsDisplay = true
            case .open(let url):
                barcodeDetector.cancel()
                needsDisplay = true
                overlayDelegate?.overlayViewDidCancel()
                if let url = URL(string: url) {
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
            case .copy(let text):
                barcodeDetector.cancel()
                needsDisplay = true
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return
        }

        // Editor top bar button clicks
        if handleTopChromeClick(at: point) {
            return
        }

        let isTextEditing = textEditView != nil

        // Check text box resize handles when editing
        if isTextEditing && showToolbars {
            // Check text box resize handles
            if let sv = textEditor.scrollView {
                let hs: CGFloat = 10  // hit area
                let f = sv.frame
                let handles: [(ResizeHandle, NSRect)] = [
                    (
                        .bottomLeft,
                        NSRect(x: f.minX - hs / 2, y: f.minY - hs / 2, width: hs, height: hs)
                    ),
                    (
                        .bottomRight,
                        NSRect(x: f.maxX - hs / 2, y: f.minY - hs / 2, width: hs, height: hs)
                    ),
                    (
                        .topLeft,
                        NSRect(x: f.minX - hs / 2, y: f.maxY - hs / 2, width: hs, height: hs)
                    ),
                    (
                        .topRight,
                        NSRect(x: f.maxX - hs / 2, y: f.maxY - hs / 2, width: hs, height: hs)
                    ),
                    (
                        .bottom,
                        NSRect(x: f.midX - hs / 2, y: f.minY - hs / 2, width: hs, height: hs)
                    ),
                    (.top, NSRect(x: f.midX - hs / 2, y: f.maxY - hs / 2, width: hs, height: hs)),
                    (.left, NSRect(x: f.minX - hs / 2, y: f.midY - hs / 2, width: hs, height: hs)),
                    (.right, NSRect(x: f.maxX - hs / 2, y: f.midY - hs / 2, width: hs, height: hs)),
                ]
                for (handle, rect) in handles {
                    if rect.contains(point) {
                        isResizingTextBox = true
                        textBoxResizeHandle = handle
                        textBoxResizeStart = point
                        textBoxOrigFrame = f
                        return
                    }
                }
            }
            // Clicking on the text editor itself — don't commit
            if let sv = textEditor.scrollView, sv.frame.contains(point) {
                return
            }
        }

        // Don't commit text if clicking on text formatting controls in the options row
        let isTextFormattingClick =
            textEditView != nil && currentTool == .text
            && ((toolOptionsRowView?.frame.contains(point) ?? false))
        if !isTextFormattingClick {
            commitTextFieldIfNeeded()
        }
        commitSizeInputIfNeeded()
        commitZoomInputIfNeeded()

        switch state {
        case .idle:
            // Always start a drag — snap is resolved in mouseUp if no real drag occurred
            selectionStart = point
            selectionRect = NSRect(origin: point, size: .zero)
            state = .selecting
            overlayDelegate?.overlayViewDidBeginSelection()
            needsDisplay = true

        case .selected:
            // Check size label click
            if sizeLabelRect.contains(point) && sizeInputField == nil {
                showSizeInput()
                return
            }
            if let field = sizeInputField, field.frame.contains(point) {
                return  // let the text field handle it
            }

            // Check zoom label click
            if zoomLabelRect.contains(point) && zoomInputField == nil && zoomLabelOpacity > 0 {
                showZoomInput()
                return
            }
            if let field = zoomInputField, field.frame.contains(point) {
                return  // let the text field handle it
            }

            if showToolbars {

            }

            // Check handles (locked during recording, disabled in editor)
            if shouldAllowSelectionResize() {
                let handle = hitTestHandle(at: point)
                if handle != .none {
                    guard !isRecording else { return }
                    isResizingSelection = true
                    resizeHandle = handle
                    return
                }
            }

            // Crop tool drag (use canvas coords so it aligns with the image)
            if currentTool == .crop && pointIsInSelection(point) {
                isCropDragging = true
                cropDragStart = viewToCanvas(point)
                cropDragRect = .zero
                needsDisplay = true
                return
            }

            // Color sampler works anywhere on the screenshot, not just inside selection
            if currentTool == .colorSampler {
                let canvasPoint = viewToCanvas(point)
                startAnnotation(at: canvasPoint)
                return
            }

            // Start annotation (convert to canvas space for zoom).
            // Require the click to be inside the selection rectangle.
            if currentTool != .crop && pointIsInSelection(point) {
                let canvasPoint = viewToCanvas(point)
                startAnnotation(at: canvasPoint)
                return
            }

            // Outside everything - start new selection (locked during recording or editor mode)
            guard shouldAllowNewSelection() else { return }
            showToolbars = false
            annotations.removeAll()
            undoStack.removeAll()
            redoStack.removeAll()
            numberCounter = 0
            resetZoom()
            zoomLabelOpacity = 0.0
            zoomFadeTimer?.invalidate()
            selectionStart = point
            selectionRect = NSRect(origin: point, size: .zero)
            state = .selecting
            overlayDelegate?.overlayViewDidBeginSelection()
            needsDisplay = true

        case .selecting:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Crop drag update (in canvas coords)
        if isCropDragging {
            let canvasPt = viewToCanvas(point)
            let clampedPoint = NSPoint(
                x: max(selectionRect.minX, min(canvasPt.x, selectionRect.maxX)),
                y: max(selectionRect.minY, min(canvasPt.y, selectionRect.maxY))
            )
            let origin = NSPoint(
                x: min(cropDragStart.x, clampedPoint.x), y: min(cropDragStart.y, clampedPoint.y))
            cropDragRect = NSRect(
                origin: origin,
                size: NSSize(
                    width: abs(clampedPoint.x - cropDragStart.x),
                    height: abs(clampedPoint.y - cropDragStart.y)))
            needsDisplay = true
            return
        }

        // Handle text box resize
        if isResizingTextBox, let sv = textEditor.scrollView, let tv = textEditView {
            let dx = point.x - textBoxResizeStart.x
            let dy = point.y - textBoxResizeStart.y
            let orig = textBoxOrigFrame
            var newFrame = orig
            let minW: CGFloat = 60
            let minH: CGFloat = max(28, textEditor.fontSize + 12)

            switch textBoxResizeHandle {
            case .right: newFrame.size.width = max(minW, orig.width + dx)
            case .left:
                newFrame.origin.x = min(orig.maxX - minW, orig.minX + dx)
                newFrame.size.width = orig.maxX - newFrame.minX
            case .top: newFrame.size.height = max(minH, orig.height + dy)
            case .bottom:
                let newMinY = min(orig.maxY - minH, orig.minY + dy)
                newFrame.origin.y = newMinY
                newFrame.size.height = orig.maxY - newMinY
            case .topRight:
                newFrame.size.width = max(minW, orig.width + dx)
                newFrame.size.height = max(minH, orig.height + dy)
            case .topLeft:
                newFrame.origin.x = min(orig.maxX - minW, orig.minX + dx)
                newFrame.size.width = orig.maxX - newFrame.minX
                newFrame.size.height = max(minH, orig.height + dy)
            case .bottomRight:
                newFrame.size.width = max(minW, orig.width + dx)
                let newMinY = min(orig.maxY - minH, orig.minY + dy)
                newFrame.origin.y = newMinY
                newFrame.size.height = orig.maxY - newMinY
            case .bottomLeft:
                newFrame.origin.x = min(orig.maxX - minW, orig.minX + dx)
                newFrame.size.width = orig.maxX - newFrame.minX
                let newMinY = min(orig.maxY - minH, orig.minY + dy)
                newFrame.origin.y = newMinY
                newFrame.size.height = orig.maxY - newMinY
            default: break
            }

            sv.frame = newFrame
            tv.frame.size = newFrame.size
            tv.textContainer?.containerSize = NSSize(
                width: newFrame.width - tv.textContainerInset.width * 2,
                height: CGFloat.greatestFiniteMagnitude)
            needsDisplay = true
            return
        }

        switch state {
        case .selecting:
            if spaceRepositioning {
                // Space held: move the origin without changing size
                let dx = point.x - spaceRepositionLast.x
                let dy = point.y - spaceRepositionLast.y
                selectionStart.x += dx
                selectionStart.y += dy
                spaceRepositionLast = point
            }
            let rawW = abs(point.x - selectionStart.x)
            let rawH = abs(point.y - selectionStart.y)
            let shiftHeld = event.modifierFlags.contains(.shift)
            let w = max(1, shiftHeld ? min(rawW, rawH) : rawW)
            let h = max(1, shiftHeld ? min(rawW, rawH) : rawH)
            let x = selectionStart.x < point.x ? selectionStart.x : selectionStart.x - w
            let y = selectionStart.y < point.y ? selectionStart.y : selectionStart.y - h
            selectionRect = NSRect(x: x, y: y, width: w, height: h)
            overlayDelegate?.overlayViewSelectionDidChange(selectionRect)
            needsDisplay = true

        case .selected:
            // Convert to canvas space for annotation interactions (accounts for zoom)
            let canvasPoint = viewToCanvas(point)
            if isRotatingAnnotation, let annotation = selectedAnnotation {
                let center = NSPoint(
                    x: annotation.boundingRect.midX, y: annotation.boundingRect.midY)
                let currentAngle = atan2(canvasPoint.x - center.x, canvasPoint.y - center.y)
                var newRotation = rotationOriginal - (currentAngle - rotationStartAngle)
                // Shift: snap to 90° steps
                if NSEvent.modifierFlags.contains(.shift) {
                    let step = CGFloat.pi / 2
                    newRotation = (newRotation / step).rounded() * step
                }
                annotation.rotation = newRotation
                needsDisplay = true
                return
            }
            if isResizingAnnotation, let annotation = selectedAnnotation {
                let dx = canvasPoint.x - annotationResizeMouseStart.x
                let dy = canvasPoint.y - annotationResizeMouseStart.y
                let origStart = annotationResizeOrigStart
                let origEnd = annotationResizeOrigEnd

                // Text annotations: dragging any handle just moves the text
                if annotation.tool == .text {
                    annotation.startPoint = NSPoint(x: origStart.x + dx, y: origStart.y + dy)
                    annotation.endPoint = NSPoint(x: origEnd.x + dx, y: origEnd.y + dy)
                    annotation.textDrawRect.origin = NSPoint(
                        x: annotationResizeOrigTextOrigin.x + dx,
                        y: annotationResizeOrigTextOrigin.y + dy)
                    needsDisplay = true
                    break
                }

                let shiftHeld = event.modifierFlags.contains(.shift)

                // Arrow/line/measure: .bottomLeft = startPoint, .topRight = endPoint, others = anchor points
                if annotation.tool == .arrow || annotation.tool == .line
                    || annotation.tool == .measure
                {
                    let newPt = NSPoint(
                        x: annotationResizeOrigControlPoint.x + dx,
                        y: annotationResizeOrigControlPoint.y + dy)
                    switch annotationResizeHandle {
                    case .bottomLeft:
                        var newStart = NSPoint(x: origStart.x + dx, y: origStart.y + dy)
                        if shiftHeld {
                            let anchor = annotation.endPoint
                            let ddx = newStart.x - anchor.x
                            let ddy = newStart.y - anchor.y
                            let angle = atan2(ddy, ddx)
                            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
                            let dist = hypot(ddx, ddy)
                            newStart = NSPoint(
                                x: anchor.x + dist * cos(snapped), y: anchor.y + dist * sin(snapped)
                            )
                        }
                        annotation.startPoint = newStart
                        if var anchors = annotation.anchorPoints, !anchors.isEmpty {
                            anchors[0] = newStart
                            annotation.anchorPoints = anchors
                        }
                    case .topRight:
                        var newEnd = NSPoint(x: origEnd.x + dx, y: origEnd.y + dy)
                        if shiftHeld {
                            let anchor = annotation.startPoint
                            let ddx = newEnd.x - anchor.x
                            let ddy = newEnd.y - anchor.y
                            let angle = atan2(ddy, ddx)
                            let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
                            let dist = hypot(ddx, ddy)
                            newEnd = NSPoint(
                                x: anchor.x + dist * cos(snapped), y: anchor.y + dist * sin(snapped)
                            )
                        }
                        annotation.endPoint = newEnd
                        if var anchors = annotation.anchorPoints, anchors.count >= 2 {
                            anchors[anchors.count - 1] = newEnd
                            annotation.anchorPoints = anchors
                        }
                    default:
                        // Dragging an anchor point (multi-anchor or legacy controlPoint)
                        if annotationResizeAnchorIndex >= 0, var anchors = annotation.anchorPoints {
                            if annotationResizeAnchorIndex < anchors.count {
                                anchors[annotationResizeAnchorIndex] = newPt
                                annotation.anchorPoints = anchors
                                // Keep start/end in sync
                                annotation.startPoint = anchors.first!
                                annotation.endPoint = anchors.last!
                            }
                        } else {
                            // Legacy single controlPoint
                            annotation.controlPoint = newPt
                        }
                    }
                } else {
                    // Work in bounding-rect space so resize is correct regardless of draw direction
                    let origMinX = min(origStart.x, origEnd.x)
                    let origMaxX = max(origStart.x, origEnd.x)
                    let origMinY = min(origStart.y, origEnd.y)
                    let origMaxY = max(origStart.y, origEnd.y)
                    var newMinX = origMinX
                    var newMaxX = origMaxX
                    var newMinY = origMinY
                    var newMaxY = origMaxY

                    switch annotationResizeHandle {
                    case .topLeft:
                        newMinX = min(origMinX + dx, origMaxX - 10)
                        newMaxY = max(origMaxY + dy, origMinY + 10)
                    case .topRight:
                        newMaxX = max(origMaxX + dx, origMinX + 10)
                        newMaxY = max(origMaxY + dy, origMinY + 10)
                    case .bottomLeft:
                        newMinX = min(origMinX + dx, origMaxX - 10)
                        newMinY = min(origMinY + dy, origMaxY - 10)
                    case .bottomRight:
                        newMaxX = max(origMaxX + dx, origMinX + 10)
                        newMinY = min(origMinY + dy, origMaxY - 10)
                    case .top:
                        newMaxY = max(origMaxY + dy, origMinY + 10)
                    case .bottom:
                        newMinY = min(origMinY + dy, origMaxY - 10)
                    case .left:
                        newMinX = min(origMinX + dx, origMaxX - 10)
                    case .right:
                        newMaxX = max(origMaxX + dx, origMinX + 10)
                    default:
                        break
                    }

                    // Shift constraint: force square/circle for corner handles
                    if shiftHeld {
                        let w = newMaxX - newMinX
                        let h = newMaxY - newMinY
                        let side = max(w, h)
                        switch annotationResizeHandle {
                        case .topLeft:
                            newMinX = newMaxX - side
                            newMaxY = newMinY + side
                        case .topRight:
                            newMaxX = newMinX + side
                            newMaxY = newMinY + side
                        case .bottomLeft:
                            newMinX = newMaxX - side
                            newMinY = newMaxY - side
                        case .bottomRight:
                            newMaxX = newMinX + side
                            newMinY = newMaxY - side
                        default: break
                        }
                    }

                    annotation.startPoint = NSPoint(x: newMinX, y: newMinY)
                    annotation.endPoint = NSPoint(x: newMaxX, y: newMaxY)
                }
                cachedCompositedImage = nil
                needsDisplay = true
            } else if isDraggingAnnotation, let annotation = selectedAnnotation {
                let rawDx = canvasPoint.x - annotationDragStart.x
                let rawDy = canvasPoint.y - annotationDragStart.y
                // Apply snap to the annotation's bounding rect after tentative move
                var movedRect = annotation.boundingRect.offsetBy(dx: rawDx, dy: rawDy)
                let snap = snapRectDelta(rect: movedRect, excluding: annotation)
                let finalDx = rawDx + snap.dx
                let finalDy = rawDy + snap.dy
                annotation.move(dx: finalDx, dy: finalDy)
                annotationDragStart = NSPoint(
                    x: canvasPoint.x + snap.dx, y: canvasPoint.y + snap.dy)
                cachedCompositedImage = nil
                needsDisplay = true
            } else if isDraggingSelection {
                selectionRect.origin = NSPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y)
                needsDisplay = true
            } else if isResizingSelection {
                resizeSelection(to: point)
                needsDisplay = true
            } else if currentAnnotation != nil {
                if spaceRepositioning {
                    // Space held: reposition the whole shape
                    let dx = canvasPoint.x - spaceRepositionLast.x
                    let dy = canvasPoint.y - spaceRepositionLast.y
                    currentAnnotation!.startPoint.x += dx
                    currentAnnotation!.startPoint.y += dy
                    currentAnnotation!.endPoint.x += dx
                    currentAnnotation!.endPoint.y += dy
                    if let points = currentAnnotation!.points {
                        currentAnnotation!.points = points.map {
                            NSPoint(x: $0.x + dx, y: $0.y + dy)
                        }
                    }
                    spaceRepositionLast = canvasPoint
                } else {
                    updateAnnotation(
                        at: canvasPoint, shiftHeld: event.modifierFlags.contains(.shift))
                }
                lastDragPoint = canvasPoint
                needsDisplay = true
            }

        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        spaceRepositioning = false

        // Crop commit
        if isCropDragging {
            isCropDragging = false
            let rect = cropDragRect
            cropDragRect = .zero
            if rect.width > 4 && rect.height > 4 {
                commitCrop(viewRect: rect)
            }
            needsDisplay = true
            return
        }

        if isResizingTextBox {
            isResizingTextBox = false
            return
        }
        if isRotatingAnnotation {
            isRotatingAnnotation = false
            needsDisplay = true
            return
        }
        if isResizingAnnotation {
            isResizingAnnotation = false
            annotationResizeHandle = .none
            if let ann = selectedAnnotation, ann.tool == .loupe {
                ann.bakeLoupe()
            }
            // If this resize was initiated via hover-to-move (not the select tool), clear selectedAnnotation
            if currentTool != .select {
                selectedAnnotation = nil
            }
            needsDisplay = true
            return
        }
        lastDragPoint = nil
        switch state {
        case .selecting:
            if selectionRect.width > 5 || selectionRect.height > 5 {
                // Real drag — use drawn rect as-is
                state = .selected
                if !autoOCRMode && !autoQuickSaveMode { showToolbars = true }
                overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
            } else if windowSnapEnabled, let snapRect = hoveredWindowRect, !snapRect.isEmpty {
                // Click (no drag) with snap on — snap to hovered window
                selectionRect = snapRect
                state = .selected
                if !autoOCRMode && !autoQuickSaveMode { showToolbars = true }
                overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
            } else {
                // Click (no drag), snap off — expand to full screen
                selectionRect = bounds
                state = .selected
                if !autoOCRMode && !autoQuickSaveMode { showToolbars = true }
                overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
            }
            hoveredWindowRect = nil
            // Update cursor to match the selected tool (replaces resize cursor from dragging)
            if let win = window {
                let point = convert(win.mouseLocationOutsideOfEventStream, from: nil)
                updateCursorForPoint(point)
            }
            scheduleBarcodeDetection()
            // Auto-enter recording mode if triggered from "Record Screen"
            if autoEnterRecordingMode {
                autoEnterRecordingMode = false
                overlayDelegate?.overlayViewDidRequestEnterRecordingMode()
            }
            // Auto-trigger OCR if triggered from "Capture OCR"
            if autoOCRMode {
                autoOCRMode = false
                overlayDelegate?.overlayViewDidRequestOCR()
            }
            // Auto-trigger quick save if triggered from "Quick Capture"
            if autoQuickSaveMode {
                autoQuickSaveMode = false
                overlayDelegate?.overlayViewDidRequestQuickSave()
            }
            needsDisplay = true

        case .selected:
            if isDraggingAnnotation {
                isDraggingAnnotation = false
                snapGuideX = nil
                snapGuideY = nil
                if let ann = selectedAnnotation, ann.tool == .loupe {
                    ann.bakeLoupe()
                }
                // If this drag was initiated via hover-to-move (not the select tool), clear selectedAnnotation
                if currentTool != .select {
                    selectedAnnotation = nil
                }
                needsDisplay = true
            } else if isDraggingSelection {
                isDraggingSelection = false
                scheduleBarcodeDetection()
                needsDisplay = true
            } else if isResizingSelection {
                isResizingSelection = false
                resizeHandle = .none
                scheduleBarcodeDetection()
                if let win = window {
                    updateCursorForPoint(convert(win.mouseLocationOutsideOfEventStream, from: nil))
                }
                needsDisplay = true
            } else if let annotation = currentAnnotation {
                finishAnnotation(annotation)
            }

        default:
            break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Text Fill/Outline color picking handled by ToolOptionsRowView

        // Toolbar right-clicks handled by ToolbarButtonView.onRightClick → handleToolbarButtonRightClick

        // Right-click on a selected/hovered line/arrow: add anchor point
        if state == .selected {
            if let ann = selectedAnnotation ?? hoveredAnnotation,
                ann.tool == .arrow || ann.tool == .line || ann.tool == .measure
            {
                let canvasPoint = viewToCanvas(point)
                if ann.hitTest(point: canvasPoint) {
                    addAnchorPoint(to: ann, at: canvasPoint)
                    cachedCompositedImage = nil
                    needsDisplay = true
                    return
                }
            }
        }

        if state == .selected && currentTool == .colorSampler {
            // Right-click with color sampler: copy hex to clipboard
            if let screenshot = screenshotImage,
                let result = sampleColor(from: screenshot, at: viewToCanvas(point))
            {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.hex, forType: .string)
                showOverlayError("Copied \(result.hex)")
                needsDisplay = true
            }
            return
        }

        if state == .selected && pointIsInSelection(point) {
            // Show radial color wheel
            colorWheel.show(at: point)

            colorWheel.hoveredIndex = -1
            needsDisplay = true
            return
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if colorWheel.isVisible {
            let point = convert(event.locationInWindow, from: nil)
            colorWheel.updateHover(at: point)
            needsDisplay = true
            return
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        if colorWheel.isVisible {
            if colorWheel.hoveredColor != nil {
                currentColor = colorWheel.hoveredColor!
                applyColorToTextIfEditing()
                applyColorToSelectedAnnotation()
            }
            colorWheel.dismiss()
            colorWheel.hoveredIndex = -1
            needsDisplay = true
            return
        }
    }

    // MARK: - Zoom (scroll wheel + trackpad pinch)

    override func scrollWheel(with event: NSEvent) {
        if isInsideScrollView {
            guard let sv = enclosingScrollView else { return }
            let isTrackpad = event.phase != [] || event.momentumPhase != []
            if !isTrackpad {
                // Mouse scroll wheel → zoom
                let delta = event.deltaY
                let newMag = sv.magnification + delta * 0.05
                sv.magnification = max(sv.minMagnification, min(sv.maxMagnification, newMag))
                // Update zoom label
                if let topBar = sv.superview?.subviews.compactMap({ $0 as? EditorTopBarView }).first
                {
                    topBar.updateZoom(sv.magnification)
                }
            } else {
                sv.scrollWheel(with: event)
            }
            return
        }
        guard state == .selected else { return }
        let isTrackpadPhased = event.phase != [] || event.momentumPhase != []
        let isCommandScroll = event.modifierFlags.contains(.command)

        // Phase-based (trackpad) scroll without Cmd → pan only, never zoom
        if isTrackpadPhased && !isCommandScroll {
            // Allow panning when zoomed OR when the image exceeds the view (tall/wide images in editor)
            let imageExceedsView =
                canPanAtOneX()
                || (isEditorMode
                    && (selectionRect.height > bounds.height || selectionRect.width > bounds.width))
            guard zoomLevel != 1.0 || imageExceedsView else { return }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            zoomAnchorView.x += dx
            zoomAnchorView.y -= dy  // AppKit Y is flipped vs scroll direction
            clampZoomAnchor()
            needsDisplay = true
            return
        }

        // Cmd+scroll or plain mouse wheel (non-trackpad) → zoom
        guard isCommandScroll || !isTrackpadPhased else { return }
        let cursor = convert(event.locationInWindow, from: nil)
        let delta = event.deltaY
        let factor: CGFloat = 0.1
        setZoom(zoomLevel + delta * factor, cursorView: cursor)
    }

    override func magnify(with event: NSEvent) {
        if isInsideScrollView {
            enclosingScrollView?.magnify(with: event)
            return
        }
        guard state == .selected else { return }
        let cursor = convert(event.locationInWindow, from: nil)
        setZoom(zoomLevel + event.magnification, cursorView: cursor)
    }

    // MARK: - Middle Mouse (toggle move mode)

    override func otherMouseDown(with event: NSEvent) {
        // Middle mouse: no action (previously toggled select tool)
    }

    // MARK: - Selection Resizing

    private func resizeSelection(to point: NSPoint) {
        let minSize: CGFloat = 10
        let r = selectionRect
        var newRect = r

        switch resizeHandle {
        case .topLeft:
            let newX = min(point.x, r.maxX - minSize)
            let newMaxY = max(point.y, r.minY + minSize)
            newRect = NSRect(x: newX, y: r.minY, width: r.maxX - newX, height: newMaxY - r.minY)
        case .topRight:
            let newMaxX = max(point.x, r.minX + minSize)
            let newMaxY = max(point.y, r.minY + minSize)
            newRect = NSRect(
                x: r.minX, y: r.minY, width: newMaxX - r.minX, height: newMaxY - r.minY)
        case .bottomLeft:
            let newX = min(point.x, r.maxX - minSize)
            let newY = min(point.y, r.maxY - minSize)
            newRect = NSRect(x: newX, y: newY, width: r.maxX - newX, height: r.maxY - newY)
        case .bottomRight:
            let newMaxX = max(point.x, r.minX + minSize)
            let newY = min(point.y, r.maxY - minSize)
            newRect = NSRect(x: r.minX, y: newY, width: newMaxX - r.minX, height: r.maxY - newY)
        case .top:
            let newMaxY = max(point.y, r.minY + minSize)
            newRect = NSRect(x: r.minX, y: r.minY, width: r.width, height: newMaxY - r.minY)
        case .bottom:
            let newY = min(point.y, r.maxY - minSize)
            newRect = NSRect(x: r.minX, y: newY, width: r.width, height: r.maxY - newY)
        case .left:
            let newX = min(point.x, r.maxX - minSize)
            newRect = NSRect(x: newX, y: r.minY, width: r.maxX - newX, height: r.height)
        case .right:
            let newMaxX = max(point.x, r.minX + minSize)
            newRect = NSRect(x: r.minX, y: r.minY, width: newMaxX - r.minX, height: r.height)
        default:
            break
        }

        selectionRect = newRect
    }

    // MARK: - Toolbar Actions

    /// Handle right-click on a toolbar button (context menus, popovers).
    private func handleToolbarButtonHover(_ action: ToolbarButtonAction, hovered: Bool, strip: ToolbarStripView?) {
        if hovered {
            let btn = strip?.buttonViews.first { bv in
                // Compare by identity — find the button that triggered the hover
                if case .tool(let t1) = bv.action, case .tool(let t2) = action { return t1 == t2 }
                // For non-tool actions, compare string representation
                return "\(bv.action)" == "\(action)"
            }
            hoveredTooltip = btn?.tooltipText
            hoveredTooltipButtonView = btn
        } else {
            hoveredTooltip = nil
            hoveredTooltipButtonView = nil
        }
        needsDisplay = true
    }

    private func drawHoveredTooltip() {
        guard let tooltip = hoveredTooltip, !tooltip.isEmpty,
              let btn = hoveredTooltipButtonView,
              !PopoverHelper.isVisible else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = tooltip as NSString
        let textSize = str.size(withAttributes: attrs)
        let pad: CGFloat = 6
        let tipW = textSize.width + pad * 2
        let tipH = textSize.height + pad

        // Convert button position to OverlayView coordinates
        let btnFrame = btn.convert(btn.bounds, to: self)
        let isBottomBar = btn.superview === bottomStripView
        let tipRect: NSRect

        if isBottomBar {
            // Above bottom bar, or below if no room
            var tipY = bottomBarRect.maxY + 4
            if tipY + tipH > bounds.maxY - 2 { tipY = bottomBarRect.minY - tipH - 4 }
            tipRect = NSRect(x: btnFrame.midX - tipW / 2, y: tipY, width: tipW, height: tipH)
        } else {
            // Left of right bar
            tipRect = NSRect(x: btnFrame.minX - tipW - 6, y: btnFrame.midY - tipH / 2, width: tipW, height: tipH)
        }

        // Clamp to bounds
        let clamped = NSRect(
            x: max(bounds.minX + 2, min(tipRect.minX, bounds.maxX - tipW - 2)),
            y: max(bounds.minY + 2, min(tipRect.minY, bounds.maxY - tipH - 2)),
            width: tipW, height: tipH)

        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: clamped, xRadius: 4, yRadius: 4).fill()
        str.draw(at: NSPoint(x: clamped.minX + pad, y: clamped.minY + pad / 2), withAttributes: attrs)
    }

    private func handleToolbarButtonRightClick(_ action: ToolbarButtonAction, anchorView: NSView) {
        switch action {
        case .autoRedact:
            showRedactTypePopover(
                anchorRect: anchorView.convert(anchorView.bounds, to: self), anchorView: anchorView)
        case .save:
            let menu = NSMenu()
            let saveAsItem = NSMenuItem(
                title: "Save As...", action: #selector(saveAsMenuAction), keyEquivalent: "")
            saveAsItem.target = self
            menu.addItem(saveAsItem)
            menu.popUp(
                positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height), in: anchorView)
        case .upload:
            showUploadConfirmPopover(
                anchorRect: anchorView.convert(anchorView.bounds, to: self), anchorView: anchorView)
        case .translate:
            showTranslatePopover(
                anchorRect: anchorView.convert(anchorView.bounds, to: self), anchorView: anchorView)
        default:
            break
        }
    }

    func handleToolbarAction(_ action: ToolbarButtonAction, mousePoint: NSPoint = .zero) {
        // When recording but not in annotation mode, only allow recording-control actions
        if isRecording && !isAnnotating {
            switch action {
            case .annotationMode, .startRecord, .stopRecord, .mouseHighlight, .systemAudio,
                .micAudio:
                break  // allowed — fall through to main switch
            default:
                return
            }
        }

        switch action {
        case .tool(let tool):
            if tool == .select && !annotations.contains(where: { $0.isMovable }) {
                showOverlayError("Draw something first to use the move tool.")
                return
            }
            commitTextFieldIfNeeded()
            showBeautifyInOptionsRow = false  // switch back to tool options
            currentTool = tool
            // Auto-select first emoji when switching to stamp tool with nothing selected
            if tool == .stamp && currentStampImage == nil {
                currentStampImage = StampEmojis.renderEmoji(StampEmojis.common[0])
                currentStampEmoji = StampEmojis.common[0]
            }
            needsDisplay = true
        case .loupe:
            currentTool = .loupe
            needsDisplay = true
        case .color:
            if PopoverHelper.isVisible { PopoverHelper.dismiss(); break }
            let colorBtn = bottomStripView?.buttonViews.first { if case .color = $0.action { return true }; return false }
            showColorPickerPopover(target: .drawColor, anchorView: colorBtn)
        case .sizeDisplay:
            break
        case .moveSelection:
            guard !isRecording, let win = window else { break }
            // Show drag hint tooltip
            hoveredTooltip = "Drag to reposition"
            needsDisplay = true
            displayIfNeeded()
            // Synchronous drag loop: tracks mouse from button press until release
            let startPoint = convert(win.mouseLocationOutsideOfEventStream, from: nil)
            let offset = NSPoint(x: startPoint.x - selectionRect.origin.x, y: startPoint.y - selectionRect.origin.y)
            while true {
                guard let event = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
                let point = convert(event.locationInWindow, from: nil)
                selectionRect.origin = NSPoint(x: point.x - offset.x, y: point.y - offset.y)
                needsDisplay = true
                displayIfNeeded()
                if event.type == .leftMouseUp { break }
            }
            // Restore original tooltip
            hoveredTooltip = hoveredTooltipButtonView?.tooltipText
            scheduleBarcodeDetection()
            needsDisplay = true
        case .undo:
            undo()
        case .redo:
            redo()
        case .copy:
            overlayDelegate?.overlayViewDidConfirm()
        case .save:
            overlayDelegate?.overlayViewDidRequestQuickSave()
        case .upload:
            let confirmEnabled = UserDefaults.standard.bool(forKey: "uploadConfirmEnabled")
            if confirmEnabled {
                let provider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"
                let title: String
                switch provider {
                case "gdrive": title = "Upload to Google Drive?"
                case "s3": title = "Upload to S3?"
                default: title = "Upload to imgbb.com?"
                }
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = "Your screenshot will be uploaded."
                alert.addButton(withTitle: "Upload")
                alert.addButton(withTitle: "Cancel")
                alert.alertStyle = .informational
                // Temporarily lower window level so the alert is visible
                let originalLevel = window?.level ?? .statusBar
                window?.level = .normal
                let response = alert.runModal()
                window?.level = originalLevel
                if response == .alertFirstButtonReturn {
                    overlayDelegate?.overlayViewDidRequestUpload()
                }
            } else {
                overlayDelegate?.overlayViewDidRequestUpload()
            }
        case .share:
            // Show share picker anchored to the share button, then dismiss on selection
            let shareBtn = rightStripView?.buttonViews.first { if case .share = $0.action { return true }; return false }
            overlayDelegate?.overlayViewDidRequestShare(anchorView: shareBtn)
        case .pin:
            overlayDelegate?.overlayViewDidRequestPin()
        case .ocr:
            overlayDelegate?.overlayViewDidRequestOCR()
        case .autoRedact:
            performAutoRedact()
        case .removeBackground:
            if #available(macOS 14.0, *) {
                overlayDelegate?.overlayViewDidRequestRemoveBackground()
            }
        case .invertColors:
            invertImageColors()
        case .beautify:
            commitTextFieldIfNeeded()
            stampPreviewPoint = nil
            loupeCursorPoint = .zero
            // Auto-enable beautify on first click in this session
            if !beautifyEnabled {
                beautifyEnabled = true
                UserDefaults.standard.set(true, forKey: "beautifyEnabled")
                startBeautifyToolbarAnimation()
            }
            showBeautifyInOptionsRow = true
            needsDisplay = true
        case .beautifyStyle:
            beautifyStyleIndex = (beautifyStyleIndex + 1) % BeautifyRenderer.styles.count
            UserDefaults.standard.set(beautifyStyleIndex, forKey: "beautifyStyleIndex")
            needsDisplay = true
        case .delayCapture:
            break
        case .translate:
            if translateEnabled {
                // Toggle off: remove overlays, restore original
                translateEnabled = false
                annotations.removeAll { $0.tool == .translateOverlay }
                isTranslating = false
            } else {
                translateEnabled = true
                performTranslate(targetLang: TranslationService.targetLanguage)
            }
            needsDisplay = true
        case .record:
            // Enter recording mode — delegate handles pass-through + control window
            overlayDelegate?.overlayViewDidRequestEnterRecordingMode()
        case .startRecord:
            // Actually start recording
            isCapturingVideo = true
            // Start monitors based on toggle state
            if UserDefaults.standard.bool(forKey: "recordMouseHighlight") {
                startMouseHighlightMonitor()
            }
            rebuildToolbarLayout()
            overlayDelegate?.overlayViewDidRequestStartRecording(rect: selectionRect)
        case .stopRecord:
            if isCapturingVideo {
                overlayDelegate?.overlayViewDidRequestStopRecording()
            } else {
                // Not actually recording — just exit recording mode
                isRecording = false
                rebuildToolbarLayout()
                needsDisplay = true
            }
        case .annotationMode:
            isAnnotating.toggle()
            rebuildToolbarLayout()
        case .mouseHighlight:
            let current = UserDefaults.standard.bool(forKey: "recordMouseHighlight")
            UserDefaults.standard.set(!current, forKey: "recordMouseHighlight")
            // Start/stop monitor only if currently capturing
            if isCapturingVideo {
                if !current { startMouseHighlightMonitor() } else { stopMouseHighlightMonitor() }
            }
            rebuildToolbarLayout()
        case .systemAudio:
            let current = UserDefaults.standard.bool(forKey: "recordSystemAudio")
            UserDefaults.standard.set(!current, forKey: "recordSystemAudio")
            rebuildToolbarLayout()
        case .micAudio:
            toggleMicAudio()
        case .cancel:
            overlayDelegate?.overlayViewDidCancel()
        case .detach:
            overlayDelegate?.overlayViewDidRequestDetach()
        case .scrollCapture:
            overlayDelegate?.overlayViewDidRequestScrollCapture(rect: selectionRect)
        }

        // Rebuild toolbars to reflect new state (selected tool, color, etc.)
        rebuildToolbarLayout()
    }

    /// Returns a color if a preset swatch was clicked, toggles the inline HSB picker
    /// if the custom picker swatch was clicked, or picks from the HSB gradient.
    /// Returns nil if nothing was hit.

    private func applyColorToTextIfEditing() {
        if textEditor.isEditing {
            textEditor.applyColorToLiveText(color: annotationColor)
        }
    }

    private func applyColorToSelectedAnnotation() {
        guard let ann = selectedAnnotation else { return }
        ann.color = opacityAppliedColor(for: ann.tool)
        cachedCompositedImage = nil
        needsDisplay = true
    }

    /// Returns currentColor with opacity applied for tools that respect it.
    /// Marker uses a fixed alpha in its draw method; loupe/measure/pixelate/blur are color-independent.
    func opacityAppliedColor(for tool: AnnotationTool) -> NSColor {
        switch tool {
        case .marker, .loupe, .measure, .pixelate, .blur, .translateOverlay:
            return currentColor
        default:
            return annotationColor
        }
    }

    // MARK: - Annotation Creation

    private func startAnnotation(at point: NSPoint) {

        // Hover-to-move: if the cursor is over a hovered annotation (while a drawing tool is active),
        // intercept the click and handle it like the select tool — resize handle or drag — without
        // switching currentTool. Must run BEFORE tool handler dispatch.
        if currentTool != .select && currentTool != .colorSampler && currentTool != .text,
           let hovered = hoveredAnnotation
        {
            if handleHoveredAnnotationClick(hovered, at: point) { return }
        }

        // Dispatch to extracted tool handler if available
        if let handler = toolHandlers[currentTool] {
            if let annotation = handler.start(at: point, canvas: self) {
                currentAnnotation = annotation
                needsDisplay = true
            }
            return
        }

        // Color sampler: click sets the current drawing color, no annotation created.
        // Note: point is already in canvas space (converted by caller).
        if currentTool == .colorSampler {
            if let screenshot = screenshotImage,
                let result = sampleColor(from: screenshot, at: point)
            {
                currentColor = result.color
                currentColorOpacity = 1.0
                OverlayView.lastUsedOpacity = 1.0
                // Also save to selected custom slot
                if selectedColorSlot >= 0 && selectedColorSlot < customColors.count {
                    customColors[selectedColorSlot] = result.color.withAlphaComponent(1.0)
                    saveCustomColors()
                    // Advance to next slot for rapid collection
                    let nextSlot = selectedColorSlot + 1
                    if nextSlot < customColors.count { selectedColorSlot = nextSlot }
                }
                showOverlayError("Set color \(result.hex)")
                needsDisplay = true
            }
            return
        }

        // Select/move tool: find annotation under cursor
        if currentTool == .select {
            // Check annotation control buttons first
            if let selected = selectedAnnotation {
                // Delete button
                if annotationDeleteButtonRect.contains(point) {
                    if let idx = annotations.firstIndex(where: { $0 === selected }) {
                        annotations.remove(at: idx)
                        undoStack.append(.deleted(selected, idx))
                        redoStack.removeAll()
                    }
                    selectedAnnotation = nil
                    needsDisplay = true
                    return
                }
                // Edit button (text only)
                if annotationEditButtonRect != .zero && annotationEditButtonRect.contains(point) {
                    textEditor.restoreState(from: selected)
                    if let idx = annotations.firstIndex(where: { $0 === selected }) {
                        annotations.remove(at: idx)
                        selectedAnnotation = nil
                    }
                    showTextField(
                        at: selected.textDrawRect.origin, existingText: selected.attributedText,
                        existingFrame: selected.textDrawRect)
                    needsDisplay = true
                    return
                }
                // Rotation handle
                if annotationRotateHandleRect != .zero
                    && annotationRotateHandleRect.insetBy(dx: -6, dy: -6).contains(point)
                {
                    isRotatingAnnotation = true
                    let center = NSPoint(
                        x: selected.boundingRect.midX, y: selected.boundingRect.midY)
                    rotationStartAngle = atan2(point.x - center.x, point.y - center.y)
                    rotationOriginal = selected.rotation
                    return
                }
                // Resize handles — unrotate point into annotation's local space
                let handleTestPoint: NSPoint
                if selected.rotation != 0 && selected.supportsRotation {
                    let center = NSPoint(
                        x: selected.boundingRect.midX, y: selected.boundingRect.midY)
                    let cos_r = cos(-selected.rotation)
                    let sin_r = sin(-selected.rotation)
                    let dx = point.x - center.x
                    let dy = point.y - center.y
                    handleTestPoint = NSPoint(
                        x: center.x + dx * cos_r - dy * sin_r,
                        y: center.y + dx * sin_r + dy * cos_r)
                } else {
                    handleTestPoint = point
                }
                for (handleIdx, handleEntry) in annotationResizeHandleRects.enumerated() {
                    let (handle, rect) = handleEntry
                    if rect.insetBy(dx: -4, dy: -4).contains(handleTestPoint) {
                        isResizingAnnotation = true
                        annotationResizeHandle = handle
                        annotationResizeOrigStart = selected.startPoint
                        annotationResizeOrigEnd = selected.endPoint
                        annotationResizeOrigTextOrigin = selected.textDrawRect.origin
                        annotationResizeMouseStart = point
                        // For multi-anchor: handleIdx 0=start, 1=end, 2+=intermediate anchors
                        annotationResizeAnchorIndex = -1
                        if let anchors = selected.anchorPoints, anchors.count >= 3, handleIdx >= 2 {
                            let anchorIdx = handleIdx - 2 + 1  // anchors[0]=start, so intermediate starts at 1
                            if anchorIdx > 0 && anchorIdx < anchors.count - 1 {
                                annotationResizeAnchorIndex = anchorIdx
                                annotationResizeOrigControlPoint = anchors[anchorIdx]
                            }
                        } else if handle == .none || (handle != .bottomLeft && handle != .topRight) {
                            // Legacy single controlPoint or intermediate anchor
                            if annotationResizeAnchorIndex < 0 {
                                annotationResizeOrigControlPoint =
                                    selected.controlPoint
                                    ?? NSPoint(
                                        x: (selected.startPoint.x + selected.endPoint.x) / 2,
                                        y: (selected.startPoint.y + selected.endPoint.y) / 2
                                    )
                            }
                        }
                        return
                    }
                }
            }

            // Search in reverse (topmost first)
            for annotation in annotations.reversed() {
                if annotation.isMovable && annotation.hitTest(point: point) {
                    selectedAnnotation = annotation
                    isDraggingAnnotation = true
                    annotationDragStart = point
                    needsDisplay = true
                    return
                }
            }
            // Clicked empty space — deselect
            selectedAnnotation = nil
            needsDisplay = true
            return
        }

        // Deselect when using other tools
        selectedAnnotation = nil

        if currentTool == .text {
            // Check if clicking on an existing text annotation → re-edit it
            // Note: point is already in canvas space (converted by caller).
            if let existingAnn = annotations.reversed().first(where: {
                $0.tool == .text && $0.hitTest(point: point)
            }) {
                // Remove from annotations (will be re-added on commit)
                if let idx = annotations.firstIndex(where: { $0 === existingAnn }) {
                    annotations.remove(at: idx)
                }
                textEditor.editingAnnotation = existingAnn
                textEditor.restoreState(from: existingAnn)
                showTextField(
                    at: existingAnn.textDrawRect.origin,
                    existingText: existingAnn.attributedText,
                    existingFrame: existingAnn.textDrawRect)
            } else {
                showTextField(at: point)
            }
        }
    }

    private func updateAnnotation(at point: NSPoint, shiftHeld: Bool = false) {
        guard let annotation = currentAnnotation else { return }
        if let handler = toolHandlers[annotation.tool] {
            handler.update(to: point, shiftHeld: shiftHeld, canvas: self)
        }
    }

    private func finishAnnotation(_ annotation: Annotation) {
        if let handler = toolHandlers[annotation.tool] {
            handler.finish(canvas: self)
        }
    }

    /// Handle click on a hovered annotation's controls or body (hover-to-move).
    /// Returns true if the click was consumed.
    private func handleHoveredAnnotationClick(_ hovered: Annotation, at point: NSPoint) -> Bool {
        // Unrotate point for resize handle hit test
        let hoverHandlePoint: NSPoint
        if hovered.rotation != 0 && hovered.supportsRotation {
            let center = NSPoint(x: hovered.boundingRect.midX, y: hovered.boundingRect.midY)
            let cos_r = cos(-hovered.rotation)
            let sin_r = sin(-hovered.rotation)
            let dx = point.x - center.x
            let dy = point.y - center.y
            hoverHandlePoint = NSPoint(
                x: center.x + dx * cos_r - dy * sin_r,
                y: center.y + dx * sin_r + dy * cos_r)
        } else {
            hoverHandlePoint = point
        }
        // Check resize handles of the hovered annotation (populated by drawAnnotationControls)
        for (handleIdx, handleEntry) in annotationResizeHandleRects.enumerated() {
            let (handle, rect) = handleEntry
            if rect.insetBy(dx: -4, dy: -4).contains(hoverHandlePoint) {
                selectedAnnotation = hovered
                isResizingAnnotation = true
                annotationResizeHandle = handle
                annotationResizeOrigStart = hovered.startPoint
                annotationResizeOrigEnd = hovered.endPoint
                annotationResizeOrigTextOrigin = hovered.textDrawRect.origin
                annotationResizeMouseStart = point
                annotationResizeAnchorIndex = -1
                if let anchors = hovered.anchorPoints, anchors.count >= 3, handleIdx >= 2 {
                    let anchorIdx = handleIdx - 2 + 1
                    if anchorIdx > 0 && anchorIdx < anchors.count - 1 {
                        annotationResizeAnchorIndex = anchorIdx
                        annotationResizeOrigControlPoint = anchors[anchorIdx]
                    }
                } else if handle == .none || (handle != .bottomLeft && handle != .topRight) {
                    if annotationResizeAnchorIndex < 0 {
                        annotationResizeOrigControlPoint =
                            hovered.controlPoint
                            ?? NSPoint(
                                x: (hovered.startPoint.x + hovered.endPoint.x) / 2,
                                y: (hovered.startPoint.y + hovered.endPoint.y) / 2
                            )
                    }
                }
                needsDisplay = true
                return true
            }
        }
        // Check rotation handle
        if annotationRotateHandleRect != .zero
            && annotationRotateHandleRect.insetBy(dx: -6, dy: -6).contains(point)
        {
            selectedAnnotation = hovered
            isRotatingAnnotation = true
            let center = NSPoint(x: hovered.boundingRect.midX, y: hovered.boundingRect.midY)
            rotationStartAngle = atan2(point.x - center.x, point.y - center.y)
            rotationOriginal = hovered.rotation
            needsDisplay = true
            return true
        }
        // Check delete button
        if annotationDeleteButtonRect.contains(point) {
            if let idx = annotations.firstIndex(where: { $0 === hovered }) {
                annotations.remove(at: idx)
                undoStack.append(.deleted(hovered, idx))
                redoStack.removeAll()
            }
            hoveredAnnotation = nil
            selectedAnnotation = nil
            needsDisplay = true
            return true
        }
        // Click on the annotation body — start drag
        if hovered.hitTest(point: point) {
            selectedAnnotation = hovered
            isDraggingAnnotation = true
            annotationDragStart = point
            needsDisplay = true
            return true
        }
        return false
    }

    // MARK: - Text Field

    private func showTextField(
        at point: NSPoint, existingText: NSAttributedString? = nil, existingFrame: NSRect = .zero
    ) {
        textEditor.show(
            in: self, at: point, color: currentColor,
            existingText: existingText, existingFrame: existingFrame,
            canvas: self)
        textEditor.textView?.delegate = self
        rebuildToolbarLayout()
        needsDisplay = true
    }

    func cancelTextEditing() {
        textEditor.cancel(canvas: self)
        window?.makeFirstResponder(self)
        rebuildToolbarLayout()
        needsDisplay = true
    }

    func commitTextFieldIfNeeded() {
        guard textEditor.isEditing else { return }
        textEditor.commit(canvas: self)
        window?.makeFirstResponder(self)
        rebuildToolbarLayout()
        needsDisplay = true
    }

    // MARK: - Mic Permission & Toggle

    private func toggleMicAudio() {
        let current = UserDefaults.standard.bool(forKey: "recordMicAudio")
        if current {
            // Turning off — no permission needed
            UserDefaults.standard.set(false, forKey: "recordMicAudio")
            rebuildToolbarLayout()
            return
        }
        // Turning on — check mic permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            UserDefaults.standard.set(true, forKey: "recordMicAudio")
            rebuildToolbarLayout()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        UserDefaults.standard.set(true, forKey: "recordMicAudio")
                    }
                    self?.rebuildToolbarLayout()
                }
            }
        case .denied, .restricted:
            showMicPermissionAlert()
        @unknown default:
            break
        }
    }

    private func showMicPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Required"
        alert.informativeText =
            "macshot needs microphone permission to record voice audio. Open System Settings to grant access."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Context Menu Actions

    /// Add an anchor point to a line/arrow annotation at the position closest to `canvasPoint`.
    /// Inserts the point between the two nearest existing waypoints.
    private func addAnchorPoint(to annotation: Annotation, at canvasPoint: NSPoint) {
        var pts = annotation.waypoints

        // Find which segment the point is closest to, and insert there
        var bestIdx = 1
        var bestDist = CGFloat.greatestFiniteMagnitude
        for i in 1..<pts.count {
            let d = distanceToSegment(point: canvasPoint, from: pts[i - 1], to: pts[i])
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }

        // Project the point onto the segment for exact placement
        let a = pts[bestIdx - 1]
        let b = pts[bestIdx]
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        let t: CGFloat =
            lenSq < 0.001
            ? 0.5
            : max(
                0.05, min(0.95, ((canvasPoint.x - a.x) * dx + (canvasPoint.y - a.y) * dy) / lenSq))
        let projected = NSPoint(x: a.x + t * dx, y: a.y + t * dy)

        pts.insert(projected, at: bestIdx)

        // Store as anchorPoints, update startPoint/endPoint to match
        annotation.anchorPoints = pts
        annotation.startPoint = pts.first!
        annotation.endPoint = pts.last!
        // Clear legacy controlPoint since we're using anchorPoints now
        annotation.controlPoint = nil
    }

    private func distanceToSegment(point: NSPoint, from a: NSPoint, to b: NSPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        if lenSq < 0.001 { return hypot(point.x - a.x, point.y - a.y) }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSq
        t = max(0, min(1, t))
        let proj = NSPoint(x: a.x + t * dx, y: a.y + t * dy)
        return hypot(point.x - proj.x, point.y - proj.y)
    }

    @objc private func saveAsMenuAction() {
        overlayDelegate?.overlayViewDidRequestSave()
    }

    // MARK: - Keyboard

    override func flagsChanged(with event: NSEvent) {
        // Re-apply shift constraint immediately when Shift is pressed/released during annotation drag
        if currentAnnotation != nil, let lastPoint = lastDragPoint {
            let shiftHeld = event.modifierFlags.contains(.shift)
            updateAnnotation(at: lastPoint, shiftHeld: shiftHeld)
            needsDisplay = true
        }
    }

    /// Called by the Character Palette when the user selects an emoji.
    override func insertText(_ insertString: Any) {
        guard currentTool == .stamp, let str = insertString as? String, !str.isEmpty else { return }
        currentStampImage = StampEmojis.renderEmoji(str)
        currentStampEmoji = str
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Forward Cmd shortcuts to the text view when editing — the main menu
        // intercepts these before keyDown reaches the overlay window.
        if event.modifierFlags.contains(.command), let char = event.charactersIgnoringModifiers {
            // Text editing: forward to NSTextView
            if let tv = textEditView {
                switch char {
                case "v": tv.paste(nil); return true
                case "c": tv.copy(nil); return true
                case "x": tv.cut(nil); return true
                case "a": tv.selectAll(nil); return true
                case "z":
                    if event.modifierFlags.contains(.shift) { tv.undoManager?.redo() }
                    else { tv.undoManager?.undo() }
                    return true
                default: break
                }
            }

            // Canvas undo/redo — intercept before main menu consumes the event
            if state == .selected {
                switch char {
                case "z":
                    if event.modifierFlags.contains(.shift) { redo() }
                    else { undo() }
                    return true
                case "y":
                    redo()
                    return true
                default: break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Space: reposition shape/selection mid-drag (design tool convention)
        if event.keyCode == 49 {
            // Swallow all repeats while repositioning to prevent system beep
            if spaceRepositioning { return }

            if !event.isARepeat {
                let isDraggingAnnotation =
                    currentAnnotation != nil && currentAnnotation!.tool != .pencil
                    && currentAnnotation!.tool != .marker
                let isDraggingNewSelection = state == .selecting

                if isDraggingAnnotation || isDraggingNewSelection {
                    spaceRepositioning = true
                    if isDraggingAnnotation {
                        spaceRepositionLast = lastDragPoint ?? .zero
                    } else if let windowPoint = window?.mouseLocationOutsideOfEventStream {
                        spaceRepositionLast = convert(windowPoint, from: nil)
                    }
                    return
                }
            }
        }

        switch event.keyCode {
        case 53:  // Escape
            if isScrollCapturing {
                overlayDelegate?.overlayViewDidRequestStopScrollCapture()
                return
            }
            // Block ESC only when actually capturing video; allow cancel
            // when recording mode is entered but capture hasn't started yet.
            guard !isCapturingVideo else { return }
            if textEditView != nil {
                cancelTextEditing()
            } else if PopoverHelper.isVisible {
                PopoverHelper.dismiss()
            } else {
                overlayDelegate?.overlayViewDidCancel()
            }
        case 48:  // Tab — toggle window snapping (only in idle state)
            if state == .idle {
                windowSnapEnabled = !windowSnapEnabled
                hoveredWindowRect = nil
                needsDisplay = true
            }
        case 3:  // F — full screen capture (only in idle state with snap on)
            if state == .idle && windowSnapEnabled {
                selectionRect = bounds
                state = .selected
                hoveredWindowRect = nil
                if autoQuickSaveMode {
                    autoQuickSaveMode = false
                    overlayDelegate?.overlayViewDidRequestQuickSave()
                } else {
                    showToolbars = true
                    scheduleBarcodeDetection()
                    overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
                    needsDisplay = true
                }
            }
        case 36:  // Return/Enter — only confirm overlay when not editing text
            if textEditView == nil, state == .selected {
                let saveMode =
                    !(UserDefaults.standard.object(forKey: "quickModeCopyToClipboard") as? Bool
                    ?? false)
                if saveMode {
                    overlayDelegate?.overlayViewDidRequestQuickSave()
                } else {
                    overlayDelegate?.overlayViewDidConfirm()
                }
            }
        case 51:  // Backspace/Delete — remove selected or hovered annotation
            guard textEditView == nil, state == .selected else { break }
            if let ann = selectedAnnotation {
                if let idx = annotations.firstIndex(where: { $0 === ann }) {
                    annotations.remove(at: idx)
                    undoStack.append(.deleted(ann, idx))
                    redoStack.removeAll()
                }
                selectedAnnotation = nil
                cachedCompositedImage = nil
                needsDisplay = true
            } else if let ann = hoveredAnnotation {
                if let idx = annotations.firstIndex(where: { $0 === ann }) {
                    annotations.remove(at: idx)
                    undoStack.append(.deleted(ann, idx))
                    redoStack.removeAll()
                }
                hoveredAnnotation = nil
                hoveredAnnotationClearTimer?.invalidate()
                hoveredAnnotationClearTimer = nil
                cachedCompositedImage = nil
                needsDisplay = true
            }
        default:
            // Auto-measure: hold "1" = vertical preview, hold "2" = horizontal preview
            if state == .selected && currentTool == .measure && textEditView == nil
                && !event.modifierFlags.contains(.command)
            {
                if let char = event.charactersIgnoringModifiers {
                    if char == "1" || char == "2" {
                        autoMeasureVertical = (char == "1")
                        updateAutoMeasurePreview()
                        return
                    }
                }
            }
            // Single-key tool shortcuts (only when selected, not editing text, no modifiers)
            if state == .selected && textEditView == nil && !event.modifierFlags.contains(.command)
                && !event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.control)
            {
                if let char = event.charactersIgnoringModifiers?.lowercased() {
                    switch char {
                    case "p":
                        handleToolbarAction(.tool(.pencil))
                        return
                    case "a":
                        handleToolbarAction(.tool(.arrow))
                        return
                    case "l":
                        handleToolbarAction(.tool(.line))
                        return
                    case "r":
                        handleToolbarAction(.tool(.rectangle))
                        return
                    case "t":
                        handleToolbarAction(.tool(.text))
                        return
                    case "m":
                        handleToolbarAction(.tool(.marker))
                        return
                    case "n":
                        handleToolbarAction(.tool(.number))
                        return
                    case "b":
                        handleToolbarAction(.tool(.blur))
                        return
                    case "x":
                        handleToolbarAction(.tool(.pixelate))
                        return
                    case "i":
                        handleToolbarAction(.tool(.colorSampler))
                        return
                    case "s":
                        handleToolbarAction(.tool(.select))
                        return
                    case "g":
                        handleToolbarAction(.tool(.stamp))
                        return
                    case "e":
                        if shouldAllowDetach() { handleToolbarAction(.detach) }
                        return
                    default: break
                    }
                }
            }
            if event.modifierFlags.contains(.command) {
                // When editing text, forward text-editing shortcuts to the text view
                if let tv = textEditView, let char = event.charactersIgnoringModifiers {
                    switch char {
                    case "a":
                        tv.selectAll(nil)
                        return
                    case "c":
                        tv.copy(nil)
                        return
                    case "v":
                        tv.paste(nil)
                        return
                    case "x":
                        tv.cut(nil)
                        return
                    case "z":
                        if event.modifierFlags.contains(.shift) {
                            tv.undoManager?.redo()
                        } else {
                            tv.undoManager?.undo()
                        }
                        return
                    default: break
                    }
                }
                if event.charactersIgnoringModifiers == "c" {
                    if state == .selected {
                        overlayDelegate?.overlayViewDidConfirm()
                    }
                    return
                }
                if event.charactersIgnoringModifiers == "s" {
                    if state == .selected {
                        overlayDelegate?.overlayViewDidRequestSave()
                    }
                    return
                }
                if event.charactersIgnoringModifiers == "0" {
                    if state == .selected && zoomLevel != 1.0 {
                        resetZoom()
                        showZoomLabel()
                        needsDisplay = true
                    }
                    return
                }
            }
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 && spaceRepositioning {
            spaceRepositioning = false
            return
        }
        // Commit auto-measure preview on key release
        if let preview = autoMeasurePreview {
            if let char = event.charactersIgnoringModifiers, char == "1" || char == "2" {
                annotations.append(preview)
                undoStack.append(.added(preview))
                redoStack.removeAll()
                autoMeasurePreview = nil
                cachedCompositedImage = nil
                needsDisplay = true
                return
            }
        }
        super.keyUp(with: event)
    }

    // MARK: - Undo/Redo

    func undo() {
        guard let entry = undoStack.last else { return }
        undoStack.removeLast()
        switch entry {
        case .added(let ann):
            // Undo an addition — handle batch (groupID) or single
            if let groupID = ann.groupID {
                var batch: [UndoEntry] = [.added(ann)]
                while let prev = undoStack.last, prev.annotation.groupID == groupID {
                    undoStack.removeLast()
                    batch.append(prev)
                }
                for e in batch { annotations.removeAll { $0 === e.annotation } }
                if ann.tool == .number { numberCounter = max(0, numberCounter - batch.count) }
                redoStack.append(contentsOf: batch)
                clearHoverIfNeeded(batch.map { $0.annotation })
            } else {
                annotations.removeAll { $0 === ann }
                if ann.tool == .number { numberCounter = max(0, numberCounter - 1) }
                redoStack.append(.added(ann))
                clearHoverIfNeeded([ann])
            }
        case .deleted(let ann, let idx):
            // Undo a deletion — re-insert at original position
            let safeIdx = min(idx, annotations.count)
            annotations.insert(ann, at: safeIdx)
            if ann.tool == .number { numberCounter += 1 }
            redoStack.append(.deleted(ann, idx))
        case .imageTransform(let previousImage, _):
            // Undo crop/flip — swap the current image with the saved one
            let currentImage = screenshotImage?.copy() as? NSImage ?? previousImage
            redoStack.append(.imageTransform(previousImage: currentImage, annotationOffsets: []))
            screenshotImage = previousImage
            // Update selectionRect to match restored image size
            if isEditorMode {
                selectionRect = NSRect(origin: .zero, size: previousImage.size)
                if isInsideScrollView { frame.size = previousImage.size }
            }
            cachedCompositedImage = nil
            resetZoom()
        }
        needsDisplay = true
    }

    private func clearHoverIfNeeded(_ removed: [Annotation]) {
        var changed = false
        if let h = hoveredAnnotation, removed.contains(where: { $0 === h }) {
            hoveredAnnotationClearTimer?.invalidate()
            hoveredAnnotationClearTimer = nil
            hoveredAnnotation = nil
            changed = true
        }
        if let s = selectedAnnotation, removed.contains(where: { $0 === s }) {
            selectedAnnotation = nil
            changed = true
        }
    }

    func redo() {
        guard let entry = redoStack.last else { return }
        redoStack.removeLast()
        switch entry {
        case .added(let ann):
            if let groupID = ann.groupID {
                var batch: [UndoEntry] = [.added(ann)]
                while let next = redoStack.last, next.annotation.groupID == groupID {
                    redoStack.removeLast()
                    batch.append(next)
                }
                for e in batch { annotations.append(e.annotation) }
                if ann.tool == .number { numberCounter += batch.count }
                undoStack.append(contentsOf: batch)
            } else {
                annotations.append(ann)
                if ann.tool == .number { numberCounter += 1 }
                undoStack.append(.added(ann))
            }
        case .deleted(let ann, let idx):
            // Redo a deletion — remove again
            annotations.removeAll { $0 === ann }
            if ann.tool == .number { numberCounter = max(0, numberCounter - 1) }
            undoStack.append(.deleted(ann, idx))
        case .imageTransform(let redoImage, _):
            // Redo crop/flip — swap back
            let currentImage = screenshotImage?.copy() as? NSImage ?? redoImage
            undoStack.append(.imageTransform(previousImage: currentImage, annotationOffsets: []))
            screenshotImage = redoImage
            if isEditorMode {
                selectionRect = NSRect(origin: .zero, size: redoImage.size)
                if isInsideScrollView { frame.size = redoImage.size }
            }
            cachedCompositedImage = nil
            if !isInsideScrollView { resetZoom() }
        }
        needsDisplay = true
    }

    // MARK: - Output

    /// Render screenshot + all existing annotations into a full-size image.
    /// Used as source for pixelate/blur so they operate on the composited result.
    func compositedImage() -> NSImage? {
        if let cached = cachedCompositedImage { return cached }
        guard let screenshot = screenshotImage else { return nil }
        if annotations.isEmpty { return screenshot }

        let drawRect = captureDrawRect
        let annotationsCopy = annotations
        var success = false
        let image = NSImage(size: drawRect.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else {
                return true
            }
            screenshot.draw(
                in: NSRect(origin: .zero, size: drawRect.size), from: .zero, operation: .copy,
                fraction: 1.0)
            // Translate so annotations at selectionRect coords render correctly
            context.cgContext.translateBy(x: -drawRect.origin.x, y: -drawRect.origin.y)
            for annotation in annotationsCopy {
                annotation.draw(in: context)
            }
            success = true
            return true
        }
        if !success {
            _ = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        if !success { return screenshot }
        cachedCompositedImage = image
        return image
    }
    func captureSelectedRegion() -> NSImage? {
        guard selectionRect.width > 0, selectionRect.height > 0 else { return nil }

        // Determine the source image's actual pixel scale so we render at
        // native resolution instead of relying on lockFocus() which always
        // picks the highest backing scale of any connected display.  This
        // prevents interpolation-upscaling when a 1x external monitor is
        // captured while a Retina display is also connected.
        let scale: CGFloat
        if let screenshot = screenshotImage,
            let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
        {
            scale = CGFloat(cg.width) / screenshot.size.width
        } else {
            scale = window?.backingScaleFactor ?? 2.0
        }

        let pixelW = Int(selectionRect.width * scale)
        let pixelH = Int(selectionRect.height * scale)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard
            let cgCtx = CGContext(
                data: nil,
                width: pixelW, height: pixelH,
                bitsPerComponent: 8,
                bytesPerRow: pixelW * 4,
                space: cs,
                bitmapInfo: bitmapInfo
            )
        else { return nil }

        // Scale the CG context so drawing in points maps to the correct pixels.
        cgCtx.scaleBy(x: scale, y: scale)
        cgCtx.translateBy(x: -selectionRect.origin.x, y: -selectionRect.origin.y)

        let nsContext = NSGraphicsContext(cgContext: cgCtx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        if let screenshot = screenshotImage {
            // In editor mode the image is at selectionRect (natural size);
            // in overlay mode it fills bounds (full screen).
            let drawRect = captureDrawRect
            screenshot.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
        }

        for annotation in annotations {
            annotation.draw(in: nsContext)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = cgCtx.makeImage() else { return nil }
        let image = NSImage(cgImage: cgImage, size: selectionRect.size)
        return image
    }

    func copyToClipboard() {
        guard let image = captureSelectedRegion() else { return }
        ImageEncoder.copyToClipboard(image)
    }

    // MARK: - Cleanup

    /// Pre-set a selection (used by delay capture to restore the previous region)
    func snapshotEditorState() -> OverlayEditorState {
        return OverlayEditorState(
            screenshotImage: screenshotImage,
            selectionRect: selectionRect,
            annotations: annotations,
            undoStack: undoStack,
            redoStack: redoStack,
            currentTool: currentTool,
            currentColor: currentColor,
            currentStrokeWidth: currentStrokeWidth,
            currentMarkerSize: currentMarkerSize,
            currentNumberSize: currentNumberSize,
            numberCounter: numberCounter,
            beautifyEnabled: beautifyEnabled,
            beautifyStyleIndex: beautifyStyleIndex
        )
    }

    /// Restore editor state.
    /// Translates annotation coordinates by `offset` (the selection origin in the original view).
    func setAnnotations(_ anns: [Annotation]) {
        annotations = anns
        undoStack = anns.map { .added($0) }
        redoStack = []
        cachedCompositedImage = nil
        needsDisplay = true
    }

    func applySelection(_ rect: NSRect) {
        selectionRect = rect
        selectionStart = rect.origin
        state = .selected
        showToolbars = true
        needsDisplay = true
    }

    func applyFullScreenSelection() {
        selectionRect = bounds
        selectionStart = bounds.origin
        state = .selected
        showToolbars = true
        scheduleBarcodeDetection()
        overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
        needsDisplay = true
    }

    func clearSelection() {
        state = .idle
        selectionRect = .zero
        remoteSelectionRect = .zero
        showToolbars = false
        needsDisplay = true
    }

    // MARK: - Tool options API (used by ToolOptionsRowView)

    func activeStrokeWidthForTool(_ tool: AnnotationTool) -> CGFloat {
        switch tool {
        case .number: return currentNumberSize
        case .marker: return currentMarkerSize
        case .loupe: return currentLoupeSize
        default: return currentStrokeWidth
        }
    }

    func setActiveStrokeWidth(_ value: CGFloat, for tool: AnnotationTool) {
        switch tool {
        case .number:
            currentNumberSize = value
            UserDefaults.standard.set(Double(value), forKey: "numberStrokeWidth")
        case .marker:
            currentMarkerSize = value
            UserDefaults.standard.set(Double(value), forKey: "markerStrokeWidth")
        case .loupe:
            currentLoupeSize = value
            UserDefaults.standard.set(Double(value), forKey: "loupeSize")
        default:
            currentStrokeWidth = value
            UserDefaults.standard.set(Double(value), forKey: "currentStrokeWidth")
        }
        needsDisplay = true
    }


    func showColorPickerPopover(target: ColorPickerTarget, anchorView: NSView? = nil, anchorRect: NSRect = .zero) {
        colorPickerTarget = target
        let picker = ColorPickerView()
        let initialColor: NSColor
        switch target {
        case .drawColor: initialColor = currentColor
        case .textBg: initialColor = textEditor.bgColor
        case .textOutline: initialColor = textEditor.outlineColor
        }
        picker.setColor(initialColor, opacity: currentColorOpacity)
        picker.customColors = customColors
        picker.selectedColorSlot = selectedColorSlot

        picker.onColorChanged = { [weak self] color in
            guard let self = self else { return }
            self.applyPickedColor(color)
            // Save to selected custom slot
            picker.saveToSelectedSlot(color)
            self.rebuildToolbarLayout()
        }
        picker.onOpacityChanged = { [weak self] opacity in
            guard let self = self else { return }
            self.currentColorOpacity = opacity
            OverlayView.lastUsedOpacity = opacity
            self.applyColorToSelectedAnnotation()
            self.needsDisplay = true
        }
        picker.onCustomSlotSelected = { [weak self] idx in
            self?.selectedColorSlot = idx
        }
        picker.onCustomColorsChanged = { [weak self] colors in
            self?.customColors = colors
            self?.saveCustomColors()
        }

        let size = picker.preferredSize
        if let anchor = anchorView {
            // Convert button rect to OverlayView coordinates — use full height so the popover
            // arrow clears the button whether it opens above or below
            let btnOrigin = anchor.convert(anchor.bounds.origin, to: self)
            let btnRect = NSRect(origin: btnOrigin, size: anchor.bounds.size)
            PopoverHelper.showAtRect(picker, size: size, rect: btnRect, in: self, preferredEdge: .minY)
        } else if anchorRect != .zero {
            PopoverHelper.showAtPoint(picker, size: size, at: NSPoint(x: anchorRect.midX, y: anchorRect.midY), in: self, preferredEdge: .minY)
        } else {
            PopoverHelper.showAtPoint(picker, size: size, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self, preferredEdge: .minY)
        }
    }

    private func applyPickedColor(_ color: NSColor) {
        switch colorPickerTarget {
        case .drawColor:
            currentColor = color
            applyColorToTextIfEditing()
            applyColorToSelectedAnnotation()
        case .textBg:
            textEditor.bgColor = color
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "textBgColor")
            }
        case .textOutline:
            textEditor.outlineColor = color
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "textOutlineColor")
            }
        }
        needsDisplay = true
    }

    func reset() {
        state = .idle
        selectionRect = .zero
        remoteSelectionRect = .zero
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        currentAnnotation = nil
        numberCounter = 0
        showToolbars = false
        bottomStripView?.isHidden = true
        rightStripView?.isHidden = true
        toolOptionsRowView?.isHidden = true
        PopoverHelper.dismiss()
        stopMouseHighlightMonitor()
        isTranslating = false
        translateEnabled = false
        autoMeasurePreview = nil
        selectedAnnotation = nil
        isDraggingAnnotation = false
        hoveredAnnotationClearTimer?.invalidate()
        hoveredAnnotationClearTimer = nil
        hoveredAnnotation = nil
        colorWheel.dismiss()
        beautifyEnabled = UserDefaults.standard.bool(forKey: "beautifyEnabled")
        beautifyStyleIndex = UserDefaults.standard.integer(forKey: "beautifyStyleIndex")
        beautifyMode =
            BeautifyMode(rawValue: UserDefaults.standard.integer(forKey: "beautifyMode")) ?? .window
        beautifyPadding = CGFloat(
            UserDefaults.standard.object(forKey: "beautifyPadding") as? Double ?? 48)
        beautifyCornerRadius = CGFloat(
            UserDefaults.standard.object(forKey: "beautifyCornerRadius") as? Double ?? 10)
        beautifyShadowRadius = CGFloat(
            UserDefaults.standard.object(forKey: "beautifyShadowRadius") as? Double ?? 20)
        beautifyBgRadius = CGFloat(
            UserDefaults.standard.object(forKey: "beautifyBgRadius") as? Double ?? 8)
        currentLineStyle =
            LineStyle(rawValue: UserDefaults.standard.integer(forKey: "currentLineStyle")) ?? .solid
        currentArrowStyle =
            ArrowStyle(rawValue: UserDefaults.standard.integer(forKey: "currentArrowStyle"))
            ?? .single
        currentRectFillStyle =
            RectFillStyle(rawValue: UserDefaults.standard.integer(forKey: "currentRectFillStyle"))
            ?? .stroke
        currentRectCornerRadius = CGFloat(
            UserDefaults.standard.object(forKey: "currentRectCornerRadius") as? Double ?? 0)
        textEditor.dismiss()
        sizeInputField?.removeFromSuperview()
        sizeInputField = nil
        isResizingAnnotation = false
        loupeCursorPoint = .zero
        colorSamplerPoint = .zero
        colorSamplerBitmap = nil
        overlayErrorTimer?.invalidate()
        overlayErrorTimer = nil
        overlayErrorMessage = nil
        barcodeDetector.cancel()
        hoveredWindowRect = nil
        isRecording = false
        isCapturingVideo = false
        recordingElapsedSeconds = 0
        isAnnotating = false
        annotationModeEverUsed = false
        needsDisplay = true
    }
}

// MARK: - NSTextFieldDelegate

extension OverlayView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
        -> Bool
    {
        if control.tag == 888 {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                commitSizeInputIfNeeded()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                sizeInputField?.removeFromSuperview()
                sizeInputField = nil
                window?.makeFirstResponder(self)
                needsDisplay = true
                return true
            }
        }
        if control.tag == 889 {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                commitZoomInputIfNeeded()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                zoomInputField?.removeFromSuperview()
                zoomInputField = nil
                window?.makeFirstResponder(self)
                needsDisplay = true
                return true
            }
        }
        return false
    }
}

// MARK: - NSTextViewDelegate

extension OverlayView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            textView.insertNewlineIgnoringFieldEditor(self)
            textDidChange(Notification(name: NSText.didChangeNotification))
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextEditing()
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        textEditor.resizeToFit()
        needsDisplay = true
    }
}

// MARK: - AnnotationCanvas conformance

extension OverlayView: AnnotationCanvas {
    var activeAnnotation: Annotation? {
        get { currentAnnotation }
        set { currentAnnotation = newValue }
    }

    func setNeedsDisplay() {
        needsDisplay = true
    }
}

// MARK: - TextEditingCanvas conformance

extension OverlayView: TextEditingCanvas {}

// MARK: - HoverButton

class HoverButton: NSButton {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        layer?.cornerRadius = 4
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}
