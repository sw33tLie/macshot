import Cocoa
import UniformTypeIdentifiers
import Vision

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
    func overlayViewDidRequestDelayCapture(seconds: Int, selectionRect: NSRect)
    func overlayViewDidRequestUpload()
    @available(macOS 14.0, *)
    func overlayViewDidRequestRemoveBackground()
    func overlayViewDidRequestStartRecording(rect: NSRect)
    func overlayViewDidRequestStopRecording()
    func overlayViewDidRequestDetach()
    func overlayViewDidRequestScrollCapture(rect: NSRect)
    func overlayViewDidRequestStopScrollCapture()
}

/// An entry in the undo/redo history.
enum UndoEntry {
    case added(Annotation)          // annotation was added; undo removes it
    case deleted(Annotation, Int)   // annotation was deleted at index; undo re-inserts it

    var annotation: Annotation {
        switch self { case .added(let a), .deleted(let a, _): return a }
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
    /// The view itself renders identically — same coordinates, same drawing, same everything.
    var isDetached: Bool = false

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
    private var zoomLevel: CGFloat = 1.0
    // The canvas point that stays pinned to zoomAnchorView on screen.
    // Both default to selection center; updated on each scroll/pinch to be the cursor position.
    private var zoomAnchorCanvas: NSPoint = .zero
    private var zoomAnchorView: NSPoint = .zero
    private var zoomFadingOut: Bool = false
    private var zoomLabelOpacity: CGFloat = 0.0
    private var zoomFadeTimer: Timer?
    private var zoomMin: CGFloat { isDetached ? 0.1 : 1.0 }
    private let zoomMax: CGFloat = 8.0

    // Selection
    private(set) var selectionRect: NSRect = .zero
    private var selectionStart: NSPoint = .zero
    private var isDraggingSelection: Bool = false
    private var isResizingSelection: Bool = false
    private var resizeHandle: ResizeHandle = .none
    private var dragOffset: NSPoint = .zero
    private var moveMode: Bool = false  // move tool active
    private var lastDragPoint: NSPoint?  // for shift constraint on flagsChanged
    private var isRightClickSelecting: Bool = false  // right-click quick save mode

    // Annotations
    private var annotations: [Annotation] = [] { didSet { cachedCompositedImage = nil } }
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private var currentAnnotation: Annotation?
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
    private var currentNumberSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "numberStrokeWidth") as? Double
        return saved != nil ? CGFloat(saved!) : 3.0
    }()
    private var currentMarkerSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "markerStrokeWidth") as? Double
        return saved != nil ? CGFloat(saved!) : 3.0
    }()
    private var numberCounter: Int = 0

    // Select/move mode
    private var selectedAnnotation: Annotation?
    private var isDraggingAnnotation: Bool = false
    private var annotationDragStart: NSPoint = .zero
    private var toolBeforeSelect: AnnotationTool?  // for middle-click toggle
    /// Annotation under the cursor when using a non-select drawing tool — enables on-the-fly move without switching tools.
    private var hoveredAnnotation: Annotation?
    /// Delays clearing hoveredAnnotation so the cursor can travel to handles/buttons that sit outside the hit area.
    private var hoveredAnnotationClearTimer: Timer?

    // Text editing
    private var textEditView: NSTextView?
    private var textScrollView: NSScrollView?
    private var textControlBar: NSView?
    private var textFontSize: CGFloat = 16
    private var textBold: Bool = false
    private var textItalic: Bool = false
    private var textUnderline: Bool = false
    private var textStrikethrough: Bool = false

    // Toolbars (drawn inline)
    private var bottomButtons: [ToolbarButton] = []
    var rightButtons: [ToolbarButton] = []
    private var bottomBarRect: NSRect = .zero
    var rightBarRect: NSRect = .zero
    private var showToolbars: Bool = false
    private var hoveredButtonIndex: Int = -1  // -1 = none, 0..N bottom, 1000+ right

    // Size label
    private var sizeLabelRect: NSRect = .zero
    private var sizeInputField: NSTextField?

    // Zoom label
    private var zoomLabelRect: NSRect = .zero
    private var zoomInputField: NSTextField?

    // Beautify
    private(set) var beautifyEnabled: Bool = UserDefaults.standard.bool(forKey: "beautifyEnabled")
    private(set) var beautifyStyleIndex: Int = UserDefaults.standard.integer(forKey: "beautifyStyleIndex")

    // Cursor enforcement timer — forces crosshair until selection is made
    private var cursorTimer: Timer?

    // Delay capture
    private var delaySeconds: Int = 0

    // Draggable toolbars
    private var bottomBarDragOffset: NSPoint = .zero
    private var rightBarDragOffset: NSPoint = .zero
    private var isDraggingBottomBar: Bool = false
    private var isDraggingRightBar: Bool = false
    private var toolbarDragStart: NSPoint = .zero

    // Color picker popover
    private var showColorPicker: Bool = false
    private var colorPickerRect: NSRect = .zero

    // Beautify style picker popover
    private var showBeautifyPicker: Bool = false
    private var beautifyPickerRect: NSRect = .zero
    private var hoveredBeautifyRow: Int = -1

    // Stroke width picker popover
    private var showStrokePicker: Bool = false
    private var strokePickerRect: NSRect = .zero
    private var hoveredStrokeRow: Int = -1
    private var strokeSmoothToggleRect: NSRect = .zero  // hit rect for the smooth toggle row

    // Pencil smoothing — persisted in UserDefaults
    private var pencilSmoothEnabled: Bool = UserDefaults.standard.object(forKey: "pencilSmoothEnabled") as? Bool ?? true

    // Delay picker popover
    private var showDelayPicker: Bool = false
    private var delayPickerRect: NSRect = .zero
    private var hoveredDelayRow: Int = -1

    // Upload confirm picker (toggle setting via right-click)
    private var showUploadConfirmPicker: Bool = false
    private var uploadConfirmPickerRect: NSRect = .zero

    // Upload confirm dialog (inline confirmation before uploading)
    private var showUploadConfirmDialog: Bool = false
    private var uploadConfirmDialogRect: NSRect = .zero
    private var uploadConfirmOKRect: NSRect = .zero
    private var uploadConfirmCancelRect: NSRect = .zero

    // Redact type picker
    private var showRedactTypePicker: Bool = false
    private var redactTypePickerRect: NSRect = .zero
    private var hoveredRedactTypeRow: Int = -1

    private static let redactTypeNames: [(key: String, label: String)] = [
        ("email", "Emails"),
        ("phone", "Phone Numbers"),
        ("ssn", "SSN"),
        ("credit_card", "Credit Cards"),
        ("cvv", "CVV Codes"),
        ("expiry", "Expiry Dates"),
        ("ipv4", "IP Addresses"),
        ("aws_key", "AWS Keys"),
        ("secret_assignment", "Secrets/Tokens"),
        ("hex_key", "Hex Keys"),
        ("bearer", "Bearer Tokens"),
    ]

    // Loupe size picker
    private var currentLoupeSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "loupeSize") as? Double
        return saved != nil ? CGFloat(saved!) : 120.0
    }()
    private var loupeCursorPoint: NSPoint = .zero
    private var markerCursorPoint: NSPoint = .zero
    private var colorSamplerPoint: NSPoint = .zero  // canvas space, for color picker tool
    private var colorSamplerBitmap: NSBitmapImageRep?  // cached bitmap for fast pixel sampling
    private var cachedCompositedImage: NSImage? = nil  // invalidated when annotations change
    private var showLoupeSizePicker: Bool = false
    private var loupeSizePickerRect: NSRect = .zero
    private var hoveredLoupeSizeRow: Int = -1

    // Translate language picker popover
    private var showTranslatePicker: Bool = false
    private var translatePickerRect: NSRect = .zero
    private var hoveredTranslateRow: Int = -1
    private var isTranslating: Bool = false
    private var translateEnabled: Bool = false

    // Crop tool state
    private var isCropDragging: Bool = false
    private var cropDragStart: NSPoint = .zero
    private var cropDragRect: NSRect = .zero

    // Press feedback for momentary buttons
    private var pressedButtonIndex: Int = -1

    // Annotation selection/resize controls
    private var isResizingAnnotation: Bool = false
    private var annotationResizeHandle: ResizeHandle = .none
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
    private var overlayErrorTimer: Timer? = nil

    // Barcode / QR detection
    private var detectedBarcodePayload: String? = nil
    private var barcodeActionRects: [NSRect] = []   // [0] = primary action, [1] = dismiss
    private var barcodeScanTask: DispatchWorkItem? = nil

    // Recording state
    var isRecording: Bool = false
    var recordingElapsedSeconds: Int = 0

    // Scroll capture state
    var isScrollCapturing: Bool = false
    var scrollCaptureStripCount: Int = 0
    var scrollCapturePixelSize: CGSize = .zero
    /// Global mouseDown monitor used to intercept Stop button clicks while ignoresMouseEvents is on.
    private var scrollCaptureClickMonitor: Any?
    private var annotationModeEverUsed: Bool = false  // once true, never show frozen screenshot again
    /// Activate the app visible under the selection rect so the user doesn't need a warmup click.
    private func activateAppUnderSelection() {
        guard selectionRect.width > 0, let win = window else { return }
        // Convert selection center to global screen coords
        let centerLocal = NSPoint(x: selectionRect.midX, y: selectionRect.midY)
        let centerScreen = win.convertToScreen(NSRect(origin: centerLocal, size: .zero)).origin

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        let overlayWindowNumber = win.windowNumber
        let screenH = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0

        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winNum = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  winNum != overlayWindowNumber else { continue }

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
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func startScrollCaptureMode() {
        isScrollCapturing = true
        scrollCaptureStripCount = 0
        scrollCapturePixelSize = .zero
        scrollCaptureStopRect = .zero
        // Pass mouse & scroll events through to the underlying app.
        activateAppUnderSelection()
        window?.ignoresMouseEvents = true
        window?.invalidateCursorRects(for: self)
        // Install a global monitor so the Stop button (drawn at scrollCaptureStopRect) is still
        // clickable even though the overlay window ignores mouse events.
        scrollCaptureClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self, self.isScrollCapturing else { return }
            guard let win = self.window else { return }
            // Global monitors: use NSEvent.mouseLocation (screen coords, bottom-left origin)
            let screenPt = NSEvent.mouseLocation
            let winLocal = win.convertFromScreen(NSRect(origin: screenPt, size: .zero)).origin
            let viewPt   = self.convert(winLocal, from: nil)
            if self.scrollCaptureStopRect != .zero && self.scrollCaptureStopRect.contains(viewPt) {
                DispatchQueue.main.async { self.overlayDelegate?.overlayViewDidRequestStopScrollCapture() }
            }
        }
        needsDisplay = true
    }

    func stopScrollCaptureMode() {
        isScrollCapturing = false
        scrollCaptureStripCount = 0
        scrollCapturePixelSize = .zero
        scrollCaptureStopRect = .zero
        if let m = scrollCaptureClickMonitor { NSEvent.removeMonitor(m); scrollCaptureClickMonitor = nil }
        window?.ignoresMouseEvents = false
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    var onAnnotationModeChanged: ((Bool) -> Void)?

    var isAnnotating: Bool = false {
        didSet {
            guard isAnnotating != oldValue else { return }
            if isAnnotating { annotationModeEverUsed = true }
            window?.ignoresMouseEvents = !isAnnotating
            window?.invalidateCursorRects(for: self)
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
    private var windowSnapEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "windowSnapEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "windowSnapEnabled") }
    }
    private var hoveredWindowRect: NSRect? = nil
    private var windowSnapQueryInFlight: Bool = false
    private let availableColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
        .systemPink, .systemTeal, .systemIndigo, .systemBrown, .systemMint, .systemCyan,
        .white, .lightGray, .gray, .darkGray, .black,
        NSColor(calibratedRed: 0.8, green: 0.2, blue: 0.2, alpha: 1),  // dark red
        NSColor(calibratedRed: 1.0, green: 0.6, blue: 0.0, alpha: 1),  // warm orange
        NSColor(calibratedRed: 0.0, green: 0.5, blue: 0.0, alpha: 1),  // dark green
        NSColor(calibratedRed: 0.0, green: 0.3, blue: 0.7, alpha: 1),  // navy
        NSColor(calibratedRed: 0.6, green: 0.2, blue: 0.6, alpha: 1),  // plum
        NSColor(calibratedRed: 1.0, green: 1.0, blue: 0.6, alpha: 1),  // cream
    ]
    private var customPickerSwatchRect: NSRect = .zero
    private var showCustomColorPicker: Bool = false
    private var customHSBCachedImage: NSImage?
    private var customBrightness: CGFloat = 1.0
    private var customPickerGradientRect: NSRect = .zero
    private var customPickerBrightnessRect: NSRect = .zero
    private var isDraggingHSBGradient: Bool = false
    private var isDraggingBrightnessSlider: Bool = false
    private var customPickerHue: CGFloat = 0
    private var customPickerSaturation: CGFloat = 1
    private static var lastUsedOpacity: CGFloat = 1.0
    private var currentColorOpacity: CGFloat = OverlayView.lastUsedOpacity
    private var opacitySliderRect: NSRect = .zero
    private var isDraggingOpacitySlider: Bool = false

    // Radial color wheel (right-click in drawing mode)
    private var showColorWheel: Bool = false
    private var colorWheelCenter: NSPoint = .zero
    private var colorWheelHoveredIndex: Int = -1  // -1 = none
    private let colorWheelRadius: CGFloat = 60
    private let colorWheelSwatchRadius: CGFloat = 14
    private let colorWheelColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemTeal, .systemBlue, .systemIndigo, .systemPurple,
        .systemPink, .white, .gray, .black,
    ]

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
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)

        // Keep forcing crosshair until the user finishes drawing a selection.
        // AppKit's cursor rect system races with app activation and can reset
        // the cursor to arrow; this timer wins that race by re-setting every frame.
        if window != nil {
            cursorTimer?.invalidate()
            cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { @MainActor [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                if self.state == .idle || self.state == .selecting {
                    NSCursor.crosshair.set()
                } else {
                    timer.invalidate()
                    self.cursorTimer = nil
                }
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Window snap: highlight hovered window in idle state.
        // CGWindowListCopyWindowInfo is expensive — run it on a background thread,
        // skipping new queries while one is already in flight.
        if state == .idle && windowSnapEnabled && !windowSnapQueryInFlight {
            guard let screenPoint = window.map({ NSPoint(x: $0.frame.origin.x + point.x, y: $0.frame.origin.y + point.y) }),
                  let viewWindow = window else { return }
            let overlayWindowNumber = viewWindow.windowNumber
            let windowOrigin = viewWindow.frame.origin
            let viewBounds = bounds
            let screenH = NSScreen.screens.map { $0.frame.maxY }.max() ?? NSScreen.main?.frame.height ?? 0
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
        if state == .selected && currentTool == .loupe {
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

        guard showToolbars else { return }
        var newHovered = -1

        for (i, btn) in bottomButtons.enumerated() {
            if btn.rect.contains(point) {
                newHovered = i
                break
            }
        }
        if newHovered == -1 {
            for (i, btn) in rightButtons.enumerated() {
                if btn.rect.contains(point) {
                    newHovered = 1000 + i
                    break
                }
            }
        }

        var needsRedraw = false
        if newHovered != hoveredButtonIndex {
            hoveredButtonIndex = newHovered
            needsRedraw = true
        }

        if needsRedraw {
            needsDisplay = true
        }

        // Stroke picker hover (including smooth toggle row = sentinel 99)
        if showStrokePicker && strokePickerRect.contains(point) {
            let widths: [CGFloat] = [1, 2, 3, 5, 8, 12, 20]
            let rowH: CGFloat = 30; let padding: CGFloat = 6
            var newRow = -1
            if currentTool == .pencil && strokeSmoothToggleRect.contains(point) {
                newRow = 99
            } else {
                for i in 0..<widths.count {
                    let rowY = strokePickerRect.maxY - padding - rowH * CGFloat(i + 1)
                    let rowRect = NSRect(x: strokePickerRect.minX, y: rowY, width: strokePickerRect.width, height: rowH)
                    if rowRect.contains(point) { newRow = i; break }
                }
            }
            if newRow != hoveredStrokeRow { hoveredStrokeRow = newRow; needsDisplay = true }
        } else if showStrokePicker && hoveredStrokeRow != -1 {
            hoveredStrokeRow = -1; needsDisplay = true
        }

        // Loupe size picker hover
        if showLoupeSizePicker && loupeSizePickerRect.contains(point) {
            let sizes = 8
            let rowH: CGFloat = 28
            let padding: CGFloat = 6
            var newRow = -1
            for i in 0..<sizes {
                let rowY = loupeSizePickerRect.maxY - padding - rowH * CGFloat(i + 1)
                let rowRect = NSRect(x: loupeSizePickerRect.minX, y: rowY, width: loupeSizePickerRect.width, height: rowH)
                if rowRect.contains(point) { newRow = i; break }
            }
            if newRow != hoveredLoupeSizeRow { hoveredLoupeSizeRow = newRow; needsDisplay = true }
        }

        // Delay picker hover
        if showDelayPicker && delayPickerRect.contains(point) {
            let options = 7 // number of options
            let rowH: CGFloat = 28
            let padding: CGFloat = 6
            var newRow = -1
            for i in 0..<options {
                let rowY = delayPickerRect.maxY - padding - rowH * CGFloat(i + 1)
                let rowRect = NSRect(x: delayPickerRect.minX, y: rowY, width: delayPickerRect.width, height: rowH)
                if rowRect.contains(point) { newRow = i; break }
            }
            if newRow != hoveredDelayRow { hoveredDelayRow = newRow; needsDisplay = true }
        }

        // Redact type picker hover
        if showRedactTypePicker && redactTypePickerRect.contains(point) {
            let types = OverlayView.redactTypeNames.count
            let rowH: CGFloat = 26; let padding: CGFloat = 6
            var newRow = -1
            for i in 0..<types {
                let rowY = redactTypePickerRect.maxY - padding - rowH * CGFloat(i + 1)
                let rowRect = NSRect(x: redactTypePickerRect.minX, y: rowY, width: redactTypePickerRect.width, height: rowH)
                if rowRect.contains(point) { newRow = i; break }
            }
            if newRow != hoveredRedactTypeRow { hoveredRedactTypeRow = newRow; needsDisplay = true }
        }

        // Translate language picker hover
        if showTranslatePicker && translatePickerRect.contains(point) {
            let langs = TranslationService.availableLanguages.count
            let rowH: CGFloat = 26; let padding: CGFloat = 6
            var newRow = -1
            for i in 0..<langs {
                let rowY = translatePickerRect.maxY - padding - rowH * CGFloat(i + 1)
                let rowRect = NSRect(x: translatePickerRect.minX, y: rowY, width: translatePickerRect.width, height: rowH)
                if rowRect.contains(point) { newRow = i; break }
            }
            if newRow != hoveredTranslateRow { hoveredTranslateRow = newRow; needsDisplay = true }
        }

        // Hover-to-move: only active for the core shape/drawing tools.
        let hoverMoveTools: Set<AnnotationTool> = [.pencil, .arrow, .line, .rectangle, .filledRectangle, .ellipse]
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
        if state == .selected && hoverMoveTools.contains(currentTool) && !isDraggingAnnotation && !isResizingAnnotation {
            let canvasPoint = viewToCanvas(point)
            let newHovered = annotations.reversed().first { $0.isMovable && $0.hitTest(point: canvasPoint) }

            if newHovered !== nil {
                // Cursor is directly over an annotation — show controls immediately.
                hoveredAnnotationClearTimer?.invalidate()
                hoveredAnnotationClearTimer = nil
                if newHovered !== hoveredAnnotation {
                    hoveredAnnotation = newHovered
                    window?.invalidateCursorRects(for: self)
                    needsDisplay = true
                }
            } else if hoveredAnnotation != nil {
                // Cursor left the annotation hit area. Check if it's within the extended controls
                // zone (handles + delete button sit outside the hit area) — if so, keep hoveredAnnotation.
                let controlsActive = annotationDeleteButtonRect.contains(point)
                    || annotationResizeHandleRects.contains { $0.1.insetBy(dx: -8, dy: -8).contains(point) }

                if controlsActive {
                    // Inside a control rect — cancel any pending clear and stay active.
                    hoveredAnnotationClearTimer?.invalidate()
                    hoveredAnnotationClearTimer = nil
                } else if hoveredAnnotationClearTimer == nil {
                    // Start a linger timer — gives the cursor time to travel to a nearby handle/button.
                    hoveredAnnotationClearTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                        guard let self = self else { return }
                        self.hoveredAnnotationClearTimer = nil
                        self.hoveredAnnotation = nil
                        self.window?.invalidateCursorRects(for: self)
                        self.needsDisplay = true
                    }
                }
            }
        } else if hoveredAnnotation != nil && (!hoverMoveTools.contains(currentTool) || isDraggingAnnotation || isResizingAnnotation) {
            hoveredAnnotationClearTimer?.invalidate()
            hoveredAnnotationClearTimer = nil
            hoveredAnnotation = nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    // Diagonal resize cursors (macOS doesn't provide these publicly)
    private static let nwseCursor: NSCursor = {
        // Top-left <-> Bottom-right (backslash direction)
        if let cursor = NSCursor.perform(NSSelectorFromString("_windowResizeNorthWestSouthEastCursor"))?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .crosshair
    }()

    private static let neswCursor: NSCursor = {
        // Top-right <-> Bottom-left (slash direction)
        if let cursor = NSCursor.perform(NSSelectorFromString("_windowResizeNorthEastSouthWestCursor"))?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .crosshair
    }()

    override func resetCursorRects() {
        super.resetCursorRects()
        if isRecording && !isAnnotating {
            addCursorRect(bounds, cursor: .arrow)
            return
        }
        // When text editing, force arrow cursor everywhere
        if textEditView != nil {
            addCursorRect(bounds, cursor: .arrow)
            return
        }
        if state == .idle {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }

        guard state == .selected, selectionRect.width > 1, selectionRect.height > 1 else {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }

        let edgeThickness: CGFloat = 6
        let r = selectionRect
        let hs = handleSize + 4  // handle hit area

        // Corner handles — diagonal resize cursors
        // Top-left (NWSE)
        addCursorRect(NSRect(x: r.minX - hs/2, y: r.maxY - hs/2, width: hs, height: hs), cursor: Self.nwseCursor)
        // Bottom-right (NWSE)
        addCursorRect(NSRect(x: r.maxX - hs/2, y: r.minY - hs/2, width: hs, height: hs), cursor: Self.nwseCursor)
        // Top-right (NESW)
        addCursorRect(NSRect(x: r.maxX - hs/2, y: r.maxY - hs/2, width: hs, height: hs), cursor: Self.neswCursor)
        // Bottom-left (NESW)
        addCursorRect(NSRect(x: r.minX - hs/2, y: r.minY - hs/2, width: hs, height: hs), cursor: Self.neswCursor)

        // Edge handles — horizontal/vertical resize cursors
        // Top edge
        addCursorRect(NSRect(x: r.minX + hs/2, y: r.maxY - edgeThickness/2, width: r.width - hs, height: edgeThickness), cursor: .resizeUpDown)
        // Bottom edge
        addCursorRect(NSRect(x: r.minX + hs/2, y: r.minY - edgeThickness/2, width: r.width - hs, height: edgeThickness), cursor: .resizeUpDown)
        // Left edge
        addCursorRect(NSRect(x: r.minX - edgeThickness/2, y: r.minY + hs/2, width: edgeThickness, height: r.height - hs), cursor: .resizeLeftRight)
        // Right edge
        addCursorRect(NSRect(x: r.maxX - edgeThickness/2, y: r.minY + hs/2, width: edgeThickness, height: r.height - hs), cursor: .resizeLeftRight)

        // Toolbar buttons — arrow cursor so they look clickable
        if showToolbars {
            for btn in bottomButtons {
                if btn.rect.width > 0 {
                    addCursorRect(btn.rect, cursor: .arrow)
                }
            }
            for btn in rightButtons {
                if btn.rect.width > 0 {
                    addCursorRect(btn.rect, cursor: .arrow)
                }
            }
            if bottomBarRect.width > 0 {
                addCursorRect(bottomBarRect, cursor: .arrow)
            }
            if rightBarRect.width > 0 {
                addCursorRect(rightBarRect, cursor: .arrow)
            }
        }

        // Color picker popup — arrow cursor
        if showColorPicker && colorPickerRect.width > 0 {
            addCursorRect(colorPickerRect, cursor: .arrow)
        }

        // Beautify/Stroke pickers — pointing hand for rows
        let popups: [(Bool, NSRect, Int)] = [
            (showBeautifyPicker, beautifyPickerRect, BeautifyRenderer.styles.count),
            (showStrokePicker, strokePickerRect, 7) // 7 widths
        ]
        for (isVisible, rect, count) in popups {
            if isVisible && rect.width > 0 {
                addCursorRect(rect, cursor: .arrow) // default arrow for background
                let rowH: CGFloat = 28
                let padding: CGFloat = 6
                for i in 0..<count {
                    let rowY = rect.maxY - padding - rowH * CGFloat(i + 1)
                    let rowRect = NSRect(x: rect.minX, y: rowY, width: rect.width, height: rowH)
                    addCursorRect(rowRect, cursor: .pointingHand)
                }
            }
        }

        // Loupe size picker
        if showLoupeSizePicker && loupeSizePickerRect.width > 0 {
            addCursorRect(loupeSizePickerRect, cursor: .arrow)
            let rowH: CGFloat = 28; let padding: CGFloat = 6
            for i in 0..<8 {
                let rowY = loupeSizePickerRect.maxY - padding - rowH * CGFloat(i + 1)
                addCursorRect(NSRect(x: loupeSizePickerRect.minX, y: rowY, width: loupeSizePickerRect.width, height: rowH), cursor: .pointingHand)
            }
        }
        // Delay picker
        if showDelayPicker && delayPickerRect.width > 0 {
            addCursorRect(delayPickerRect, cursor: .arrow)
            let rowH: CGFloat = 28; let padding: CGFloat = 6
            for i in 0..<7 {
                let rowY = delayPickerRect.maxY - padding - rowH * CGFloat(i + 1)
                addCursorRect(NSRect(x: delayPickerRect.minX, y: rowY, width: delayPickerRect.width, height: rowH), cursor: .pointingHand)
            }
        }
        // Upload confirm picker (handled after bounds crosshair below)
        // Redact type picker
        if showRedactTypePicker && redactTypePickerRect.width > 0 {
            addCursorRect(redactTypePickerRect, cursor: .arrow)
            let rowH: CGFloat = 26; let padding: CGFloat = 6
            for i in 0..<OverlayView.redactTypeNames.count {
                let rowY = redactTypePickerRect.maxY - padding - rowH * CGFloat(i + 1)
                addCursorRect(NSRect(x: redactTypePickerRect.minX, y: rowY, width: redactTypePickerRect.width, height: rowH), cursor: .pointingHand)
            }
        }

        // Translate picker
        if showTranslatePicker && translatePickerRect.width > 0 {
            addCursorRect(translatePickerRect, cursor: .arrow)
            let rowH: CGFloat = 26; let padding: CGFloat = 6
            for i in 0..<TranslationService.availableLanguages.count {
                let rowY = translatePickerRect.maxY - padding - rowH * CGFloat(i + 1)
                addCursorRect(NSRect(x: translatePickerRect.minX, y: rowY, width: translatePickerRect.width, height: rowH), cursor: .pointingHand)
            }
        }

        // Size label — pointer cursor to indicate clickable
        if sizeLabelRect.width > 0 && sizeInputField == nil {
            addCursorRect(sizeLabelRect, cursor: .pointingHand)
        }

        // Zoom label — pointer cursor to indicate clickable
        if zoomLabelRect.width > 0 && zoomLabelOpacity > 0 && zoomInputField == nil {
            addCursorRect(zoomLabelRect, cursor: .pointingHand)
        }

        // Inside selection — crosshair for drawing, open hand for move mode
        let innerRect = r.insetBy(dx: edgeThickness, dy: edgeThickness)
        if innerRect.width > 0 && innerRect.height > 0 {
            let selectionCursor: NSCursor = currentTool == .select ? .openHand : .crosshair
            addCursorRect(innerRect, cursor: selectionCursor)
        }

        // Hover-to-move: openHand over a hovered annotation when using a shape/drawing tool
        let hoverMoveToolsForCursor: Set<AnnotationTool> = [.pencil, .arrow, .line, .rectangle, .filledRectangle, .ellipse]
        if hoverMoveToolsForCursor.contains(currentTool), let hovered = hoveredAnnotation {
            // Use a generous inset so the cursor rect covers the annotation's visual bounds
            let bb = hovered.boundingRect.insetBy(dx: -12, dy: -12)
            if bb.width > 0 && bb.height > 0 {
                addCursorRect(bb, cursor: .openHand)
            }
        }

        // When select tool is active, layer annotation-specific cursors on top
        if currentTool == .select, let selected = selectedAnnotation {
            // Annotation bounding box interior → move cursor (already covered by openHand above)
            // Resize handles → appropriate resize cursors
            let isEndpointTool = selected.tool == .arrow || selected.tool == .line || selected.tool == .measure
            for (handle, rect) in annotationResizeHandleRects {
                let hitRect = rect.insetBy(dx: -4, dy: -4)
                if isEndpointTool {
                    addCursorRect(hitRect, cursor: .crosshair)
                } else {
                switch handle {
                case .topLeft, .bottomRight:
                    addCursorRect(hitRect, cursor: Self.nwseCursor)
                case .topRight, .bottomLeft:
                    addCursorRect(hitRect, cursor: Self.neswCursor)
                case .top, .bottom:
                    addCursorRect(hitRect, cursor: .resizeUpDown)
                case .left, .right:
                    addCursorRect(hitRect, cursor: .resizeLeftRight)
                default:
                    break
                }
                }
            }
            // Delete / edit buttons → arrow
            if annotationDeleteButtonRect.width > 0 {
                addCursorRect(annotationDeleteButtonRect, cursor: .arrow)
            }
            if annotationEditButtonRect.width > 0 {
                addCursorRect(annotationEditButtonRect, cursor: .arrow)
            }
        }

        // Outside selection — crosshair for new selection
        addCursorRect(bounds, cursor: .crosshair)

        // Upload confirm picker — override crosshair with arrow (must come after bounds rect)
        if showUploadConfirmPicker && uploadConfirmPickerRect.width > 0 {
            addCursorRect(uploadConfirmPickerRect, cursor: .arrow)
            let rowY = uploadConfirmPickerRect.minY + 8
            let rowRect = NSRect(x: uploadConfirmPickerRect.minX, y: rowY, width: uploadConfirmPickerRect.width, height: 32)
            addCursorRect(rowRect, cursor: .pointingHand)
        }

        // Upload confirm dialog — override crosshair with arrow
        if showUploadConfirmDialog && uploadConfirmDialogRect.width > 0 {
            addCursorRect(uploadConfirmDialogRect, cursor: .arrow)
            if uploadConfirmOKRect.width > 0 { addCursorRect(uploadConfirmOKRect, cursor: .pointingHand) }
            if uploadConfirmCancelRect.width > 0 { addCursorRect(uploadConfirmCancelRect, cursor: .pointingHand) }
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current else { return }

        window?.invalidateCursorRects(for: self)

        // In editor mode: dark background, draw image centered at natural size (no stretch).
        // Reserve padding around the image for toolbars (bottom bar + right bar).
        if isDetached {
            let padLeft:   CGFloat = 8
            let padRight:  CGFloat = 52  // right toolbar width
            let padBottom: CGFloat = 52  // bottom toolbar height
            let padTop:    CGFloat = 8
            let availW = bounds.width  - padLeft - padRight
            let availH = bounds.height - padBottom - padTop
            if let image = screenshotImage {
                let imgW = image.size.width
                let imgH = image.size.height
                let cx = padLeft + max(0, (availW - imgW) / 2)
                let cy = padBottom + max(0, (availH - imgH) / 2)
                let newRect = NSRect(x: cx, y: cy, width: imgW, height: imgH)
                let dx = newRect.origin.x - selectionRect.origin.x
                let dy = newRect.origin.y - selectionRect.origin.y
                if dx != 0 || dy != 0 {
                    for ann in annotations { ann.move(dx: dx, dy: dy) }
                    for entry in undoStack { entry.annotation.move(dx: dx, dy: dy) }
                    for entry in redoStack { entry.annotation.move(dx: dx, dy: dy) }
                }
                selectionRect = newRect
            }
            NSColor(white: 0.15, alpha: 1.0).setFill()
            NSBezierPath(rect: bounds).fill()
            // Draw image with zoom transform applied
            context.saveGraphicsState()
            applyZoomTransform(to: context)
            if let image = screenshotImage {
                image.draw(in: selectionRect, from: .zero, operation: .copy, fraction: 1.0)
            }
            context.restoreGraphicsState()
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
            if !isDetached {
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
            NSBezierPath(rect: selectionRect).setClip()
            applyZoomTransform(to: context)
            for annotation in annotations where annotation.tool == .translateOverlay {
                annotation.draw(in: context)
            }
            context.restoreGraphicsState()

            // Draw user annotations unclipped — strokes can continue past the selection border.
            context.saveGraphicsState()
            applyZoomTransform(to: context)
            for annotation in annotations where annotation.tool != .translateOverlay {
                annotation.draw(in: context)
            }
            currentAnnotation?.draw(in: context)

            // Live loupe preview when loupe tool is active
            if currentTool == .loupe && selectionRect.contains(loupeCursorPoint) && loupeCursorPoint != .zero {
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
                } else if let hovered = hoveredAnnotation, [AnnotationTool.pencil, .arrow, .line, .rectangle, .filledRectangle, .ellipse].contains(currentTool) {
                    drawAnnotationControls(for: hovered)
                }
            }

            // Marker cursor preview inside zoom transform so it scales with zoom
            if currentTool == .marker && markerCursorPoint != .zero && currentAnnotation == nil {
                drawMarkerCursorPreview(at: markerCursorPoint)
            }

            context.restoreGraphicsState()

            // Selection border — hidden in editor mode, red during scroll capture, purple otherwise
            if !isDetached {
                let borderPath = NSBezierPath(rect: selectionRect)
                borderPath.lineWidth = isScrollCapturing ? 2.5 : 2.0
                (isScrollCapturing ? NSColor.systemRed : ToolbarLayout.accentColor).setStroke()
                borderPath.stroke()
            }

            if !isRecording && !isScrollCapturing && !isDetached {
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

            // Toolbars
            if showToolbars && state == .selected && !isScrollCapturing {
                rebuildToolbarLayout()
                ToolbarLayout.drawToolbar(barRect: bottomBarRect, buttons: bottomButtons, selectionSize: selectionRect.size)
                ToolbarLayout.drawToolbar(barRect: rightBarRect, buttons: rightButtons, selectionSize: nil)


                // Color picker popover
                if showColorPicker {
                    drawColorPicker()
                }

                // Beautify style picker popover
                if showBeautifyPicker {
                    drawBeautifyPicker()
                }

                // Stroke width picker popover
                if showStrokePicker {
                    drawStrokePicker()
                }

                // Loupe size picker
                if showLoupeSizePicker {
                    drawLoupeSizePicker()
                }

                // Delay picker
                if showDelayPicker {
                    drawDelayPicker()
                }

                // Upload confirm picker
                if showUploadConfirmPicker {
                    drawUploadConfirmPicker()
                }

                // Redact type picker
                if showRedactTypePicker {
                    drawRedactTypePicker()
                }

                // Translate language picker
                if showTranslatePicker {
                    drawTranslatePicker()
                }

                // Tooltip for hovered button
                drawHoveredTooltip()
            }

            // Radial color wheel
            if showColorWheel {
                drawColorWheel()
            }
        }

        // Upload confirm dialog — drawn on top of everything
        if showUploadConfirmDialog {
            drawUploadConfirmDialog()
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
            str.draw(at: NSPoint(x: msgRect.minX + padding, y: msgRect.minY + padding / 2), withAttributes: attrs)
        }

        // Barcode / QR badge
        if state == .selected { drawBarcodeBar() }

        // Recording HUD
        if isRecording { drawRecordingHUD() }

        // Scroll capture HUD (drawn on top of everything when active)
        if isScrollCapturing { drawScrollCaptureHUD() }

        // Keep cursor rects in sync with current selection
        window?.invalidateCursorRects(for: self)
    }

    private func drawHoveredTooltip() {
        guard hoveredButtonIndex >= 0 else { return }

        // Find the hovered button
        var btn: ToolbarButton?
        var isBottomBar = false
        if hoveredButtonIndex < 1000 && hoveredButtonIndex < bottomButtons.count {
            btn = bottomButtons[hoveredButtonIndex]
            isBottomBar = true
        } else if hoveredButtonIndex >= 1000 && (hoveredButtonIndex - 1000) < rightButtons.count {
            btn = rightButtons[hoveredButtonIndex - 1000]
        }
        guard let button = btn, !button.tooltip.isEmpty else { return }

        // While move-selection drag is active, show a contextual hint
        var tooltipText = button.tooltip
        if moveMode, case .moveSelection = button.action {
            tooltipText = "Drag to reposition"
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = tooltipText as NSString
        let textSize = str.size(withAttributes: attrs)
        let padding: CGFloat = 6
        let tipWidth = textSize.width + padding * 2
        let tipHeight = textSize.height + padding

        let tipX = button.rect.midX - tipWidth / 2
        let tipY: CGFloat
        if isBottomBar {
            // Show below bottom bar, unless it would go off screen
            let below = bottomBarRect.minY - tipHeight - 4
            if below >= bounds.minY + 2 {
                tipY = below
            } else {
                tipY = bottomBarRect.maxY + 4
            }
        } else {
            // Right bar: show to the left
            let tipRect = NSRect(x: button.rect.minX - tipWidth - 6, y: button.rect.midY - tipHeight / 2, width: tipWidth, height: tipHeight)
            ToolbarLayout.bgColor.setFill()
            NSBezierPath(roundedRect: tipRect, xRadius: 4, yRadius: 4).fill()
            str.draw(at: NSPoint(x: tipRect.minX + padding, y: tipRect.minY + padding / 2), withAttributes: attrs)
            return
        }

        let tipRect = NSRect(x: tipX, y: tipY, width: tipWidth, height: tipHeight)
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: tipRect, xRadius: 4, yRadius: 4).fill()
        str.draw(at: NSPoint(x: tipRect.minX + padding, y: tipRect.minY + padding / 2), withAttributes: attrs)
    }

    private func drawIdleHelperText() {
        let line1 = windowSnapEnabled
            ? "Click a window  ·  Drag for custom area  ·  F for full screen"
            : "Drag to select  ·  Click for full screen"
        let copyMode = UserDefaults.standard.object(forKey: "quickModeCopyToClipboard") as? Bool ?? false
        let line2: String
        if windowSnapEnabled {
            line2 = copyMode
                ? "Right-click a window to quick copy  ·  drag for custom area"
                : "Right-click a window to quick save  ·  drag for custom area"
        } else {
            line2 = copyMode
                ? "Right-click: drag to quick copy  ·  click to copy full screen"
                : "Right-click: drag to quick save  ·  click to save full screen"
        }
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
        let attrs2: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: dimColor]
        let attrs3prefix: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: dimColor]
        let attrs3state: [NSAttributedString.Key: Any]  = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: snapColor]
        let attrs3suffix: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: dimColor]

        let size1       = (line1 as NSString).size(withAttributes: attrs1)
        let size2       = (line2 as NSString).size(withAttributes: attrs2)
        let size3pre    = (line3prefix as NSString).size(withAttributes: attrs3prefix)
        let size3state  = (line3state as NSString).size(withAttributes: attrs3state)
        let size3suf    = (line3suffix as NSString).size(withAttributes: attrs3suffix)
        let size3total  = CGSize(width: size3pre.width + size3state.width + size3suf.width,
                                 height: max(size3pre.height, size3state.height, size3suf.height))

        let lineSpacing: CGFloat = 6
        let padding: CGFloat = 14
        let totalTextHeight = size1.height + lineSpacing + size2.height + lineSpacing + size3total.height
        let bgWidth = max(size1.width, size2.width, size3total.width) + padding * 2
        let bgHeight = totalTextHeight + padding * 2

        let bgX = bounds.midX - bgWidth / 2
        let bgY = bounds.midY - bgHeight / 2
        let bgRect = NSRect(x: bgX, y: bgY, width: bgWidth, height: bgHeight)

        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 8, yRadius: 8).fill()

        let textY1 = bgY + padding + size2.height + lineSpacing + size3total.height + lineSpacing
        let textY2 = bgY + padding + size3total.height + lineSpacing
        let textY3 = bgY + padding

        (line1 as NSString).draw(at: NSPoint(x: bounds.midX - size1.width / 2, y: textY1), withAttributes: attrs1)
        (line2 as NSString).draw(at: NSPoint(x: bounds.midX - size2.width / 2, y: textY2), withAttributes: attrs2)

        // Draw line3 as three segments with different colors
        let line3startX = bounds.midX - size3total.width / 2
        let line3Y = textY3 + (size3total.height - size3pre.height) / 2
        (line3prefix as NSString).draw(at: NSPoint(x: line3startX, y: line3Y), withAttributes: attrs3prefix)
        (line3state as NSString).draw(at: NSPoint(x: line3startX + size3pre.width, y: line3Y), withAttributes: attrs3state)
        (line3suffix as NSString).draw(at: NSPoint(x: line3startX + size3pre.width + size3state.width, y: line3Y), withAttributes: attrs3suffix)
    }

    private func drawSelectingHelperText() {
        guard selectionRect.width >= 1, selectionRect.height >= 1 else { return }

        let text: String
        if isRightClickSelecting {
            let copyMode = UserDefaults.standard.object(forKey: "quickModeCopyToClipboard") as? Bool ?? false
            if copyMode {
                text = "Release to copy to clipboard"
            } else {
                let dirURL: URL
                if let savedPath = UserDefaults.standard.string(forKey: "saveDirectory") {
                    dirURL = URL(fileURLWithPath: savedPath)
                } else {
                    dirURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                        ?? FileManager.default.homeDirectoryForCurrentUser
                }
                let folderName = dirURL.lastPathComponent
                text = "Release to save to \(folderName)/"
            }
        } else {
            text = "Release to annotate and edit"
        }

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

        (text as NSString).draw(at: NSPoint(x: bgRect.minX + padding, y: bgRect.minY + padding / 2), withAttributes: attrs)
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
        (text as NSString).draw(at: NSPoint(x: rect.minX + padding, y: rect.minY + padding / 2), withAttributes: attrs)
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
        (text as NSString).draw(at: NSPoint(x: labelX + padding, y: labelY + padding / 2), withAttributes: attrs)
    }

    private func showSizeInput() {
        let scale = window?.backingScaleFactor ?? 2.0
        let pixelW = Int(selectionRect.width * scale)
        let pixelH = Int(selectionRect.height * scale)

        let fieldWidth: CGFloat = 120
        let fieldHeight: CGFloat = 22
        let fieldX = sizeLabelRect.midX - fieldWidth / 2
        let fieldY = sizeLabelRect.minY + (sizeLabelRect.height - fieldHeight) / 2

        let field = NSTextField(frame: NSRect(x: fieldX, y: fieldY, width: fieldWidth, height: fieldHeight))
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
            currentText = rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
        }

        let fieldWidth: CGFloat = 70
        let fieldHeight: CGFloat = 22
        let fieldX = zoomLabelRect.midX - fieldWidth / 2
        let fieldY = zoomLabelRect.minY + (zoomLabelRect.height - fieldHeight) / 2

        let field = NSTextField(frame: NSRect(x: fieldX, y: fieldY, width: fieldWidth, height: fieldHeight))
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
        let cleaned = input.replacingOccurrences(of: "×", with: "").replacingOccurrences(of: "x", with: "").trimmingCharacters(in: .whitespaces)
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

    private func drawColorWheel() {
        let center = colorWheelCenter
        let count = colorWheelColors.count
        let angleStep = (2 * CGFloat.pi) / CGFloat(count)

        // Dim background
        NSColor.black.withAlphaComponent(0.3).setFill()
        let bgCircle = NSBezierPath(ovalIn: NSRect(
            x: center.x - colorWheelRadius - colorWheelSwatchRadius - 8,
            y: center.y - colorWheelRadius - colorWheelSwatchRadius - 8,
            width: (colorWheelRadius + colorWheelSwatchRadius + 8) * 2,
            height: (colorWheelRadius + colorWheelSwatchRadius + 8) * 2
        ))
        bgCircle.fill()

        // Draw each color swatch in a circle
        for (i, color) in colorWheelColors.enumerated() {
            // Start from top (–π/2) and go clockwise
            let angle = -CGFloat.pi / 2 + CGFloat(i) * angleStep
            let sx = center.x + colorWheelRadius * cos(angle)
            let sy = center.y + colorWheelRadius * sin(angle)

            let isHovered = (i == colorWheelHoveredIndex)
            let radius = isHovered ? colorWheelSwatchRadius + 4 : colorWheelSwatchRadius
            let swatchRect = NSRect(x: sx - radius, y: sy - radius, width: radius * 2, height: radius * 2)

            // Shadow for depth
            if isHovered {
                NSColor.black.withAlphaComponent(0.4).setFill()
                NSBezierPath(ovalIn: swatchRect.insetBy(dx: -2, dy: -2)).fill()
            }

            color.setFill()
            NSBezierPath(ovalIn: swatchRect).fill()

            // Border
            let borderColor: NSColor = isHovered ? .white : .white.withAlphaComponent(0.5)
            borderColor.setStroke()
            let border = NSBezierPath(ovalIn: swatchRect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = isHovered ? 2.5 : 1.0
            border.stroke()

            // Check mark for current color
            if color == currentColor && !isHovered {
                let checkSize: CGFloat = 8
                let checkPath = NSBezierPath()
                checkPath.lineWidth = 2
                checkPath.lineCapStyle = .round
                checkPath.lineJoinStyle = .round
                // Simple check mark
                let cx = sx - checkSize / 3
                let cy = sy
                checkPath.move(to: NSPoint(x: cx - checkSize / 3, y: cy))
                checkPath.line(to: NSPoint(x: cx, y: cy - checkSize / 3))
                checkPath.line(to: NSPoint(x: cx + checkSize / 2, y: cy + checkSize / 3))
                NSColor.white.setStroke()
                checkPath.stroke()
            }
        }

        // Center dot showing current color
        let centerRadius: CGFloat = 12
        let centerRect = NSRect(x: center.x - centerRadius, y: center.y - centerRadius, width: centerRadius * 2, height: centerRadius * 2)
        currentColor.setFill()
        NSBezierPath(ovalIn: centerRect).fill()
        NSColor.white.withAlphaComponent(0.6).setStroke()
        let centerBorder = NSBezierPath(ovalIn: centerRect.insetBy(dx: 0.5, dy: 0.5))
        centerBorder.lineWidth = 1.5
        centerBorder.stroke()
    }

    private func colorWheelIndexAt(_ point: NSPoint) -> Int {
        let dx = point.x - colorWheelCenter.x
        let dy = point.y - colorWheelCenter.y
        let dist = hypot(dx, dy)

        // Must be reasonably close to the ring
        if dist < colorWheelRadius * 0.3 || dist > colorWheelRadius + colorWheelSwatchRadius + 15 {
            return -1
        }

        let count = colorWheelColors.count
        let angleStep = (2 * CGFloat.pi) / CGFloat(count)
        var angle = atan2(dy, dx) + CGFloat.pi / 2  // offset so 0 is at top
        if angle < 0 { angle += 2 * CGFloat.pi }
        let index = Int((angle + angleStep / 2) / angleStep) % count
        return index
    }

    private func drawColorPicker() {
        let cols = 6
        let totalItems = availableColors.count + 1  // +1 for custom picker
        let rows = (totalItems + cols - 1) / cols
        let swatchSize: CGFloat = 24
        let padding: CGFloat = 6
        let pickerWidth = CGFloat(cols) * (swatchSize + padding) + padding
        let opacityBarHeight: CGFloat = 12
        var pickerHeight = CGFloat(rows) * (swatchSize + padding) + padding + padding + opacityBarHeight + padding

        // Extra height for inline HSB picker
        let gradientSize: CGFloat = 140
        let brightnessBarHeight: CGFloat = 16
        let hsbExtraHeight: CGFloat = showCustomColorPicker ? (padding + gradientSize + padding + brightnessBarHeight + padding) : 0
        pickerHeight += hsbExtraHeight

        // Find color button in bottom bar
        var anchorX = bottomBarRect.midX
        for btn in bottomButtons {
            if case .color = btn.action {
                anchorX = btn.rect.midX
                break
            }
        }

        var pickerX = anchorX - pickerWidth / 2
        var pickerY: CGFloat
        if bottomBarRect.minY < selectionRect.minY {
            // Bar is below selection — place picker below bar
            pickerY = bottomBarRect.minY - pickerHeight - 4
            // If it goes off the bottom, try above the bar instead
            if pickerY < bounds.minY + 4 {
                pickerY = bottomBarRect.maxY + 4
            }
            // If it still goes off the top, clamp to top
            if pickerY + pickerHeight > bounds.maxY - 4 {
                pickerY = bounds.maxY - pickerHeight - 4
            }
        } else {
            // Bar is above selection — place picker above bar
            pickerY = bottomBarRect.maxY + 4
            // If it goes off the top, try below the bar instead
            if pickerY + pickerHeight > bounds.maxY - 4 {
                pickerY = bottomBarRect.minY - pickerHeight - 4
            }
            // If it still goes off the bottom, clamp to bottom
            if pickerY < bounds.minY + 4 {
                pickerY = bounds.minY + 4
            }
        }

        // Clamp horizontal
        pickerX = max(bounds.minX + 4, min(pickerX, bounds.maxX - pickerWidth - 4))

        colorPickerRect = NSRect(x: pickerX, y: pickerY, width: pickerWidth, height: pickerHeight)

        // Background
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: colorPickerRect, xRadius: 6, yRadius: 6).fill()

        // Swatches Y base: if HSB picker is showing, swatches start above it
        let swatchBaseY = colorPickerRect.maxY

        // Preset swatches
        for (i, color) in availableColors.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = colorPickerRect.minX + padding + CGFloat(col) * (swatchSize + padding)
            let y = swatchBaseY - padding - swatchSize - CGFloat(row) * (swatchSize + padding)
            let swatchRect = NSRect(x: x, y: y, width: swatchSize, height: swatchSize)

            color.setFill()
            NSBezierPath(roundedRect: swatchRect, xRadius: 4, yRadius: 4).fill()

            if color == currentColor {
                NSColor.white.setStroke()
                let border = NSBezierPath(roundedRect: swatchRect.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
                border.lineWidth = 2
                border.stroke()
            }
        }

        // Custom color picker swatch (rainbow gradient + "+" label)
        let customIdx = availableColors.count
        let customCol = customIdx % cols
        let customRow = customIdx / cols
        let cx = colorPickerRect.minX + padding + CGFloat(customCol) * (swatchSize + padding)
        let cy = swatchBaseY - padding - swatchSize - CGFloat(customRow) * (swatchSize + padding)
        let customRect = NSRect(x: cx, y: cy, width: swatchSize, height: swatchSize)
        customPickerSwatchRect = customRect

        // Draw a rainbow gradient
        let rainbowGrad = NSGradient(colors: [.systemRed, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .systemRed])
        let rainbowPath = NSBezierPath(roundedRect: customRect, xRadius: 4, yRadius: 4)
        rainbowGrad?.draw(in: rainbowPath, angle: 45)

        // Highlight if expanded
        if showCustomColorPicker {
            NSColor.white.withAlphaComponent(0.4).setStroke()
            let border = NSBezierPath(roundedRect: customRect.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
            border.lineWidth = 2
            border.stroke()
        }

        // "+" label
        let plusAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let plusStr = "+" as NSString
        let plusSize = plusStr.size(withAttributes: plusAttrs)
        plusStr.draw(at: NSPoint(x: customRect.midX - plusSize.width / 2, y: customRect.midY - plusSize.height / 2), withAttributes: plusAttrs)

        // Opacity slider (always visible, below swatches)
        do {
            let swatchRowsHeight = CGFloat(rows) * (swatchSize + padding) + padding
            let opacityY = colorPickerRect.maxY - swatchRowsHeight - padding - opacityBarHeight
            let opacityX = colorPickerRect.minX + padding
            let opacityW = pickerWidth - padding * 2
            let oRect = NSRect(x: opacityX, y: opacityY, width: opacityW, height: opacityBarHeight)
            opacitySliderRect = oRect

            // Checkerboard background to indicate transparency
            let checkSize: CGFloat = opacityBarHeight / 2
            NSGraphicsContext.current?.saveGraphicsState()
            let checkPath = NSBezierPath(roundedRect: oRect, xRadius: 4, yRadius: 4)
            checkPath.addClip()
            let cols2 = Int(ceil(opacityW / checkSize))
            for ci in 0...cols2 {
                for ri in 0...1 {
                    if (ci + ri) % 2 == 0 {
                        NSColor(white: 0.5, alpha: 1).setFill()
                    } else {
                        NSColor(white: 0.7, alpha: 1).setFill()
                    }
                    NSRect(x: oRect.minX + CGFloat(ci) * checkSize, y: oRect.minY + CGFloat(ri) * checkSize,
                           width: checkSize, height: checkSize).fill()
                }
            }
            NSGraphicsContext.current?.restoreGraphicsState()

            // Gradient overlay: transparent color to opaque color
            let oPath = NSBezierPath(roundedRect: oRect, xRadius: 4, yRadius: 4)
            let oGrad = NSGradient(starting: currentColor.withAlphaComponent(0), ending: currentColor.withAlphaComponent(1))
            oGrad?.draw(in: oPath, angle: 0)

            // Thin border
            NSColor.white.withAlphaComponent(0.3).setStroke()
            let oBorder = NSBezierPath(roundedRect: oRect, xRadius: 4, yRadius: 4)
            oBorder.lineWidth = 0.5
            oBorder.stroke()

            // Thumb indicator
            let thumbX = oRect.minX + currentColorOpacity * oRect.width
            let thumbH: CGFloat = opacityBarHeight + 4
            let thumbRect = NSRect(x: thumbX - 4, y: oRect.midY - thumbH / 2, width: 8, height: thumbH)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: thumbRect, xRadius: 3, yRadius: 3).fill()
            NSColor.black.withAlphaComponent(0.3).setStroke()
            let thumbBorder = NSBezierPath(roundedRect: thumbRect, xRadius: 3, yRadius: 3)
            thumbBorder.lineWidth = 0.5
            thumbBorder.stroke()

            // "Opacity" label
            let opacityPct = Int(currentColorOpacity * 100)
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            ]
            let labelStr = "\(opacityPct)%" as NSString
            let labelSize = labelStr.size(withAttributes: labelAttrs)
            labelStr.draw(at: NSPoint(x: oRect.maxX - labelSize.width - 2, y: oRect.midY - labelSize.height / 2), withAttributes: labelAttrs)
        }

        // Inline HSB color picker
        if showCustomColorPicker {
            let swatchRowsHeight = CGFloat(rows) * (swatchSize + padding) + padding
            let gradientY = colorPickerRect.maxY - swatchRowsHeight - padding - opacityBarHeight - padding - gradientSize
            let gradientX = colorPickerRect.minX + padding
            let gradientW = pickerWidth - padding * 2
            let gradRect = NSRect(x: gradientX, y: gradientY, width: gradientW, height: gradientSize)
            customPickerGradientRect = gradRect

            // Draw HS gradient (cached bitmap for performance)
            drawHSBGradient(in: gradRect, brightness: customBrightness)

            // Crosshair indicator for current color
            do {
                let cx = gradRect.minX + customPickerHue * gradRect.width
                let cy = gradRect.minY + customPickerSaturation * gradRect.height
                let crossSize: CGFloat = 10
                // Outer ring (dark)
                NSColor.black.withAlphaComponent(0.6).setStroke()
                let outerRing = NSBezierPath(ovalIn: NSRect(x: cx - crossSize/2, y: cy - crossSize/2, width: crossSize, height: crossSize))
                outerRing.lineWidth = 2
                outerRing.stroke()
                // Inner ring (white)
                NSColor.white.setStroke()
                let innerRing = NSBezierPath(ovalIn: NSRect(x: cx - crossSize/2 + 1, y: cy - crossSize/2 + 1, width: crossSize - 2, height: crossSize - 2))
                innerRing.lineWidth = 1.5
                innerRing.stroke()
            }

            // Brightness slider
            let bSliderY = gradientY - padding - brightnessBarHeight
            let bSliderRect = NSRect(x: gradientX, y: bSliderY, width: gradientW, height: brightnessBarHeight)
            customPickerBrightnessRect = bSliderRect

            // Draw brightness gradient: black to current HS color at full brightness
            let currentHS = NSColor(calibratedHue: customPickerHue,
                                     saturation: customPickerSaturation,
                                     brightness: 1.0, alpha: 1.0)
            let bPath = NSBezierPath(roundedRect: bSliderRect, xRadius: 4, yRadius: 4)
            let bGrad = NSGradient(starting: .black, ending: currentHS)
            bGrad?.draw(in: bPath, angle: 0)

            // Brightness indicator
            let bx = bSliderRect.minX + customBrightness * bSliderRect.width
            NSColor.white.setStroke()
            let bIndicator = NSBezierPath(ovalIn: NSRect(x: bx - 6, y: bSliderRect.midY - 6, width: 12, height: 12))
            bIndicator.lineWidth = 2
            bIndicator.stroke()
            NSColor.black.withAlphaComponent(0.3).setStroke()
            let bIndicatorOuter = NSBezierPath(ovalIn: NSRect(x: bx - 7, y: bSliderRect.midY - 7, width: 14, height: 14))
            bIndicatorOuter.lineWidth = 1
            bIndicatorOuter.stroke()
        }
    }

    private var cachedBrightness: CGFloat = -1

    private func drawHSBGradient(in rect: NSRect, brightness: CGFloat) {
        // Render at reduced resolution for performance, then scale up
        let scale: CGFloat = 2  // half-res
        let w = Int(rect.width / scale)
        let h = Int(rect.height / scale)
        guard w > 0 && h > 0 else { return }

        // Only regenerate if brightness changed or cache is nil
        if customHSBCachedImage == nil || cachedBrightness != brightness {
            let bitmapRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: .calibratedRGB,
                bytesPerRow: w * 4, bitsPerPixel: 32
            )!
            for px in 0..<w {
                for py in 0..<h {
                    let hue = CGFloat(px) / CGFloat(w)
                    let sat = CGFloat(py) / CGFloat(h)
                    let color = NSColor(calibratedHue: hue, saturation: sat, brightness: brightness, alpha: 1.0)
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    color.getRed(&r, green: &g, blue: &b, alpha: &a)
                    bitmapRep.setColor(NSColor(calibratedRed: r, green: g, blue: b, alpha: 1), atX: px, y: h - 1 - py)
                }
            }
            let img = NSImage(size: NSSize(width: w, height: h))
            img.addRepresentation(bitmapRep)
            customHSBCachedImage = img
            cachedBrightness = brightness
        }

        // Clip to rounded rect and draw scaled
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        customHSBCachedImage!.draw(in: rect, from: NSRect(origin: .zero, size: customHSBCachedImage!.size), operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBeautifyPicker() {
        let styles = BeautifyRenderer.styles
        let rowH: CGFloat = 28
        let pickerWidth: CGFloat = 130
        let padding: CGFloat = 6
        let pickerHeight = rowH * CGFloat(styles.count) + padding * 2

        // Anchor to the beautify button in bottom bar
        var anchorRect = NSRect.zero
        for btn in bottomButtons {
            if case .beautify = btn.action {
                anchorRect = btn.rect
                break
            }
        }

        let pickerX = anchorRect.midX - pickerWidth / 2
        var pickerY = anchorRect.maxY + 4
        if pickerY + pickerHeight > bounds.maxY - 4 {
            pickerY = anchorRect.minY - pickerHeight - 4
        }
        pickerY = max(bounds.minY + 4, min(pickerY, bounds.maxY - pickerHeight - 4))

        let pickerRect = NSRect(x: pickerX, y: pickerY, width: pickerWidth, height: pickerHeight)
        beautifyPickerRect = pickerRect

        // Background
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: pickerRect, xRadius: 6, yRadius: 6).fill()

        // Rows — drawn top-to-bottom (index 0 at top)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]

        for (i, style) in styles.enumerated() {
            let rowY = pickerRect.maxY - padding - rowH * CGFloat(i + 1)
            let rowRect = NSRect(x: pickerRect.minX, y: rowY, width: pickerRect.width, height: rowH)

            // Highlight selected row
            if i == beautifyStyleIndex % styles.count {
                ToolbarLayout.accentColor.withAlphaComponent(0.5).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
            } else if i == hoveredBeautifyRow {
                // Hover highlight
                NSColor.white.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
            }

            // Gradient swatch (mini 2-color pill)
            let swatchRect = NSRect(x: rowRect.minX + 8, y: rowRect.midY - 7, width: 20, height: 14)
            let swatchPath = NSBezierPath(roundedRect: swatchRect, xRadius: 3, yRadius: 3)
            if let grad = NSGradient(starting: style.colors.0, ending: style.colors.1) {
                grad.draw(in: swatchPath, angle: 45)
            }

            // Style name
            let nameStr = style.name as NSString
            let nameSize = nameStr.size(withAttributes: textAttrs)
            nameStr.draw(at: NSPoint(x: rowRect.minX + 36, y: rowRect.midY - nameSize.height / 2), withAttributes: textAttrs)
        }
    }

    private func drawStrokePicker() {
        let widths: [CGFloat] = [1, 2, 3, 5, 8, 12, 20]
        let rowH: CGFloat = 30
        let pickerWidth: CGFloat = 140
        let padding: CGFloat = 6
        let showSmoothToggle = (currentTool == .pencil)
        let toggleRowH: CGFloat = showSmoothToggle ? 32 : 0
        let separatorH: CGFloat = showSmoothToggle ? 5 : 0
        let pickerHeight = rowH * CGFloat(widths.count) + padding * 2 + separatorH + toggleRowH

        // Anchor to the current tool button
        var anchorX = bottomBarRect.midX
        var anchorRect = NSRect.zero
        for btn in bottomButtons {
            if case .tool(let t) = btn.action, t == currentTool {
                anchorX = btn.rect.midX
                anchorRect = btn.rect
                break
            }
        }

        let pickerX = max(bounds.minX + 4, min(anchorX - pickerWidth / 2, bounds.maxX - pickerWidth - 4))
        var pickerY = anchorRect.maxY + 4
        if pickerY + pickerHeight > bounds.maxY - 4 {
            pickerY = anchorRect.minY - pickerHeight - 4
        }

        let pickerRect = NSRect(x: pickerX, y: pickerY, width: pickerWidth, height: pickerHeight)
        strokePickerRect = pickerRect

        // Current size for this tool
        let activeWidth: CGFloat
        switch currentTool {
        case .number: activeWidth = currentNumberSize
        case .marker: activeWidth = currentMarkerSize
        default:      activeWidth = currentStrokeWidth
        }

        // Background
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: pickerRect, xRadius: 6, yRadius: 6).fill()

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]

        let labelX = pickerRect.minX + 12
        let labelW: CGFloat = 44   // fixed label column width
        let lineStartX = labelX + labelW + 8  // gap between label and preview

        for (i, width) in widths.enumerated() {
            let rowY = pickerRect.maxY - padding - rowH * CGFloat(i + 1)
            let rowRect = NSRect(x: pickerRect.minX, y: rowY, width: pickerRect.width, height: rowH)

            if activeWidth == width {
                ToolbarLayout.accentColor.withAlphaComponent(0.5).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
            } else if i == hoveredStrokeRow {
                NSColor.white.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
            }

            // Label
            let labelText = "\(Int(width))px"
            let nameStr = labelText as NSString
            let nameSize = nameStr.size(withAttributes: textAttrs)
            nameStr.draw(at: NSPoint(x: labelX, y: rowRect.midY - nameSize.height / 2), withAttributes: textAttrs)

            // Stroke preview line (all tools — no circle for number)
            let lineY = rowRect.midY
            let linePath = NSBezierPath()
            linePath.move(to: NSPoint(x: lineStartX, y: lineY))
            linePath.line(to: NSPoint(x: pickerRect.maxX - 10, y: lineY))
            linePath.lineWidth = min(width, 14)
            linePath.lineCapStyle = .round
            NSColor.white.setStroke()
            linePath.stroke()
        }

        // Smooth toggle row (pencil only)
        if showSmoothToggle {
            // Separator
            let sepY = pickerRect.minY + toggleRowH
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: NSRect(x: pickerRect.minX + 8, y: sepY, width: pickerRect.width - 16, height: 1)).fill()

            let toggleRowRect = NSRect(x: pickerRect.minX, y: pickerRect.minY, width: pickerRect.width, height: toggleRowH)
            strokeSmoothToggleRect = toggleRowRect

            // Hover highlight
            if hoveredStrokeRow == 99 {
                NSColor.white.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: toggleRowRect.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
            }

            // Label
            let toggleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let label = "Smooth strokes" as NSString
            let labelSize = label.size(withAttributes: toggleAttrs)
            label.draw(at: NSPoint(x: toggleRowRect.minX + 10, y: toggleRowRect.midY - labelSize.height / 2), withAttributes: toggleAttrs)

            // Checkbox
            let checkSize: CGFloat = 14
            let checkX = toggleRowRect.maxX - checkSize - 10
            let checkY = toggleRowRect.midY - checkSize / 2
            let checkRect = NSRect(x: checkX, y: checkY, width: checkSize, height: checkSize)
            NSColor.white.withAlphaComponent(pencilSmoothEnabled ? 0.9 : 0.25).setFill()
            NSBezierPath(roundedRect: checkRect, xRadius: 3, yRadius: 3).fill()
            if pencilSmoothEnabled {
                let checkAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.black,
                ]
                let tick = "✓" as NSString
                let tickSize = tick.size(withAttributes: checkAttrs)
                tick.draw(at: NSPoint(x: checkRect.midX - tickSize.width / 2, y: checkRect.midY - tickSize.height / 2), withAttributes: checkAttrs)
            }
        } else {
            strokeSmoothToggleRect = .zero
        }
    }

    // MARK: - Delay Picker

    private func drawDelayPicker() {
        let options: [(label: String, seconds: Int)] = [
            ("Off", 0), ("1s", 1), ("2s", 2), ("3s", 3), ("5s", 5), ("10s", 10), ("30s", 30)
        ]
        let rowH: CGFloat = 28
        let pickerWidth: CGFloat = 90
        let padding: CGFloat = 6
        let pickerHeight = rowH * CGFloat(options.count) + padding * 2

        var anchorRect = NSRect.zero
        for btn in rightButtons {
            if case .delayCapture = btn.action {
                anchorRect = btn.rect
                break
            }
        }

        let pickerX = anchorRect.minX - pickerWidth - 4
        var pickerY = anchorRect.maxY - pickerHeight
        pickerY = max(bounds.minY + 4, min(pickerY, bounds.maxY - pickerHeight - 4))

        let pickerRect = NSRect(x: pickerX, y: pickerY, width: pickerWidth, height: pickerHeight)
        delayPickerRect = pickerRect

        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: pickerRect, xRadius: 6, yRadius: 6).fill()

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]

        for (i, option) in options.enumerated() {
            let rowY = pickerRect.maxY - padding - rowH * CGFloat(i + 1)
            let rowRect = NSRect(x: pickerRect.minX, y: rowY, width: pickerRect.width, height: rowH)

            if option.seconds == delaySeconds {
                ToolbarLayout.accentColor.withAlphaComponent(0.5).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
            } else if i == hoveredDelayRow {
                NSColor.white.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
            }

            let labelStr = option.label as NSString
            let labelSize = labelStr.size(withAttributes: textAttrs)
            labelStr.draw(at: NSPoint(x: rowRect.midX - labelSize.width / 2, y: rowRect.midY - labelSize.height / 2), withAttributes: textAttrs)
        }
    }

    // MARK: - Upload Confirm Picker

    private func drawUploadConfirmPicker() {
        let confirmEnabled = UserDefaults.standard.bool(forKey: "uploadConfirmEnabled")
        let rowH: CGFloat = 32
        let pickerWidth: CGFloat = 180
        let padding: CGFloat = 8
        let pickerHeight = rowH + padding * 2

        var anchorRect = NSRect.zero
        for btn in rightButtons {
            if case .upload = btn.action { anchorRect = btn.rect; break }
        }

        var pickerX = anchorRect.minX - pickerWidth - 4
        var pickerY = anchorRect.maxY - pickerHeight
        pickerY = max(bounds.minY + 4, min(pickerY, bounds.maxY - pickerHeight - 4))
        pickerX = max(bounds.minX + 4, min(pickerX, bounds.maxX - pickerWidth - 4))

        let pickerRect = NSRect(x: pickerX, y: pickerY, width: pickerWidth, height: pickerHeight)
        uploadConfirmPickerRect = pickerRect

        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: pickerRect, xRadius: 6, yRadius: 6).fill()

        let rowY = pickerRect.minY + padding
        let rowRect = NSRect(x: pickerRect.minX, y: rowY, width: pickerRect.width, height: rowH)

        let checkSymbol: String = confirmEnabled ? "checkmark.circle.fill" : "circle"
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let img = NSImage(systemSymbolName: checkSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) {
            let tintColor: NSColor = confirmEnabled ? ToolbarLayout.accentColor : NSColor.white.withAlphaComponent(0.5)
            let tinted = NSImage(size: img.size)
            tinted.lockFocus()
            img.draw(in: NSRect(origin: .zero, size: img.size))
            tintColor.setFill()
            NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let iconRect = NSRect(x: rowRect.minX + 10, y: rowRect.midY - 8, width: 16, height: 16)
            tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let label = "Confirm before upload" as NSString
        let labelSize = label.size(withAttributes: textAttrs)
        label.draw(at: NSPoint(x: rowRect.minX + 32, y: rowRect.midY - labelSize.height / 2), withAttributes: textAttrs)
    }

    // MARK: - Upload Confirm Dialog

    private func drawUploadConfirmDialog() {
        let dialogW: CGFloat = 280
        let dialogH: CGFloat = 110
        let dialogX = bounds.midX - dialogW / 2
        let dialogY = bounds.midY - dialogH / 2
        let dialogRect = NSRect(x: dialogX, y: dialogY, width: dialogW, height: dialogH)
        uploadConfirmDialogRect = dialogRect

        // Dim the rest of the overlay
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(rect: bounds).fill()

        // Dialog background
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: dialogRect, xRadius: 10, yRadius: 10).fill()

        // Title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let title = "Upload to imgbb.com?" as NSString
        let titleSize = title.size(withAttributes: titleAttrs)
        title.draw(at: NSPoint(x: dialogRect.midX - titleSize.width / 2, y: dialogRect.maxY - 30), withAttributes: titleAttrs)

        // Subtitle
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]
        let sub = "Your screenshot will be sent to imgbb.com" as NSString
        let subSize = sub.size(withAttributes: subAttrs)
        sub.draw(at: NSPoint(x: dialogRect.midX - subSize.width / 2, y: dialogRect.maxY - 52), withAttributes: subAttrs)

        // Buttons
        let btnW: CGFloat = 100
        let btnH: CGFloat = 28
        let btnY = dialogRect.minY + 16
        let cancelRect = NSRect(x: dialogRect.midX - btnW - 6, y: btnY, width: btnW, height: btnH)
        let okRect = NSRect(x: dialogRect.midX + 6, y: btnY, width: btnW, height: btnH)
        uploadConfirmCancelRect = cancelRect
        uploadConfirmOKRect = okRect

        // Cancel button
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: cancelRect, xRadius: 6, yRadius: 6).fill()
        let cancelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let cancelLabel = "Cancel" as NSString
        let cancelSize = cancelLabel.size(withAttributes: cancelAttrs)
        cancelLabel.draw(at: NSPoint(x: cancelRect.midX - cancelSize.width / 2, y: cancelRect.midY - cancelSize.height / 2), withAttributes: cancelAttrs)

        // Upload button
        ToolbarLayout.accentColor.setFill()
        NSBezierPath(roundedRect: okRect, xRadius: 6, yRadius: 6).fill()
        let okAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let okLabel = "Upload" as NSString
        let okSize = okLabel.size(withAttributes: okAttrs)
        okLabel.draw(at: NSPoint(x: okRect.midX - okSize.width / 2, y: okRect.midY - okSize.height / 2), withAttributes: okAttrs)
    }

    // MARK: - Redact Type Picker

    private func drawRedactTypePicker() {
        let types = OverlayView.redactTypeNames
        let enabledTypes = UserDefaults.standard.array(forKey: "enabledRedactTypes") as? [String]

        let rowH: CGFloat = 26
        let pickerWidth: CGFloat = 165
        let padding: CGFloat = 6
        let pickerHeight = rowH * CGFloat(types.count) + padding * 2

        var anchorRect = NSRect.zero
        for btn in bottomButtons {
            if case .autoRedact = btn.action { anchorRect = btn.rect; break }
        }

        let pickerX = anchorRect.midX - pickerWidth / 2
        var pickerY = anchorRect.maxY + 4
        if pickerY + pickerHeight > bounds.maxY - 4 {
            pickerY = anchorRect.minY - pickerHeight - 4
        }
        pickerY = max(bounds.minY + 4, min(pickerY, bounds.maxY - pickerHeight - 4))

        let pickerRect = NSRect(x: pickerX, y: pickerY, width: pickerWidth, height: pickerHeight)
        redactTypePickerRect = pickerRect

        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: pickerRect, xRadius: 6, yRadius: 6).fill()

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]

        for (i, item) in types.enumerated() {
            let rowY = pickerRect.maxY - padding - rowH * CGFloat(i + 1)
            let rowRect = NSRect(x: pickerRect.minX, y: rowY, width: pickerRect.width, height: rowH)

            if i == hoveredRedactTypeRow {
                NSColor.white.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
            }

            let isEnabled = enabledTypes == nil || enabledTypes!.contains(item.key)
            let checkSymbol: String = isEnabled ? "checkmark.square.fill" : "square"
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            if let img = NSImage(systemSymbolName: checkSymbol, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) {
                let tintColor: NSColor = isEnabled ? ToolbarLayout.accentColor : NSColor.white.withAlphaComponent(0.5)
                let tinted = NSImage(size: img.size)
                tinted.lockFocus()
                img.draw(in: NSRect(origin: .zero, size: img.size))
                tintColor.setFill()
                NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
                tinted.unlockFocus()
                tinted.draw(in: NSRect(x: rowRect.minX + 8, y: rowRect.midY - 7, width: 14, height: 14), from: .zero, operation: .sourceOver, fraction: 1.0)
            }

            let labelStr = item.label as NSString
            let labelSize = labelStr.size(withAttributes: textAttrs)
            labelStr.draw(at: NSPoint(x: rowRect.minX + 28, y: rowRect.midY - labelSize.height / 2), withAttributes: textAttrs)
        }
    }

    // MARK: - Loupe Size Picker

    private func drawLoupeSizePicker() {
        let sizes: [CGFloat] = [60, 80, 100, 120, 160, 200, 250, 320]
        let rowH: CGFloat = 28
        let pickerWidth: CGFloat = 120
        let padding: CGFloat = 6
        let pickerHeight = rowH * CGFloat(sizes.count) + padding * 2

        var anchorRect = NSRect.zero
        for btn in bottomButtons {
            if case .tool(let t) = btn.action, t == .loupe {
                anchorRect = btn.rect
                break
            }
        }

        let pickerX = max(bounds.minX + 4, min(anchorRect.midX - pickerWidth / 2, bounds.maxX - pickerWidth - 4))
        var pickerY = anchorRect.maxY + 4
        if pickerY + pickerHeight > bounds.maxY - 4 {
            pickerY = anchorRect.minY - pickerHeight - 4
        }

        let pickerRect = NSRect(x: pickerX, y: pickerY, width: pickerWidth, height: pickerHeight)
        loupeSizePickerRect = pickerRect

        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: pickerRect, xRadius: 6, yRadius: 6).fill()

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]

        for (i, size) in sizes.enumerated() {
            let rowY = pickerRect.maxY - padding - rowH * CGFloat(i + 1)
            let rowRect = NSRect(x: pickerRect.minX, y: rowY, width: pickerRect.width, height: rowH)

            if size == currentLoupeSize {
                ToolbarLayout.accentColor.withAlphaComponent(0.5).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
            } else if i == hoveredLoupeSizeRow {
                NSColor.white.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
            }

            let radius = min(12, size / 10)
            let cx = rowRect.maxX - 20
            let cy = rowRect.midY
            NSColor.white.withAlphaComponent(0.7).setStroke()
            let circlePath = NSBezierPath(ovalIn: NSRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
            circlePath.lineWidth = 1.5
            circlePath.stroke()

            let labelStr = "\(Int(size))px" as NSString
            let labelSize = labelStr.size(withAttributes: textAttrs)
            labelStr.draw(at: NSPoint(x: rowRect.minX + 12, y: rowRect.midY - labelSize.height / 2), withAttributes: textAttrs)
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
        let hexAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let copyAttrs: [NSAttributedString.Key: Any] = [.font: copyFont, .foregroundColor: NSColor.white.withAlphaComponent(0.5)]

        let hexSize = (hexStr as NSString).size(withAttributes: hexAttrs)
        let copyText = "C to copy"
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
        let swatchRect = NSRect(x: labelRect.minX + padding,
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
        (hexStr as NSString).draw(at: NSPoint(x: textX, y: labelRect.maxY - padding - hexSize.height), withAttributes: hexAttrs)
        (copyText as NSString).draw(at: NSPoint(x: textX, y: labelRect.minY + padding), withAttributes: copyAttrs)

        context.restoreGraphicsState()
    }

    /// Sample a pixel color from the screenshot at the given canvas-space point.
    /// Returns (NSColor for display, hex string with raw sRGB values matching what other tools report).
    private func sampleColor(from image: NSImage, at canvasPoint: NSPoint) -> (color: NSColor, hex: String)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let imgSize = image.size

        let px = canvasPoint.x * imgSize.width / bounds.width
        let py = canvasPoint.y * imgSize.height / bounds.height
        guard px >= 0, py >= 0, px < imgSize.width, py < imgSize.height else { return nil }

        // Map to CGImage pixel coordinates.
        let scaleX = CGFloat(cgImage.width) / imgSize.width
        let scaleY = CGFloat(cgImage.height) / imgSize.height
        let cgX = Int(px * scaleX)
        let cgY = Int(CGFloat(cgImage.height) - 1 - py * scaleY)  // flip Y for CGImage (top-left origin)
        guard cgX >= 0, cgX < cgImage.width, cgY >= 0, cgY < cgImage.height else { return nil }

        // Render the single pixel into a known-format 1×1 sRGB bitmap to get correct raw values.
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: 1, height: 1,
                                  bitsPerComponent: 8, bytesPerRow: 4,
                                  space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: -CGFloat(cgX), y: -(CGFloat(cgImage.height) - 1 - CGFloat(cgY)),
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
        let color = NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
        return (color, hex)
    }

    private func copyColorAtSamplerPoint() {
        guard let screenshot = screenshotImage,
              let result = sampleColor(from: screenshot, at: colorSamplerPoint) else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.hex, forType: .string)
        showOverlayError("Copied \(result.hex)")
    }

    // MARK: - Marker Cursor Preview

    private func drawMarkerCursorPreview(at center: NSPoint) {
        let radius = (currentMarkerSize * 6) / 2
        let circleRect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
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
        guard let screenshot = screenshotImage, let context = NSGraphicsContext.current else { return }
        let size = currentLoupeSize
        let squareRect = NSRect(x: center.x - size/2, y: center.y - size/2, width: size, height: size)
        let magnification: CGFloat = 2.0

        context.saveGraphicsState()
        context.cgContext.setAlpha(0.75)

        // Clip to circle
        let path = NSBezierPath(ovalIn: squareRect)
        path.addClip()

        // Draw magnified region directly from screenshot (no intermediate image)
        let srcSize = size / magnification
        let srcRect = NSRect(x: center.x - srcSize/2, y: center.y - srcSize/2, width: srcSize, height: srcSize)
        let imgSize = screenshot.size
        let scaleX = imgSize.width / bounds.width
        let scaleY = imgSize.height / bounds.height
        let fromRect = NSRect(x: srcRect.origin.x * scaleX, y: srcRect.origin.y * scaleY,
                              width: srcRect.width * scaleX, height: srcRect.height * scaleY)
        screenshot.draw(in: squareRect, from: fromRect, operation: .copy, fraction: 1.0)

        // Simple border
        NSColor.white.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 3
        path.stroke()

        context.restoreGraphicsState()
    }

    // MARK: - Pencil smoothing

    /// Chaikin corner-cutting: each iteration replaces every segment with two points
    /// at 25% and 75% along it, keeping endpoints fixed. 2 passes gives gentle smoothing.
    private func chaikinSmooth(_ pts: [NSPoint], iterations: Int) -> [NSPoint] {
        guard pts.count > 2 else { return pts }
        var result = pts
        for _ in 0..<iterations {
            var next: [NSPoint] = [result[0]]
            for i in 0..<result.count - 1 {
                let p0 = result[i], p1 = result[i + 1]
                next.append(NSPoint(x: 0.75 * p0.x + 0.25 * p1.x, y: 0.75 * p0.y + 0.25 * p1.y))
                next.append(NSPoint(x: 0.25 * p0.x + 0.75 * p1.x, y: 0.25 * p0.y + 0.75 * p1.y))
            }
            next.append(result[result.count - 1])
            result = next
        }
        return result
    }

    // MARK: - Checkerboard

    private func drawCheckerboard(in rect: NSRect) {
        let size: CGFloat = 8
        let light = NSColor(white: 0.75, alpha: 1.0)
        let dark  = NSColor(white: 0.55, alpha: 1.0)
        let cols = Int(ceil(rect.width  / size))
        let rows = Int(ceil(rect.height / size))
        for row in 0..<rows {
            for col in 0..<cols {
                let isLight = (row + col) % 2 == 0
                (isLight ? light : dark).setFill()
                let tileX = rect.minX + CGFloat(col) * size
                let tileY = rect.minY + CGFloat(row) * size
                let tileW = min(size, rect.maxX - tileX)
                let tileH = min(size, rect.maxY - tileY)
                NSBezierPath(rect: NSRect(x: tileX, y: tileY, width: tileW, height: tileH)).fill()
            }
        }
    }

    // MARK: - Zoom helpers

    /// Convert a point in view space to canvas (annotation) space by reversing the zoom transform.
    private func viewToCanvas(_ p: NSPoint) -> NSPoint {
        if zoomLevel == 1.0 { return p }
        guard zoomAnchorCanvas != .zero || zoomAnchorView != .zero else { return p }
        return NSPoint(
            x: zoomAnchorCanvas.x + (p.x - zoomAnchorView.x) / zoomLevel,
            y: zoomAnchorCanvas.y + (p.y - zoomAnchorView.y) / zoomLevel
        )
    }

    private func applyZoomTransform(to context: NSGraphicsContext) {
        guard zoomLevel != 1.0 else { return }
        guard zoomAnchorCanvas != .zero || zoomAnchorView != .zero else { return }
        let cgCtx = context.cgContext
        // screen = anchorView + (canvas - anchorCanvas) * zoom
        cgCtx.translateBy(x: zoomAnchorView.x - zoomAnchorCanvas.x * zoomLevel,
                          y: zoomAnchorView.y - zoomAnchorCanvas.y * zoomLevel)
        cgCtx.scaleBy(x: zoomLevel, y: zoomLevel)
    }

    /// Set zoom level, pinning the given view-space cursor point in place.
    private func setZoom(_ level: CGFloat, cursorView: NSPoint) {
        // Canvas point currently under cursor (before zoom change)
        let canvasUnderCursor = viewToCanvas(cursorView)
        zoomLevel = max(zoomMin, min(zoomMax, level))
        // After zoom change, pin that canvas point to the cursor's view position.
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
              let cgOriginal = originalImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        // Convert viewRect corners to canvas space (accounts for zoom).
        let canvasOrigin = viewToCanvas(viewRect.origin)
        let canvasEnd    = viewToCanvas(NSPoint(x: viewRect.maxX, y: viewRect.maxY))
        let canvasRect   = NSRect(x: min(canvasOrigin.x, canvasEnd.x),
                                  y: min(canvasOrigin.y, canvasEnd.y),
                                  width: abs(canvasEnd.x - canvasOrigin.x),
                                  height: abs(canvasEnd.y - canvasOrigin.y))

        // Map canvas rect → image pixel rect.
        let imgW = originalImage.size.width
        let imgH = originalImage.size.height

        let scaleX = imgW / selectionRect.width
        let scaleY = imgH / selectionRect.height

        let pixelX = (canvasRect.minX - selectionRect.minX) * scaleX
        let pixelY = (canvasRect.minY - selectionRect.minY) * scaleY
        let pixelW = canvasRect.width  * scaleX
        let pixelH = canvasRect.height * scaleY
        // Clamp to image bounds.
        let cgPixelRect = CGRect(
            x: max(0, pixelX),
            y: max(0, CGFloat(cgOriginal.height) - pixelY - pixelH),
            width: min(pixelW, CGFloat(cgOriginal.width)  - max(0, pixelX)),
            height: min(pixelH, CGFloat(cgOriginal.height) - max(0, CGFloat(cgOriginal.height) - pixelY - pixelH))
        )

        guard cgPixelRect.width > 0, cgPixelRect.height > 0,
              let croppedCG = cgOriginal.cropping(to: cgPixelRect) else { return }

        let dx = selectionRect.minX - canvasRect.minX
        let dy = selectionRect.minY - canvasRect.minY
        for ann in annotations { ann.move(dx: dx, dy: dy) }
        for entry in undoStack { entry.annotation.move(dx: dx, dy: dy) }
        for entry in redoStack { entry.annotation.move(dx: dx, dy: dy) }

        screenshotImage = NSImage(cgImage: croppedCG,
                                  size: NSSize(width: croppedCG.width, height: croppedCG.height))
        cachedCompositedImage = nil
        resetZoom()
        currentTool = .arrow
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
        guard zoomLevel != 1.0 else { return }
        let r = selectionRect
        let z = zoomLevel
        let ac = zoomAnchorCanvas
        var av = zoomAnchorView

        if z > 1.0 {
            // Zoom-in: edges must stay covered.
            let maxAVx = r.minX - (r.minX - ac.x) * z
            let minAVx = r.maxX - (r.maxX - ac.x) * z
            av.x = max(minAVx, min(maxAVx, av.x))

            let maxAVy = r.minY - (r.minY - ac.y) * z
            let minAVy = r.maxY - (r.maxY - ac.y) * z
            av.y = max(minAVy, min(maxAVy, av.y))
        }
        // zoom < 1×: no clamping — the image is smaller than the canvas area, let the user
        // pan freely to access the empty drawing space around it.

        zoomAnchorView = av
    }

    private func showZoomLabel() {
        zoomLabelOpacity = 1.0
        zoomFadeTimer?.invalidate()
        zoomFadeTimer = nil
        if zoomLevel == 1.0 {
            // Back at 1× — fade out after a short pause
            zoomFadeTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
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
            guard let self = self else { t.invalidate(); return }
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
            let s: CGFloat = 10
            let startRect = NSRect(x: annotation.startPoint.x - s/2, y: annotation.startPoint.y - s/2, width: s, height: s)
            let endRect   = NSRect(x: annotation.endPoint.x   - s/2, y: annotation.endPoint.y   - s/2, width: s, height: s)

            // Middle bend handle: use actual controlPoint if set, otherwise visual midpoint
            let midPt = annotation.controlPoint ?? NSPoint(
                x: (annotation.startPoint.x + annotation.endPoint.x) / 2,
                y: (annotation.startPoint.y + annotation.endPoint.y) / 2
            )
            let sm: CGFloat = 8
            let midRect = NSRect(x: midPt.x - sm/2, y: midPt.y - sm/2, width: sm, height: sm)

            annotationResizeHandleRects = [(.bottomLeft, startRect), (.topRight, endRect), (.top, midRect)]

            // Draw dashed line from endpoints to control point (only if bent)
            if annotation.controlPoint != nil {
                let guidePath = NSBezierPath()
                guidePath.lineWidth = 1
                guidePath.setLineDash([3, 4], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(0.35).setStroke()
                guidePath.move(to: annotation.startPoint)
                guidePath.line(to: midPt)
                guidePath.line(to: annotation.endPoint)
                guidePath.stroke()
            }

            for rect in [startRect, endRect] {
                ToolbarLayout.accentColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
                NSColor.white.withAlphaComponent(0.9).setStroke()
                let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1.5
                border.stroke()
            }

            // Mid handle: slightly different style (diamond-ish via smaller circle, white fill)
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: midRect).fill()
            ToolbarLayout.accentColor.setStroke()
            let midBorder = NSBezierPath(ovalIn: midRect.insetBy(dx: 0.5, dy: 0.5))
            midBorder.lineWidth = 1.5
            midBorder.stroke()

            // Delete button near endPoint
            let btnSize: CGFloat = 20
            let deleteRect = NSRect(x: annotation.endPoint.x + 8, y: annotation.endPoint.y + 2, width: btnSize, height: btnSize)
            annotationDeleteButtonRect = deleteRect
            NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: deleteRect).fill()
            let xAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 11),
                .foregroundColor: NSColor.white,
            ]
            let xStr = "×" as NSString
            let xSize = xStr.size(withAttributes: xAttrs)
            xStr.draw(at: NSPoint(x: deleteRect.midX - xSize.width/2, y: deleteRect.midY - xSize.height/2), withAttributes: xAttrs)
            annotationEditButtonRect = .zero
            return
        }

        let baseRect: NSRect
        switch annotation.tool {
        case .pencil, .marker:
            guard let points = annotation.points, !points.isEmpty else { return }
            var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            for p in points { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
            // Expand by the actual painted stroke radius so the box matches the visible stroke
            let strokeRadius = (annotation.tool == .marker ? annotation.strokeWidth * 6 : annotation.strokeWidth) / 2
            baseRect = NSRect(x: minX - strokeRadius, y: minY - strokeRadius,
                              width: maxX - minX + strokeRadius * 2, height: maxY - minY + strokeRadius * 2)
        case .text:
            // startPoint = top-left, endPoint = bottom-right (set at commit time)
            if annotation.endPoint != annotation.startPoint {
                baseRect = annotation.boundingRect
            } else {
                // Legacy: recompute from attributed string size
                let text = annotation.attributedText ?? annotation.text.map { NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: annotation.fontSize)]) }
                let size = text?.size() ?? NSSize(width: 50, height: 20)
                baseRect = NSRect(origin: annotation.startPoint, size: size)
            }
        case .number:
            let radius = max(14, annotation.strokeWidth * 4)
            baseRect = NSRect(x: annotation.startPoint.x - radius, y: annotation.startPoint.y - radius, width: radius * 2, height: radius * 2)
        default:
            baseRect = annotation.boundingRect
        }

        let padded = baseRect.insetBy(dx: -4, dy: -4)

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

        // Delete button (X) at top-right outside the box
        let btnSize: CGFloat = 20
        let deleteRect = NSRect(x: padded.maxX + 4, y: padded.maxY - btnSize, width: btnSize, height: btnSize)
        annotationDeleteButtonRect = deleteRect
        NSColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 0.9).setFill()
        NSBezierPath(ovalIn: deleteRect).fill()
        let xAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor.white,
        ]
        let xStr = "×" as NSString
        let xSize = xStr.size(withAttributes: xAttrs)
        xStr.draw(at: NSPoint(x: deleteRect.midX - xSize.width/2, y: deleteRect.midY - xSize.height/2), withAttributes: xAttrs)

        // Edit button (pencil) for text annotations
        if annotation.tool == .text {
            let editRect = NSRect(x: padded.maxX + 4, y: padded.maxY - btnSize * 2 - 4, width: btnSize, height: btnSize)
            annotationEditButtonRect = editRect
            NSColor(white: 0.3, alpha: 0.9).setFill()
            NSBezierPath(ovalIn: editRect).fill()
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            if let img = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) {
                let tinted = NSImage(size: img.size)
                tinted.lockFocus()
                img.draw(in: NSRect(origin: .zero, size: img.size))
                NSColor.white.setFill()
                NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
                tinted.unlockFocus()
                let imgRect = NSRect(x: editRect.midX - img.size.width/2, y: editRect.midY - img.size.height/2, width: img.size.width, height: img.size.height)
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
            (.topLeft,    NSRect(x: r.minX - s/2, y: r.maxY - s/2, width: s, height: s)),
            (.topRight,   NSRect(x: r.maxX - s/2, y: r.maxY - s/2, width: s, height: s)),
            (.bottomLeft, NSRect(x: r.minX - s/2, y: r.minY - s/2, width: s, height: s)),
            (.bottomRight,NSRect(x: r.maxX - s/2, y: r.minY - s/2, width: s, height: s)),
            (.top,        NSRect(x: r.midX - s/2, y: r.maxY - s/2, width: s, height: s)),
            (.bottom,     NSRect(x: r.midX - s/2, y: r.minY - s/2, width: s, height: s)),
            (.left,       NSRect(x: r.minX - s/2, y: r.midY - s/2, width: s, height: s)),
            (.right,      NSRect(x: r.maxX - s/2, y: r.midY - s/2, width: s, height: s)),
        ]
    }

    // MARK: - Action Equality Helper (for press feedback)

    private func actionEq(_ a: ToolbarButtonAction, _ b: ToolbarButtonAction) -> Bool {
        switch (a, b) {
        case (.undo, .undo), (.redo, .redo), (.copy, .copy), (.save, .save), (.upload, .upload),
             (.pin, .pin), (.ocr, .ocr), (.autoRedact, .autoRedact), (.removeBackground, .removeBackground),
             (.cancel, .cancel):
            return true
        default:
            return false
        }
    }

    // MARK: - Overlay Error

    func showOverlayError(_ message: String) {
        overlayErrorTimer?.invalidate()
        overlayErrorMessage = message
        needsDisplay = true
        overlayErrorTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            self?.overlayErrorMessage = nil
            self?.needsDisplay = true
        }
    }

    // MARK: - Window Snapping

    /// Returns the frontmost visible window rect (in view coordinates) that contains `screenPoint`.
    /// `screenPoint` is in AppKit screen coordinates (origin bottom-left of main screen).
    private static func windowRectOnBackground(
        screenPoint: NSPoint,
        overlayWindowNumber: Int,
        windowOrigin: NSPoint,
        viewBounds: NSRect,
        screenH: CGFloat
    ) -> NSRect? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }

        for info in windowList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let winNum = info[kCGWindowNumber as String] as? Int,
                  winNum != overlayWindowNumber else { continue }

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
                return viewRect.intersection(viewBounds)
            }
        }
        return nil
    }

    private func drawWindowSnapHighlight() {
        guard state == .idle, windowSnapEnabled, let rect = hoveredWindowRect, !rect.isEmpty else { return }

        // Tinted fill
        NSColor.systemBlue.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        // Border
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        border.lineWidth = 2
        NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
        border.stroke()
    }

    // MARK: - Barcode / QR Detection

    func scheduleBarcodeDetection() {
        barcodeScanTask?.cancel()
        detectedBarcodePayload = nil
        barcodeActionRects = []
        needsDisplay = true

        guard state == .selected,
              selectionRect.width > 20, selectionRect.height > 20,
              let screenshot = screenshotImage else { return }

        let rect = selectionRect
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            // Crop selected region from screenshot
            let regionImage = NSImage(size: rect.size)
            regionImage.lockFocus()
            screenshot.draw(in: NSRect(x: -rect.origin.x, y: -rect.origin.y,
                                       width: self.bounds.width, height: self.bounds.height),
                            from: .zero, operation: .copy, fraction: 1.0)
            regionImage.unlockFocus()

            guard let tiffData = regionImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let cgImage = bitmap.cgImage else { return }

            let request = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            let payload = (request.results ?? [])
                .compactMap { $0.payloadStringValue }
                .first(where: { !$0.isEmpty })

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.detectedBarcodePayload = payload
                self.needsDisplay = true
            }
        }
        barcodeScanTask = task
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3, execute: task)
    }

    private func drawRecordingHUD() {
        // Pill with pulsing red dot + elapsed time, anchored to top-right of selection
        let mins = recordingElapsedSeconds / 60
        let secs = recordingElapsedSeconds % 60
        let timeStr = String(format: "%02d:%02d", mins, secs)
        let fullStr = "● \(timeStr)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (fullStr as NSString).size(withAttributes: attrs)
        let pillH: CGFloat = 28
        let pillW = textSize.width + 24
        let pillX = selectionRect.maxX - pillW - 8
        let pillY = selectionRect.maxY + 8

        // Clamp to view bounds
        let clampedX = max(bounds.minX + 4, min(pillX, bounds.maxX - pillW - 4))
        let clampedY = min(pillY, bounds.maxY - pillH - 4)
        let pillRect = NSRect(x: clampedX, y: clampedY, width: pillW, height: pillH)

        // Background pill
        NSColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: pillH / 2, yRadius: pillH / 2).fill()

        // Text
        let textOrigin = NSPoint(x: pillRect.minX + 12,
                                 y: pillRect.minY + (pillH - textSize.height) / 2)
        (fullStr as NSString).draw(at: textOrigin, withAttributes: attrs)
    }

    // MARK: - Scroll Capture HUD

    /// Drawn directly in the overlay while scroll capture is active.
    /// Replaces both toolbars with a minimal bar:
    ///   [strip count + dimensions]  ·  [Stop button]
    /// Anchored below (or above) the selection, same position logic as the bottom toolbar.
    /// The Stop button rect is stored so mouseDown can hit-test it.
    var scrollCaptureStopRect: NSRect = .zero

    private func drawScrollCaptureHUD() {
        let barH: CGFloat = 36
        let pad: CGFloat  = 8
        let gap: CGFloat  = 6

        // --- Info label (left side) ---
        let stripLabel: String
        if scrollCaptureStripCount == 0 {
            stripLabel = "Scroll Capture  ·  Capturing first frame…"
        } else {
            let pw = Int(scrollCapturePixelSize.width)
            let ph = Int(scrollCapturePixelSize.height)
            let ptW = Int(CGFloat(pw) / (window?.backingScaleFactor ?? 2))
            let ptH = Int(CGFloat(ph) / (window?.backingScaleFactor ?? 2))
            stripLabel = "Scroll Capture  ·  \(scrollCaptureStripCount) strip\(scrollCaptureStripCount == 1 ? "" : "s")  ·  \(ptW)×\(ptH)"
        }

        let infoAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let infoSize = (stripLabel as NSString).size(withAttributes: infoAttrs)

        // --- Stop button ---
        let stopText = "Stop"
        let stopAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let stopTextSize = (stopText as NSString).size(withAttributes: stopAttrs)
        let stopBtnW = stopTextSize.width + 20
        let stopBtnH: CGFloat = 24

        let totalW = pad + infoSize.width + gap * 3 + stopBtnW + pad
        let totalH = barH

        // Position below selection (same logic as bottom toolbar)
        var barX = selectionRect.midX - totalW / 2
        var barY = selectionRect.minY - totalH - 6
        if barY < bounds.minY + 4 {
            barY = selectionRect.maxY + 6
        }
        barX = max(bounds.minX + 4, min(barX, bounds.maxX - totalW - 4))
        let barRect = NSRect(x: barX, y: barY, width: totalW, height: totalH)

        // Draw bar background
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: barRect, xRadius: ToolbarLayout.cornerRadius, yRadius: ToolbarLayout.cornerRadius).fill()

        // Draw info label
        let infoX = barRect.minX + pad
        let infoY = barRect.midY - infoSize.height / 2
        (stripLabel as NSString).draw(at: NSPoint(x: infoX, y: infoY), withAttributes: infoAttrs)

        // Draw Stop button (red pill)
        let stopBtnX = barRect.maxX - pad - stopBtnW
        let stopBtnY = barRect.midY - stopBtnH / 2
        let stopRect = NSRect(x: stopBtnX, y: stopBtnY, width: stopBtnW, height: stopBtnH)
        scrollCaptureStopRect = stopRect

        // Hover tint — convert global mouse location to view coords
        let globalMouse = NSEvent.mouseLocation
        let viewMouse: NSPoint
        if let win = window {
            let winLocal = win.convertFromScreen(NSRect(origin: globalMouse, size: .zero)).origin
            viewMouse = convert(winLocal, from: nil)
        } else {
            viewMouse = .zero
        }
        let stopHovered = stopRect.contains(viewMouse)
        NSColor.systemRed.withAlphaComponent(stopHovered ? 1.0 : 0.85).setFill()
        NSBezierPath(roundedRect: stopRect, xRadius: stopBtnH / 2, yRadius: stopBtnH / 2).fill()

        let stopTextX = stopRect.midX - stopTextSize.width / 2
        let stopTextY = stopRect.midY - stopTextSize.height / 2
        (stopText as NSString).draw(at: NSPoint(x: stopTextX, y: stopTextY), withAttributes: stopAttrs)

        // Hint text above the selection border (top-left corner, semi-transparent)
        let hintStr = "Scroll to capture  ·  Esc to cancel"
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]
        let hintSize = (hintStr as NSString).size(withAttributes: hintAttrs)
        let hintX = selectionRect.minX + 6
        let hintY = selectionRect.maxY + 5
        // Clamp so it doesn't overflow top of screen
        let clampedHintY = min(hintY, bounds.maxY - hintSize.height - 4)
        (hintStr as NSString).draw(at: NSPoint(x: hintX, y: clampedHintY), withAttributes: hintAttrs)
    }

    private func drawBarcodeBar() {
        guard let payload = detectedBarcodePayload else { return }
        let isURL = payload.hasPrefix("http://") || payload.hasPrefix("https://")

        let barH: CGFloat = 36
        let gap: CGFloat = 6
        let barW: CGFloat = max(320, min(selectionRect.width - 16, 420))
        let barX = max(bounds.minX + 4, min(selectionRect.midX - barW / 2, bounds.maxX - barW - 4))

        // Prefer below the selection; if bottom toolbar is there or no room, try above;
        // last resort: inside the selection at the top.
        let belowY = selectionRect.minY - barH - gap
        let aboveY = selectionRect.maxY + gap
        let insideY = selectionRect.maxY - barH - gap

        let bottomBarOccupied = bottomBarRect != .zero
        let belowClear = belowY >= bounds.minY + 4 &&
            !(bottomBarOccupied && NSRect(x: barX, y: belowY, width: barW, height: barH).intersects(bottomBarRect))
        let aboveClear = aboveY + barH <= bounds.maxY - 4

        let finalBarY: CGFloat
        if belowClear {
            finalBarY = belowY
        } else if aboveClear {
            finalBarY = aboveY
        } else {
            finalBarY = insideY
        }

        let barRect = NSRect(x: barX, y: finalBarY, width: barW, height: barH)

        // Background pill
        NSColor(white: 0.12, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 10, yRadius: 10).fill()

        // QR icon + label
        let icon = isURL ? "🔗" : "📋"
        let shortPayload = payload.count > 45 ? String(payload.prefix(42)) + "…" : payload
        let labelText = "\(icon)  \(shortPayload)"
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let labelStr = labelText as NSString
        let labelSize = labelStr.size(withAttributes: labelAttrs)
        let labelX = barRect.minX + 10
        let labelY = barRect.midY - labelSize.height / 2
        labelStr.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: labelAttrs)

        // Action button (right side)
        let btnTitle = isURL ? "Open" : "Copy"
        let btnAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let btnSize = (btnTitle as NSString).size(withAttributes: btnAttrs)
        let btnW = btnSize.width + 20
        let dismissW: CGFloat = 22

        let dismissRect = NSRect(x: barRect.maxX - dismissW - 4, y: barRect.minY + 4, width: dismissW, height: barH - 8)
        let actionRect  = NSRect(x: dismissRect.minX - btnW - 6,  y: barRect.minY + 4, width: btnW,    height: barH - 8)

        // Action button bg
        NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: actionRect, xRadius: 6, yRadius: 6).fill()
        (btnTitle as NSString).draw(
            at: NSPoint(x: actionRect.midX - btnSize.width / 2, y: actionRect.midY - btnSize.height / 2),
            withAttributes: btnAttrs)

        // Dismiss ✕
        let xAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(white: 0.6, alpha: 1),
        ]
        let xStr = "✕" as NSString
        let xSize = xStr.size(withAttributes: xAttrs)
        xStr.draw(at: NSPoint(x: dismissRect.midX - xSize.width / 2, y: dismissRect.midY - xSize.height / 2),
                  withAttributes: xAttrs)

        barcodeActionRects = [actionRect, dismissRect]
    }

    // MARK: - Toolbar Layout

    /// Whether the selection covers (nearly) the full screen
    private var isFullScreenSelection: Bool {
        let margin: CGFloat = 50
        return selectionRect.minX < bounds.minX + margin &&
               selectionRect.minY < bounds.minY + margin &&
               selectionRect.maxX > bounds.maxX - margin &&
               selectionRect.maxY > bounds.maxY - margin
    }

    func rebuildToolbarLayout() {
        let movableAnnotations = annotations.contains { $0.isMovable }
        bottomButtons = ToolbarLayout.bottomButtons(selectedTool: currentTool, selectedColor: currentColor, beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex, hasAnnotations: movableAnnotations, isRecording: isRecording, isAnnotating: isAnnotating)
        rightButtons = ToolbarLayout.rightButtons(delaySeconds: delaySeconds, beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex, hasAnnotations: movableAnnotations, translateEnabled: translateEnabled, isRecording: isRecording, isAnnotating: isAnnotating, isDetached: isDetached)

        // Place each toolbar inside if it would go off-screen
        let bottomMargin: CGFloat = 50  // toolbar height + gap
        let rightMargin: CGFloat = 50

        let bottomFits = selectionRect.minY > bounds.minY + bottomMargin
        let topFits = selectionRect.maxY < bounds.maxY - bottomMargin
        let bottomOutside = bottomFits || topFits  // layoutBottom handles flipping above if below doesn't fit

        if bottomOutside {
            bottomBarRect = ToolbarLayout.layoutBottom(buttons: &bottomButtons, selectionRect: selectionRect, viewBounds: bounds)
        } else {
            bottomBarRect = ToolbarLayout.layoutBottomInside(buttons: &bottomButtons, selectionRect: selectionRect, viewBounds: bounds)
        }

        let rightFits = selectionRect.maxX < bounds.maxX - rightMargin
        let leftFits = selectionRect.minX > bounds.minX + rightMargin
        let rightOutside = rightFits || leftFits  // layoutRight handles flipping to left if right doesn't fit

        if rightOutside {
            rightBarRect = ToolbarLayout.layoutRight(buttons: &rightButtons, selectionRect: selectionRect, viewBounds: bounds, bottomBarRect: bottomBarRect)
        } else {
            rightBarRect = ToolbarLayout.layoutRightInside(buttons: &rightButtons, selectionRect: selectionRect, viewBounds: bounds, bottomBarRect: bottomBarRect)
        }

        // If bottom bar overlaps right bar, push bottom bar down (or up) to clear it.
        // This handles the case where the selection is near the top of the screen and
        // the right bar's bottom-avoidance clamping couldn't move it far enough.
        if bottomBarRect.intersects(rightBarRect) {
            let rightBarXRange = rightBarRect.minX...rightBarRect.maxX
            let bottomBarXRange = bottomBarRect.minX...bottomBarRect.maxX
            let xOverlap = rightBarXRange.overlaps(bottomBarXRange)
            if xOverlap {
                // Prefer pushing bottom bar downward (below the right bar)
                let newBarYBelow = rightBarRect.minY - bottomBarRect.height - 4
                let newBarYAbove = rightBarRect.maxY + 4
                let fitsBelow = newBarYBelow >= bounds.minY + 4
                let fitsAbove = newBarYAbove + bottomBarRect.height <= bounds.maxY - 4
                let dy: CGFloat
                if fitsBelow {
                    dy = newBarYBelow - bottomBarRect.minY
                } else if fitsAbove {
                    dy = newBarYAbove - bottomBarRect.minY
                } else {
                    dy = newBarYBelow - bottomBarRect.minY  // best effort
                }
                bottomBarRect = bottomBarRect.offsetBy(dx: 0, dy: dy)
                for i in 0..<bottomButtons.count {
                    bottomButtons[i].rect = bottomButtons[i].rect.offsetBy(dx: 0, dy: dy)
                }
            }
        }

        // In editor mode: pin toolbars to the window edges, not relative to selectionRect.
        if isDetached {
            // Bottom bar: centered at the bottom of the view
            let bw = bottomBarRect.width
            let bh = bottomBarRect.height
            let newBottomY: CGFloat = 6
            let newBottomX = bounds.midX - bw / 2
            let bdx = newBottomX - bottomBarRect.origin.x
            let bdy = newBottomY - bottomBarRect.origin.y
            bottomBarRect = NSRect(x: newBottomX, y: newBottomY, width: bw, height: bh)
            for i in 0..<bottomButtons.count {
                bottomButtons[i].rect = bottomButtons[i].rect.offsetBy(dx: bdx, dy: bdy)
            }

            // Right bar: top-right corner of the view
            let rw = rightBarRect.width
            let rh = rightBarRect.height
            let newRightX = bounds.maxX - rw - 6
            let newRightY = bounds.maxY - rh - 6
            let rdx = newRightX - rightBarRect.origin.x
            let rdy = newRightY - rightBarRect.origin.y
            rightBarRect = NSRect(x: newRightX, y: newRightY, width: rw, height: rh)
            for i in 0..<rightButtons.count {
                rightButtons[i].rect = rightButtons[i].rect.offsetBy(dx: rdx, dy: rdy)
            }
        }

        // Apply drag offsets
        if bottomBarDragOffset != .zero {
            bottomBarRect = bottomBarRect.offsetBy(dx: bottomBarDragOffset.x, dy: bottomBarDragOffset.y)
            for i in 0..<bottomButtons.count {
                bottomButtons[i].rect = bottomButtons[i].rect.offsetBy(dx: bottomBarDragOffset.x, dy: bottomBarDragOffset.y)
            }
        }
        if rightBarDragOffset != .zero {
            rightBarRect = rightBarRect.offsetBy(dx: rightBarDragOffset.x, dy: rightBarDragOffset.y)
            for i in 0..<rightButtons.count {
                rightButtons[i].rect = rightButtons[i].rect.offsetBy(dx: rightBarDragOffset.x, dy: rightBarDragOffset.y)
            }
        }

        // Apply hover state
        for i in 0..<bottomButtons.count {
            bottomButtons[i].isHovered = (hoveredButtonIndex == i)
        }
        for i in 0..<rightButtons.count {
            rightButtons[i].isHovered = (hoveredButtonIndex == 1000 + i)
        }

        // Apply pressed state
        for i in 0..<bottomButtons.count {
            bottomButtons[i].isPressed = (pressedButtonIndex == i)
        }
        for i in 0..<rightButtons.count {
            rightButtons[i].isPressed = (pressedButtonIndex == 1000 + i)
        }
    }

    // MARK: - Handle hit testing

    private func allHandleRects() -> [(ResizeHandle, NSRect)] {
        let r = selectionRect
        let s = handleSize
        return [
            (.topLeft, NSRect(x: r.minX - s/2, y: r.maxY - s/2, width: s, height: s)),
            (.topRight, NSRect(x: r.maxX - s/2, y: r.maxY - s/2, width: s, height: s)),
            (.bottomLeft, NSRect(x: r.minX - s/2, y: r.minY - s/2, width: s, height: s)),
            (.bottomRight, NSRect(x: r.maxX - s/2, y: r.minY - s/2, width: s, height: s)),
            (.top, NSRect(x: r.midX - s/2, y: r.maxY - s/2, width: s, height: s)),
            (.bottom, NSRect(x: r.midX - s/2, y: r.minY - s/2, width: s, height: s)),
            (.left, NSRect(x: r.minX - s/2, y: r.midY - s/2, width: s, height: s)),
            (.right, NSRect(x: r.maxX - s/2, y: r.midY - s/2, width: s, height: s)),
        ]
    }

    private func hitTestHandle(at point: NSPoint) -> ResizeHandle {
        let hitPad: CGFloat = handleSize
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
        let edgeThickness: CGFloat = 8
        let r = selectionRect
        // Top edge
        if NSRect(x: r.minX, y: r.maxY - edgeThickness/2, width: r.width, height: edgeThickness).contains(point) {
            return .top
        }
        // Bottom edge
        if NSRect(x: r.minX, y: r.minY - edgeThickness/2, width: r.width, height: edgeThickness).contains(point) {
            return .bottom
        }
        // Left edge
        if NSRect(x: r.minX - edgeThickness/2, y: r.minY, width: edgeThickness, height: r.height).contains(point) {
            return .left
        }
        // Right edge
        if NSRect(x: r.maxX - edgeThickness/2, y: r.minY, width: edgeThickness, height: r.height).contains(point) {
            return .right
        }

        return .none
    }

    // New method for hit-testing text resize handles
    private func hitTestTextResize(point: NSPoint, scrollViewFrame: NSRect) -> ResizeHandle {
        let handleSize: CGFloat = 10
        let r = scrollViewFrame
        let hs = handleSize + 4 // handle hit area

        // Top-left
        if NSRect(x: r.minX - hs/2, y: r.maxY - hs/2, width: hs, height: hs).contains(point) { return .topLeft }
        // Top-right
        if NSRect(x: r.maxX - hs/2, y: r.maxY - hs/2, width: hs, height: hs).contains(point) { return .topRight }
        // Bottom-left
        if NSRect(x: r.minX - hs/2, y: r.minY - hs/2, width: hs, height: hs).contains(point) { return .bottomLeft }
        // Bottom-right
        if NSRect(x: r.maxX - hs/2, y: r.minY - hs/2, width: hs, height: hs).contains(point) { return .bottomRight }

        return .none
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Barcode bar button hit-test
        if detectedBarcodePayload != nil && barcodeActionRects.count == 2 {
            if barcodeActionRects[1].contains(point) {
                // Dismiss
                detectedBarcodePayload = nil
                barcodeActionRects = []
                needsDisplay = true
                return
            }
            if barcodeActionRects[0].contains(point) {
                let payload = detectedBarcodePayload!
                let isURL = payload.hasPrefix("http://") || payload.hasPrefix("https://")
                detectedBarcodePayload = nil
                barcodeActionRects = []
                needsDisplay = true
                if isURL, let url = URL(string: payload) {
                    // Cancel + dismiss overlay first, then open URL on next runloop tick
                    overlayDelegate?.overlayViewDidCancel()
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload, forType: .string)
                }
                return
            }
        }

        let isTextEditing = textEditView != nil

        // Color picker swatch selection
        if showColorPicker {
            // Check opacity slider drag start
            if opacitySliderRect.contains(point) {
                isDraggingOpacitySlider = true
                updateOpacityFromPoint(point)
                return
            }
            // Check HSB gradient drag start
            if showCustomColorPicker && customPickerGradientRect.contains(point) {
                isDraggingHSBGradient = true
                let color = colorFromHSBGradient(at: point)
                currentColor = color
                applyColorToTextIfEditing()
                applyColorToSelectedAnnotation()
                needsDisplay = true
                return
            }
            // Check brightness slider drag start
            if showCustomColorPicker && customPickerBrightnessRect.contains(point) {
                isDraggingBrightnessSlider = true
                updateBrightnessFromPoint(point)
                return
            }

            if let color = hitTestColorPicker(at: point) {
                currentColor = color
                showColorPicker = false
                showCustomColorPicker = false
                applyColorToTextIfEditing()
                applyColorToSelectedAnnotation()
                if isTextEditing {
                    window?.makeFirstResponder(textEditView)
                }
                needsDisplay = true
                return
            }
            // If click is inside the color picker rect, don't dismiss
            if colorPickerRect.contains(point) {
                needsDisplay = true
                return
            }
            showColorPicker = false
            showCustomColorPicker = false
            needsDisplay = true
        }

        // Beautify picker dismissal / selection
        if showBeautifyPicker {
            if beautifyPickerRect.contains(point) {
                // Hit-test rows inside the picker
                let rowH: CGFloat = 28
                let padding: CGFloat = 6
                let styles = BeautifyRenderer.styles
                for (i, _) in styles.enumerated() {
                    let rowY = beautifyPickerRect.maxY - padding - rowH * CGFloat(i + 1)
                    let rowRect = NSRect(x: beautifyPickerRect.minX, y: rowY, width: beautifyPickerRect.width, height: rowH)
                    if rowRect.contains(point) {
                        beautifyStyleIndex = i
                        UserDefaults.standard.set(beautifyStyleIndex, forKey: "beautifyStyleIndex")
                        showBeautifyPicker = false
                        needsDisplay = true
                        return
                    }
                }
                return
            }
            showBeautifyPicker = false
            needsDisplay = true
        }

        // Stroke picker dismissal / selection
        if showStrokePicker {
            if strokePickerRect.contains(point) {
                // Smooth toggle row (pencil only)
                if currentTool == .pencil && strokeSmoothToggleRect.contains(point) {
                    pencilSmoothEnabled.toggle()
                    UserDefaults.standard.set(pencilSmoothEnabled, forKey: "pencilSmoothEnabled")
                    needsDisplay = true
                    return
                }
                let widths: [CGFloat] = [1, 2, 3, 5, 8, 12, 20]
                let rowH: CGFloat = 30
                let padding: CGFloat = 6
                for (i, width) in widths.enumerated() {
                    let rowY = strokePickerRect.maxY - padding - rowH * CGFloat(i + 1)
                    let rowRect = NSRect(x: strokePickerRect.minX, y: rowY, width: strokePickerRect.width, height: rowH)
                    if rowRect.contains(point) {
                        switch currentTool {
                        case .number:
                            currentNumberSize = width
                            UserDefaults.standard.set(Double(width), forKey: "numberStrokeWidth")
                        case .marker:
                            currentMarkerSize = width
                            UserDefaults.standard.set(Double(width), forKey: "markerStrokeWidth")
                        default:
                            currentStrokeWidth = width
                            UserDefaults.standard.set(Double(width), forKey: "currentStrokeWidth")
                        }
                        showStrokePicker = false
                        needsDisplay = true
                        return
                    }
                }
                return
            }
            showStrokePicker = false
            needsDisplay = true
        }

        // Loupe size picker dismissal / selection
        if showLoupeSizePicker {
            if loupeSizePickerRect.contains(point) {
                let sizes: [CGFloat] = [60, 80, 100, 120, 160, 200, 250, 320]
                let rowH: CGFloat = 28
                let padding: CGFloat = 6
                for (i, size) in sizes.enumerated() {
                    let rowY = loupeSizePickerRect.maxY - padding - rowH * CGFloat(i + 1)
                    let rowRect = NSRect(x: loupeSizePickerRect.minX, y: rowY, width: loupeSizePickerRect.width, height: rowH)
                    if rowRect.contains(point) {
                        currentLoupeSize = size
                        UserDefaults.standard.set(Double(size), forKey: "loupeSize")
                        showLoupeSizePicker = false
                        needsDisplay = true
                        return
                    }
                }
                return
            }
            showLoupeSizePicker = false
            needsDisplay = true
        }

        // Delay picker dismissal / selection
        if showDelayPicker {
            if delayPickerRect.contains(point) {
                let options: [(label: String, seconds: Int)] = [
                    ("Off", 0), ("1s", 1), ("2s", 2), ("3s", 3), ("5s", 5), ("10s", 10), ("30s", 30)
                ]
                let rowH: CGFloat = 28
                let padding: CGFloat = 6
                for (i, option) in options.enumerated() {
                    let rowY = delayPickerRect.maxY - padding - rowH * CGFloat(i + 1)
                    let rowRect = NSRect(x: delayPickerRect.minX, y: rowY, width: delayPickerRect.width, height: rowH)
                    if rowRect.contains(point) {
                        delaySeconds = option.seconds
                        UserDefaults.standard.set(delaySeconds, forKey: "lastDelaySeconds")
                        showDelayPicker = false
                        needsDisplay = true
                        if delaySeconds > 0 {
                            overlayDelegate?.overlayViewDidRequestDelayCapture(seconds: delaySeconds, selectionRect: selectionRect)
                        }
                        return
                    }
                }
                return
            }
            showDelayPicker = false
            needsDisplay = true
        }

        // Upload confirm dialog
        if showUploadConfirmDialog {
            if uploadConfirmOKRect.contains(point) {
                showUploadConfirmDialog = false
                needsDisplay = true
                overlayDelegate?.overlayViewDidRequestUpload()
            } else {
                showUploadConfirmDialog = false
                needsDisplay = true
            }
            return
        }

        // Upload confirm picker
        if showUploadConfirmPicker {
            if uploadConfirmPickerRect.contains(point) {
                let current = UserDefaults.standard.bool(forKey: "uploadConfirmEnabled")
                UserDefaults.standard.set(!current, forKey: "uploadConfirmEnabled")
                showUploadConfirmPicker = false
                needsDisplay = true
                return
            }
            showUploadConfirmPicker = false
            needsDisplay = true
        }

        // Redact type picker dismissal / selection
        if showRedactTypePicker {
            if redactTypePickerRect.contains(point) {
                let types = OverlayView.redactTypeNames
                let rowH: CGFloat = 26
                let padding: CGFloat = 6
                for (i, item) in types.enumerated() {
                    let rowY = redactTypePickerRect.maxY - padding - rowH * CGFloat(i + 1)
                    let rowRect = NSRect(x: redactTypePickerRect.minX, y: rowY, width: redactTypePickerRect.width, height: rowH)
                    if rowRect.contains(point) {
                        var enabledTypes = UserDefaults.standard.array(forKey: "enabledRedactTypes") as? [String] ?? types.map { $0.key }
                        if enabledTypes.contains(item.key) {
                            enabledTypes.removeAll { $0 == item.key }
                        } else {
                            enabledTypes.append(item.key)
                        }
                        UserDefaults.standard.set(enabledTypes, forKey: "enabledRedactTypes")
                        needsDisplay = true
                        return
                    }
                }
                return
            }
            showRedactTypePicker = false
                    showTranslatePicker = false
            needsDisplay = true
        }

        // Translate language picker dismissal / selection
        if showTranslatePicker {
            if translatePickerRect.contains(point) {
                let langs = TranslationService.availableLanguages
                let rowH: CGFloat = 26
                let padding: CGFloat = 6
                for (i, lang) in langs.enumerated() {
                    let rowY = translatePickerRect.maxY - padding - rowH * CGFloat(i + 1)
                    let rowRect = NSRect(x: translatePickerRect.minX, y: rowY,
                                        width: translatePickerRect.width, height: rowH)
                    if rowRect.contains(point) {
                        TranslationService.targetLanguage = lang.code
                        translateEnabled = true
                        showTranslatePicker = false
                        needsDisplay = true
                        performTranslate(targetLang: lang.code)
                        return
                    }
                }
                return
            }
            showTranslatePicker = false
            needsDisplay = true
        }

        // If text is being edited, check if the click is on the color toolbar button
        // before committing the text field
        if isTextEditing && showToolbars {
            if let action = ToolbarLayout.hitTest(point: point, buttons: bottomButtons) {
                if case .color = action {
                    showColorPicker.toggle()
                    needsDisplay = true
                    return
                }
            }
            // Clicking on the text control bar or text editor itself — don't commit
            if let bar = textControlBar, bar.frame.contains(point) {
                return
            }
            if let sv = textScrollView, sv.frame.contains(point) {
                return
            }
        }

        commitTextFieldIfNeeded()
        commitSizeInputIfNeeded()
        commitZoomInputIfNeeded()

        switch state {
        case .idle:
            // Always start a drag — snap is resolved in mouseUp if no real drag occurred
            selectionStart = point
            selectionRect = NSRect(origin: point, size: .zero)
            state = .selecting
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
                if let action = ToolbarLayout.hitTest(point: point, buttons: bottomButtons) {
                    // Flash press feedback for momentary buttons
                    let momentaryActions: [ToolbarButtonAction] = [.undo, .redo, .copy, .save, .upload, .pin, .ocr, .autoRedact, .removeBackground]
                    let isMomentary = momentaryActions.contains { actionEq($0, action) }
                    if isMomentary, let idx = bottomButtons.firstIndex(where: { $0.rect.contains(point) }) {
                        pressedButtonIndex = idx
                        needsDisplay = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                            self?.pressedButtonIndex = -1
                            self?.needsDisplay = true
                        }
                    }
                    handleToolbarAction(action, mousePoint: point)
                    return
                }
                if let action = ToolbarLayout.hitTest(point: point, buttons: rightButtons) {
                    let momentaryActions: [ToolbarButtonAction] = [.cancel, .undo, .redo, .copy, .save, .upload, .pin, .ocr, .autoRedact, .removeBackground]
                    let isMomentary = momentaryActions.contains { actionEq($0, action) }
                    if case .moveSelection = action {
                        // Keep pressed/dark while dragging — cleared in mouseUp
                        if let idx = rightButtons.firstIndex(where: { $0.rect.contains(point) }) {
                            pressedButtonIndex = 1000 + idx
                            needsDisplay = true
                        }
                    } else if isMomentary, let idx = rightButtons.firstIndex(where: { $0.rect.contains(point) }) {
                        pressedButtonIndex = 1000 + idx
                        needsDisplay = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                            self?.pressedButtonIndex = -1
                            self?.needsDisplay = true
                        }
                    }
                    handleToolbarAction(action, mousePoint: point)
                    return
                }
                // Clicking on toolbar background — start dragging toolbar
                if ToolbarLayout.hitTestBar(point: point, barRect: bottomBarRect) {
                    isDraggingBottomBar = true
                    toolbarDragStart = point
                    return
                }
                if ToolbarLayout.hitTestBar(point: point, barRect: rightBarRect) {
                    isDraggingRightBar = true
                    toolbarDragStart = point
                    return
                }
            }

            // Check handles (locked during recording)
            let handle = hitTestHandle(at: point)
            if handle != .none {
                guard !isRecording else { return }
                isResizingSelection = true
                resizeHandle = handle
                return
            }

            // Crop tool drag
            if currentTool == .crop && selectionRect.contains(point) {
                isCropDragging = true
                cropDragStart = point
                cropDragRect = .zero
                needsDisplay = true
                return
            }

            // Start annotation (convert to canvas space for zoom).
            // Require the click to be inside the selection rectangle.
            if currentTool != .crop && selectionRect.contains(point) {
                let canvasPoint = viewToCanvas(point)
                startAnnotation(at: canvasPoint)
                return
            }

            // Outside everything - start new selection (locked during recording or editor mode)
            guard !isRecording && !isDetached else { return }
            showToolbars = false
            annotations.removeAll()
            undoStack.removeAll()
            redoStack.removeAll()
            numberCounter = 0
            bottomBarDragOffset = .zero
            rightBarDragOffset = .zero
            resetZoom()
            zoomLabelOpacity = 0.0
            zoomFadeTimer?.invalidate()
            selectionStart = point
            selectionRect = NSRect(origin: point, size: .zero)
            state = .selecting
            needsDisplay = true
        
        case .selecting:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Crop drag update
        if isCropDragging {
            let clampedPoint = NSPoint(
                x: max(selectionRect.minX, min(point.x, selectionRect.maxX)),
                y: max(selectionRect.minY, min(point.y, selectionRect.maxY))
            )
            let origin = NSPoint(x: min(cropDragStart.x, clampedPoint.x), y: min(cropDragStart.y, clampedPoint.y))
            cropDragRect = NSRect(origin: origin,
                                  size: NSSize(width: abs(clampedPoint.x - cropDragStart.x),
                                               height: abs(clampedPoint.y - cropDragStart.y)))
            needsDisplay = true
            return
        }

        // Handle toolbar dragging
        if isDraggingBottomBar {
            let dx = point.x - toolbarDragStart.x
            let dy = point.y - toolbarDragStart.y
            bottomBarDragOffset = NSPoint(x: bottomBarDragOffset.x + dx, y: bottomBarDragOffset.y + dy)
            toolbarDragStart = point
            needsDisplay = true
            return
        }
        if isDraggingRightBar {
            let dx = point.x - toolbarDragStart.x
            let dy = point.y - toolbarDragStart.y
            rightBarDragOffset = NSPoint(x: rightBarDragOffset.x + dx, y: rightBarDragOffset.y + dy)
            toolbarDragStart = point
            needsDisplay = true
            return
        }

        // Handle opacity slider dragging
        if isDraggingOpacitySlider {
            updateOpacityFromPoint(point)
            return
        }
        // Handle HSB gradient dragging
        if isDraggingHSBGradient {
            let color = colorFromHSBGradient(at: point)
            currentColor = color
            applyColorToTextIfEditing()
            applyColorToSelectedAnnotation()
            needsDisplay = true
            return
        }
        // Handle brightness slider dragging
        if isDraggingBrightnessSlider {
            updateBrightnessFromPoint(point)
            return
        }

        switch state {
        case .selecting:
            let rawW = abs(point.x - selectionStart.x)
            let rawH = abs(point.y - selectionStart.y)
            let shiftHeld = event.modifierFlags.contains(.shift)
            let w = max(1, shiftHeld ? min(rawW, rawH) : rawW)
            let h = max(1, shiftHeld ? min(rawW, rawH) : rawH)
            let x = selectionStart.x < point.x ? selectionStart.x : selectionStart.x - w
            let y = selectionStart.y < point.y ? selectionStart.y : selectionStart.y - h
            selectionRect = NSRect(x: x, y: y, width: w, height: h)
            needsDisplay = true

        case .selected:
            // Convert to canvas space for annotation interactions (accounts for zoom)
            let canvasPoint = viewToCanvas(point)
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

                // Arrow/line/measure: .bottomLeft = startPoint, .topRight = endPoint, .top = controlPoint
                if annotation.tool == .arrow || annotation.tool == .line || annotation.tool == .measure {
                    switch annotationResizeHandle {
                    case .bottomLeft:
                        annotation.startPoint = NSPoint(x: origStart.x + dx, y: origStart.y + dy)
                    case .topRight:
                        annotation.endPoint = NSPoint(x: origEnd.x + dx, y: origEnd.y + dy)
                    case .top:
                        annotation.controlPoint = NSPoint(x: annotationResizeOrigControlPoint.x + dx, y: annotationResizeOrigControlPoint.y + dy)
                    default:
                        break
                    }
                } else {
                // Work in bounding-rect space so resize is correct regardless of draw direction
                let origMinX = min(origStart.x, origEnd.x)
                let origMaxX = max(origStart.x, origEnd.x)
                let origMinY = min(origStart.y, origEnd.y)
                let origMaxY = max(origStart.y, origEnd.y)
                var newMinX = origMinX, newMaxX = origMaxX
                var newMinY = origMinY, newMaxY = origMaxY

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
                annotation.startPoint = NSPoint(x: newMinX, y: newMinY)
                annotation.endPoint   = NSPoint(x: newMaxX, y: newMaxY)
                }
                cachedCompositedImage = nil
                needsDisplay = true
            } else if isDraggingAnnotation, let annotation = selectedAnnotation {
                let dx = canvasPoint.x - annotationDragStart.x
                let dy = canvasPoint.y - annotationDragStart.y
                annotation.move(dx: dx, dy: dy)
                annotationDragStart = canvasPoint
                cachedCompositedImage = nil
                needsDisplay = true
            } else if isDraggingSelection {
                selectionRect.origin = NSPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y)
                needsDisplay = true
            } else if isResizingSelection {
                resizeSelection(to: point)
                needsDisplay = true
            } else if currentAnnotation != nil {
                lastDragPoint = canvasPoint
                updateAnnotation(at: canvasPoint, shiftHeld: event.modifierFlags.contains(.shift))
                needsDisplay = true
            }

        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
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

        if isDraggingBottomBar {
            isDraggingBottomBar = false
            return
        }
        if isDraggingRightBar {
            isDraggingRightBar = false
            return
        }
        if isDraggingOpacitySlider {
            isDraggingOpacitySlider = false
            return
        }
        if isDraggingHSBGradient {
            isDraggingHSBGradient = false
            return
        }
        if isDraggingBrightnessSlider {
            isDraggingBrightnessSlider = false
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
                showToolbars = true
                overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
            } else if windowSnapEnabled, let snapRect = hoveredWindowRect, !snapRect.isEmpty {
                // Click (no drag) with snap on — snap to hovered window
                selectionRect = snapRect
                state = .selected
                showToolbars = true
                overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
            } else {
                // Click (no drag), snap off — expand to full screen
                selectionRect = bounds
                state = .selected
                showToolbars = true
                overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
            }
            hoveredWindowRect = nil
            scheduleBarcodeDetection()
            needsDisplay = true

        case .selected:
            if isDraggingAnnotation {
                isDraggingAnnotation = false
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
                moveMode = false
                pressedButtonIndex = -1
                scheduleBarcodeDetection()
                needsDisplay = true
            } else if isResizingSelection {
                isResizingSelection = false
                resizeHandle = .none
                scheduleBarcodeDetection()
                needsDisplay = true
            } else if let annotation = currentAnnotation {
                finishAnnotation(annotation)
            }

        default:
            break
        }
    }

    // MARK: - Right-click quick save

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check toolbar button right-clicks first
        if state == .selected && showToolbars {
            if let action = ToolbarLayout.hitTest(point: point, buttons: bottomButtons) {
                if case .tool(let tool) = action {
                    let toolsWithMenu: [AnnotationTool] = [.pencil, .line, .arrow, .rectangle, .ellipse, .marker, .number, .loupe]
                    if toolsWithMenu.contains(tool) {
                        currentTool = tool // Select the tool
                        if tool == .loupe {
                            showLoupeSizePicker.toggle()
                            showColorPicker = false
                            showBeautifyPicker = false
                            showStrokePicker = false
                            showDelayPicker = false
                        } else {
                            showStrokePicker.toggle()
                            showColorPicker = false
                            showBeautifyPicker = false
                            showLoupeSizePicker = false
                            showDelayPicker = false
                        }
                        needsDisplay = true
                        return
                    }
                }
                if case .beautify = action {
                    showBeautifyPicker.toggle()
                    showColorPicker = false
                    showStrokePicker = false
                    showDelayPicker = false
                    showUploadConfirmPicker = false
                    showRedactTypePicker = false
                    showTranslatePicker = false
                    showLoupeSizePicker = false
                    needsDisplay = true
                    return
                }
                if case .autoRedact = action {
                    showRedactTypePicker.toggle()
                    showColorPicker = false
                    showBeautifyPicker = false
                    showStrokePicker = false
                    showDelayPicker = false
                    showUploadConfirmPicker = false
                    needsDisplay = true
                    return
                }
                return
            }
            if let action = ToolbarLayout.hitTest(point: point, buttons: rightButtons) {
                if case .delayCapture = action {
                    showDelayPicker.toggle()
                    showColorPicker = false
                    showBeautifyPicker = false
                    showStrokePicker = false
                    showLoupeSizePicker = false
                    showUploadConfirmPicker = false
                    showRedactTypePicker = false
                    showTranslatePicker = false
                    needsDisplay = true
                    return
                }
                if case .upload = action {
                    showUploadConfirmPicker.toggle()
                    showColorPicker = false
                    showBeautifyPicker = false
                    showStrokePicker = false
                    showDelayPicker = false
                    showRedactTypePicker = false
                    showTranslatePicker = false
                    needsDisplay = true
                    return
                }
                if case .translate = action {
                    showTranslatePicker.toggle()
                    showColorPicker = false
                    showBeautifyPicker = false
                    showStrokePicker = false
                    showDelayPicker = false
                    showRedactTypePicker = false
                    showUploadConfirmPicker = false
                    needsDisplay = true
                    return
                }
                return
            }
        }

        if state == .selected && selectionRect.contains(point) {
            // Show radial color wheel
            showColorWheel = true
            colorWheelCenter = point
            colorWheelHoveredIndex = -1
            needsDisplay = true
            return
        }

        guard state == .idle else { return }
        selectionStart = point
        selectionRect = NSRect(origin: point, size: .zero)
        isRightClickSelecting = true
        state = .selecting
        needsDisplay = true
    }

    override func rightMouseDragged(with event: NSEvent) {
        if showColorWheel {
            let point = convert(event.locationInWindow, from: nil)
            colorWheelHoveredIndex = colorWheelIndexAt(point)
            needsDisplay = true
            return
        }
        guard isRightClickSelecting else { return }
        let point = convert(event.locationInWindow, from: nil)
        let x = min(selectionStart.x, point.x)
        let y = min(selectionStart.y, point.y)
        let w = max(1, abs(point.x - selectionStart.x))
        let h = max(1, abs(point.y - selectionStart.y))
        selectionRect = NSRect(x: x, y: y, width: w, height: h)
        needsDisplay = true
    }

    override func rightMouseUp(with event: NSEvent) {
        if showColorWheel {
            if colorWheelHoveredIndex >= 0 && colorWheelHoveredIndex < colorWheelColors.count {
                currentColor = colorWheelColors[colorWheelHoveredIndex]
                applyColorToTextIfEditing()
                applyColorToSelectedAnnotation()
            }
            showColorWheel = false
            colorWheelHoveredIndex = -1
            needsDisplay = true
            return
        }
        guard isRightClickSelecting else { return }
        isRightClickSelecting = false
        if selectionRect.width > 5 || selectionRect.height > 5 {
            // Real drag — use drawn rect
            state = .selected
            overlayDelegate?.overlayViewDidRequestQuickSave()
        } else if windowSnapEnabled, let snapRect = hoveredWindowRect, !snapRect.isEmpty {
            // Click (no drag) with snap on — quick save the hovered window
            selectionRect = snapRect
            state = .selected
            hoveredWindowRect = nil
            overlayDelegate?.overlayViewDidRequestQuickSave()
        } else {
            // Click (no drag), snap off — full screen quick save
            selectionRect = bounds
            state = .selected
            overlayDelegate?.overlayViewDidRequestQuickSave()
        }
    }

    // MARK: - Zoom (scroll wheel + trackpad pinch)

    override func scrollWheel(with event: NSEvent) {
        guard state == .selected else { return }
        let isTrackpadPhased = event.phase != [] || event.momentumPhase != []
        let isCommandScroll = event.modifierFlags.contains(.command)

        // Phase-based (trackpad) scroll without Cmd → pan only, never zoom
        if isTrackpadPhased && !isCommandScroll {
            guard zoomLevel != 1.0 else { return }  // pan only makes sense when zoomed
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            zoomAnchorView.x += dx
            zoomAnchorView.y -= dy  // AppKit Y is flipped vs scroll direction
            clampZoomAnchor()
            needsDisplay = true
            return
        }

        // Cmd+scroll → zoom
        guard isCommandScroll else { return }
        let cursor = convert(event.locationInWindow, from: nil)
        let delta = event.deltaY
        let factor: CGFloat = 0.1
        setZoom(zoomLevel + delta * factor, cursorView: cursor)
    }

    override func magnify(with event: NSEvent) {
        guard state == .selected else { return }
        let cursor = convert(event.locationInWindow, from: nil)
        setZoom(zoomLevel + event.magnification, cursorView: cursor)
    }

    // MARK: - Middle Mouse (toggle move mode)

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, state == .selected else { return }
        let hasMovable = annotations.contains { $0.isMovable }
        guard hasMovable else { return }

        if currentTool == .select {
            // Toggle back to previous tool
            currentTool = toolBeforeSelect ?? .arrow
            toolBeforeSelect = nil
            selectedAnnotation = nil
        } else {
            // Toggle into select mode
            toolBeforeSelect = currentTool
            currentTool = .select
        }
        needsDisplay = true
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
            newRect = NSRect(x: r.minX, y: r.minY, width: newMaxX - r.minX, height: newMaxY - r.minY)
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

    func handleToolbarAction(_ action: ToolbarButtonAction, mousePoint: NSPoint = .zero) {
        // When recording but not in annotation mode, only allow recording-control actions
        if isRecording && !isAnnotating {
            switch action {
            case .annotationMode, .stopRecord:
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
            currentTool = tool
            needsDisplay = true
        case .loupe:
            currentTool = .loupe
            needsDisplay = true
        case .color:
            showColorPicker.toggle()
            needsDisplay = true
        case .sizeDisplay:
            break
        case .moveSelection:
            guard !isRecording else { break }
            // Start drag-to-move immediately (hold and drag, release to stop)
            isDraggingSelection = true
            moveMode = true
            dragOffset = NSPoint(x: mousePoint.x - selectionRect.origin.x, y: mousePoint.y - selectionRect.origin.y)
            needsDisplay = true
        case .undo:
            undo()
        case .redo:
            redo()
        case .copy:
            overlayDelegate?.overlayViewDidConfirm()
        case .save:
            overlayDelegate?.overlayViewDidRequestSave()
        case .upload:
            let confirmEnabled = UserDefaults.standard.bool(forKey: "uploadConfirmEnabled")
            if confirmEnabled {
                showUploadConfirmDialog = true
                needsDisplay = true
            } else {
                overlayDelegate?.overlayViewDidRequestUpload()
            }
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
        case .beautify:
            beautifyEnabled.toggle()
            UserDefaults.standard.set(beautifyEnabled, forKey: "beautifyEnabled")
            needsDisplay = true
        case .beautifyStyle:
            beautifyStyleIndex = (beautifyStyleIndex + 1) % BeautifyRenderer.styles.count
            UserDefaults.standard.set(beautifyStyleIndex, forKey: "beautifyStyleIndex")
            needsDisplay = true
        case .delayCapture:
            // Toggle: 0 → last nonzero or default 3, nonzero → 0
            if delaySeconds > 0 {
                delaySeconds = 0
            } else {
                let last = UserDefaults.standard.integer(forKey: "lastDelaySeconds")
                delaySeconds = (last > 0) ? last : 3
            }
            UserDefaults.standard.set(delaySeconds, forKey: "lastDelaySeconds")
            if delaySeconds > 0 {
                overlayDelegate?.overlayViewDidRequestDelayCapture(seconds: delaySeconds, selectionRect: selectionRect)
            }
            needsDisplay = true
        case .translate:
            showTranslatePicker = false
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
            overlayDelegate?.overlayViewDidRequestStartRecording(rect: selectionRect)
        case .stopRecord:
            overlayDelegate?.overlayViewDidRequestStopRecording()
        case .annotationMode:
            isAnnotating.toggle()
            rebuildToolbarLayout()
        case .cancel:
            overlayDelegate?.overlayViewDidCancel()
        case .detach:
            overlayDelegate?.overlayViewDidRequestDetach()
        case .scrollCapture:
            overlayDelegate?.overlayViewDidRequestScrollCapture(rect: selectionRect)
        }
    }

    /// Returns a color if a preset swatch was clicked, toggles the inline HSB picker
    /// if the custom picker swatch was clicked, or picks from the HSB gradient.
    /// Returns nil if nothing was hit.
    private func hitTestColorPicker(at point: NSPoint) -> NSColor? {
        guard showColorPicker else { return nil }
        let cols = 6
        let swatchSize: CGFloat = 24
        let padding: CGFloat = 6

        for (i, color) in availableColors.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = colorPickerRect.minX + padding + CGFloat(col) * (swatchSize + padding)
            let y = colorPickerRect.maxY - padding - swatchSize - CGFloat(row) * (swatchSize + padding)
            let swatchRect = NSRect(x: x, y: y, width: swatchSize, height: swatchSize)
            if swatchRect.contains(point) {
                showCustomColorPicker = false
                return color
            }
        }

        // Custom color picker toggle swatch
        if customPickerSwatchRect.contains(point) {
            showCustomColorPicker.toggle()
            if showCustomColorPicker {
                // Initialize tracked position from current color
                if let hsb = currentColor.usingColorSpace(.deviceRGB) {
                    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                    customPickerHue = h
                    customPickerSaturation = s
                    customBrightness = b
                }
            }
            customHSBCachedImage = nil  // force redraw
            needsDisplay = true
            return nil
        }

        // HSB gradient area
        if showCustomColorPicker && customPickerGradientRect.contains(point) {
            let color = colorFromHSBGradient(at: point)
            return color
        }

        // Brightness slider
        if showCustomColorPicker && customPickerBrightnessRect.contains(point) {
            updateBrightnessFromPoint(point)
            return nil  // brightness changed, color updated via updateBrightnessFromPoint
        }

        return nil
    }

    private func colorFromHSBGradient(at point: NSPoint) -> NSColor {
        let hue = max(0, min(1, (point.x - customPickerGradientRect.minX) / customPickerGradientRect.width))
        let sat = max(0, min(1, (point.y - customPickerGradientRect.minY) / customPickerGradientRect.height))
        customPickerHue = hue
        customPickerSaturation = sat
        return NSColor(calibratedHue: hue, saturation: sat, brightness: customBrightness, alpha: 1.0)
    }

    private func updateBrightnessFromPoint(_ point: NSPoint) {
        customBrightness = max(0, min(1, (point.x - customPickerBrightnessRect.minX) / customPickerBrightnessRect.width))
        customHSBCachedImage = nil  // brightness changed, redraw gradient
        currentColor = NSColor(calibratedHue: customPickerHue, saturation: customPickerSaturation, brightness: customBrightness, alpha: 1.0)
        applyColorToTextIfEditing()
        applyColorToSelectedAnnotation()
        needsDisplay = true
    }

    private func updateOpacityFromPoint(_ point: NSPoint) {
        currentColorOpacity = max(0.05, min(1, (point.x - opacitySliderRect.minX) / opacitySliderRect.width))
        OverlayView.lastUsedOpacity = currentColorOpacity
        applyColorToSelectedAnnotation()
        needsDisplay = true
    }

    private func applyColorToTextIfEditing() {
        if let tv = textEditView {
            let textColor = annotationColor
            let range = selectedOrAllRange()
            if range.length > 0 {
                tv.textStorage?.addAttribute(.foregroundColor, value: textColor, range: range)
            }
            tv.insertionPointColor = textColor
            tv.typingAttributes[.foregroundColor] = textColor
        }
    }

    private func applyColorToSelectedAnnotation() {
        guard let ann = selectedAnnotation else { return }
        ann.color = opacityApplied(for: ann.tool)
        cachedCompositedImage = nil
        needsDisplay = true
    }

    /// Returns currentColor with opacity applied for tools that respect it.
    /// Marker uses a fixed alpha in its draw method; loupe/measure/pixelate/blur are color-independent.
    private func opacityApplied(for tool: AnnotationTool) -> NSColor {
        switch tool {
        case .marker, .loupe, .measure, .pixelate, .blur, .translateOverlay:
            return currentColor
        default:
            return annotationColor
        }
    }

    // MARK: - Annotation Creation

    private func startAnnotation(at point: NSPoint) {

        // Color sampler is preview-only, no annotation created on click.
        if currentTool == .colorSampler { return }

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
                    let frame = selected.textDrawRect
                    if let idx = annotations.firstIndex(where: { $0 === selected }) {
                        annotations.remove(at: idx)
                        selectedAnnotation = nil
                    }
                    showTextField(at: frame.origin, existingText: selected.attributedText, existingFrame: frame)
                    needsDisplay = true
                    return
                }
                // Resize handles
                for (handle, rect) in annotationResizeHandleRects {
                    if rect.insetBy(dx: -4, dy: -4).contains(point) {
                        isResizingAnnotation = true
                        annotationResizeHandle = handle
                        annotationResizeOrigStart = selected.startPoint
                        annotationResizeOrigEnd = selected.endPoint
                        annotationResizeOrigTextOrigin = selected.textDrawRect.origin
                        annotationResizeMouseStart = point
                        // For control point handle: capture current cp or visual midpoint
                        if handle == .top {
                            annotationResizeOrigControlPoint = selected.controlPoint ?? NSPoint(
                                x: (selected.startPoint.x + selected.endPoint.x) / 2,
                                y: (selected.startPoint.y + selected.endPoint.y) / 2
                            )
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

        // Hover-to-move: if the cursor is over a hovered annotation (while a drawing tool is active),
        // intercept the click and handle it like the select tool — resize handle or drag — without
        // switching currentTool.
        if let hovered = hoveredAnnotation {
            // Check resize handles of the hovered annotation (populated by drawAnnotationControls)
            for (handle, rect) in annotationResizeHandleRects {
                if rect.insetBy(dx: -4, dy: -4).contains(point) {
                    selectedAnnotation = hovered
                    isResizingAnnotation = true
                    annotationResizeHandle = handle
                    annotationResizeOrigStart = hovered.startPoint
                    annotationResizeOrigEnd = hovered.endPoint
                    annotationResizeOrigTextOrigin = hovered.textDrawRect.origin
                    annotationResizeMouseStart = point
                    if handle == .top {
                        annotationResizeOrigControlPoint = hovered.controlPoint ?? NSPoint(
                            x: (hovered.startPoint.x + hovered.endPoint.x) / 2,
                            y: (hovered.startPoint.y + hovered.endPoint.y) / 2
                        )
                    }
                    needsDisplay = true
                    return
                }
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
                return
            }
            // Click on the annotation body — start drag
            if hovered.hitTest(point: point) {
                selectedAnnotation = hovered
                isDraggingAnnotation = true
                annotationDragStart = point
                needsDisplay = true
                return
            }
        }

        // Loupe: click to place
        if currentTool == .loupe {
            let size = currentLoupeSize
            let loupeAnnotation = Annotation(
                tool: .loupe,
                startPoint: NSPoint(x: point.x - size/2, y: point.y - size/2),
                endPoint: NSPoint(x: point.x + size/2, y: point.y + size/2),
                color: currentColor,
                strokeWidth: currentStrokeWidth
            )
            loupeAnnotation.sourceImage = compositedImage()
            loupeAnnotation.sourceImageBounds = bounds
            loupeAnnotation.bakeLoupe()
            annotations.append(loupeAnnotation)
            undoStack.append(.added(loupeAnnotation))
            redoStack.removeAll()
            needsDisplay = true
            return
        }

        // Deselect when using other tools
        selectedAnnotation = nil

        switch currentTool {
        case .text:
            showTextField(at: point)
            return
        case .number:
            numberCounter += 1
            let annotation = Annotation(tool: .number, startPoint: point, endPoint: point, color: opacityApplied(for: .number), strokeWidth: currentNumberSize)
            annotation.number = numberCounter
            annotations.append(annotation)
            undoStack.append(.added(annotation))
            redoStack.removeAll()
            needsDisplay = true
            return
        default:
            break
        }

        let toolStroke: CGFloat = currentTool == .marker ? currentMarkerSize : currentStrokeWidth
        let annotation = Annotation(tool: currentTool, startPoint: point, endPoint: point, color: opacityApplied(for: currentTool), strokeWidth: toolStroke)
        if currentTool == .pencil || currentTool == .marker {
            annotation.points = [point]
        }
        if currentTool == .pixelate || currentTool == .blur {
            annotation.sourceImage = compositedImage()
            annotation.sourceImageBounds = bounds
        }
        currentAnnotation = annotation
    }

    private func updateAnnotation(at point: NSPoint, shiftHeld: Bool = false) {
        guard let annotation = currentAnnotation else { return }
        var clampedPoint = point

        if shiftHeld {
            let start = annotation.startPoint
            let dx = clampedPoint.x - start.x
            let dy = clampedPoint.y - start.y

            switch annotation.tool {
            case .line, .arrow, .measure, .loupe, .marker:
                // Snap to nearest 45° angle
                let angle = atan2(dy, dx)
                let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
                let distance = hypot(dx, dy)
                clampedPoint = NSPoint(
                    x: start.x + distance * cos(snapped),
                    y: start.y + distance * sin(snapped)
                )
            case .rectangle, .filledRectangle, .ellipse, .pixelate, .blur:
                // Constrain to square/circle: use the larger dimension
                let side = max(abs(dx), abs(dy))
                clampedPoint = NSPoint(
                    x: start.x + side * (dx >= 0 ? 1 : -1),
                    y: start.y + side * (dy >= 0 ? 1 : -1)
                )
            default:
                break
            }
        }

        annotation.endPoint = clampedPoint

        if annotation.tool == .pencil || annotation.tool == .marker {
            annotation.points?.append(clampedPoint)
        }
    }

    private func finishAnnotation(_ annotation: Annotation) {
        let dx = abs(annotation.endPoint.x - annotation.startPoint.x)
        let dy = abs(annotation.endPoint.y - annotation.startPoint.y)

        if annotation.tool == .pencil || annotation.tool == .marker {
            if let points = annotation.points, points.count >= 1 {
                // Single click: duplicate the point so drawFreeform renders a dot
                if points.count < 3, let p = points.first {
                    annotation.points = [p, p, p]
                } else if annotation.tool == .pencil && pencilSmoothEnabled {
                    annotation.points = chaikinSmooth(points, iterations: 2)
                }
                annotation.bakePixelate()  // no-op for non-pixelate tools
                annotations.append(annotation)
                undoStack.append(.added(annotation))
                redoStack.removeAll()
            }
        } else if dx > 2 || dy > 2 {
            annotation.bakePixelate()  // bake pixelate result and release screenshot ref
            annotations.append(annotation)
            undoStack.append(.added(annotation))
            redoStack.removeAll()
        }
        // Update marker preview position so it doesn't jump back to the pre-drag location
        if annotation.tool == .marker, let lastPt = annotation.points?.last {
            markerCursorPoint = lastPt
        }
        currentAnnotation = nil
        needsDisplay = true
    }

    // MARK: - Text Field

    private func showTextField(at point: NSPoint, existingText: NSAttributedString? = nil, existingFrame: NSRect = .zero) {
        let height = max(28, textFontSize + 12)
        let minW: CGFloat = 250
        let maxW = max(minW, bounds.width - point.x - 20)
        // If we have an exact frame from a previous commit, restore it; otherwise compute fresh.
        let svFrame: NSRect = existingFrame != .zero
            ? existingFrame
            : NSRect(x: point.x, y: point.y - height, width: maxW, height: height)
        let scrollView = NSScrollView(frame: svFrame)
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: maxW, height: height))
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = true
        tv.allowsUndo = true
        tv.backgroundColor = .clear
        tv.isFieldEditor = false
        tv.textColor = currentColor
        tv.insertionPointColor = currentColor
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = .zero  // eliminate inset so editing position == draw(in:) position
        tv.delegate = self

        let font = currentTextFont()
        tv.typingAttributes = [
            .font: font,
            .foregroundColor: currentColor
        ]

        scrollView.documentView = tv
        addSubview(scrollView)
        textScrollView = scrollView
        textEditView = tv

        if let existing = existingText {
            tv.textStorage?.setAttributedString(existing)
        }

        // Control bar above the text field
        let barHeight: CGFloat = 28
        let barWidth: CGFloat = 260
        let barX = point.x
        let barY = scrollView.frame.maxY + 4
        let bar = NSView(frame: NSRect(x: barX, y: barY, width: barWidth, height: barHeight))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        bar.layer?.cornerRadius = 5

        let btnH: CGFloat = 24
        let btnY: CGFloat = (barHeight - btnH) / 2
        var btnX: CGFloat = 4

        // Bold
        let boldBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 28, height: btnH),
                                        title: "B", font: NSFont.boldSystemFont(ofSize: 12),
                                        active: textBold, action: #selector(textBoldToggle(_:)), tag: 100)
        bar.addSubview(boldBtn)
        btnX += 28

        // Italic
        let italicFont = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        let italicBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 28, height: btnH),
                                          title: "I", font: italicFont,
                                          active: textItalic, action: #selector(textItalicToggle(_:)), tag: 101)
        bar.addSubview(italicBtn)
        btnX += 28

        // Underline
        let uBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 28, height: btnH),
                                     title: "U", font: NSFont.systemFont(ofSize: 12),
                                     active: textUnderline, action: #selector(textUnderlineToggle(_:)), tag: 102)
        // Add underline to the button title
        let uAttr = NSMutableAttributedString(string: "U", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: textUnderline ? ToolbarLayout.accentColor : NSColor.white,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
        uBtn.attributedTitle = uAttr
        bar.addSubview(uBtn)
        btnX += 28

        // Strikethrough
        let sBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 28, height: btnH),
                                     title: "S", font: NSFont.systemFont(ofSize: 12),
                                     active: textStrikethrough, action: #selector(textStrikethroughToggle(_:)), tag: 103)
        let sAttr = NSMutableAttributedString(string: "S", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: textStrikethrough ? ToolbarLayout.accentColor : NSColor.white,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue
        ])
        sBtn.attributedTitle = sAttr
        bar.addSubview(sBtn)
        btnX += 32

        // Separator
        let sep = NSView(frame: NSRect(x: btnX, y: btnY + 2, width: 1, height: btnH - 4))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        bar.addSubview(sep)
        btnX += 5

        // Font size decrease
        let minusBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 24, height: btnH),
                                         title: "−", font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                         active: false, action: #selector(textSizeDecrease(_:)), tag: 0)
        bar.addSubview(minusBtn)
        btnX += 24

        let sizeLabel = NSTextField(labelWithString: "\(Int(textFontSize))")
        // Use a fixed pixel size matching the font so the label is exactly as tall as the text,
        // then center that within btnH manually — avoids NSTextField top-align quirks.
        let labelFontSize: CGFloat = 12
        let labelH: CGFloat = labelFontSize + 4
        let sizeLabel_y = btnY + (btnH - labelH) / 2
        sizeLabel.frame = NSRect(x: btnX, y: sizeLabel_y, width: 28, height: labelH)
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: labelFontSize, weight: .medium)
        sizeLabel.textColor = .white
        sizeLabel.alignment = .center
        sizeLabel.tag = 999
        bar.addSubview(sizeLabel)
        btnX += 28

        // Font size increase
        let plusBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 24, height: btnH),
                                        title: "+", font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                        active: false, action: #selector(textSizeIncrease(_:)), tag: 0)
        bar.addSubview(plusBtn)
        btnX += 28

        // Separator
        let sep2 = NSView(frame: NSRect(x: btnX, y: btnY + 2, width: 1, height: btnH - 4))
        sep2.wantsLayer = true
        sep2.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        bar.addSubview(sep2)
        btnX += 5

        // Cancel (X) button
        let cancelBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 24, height: btnH),
                                          title: "✕", font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                          active: false, action: #selector(textCancelClicked(_:)), tag: 0)
        cancelBtn.contentTintColor = .systemRed
        bar.addSubview(cancelBtn)
        btnX += 28

        // Confirm (✓) button
        let confirmBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 24, height: btnH),
                                           title: "✓", font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                           active: false, action: #selector(textConfirmClicked(_:)), tag: 0)
        confirmBtn.contentTintColor = .systemGreen
        bar.addSubview(confirmBtn)
        btnX += 24

        // Resize bar to fit all buttons
        var barFrame = bar.frame
        barFrame.size.width = btnX + 4
        bar.frame = barFrame

        addSubview(bar)
        textControlBar = bar

        window?.makeFirstResponder(tv)
        window?.invalidateCursorRects(for: self)
    }

    private func currentTextFont() -> NSFont {
        if textBold && textItalic {
            return NSFontManager.shared.convert(NSFont.systemFont(ofSize: textFontSize, weight: .bold), toHaveTrait: .italicFontMask)
        } else if textItalic {
            return NSFontManager.shared.convert(NSFont.systemFont(ofSize: textFontSize), toHaveTrait: .italicFontMask)
        } else {
            return NSFont.systemFont(ofSize: textFontSize, weight: textBold ? .bold : .regular)
        }
    }

    private func selectedOrAllRange() -> NSRange {
        guard let tv = textEditView else { return NSRange(location: 0, length: 0) }
        let sel = tv.selectedRange()
        if sel.length > 0 { return sel }
        return NSRange(location: 0, length: tv.textStorage?.length ?? 0)
    }

    private func makeTextBarButton(frame: NSRect, title: String, font: NSFont, active: Bool, action: Selector, tag: Int) -> HoverButton {
        let btn = HoverButton(frame: frame)
        btn.bezelStyle = .smallSquare
        btn.isBordered = false
        btn.title = title
        btn.font = font
        btn.contentTintColor = active ? ToolbarLayout.accentColor : .white
        btn.target = self
        btn.action = action
        btn.tag = tag
        return btn
    }

    @objc private func textBoldToggle(_ sender: NSButton) {
        guard let tv = textEditView, let ts = tv.textStorage else { return }
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.font, in: range) { value, attrRange, _ in
                if let font = value as? NSFont {
                    let fm = NSFontManager.shared
                    let isBold = fm.traits(of: font).contains(.boldFontMask)
                    let newFont = isBold ? fm.convert(font, toNotHaveTrait: .boldFontMask) : fm.convert(font, toHaveTrait: .boldFontMask)
                    ts.addAttribute(.font, value: newFont, range: attrRange)
                }
            }
            ts.endEditing()
        }
        textBold.toggle()
        sender.contentTintColor = textBold ? ToolbarLayout.accentColor : .white
        tv.typingAttributes[.font] = currentTextFont()
        window?.makeFirstResponder(tv)
    }

    @objc private func textItalicToggle(_ sender: NSButton) {
        guard let tv = textEditView, let ts = tv.textStorage else { return }
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.font, in: range) { value, attrRange, _ in
                if let font = value as? NSFont {
                    let fm = NSFontManager.shared
                    let isItalic = fm.traits(of: font).contains(.italicFontMask)
                    let newFont = isItalic ? fm.convert(font, toNotHaveTrait: .italicFontMask) : fm.convert(font, toHaveTrait: .italicFontMask)
                    ts.addAttribute(.font, value: newFont, range: attrRange)
                }
            }
            ts.endEditing()
        }
        textItalic.toggle()
        sender.contentTintColor = textItalic ? ToolbarLayout.accentColor : .white
        tv.typingAttributes[.font] = currentTextFont()
        window?.makeFirstResponder(tv)
    }

    @objc private func textUnderlineToggle(_ sender: NSButton) {
        guard let tv = textEditView, let ts = tv.textStorage else { return }
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.underlineStyle, in: range) { value, attrRange, _ in
                let current = (value as? Int) ?? 0
                if current != 0 {
                    ts.removeAttribute(.underlineStyle, range: attrRange)
                } else {
                    ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: attrRange)
                }
            }
            ts.endEditing()
        }
        textUnderline.toggle()
        let uAttr = NSMutableAttributedString(string: "U", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: textUnderline ? ToolbarLayout.accentColor : NSColor.white,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
        sender.attributedTitle = uAttr
        if textUnderline {
            tv.typingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else {
            tv.typingAttributes.removeValue(forKey: .underlineStyle)
        }
        window?.makeFirstResponder(tv)
    }

    @objc private func textStrikethroughToggle(_ sender: NSButton) {
        guard let tv = textEditView, let ts = tv.textStorage else { return }
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.strikethroughStyle, in: range) { value, attrRange, _ in
                let current = (value as? Int) ?? 0
                if current != 0 {
                    ts.removeAttribute(.strikethroughStyle, range: attrRange)
                } else {
                    ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: attrRange)
                }
            }
            ts.endEditing()
        }
        textStrikethrough.toggle()
        let sAttr = NSMutableAttributedString(string: "S", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: textStrikethrough ? ToolbarLayout.accentColor : NSColor.white,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue
        ])
        sender.attributedTitle = sAttr
        if textStrikethrough {
            tv.typingAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        } else {
            tv.typingAttributes.removeValue(forKey: .strikethroughStyle)
        }
        window?.makeFirstResponder(tv)
    }

    @objc private func textSizeDecrease(_ sender: Any) {
        textFontSize = max(10, textFontSize - 2)
        applyFontSizeToSelection()
        updateSizeLabel()
    }

    @objc private func textSizeIncrease(_ sender: Any) {
        textFontSize = min(72, textFontSize + 2)
        applyFontSizeToSelection()
        updateSizeLabel()
    }

    private func applyFontSizeToSelection() {
        guard let tv = textEditView, let ts = tv.textStorage else { return }
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.font, in: range) { value, attrRange, _ in
                if let font = value as? NSFont {
                    let newFont = NSFontManager.shared.convert(font, toSize: textFontSize)
                    ts.addAttribute(.font, value: newFont, range: attrRange)
                }
            }
            ts.endEditing()
        }
        tv.typingAttributes[.font] = currentTextFont()
        resizeTextViewToFit()
        window?.makeFirstResponder(tv)
    }

    @objc private func textCancelClicked(_ sender: Any) {
        textScrollView?.removeFromSuperview()
        textScrollView = nil
        textEditView = nil
        textControlBar?.removeFromSuperview()
        textControlBar = nil
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
    }

    @objc private func textConfirmClicked(_ sender: Any) {
        commitTextFieldIfNeeded()
    }

    private func updateSizeLabel() {
        guard let bar = textControlBar,
              let label = bar.viewWithTag(999) as? NSTextField else { return }
        label.stringValue = "\(Int(textFontSize))"
    }

    private func commitTextFieldIfNeeded() {
        guard let tv = textEditView, let sv = textScrollView else { return }
        let text = tv.string
        if !text.isEmpty {
            // Render the attributed string into an NSImage using its own layout engine.
            // NSImage.lockFocus gives a flipped context matching NSTextView, so
            // draw(in:) lands correctly with no coordinate math.
            let attrStr = NSAttributedString(attributedString: tv.textStorage!)
            let imgSize = sv.frame.size
            let img = NSImage(size: imgSize)
            img.lockFocusFlipped(true)
            attrStr.draw(in: NSRect(origin: .zero, size: imgSize))
            img.unlockFocus()

            let annotation = Annotation(tool: .text,
                                        startPoint: sv.frame.origin,
                                        endPoint: NSPoint(x: sv.frame.maxX, y: sv.frame.maxY),
                                        color: opacityApplied(for: .text),
                                        strokeWidth: currentStrokeWidth)
            annotation.attributedText = attrStr
            annotation.text = text
            annotation.fontSize = textFontSize
            annotation.isBold = textBold
            annotation.isItalic = textItalic
            annotation.isUnderline = textUnderline
            annotation.isStrikethrough = textStrikethrough
            annotation.textImage = img
            annotation.textDrawRect = sv.frame
            annotations.append(annotation)
            undoStack.append(.added(annotation))
            redoStack.removeAll()
        }
        sv.removeFromSuperview()
        textScrollView = nil
        textEditView = nil
        textControlBar?.removeFromSuperview()
        textControlBar = nil
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
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

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            if isScrollCapturing {
                overlayDelegate?.overlayViewDidRequestStopScrollCapture()
                return
            }
            guard !isRecording else { return }
            if textEditView != nil {
                textScrollView?.removeFromSuperview()
                textScrollView = nil
                textEditView = nil
                textControlBar?.removeFromSuperview()
                textControlBar = nil
                window?.makeFirstResponder(self)
                window?.invalidateCursorRects(for: self)
            } else if showColorPicker {
                showColorPicker = false
                showCustomColorPicker = false
                needsDisplay = true
            } else if showUploadConfirmDialog {
                showUploadConfirmDialog = false
                needsDisplay = true
            } else if showBeautifyPicker || showStrokePicker || showLoupeSizePicker || showDelayPicker || showUploadConfirmPicker || showRedactTypePicker {
                showBeautifyPicker = false
                showStrokePicker = false
                showLoupeSizePicker = false
                showDelayPicker = false
                showUploadConfirmPicker = false
                showRedactTypePicker = false
                    showTranslatePicker = false
                needsDisplay = true
            } else {
                overlayDelegate?.overlayViewDidCancel()
            }
        case 48: // Tab — toggle window snapping (only in idle state)
            if state == .idle {
                windowSnapEnabled = !windowSnapEnabled
                hoveredWindowRect = nil
                needsDisplay = true
            }
        case 3: // F — full screen capture (only in idle state with snap on)
            if state == .idle && windowSnapEnabled {
                selectionRect = bounds
                state = .selected
                showToolbars = true
                hoveredWindowRect = nil
                scheduleBarcodeDetection()
                overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
                needsDisplay = true
            }
        case 36: // Return/Enter — only confirm overlay when not editing text
            if textEditView == nil, state == .selected {
                overlayDelegate?.overlayViewDidConfirm()
            }
        case 51: // Backspace/Delete — remove selected or hovered annotation
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
            // C (without Cmd) — copy color hex when color sampler is active
            if event.keyCode == 8 && !event.modifierFlags.contains(.command) &&
               currentTool == .colorSampler && colorSamplerPoint != .zero {
                copyColorAtSamplerPoint()
                return
            }
            // Single-key tool shortcuts (only when selected, not editing text, no modifiers)
            if state == .selected && textEditView == nil &&
               !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.option) &&
               !event.modifierFlags.contains(.control) {
                if let char = event.charactersIgnoringModifiers?.lowercased() {
                    switch char {
                    case "p": handleToolbarAction(.tool(.pencil)); return
                    case "a": handleToolbarAction(.tool(.arrow)); return
                    case "l": handleToolbarAction(.tool(.line)); return
                    case "r": handleToolbarAction(.tool(.rectangle)); return
                    case "t": handleToolbarAction(.tool(.text)); return
                    case "m": handleToolbarAction(.tool(.marker)); return
                    case "n": handleToolbarAction(.tool(.number)); return
                    case "b": handleToolbarAction(.tool(.blur)); return
                    case "x": handleToolbarAction(.tool(.pixelate)); return
                    case "i": handleToolbarAction(.tool(.colorSampler)); return
                    case "s": handleToolbarAction(.tool(.select)); return
                    case "e":
                        if !isDetached { handleToolbarAction(.detach) }
                        return
                    default: break
                    }
                }
            }
            if event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "z" {
                    if event.modifierFlags.contains(.shift) {
                        redo()
                    } else {
                        undo()
                    }
                    return
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
        if changed { window?.invalidateCursorRects(for: self) }
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
        }
        needsDisplay = true
    }

    // MARK: - Auto-Redact

    private static let sensitivePatterns: [(name: String, pattern: NSRegularExpression)] = {
        let patterns: [(String, String)] = [
            // Email addresses
            ("email", #"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"#),
            // Phone numbers (international and US formats)
            ("phone", #"(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}"#),
            // SSN (US Social Security Number)
            ("ssn", #"\b\d{3}[-\s]\d{2}[-\s]\d{4}\b"#),
            // Credit card numbers (16 digits with any whitespace/dash separators)
            ("credit_card", #"\b\d{4}[-\s]*\d{4}[-\s]*\d{4}[-\s]*\d{4}\b"#),
            // 4-digit groups that look like card number parts (standalone)
            ("card_group", #"\b\d{4}\s+\d{4}\s+\d{4}\s+\d{4}\b"#),
            // CVV (3-4 digit code near CVV/CVC/CSC label)
            ("cvv", #"(?:CVV|CVC|CSC|CCV)\s*:?\s*\d{3,4}"#),
            // Expiry dates (MM/YY, MM/YYYY, YYYY-MM, etc.)
            ("expiry", #"\b(?:\d{2}[/\-]\d{2,4}|\d{4}[/\-]\d{2})\b"#),
            // IPv4 addresses
            ("ipv4", #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#),
            // AWS access keys
            ("aws_key", #"\b(?:AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b"#),
            // Generic secret assignments (password=, token:, api_key=, etc.)
            ("secret_assignment", #"(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)\s*[:=]\s*\S+"#),
            // Long hex strings (API keys, hashes — 32+ chars)
            ("hex_key", #"\b[0-9a-fA-F]{32,}\b"#),
            // Bearer tokens
            ("bearer", #"Bearer\s+[A-Za-z0-9\-._~+/]+=*"#),
        ]
        return patterns.compactMap { (name, pat) in
            guard let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return nil }
            return (name, regex)
        }
    }()

    private func performAutoRedact() {
        guard state == .selected,
              selectionRect.width > 1, selectionRect.height > 1,
              let screenshot = screenshotImage else { return }

        // Crop the selected region for Vision
        let regionImage = NSImage(size: selectionRect.size)
        regionImage.lockFocus()
        screenshot.draw(in: NSRect(x: -selectionRect.origin.x, y: -selectionRect.origin.y,
                                    width: bounds.width, height: bounds.height),
                        from: .zero, operation: .copy, fraction: 1.0)
        regionImage.unlockFocus()

        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { return }

        let selRect = selectionRect
        let redactColor = currentColor

        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let self = self else { return }
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

            var redactAnnotations: [Annotation] = []
            let groupID = UUID()
            let padding: CGFloat = 2
            var redactedObservations = Set<Int>()  // track already-redacted observations by index

            // Helper to create a redaction annotation from a Vision bounding box
            func addRedaction(box: CGRect) {
                let viewX = selRect.origin.x + box.origin.x * selRect.width - padding
                let viewY = selRect.origin.y + box.origin.y * selRect.height - padding
                let viewW = box.width * selRect.width + padding * 2
                let viewH = box.height * selRect.height + padding * 2
                let annotation = Annotation(
                    tool: .filledRectangle,
                    startPoint: NSPoint(x: viewX, y: viewY),
                    endPoint: NSPoint(x: viewX + viewW, y: viewY + viewH),
                    color: redactColor,
                    strokeWidth: 0
                )
                annotation.groupID = groupID
                redactAnnotations.append(annotation)
            }

            // Pass 1: regex matching within each observation
            let enabledTypes = UserDefaults.standard.array(forKey: "enabledRedactTypes") as? [String]
            let activePatterns = OverlayView.sensitivePatterns.filter { pattern in
                enabledTypes == nil || enabledTypes!.contains(pattern.name)
            }

            for (i, observation) in observations.enumerated() {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                let fullRange = NSRange(location: 0, length: (text as NSString).length)

                for (_, regex) in activePatterns {
                    let matches = regex.matches(in: text, options: [], range: fullRange)
                    for match in matches {
                        guard let swiftRange = Range(match.range, in: text) else { continue }
                        guard let box = try? candidate.boundingBox(for: swiftRange) else { continue }
                        addRedaction(box: box.boundingBox)
                        redactedObservations.insert(i)
                    }
                }
            }

            // Pass 2: detect card numbers split across observations
            // Collect observations that are purely digit groups (e.g. "4868", "7191 9682", etc.)
            let digitGroupPattern = try? NSRegularExpression(pattern: #"^\d{3,4}$"#)
            var digitGroupIndices: [Int] = []
            for (i, observation) in observations.enumerated() {
                guard !redactedObservations.contains(i) else { continue }
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespaces)
                let range = NSRange(location: 0, length: (text as NSString).length)
                if digitGroupPattern?.firstMatch(in: text, options: [], range: range) != nil {
                    digitGroupIndices.append(i)
                }
            }
            // If 4+ standalone digit groups exist, they're likely a split card number — redact them all
            if digitGroupIndices.count >= 4 {
                for i in digitGroupIndices {
                    addRedaction(box: observations[i].boundingBox)
                    redactedObservations.insert(i)
                }
            }

            // Pass 3: redact observations whose text matches known sensitive labels + values
            // e.g. "CVV 344", "EXP 2029-01", standalone 3-digit numbers near card data
            if !redactedObservations.isEmpty {
                let cvvPattern = try? NSRegularExpression(pattern: #"^\d{3,4}$"#)
                let expiryPattern = try? NSRegularExpression(pattern: #"^\d{4}[-/]\d{2}$|^\d{2}[-/]\d{2,4}$"#)
                for (i, observation) in observations.enumerated() {
                    guard !redactedObservations.contains(i) else { continue }
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let text = candidate.string.trimmingCharacters(in: .whitespaces)
                    let range = NSRange(location: 0, length: (text as NSString).length)

                    // Standalone 3-digit number (likely CVV if card data was found)
                    if cvvPattern?.firstMatch(in: text, options: [], range: range) != nil {
                        addRedaction(box: observation.boundingBox)
                        redactedObservations.insert(i)
                    }
                    // Expiry date
                    if expiryPattern?.firstMatch(in: text, options: [], range: range) != nil {
                        addRedaction(box: observation.boundingBox)
                        redactedObservations.insert(i)
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self, !redactAnnotations.isEmpty else { return }
                self.annotations.append(contentsOf: redactAnnotations)
                self.undoStack.append(contentsOf: redactAnnotations.map { .added($0) })
                self.redoStack.removeAll()
                self.needsDisplay = true
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: - Translate

    private func drawTranslatePicker() {
        let langs = TranslationService.availableLanguages
        let currentCode = TranslationService.targetLanguage

        let rowH: CGFloat = 26
        let pickerWidth: CGFloat = 175
        let padding: CGFloat = 6
        let pickerHeight = rowH * CGFloat(langs.count) + padding * 2

        // Anchor to translate button in right bar
        var anchorRect = NSRect.zero
        for btn in rightButtons {
            if case .translate = btn.action { anchorRect = btn.rect; break }
        }
        if anchorRect == .zero {
            anchorRect = rightBarRect
        }

        // Position to the left of the right bar
        var pickerX = anchorRect.minX - pickerWidth - 6
        if pickerX < bounds.minX + 4 { pickerX = anchorRect.maxX + 6 }

        var pickerY = anchorRect.midY - pickerHeight / 2
        pickerY = max(bounds.minY + 4, min(pickerY, bounds.maxY - pickerHeight - 4))

        let pickerRect = NSRect(x: pickerX, y: pickerY, width: pickerWidth, height: pickerHeight)
        translatePickerRect = pickerRect

        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: pickerRect, xRadius: 6, yRadius: 6).fill()

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let dimAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.45),
        ]

        for (i, lang) in langs.enumerated() {
            let rowY = pickerRect.maxY - padding - rowH * CGFloat(i + 1)
            let rowRect = NSRect(x: pickerRect.minX, y: rowY, width: pickerRect.width, height: rowH)

            let isSelected = (lang.code == currentCode)
            if isSelected {
                ToolbarLayout.accentColor.withAlphaComponent(0.4).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
            } else if i == hoveredTranslateRow {
                NSColor.white.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
            }

            let attrs = isSelected ? textAttrs : dimAttrs
            let label = lang.name as NSString
            let labelSize = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: rowRect.minX + 10, y: rowRect.midY - labelSize.height / 2), withAttributes: attrs)

            if isSelected {
                let checkAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: ToolbarLayout.accentColor,
                ]
                let checkStr = "✓" as NSString
                let checkSize = checkStr.size(withAttributes: checkAttrs)
                checkStr.draw(at: NSPoint(x: rowRect.maxX - checkSize.width - 8, y: rowRect.midY - checkSize.height / 2), withAttributes: checkAttrs)
            }
        }

        // Show spinner if translating
        if isTranslating {
            let spinAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.white.withAlphaComponent(0.6),
            ]
            let spinStr = "Translating…" as NSString
            let spinSize = spinStr.size(withAttributes: spinAttrs)
            spinStr.draw(at: NSPoint(x: pickerRect.midX - spinSize.width / 2, y: pickerRect.minY - spinSize.height - 4), withAttributes: spinAttrs)
        }
    }

    private func performTranslate(targetLang: String) {
        guard state == .selected,
              selectionRect.width > 1, selectionRect.height > 1,
              let screenshot = screenshotImage else { return }

        // Remove any previous translate overlays
        annotations.removeAll { $0.tool == .translateOverlay }
        isTranslating = true
        needsDisplay = true

        // Crop selected region for Vision.
        // The screenshot covers the full bounds, so offset to extract the selection.
        let regionImage = NSImage(size: selectionRect.size)
        regionImage.lockFocus()
        screenshot.draw(
            in: NSRect(x: -selectionRect.origin.x, y: -selectionRect.origin.y,
                       width: bounds.width, height: bounds.height),
            from: .zero, operation: .copy, fraction: 1.0
        )
        regionImage.unlockFocus()

        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else {
            isTranslating = false
            return
        }

        let selRect = self.selectionRect
        let viewBounds = self.bounds

        // Vision OCR with bounding boxes
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let self = self else { return }
            guard let observations = request.results as? [VNRecognizedTextObservation],
                  !observations.isEmpty else {
                DispatchQueue.main.async {
                    self.isTranslating = false
                    self.showOverlayError("No text found in selection.")
                }
                return
            }

            // Filter out low-confidence / whitespace observations
            let blocks = observations.compactMap { obs -> (text: String, box: CGRect, h: CGFloat)? in
                guard let top = obs.topCandidates(1).first else { return nil }
                let t = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return nil }
                return (t, obs.boundingBox, obs.boundingBox.height)
            }

            let texts = blocks.map { $0.text }

            TranslationService.translateBatch(texts: texts, targetLang: targetLang) { [weak self] result in
                guard let self = self else { return }
                self.isTranslating = false

                switch result {
                case .failure(let error):
                    self.showOverlayError("Translation failed: \(error.localizedDescription)")
                    self.needsDisplay = true

                case .success(let translations):
                    var newAnnotations: [Annotation] = []
                    let groupID = UUID()

                    for (i, block) in blocks.enumerated() {
                        guard i < translations.count else { continue }
                        let translated = translations[i].trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !translated.isEmpty else { continue }

                        // Convert Vision normalized box (origin bottom-left) → view coords
                        let vBox = block.box
                        let padding: CGFloat = 1
                        let viewX = selRect.origin.x + vBox.origin.x * selRect.width - padding
                        let viewY = selRect.origin.y + vBox.origin.y * selRect.height - padding
                        let viewW = vBox.width * selRect.width + padding * 2
                        let viewH = vBox.height * selRect.height + padding * 2

                        // Sample average background color from the screenshot at this region
                        let bgColor = self.sampleAverageColor(
                            in: cgImage,
                            region: CGRect(
                                x: vBox.origin.x * CGFloat(cgImage.width),
                                y: vBox.origin.y * CGFloat(cgImage.height),
                                width: vBox.width * CGFloat(cgImage.width),
                                height: vBox.height * CGFloat(cgImage.height)
                            )
                        )

                        // Font size approximation from box height in view coords
                        let approxFontSize = max(8, viewH * 0.65)

                        let ann = Annotation(
                            tool: .translateOverlay,
                            startPoint: NSPoint(x: viewX, y: viewY),
                            endPoint: NSPoint(x: viewX + viewW, y: viewY + viewH),
                            color: bgColor,
                            strokeWidth: 0
                        )
                        ann.text = translated
                        ann.fontSize = approxFontSize
                        ann.groupID = groupID
                        newAnnotations.append(ann)
                    }

                    self.annotations.removeAll { $0.tool == .translateOverlay }
                    self.annotations.append(contentsOf: newAnnotations)
                    self.undoStack.append(contentsOf: newAnnotations.map { .added($0) })
                    self.redoStack.removeAll()
                    self.needsDisplay = true
                }
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    /// Samples the average color of a region in a CGImage. Returns a near-match fill color.
    private func sampleAverageColor(in cgImage: CGImage, region: CGRect) -> NSColor {
        let sampleW = max(1, Int(region.width))
        let sampleH = max(1, Int(region.height))
        let clampedX = max(0, min(Int(region.origin.x), cgImage.width - 1))
        let clampedY = max(0, min(Int(region.origin.y), cgImage.height - 1))
        let clampedW = min(sampleW, cgImage.width - clampedX)
        let clampedH = min(sampleH, cgImage.height - clampedY)
        guard clampedW > 0, clampedH > 0 else { return .white }

        // Downscale to 4×4 for cheap averaging
        let thumbW = 4, thumbH = 4
        var pixelData = [UInt8](repeating: 0, count: thumbW * thumbH * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixelData, width: thumbW, height: thumbH,
                                  bitsPerComponent: 8, bytesPerRow: thumbW * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cropped = cgImage.cropping(to: CGRect(x: clampedX, y: clampedY,
                                                        width: clampedW, height: clampedH))
        else { return .white }

        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        let count = CGFloat(thumbW * thumbH)
        for i in 0..<(thumbW * thumbH) {
            let base = i * 4
            let a = CGFloat(pixelData[base + 3]) / 255.0
            if a > 0 {
                r += CGFloat(pixelData[base])     / 255.0
                g += CGFloat(pixelData[base + 1]) / 255.0
                b += CGFloat(pixelData[base + 2]) / 255.0
            }
        }
        return NSColor(deviceRed: r / count, green: g / count, blue: b / count, alpha: 1.0)
    }

    // MARK: - Output

    /// Render screenshot + all existing annotations into a full-size image.
    /// Used as source for pixelate/blur so they operate on the composited result.
    private func compositedImage() -> NSImage? {
        if let cached = cachedCompositedImage { return cached }
        guard let screenshot = screenshotImage else { return nil }
        if annotations.isEmpty { return screenshot }

        let image = NSImage(size: bounds.size)
        image.lockFocus()
        guard let context = NSGraphicsContext.current else {
            image.unlockFocus()
            return screenshot
        }
        screenshot.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
        for annotation in annotations {
            annotation.draw(in: context)
        }
        image.unlockFocus()
        cachedCompositedImage = image
        return image
    }

    private func invalidateCompositedImageCache() {
        cachedCompositedImage = nil
    }

    func captureSelectedRegion() -> NSImage? {
        guard selectionRect.width > 0, selectionRect.height > 0 else { return nil }

        let image = NSImage(size: selectionRect.size)
        image.lockFocus()

        guard let context = NSGraphicsContext.current else {
            image.unlockFocus()
            return nil
        }

        context.cgContext.translateBy(x: -selectionRect.origin.x, y: -selectionRect.origin.y)

        if let screenshot = screenshotImage {
            // In editor mode the image is at selectionRect (natural size);
            // in overlay mode it fills bounds (full screen).
            let drawRect = isDetached ? selectionRect : bounds
            screenshot.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
        }

        for annotation in annotations {
            annotation.draw(in: context)
        }

        image.unlockFocus()
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
    func applyEditorState(_ s: OverlayEditorState, translatingBy offset: NSPoint = .zero) {
        screenshotImage = s.screenshotImage
        // Translate annotations so they're relative to the new (0,0) origin
        if offset != .zero {
            for ann in s.annotations { ann.move(dx: -offset.x, dy: -offset.y) }
            for entry in s.undoStack { entry.annotation.move(dx: -offset.x, dy: -offset.y) }
            for entry in s.redoStack { entry.annotation.move(dx: -offset.x, dy: -offset.y) }
        }
        annotations = s.annotations
        undoStack = s.undoStack
        redoStack = s.redoStack
        currentTool = s.currentTool
        currentColor = s.currentColor
        currentStrokeWidth = s.currentStrokeWidth
        currentMarkerSize = s.currentMarkerSize
        currentNumberSize = s.currentNumberSize
        numberCounter = s.numberCounter
        beautifyEnabled = s.beautifyEnabled
        beautifyStyleIndex = s.beautifyStyleIndex
        cachedCompositedImage = nil
    }

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
        cursorTimer?.invalidate()
        cursorTimer = nil
        needsDisplay = true
    }

    func reset() {
        state = .idle
        selectionRect = .zero
        annotations.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        currentAnnotation = nil
        numberCounter = 0
        showToolbars = false
        showColorPicker = false
        showBeautifyPicker = false
        showStrokePicker = false
        showLoupeSizePicker = false
        showDelayPicker = false
        showUploadConfirmPicker = false
        showUploadConfirmDialog = false
        uploadConfirmDialogRect = .zero
        uploadConfirmOKRect = .zero
        uploadConfirmCancelRect = .zero
        showRedactTypePicker = false
                    showTranslatePicker = false
        showTranslatePicker = false
        isTranslating = false
        translateEnabled = false
        moveMode = false
        selectedAnnotation = nil
        isDraggingAnnotation = false
        toolBeforeSelect = nil
        hoveredAnnotationClearTimer?.invalidate()
        hoveredAnnotationClearTimer = nil
        hoveredAnnotation = nil
        showColorWheel = false
        isRightClickSelecting = false
        delaySeconds = 0
        beautifyEnabled = UserDefaults.standard.bool(forKey: "beautifyEnabled")
        beautifyStyleIndex = UserDefaults.standard.integer(forKey: "beautifyStyleIndex")
        textScrollView?.removeFromSuperview()
        textScrollView = nil
        textEditView = nil
        textControlBar?.removeFromSuperview()
        textControlBar = nil
        sizeInputField?.removeFromSuperview()
        sizeInputField = nil
        cursorTimer?.invalidate()
        cursorTimer = nil
        showCustomColorPicker = false
        customHSBCachedImage = nil
        isDraggingHSBGradient = false
        isDraggingBrightnessSlider = false
        isDraggingOpacitySlider = false
        isDraggingBottomBar = false
        isDraggingRightBar = false
        bottomBarDragOffset = .zero
        rightBarDragOffset = .zero
        isResizingAnnotation = false
        pressedButtonIndex = -1
        loupeCursorPoint = .zero
        colorSamplerPoint = .zero
        colorSamplerBitmap = nil
        overlayErrorTimer?.invalidate()
        overlayErrorTimer = nil
        overlayErrorMessage = nil
        barcodeScanTask?.cancel()
        barcodeScanTask = nil
        detectedBarcodePayload = nil
        barcodeActionRects = []
        hoveredWindowRect = nil
        isRecording = false
        recordingElapsedSeconds = 0
        isAnnotating = false
        annotationModeEverUsed = false
        needsDisplay = true
    }
}

// MARK: - NSTextFieldDelegate

extension OverlayView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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
            // Plain Enter = new line; Shift+Enter has no special meaning
            textView.insertNewlineIgnoringFieldEditor(self)
            textDidChange(Notification(name: NSText.didChangeNotification))
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textScrollView?.removeFromSuperview()
            textScrollView = nil
            textEditView = nil
            textControlBar?.removeFromSuperview()
            textControlBar = nil
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        resizeTextViewToFit()
    }

    private func resizeTextViewToFit() {
        guard let tv = textEditView, let sv = textScrollView else { return }
        guard let layoutManager = tv.layoutManager, let textContainer = tv.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let extraHeight = layoutManager.extraLineFragmentRect.height

        let minH = max(28, textFontSize + 12)
        let newWidth = max(250, ceil(usedRect.width) + 16)
        let newHeight = max(minH, ceil(usedRect.height + extraHeight) + 10)

        // Pin the top edge, adjust origin Y downward as height grows
        let topEdge = sv.frame.maxY
        sv.frame = NSRect(x: sv.frame.minX, y: topEdge - newHeight, width: newWidth, height: newHeight)
        tv.frame.size = NSSize(width: newWidth, height: newHeight)
        if let bar = textControlBar {
            bar.frame.origin.y = sv.frame.maxY + 4
        }
    }
}

// MARK: - HoverButton

class HoverButton: NSButton {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
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
