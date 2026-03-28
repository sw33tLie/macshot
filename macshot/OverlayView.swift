import Cocoa
import UniformTypeIdentifiers
import Vision
import AVFoundation

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
    func overlayViewDidRequestShare()
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
    case added(Annotation)          // annotation was added; undo removes it
    case deleted(Annotation, Int)   // annotation was deleted at index; undo re-inserts it
    /// Image transform (crop/flip): stores the previous image and annotation offsets to restore.
    case imageTransform(previousImage: NSImage, annotationOffsets: [(Annotation, CGFloat, CGFloat)])

    var annotation: Annotation {
        switch self {
        case .added(let a), .deleted(let a, _): return a
        case .imageTransform: return Annotation(tool: .measure, startPoint: .zero, endPoint: .zero, color: .clear, strokeWidth: 0)  // dummy
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
    var editorCanvasOffset: NSPoint = .zero  // rendering offset for centering image in editor (legacy, unused in scroll view mode)

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
    var zoomMin: CGFloat { isEditorMode ? 0.1 : 1.0 }
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
    private var moveMode: Bool = false  // move tool active
    private var lastDragPoint: NSPoint?  // for shift constraint on flagsChanged
    private var spaceRepositioning: Bool = false  // Space held during drag to reposition
    private var freeformShiftDirection: Int = 0  // 0 = undecided, 1 = horizontal, 2 = vertical
    private var spaceRepositionLast: NSPoint = .zero  // last mouse position when space reposition started

    // Annotations
    var annotations: [Annotation] = [] { didSet { cachedCompositedImage = nil } }
    var undoStack: [UndoEntry] = []
    var redoStack: [UndoEntry] = []
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
    var currentNumberSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "numberStrokeWidth") as? Double
        return saved != nil ? CGFloat(saved!) : 3.0
    }()
    var currentMarkerSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "markerStrokeWidth") as? Double
        return saved != nil ? CGFloat(saved!) : 3.0
    }()
    private var numberCounter: Int = 0
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
    private var toolBeforeSelect: AnnotationTool?  // for middle-click toggle
    /// Annotation under the cursor when using a non-select drawing tool — enables on-the-fly move without switching tools.
    private var hoveredAnnotation: Annotation?
    /// Delays clearing hoveredAnnotation so the cursor can travel to handles/buttons that sit outside the hit area.
    private var hoveredAnnotationClearTimer: Timer?

    // Text editing
    var textEditView: NSTextView?
    private var textScrollView: NSScrollView?
    var textFontSize: CGFloat = 20
    var textBold: Bool = false
    var textItalic: Bool = false
    var textUnderline: Bool = false
    var textStrikethrough: Bool = false
    var textFontFamily: String = UserDefaults.standard.string(forKey: "textFontFamily") ?? "System"

    // Text options row rects (drawn in secondary toolbar)
    private var textSizeDecRect: NSRect = .zero
    private var textSizeIncRect: NSRect = .zero
    private var textFontDropdownRect: NSRect = .zero
    private var textConfirmRect: NSRect = .zero
    private var textCancelRect: NSRect = .zero
    var textAlignment: NSTextAlignment = .left
    private var isResizingTextBox: Bool = false
    private var textBoxResizeHandle: ResizeHandle = .none
    private var textBoxResizeStart: NSPoint = .zero
    private var textBoxOrigFrame: NSRect = .zero
    private var editingAnnotation: Annotation?  // annotation being re-edited
    var textBgEnabled: Bool = UserDefaults.standard.bool(forKey: "textBgEnabled")
    var textOutlineEnabled: Bool = UserDefaults.standard.bool(forKey: "textOutlineEnabled")
    private var textBgColorValue: NSColor = {
        if let data = UserDefaults.standard.data(forKey: "textBgColor"),
           let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) { return c }
        return NSColor.black.withAlphaComponent(0.6)
    }()
    private var textOutlineColorValue: NSColor = {
        if let data = UserDefaults.standard.data(forKey: "textOutlineColor"),
           let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) { return c }
        return NSColor.white
    }()
    private var showFontPicker: Bool = false
    private var fontPickerRect: NSRect = .zero
    private var fontPickerItemRects: [NSRect] = []
    private var hoveredFontIndex: Int = -1

    // Toolbars (drawn inline)
    var bottomButtons: [ToolbarButton] = []
    var rightButtons: [ToolbarButton] = []
    var bottomBarRect: NSRect = .zero
    var rightBarRect: NSRect = .zero
    var showToolbars: Bool = false {
        didSet { if showToolbars && !oldValue { rebuildToolbarLayout() } }
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
    private(set) var beautifyStyleIndex: Int = UserDefaults.standard.integer(forKey: "beautifyStyleIndex")
    var beautifyMode: BeautifyMode = BeautifyMode(rawValue: UserDefaults.standard.integer(forKey: "beautifyMode")) ?? .window
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

    // Cursor enforcement timer — forces crosshair until selection is made

    var showBeautifyInOptionsRow: Bool = false

    // Draggable toolbars

    // Color picker popover
    enum ColorPickerTarget { case drawColor, textBg, textOutline }
    private var colorPickerTarget: ColorPickerTarget = .drawColor

    // Beautify style picker popover
    // Beautify panel slider hit rects and dragging state
    private var beautifyToolbarAnimProgress: CGFloat = 1.0  // 0..1, 1 = fully settled
    private var beautifyToolbarAnimTimer: Timer?
    private var beautifyToolbarAnimTarget: Bool = false  // target beautify state

    // Tool options row (second row below bottom bar)
    var currentMeasureInPoints: Bool = UserDefaults.standard.bool(forKey: "measureInPoints")
    var currentLineStyle: LineStyle = LineStyle(rawValue: UserDefaults.standard.integer(forKey: "currentLineStyle")) ?? .solid
    var currentArrowStyle: ArrowStyle = ArrowStyle(rawValue: UserDefaults.standard.integer(forKey: "currentArrowStyle")) ?? .single
    var currentRectFillStyle: RectFillStyle = RectFillStyle(rawValue: UserDefaults.standard.integer(forKey: "currentRectFillStyle")) ?? .stroke
    private var optionsRectFillStyleRects: [NSRect] = []
    var currentStampImage: NSImage?  // selected emoji/image for stamp tool
    var currentStampEmoji: String?   // emoji string for highlight tracking
    private var stampPreviewPoint: NSPoint? // mouse position for stamp cursor preview
    static let emojiCategories: [(String, [String])] = [
        ("😀", [  // Faces & People
            "😀", "😂", "🤣", "😍", "🤔", "😎", "🤯", "😱",
            "😤", "🥳", "🤡", "💩", "👻", "🤖", "👽", "😈",
            "🙈", "🙉", "🙊", "💪", "👏", "🙌", "🤝", "🫡",
        ]),
        ("👆", [  // Hands & Gestures
            "👆", "👇", "👈", "👉", "👍", "👎", "✊", "👊",
            "🤞", "✌️", "🤟", "🫵", "☝️", "👋", "🖐️", "✋",
        ]),
        ("✅", [  // Symbols & Status
            "✅", "❌", "⚠️", "❓", "❗", "⛔", "🚫", "💯",
            "✏️", "🗑️", "📌", "🔒", "🔓", "🏷️", "📎", "🔗",
            "⬆️", "⬇️", "⬅️", "➡️", "↩️", "🔄", "➕", "➖",
        ]),
        ("🔥", [  // Objects & Reactions
            "🔥", "💡", "⭐", "❤️", "💀", "🐛", "🎯", "🚀",
            "🎉", "💣", "🧨", "⚡", "💥", "🔔", "📢", "🏆",
            "🛑", "🚧", "🏗️", "🧪", "🔬", "💻", "📱", "🖥️",
        ]),
        ("🚩", [  // Flags & Markers
            "🚩", "🏁", "📍", "💬", "💭", "🗯️", "👁️", "👀",
            "🔍", "🔎", "📝", "📋", "📊", "📈", "📉", "🗂️",
        ]),
    ]
    static let commonEmojis = [
        "👆", "👇", "👈", "👉",           // point at things
        "✅", "❌", "⚠️", "❓",            // approve / reject / warn / question
        "🔥", "🐛", "💀", "🎉",           // reactions: hot, bug, dead, celebrate
        "👀", "💡", "🎯", "⭐",           // look here, idea, bullseye, star
        "❤️", "👍", "👎", "🚀",           // love, thumbs, launch
        "✏️",                              // edit
    ]
    var currentRectCornerRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "currentRectCornerRadius") as? Double
        return v != nil ? CGFloat(v!) : 0
    }()

    // Stroke width picker popover

    // Pencil smoothing — persisted in UserDefaults
    var pencilSmoothEnabled: Bool = UserDefaults.standard.object(forKey: "pencilSmoothEnabled") as? Bool ?? true
    // Rounded rectangle corners — persisted in UserDefaults
    private var roundedRectEnabled: Bool = UserDefaults.standard.object(forKey: "roundedRectEnabled") as? Bool ?? false

    // Upload confirm picker (toggle setting via right-click)

    // Upload confirm dialog (inline confirmation before uploading)

    // Redact type picker

    static let redactTypeNames: [(key: String, label: String)] = [
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
    var currentLoupeSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "loupeSize") as? Double
        return saved != nil ? CGFloat(saved!) : 120.0
    }()
    private var loupeCursorPoint: NSPoint = .zero
    private var markerCursorPoint: NSPoint = .zero
    private var colorSamplerPoint: NSPoint = .zero  // canvas space, for color picker tool
    private var colorSamplerBitmap: NSBitmapImageRep?  // cached bitmap for fast pixel sampling
    // Auto-measure preview (live while holding 1 or 2 key)
    private var autoMeasurePreview: Annotation?  // temporary, drawn but not in annotations[]
    private var autoMeasureVertical: Bool = true  // true = "1" key, false = "2" key
    // Snap/alignment guides
    private var snapGuideX: CGFloat? = nil  // vertical guide line X
    private var snapGuideY: CGFloat? = nil  // horizontal guide line Y
    private let snapThreshold: CGFloat = 5
    private var snapGuidesEnabled: Bool {
        UserDefaults.standard.object(forKey: "snapGuidesEnabled") as? Bool ?? true
    }

    // Redact options in blur/pixelate options row
    // Editor top bar
    var editorTopBarRect: NSRect = .zero
    var editorCropBtnRect: NSRect = .zero
    var editorFlipHBtnRect: NSRect = .zero
    var editorFlipVBtnRect: NSRect = .zero
    var editorResetZoomBtnRect: NSRect = .zero
    var cachedCompositedImage: NSImage? = nil  // invalidated when annotations change

    // Translate language picker popover
    private var isTranslating: Bool = false
    private var translateEnabled: Bool = false

    // Crop tool state
    private var isCropDragging: Bool = false
    private var cropDragStart: NSPoint = .zero
    private var cropDragRect: NSRect = .zero

    // Press feedback for momentary buttons

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
    private var overlayErrorTimer: Timer? = nil

    // Barcode / QR detection
    private var detectedBarcodePayload: String? = nil
    private var barcodeActionRects: [NSRect] = []   // [0] = primary action, [1] = dismiss
    private var barcodeScanTask: DispatchWorkItem? = nil

    // Recording state
    var isRecording: Bool = false       // true when recording toolbar is shown (mode entered)
    var isCapturingVideo: Bool = false   // true when SCStream is actually capturing
    var recordingElapsedSeconds: Int = 0
    var autoEnterRecordingMode: Bool = false  // set by "Record Screen" menu — enters recording mode after selection
    var autoOCRMode: Bool = false  // set by "Capture OCR" menu — triggers OCR immediately after selection
    var autoQuickSaveMode: Bool = false  // set by "Quick Capture" menu — quick-saves immediately after selection
    // Recording overlay features
    private var mouseHighlightPoints: [(point: NSPoint, time: Date)] = []
    private var globalMouseMonitor: Any?

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
        let screenH = NSScreen.screens.first?.frame.height ?? 0

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

        needsDisplay = true
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
    private var windowSnapEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "windowSnapEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "windowSnapEnabled") }
    }
    private var hoveredWindowRect: NSRect? = nil
    private var windowSnapQueryInFlight: Bool = false
    private var customColors: [NSColor?] = Array(repeating: nil, count: 7)
    private var selectedColorSlot: Int = 0  // which custom slot is selected for saving colors
    private static var lastUsedOpacity: CGFloat = 1.0
    private var currentColorOpacity: CGFloat = OverlayView.lastUsedOpacity

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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Stamp cursor preview — track in view coords (same as annotations)
        if currentTool == .stamp && currentStampImage != nil && state == .selected && !isRecording && !showBeautifyInOptionsRow {
            let canvasStampPt = viewToCanvas(point)
            if stampPreviewPoint == nil || hypot(canvasStampPt.x - (stampPreviewPoint?.x ?? 0), canvasStampPt.y - (stampPreviewPoint?.y ?? 0)) > 0.5 {
                stampPreviewPoint = canvasStampPt
                needsDisplay = true
            }
        } else if stampPreviewPoint != nil {
            stampPreviewPoint = nil
            needsDisplay = true
        }

        // Update cursor on every mouse move
        updateCursorForPoint(point)

        // Font picker hover tracking
        if showFontPicker {
            NSCursor.arrow.set()
            var newIdx = -1
            for (i, itemRect) in fontPickerItemRects.enumerated() {
                if itemRect.contains(point) { newIdx = i; break }
            }
            if newIdx != hoveredFontIndex {
                hoveredFontIndex = newIdx
                needsDisplay = true
            }
        } else if hoveredFontIndex != -1 {
            hoveredFontIndex = -1
        }

        // Window snap: highlight hovered window in idle state.
        // CGWindowListCopyWindowInfo is expensive — run it on a background thread,
        // skipping new queries while one is already in flight.
        if state == .idle && windowSnapEnabled && !windowSnapQueryInFlight {
            guard let screenPoint = window.map({ NSPoint(x: $0.frame.origin.x + point.x, y: $0.frame.origin.y + point.y) }),
                  let viewWindow = window else { return }
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
        if state == .selected && hoverMoveTools.contains(currentTool) && !isDraggingAnnotation && !isResizingAnnotation {
            let canvasPoint = viewToCanvas(point)
            let newHovered = annotations.reversed().first { $0.isMovable && $0.hitTest(point: canvasPoint) }

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
                    unrotatedPoint = NSPoint(x: center.x + dx * cos_r - dy * sin_r,
                                             y: center.y + dx * sin_r + dy * cos_r)
                } else {
                    unrotatedPoint = point
                }
                let controlsActive = annotationDeleteButtonRect.contains(point)
                    || annotationResizeHandleRects.contains { $0.1.insetBy(dx: -8, dy: -8).contains(unrotatedPoint) }
                    || (annotationRotateHandleRect != .zero && annotationRotateHandleRect.insetBy(dx: -8, dy: -8).contains(point))

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
                        self.needsDisplay = true
                    }
                }
            }
        } else if hoveredAnnotation != nil && (!hoverMoveTools.contains(currentTool) || isDraggingAnnotation || isResizingAnnotation) {
            hoveredAnnotationClearTimer?.invalidate()
            hoveredAnnotationClearTimer = nil
            hoveredAnnotation = nil
    
            needsDisplay = true
        }
    }

    // Custom cursors
    /// Render an SF Symbol as a cursor image: white icon with dark shadow for visibility on any background.
    private static func cursorFromSymbol(_ name: String, pointSize: CGFloat, hotSpot: NSPoint, canvasSize: CGFloat = 22) -> NSCursor {
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
                        dark.draw(in: iconRect.offsetBy(dx: dx, dy: dy), from: .zero, operation: .sourceOver, fraction: 1.0)
                    }
                }
                // Draw white icon on top
                tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        return NSCursor(image: image, hotSpot: hotSpot)
    }

    private static let penCursor: NSCursor = cursorFromSymbol("pencil", pointSize: 14, hotSpot: NSPoint(x: 2, y: 20))
    private static let moveCursor: NSCursor = cursorFromSymbol("arrow.up.and.down.and.arrow.left.and.right", pointSize: 13, hotSpot: NSPoint(x: 11, y: 11))

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
        // Editor title bar — let AppKit handle
        if isEditorMode, let win = window {
            let titleH = win.frame.height - win.contentRect(forFrameRect: win.frame).height
            if point.y > bounds.height - titleH { return }
        }

        // Non-interactive states — simple cursors
        if isRecording && !isAnnotating { NSCursor.arrow.set(); return }
        if textEditView != nil { NSCursor.arrow.set(); return }
        if state == .idle || state == .selecting { NSCursor.crosshair.set(); return }
        guard state == .selected else { return }

        // Chrome areas — arrow
        if isPointOnChrome(point) { NSCursor.arrow.set(); return }

        // Selection resize handles (overlay only)
        if !isEditorMode, let handleCursor = resizeHandleCursor(at: point) {
            handleCursor.set(); return
        }

        // Hover-to-move over annotations
        if [.arrow, .line, .rectangle, .ellipse, .select].contains(currentTool) {
            if let hovered = hoveredAnnotation, hovered.hitTest(point: viewToCanvas(point)) {
                Self.moveCursor.set(); return
            }
        }

        // Tool cursor
        switch currentTool {
        case .pencil, .marker: Self.penCursor.set()
        case .select: NSCursor.arrow.set()
        default: NSCursor.crosshair.set()
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
            if let strip = bottomStripView, !strip.isHidden, strip.frame.contains(point) { return true }
            if let strip = rightStripView, !strip.isHidden, strip.frame.contains(point) { return true }
            if let row = toolOptionsRowView, !row.isHidden, row.frame.contains(point) { return true }
        }
        if showFontPicker && fontPickerRect.contains(point) { return true }
        if updateCursorForChrome(at: point) { return true }
        if sizeLabelRect.contains(point) && sizeInputField == nil { return true }
        if zoomLabelRect.contains(point) && zoomLabelOpacity > 0 && zoomInputField == nil { return true }
        return false
    }

    /// Returns the appropriate resize cursor if the point is on a selection handle, nil otherwise.
    private func resizeHandleCursor(at point: NSPoint) -> NSCursor? {
        let r = selectionRect
        let hs = handleSize + 4
        let edgeT: CGFloat = 6
        // Corner handles
        if NSRect(x: r.minX - hs/2, y: r.maxY - hs/2, width: hs, height: hs).contains(point) ||
           NSRect(x: r.maxX - hs/2, y: r.minY - hs/2, width: hs, height: hs).contains(point) { return Self.nwseCursor }
        if NSRect(x: r.maxX - hs/2, y: r.maxY - hs/2, width: hs, height: hs).contains(point) ||
           NSRect(x: r.minX - hs/2, y: r.minY - hs/2, width: hs, height: hs).contains(point) { return Self.neswCursor }
        // Edge handles
        if NSRect(x: r.minX + hs/2, y: r.maxY - edgeT/2, width: r.width - hs, height: edgeT).contains(point) ||
           NSRect(x: r.minX + hs/2, y: r.minY - edgeT/2, width: r.width - hs, height: edgeT).contains(point) { return .resizeUpDown }
        if NSRect(x: r.minX - edgeT/2, y: r.minY + hs/2, width: edgeT, height: r.height - hs).contains(point) ||
           NSRect(x: r.maxX - edgeT/2, y: r.minY + hs/2, width: edgeT, height: r.height - hs).contains(point) { return .resizeLeftRight }
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

    /// Override to draw editor background (dark canvas, centered image). Base does nothing.
    func drawEditorBackground(context: NSGraphicsContext) {
        guard isEditorMode else { return }
        let padLeft:   CGFloat = 8
        let padRight:  CGFloat = 52  // right toolbar width
        let optionsRowExtra: CGFloat = toolHasOptionsRow ? 36 : 0  // 34 row + 2 gap
        let padBottom: CGFloat = 56 + optionsRowExtra  // bottom toolbar + options row + gap
        let editorTopBarH: CGFloat = 32
        let padTop:    CGFloat = editorTopBarH + 4  // top bar + gap
        let availW = bounds.width  - padLeft - padRight
        let availH = bounds.height - padBottom - padTop
        let imgW = selectionRect.width
        let imgH = selectionRect.height
        let cx = padLeft + max(0, (availW - imgW) / 2)
        let cy = padBottom + max(0, (availH - imgH) / 2)
        editorCanvasOffset = NSPoint(x: cx, y: cy)

        NSColor(white: 0.15, alpha: 1.0).setFill()
        NSBezierPath(rect: bounds).fill()
        // Draw image with canvas offset + zoom transform
        context.saveGraphicsState()
        context.cgContext.translateBy(x: editorCanvasOffset.x, y: editorCanvasOffset.y)
        applyZoomTransform(to: context)
        if let image = screenshotImage {
            image.draw(in: selectionRect, from: .zero, operation: .copy, fraction: 1.0)
        }
        context.restoreGraphicsState()
    }

    /// Override to clip the selection image in overlay mode. Base returns true when not in editor mode.
    func shouldClipSelectionImage() -> Bool { !isEditorMode }

    /// Override to control selection border drawing. Base returns true when not in editor mode.
    func shouldDrawSelectionBorder() -> Bool { !isEditorMode }

    /// Override to control size label drawing. Base returns true when not recording/scrolling/editing.
    func shouldDrawSizeLabel() -> Bool { !isRecording && !isScrollCapturing && !isEditorMode }

    /// Override to draw top chrome (e.g. editor top bar). Base draws editor top bar when in editor mode.
    func drawTopChrome() {
        if isEditorMode {
            drawEditorTopBar()
        }
    }

    /// Override to adjust a view-space point for editor canvas offset. Base returns point unchanged.
    func adjustPointForEditor(_ p: NSPoint) -> NSPoint {
        if isEditorMode {
            return NSPoint(x: p.x - editorCanvasOffset.x, y: p.y - editorCanvasOffset.y)
        }
        return p
    }

    /// Override to apply editor-specific graphics context transform. Base translates by editorCanvasOffset when in editor mode.
    func applyEditorTransform(to context: NSGraphicsContext) {
        if isEditorMode {
            context.cgContext.translateBy(x: editorCanvasOffset.x, y: editorCanvasOffset.y)
        }
    }

    /// Override to control whether selection resize handles are active. Base returns true when not in editor mode.
    func shouldAllowSelectionResize() -> Bool { !isEditorMode }

    /// Override to control whether a new selection can be started. Base returns true when not recording and not in editor mode.
    func shouldAllowNewSelection() -> Bool { !isRecording && !isEditorMode }

    /// Override to allow panning at 1x zoom. Base returns false.
    func canPanAtOneX() -> Bool { false }

    /// Override to control whether the editor-specific zoom clamping applies. Base handles editor mode internally.
    func clampZoomAnchorForEditor(r: NSRect, z: CGFloat, ac: NSPoint, av: inout NSPoint) {
        if isEditorMode {
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
    }

    /// Override to change the rect used when drawing the screenshot in `captureSelectedRegion`. Base returns bounds.
    var captureDrawRect: NSRect { isEditorMode ? selectionRect : bounds }

    /// Override to position toolbars for editor mode. Base pins bottom bar centered at bottom, right bar at top-right.    /// Override to control whether detach (open in editor) is allowed. Base returns true when not in editor mode.
    func shouldAllowDetach() -> Bool { !isEditorMode }

    /// Override to handle clicks on the top chrome area. Base handles editor top bar buttons. Returns true if click was consumed.
    func handleTopChromeClick(at point: NSPoint) -> Bool {
        guard isEditorMode && editorTopBarRect.contains(point) else { return false }
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
        return true  // click was on top bar but not on a button — consume it
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current else { return }



        // In editor mode: dark background, draw image centered at natural size (no stretch).
        // selectionRect stays at (0, 0, imgW, imgH) — annotations always use image-relative coords.
        // editorCanvasOffset is a pure rendering offset applied via graphics context transform.
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
                    gridLine.move(to: NSPoint(x: cropDragRect.minX + thirdW * CGFloat(i), y: cropDragRect.minY))
                    gridLine.line(to: NSPoint(x: cropDragRect.minX + thirdW * CGFloat(i), y: cropDragRect.maxY))
                    gridLine.lineWidth = 0.5
                    gridLine.stroke()
                    let hLine = NSBezierPath()
                    hLine.move(to: NSPoint(x: cropDragRect.minX, y: cropDragRect.minY + thirdH * CGFloat(i)))
                    hLine.line(to: NSPoint(x: cropDragRect.maxX, y: cropDragRect.minY + thirdH * CGFloat(i)))
                    hLine.lineWidth = 0.5
                    hLine.stroke()
                }
            }

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
                } else if let hovered = hoveredAnnotation, [AnnotationTool.arrow, .line, .rectangle, .ellipse].contains(currentTool) {
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
                    } else if let hovered = hoveredAnnotation, [AnnotationTool.arrow, .line, .rectangle, .ellipse].contains(currentTool) {
                        drawAnnotationControls(for: hovered)
                    }
                    context.restoreGraphicsState()
                }

                // Re-draw loupe preview on top of beautify so it stays visible
                if currentTool == .loupe && selectionRect.contains(loupeCursorPoint) && loupeCursorPoint != .zero {
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
                if currentTool == .marker && markerCursorPoint != .zero && currentAnnotation == nil {
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
            if shouldDrawSelectionBorder() && !(beautifyEnabled && state == .selected && !isScrollCapturing && !isRecording) {
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
            if let sv = textScrollView {
                let shouldHide = false
                sv.isHidden = shouldHide
            }

            // Live text box (bg/outline + resize handles)
            if let sv = textScrollView, textEditView != nil {
                let pad: CGFloat = 4
                let pillRect = sv.frame.insetBy(dx: -pad, dy: -pad)
                let cornerR: CGFloat = 4

                // Background fill
                if textBgEnabled {
                    textBgColorValue.setFill()
                    NSBezierPath(roundedRect: pillRect, xRadius: cornerR, yRadius: cornerR).fill()
                }

                // Text outline
                if textOutlineEnabled {
                    textOutlineColorValue.setStroke()
                    let outlinePath = NSBezierPath(roundedRect: pillRect, xRadius: cornerR, yRadius: cornerR)
                    outlinePath.lineWidth = 2
                    outlinePath.stroke()
                }

                // Draw text content when scroll view is hidden (color picker open)
                if sv.isHidden, let tv = textEditView, let attrStr = tv.textStorage, attrStr.length > 0 {
                    let inset = tv.textContainerInset
                    let textRect = NSRect(x: sv.frame.minX + inset.width, y: sv.frame.minY + inset.height,
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
                    NSRect(x: sv.frame.minX - hs/2, y: sv.frame.minY - hs/2, width: hs, height: hs),  // bottom-left
                    NSRect(x: sv.frame.maxX - hs/2, y: sv.frame.minY - hs/2, width: hs, height: hs),  // bottom-right
                    NSRect(x: sv.frame.minX - hs/2, y: sv.frame.maxY - hs/2, width: hs, height: hs),  // top-left
                    NSRect(x: sv.frame.maxX - hs/2, y: sv.frame.maxY - hs/2, width: hs, height: hs),  // top-right
                    NSRect(x: sv.frame.midX - hs/2, y: sv.frame.minY - hs/2, width: hs, height: hs),  // bottom
                    NSRect(x: sv.frame.midX - hs/2, y: sv.frame.maxY - hs/2, width: hs, height: hs),  // top
                    NSRect(x: sv.frame.minX - hs/2, y: sv.frame.midY - hs/2, width: hs, height: hs),  // left
                    NSRect(x: sv.frame.maxX - hs/2, y: sv.frame.midY - hs/2, width: hs, height: hs),  // right
                ]
                for hr in handleRects {
                    handleColor.setFill()
                    NSBezierPath(roundedRect: hr, xRadius: 1, yRadius: 1).fill()
                    NSColor.black.withAlphaComponent(0.3).setStroke()
                    NSBezierPath(roundedRect: hr, xRadius: 1, yRadius: 1).stroke()
                }
            }

            // Stamp cursor preview
            if let previewPt = stampPreviewPoint, let img = currentStampImage, currentTool == .stamp, !isRecording {
                let stampSize: CGFloat = 64
                let aspect = img.size.width / max(img.size.height, 1)
                let w = aspect >= 1 ? stampSize : stampSize * aspect
                let h = aspect >= 1 ? stampSize / aspect : stampSize
                let previewRect = NSRect(x: previewPt.x - w / 2, y: previewPt.y - h / 2, width: w, height: h)
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
                img.draw(in: previewRect, from: .zero, operation: .sourceOver, fraction: 0.5, respectFlipped: true, hints: nil)
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

                // Beautify gradient picker

                // Translate language picker

                // Emoji picker

                // Tooltip for hovered button
                // Tooltips handled by ToolbarButtonView.toolTip
            }

            // Editor top bar — skip in scroll view mode (drawn in canvas coords which get magnified)
            if !isInsideScrollView {
                drawTopChrome()
            }

            // Radial color wheel
            if showColorWheel {
                drawColorWheel()
            }
        }

        // Upload confirm dialog — drawn on top of everything

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
        if isRecording {
            drawRecordingHUD()
            if UserDefaults.standard.bool(forKey: "recordMouseHighlight") { drawMouseHighlights() }
        }

        // Scroll capture HUD (drawn on top of everything when active)
        if isScrollCapturing { drawScrollCaptureHUD() }

        // Keep cursor rects in sync with current selection

    }
    private func drawIdleHelperText() {
        let line1 = windowSnapEnabled
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
        let attrs2prefix: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: dimColor]
        let attrs2state: [NSAttributedString.Key: Any]  = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: snapColor]
        let attrs2suffix: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: dimColor]

        let size1       = (line1 as NSString).size(withAttributes: attrs1)
        let size2pre    = (line3prefix as NSString).size(withAttributes: attrs2prefix)
        let size2state  = (line3state as NSString).size(withAttributes: attrs2state)
        let size2suf    = (line3suffix as NSString).size(withAttributes: attrs2suffix)
        let size2total  = CGSize(width: size2pre.width + size2state.width + size2suf.width,
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

        (line1 as NSString).draw(at: NSPoint(x: bounds.midX - size1.width / 2, y: textY1), withAttributes: attrs1)

        // Draw snap line as three segments with different colors
        let line2startX = bounds.midX - size2total.width / 2
        let line2Y = textY2 + (size2total.height - size2pre.height) / 2
        (line3prefix as NSString).draw(at: NSPoint(x: line2startX, y: line2Y), withAttributes: attrs2prefix)
        (line3state as NSString).draw(at: NSPoint(x: line2startX + size2pre.width, y: line2Y), withAttributes: attrs2state)
        (line3suffix as NSString).draw(at: NSPoint(x: line2startX + size2pre.width + size2state.width, y: line2Y), withAttributes: attrs2suffix)
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
    /// Compare two colors by RGB components (ignoring minor floating point differences)
    private func colorsMatchRGB(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let ac = a.usingColorSpace(.deviceRGB), let bc = b.usingColorSpace(.deviceRGB) else {
            return a == b
        }
        let threshold: CGFloat = 0.01
        return abs(ac.redComponent - bc.redComponent) < threshold
            && abs(ac.greenComponent - bc.greenComponent) < threshold
            && abs(ac.blueComponent - bc.blueComponent) < threshold
    }

    /// Convert NSColor to hex string like "FF3B30"
    private func colorToHexString(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "%02X%02X%02X", r, g, b)
    }

    /// Convert hex string to NSColor
    private func hexStringToColor(_ hex: String) -> NSColor? {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard h.count == 6 else { return nil }
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
    }

    // MARK: - Custom Color Persistence

    private func loadCustomColors() -> [NSColor?] {
        guard let hexArray = UserDefaults.standard.array(forKey: "customColors") as? [String] else {
            return Array(repeating: nil, count: 7)
        }
        var result: [NSColor?] = []
        for hex in hexArray.prefix(7) {
            if hex.isEmpty {
                result.append(nil)
            } else {
                result.append(hexStringToColor(hex))
            }
        }
        // Pad to 7 slots if needed
        while result.count < 7 {
            result.append(nil)
        }
        return result
    }

    private func saveCustomColors() {
        let hexArray = customColors.map { color -> String in
            guard let c = color else { return "" }
            return colorToHexString(c)
        }
        UserDefaults.standard.set(hexArray, forKey: "customColors")
    }
    /// Draw a gradient swatch — uses mesh rendering on macOS 15+ for mesh styles, linear otherwise.
    func drawStyleSwatch(style: BeautifyStyle, path: NSBezierPath, rect: NSRect) {
        if #available(macOS 15.0, *), let mesh = style.meshDef {
            if let img = BeautifyRenderer.renderMeshSwatch(mesh, size: max(rect.width, rect.height)) {
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()
                return
            }
        }
        if let grad = NSGradient(colors: style.stops.map { $0.0 }, atLocations: style.stops.map { $0.1 }, colorSpace: .deviceRGB) {
            grad.draw(in: path, angle: style.angle - 90)  // NSGradient angle: 0=up, CG angle: 0=right
        }
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
            bgRect = NSRect(x: innerX, y: innerY, width: selectionRect.width + pad * 2, height: selectionRect.height + titleBarH + pad * 2)
        } else {
            bgRect = NSRect(x: innerX, y: innerY, width: selectionRect.width + pad * 2, height: selectionRect.height + pad * 2)
        }
        context.cgContext.saveGState()
        let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: config.bgRadius, yRadius: config.bgRadius)
        bgPath.addClip()
        BeautifyRenderer.drawGradientBackground(in: bgRect, config: config, context: context.cgContext)
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
            NSBezierPath(roundedRect: windowRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        if config.mode == .window {
            // Draw window chrome
            let titleBarH: CGFloat = 28

            context.cgContext.saveGState()
            NSBezierPath(roundedRect: windowRect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()

            // Window background
            NSColor(white: 0.97, alpha: 1.0).setFill()
            NSBezierPath(rect: windowRect).fill()

            // Title bar
            let titleBarRect = NSRect(x: windowRect.minX, y: windowRect.maxY - titleBarH, width: windowRect.width, height: titleBarH)
            NSColor(white: 0.94, alpha: 1.0).setFill()
            NSBezierPath(rect: titleBarRect).fill()

            // Separator
            NSColor(white: 0.82, alpha: 1.0).setFill()
            NSBezierPath(rect: NSRect(x: windowRect.minX, y: titleBarRect.minY - 0.5, width: windowRect.width, height: 0.5)).fill()

            // Traffic lights
            let buttonY = titleBarRect.midY
            let buttonRadius: CGFloat = 6
            let buttonStartX = windowRect.minX + 14
            let buttonSpacing: CGFloat = 20
            let trafficLights: [(NSColor, NSColor)] = [
                (NSColor(calibratedRed: 1.0, green: 0.38, blue: 0.35, alpha: 1.0),
                 NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.22, alpha: 1.0)),
                (NSColor(calibratedRed: 1.0, green: 0.75, blue: 0.25, alpha: 1.0),
                 NSColor(calibratedRed: 0.85, green: 0.60, blue: 0.15, alpha: 1.0)),
                (NSColor(calibratedRed: 0.30, green: 0.80, blue: 0.35, alpha: 1.0),
                 NSColor(calibratedRed: 0.20, green: 0.65, blue: 0.25, alpha: 1.0)),
            ]
            for (i, (fill, ring)) in trafficLights.enumerated() {
                let cx = buttonStartX + CGFloat(i) * buttonSpacing
                let circleRect = NSRect(x: cx - buttonRadius, y: buttonY - buttonRadius, width: buttonRadius * 2, height: buttonRadius * 2)
                fill.setFill()
                NSBezierPath(ovalIn: circleRect).fill()
                ring.setStroke()
                let border = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 0.5
                border.stroke()
            }

            // Draw screenshot in content area (clipped to window shape)
            if let image = screenshotImage {
                image.draw(in: imageRect, from: selectionRect, operation: .sourceOver, fraction: 1.0)
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
            NSBezierPath(roundedRect: imageRect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()

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
        case .pencil, .line, .arrow, .rectangle, .ellipse, .marker, .number, .loupe, .measure, .pixelate, .blur, .stamp:
            return true
        case .text:
            return true
        default:
            return showBeautifyInOptionsRow
        }
    }
    /// Curated font families for the font picker
    static let fontFamilies: [String] = {
        // "System" uses the default SF Pro; the rest are well-known macOS-bundled families
        var families = ["System"]
        let wanted = [
            "Helvetica Neue", "Arial", "Avenir Next", "Futura",
            "Georgia", "Times New Roman", "Palatino",
            "Courier New", "Menlo", "SF Mono",
            "Gill Sans", "Verdana", "Trebuchet MS",
            "American Typewriter", "Didot", "Baskerville",
            "Marker Felt", "Noteworthy", "Chalkboard SE",
            "Copperplate", "Optima", "Phosphate",
        ]
        let available = Set(NSFontManager.shared.availableFontFamilies)
        for name in wanted {
            if available.contains(name) { families.append(name) }
        }
        return families
    }()

    func renderEmoji(_ emoji: String, size: CGFloat = 128) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.85)]
        let str = emoji as NSString
        let strSize = str.size(withAttributes: attrs)
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            str.draw(at: NSPoint(x: (size - strSize.width) / 2, y: (size - strSize.height) / 2), withAttributes: attrs)
            return true
        }
        img.setName(emoji)
        return img
    }

    func loadStampImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.level = .statusBar + 3
        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url,
                  let image = NSImage(contentsOf: url) else { return }
            self.currentStampImage = image
            self.currentStampEmoji = nil
            self.needsDisplay = true
        }
    }
    @discardableResult
    private func drawTextStyleToggle(label: String, color: NSColor, enabled: Bool,
                                     x: CGFloat, rowRect: NSRect, targetRect: inout NSRect) -> CGFloat {
        let btnH: CGFloat = 20
        let swatchSize: CGFloat = 12
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(enabled ? 0.85 : 0.35),
        ]
        let labelStr = label as NSString
        let labelSize = labelStr.size(withAttributes: labelAttrs)
        let btnW = swatchSize + 4 + labelSize.width + 8
        let btnRect = NSRect(x: x, y: rowRect.midY - btnH / 2, width: btnW, height: btnH)
        targetRect = btnRect

        // Button background
        let bgAlpha: CGFloat = enabled ? 0.15 : 0.06
        NSColor.white.withAlphaComponent(bgAlpha).setFill()
        NSBezierPath(roundedRect: btnRect, xRadius: 4, yRadius: 4).fill()

        // Color swatch
        let swatchRect = NSRect(x: btnRect.minX + 4, y: btnRect.midY - swatchSize / 2,
                                width: swatchSize, height: swatchSize)
        if enabled {
            color.setFill()
            NSBezierPath(roundedRect: swatchRect, xRadius: 2, yRadius: 2).fill()
        } else {
            NSColor.white.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: swatchRect, xRadius: 2, yRadius: 2).fill()
            // Diagonal line through swatch
            NSColor.white.withAlphaComponent(0.25).setStroke()
            let strike = NSBezierPath()
            strike.lineWidth = 1
            strike.move(to: NSPoint(x: swatchRect.minX + 2, y: swatchRect.minY + 2))
            strike.line(to: NSPoint(x: swatchRect.maxX - 2, y: swatchRect.maxY - 2))
            strike.stroke()
        }

        // Label
        labelStr.draw(at: NSPoint(x: swatchRect.maxX + 4, y: btnRect.midY - labelSize.height / 2),
                       withAttributes: labelAttrs)

        return x + btnW
    }

    private func drawTextFormatButton(rect: NSRect, label: String, font: NSFont, active: Bool,
                                      activeColor: NSColor, inactiveColor: NSColor) {
        if active {
            activeColor.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        let color = active ? activeColor : inactiveColor
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (label as NSString).size(withAttributes: attrs)
        (label as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    }

    private func drawTextFormatButtonAttributed(rect: NSRect, label: String, font: NSFont, active: Bool,
                                                activeColor: NSColor, inactiveColor: NSColor,
                                                extraAttrs: [NSAttributedString.Key: Any]) {
        if active {
            activeColor.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        let color = active ? activeColor : inactiveColor
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        for (k, v) in extraAttrs { attrs[k] = v }
        let str = NSAttributedString(string: label, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    private func drawFontPickerDropdown() {
        let families = OverlayView.fontFamilies
        let itemH: CGFloat = 24
        let pickerW: CGFloat = 180
        let pickerH = CGFloat(families.count) * itemH + 8
        let pickerX = textFontDropdownRect.minX
        let pickerY: CGFloat
        if bottomBarRect.midY < selectionRect.midY {
            // Toolbar is below selection — try opening downward
            let downY = (toolOptionsRowView?.frame.minY ?? 0) - pickerH - 2
            pickerY = downY >= bounds.minY + 4 ? downY : (toolOptionsRowView?.frame.maxY ?? 0) + 2
        } else {
            // Toolbar is above selection — try opening upward
            let upY = (toolOptionsRowView?.frame.maxY ?? 0) + 2
            pickerY = (upY + pickerH) <= bounds.maxY - 4 ? upY : (toolOptionsRowView?.frame.minY ?? 0) - pickerH - 2
        }

        let pRect = NSRect(x: pickerX, y: pickerY, width: pickerW, height: pickerH)
        fontPickerRect = pRect

        // Background
        NSColor(white: 0.10, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: pRect, xRadius: 6, yRadius: 6).fill()
        // Border
        NSColor.white.withAlphaComponent(0.1).setStroke()
        let borderPath = NSBezierPath(roundedRect: pRect, xRadius: 6, yRadius: 6)
        borderPath.lineWidth = 0.5
        borderPath.stroke()

        fontPickerItemRects = []
        for (i, family) in families.enumerated() {
            let itemY = pRect.maxY - 4 - CGFloat(i + 1) * itemH
            let itemRect = NSRect(x: pRect.minX + 4, y: itemY, width: pickerW - 8, height: itemH)
            fontPickerItemRects.append(itemRect)

            let isSelected = family == textFontFamily
            let isHovered = i == hoveredFontIndex

            if isSelected {
                ToolbarLayout.accentColor.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: itemRect, xRadius: 4, yRadius: 4).fill()
            } else if isHovered {
                NSColor.white.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: itemRect, xRadius: 4, yRadius: 4).fill()
            }

            // Use the actual font family for the label so users see a preview
            let previewFont: NSFont
            if family == "System" {
                previewFont = NSFont.systemFont(ofSize: 11)
            } else {
                previewFont = NSFont(name: family, size: 11) ?? NSFont.systemFont(ofSize: 11)
            }
            let textColor: NSColor = isSelected ? ToolbarLayout.accentColor : (isHovered ? NSColor.white : NSColor.white.withAlphaComponent(0.8))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: previewFont,
                .foregroundColor: textColor,
            ]
            let nameSize = (family as NSString).size(withAttributes: attrs)
            (family as NSString).draw(
                at: NSPoint(x: itemRect.minX + 8, y: itemRect.midY - nameSize.height / 2),
                withAttributes: attrs)

            // Check mark for selected
            if isSelected {
                let checkAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: ToolbarLayout.accentColor,
                ]
                let checkStr = "✓" as NSString
                let checkSize = checkStr.size(withAttributes: checkAttrs)
                checkStr.draw(at: NSPoint(x: itemRect.maxX - checkSize.width - 6, y: itemRect.midY - checkSize.height / 2), withAttributes: checkAttrs)
            }
        }
    }

    /// Draws a macOS-style pill toggle (like iOS switches but smaller)
    @discardableResult    private func drawArrowStylePreview(style: ArrowStyle, in rect: NSRect, active: Bool) {
        let color = NSColor.white.withAlphaComponent(active ? 0.9 : 0.35)
        let inset: CGFloat = 7
        let left = NSPoint(x: rect.minX + inset, y: rect.midY)
        let right = NSPoint(x: rect.maxX - inset, y: rect.midY)
        let headLen: CGFloat = 6
        let headAngle: CGFloat = .pi / 5

        // Shaft
        let shaft = NSBezierPath()
        shaft.lineWidth = 1.5
        shaft.lineCapStyle = .round
        color.setStroke()
        color.setFill()

        switch style {
        case .single:
            let base = NSPoint(x: right.x - headLen * cos(0), y: right.y)
            shaft.move(to: left)
            shaft.line(to: base)
            shaft.stroke()
            let head = NSBezierPath()
            head.move(to: right)
            head.line(to: NSPoint(x: right.x - headLen * cos(headAngle), y: right.y + headLen * sin(headAngle)))
            head.line(to: NSPoint(x: right.x - headLen * cos(headAngle), y: right.y - headLen * sin(headAngle)))
            head.close()
            head.fill()

        case .thick:
            let tailHalf: CGFloat = 1.5
            let shaftHalf: CGFloat = 3
            let headHalf: CGFloat = 7
            let headW: CGFloat = 8
            let headBaseX = right.x - headW
            let ctrlX = left.x + (headBaseX - left.x) * 0.6
            let path = NSBezierPath()
            // Left side: narrow tail -> wide shaft (curve)
            path.move(to: NSPoint(x: left.x, y: left.y + tailHalf))
            path.curve(to: NSPoint(x: headBaseX, y: left.y + shaftHalf),
                        controlPoint1: NSPoint(x: ctrlX, y: left.y + tailHalf),
                        controlPoint2: NSPoint(x: headBaseX, y: left.y + shaftHalf))
            // Left wing
            path.curve(to: NSPoint(x: headBaseX, y: left.y + headHalf),
                        controlPoint1: NSPoint(x: headBaseX - 2, y: left.y + shaftHalf),
                        controlPoint2: NSPoint(x: headBaseX, y: left.y + headHalf))
            path.line(to: right)
            // Right wing
            path.line(to: NSPoint(x: headBaseX, y: left.y - headHalf))
            path.curve(to: NSPoint(x: headBaseX, y: left.y - shaftHalf),
                        controlPoint1: NSPoint(x: headBaseX, y: left.y - headHalf),
                        controlPoint2: NSPoint(x: headBaseX - 2, y: left.y - shaftHalf))
            // Right side: wide shaft -> narrow tail (curve)
            path.curve(to: NSPoint(x: left.x, y: left.y - tailHalf),
                        controlPoint1: NSPoint(x: headBaseX, y: left.y - shaftHalf),
                        controlPoint2: NSPoint(x: ctrlX, y: left.y - tailHalf))
            path.close()
            path.fill()

        case .double:
            let endBase = NSPoint(x: right.x - headLen, y: right.y)
            let startBase = NSPoint(x: left.x + headLen, y: left.y)
            shaft.move(to: startBase)
            shaft.line(to: endBase)
            shaft.stroke()
            // End head
            let endHead = NSBezierPath()
            endHead.move(to: right)
            endHead.line(to: NSPoint(x: right.x - headLen * cos(headAngle), y: right.y + headLen * sin(headAngle)))
            endHead.line(to: NSPoint(x: right.x - headLen * cos(headAngle), y: right.y - headLen * sin(headAngle)))
            endHead.close()
            endHead.fill()
            // Start head
            let startHead = NSBezierPath()
            startHead.move(to: left)
            startHead.line(to: NSPoint(x: left.x + headLen * cos(headAngle), y: left.y + headLen * sin(headAngle)))
            startHead.line(to: NSPoint(x: left.x + headLen * cos(headAngle), y: left.y - headLen * sin(headAngle)))
            startHead.close()
            startHead.fill()

        case .open:
            shaft.move(to: left)
            shaft.line(to: right)
            shaft.stroke()
            let head = NSBezierPath()
            head.lineWidth = 1.5
            head.lineCapStyle = .round
            head.lineJoinStyle = .round
            head.move(to: NSPoint(x: right.x - headLen * cos(headAngle), y: right.y + headLen * sin(headAngle)))
            head.line(to: right)
            head.line(to: NSPoint(x: right.x - headLen * cos(headAngle), y: right.y - headLen * sin(headAngle)))
            head.stroke()

        case .tail:
            let base = NSPoint(x: right.x - headLen, y: right.y)
            shaft.move(to: left)
            shaft.line(to: base)
            shaft.stroke()
            let head = NSBezierPath()
            head.move(to: right)
            head.line(to: NSPoint(x: right.x - headLen * cos(headAngle), y: right.y + headLen * sin(headAngle)))
            head.line(to: NSPoint(x: right.x - headLen * cos(headAngle), y: right.y - headLen * sin(headAngle)))
            head.close()
            head.fill()
            let r: CGFloat = 3
            NSBezierPath(ovalIn: NSRect(x: left.x - r, y: left.y - r, width: r * 2, height: r * 2)).fill()
        }
    }
    @discardableResult    private func startBeautifyToolbarAnimation() {
        beautifyToolbarAnimProgress = 0
        beautifyToolbarAnimTarget = beautifyEnabled
        beautifyToolbarAnimTimer?.invalidate()
        beautifyToolbarAnimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.beautifyToolbarAnimProgress += 0.08  // ~12 frames = 0.2s
            if self.beautifyToolbarAnimProgress >= 1.0 {
                self.beautifyToolbarAnimProgress = 1.0
                timer.invalidate()
                self.beautifyToolbarAnimTimer = nil
            }
            self.needsDisplay = true
        }
    }


    // MARK: - Beautify Slider (used from options row)

    // MARK: - Upload Confirm Picker
    // MARK: - Upload Confirm Dialog
    // MARK: - Redact Type Picker
    // MARK: - Loupe Size Picker

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

    // MARK: - Editor Top Bar

    func drawEditorTopBar() {
        let barH: CGFloat = 32
        let barRect = NSRect(x: 0, y: bounds.maxY - barH, width: bounds.width, height: barH)
        editorTopBarRect = barRect

        // Background — subtle dark bar
        NSColor(white: 0.10, alpha: 1.0).setFill()
        NSBezierPath(rect: barRect).fill()

        // Bottom separator line
        NSColor(white: 0.25, alpha: 1.0).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: barRect.minY, width: barRect.width, height: 0.5)).fill()

        let btnH: CGFloat = 22
        let btnY = barRect.midY - btnH / 2
        let btnRadius: CGFloat = 4
        var curX: CGFloat = 12

        let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let labelColor = NSColor.white.withAlphaComponent(0.85)
        let dimColor = NSColor.white.withAlphaComponent(0.45)

        // ── Pixel size label ──
        if let img = screenshotImage {
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            let pw = Int(img.size.width * scale)
            let ph = Int(img.size.height * scale)
            let sizeStr = "\(pw) × \(ph)" as NSString
            let sizeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: dimColor,
            ]
            let sizeSize = sizeStr.size(withAttributes: sizeAttrs)
            sizeStr.draw(at: NSPoint(x: curX, y: barRect.midY - sizeSize.height / 2), withAttributes: sizeAttrs)
            curX += sizeSize.width + 16
        }

        // ── Separator ──
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSBezierPath(rect: NSRect(x: curX, y: barRect.minY + 7, width: 0.5, height: barH - 14)).fill()
        curX += 12

        // ── Crop button ──
        let isCropActive = (currentTool == .crop)
        let cropBtnW: CGFloat = btnH
        let cropRect = NSRect(x: curX, y: btnY, width: cropBtnW, height: btnH)
        editorCropBtnRect = cropRect

        let cropBg = isCropActive ? ToolbarLayout.selectedBg : NSColor.white.withAlphaComponent(0.08)
        cropBg.setFill()
        NSBezierPath(roundedRect: cropRect, xRadius: btnRadius, yRadius: btnRadius).fill()
        drawTopBarIcon("crop", in: cropRect, selected: isCropActive)
        curX += cropBtnW + 4

        // ── Flip Horizontal button ──
        let flipHBtnW: CGFloat = btnH
        let flipHRect = NSRect(x: curX, y: btnY, width: flipHBtnW, height: btnH)
        editorFlipHBtnRect = flipHRect

        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: flipHRect, xRadius: btnRadius, yRadius: btnRadius).fill()
        drawTopBarIcon("arrow.left.and.right.righttriangle.left.righttriangle.right", in: flipHRect, selected: false)
        curX += flipHBtnW + 4

        // ── Flip Vertical button ──
        let flipVBtnW: CGFloat = btnH
        let flipVRect = NSRect(x: curX, y: btnY, width: flipVBtnW, height: btnH)
        editorFlipVBtnRect = flipVRect

        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: flipVRect, xRadius: btnRadius, yRadius: btnRadius).fill()
        drawTopBarIcon("arrow.up.and.down.righttriangle.up.righttriangle.down", in: flipVRect, selected: false)

        // ── Zoom label (right-aligned) ──
        let zoomStr = "\(Int(zoomLevel * 100))%" as NSString
        let zoomAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: dimColor,
        ]
        let zoomSize = zoomStr.size(withAttributes: zoomAttrs)
        let zoomX = barRect.maxX - zoomSize.width - 12
        zoomStr.draw(at: NSPoint(x: zoomX, y: barRect.midY - zoomSize.height / 2),
                     withAttributes: zoomAttrs)

        // ── Reset zoom button (left of zoom %) ──
        let resetBtnW: CGFloat = btnH
        let resetRect = NSRect(x: zoomX - resetBtnW - 6, y: btnY, width: resetBtnW, height: btnH)
        editorResetZoomBtnRect = resetRect
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: resetRect, xRadius: btnRadius, yRadius: btnRadius).fill()
        drawTopBarIcon("arrow.counterclockwise", in: resetRect, selected: false)
    }

    private func drawTopBarIcon(_ symbolName: String, in rect: NSRect, selected: Bool) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        guard let baseImg = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) else { return }
        let tint: NSColor = selected ? .white : .white.withAlphaComponent(0.85)
        let imgSize = baseImg.size
        let tintedImg = NSImage(size: imgSize, flipped: false) { r in
            baseImg.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            tint.setFill()
            r.fill(using: .sourceAtop)
            return true
        }
        let iconRect = NSRect(x: rect.midX - imgSize.width / 2, y: rect.midY - imgSize.height / 2,
                              width: imgSize.width, height: imgSize.height)
        tintedImg.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    // MARK: - Editor Image Transforms

    func flipImageHorizontally() {
        guard let original = screenshotImage,
              let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        // Save state for undo
        let prevImage = original.copy() as! NSImage
        undoStack.append(.imageTransform(previousImage: prevImage, annotationOffsets: []))
        redoStack.removeAll()

        let w = cgImage.width, h = cgImage.height
        let cs = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: cgImage.bitsPerComponent,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: cgImage.bitmapInfo.rawValue) else { return }
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
                ann.controlPoint = NSPoint(x: selectionRect.minX + (selectionRect.maxX - cp.x), y: cp.y)
            }
            // Mirror freeform points
            if let pts = ann.points {
                ann.points = pts.map { NSPoint(x: selectionRect.minX + (selectionRect.maxX - $0.x), y: $0.y) }
            }
        }

        cachedCompositedImage = nil
        needsDisplay = true
    }

    func flipImageVertically() {
        guard let original = screenshotImage,
              let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let prevImage = original.copy() as! NSImage
        undoStack.append(.imageTransform(previousImage: prevImage, annotationOffsets: []))
        redoStack.removeAll()

        let w = cgImage.width, h = cgImage.height
        let cs = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: cgImage.bitsPerComponent,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: cgImage.bitmapInfo.rawValue) else { return }
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
                ann.controlPoint = NSPoint(x: cp.x, y: selectionRect.minY + (selectionRect.maxY - cp.y))
            }
            if let pts = ann.points {
                ann.points = pts.map { NSPoint(x: $0.x, y: selectionRect.minY + (selectionRect.maxY - $0.y)) }
            }
        }

        cachedCompositedImage = nil
        needsDisplay = true
    }

    private func invertImageColors() {
        guard let original = screenshotImage,
              let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

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
    private func collectSnapTargets(excluding: Annotation? = nil) -> (xs: [CGFloat], ys: [CGFloat]) {
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
    private func snapPoint(_ point: NSPoint, excluding: Annotation? = nil) -> NSPoint {
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
        if bestDx > snapThreshold { snapGuideX = nil; result.x = point.x }

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
        if bestDy > snapThreshold { snapGuideY = nil; result.y = point.y }

        return result
    }

    /// Snap a rect (for move operations) — checks all edges and center against targets.
    /// Returns the delta adjustment needed.
    private func snapRectDelta(rect: NSRect, excluding: Annotation? = nil) -> (dx: CGFloat, dy: CGFloat) {
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
        if bestDx > snapThreshold { snapGuideX = nil; snapDx = 0 }

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
        if bestDy > snapThreshold { snapGuideY = nil; snapDy = 0 }

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
              let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        guard let window = window else { return nil }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let viewPoint = convert(windowPoint, from: nil)
        let canvasPoint = viewToCanvas(viewPoint)

        let drawRect = captureDrawRect
        let normX = (canvasPoint.x - drawRect.minX) / drawRect.width
        let normY = (canvasPoint.y - drawRect.minY) / drawRect.height

        let pixelX = Int(normX * CGFloat(cgImage.width))
        let pixelY = Int((1.0 - normY) * CGFloat(cgImage.height))

        guard pixelX >= 0, pixelX < cgImage.width, pixelY >= 0, pixelY < cgImage.height else { return nil }

        let w = cgImage.width, h = cgImage.height
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
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
            return NSPoint(x: drawRect.minX + nx * drawRect.width,
                           y: drawRect.minY + ny * drawRect.height)
        }

        var startPx: Int, endPx: Int

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
            let ann = Annotation(tool: .measure, startPoint: p1, endPoint: p2,
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
            let ann = Annotation(tool: .measure, startPoint: p1, endPoint: p2,
                              color: annotationColor, strokeWidth: currentStrokeWidth)
            ann.measureInPoints = currentMeasureInPoints
            return ann
        }
    }

    // MARK: - Marker Cursor Preview

    private func drawCropPreview() {
        let dimColor = NSColor.black.withAlphaComponent(0.4)
        dimColor.setFill()
        NSBezierPath(rect: NSRect(x: selectionRect.minX, y: cropDragRect.maxY,
                                  width: selectionRect.width, height: selectionRect.maxY - cropDragRect.maxY)).fill()
        NSBezierPath(rect: NSRect(x: selectionRect.minX, y: selectionRect.minY,
                                  width: selectionRect.width, height: cropDragRect.minY - selectionRect.minY)).fill()
        NSBezierPath(rect: NSRect(x: selectionRect.minX, y: cropDragRect.minY,
                                  width: cropDragRect.minX - selectionRect.minX, height: cropDragRect.height)).fill()
        NSBezierPath(rect: NSRect(x: cropDragRect.maxX, y: cropDragRect.minY,
                                  width: selectionRect.maxX - cropDragRect.maxX, height: cropDragRect.height)).fill()
    }

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
        let drawRect = captureDrawRect
        let scaleX = imgSize.width / drawRect.width
        let scaleY = imgSize.height / drawRect.height
        let fromRect = NSRect(x: (srcRect.origin.x - drawRect.origin.x) * scaleX,
                              y: (srcRect.origin.y - drawRect.origin.y) * scaleY,
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
        // Add editor offset
        if isEditorMode {
            q.x += editorCanvasOffset.x
            q.y += editorCanvasOffset.y
        }
        return q
    }

    /// Convert a point in view space to canvas (annotation) space by reversing the zoom transform.
    private func viewToCanvas(_ p: NSPoint) -> NSPoint {
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
        cgCtx.translateBy(x: zoomAnchorView.x - zoomAnchorCanvas.x * zoomLevel,
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
        // In editor mode, zoomAnchorView is in offset-adjusted space (after editorCanvasOffset)
        // because applyZoomTransform runs after the editor translate.
        zoomAnchorCanvas = canvasUnderCursor
        zoomAnchorView = adjustPointForEditor(cursorView)
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
              let croppedCG = cgOriginal.cropping(to: cgPixelRect) else { return }

        // Save state for undo before modifying
        let prevImage = originalImage.copy() as! NSImage
        undoStack.append(.imageTransform(previousImage: prevImage, annotationOffsets: []))
        redoStack.removeAll()

        let dx = selectionRect.minX - canvasRect.minX
        let dy = selectionRect.minY - canvasRect.minY
        for ann in annotations { ann.move(dx: dx, dy: dy) }

        // Set NSImage size in points (not pixels) to preserve Retina scale
        let croppedPointSize = NSSize(width: CGFloat(croppedCG.width) / pixScale,
                                       height: CGFloat(croppedCG.height) / pixScale)
        screenshotImage = NSImage(cgImage: croppedCG, size: croppedPointSize)

        // Update selectionRect to match new image size
        selectionRect = NSRect(origin: .zero, size: croppedPointSize)

        cachedCompositedImage = nil
        editorCanvasOffset = .zero

        // Resize view frame to match new image size (scroll view re-centers automatically)
        if isInsideScrollView {
            frame.size = croppedPointSize
            enclosingScrollView?.magnification = 1.0
            // Update top bar size label
            if let topBar = chromeParentView?.subviews.compactMap({ $0 as? EditorTopBarView }).first {
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
        // In overlay mode at 1x, no clamping needed (image fills the view exactly)
        if zoomLevel == 1.0 && !isEditorMode { return }
        let r = selectionRect
        let z = zoomLevel
        let ac = zoomAnchorCanvas
        var av = zoomAnchorView

        if isEditorMode {
            // Editor: unified clamping for all zoom levels.
            // Keep at least 10% of the image visible on each side.
            let viewW = bounds.width
            let viewH = bounds.height
            let margin: CGFloat = 0.1

            let maxAVx = r.minX - (r.minX - ac.x) * z + viewW * margin
            let minAVx = r.maxX - (r.maxX - ac.x) * z - viewW * margin
            if minAVx < maxAVx { av.x = max(minAVx, min(maxAVx, av.x)) }

            let maxAVy = r.minY - (r.minY - ac.y) * z + viewH * margin
            let minAVy = r.maxY - (r.maxY - ac.y) * z - viewH * margin
            if minAVy < maxAVy { av.y = max(minAVy, min(maxAVy, av.y)) }
        } else if z > 1.0 {
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
            let startRect = NSRect(x: pts.first!.x - s/2, y: pts.first!.y - s/2, width: s, height: s)
            let endRect = NSRect(x: pts.last!.x - s/2, y: pts.last!.y - s/2, width: s, height: s)
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

            // Intermediate anchor handles (use .top, .bottom, .left, .right, etc. as unique handle IDs)
            let anchorHandleIDs: [ResizeHandle] = [.top, .bottom, .left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight]
            if pts.count > 2 {
                for i in 1..<(pts.count - 1) {
                    let handleID = i - 1 < anchorHandleIDs.count ? anchorHandleIDs[i - 1] : .top
                    let midRect = NSRect(x: pts[i].x - sm/2, y: pts[i].y - sm/2, width: sm, height: sm)
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
                let midPt = annotation.controlPoint ?? NSPoint(
                    x: (annotation.startPoint.x + annotation.endPoint.x) / 2,
                    y: (annotation.startPoint.y + annotation.endPoint.y) / 2
                )
                let midRect = NSRect(x: midPt.x - sm/2, y: midPt.y - sm/2, width: sm, height: sm)
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
            let radius = 8 + annotation.strokeWidth * 3
            let circleRect = NSRect(x: annotation.startPoint.x - radius, y: annotation.startPoint.y - radius, width: radius * 2, height: radius * 2)
            baseRect = circleRect.union(NSRect(x: annotation.endPoint.x - 2, y: annotation.endPoint.y - 2, width: 4, height: 4))
        default:
            baseRect = annotation.boundingRect
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
            let iconRect = NSRect(x: rotRect.midX - iconSize / 2, y: rotRect.midY - iconSize / 2,
                                   width: iconSize, height: iconSize)
            let cfg = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .bold)
            if let img = NSImage(systemSymbolName: "arrow.trianglehead.2.clockwise.rotate.90", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let tinted = NSImage(size: img.size, flipped: false) { rect in
                    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                    NSColor.white.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
            }
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
                let tinted = NSImage(size: img.size, flipped: false) { rect in
                    img.draw(in: rect)
                    NSColor.white.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
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
            let drawRect = self.captureDrawRect
            let regionImage = NSImage(size: rect.size, flipped: false) { _ in
                screenshot.draw(in: NSRect(x: -rect.origin.x, y: -rect.origin.y,
                                           width: drawRect.width, height: drawRect.height),
                                from: .zero, operation: .copy, fraction: 1.0)
                return true
            }

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

    // MARK: - Recording Overlays (Mouse Highlight + Keystrokes)

    private func drawMouseHighlights() {
        let now = Date()

        for entry in mouseHighlightPoints {
            let age = now.timeIntervalSince(entry.time)
            guard age <= 0.3 else { continue }
            let alpha = max(0, 1.0 - age / 0.3)
            let radius: CGFloat = 18 + CGFloat(age) * 60  // expands outward faster
            let rect = NSRect(x: entry.point.x - radius, y: entry.point.y - radius, width: radius * 2, height: radius * 2)
            NSColor.systemYellow.withAlphaComponent(0.35 * alpha).setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.systemYellow.withAlphaComponent(0.6 * alpha).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 2
            ring.stroke()
        }

        if !mouseHighlightPoints.isEmpty {
            // Prune expired highlights and schedule redraw outside of draw()
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.mouseHighlightPoints.removeAll { now.timeIntervalSince($0.time) > 0.3 }
                self.needsDisplay = true
                self.displayIfNeeded()
            }
        }
    }

    func startMouseHighlightMonitor() {
        guard globalMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return }
            // Convert screen point to view coordinates
            // For global monitors, event.locationInWindow is in screen coordinates
            guard let window = self.window else { return }
            let windowPoint = window.convertPoint(fromScreen: event.locationInWindow)
            let viewPoint = self.convert(windowPoint, from: nil)
            DispatchQueue.main.async {
                self.mouseHighlightPoints.append((point: viewPoint, time: Date()))
                self.needsDisplay = true
                self.displayIfNeeded()
            }
        }
    }

    func stopMouseHighlightMonitor() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        mouseHighlightPoints.removeAll()
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

    /// Rebuild toolbar button content. Call when tool, color, or state changes — NOT on every draw.
    func rebuildToolbarLayout() {
        let movableAnnotations = annotations.contains { $0.isMovable }
        bottomButtons = ToolbarLayout.bottomButtons(selectedTool: currentTool, selectedColor: currentColor, beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex, hasAnnotations: movableAnnotations, isRecording: isRecording, isAnnotating: isAnnotating)
        if showBeautifyInOptionsRow {
            for i in bottomButtons.indices {
                if case .tool = bottomButtons[i].action { bottomButtons[i].isSelected = false }
                else if case .beautify = bottomButtons[i].action { bottomButtons[i].isSelected = true }
            }
        }
        rightButtons = ToolbarLayout.rightButtons(beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex, hasAnnotations: movableAnnotations, translateEnabled: translateEnabled, isRecording: isRecording, isCapturingVideo: isCapturingVideo, isAnnotating: isAnnotating, isEditorMode: isEditorMode)

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
        rightStripView?.setButtons(rightButtons)
        rightStripView?.onClick = { [weak self] action in self?.handleToolbarAction(action) }
        rightStripView?.onRightClick = { [weak self] action, view in
            self?.handleToolbarButtonRightClick(action, anchorView: view)
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
    }

    /// Reposition toolbar strips based on current selection/bounds. Cheap — safe to call from draw().
    private func repositionToolbars() {
        guard let bottomStrip = bottomStripView, let rightStrip = rightStripView else { return }

        let visible = showToolbars && state == .selected && !isScrollCapturing
        bottomStrip.isHidden = !visible
        rightStrip.isHidden = !visible
        toolOptionsRowView?.isHidden = !visible || !toolHasOptionsRow
        guard visible else { return }

        // Anchor rect: beautify-expanded when active, selection otherwise
        let config = beautifyConfig
        let bPad = config.padding
        let titleBarH: CGFloat = config.mode == .window ? 28 : 0
        let expandedAnchor = NSRect(
            x: selectionRect.minX - bPad, y: selectionRect.minY - bPad,
            width: selectionRect.width + bPad * 2, height: selectionRect.height + titleBarH + bPad * 2)
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
            rightStrip.frame.origin = NSPoint(x: cb.maxX - rightSize.width - 6, y: cb.maxY - rightSize.height - 36)
            rightStrip.autoresizingMask = [.minXMargin, .minYMargin]
        } else {
            var bx = anchorRect.midX - bottomSize.width / 2
            var by = anchorRect.minY - bottomSize.height - 6
            if by < bounds.minY + 4 { by = anchorRect.maxY + 6 }
            bx = max(bounds.minX + 4, min(bx, bounds.maxX - bottomSize.width - 4))
            bottomStrip.frame.origin = NSPoint(x: bx, y: by)

            // Right: to the right of selection, flip to left if no room
            var rx = anchorRect.maxX + 6
            if rx + rightSize.width > bounds.maxX - 4 {
                rx = anchorRect.minX - rightSize.width - 6
            }
            rx = max(bounds.minX + 4, min(rx, bounds.maxX - rightSize.width - 4))

            // Top-align with selection top
            var ry = anchorRect.maxY - rightSize.height
            ry = max(bounds.minY + 4, min(ry, bounds.maxY - rightSize.height - 4))

            // Avoid overlapping bottom bar — shift right bar horizontally if needed
            let bf = bottomStrip.frame
            if bf.width > 0 {
                let rightRect = NSRect(x: rx, y: ry, width: rightSize.width, height: rightSize.height)
                if rightRect.intersects(bf) {
                    // Move right bar to the right of the bottom bar
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

        // Note: toolbar strips and options row are routed by hitTest() — they never reach here

        // Control-click = right-click for color sampler (supports BetterTouchTool and other tools
        // that simulate right-click via control-click instead of rightMouseDown)
        if event.modifierFlags.contains(.control) && state == .selected && currentTool == .colorSampler {
            if let screenshot = screenshotImage,
               let result = sampleColor(from: screenshot, at: viewToCanvas(point)) {
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
               (ann.tool == .arrow || ann.tool == .line || ann.tool == .measure) {
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

        // Editor top bar button clicks
        if handleTopChromeClick(at: point) {
            return
        }

        let isTextEditing = textEditView != nil




        // Check text box resize handles when editing
        if isTextEditing && showToolbars {
            // Check text box resize handles
            if let sv = textScrollView {
                let hs: CGFloat = 10  // hit area
                let f = sv.frame
                let handles: [(ResizeHandle, NSRect)] = [
                    (.bottomLeft,  NSRect(x: f.minX - hs/2, y: f.minY - hs/2, width: hs, height: hs)),
                    (.bottomRight, NSRect(x: f.maxX - hs/2, y: f.minY - hs/2, width: hs, height: hs)),
                    (.topLeft,     NSRect(x: f.minX - hs/2, y: f.maxY - hs/2, width: hs, height: hs)),
                    (.topRight,    NSRect(x: f.maxX - hs/2, y: f.maxY - hs/2, width: hs, height: hs)),
                    (.bottom,      NSRect(x: f.midX - hs/2, y: f.minY - hs/2, width: hs, height: hs)),
                    (.top,         NSRect(x: f.midX - hs/2, y: f.maxY - hs/2, width: hs, height: hs)),
                    (.left,        NSRect(x: f.minX - hs/2, y: f.midY - hs/2, width: hs, height: hs)),
                    (.right,       NSRect(x: f.maxX - hs/2, y: f.midY - hs/2, width: hs, height: hs)),
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
            if let sv = textScrollView, sv.frame.contains(point) {
                return
            }
        }

        // Don't commit text if clicking on text formatting controls in the options row
        let isTextFormattingClick = textEditView != nil && currentTool == .text &&
            ((toolOptionsRowView?.frame.contains(point) ?? false) || (showFontPicker && fontPickerRect.contains(point)))
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
                // Font picker dropdown click handling
                if showFontPicker {
                    if fontPickerRect.contains(point) {
                        for (i, itemRect) in fontPickerItemRects.enumerated() {
                            if itemRect.contains(point) {
                                let family = OverlayView.fontFamilies[i]
                                textFontFamily = family
                                UserDefaults.standard.set(family, forKey: "textFontFamily")
                                applyFontFamilyToSelection(family)
                                showFontPicker = false
                                if let tv = textEditView {
                                    window?.makeFirstResponder(tv)
                                }
                                needsDisplay = true
                                return
                            }
                        }
                        return  // clicked in picker but not on an item
                    } else {
                        // Clicking the dropdown button again should just close the picker
                        showFontPicker = false
                        needsDisplay = true
                        if textFontDropdownRect.contains(point) {
                            return  // consumed — don't let the toggle re-open it
                        }
                        // fall through to handle click normally
                    }
                }


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
            let origin = NSPoint(x: min(cropDragStart.x, clampedPoint.x), y: min(cropDragStart.y, clampedPoint.y))
            cropDragRect = NSRect(origin: origin,
                                  size: NSSize(width: abs(clampedPoint.x - cropDragStart.x),
                                               height: abs(clampedPoint.y - cropDragStart.y)))
            needsDisplay = true
            return
        }

        // Handle text box resize
        if isResizingTextBox, let sv = textScrollView, let tv = textEditView {
            let dx = point.x - textBoxResizeStart.x
            let dy = point.y - textBoxResizeStart.y
            let orig = textBoxOrigFrame
            var newFrame = orig
            let minW: CGFloat = 60
            let minH: CGFloat = max(28, textFontSize + 12)

            switch textBoxResizeHandle {
            case .right:       newFrame.size.width = max(minW, orig.width + dx)
            case .left:        newFrame.origin.x = min(orig.maxX - minW, orig.minX + dx); newFrame.size.width = orig.maxX - newFrame.minX
            case .top:         newFrame.size.height = max(minH, orig.height + dy)
            case .bottom:      let newMinY = min(orig.maxY - minH, orig.minY + dy); newFrame.origin.y = newMinY; newFrame.size.height = orig.maxY - newMinY
            case .topRight:    newFrame.size.width = max(minW, orig.width + dx); newFrame.size.height = max(minH, orig.height + dy)
            case .topLeft:     newFrame.origin.x = min(orig.maxX - minW, orig.minX + dx); newFrame.size.width = orig.maxX - newFrame.minX; newFrame.size.height = max(minH, orig.height + dy)
            case .bottomRight: newFrame.size.width = max(minW, orig.width + dx); let newMinY = min(orig.maxY - minH, orig.minY + dy); newFrame.origin.y = newMinY; newFrame.size.height = orig.maxY - newMinY
            case .bottomLeft:  newFrame.origin.x = min(orig.maxX - minW, orig.minX + dx); newFrame.size.width = orig.maxX - newFrame.minX; let newMinY = min(orig.maxY - minH, orig.minY + dy); newFrame.origin.y = newMinY; newFrame.size.height = orig.maxY - newMinY
            default: break
            }

            sv.frame = newFrame
            tv.frame.size = newFrame.size
            tv.textContainer?.containerSize = NSSize(width: newFrame.width - tv.textContainerInset.width * 2, height: CGFloat.greatestFiniteMagnitude)
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
                let center = NSPoint(x: annotation.boundingRect.midX, y: annotation.boundingRect.midY)
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
                if annotation.tool == .arrow || annotation.tool == .line || annotation.tool == .measure {
                    let newPt = NSPoint(x: annotationResizeOrigControlPoint.x + dx, y: annotationResizeOrigControlPoint.y + dy)
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
                            newStart = NSPoint(x: anchor.x + dist * cos(snapped), y: anchor.y + dist * sin(snapped))
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
                            newEnd = NSPoint(x: anchor.x + dist * cos(snapped), y: anchor.y + dist * sin(snapped))
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
                annotation.endPoint   = NSPoint(x: newMaxX, y: newMaxY)
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
                annotationDragStart = NSPoint(x: canvasPoint.x + snap.dx, y: canvasPoint.y + snap.dy)
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
                        currentAnnotation!.points = points.map { NSPoint(x: $0.x + dx, y: $0.y + dy) }
                    }
                    spaceRepositionLast = canvasPoint
                } else {
                    updateAnnotation(at: canvasPoint, shiftHeld: event.modifierFlags.contains(.shift))
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
                moveMode = false
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
               (ann.tool == .arrow || ann.tool == .line || ann.tool == .measure) {
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
               let result = sampleColor(from: screenshot, at: viewToCanvas(point)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.hex, forType: .string)
                showOverlayError("Copied \(result.hex)")
                needsDisplay = true
            }
            return
        }

        if state == .selected && pointIsInSelection(point) {
            // Show radial color wheel
            showColorWheel = true
            colorWheelCenter = point
            colorWheelHoveredIndex = -1
            needsDisplay = true
            return
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if showColorWheel {
            let point = convert(event.locationInWindow, from: nil)
            colorWheelHoveredIndex = colorWheelIndexAt(point)
            needsDisplay = true
            return
        }
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
                if let topBar = sv.superview?.subviews.compactMap({ $0 as? EditorTopBarView }).first {
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
            let imageExceedsView = canPanAtOneX() || (isEditorMode && (selectionRect.height > bounds.height || selectionRect.width > bounds.width))
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
        if isInsideScrollView { enclosingScrollView?.magnify(with: event); return }
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

    /// Handle right-click on a toolbar button (context menus, popovers).
    private func handleToolbarButtonRightClick(_ action: ToolbarButtonAction, anchorView: NSView) {
        switch action {
        case .autoRedact:
            PopoverHelper.dismiss()
            showRedactTypePopover(anchorRect: anchorView.convert(anchorView.bounds, to: self), anchorView: anchorView)
        case .save:
            let menu = NSMenu()
            let saveAsItem = NSMenuItem(title: "Save As...", action: #selector(saveAsMenuAction), keyEquivalent: "")
            saveAsItem.target = self
            menu.addItem(saveAsItem)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height), in: anchorView)
        case .upload:
            PopoverHelper.dismiss()
            showUploadConfirmPopover(anchorRect: anchorView.convert(anchorView.bounds, to: self), anchorView: anchorView)
        case .translate:
            PopoverHelper.dismiss()
            showTranslatePopover(anchorRect: anchorView.convert(anchorView.bounds, to: self), anchorView: anchorView)
        default:
            break
        }
    }

    func handleToolbarAction(_ action: ToolbarButtonAction, mousePoint: NSPoint = .zero) {
        // When recording but not in annotation mode, only allow recording-control actions
        if isRecording && !isAnnotating {
            switch action {
            case .annotationMode, .startRecord, .stopRecord, .mouseHighlight, .systemAudio, .micAudio:
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
            showFontPicker = false
            currentTool = tool
            // Auto-select first emoji when switching to stamp tool with nothing selected
            if tool == .stamp && currentStampImage == nil {
                currentStampImage = renderEmoji(Self.commonEmojis[0])
                currentStampEmoji = Self.commonEmojis[0]
            }
            needsDisplay = true
        case .loupe:
            currentTool = .loupe
            needsDisplay = true
        case .color:
            showSystemColorPicker(target: .drawColor)
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
                if alert.runModal() == .alertFirstButtonReturn {
                    overlayDelegate?.overlayViewDidRequestUpload()
                }
            } else {
                overlayDelegate?.overlayViewDidRequestUpload()
            }
        case .share:
            overlayDelegate?.overlayViewDidRequestShare()
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
            showFontPicker = false
            stampPreviewPoint = nil
            loupeCursorPoint = .zero
            // Auto-enable beautify on first click in this session
            if !beautifyEnabled {
                beautifyEnabled = true
                UserDefaults.standard.set(true, forKey: "beautifyEnabled")
                startBeautifyToolbarAnimation()
            }
            showBeautifyInOptionsRow.toggle()
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
            if UserDefaults.standard.bool(forKey: "recordMouseHighlight") { startMouseHighlightMonitor() }
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

        // Color sampler: click sets the current drawing color, no annotation created.
        // Note: point is already in canvas space (converted by caller).
        if currentTool == .colorSampler {
            if let screenshot = screenshotImage,
               let result = sampleColor(from: screenshot, at: point) {
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
                    let frame = selected.textDrawRect
                    // Restore formatting state from the annotation
                    textFontSize = selected.fontSize
                    textBold = selected.isBold
                    textItalic = selected.isItalic
                    textUnderline = selected.isUnderline
                    textStrikethrough = selected.isStrikethrough
                    textFontFamily = selected.fontFamilyName ?? "System"
                    if let idx = annotations.firstIndex(where: { $0 === selected }) {
                        annotations.remove(at: idx)
                        selectedAnnotation = nil
                    }
                    showTextField(at: frame.origin, existingText: selected.attributedText, existingFrame: frame)
                    needsDisplay = true
                    return
                }
                // Rotation handle
                if annotationRotateHandleRect != .zero && annotationRotateHandleRect.insetBy(dx: -6, dy: -6).contains(point) {
                    isRotatingAnnotation = true
                    let center = NSPoint(x: selected.boundingRect.midX, y: selected.boundingRect.midY)
                    rotationStartAngle = atan2(point.x - center.x, point.y - center.y)
                    rotationOriginal = selected.rotation
                    return
                }
                // Resize handles — unrotate point into annotation's local space
                let handleTestPoint: NSPoint
                if selected.rotation != 0 && selected.supportsRotation {
                    let center = NSPoint(x: selected.boundingRect.midX, y: selected.boundingRect.midY)
                    let cos_r = cos(-selected.rotation)
                    let sin_r = sin(-selected.rotation)
                    let dx = point.x - center.x
                    let dy = point.y - center.y
                    handleTestPoint = NSPoint(x: center.x + dx * cos_r - dy * sin_r,
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
                        } else if handle != .bottomLeft && handle != .topRight {
                            // Legacy single controlPoint
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
            // Unrotate point for resize handle hit test
            let hoverHandlePoint: NSPoint
            if hovered.rotation != 0 && hovered.supportsRotation {
                let center = NSPoint(x: hovered.boundingRect.midX, y: hovered.boundingRect.midY)
                let cos_r = cos(-hovered.rotation)
                let sin_r = sin(-hovered.rotation)
                let dx = point.x - center.x
                let dy = point.y - center.y
                hoverHandlePoint = NSPoint(x: center.x + dx * cos_r - dy * sin_r,
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
                    // Capture anchor index for multi-anchor drag
                    annotationResizeAnchorIndex = -1
                    if let anchors = hovered.anchorPoints, anchors.count >= 3, handleIdx >= 2 {
                        let anchorIdx = handleIdx - 2 + 1
                        if anchorIdx > 0 && anchorIdx < anchors.count - 1 {
                            annotationResizeAnchorIndex = anchorIdx
                            annotationResizeOrigControlPoint = anchors[anchorIdx]
                        }
                    } else if handle != .bottomLeft && handle != .topRight {
                        annotationResizeOrigControlPoint = hovered.controlPoint ?? NSPoint(
                            x: (hovered.startPoint.x + hovered.endPoint.x) / 2,
                            y: (hovered.startPoint.y + hovered.endPoint.y) / 2
                        )
                    }
                    needsDisplay = true
                    return
                }
            }
            // Check rotation handle
            if annotationRotateHandleRect != .zero && annotationRotateHandleRect.insetBy(dx: -6, dy: -6).contains(point) {
                selectedAnnotation = hovered
                isRotatingAnnotation = true
                let center = NSPoint(x: hovered.boundingRect.midX, y: hovered.boundingRect.midY)
                rotationStartAngle = atan2(point.x - center.x, point.y - center.y)
                rotationOriginal = hovered.rotation
                needsDisplay = true
                return
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
            loupeAnnotation.sourceImage = screenshotImage
            loupeAnnotation.sourceImageBounds = captureDrawRect
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
            // Check if clicking on an existing text annotation → re-edit it
            // Note: point is already in canvas space (converted by caller).
            if let existingAnn = annotations.reversed().first(where: { $0.tool == .text && $0.hitTest(point: point) }) {
                // Remove from annotations (will be re-added on commit)
                if let idx = annotations.firstIndex(where: { $0 === existingAnn }) {
                    annotations.remove(at: idx)
                }
                editingAnnotation = existingAnn
                // Restore text formatting state
                textFontSize = existingAnn.fontSize
                textBold = existingAnn.isBold
                textItalic = existingAnn.isItalic
                textUnderline = existingAnn.isUnderline
                textStrikethrough = existingAnn.isStrikethrough
                textFontFamily = existingAnn.fontFamilyName ?? "System"
                textAlignment = existingAnn.textAlignment
                textBgEnabled = existingAnn.textBgColor != nil
                if let bg = existingAnn.textBgColor { textBgColorValue = bg }
                textOutlineEnabled = existingAnn.textOutlineColor != nil
                if let ol = existingAnn.textOutlineColor { textOutlineColorValue = ol }
                showTextField(at: existingAnn.textDrawRect.origin,
                              existingText: existingAnn.attributedText,
                              existingFrame: existingAnn.textDrawRect)
            } else {
                showTextField(at: point)
            }
            return
        case .number:
            numberCounter += 1
            let annotation = Annotation(tool: .number, startPoint: point, endPoint: point, color: opacityApplied(for: .number), strokeWidth: currentNumberSize)
            annotation.number = numberCounter + (numberStartAt - 1)
            annotation.numberFormat = currentNumberFormat
            currentAnnotation = annotation
            needsDisplay = true
            return
        case .stamp:
            // Auto-select first emoji if nothing selected
            if currentStampImage == nil {
                currentStampImage = renderEmoji(Self.commonEmojis[0])
                currentStampEmoji = Self.commonEmojis[0]
            }
            guard let img = currentStampImage else { return }
            let stampSize: CGFloat = 64
            let aspect = img.size.width / max(img.size.height, 1)
            let w = aspect >= 1 ? stampSize : stampSize * aspect
            let h = aspect >= 1 ? stampSize / aspect : stampSize
            let annotation = Annotation(tool: .stamp, startPoint: NSPoint(x: point.x - w / 2, y: point.y - h / 2),
                                        endPoint: NSPoint(x: point.x + w / 2, y: point.y + h / 2),
                                        color: .clear, strokeWidth: 0)
            annotation.stampImage = img
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
            annotation.sourceImageBounds = captureDrawRect
        }
        if currentTool == .rectangle {
            annotation.rectCornerRadius = currentRectCornerRadius
        }
        if currentTool == .rectangle || currentTool == .ellipse {
            annotation.rectFillStyle = currentRectFillStyle
        }
        if [.pencil, .line, .arrow, .rectangle, .ellipse].contains(currentTool) {
            annotation.lineStyle = currentLineStyle
        }
        if currentTool == .arrow {
            annotation.arrowStyle = currentArrowStyle
        }
        if currentTool == .measure {
            annotation.measureInPoints = currentMeasureInPoints
        }
        currentAnnotation = annotation
    }

    private func updateAnnotation(at point: NSPoint, shiftHeld: Bool = false) {
        guard let annotation = currentAnnotation else { return }
        var clampedPoint = point

        if shiftHeld {
            // For freeform tools (marker, pencil), snap relative to the last point
            // so each segment constrains independently. For other tools, snap from start.
            let refPoint: NSPoint
            if (annotation.tool == .marker || annotation.tool == .pencil),
               let lastPt = annotation.points?.last {
                refPoint = lastPt
            } else {
                refPoint = annotation.startPoint
            }
            let dx = clampedPoint.x - refPoint.x
            let dy = clampedPoint.y - refPoint.y

            switch annotation.tool {
            case .marker, .pencil:
                // Freeform: snap to horizontal or vertical, locked once decided
                if freeformShiftDirection == 0 && hypot(dx, dy) > 5 {
                    freeformShiftDirection = abs(dx) >= abs(dy) ? 1 : 2
                }
                if freeformShiftDirection == 1 {
                    clampedPoint = NSPoint(x: clampedPoint.x, y: annotation.startPoint.y)
                } else if freeformShiftDirection == 2 {
                    clampedPoint = NSPoint(x: annotation.startPoint.x, y: clampedPoint.y)
                } else {
                    // Not decided yet — lock to start point
                    clampedPoint = annotation.startPoint
                }
            case .line, .arrow, .measure, .loupe:
                // Snap to nearest 45° angle
                let angle = atan2(dy, dx)
                let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
                let distance = hypot(dx, dy)
                clampedPoint = NSPoint(
                    x: refPoint.x + distance * cos(snapped),
                    y: refPoint.y + distance * sin(snapped)
                )
            case .rectangle, .ellipse, .pixelate, .blur:
                // Constrain to square/circle: use the larger dimension
                let side = max(abs(dx), abs(dy))
                clampedPoint = NSPoint(
                    x: refPoint.x + side * (dx >= 0 ? 1 : -1),
                    y: refPoint.y + side * (dy >= 0 ? 1 : -1)
                )
            default:
                break
            }
        }

        // Apply snap guides for non-freeform tools (skip when shift-constraining)
        if !shiftHeld && annotation.tool != .pencil && annotation.tool != .marker {
            clampedPoint = snapPoint(clampedPoint, excluding: annotation)
        } else {
            snapGuideX = nil
            snapGuideY = nil
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
        } else if annotation.tool == .number || dx > 2 || dy > 2 {
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
        freeformShiftDirection = 0
        snapGuideX = nil
        snapGuideY = nil
        needsDisplay = true
    }

    // MARK: - Text Field

    private func showTextField(at point: NSPoint, existingText: NSAttributedString? = nil, existingFrame: NSRect = .zero) {
        let height = max(28, textFontSize + 12)
        let defaultW: CGFloat = 200
        // point is in canvas space — convert to view space for NSView positioning
        let viewPt = canvasToView(point)
        let svFrame: NSRect
        if existingFrame != .zero {
            let viewOrigin = canvasToView(existingFrame.origin)
            svFrame = NSRect(origin: viewOrigin, size: existingFrame.size)
        } else {
            svFrame = NSRect(x: viewPt.x, y: viewPt.y - height, width: defaultW, height: height)
        }
        let scrollView = NSScrollView(frame: svFrame)
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: svFrame.width, height: svFrame.height))
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = true
        tv.allowsUndo = true
        tv.backgroundColor = .clear
        tv.isFieldEditor = false
        tv.textColor = currentColor
        tv.insertionPointColor = currentColor
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: svFrame.width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.delegate = self
        tv.alignment = textAlignment

        let font = currentTextFont()
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.alignment = textAlignment
        tv.typingAttributes = [
            .font: font,
            .foregroundColor: currentColor,
            .paragraphStyle: paraStyle,
        ]

        scrollView.documentView = tv
        addSubview(scrollView)
        textScrollView = scrollView
        textEditView = tv

        if let existing = existingText {
            tv.textStorage?.setAttributedString(existing)
            resizeTextViewToFit()
        }

        window?.makeFirstResponder(tv)
        needsDisplay = true

    }

    private func currentTextFont() -> NSFont {
        let fm = NSFontManager.shared
        let baseFont: NSFont
        if textFontFamily == "System" {
            baseFont = NSFont.systemFont(ofSize: textFontSize, weight: textBold ? .bold : .regular)
        } else if let font = NSFont(name: textFontFamily, size: textFontSize) {
            baseFont = textBold ? fm.convert(font, toHaveTrait: .boldFontMask) : font
        } else {
            baseFont = NSFont.systemFont(ofSize: textFontSize, weight: textBold ? .bold : .regular)
        }
        if textItalic {
            return fm.convert(baseFont, toHaveTrait: .italicFontMask)
        }
        return baseFont
    }

    private func selectedOrAllRange() -> NSRange {
        guard let tv = textEditView else { return NSRange(location: 0, length: 0) }
        let sel = tv.selectedRange()
        if sel.length > 0 { return sel }
        return NSRange(location: 0, length: tv.textStorage?.length ?? 0)
    }

    func toggleTextBold() {
        guard let tv = textEditView, let ts = tv.textStorage else {
            textBold.toggle(); needsDisplay = true; return
        }
        textBold.toggle()
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.font, in: range) { value, attrRange, _ in
                if let font = value as? NSFont {
                    let newFont = self.applyBoldItalic(to: font, bold: self.textBold, italic: self.textItalic)
                    ts.addAttribute(.font, value: newFont, range: attrRange)
                }
            }
            ts.endEditing()
        }
        tv.typingAttributes[.font] = currentTextFont()
        window?.makeFirstResponder(tv)
        needsDisplay = true
    }

    func toggleTextItalic() {
        guard let tv = textEditView, let ts = tv.textStorage else {
            textItalic.toggle(); needsDisplay = true; return
        }
        textItalic.toggle()
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.font, in: range) { value, attrRange, _ in
                if let font = value as? NSFont {
                    let newFont = self.applyBoldItalic(to: font, bold: self.textBold, italic: self.textItalic)
                    ts.addAttribute(.font, value: newFont, range: attrRange)
                }
            }
            ts.endEditing()
        }
        tv.typingAttributes[.font] = currentTextFont()
        window?.makeFirstResponder(tv)
        needsDisplay = true
    }

    /// Apply bold/italic to a font, handling system fonts that NSFontManager can't convert via traits.
    private func applyBoldItalic(to font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        let size = font.pointSize
        let familyName = font.familyName ?? "System"

        // System font: use NSFont.systemFont directly (NSFontManager can't convert SF traits)
        if familyName.hasPrefix(".") || familyName == "System" || textFontFamily == "System" {
            var base: NSFont
            if bold && italic {
                base = NSFont.systemFont(ofSize: size, weight: .bold)
                // System italic via font descriptor
                let desc = base.fontDescriptor.withSymbolicTraits(.italic)
                base = NSFont(descriptor: desc, size: size) ?? base
            } else if bold {
                base = NSFont.systemFont(ofSize: size, weight: .bold)
            } else if italic {
                let regular = NSFont.systemFont(ofSize: size, weight: .regular)
                let desc = regular.fontDescriptor.withSymbolicTraits(.italic)
                base = NSFont(descriptor: desc, size: size) ?? regular
            } else {
                base = NSFont.systemFont(ofSize: size, weight: .regular)
            }
            return base
        }

        // Non-system fonts: use NSFontManager trait conversion
        let fm = NSFontManager.shared
        var result = font
        if bold {
            result = fm.convert(result, toHaveTrait: .boldFontMask)
        } else {
            result = fm.convert(result, toNotHaveTrait: .boldFontMask)
        }
        if italic {
            result = fm.convert(result, toHaveTrait: .italicFontMask)
        } else {
            result = fm.convert(result, toNotHaveTrait: .italicFontMask)
        }
        return result
    }

    func toggleTextUnderline() {
        guard let tv = textEditView, let ts = tv.textStorage else {
            textUnderline.toggle(); needsDisplay = true; return
        }
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
        if textUnderline {
            tv.typingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else {
            tv.typingAttributes.removeValue(forKey: .underlineStyle)
        }
        window?.makeFirstResponder(tv)
        needsDisplay = true
    }

    func toggleTextStrikethrough() {
        guard let tv = textEditView, let ts = tv.textStorage else {
            textStrikethrough.toggle(); needsDisplay = true; return
        }
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
        if textStrikethrough {
            tv.typingAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        } else {
            tv.typingAttributes.removeValue(forKey: .strikethroughStyle)
        }
        window?.makeFirstResponder(tv)
        needsDisplay = true
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

    private func applyFontFamilyToSelection(_ family: String) {
        guard let tv = textEditView, let ts = tv.textStorage else { return }
        let fm = NSFontManager.shared
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.font, in: range) { value, attrRange, _ in
                if let font = value as? NSFont {
                    let newFont: NSFont
                    if family == "System" {
                        newFont = NSFont.systemFont(ofSize: font.pointSize, weight: fm.traits(of: font).contains(.boldFontMask) ? .bold : .regular)
                    } else {
                        newFont = fm.convert(font, toFamily: family)
                    }
                    ts.addAttribute(.font, value: newFont, range: attrRange)
                }
            }
            ts.endEditing()
        }
        tv.typingAttributes[.font] = currentTextFont()
        resizeTextViewToFit()
        window?.makeFirstResponder(tv)
    }

    func applyAlignmentToTextIfEditing() {
        guard let tv = textEditView, let ts = tv.textStorage else { return }
        let range = NSRange(location: 0, length: ts.length)
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.alignment = textAlignment
        ts.beginEditing()
        ts.addAttribute(.paragraphStyle, value: paraStyle, range: range)
        ts.endEditing()
        tv.alignment = textAlignment
        tv.typingAttributes[.paragraphStyle] = paraStyle
        window?.makeFirstResponder(tv)
    }

    func cancelTextEditing() {
        // If re-editing, restore the original annotation
        if let ann = editingAnnotation {
            annotations.append(ann)
            editingAnnotation = nil
        }
        textScrollView?.removeFromSuperview()
        textScrollView = nil
        textEditView = nil
        showFontPicker = false
        window?.makeFirstResponder(self)

        needsDisplay = true
    }

    func commitTextFieldIfNeeded() {
        guard let tv = textEditView, let sv = textScrollView else { return }
        let text = tv.string
        if !text.isEmpty {
            // Render the attributed string into an NSImage using its own layout engine.
            // NSImage(size:flipped:true) gives a flipped context matching NSTextView, so
            // draw(in:) lands correctly with no coordinate math.
            let attrStr = NSAttributedString(attributedString: tv.textStorage!)
            let imgSize = sv.frame.size
            let inset = tv.textContainerInset
            let img = NSImage(size: imgSize, flipped: true) { _ in
                attrStr.draw(in: NSRect(x: inset.width, y: inset.height,
                                         width: imgSize.width - inset.width * 2,
                                         height: imgSize.height - inset.height * 2))
                return true
            }

            // Convert view-space frame to canvas-space for annotation positioning
            let canvasOrigin = viewToCanvas(sv.frame.origin)
            let canvasEnd = viewToCanvas(NSPoint(x: sv.frame.maxX, y: sv.frame.maxY))
            let canvasFrame = NSRect(x: canvasOrigin.x, y: canvasOrigin.y,
                                     width: canvasEnd.x - canvasOrigin.x,
                                     height: canvasEnd.y - canvasOrigin.y)

            let annotation = Annotation(tool: .text,
                                        startPoint: canvasFrame.origin,
                                        endPoint: NSPoint(x: canvasFrame.maxX, y: canvasFrame.maxY),
                                        color: opacityApplied(for: .text),
                                        strokeWidth: currentStrokeWidth)
            annotation.attributedText = attrStr
            annotation.text = text
            annotation.fontSize = textFontSize
            annotation.isBold = textBold
            annotation.isItalic = textItalic
            annotation.isUnderline = textUnderline
            annotation.isStrikethrough = textStrikethrough
            annotation.fontFamilyName = textFontFamily == "System" ? nil : textFontFamily
            annotation.textBgColor = textBgEnabled ? textBgColorValue : nil
            annotation.textOutlineColor = textOutlineEnabled ? textOutlineColorValue : nil
            annotation.textAlignment = textAlignment
            annotation.textImage = img
            annotation.textDrawRect = canvasFrame
            annotations.append(annotation)
            undoStack.append(.added(annotation))
            redoStack.removeAll()
        }
        editingAnnotation = nil
        sv.removeFromSuperview()
        textScrollView = nil
        textEditView = nil
        showFontPicker = false
        window?.makeFirstResponder(self)

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
        alert.informativeText = "macshot needs microphone permission to record voice audio. Open System Settings to grant access."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
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
            let d = distanceToSegment(point: canvasPoint, from: pts[i-1], to: pts[i])
            if d < bestDist {
                bestDist = d
                bestIdx = i
            }
        }

        // Project the point onto the segment for exact placement
        let a = pts[bestIdx - 1]
        let b = pts[bestIdx]
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        let t: CGFloat = lenSq < 0.001 ? 0.5 : max(0.05, min(0.95, ((canvasPoint.x - a.x) * dx + (canvasPoint.y - a.y) * dy) / lenSq))
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
        let dx = b.x - a.x, dy = b.y - a.y
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
        currentStampImage = renderEmoji(str)
        currentStampEmoji = str
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Forward Cmd shortcuts to the text view when editing — the main menu
        // intercepts these before keyDown reaches the overlay window.
        if let tv = textEditView, event.modifierFlags.contains(.command),
           let char = event.charactersIgnoringModifiers {
            switch char {
            case "v": tv.paste(nil); return true
            case "c": tv.copy(nil); return true
            case "x": tv.cut(nil); return true
            case "a": tv.selectAll(nil); return true
            case "z":
                if event.modifierFlags.contains(.shift) {
                    tv.undoManager?.redo()
                } else {
                    tv.undoManager?.undo()
                }
                return true
            default: break
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
                let isDraggingAnnotation = currentAnnotation != nil && currentAnnotation!.tool != .pencil && currentAnnotation!.tool != .marker
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
        case 53: // Escape
            if isScrollCapturing {
                overlayDelegate?.overlayViewDidRequestStopScrollCapture()
                return
            }
            // Block ESC only when actually capturing video; allow cancel
            // when recording mode is entered but capture hasn't started yet.
            guard !isCapturingVideo else { return }
            if textEditView != nil {
                textScrollView?.removeFromSuperview()
                textScrollView = nil
                textEditView = nil
                showFontPicker = false
                window?.makeFirstResponder(self)
        
                needsDisplay = true
            } else if PopoverHelper.isVisible {
                PopoverHelper.dismiss()
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
        case 36: // Return/Enter — only confirm overlay when not editing text
            if textEditView == nil, state == .selected {
                let saveMode = !(UserDefaults.standard.object(forKey: "quickModeCopyToClipboard") as? Bool ?? false)
                if saveMode {
                    overlayDelegate?.overlayViewDidRequestQuickSave()
                } else {
                    overlayDelegate?.overlayViewDidConfirm()
                }
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
            // Auto-measure: hold "1" = vertical preview, hold "2" = horizontal preview
            if state == .selected && currentTool == .measure && textEditView == nil &&
               !event.modifierFlags.contains(.command) {
                if let char = event.charactersIgnoringModifiers {
                    if char == "1" || char == "2" {
                        autoMeasureVertical = (char == "1")
                        updateAutoMeasurePreview()
                        return
                    }
                }
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
                    case "g": handleToolbarAction(.tool(.stamp)); return
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
                    case "a": tv.selectAll(nil); return
                    case "c": tv.copy(nil); return
                    case "v": tv.paste(nil); return
                    case "x": tv.cut(nil); return
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
                editorCanvasOffset = .zero  // force recalculation
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
                editorCanvasOffset = .zero
            }
            cachedCompositedImage = nil
            resetZoom()
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
            // Credit card numbers: 13-19 digits with any separators, tolerating trailing OCR junk
            ("credit_card", #"\d{4}[-\s]*\d{4}[-\s]*\d{4}[-\s]*\d{1,7}"#),
            // Amex format: 4-6-5
            ("credit_card", #"\d{4}[-\s]*\d{6}[-\s]*\d{5}"#),
            // Any sequence of 2+ groups of 3-6 digits separated by spaces
            ("credit_card", #"\d{3,6}\s+\d{3,6}(?:\s+\d{3,6}){0,3}"#),
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

    func performAutoRedact() {
        guard state == .selected,
              selectionRect.width > 1, selectionRect.height > 1,
              let screenshot = screenshotImage else { return }

        // Determine redact style based on current tool
        let redactTool: AnnotationTool = (currentTool == .blur) ? .blur : (currentTool == .pixelate ? .pixelate : .rectangle)

        // Crop the selected region for Vision
        let drawR = captureDrawRect
        let selRect0 = selectionRect
        let regionImage = NSImage(size: selRect0.size, flipped: false) { _ in
            screenshot.draw(in: NSRect(x: -selRect0.origin.x, y: -selRect0.origin.y,
                                        width: drawR.width, height: drawR.height),
                            from: .zero, operation: .copy, fraction: 1.0)
            return true
        }

        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { return }

        let selRect = selectionRect
        let redactColor = currentColor
        // Capture composited image for blur/pixelate source
        let sourceImg = (redactTool == .blur || redactTool == .pixelate) ? compositedImage() : nil
        let sourceBounds = captureDrawRect

        let request = VisionOCR.makeTextRecognitionRequest { [weak self] request, error in
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
                    tool: redactTool,
                    startPoint: NSPoint(x: viewX, y: viewY),
                    endPoint: NSPoint(x: viewX + viewW, y: viewY + viewH),
                    color: redactColor,
                    strokeWidth: 0
                )
                annotation.groupID = groupID
                if redactTool == .rectangle {
                    annotation.rectFillStyle = .fill
                } else if redactTool == .blur || redactTool == .pixelate {
                    annotation.sourceImage = sourceImg
                    annotation.sourceImageBounds = sourceBounds
                }
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
            // Find observations that are purely numeric (3-6 digits) and group ones
            // that are horizontally adjacent (similar Y, sequential X) into card candidates
            struct DigitObs { let index: Int; let midY: CGFloat; let midX: CGFloat; let box: CGRect; let digitCount: Int }
            var digitObservations: [DigitObs] = []
            for (i, observation) in observations.enumerated() {
                guard !redactedObservations.contains(i) else { continue }
                guard let candidate = observation.topCandidates(1).first else { continue }
                // Strip non-digit chars (OCR artifacts like ฿, @, :, etc.)
                let digitsOnly = candidate.string.filter(\.isNumber)
                if digitsOnly.count >= 3 && digitsOnly.count <= 6 {
                    let box = observation.boundingBox
                    digitObservations.append(DigitObs(index: i, midY: box.midY, midX: box.midX, box: box, digitCount: digitsOnly.count))
                }
            }
            // Group by similar Y position (same row) — tolerance 3% of image height
            let yTolerance: CGFloat = 0.03
            var grouped: [[DigitObs]] = []
            var used = Set<Int>()
            for (idx, obs) in digitObservations.enumerated() {
                guard !used.contains(idx) else { continue }
                var row = [obs]
                used.insert(idx)
                for (jdx, other) in digitObservations.enumerated() {
                    guard !used.contains(jdx) else { continue }
                    if abs(other.midY - obs.midY) < yTolerance {
                        row.append(other)
                        used.insert(jdx)
                    }
                }
                row.sort { $0.midX < $1.midX }
                grouped.append(row)
            }
            // Redact rows with 2+ digit groups (likely split card numbers)
            for row in grouped where row.count >= 2 {
                let totalDigits = row.reduce(0) { $0 + $1.digitCount }
                // 8-19 digits = plausible card number; also accept 2 groups of 4 (partial)
                guard totalDigits >= 8 || (row.count >= 2 && row.allSatisfy { $0.digitCount >= 4 }) else { continue }
                for obs in row {
                    addRedaction(box: obs.box)
                    redactedObservations.insert(obs.index)
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

            // Bake blur/pixelate annotations on background thread
            for ann in redactAnnotations {
                ann.bakePixelate()
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self, !redactAnnotations.isEmpty else { return }
                self.annotations.append(contentsOf: redactAnnotations)
                self.undoStack.append(contentsOf: redactAnnotations.map { .added($0) })
                self.redoStack.removeAll()
                self.cachedCompositedImage = nil
                self.needsDisplay = true
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    private func performRedactAllText() {
        guard state == .selected,
              selectionRect.width > 1, selectionRect.height > 1,
              let screenshot = screenshotImage else { return }

        let redactTool: AnnotationTool = (currentTool == .blur) ? .blur : (currentTool == .pixelate ? .pixelate : .rectangle)

        let drawR2 = captureDrawRect
        let selRect0 = selectionRect
        let regionImage = NSImage(size: selRect0.size, flipped: false) { _ in
            screenshot.draw(in: NSRect(x: -selRect0.origin.x, y: -selRect0.origin.y,
                                        width: drawR2.width, height: drawR2.height),
                            from: .zero, operation: .copy, fraction: 1.0)
            return true
        }

        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { return }

        let selRect = selectionRect
        let redactColor = currentColor
        let sourceImg = (redactTool == .blur || redactTool == .pixelate) ? compositedImage() : nil
        let sourceBounds = captureDrawRect

        let request = VisionOCR.makeTextRecognitionRequest { [weak self] request, error in
            guard let self = self else { return }
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

            var redactAnnotations: [Annotation] = []
            let groupID = UUID()
            let padding: CGFloat = 2

            for observation in observations {
                let box = observation.boundingBox
                let viewX = selRect.origin.x + box.origin.x * selRect.width - padding
                let viewY = selRect.origin.y + box.origin.y * selRect.height - padding
                let viewW = box.width * selRect.width + padding * 2
                let viewH = box.height * selRect.height + padding * 2
                let annotation = Annotation(
                    tool: redactTool,
                    startPoint: NSPoint(x: viewX, y: viewY),
                    endPoint: NSPoint(x: viewX + viewW, y: viewY + viewH),
                    color: redactColor,
                    strokeWidth: 0
                )
                annotation.groupID = groupID
                if redactTool == .rectangle {
                    annotation.rectFillStyle = .fill
                } else if redactTool == .blur || redactTool == .pixelate {
                    annotation.sourceImage = sourceImg
                    annotation.sourceImageBounds = sourceBounds
                }
                redactAnnotations.append(annotation)
            }

            for ann in redactAnnotations {
                ann.bakePixelate()
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self, !redactAnnotations.isEmpty else { return }
                self.annotations.append(contentsOf: redactAnnotations)
                self.undoStack.append(contentsOf: redactAnnotations.map { .added($0) })
                self.redoStack.removeAll()
                self.cachedCompositedImage = nil
                self.needsDisplay = true
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: - Translate
    private func performTranslate(targetLang: String) {
        guard state == .selected,
              selectionRect.width > 1, selectionRect.height > 1,
              let screenshot = screenshotImage else { return }

        // Remove any previous translate overlays
        annotations.removeAll { $0.tool == .translateOverlay }
        isTranslating = true
        needsDisplay = true

        // Crop selected region for Vision.
        let drawR3 = captureDrawRect
        let selRect0 = selectionRect
        let regionImage = NSImage(size: selRect0.size, flipped: false) { _ in
            screenshot.draw(
                in: NSRect(x: -selRect0.origin.x, y: -selRect0.origin.y,
                           width: drawR3.width, height: drawR3.height),
                from: .zero, operation: .copy, fraction: 1.0
            )
            return true
        }

        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else {
            isTranslating = false
            return
        }

        let selRect = self.selectionRect
        let viewBounds = self.bounds

        // Vision OCR with bounding boxes
        let request = VisionOCR.makeTextRecognitionRequest { [weak self] request, error in
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

        let drawRect = captureDrawRect
        let annotationsCopy = annotations
        var success = false
        let image = NSImage(size: drawRect.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else {
                return true
            }
            screenshot.draw(in: NSRect(origin: .zero, size: drawRect.size), from: .zero, operation: .copy, fraction: 1.0)
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

    private func invalidateCompositedImageCache() {
        cachedCompositedImage = nil
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
           let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            scale = CGFloat(cg.width) / screenshot.size.width
        } else {
            scale = window?.backingScaleFactor ?? 2.0
        }

        let pixelW = Int(selectionRect.width * scale)
        let pixelH = Int(selectionRect.height * scale)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let cgCtx = CGContext(
            data: nil,
            width: pixelW, height: pixelH,
            bitsPerComponent: 8,
            bytesPerRow: pixelW * 4,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else { return nil }

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
        case .number: currentNumberSize = value; UserDefaults.standard.set(Double(value), forKey: "numberStrokeWidth")
        case .marker: currentMarkerSize = value; UserDefaults.standard.set(Double(value), forKey: "markerStrokeWidth")
        case .loupe: currentLoupeSize = value; UserDefaults.standard.set(Double(value), forKey: "loupeSize")
        default: currentStrokeWidth = value; UserDefaults.standard.set(Double(value), forKey: "currentStrokeWidth")
        }
        needsDisplay = true
    }


    func updateTextFontSize() {
        guard let tv = textEditView else { return }
        let range = tv.selectedRange().length > 0 ? tv.selectedRange() : NSRange(location: 0, length: tv.textStorage?.length ?? 0)
        tv.textStorage?.addAttribute(.font, value: NSFont.systemFont(ofSize: textFontSize, weight: textBold ? .bold : .regular), range: range)
        needsDisplay = true
    }

    func performAutoRedactPII() {
        performAutoRedact()
    }


    // MARK: - NSPopover-based pickers

    func showUploadConfirmPopover(anchorRect: NSRect, anchorView: NSView? = nil) {
        let current = UserDefaults.standard.bool(forKey: "uploadConfirmEnabled")
        let picker = ListPickerView()
        picker.items = [
            .init(title: "Confirm before upload", isSelected: current),
        ]
        picker.onSelect = { [weak self] _ in
            UserDefaults.standard.set(!current, forKey: "uploadConfirmEnabled")
            PopoverHelper.dismiss()
            self?.needsDisplay = true
        }
        let size = picker.preferredSize
        if let anchor = anchorView {
            PopoverHelper.show(picker, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(picker, size: size, at: NSPoint(x: anchorRect.maxX + 4, y: anchorRect.midY), in: self, preferredEdge: .maxX)
        }
    }

    func showRedactTypePopover(anchorRect: NSRect, anchorView: NSView? = nil) {
        let types = Self.redactTypeNames
        let picker = ListPickerView()
        picker.items = types.map { item in
            .init(title: item.label, isSelected: UserDefaults.standard.object(forKey: item.key) as? Bool ?? true)
        }
        picker.onSelect = { [weak self] idx in
            let key = types[idx].key
            let current = UserDefaults.standard.object(forKey: key) as? Bool ?? true
            UserDefaults.standard.set(!current, forKey: key)
            picker.items = types.map { item in
                .init(title: item.label, isSelected: UserDefaults.standard.object(forKey: item.key) as? Bool ?? true)
            }
            self?.needsDisplay = true
        }
        let size = picker.preferredSize
        if let anchor = anchorView {
            PopoverHelper.show(picker, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(picker, size: size, at: NSPoint(x: anchorRect.maxX + 4, y: anchorRect.midY), in: self, preferredEdge: .maxX)
        }
    }

    func showTranslatePopover(anchorRect: NSRect, anchorView: NSView? = nil) {
        let languages = TranslationService.availableLanguages
        let currentCode = TranslationService.targetLanguage
        let picker = ListPickerView()
        picker.items = languages.map { lang in
            .init(title: lang.name, isSelected: lang.code == currentCode)
        }
        picker.onSelect = { [weak self] idx in
            TranslationService.targetLanguage = languages[idx].code
            PopoverHelper.dismiss()
            self?.needsDisplay = true
        }
        let size = NSSize(width: 160, height: min(400, CGFloat(languages.count) * 28 + 12))
        if let anchor = anchorView {
            PopoverHelper.show(picker, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else {
            PopoverHelper.showAtPoint(picker, size: size, at: NSPoint(x: anchorRect.maxX + 4, y: anchorRect.midY), in: self, preferredEdge: .maxX)
        }
    }

    func showBeautifyGradientPopover(anchorRect: NSRect) {
        let picker = GradientPickerView(selectedIndex: beautifyStyleIndex)
        picker.onSelect = { [weak self] idx in
            self?.beautifyStyleIndex = idx
            UserDefaults.standard.set(idx, forKey: "beautifyStyleIndex")
            self?.needsDisplay = true
        }
        PopoverHelper.showAtPoint(picker, size: picker.preferredSize, at: NSPoint(x: anchorRect.midX, y: anchorRect.midY), in: self, preferredEdge: .minY)
    }

    func showEmojiPopover(anchorRect: NSRect) {
        let picker = EmojiPickerView()
        picker.onSelectEmoji = { [weak self] emoji in
            self?.currentStampImage = self?.renderEmoji(emoji)
            self?.currentStampEmoji = emoji
            self?.needsDisplay = true
        }
        PopoverHelper.showAtPoint(picker, size: picker.preferredSize, at: NSPoint(x: anchorRect.midX, y: anchorRect.midY), in: self, preferredEdge: .minY)
    }

    func showSystemColorPicker(target: ColorPickerTarget) {
        colorPickerTarget = target
        let panel = NSColorPanel.shared
        switch target {
        case .drawColor: panel.color = currentColor
        case .textBg: panel.color = textBgColorValue ?? .clear
        case .textOutline: panel.color = textOutlineColorValue ?? .clear
        }
        panel.showsAlpha = true
        panel.setTarget(self)
        panel.setAction(#selector(systemColorPanelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func systemColorPanelChanged(_ sender: NSColorPanel) {
        let color = sender.color
        switch colorPickerTarget {
        case .drawColor:
            currentColor = color
            applyColorToTextIfEditing()
            applyColorToSelectedAnnotation()
        case .textBg:
            textBgColorValue = color
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "textBgColor")
            }
        case .textOutline:
            textOutlineColorValue = color
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
        moveMode = false
        autoMeasurePreview = nil
        selectedAnnotation = nil
        isDraggingAnnotation = false
        toolBeforeSelect = nil
        hoveredAnnotationClearTimer?.invalidate()
        hoveredAnnotationClearTimer = nil
        hoveredAnnotation = nil
        showColorWheel = false
        beautifyEnabled = UserDefaults.standard.bool(forKey: "beautifyEnabled")
        beautifyStyleIndex = UserDefaults.standard.integer(forKey: "beautifyStyleIndex")
        beautifyMode = BeautifyMode(rawValue: UserDefaults.standard.integer(forKey: "beautifyMode")) ?? .window
        beautifyPadding = CGFloat(UserDefaults.standard.object(forKey: "beautifyPadding") as? Double ?? 48)
        beautifyCornerRadius = CGFloat(UserDefaults.standard.object(forKey: "beautifyCornerRadius") as? Double ?? 10)
        beautifyShadowRadius = CGFloat(UserDefaults.standard.object(forKey: "beautifyShadowRadius") as? Double ?? 20)
        beautifyBgRadius = CGFloat(UserDefaults.standard.object(forKey: "beautifyBgRadius") as? Double ?? 8)
        currentLineStyle = LineStyle(rawValue: UserDefaults.standard.integer(forKey: "currentLineStyle")) ?? .solid
        currentArrowStyle = ArrowStyle(rawValue: UserDefaults.standard.integer(forKey: "currentArrowStyle")) ?? .single
        currentRectFillStyle = RectFillStyle(rawValue: UserDefaults.standard.integer(forKey: "currentRectFillStyle")) ?? .stroke
        currentRectCornerRadius = CGFloat(UserDefaults.standard.object(forKey: "currentRectCornerRadius") as? Double ?? 0)
        textScrollView?.removeFromSuperview()
        textScrollView = nil
        textEditView = nil
        showFontPicker = false
        sizeInputField?.removeFromSuperview()
        sizeInputField = nil
        isResizingAnnotation = false
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
        isCapturingVideo = false
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
            showFontPicker = false
            window?.makeFirstResponder(self)
            needsDisplay = true
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        resizeTextViewToFit()
        needsDisplay = true
    }

    private func resizeTextViewToFit() {
        guard let tv = textEditView, let sv = textScrollView else { return }
        guard let layoutManager = tv.layoutManager, let textContainer = tv.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let extraHeight = layoutManager.extraLineFragmentRect.height

        let minH = max(28, textFontSize + 12)
        let inset = tv.textContainerInset
        let newHeight = max(minH, ceil(usedRect.height + extraHeight) + inset.height * 2)
        let width = sv.frame.width  // keep width fixed

        // Pin the top edge, adjust origin Y downward as height grows
        let topEdge = sv.frame.maxY
        sv.frame = NSRect(x: sv.frame.minX, y: topEdge - newHeight, width: width, height: newHeight)
        tv.frame.size = NSSize(width: width, height: newHeight)
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
