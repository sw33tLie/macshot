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
    func overlayViewDidRequestEnterRecordingMode()
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
    var editorCanvasOffset: NSPoint = .zero  // rendering offset for centering image in editor

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
    private var isRightClickSelecting: Bool = false  // right-click quick save mode

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
    private var textFontSize: CGFloat = 20
    private var textBold: Bool = false
    private var textItalic: Bool = false
    private var textUnderline: Bool = false
    private var textStrikethrough: Bool = false
    private var textFontFamily: String = UserDefaults.standard.string(forKey: "textFontFamily") ?? "System"

    // Text options row rects (drawn in secondary toolbar)
    private var textBoldRect: NSRect = .zero
    private var textItalicRect: NSRect = .zero
    private var textUnderlineRect: NSRect = .zero
    private var textStrikethroughRect: NSRect = .zero
    private var textSizeDecRect: NSRect = .zero
    private var textSizeIncRect: NSRect = .zero
    private var textFontDropdownRect: NSRect = .zero
    private var textConfirmRect: NSRect = .zero
    private var textCancelRect: NSRect = .zero
    private var textBgToggleRect: NSRect = .zero
    private var textOutlineToggleRect: NSRect = .zero
    private var textAlignLeftRect: NSRect = .zero
    private var textAlignCenterRect: NSRect = .zero
    private var textAlignRightRect: NSRect = .zero
    private var textAlignment: NSTextAlignment = .left
    private var isResizingTextBox: Bool = false
    private var textBoxResizeHandle: ResizeHandle = .none
    private var textBoxResizeStart: NSPoint = .zero
    private var textBoxOrigFrame: NSRect = .zero
    private var editingAnnotation: Annotation?  // annotation being re-edited
    private var textBgEnabled: Bool = UserDefaults.standard.bool(forKey: "textBgEnabled")
    private var textOutlineEnabled: Bool = UserDefaults.standard.bool(forKey: "textOutlineEnabled")
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
    var showToolbars: Bool = false
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
    private(set) var beautifyMode: BeautifyMode = BeautifyMode(rawValue: UserDefaults.standard.integer(forKey: "beautifyMode")) ?? .window
    private(set) var beautifyPadding: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "beautifyPadding") as? Double
        return v != nil ? CGFloat(v!) : 48
    }()
    private(set) var beautifyCornerRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "beautifyCornerRadius") as? Double
        return v != nil ? CGFloat(v!) : 10
    }()
    private(set) var beautifyShadowRadius: CGFloat = {
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
    private enum ColorPickerTarget { case drawColor, textBg, textOutline }
    private var colorPickerTarget: ColorPickerTarget = .drawColor
    private var colorPickerRect: NSRect = .zero

    // Beautify style picker popover
    private var showBeautifyPicker: Bool = false
    private var beautifyPickerRect: NSRect = .zero
    private var hoveredBeautifyRow: Int = -1
    // Beautify panel slider hit rects and dragging state
    private var beautifyPaddingSliderRect: NSRect = .zero
    private var beautifyCornerSliderRect: NSRect = .zero
    private var beautifyShadowSliderRect: NSRect = .zero
    private var beautifyModeWindowRect: NSRect = .zero
    private var beautifyModeRoundedRect: NSRect = .zero
    private var isDraggingBeautifySlider: Bool = false
    private var activeBeautifySlider: Int = -1  // 0=padding, 1=corner, 2=shadow
    private var beautifyBgRadiusSliderRect: NSRect = .zero
    private var beautifySwatchRects: [NSRect] = []
    private var showBeautifyGradientPicker: Bool = false
    private var beautifyGradientPickerRect: NSRect = .zero
    private var beautifyGradientBtnRect: NSRect = .zero
    private var beautifyToggleRect: NSRect = .zero
    private var beautifyToolbarAnimProgress: CGFloat = 1.0  // 0..1, 1 = fully settled
    private var beautifyToolbarAnimTimer: Timer?
    private var beautifyToolbarAnimTarget: Bool = false  // target beautify state

    // Tool options row (second row below bottom bar)
    var optionsRowRect: NSRect = .zero
    private var optionsStrokeSliderRect: NSRect = .zero
    private var optionsSmoothToggleRect: NSRect = .zero
    private var optionsRoundedToggleRect: NSRect = .zero
    private var measureUnitToggleRect: NSRect = .zero
    private var currentMeasureInPoints: Bool = UserDefaults.standard.bool(forKey: "measureInPoints")
    private var isDraggingOptionsStroke: Bool = false
    private var showBeautifyInOptionsRow: Bool = false  // true when user clicks beautify button to adjust settings
    private var optionsLineStyleRects: [NSRect] = []  // hit rects for line style buttons
    private var optionsCornerRadiusSliderRect: NSRect = .zero
    private var isDraggingOptionsCornerRadius: Bool = false
    private var currentLineStyle: LineStyle = LineStyle(rawValue: UserDefaults.standard.integer(forKey: "currentLineStyle")) ?? .solid
    private var currentArrowStyle: ArrowStyle = ArrowStyle(rawValue: UserDefaults.standard.integer(forKey: "currentArrowStyle")) ?? .single
    private var optionsArrowStyleRects: [NSRect] = []
    private var currentRectFillStyle: RectFillStyle = RectFillStyle(rawValue: UserDefaults.standard.integer(forKey: "currentRectFillStyle")) ?? .stroke
    private var optionsRectFillStyleRects: [NSRect] = []
    private var currentStampImage: NSImage?  // selected emoji/image for stamp tool
    private var currentStampEmoji: String?   // emoji string for highlight tracking
    private var stampPreviewPoint: NSPoint? // mouse position for stamp cursor preview
    private var stampEmojiRects: [NSRect] = []
    private var stampMoreRect: NSRect = .zero
    private var stampLoadRect: NSRect = .zero
    private var showEmojiPicker: Bool = false
    private var emojiPickerRect: NSRect = .zero
    private var emojiPickerItemRects: [NSRect] = []
    private var emojiPickerCategoryIndex: Int = 0
    private var emojiPickerCategoryRects: [NSRect] = []
    private static let emojiCategories: [(String, [String])] = [
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
    private static let commonEmojis = [
        "👆", "👇", "👈", "👉",           // point at things
        "✅", "❌", "⚠️", "❓",            // approve / reject / warn / question
        "🔥", "🐛", "💀", "🎉",           // reactions: hot, bug, dead, celebrate
        "👀", "💡", "🎯", "⭐",           // look here, idea, bullseye, star
        "❤️", "👍", "👎", "🚀",           // love, thumbs, launch
        "✏️",                              // edit
    ]
    private var currentRectCornerRadius: CGFloat = {
        let v = UserDefaults.standard.object(forKey: "currentRectCornerRadius") as? Double
        return v != nil ? CGFloat(v!) : 0
    }()

    // Stroke width picker popover
    private var showStrokePicker: Bool = false
    private var strokePickerRect: NSRect = .zero
    private var hoveredStrokeRow: Int = -1
    private var strokeSmoothToggleRect: NSRect = .zero  // hit rect for the smooth toggle row

    // Pencil smoothing — persisted in UserDefaults
    private var pencilSmoothEnabled: Bool = UserDefaults.standard.object(forKey: "pencilSmoothEnabled") as? Bool ?? true
    // Rounded rectangle corners — persisted in UserDefaults
    private var roundedRectEnabled: Bool = UserDefaults.standard.object(forKey: "roundedRectEnabled") as? Bool ?? false
    private var roundedRectToggleRect: NSRect = .zero

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
    private var redactPIIBtnRect: NSRect = .zero
    private var redactAllTextBtnRect: NSRect = .zero
    private var redactTypeDropdownRect: NSRect = .zero
    private var hoveredRedactBtn: Int = -1  // 0 = all text, 1 = PII, -1 = none
    private var pressedRedactBtn: Int = -1
    // Editor top bar
    var editorTopBarRect: NSRect = .zero
    var editorCropBtnRect: NSRect = .zero
    var editorFlipHBtnRect: NSRect = .zero
    var editorFlipVBtnRect: NSRect = .zero
    var editorResetZoomBtnRect: NSRect = .zero
    var cachedCompositedImage: NSImage? = nil  // invalidated when annotations change
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
    private let availableColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
        .systemPink, .white, .lightGray, .gray, .darkGray, .black,
    ]
    private var customColors: [NSColor?] = Array(repeating: nil, count: 7)
    private var customColorSlotsLoaded: Bool = false
    private var customColorSlotRects: [NSRect] = []
    private var selectedColorSlot: Int = 0  // which custom slot is selected for saving colors
    private var hexDisplayRect: NSRect = .zero
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)

        // Imperative cursor timer for overlay mode — continuously sets the correct cursor
        // to prevent AppKit's cursor rect system from interfering (especially on multi-monitor).
        // Only fires when the mouse is actually over THIS window to avoid cross-window fights.
        if window != nil {
            cursorTimer?.invalidate()
            cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { @MainActor [weak self] timer in
                guard let self = self, let win = self.window else { timer.invalidate(); return }
                // Only set cursor if this is the frontmost window under the mouse
                let mouseScreen = NSEvent.mouseLocation
                guard win.frame.contains(mouseScreen) else { return }
                // Skip if another window is above us at this point
                if let frontWindow = NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(mouseScreen) && $0.level >= win.level && $0 !== win }) {
                    _ = frontWindow  // another window is on top, don't fight
                    return
                }
                let windowPoint = win.mouseLocationOutsideOfEventStream
                let point = self.convert(windowPoint, from: nil)
                self.updateCursorForPoint(point)
            }
        }
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

        // Update cursor imperatively — only if this is the topmost window under the mouse
        if let win = window, win.frame.contains(NSEvent.mouseLocation) {
            let dominated = NSApp.windows.contains { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) && $0.level >= win.level && $0 !== win }
            if !dominated {
                updateCursorForPoint(point)
            }
        }

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
            } else if currentTool == .rectangle && roundedRectToggleRect.contains(point) {
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
            let padding: CGFloat = 2
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
            let padding: CGFloat = 2
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

        // Redact button hover
        if (currentTool == .pixelate || currentTool == .blur) && optionsRowRect.contains(point) {
            let newHovered: Int
            if redactAllTextBtnRect != .zero && redactAllTextBtnRect.contains(point) { newHovered = 0 }
            else if redactPIIBtnRect != .zero && redactPIIBtnRect.contains(point) { newHovered = 1 }
            else { newHovered = -1 }
            if newHovered != hoveredRedactBtn { hoveredRedactBtn = newHovered; needsDisplay = true }
        } else if hoveredRedactBtn != -1 {
            hoveredRedactBtn = -1; needsDisplay = true
        }

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

    override func resetCursorRects() {
        // Cursor is managed entirely by updateCursorForPoint() called from
        // mouseMoved and a repeating timer. No cursor rects needed.
    }

    /// Imperative cursor management for overlay mode. Called from mouseMoved and a timer.
    private func updateCursorForPoint(_ point: NSPoint) {
        // In editor window, don't override cursor in the title bar area (traffic lights, title)
        if isEditorMode, let win = window {
            let contentRect = win.contentRect(forFrameRect: win.frame)
            let titleBarHeight = win.frame.height - contentRect.height
            if point.y > bounds.height - titleBarHeight {
                return  // let AppKit handle the title bar cursor
            }
        }

        // Recording without annotation — always arrow
        if isRecording && !isAnnotating {
            NSCursor.arrow.set()
            return
        }
        // Text editing — always arrow
        if textEditView != nil {
            NSCursor.arrow.set()
            return
        }
        // Idle / selecting — always crosshair
        if state == .idle || state == .selecting {
            NSCursor.crosshair.set()
            return
        }
        guard state == .selected else { return }

        // Check UI elements first — arrow for all toolbars, popups, labels
        if showToolbars && (bottomBarRect.contains(point) || rightBarRect.contains(point) || optionsRowRect.contains(point)) { NSCursor.arrow.set(); return }
        if showColorPicker && colorPickerRect.contains(point) { NSCursor.arrow.set(); return }
        if showBeautifyPicker && beautifyPickerRect.contains(point) { NSCursor.arrow.set(); return }
        if showBeautifyGradientPicker && beautifyGradientPickerRect.contains(point) { NSCursor.arrow.set(); return }
        if showStrokePicker && strokePickerRect.contains(point) { NSCursor.arrow.set(); return }
        if showLoupeSizePicker && loupeSizePickerRect.contains(point) { NSCursor.arrow.set(); return }
        if showDelayPicker && delayPickerRect.contains(point) { NSCursor.arrow.set(); return }
        if showUploadConfirmPicker && uploadConfirmPickerRect.contains(point) { NSCursor.arrow.set(); return }
        if showUploadConfirmDialog && uploadConfirmDialogRect.contains(point) { NSCursor.arrow.set(); return }
        if showRedactTypePicker && redactTypePickerRect.contains(point) { NSCursor.arrow.set(); return }
        if showTranslatePicker && translatePickerRect.contains(point) { NSCursor.arrow.set(); return }
        if showFontPicker && fontPickerRect.contains(point) { NSCursor.arrow.set(); return }
        if showEmojiPicker && emojiPickerRect.contains(point) { NSCursor.arrow.set(); return }
        if updateCursorForChrome(at: point) { return }
        if sizeLabelRect.contains(point) && sizeInputField == nil { NSCursor.pointingHand.set(); return }
        if zoomLabelRect.contains(point) && zoomLabelOpacity > 0 && zoomInputField == nil { NSCursor.pointingHand.set(); return }

        // Selection resize handles (overlay only — disabled in editor)
        if !isEditorMode {
            let r = selectionRect
            let hs = handleSize + 4
            let edgeT: CGFloat = 6
            if NSRect(x: r.minX - hs/2, y: r.maxY - hs/2, width: hs, height: hs).contains(point) ||
               NSRect(x: r.maxX - hs/2, y: r.minY - hs/2, width: hs, height: hs).contains(point) {
                Self.nwseCursor.set(); return
            }
            if NSRect(x: r.maxX - hs/2, y: r.maxY - hs/2, width: hs, height: hs).contains(point) ||
               NSRect(x: r.minX - hs/2, y: r.minY - hs/2, width: hs, height: hs).contains(point) {
                Self.neswCursor.set(); return
            }
            if NSRect(x: r.minX + hs/2, y: r.maxY - edgeT/2, width: r.width - hs, height: edgeT).contains(point) ||
               NSRect(x: r.minX + hs/2, y: r.minY - edgeT/2, width: r.width - hs, height: edgeT).contains(point) {
                NSCursor.resizeUpDown.set(); return
            }
            if NSRect(x: r.minX - edgeT/2, y: r.minY + hs/2, width: edgeT, height: r.height - hs).contains(point) ||
               NSRect(x: r.maxX - edgeT/2, y: r.minY + hs/2, width: edgeT, height: r.height - hs).contains(point) {
                NSCursor.resizeLeftRight.set(); return
            }
        }

        // Hover-to-move over annotations
        let hoverMoveTools: Set<AnnotationTool> = [.arrow, .line, .rectangle, .ellipse, .select]
        if hoverMoveTools.contains(currentTool) {
            let canvasPoint = viewToCanvas(point)
            if let hovered = hoveredAnnotation, hovered.hitTest(point: canvasPoint) {
                Self.moveCursor.set(); return
            }
        }

        // Tool-specific cursor inside selection
        switch currentTool {
        case .pencil, .marker: Self.penCursor.set()
        case .select: NSCursor.arrow.set()
        default: NSCursor.crosshair.set()
        }
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

    /// Override to position toolbars for editor mode. Base pins bottom bar centered at bottom, right bar at top-right.
    func positionToolbarsForEditor() {
        // Bottom bar: centered at the bottom of the view
        let bw = bottomBarRect.width
        let bh = bottomBarRect.height
        let optRowSpace: CGFloat = toolHasOptionsRow ? 40 : 0  // 34 row + 2 gap + 4 margin
        let newBottomY: CGFloat = 6 + optRowSpace
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
        let editorTopBarOffset: CGFloat = 32 + 4  // top bar height + gap
        let newRightY = bounds.maxY - rh - editorTopBarOffset
        let rdx = newRightX - rightBarRect.origin.x
        let rdy = newRightY - rightBarRect.origin.y
        rightBarRect = NSRect(x: newRightX, y: newRightY, width: rw, height: rh)
        for i in 0..<rightButtons.count {
            rightButtons[i].rect = rightButtons[i].rect.offsetBy(dx: rdx, dy: rdy)
        }
    }

    /// Override to control whether detach (open in editor) is allowed. Base returns true when not in editor mode.
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
                let shouldHide = showColorPicker && (colorPickerTarget == .textBg || colorPickerTarget == .textOutline)
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
                rebuildToolbarLayout()
                // Hide bottom bar and options row when in recording mode (not annotating)
                // — the right bar is drawn by RecordingControlView instead
                if !(isRecording && !isAnnotating) {
                    ToolbarLayout.drawToolbar(barRect: bottomBarRect, buttons: bottomButtons, selectionSize: selectionRect.size)
                }
                if !(isRecording && !isAnnotating) {
                    ToolbarLayout.drawToolbar(barRect: rightBarRect, buttons: rightButtons, selectionSize: nil)
                }

                // Tool options row (second row below/above bottom bar)
                if toolHasOptionsRow && !(isRecording && !isAnnotating) {
                    drawToolOptionsRow()
                } else {
                    optionsRowRect = .zero
                }

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

                // Beautify gradient picker
                if showBeautifyGradientPicker {
                    drawBeautifyGradientPicker()
                }

                // Translate language picker
                if showTranslatePicker {
                    drawTranslatePicker()
                }

                // Emoji picker
                if showEmojiPicker {
                    drawEmojiPicker()
                }

                // Tooltip for hovered button
                drawHoveredTooltip()
            }

            // Editor top bar (drawn outside zoom transform, fixed to window top)
            drawTopChrome()

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
        if isRecording {
            drawRecordingHUD()
            if UserDefaults.standard.bool(forKey: "recordMouseHighlight") { drawMouseHighlights() }
        }

        // Scroll capture HUD (drawn on top of everything when active)
        if isScrollCapturing { drawScrollCaptureHUD() }

        // Keep cursor rects in sync with current selection

    }

    private func drawHoveredTooltip() {
        guard hoveredButtonIndex >= 0 else { return }

        // Hide tooltip when any picker/popover is open (they overlap)
        if showDelayPicker || showUploadConfirmPicker || showRedactTypePicker
            || showTranslatePicker || showStrokePicker || showLoupeSizePicker || showBeautifyPicker {
            return
        }

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
                let folderName = URL(fileURLWithPath: SaveDirectoryAccess.displayPath).lastPathComponent
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
        // Lazy-load custom colors on first use
        if !customColorSlotsLoaded {
            customColors = loadCustomColors()
            customColorSlotsLoaded = true
            // Initialize HSB tracker from current color
            if let hsb = currentColor.usingColorSpace(.deviceRGB) {
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                customPickerHue = h
                customPickerSaturation = s
                customBrightness = b
            }
        }

        let cols = 6
        let presetRows = 2  // 12 colors in 2 rows of 6
        let swatchSize: CGFloat = 24
        let padding: CGFloat = 6
        let pickerWidth = CGFloat(cols) * (swatchSize + padding) + padding

        // Custom color slot dimensions
        let customSlotSize: CGFloat = 20
        let customSlotSpacing: CGFloat = 6
        let customSlotCount = customColors.count

        let opacityBarHeight: CGFloat = 12
        let gradientSize: CGFloat = 140
        let brightnessBarHeight: CGFloat = 16
        let hexRowHeight: CGFloat = 22
        // Calculate total picker height
        let presetSwatchesHeight = CGFloat(presetRows) * (swatchSize + padding)
        let customSlotsRowHeight = customSlotSize
        let pickerHeight = padding + presetSwatchesHeight + padding + customSlotsRowHeight + padding
            + opacityBarHeight + padding + gradientSize + padding + brightnessBarHeight
            + padding + hexRowHeight + padding

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
            pickerY = bottomBarRect.minY - pickerHeight - 4
            if pickerY < bounds.minY + 4 {
                pickerY = bottomBarRect.maxY + 4
            }
            if pickerY + pickerHeight > bounds.maxY - 4 {
                pickerY = bounds.maxY - pickerHeight - 4
            }
        } else {
            pickerY = bottomBarRect.maxY + 4
            if pickerY + pickerHeight > bounds.maxY - 4 {
                pickerY = bottomBarRect.minY - pickerHeight - 4
            }
            if pickerY < bounds.minY + 4 {
                pickerY = bounds.minY + 4
            }
        }

        // Clamp horizontal
        pickerX = max(bounds.minX + 4, min(pickerX, bounds.maxX - pickerWidth - 4))

        colorPickerRect = NSRect(x: pickerX, y: pickerY, width: pickerWidth, height: pickerHeight)

        // Background
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: colorPickerRect, xRadius: 8, yRadius: 8).fill()

        // Track cursor Y position from top of picker (AppKit: top = maxY)
        var cursorY = colorPickerRect.maxY

        // --- 1. Preset color swatches (2 rows of 6) ---
        cursorY -= padding
        for (i, color) in availableColors.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = colorPickerRect.minX + padding + CGFloat(col) * (swatchSize + padding)
            let y = cursorY - swatchSize - CGFloat(row) * (swatchSize + padding)
            let swatchRect = NSRect(x: x, y: y, width: swatchSize, height: swatchSize)

            color.setFill()
            NSBezierPath(roundedRect: swatchRect, xRadius: 4, yRadius: 4).fill()

            // Selected highlight — compare ignoring alpha
            let selColor = currentColor.withAlphaComponent(1.0)
            let cmpColor = color.withAlphaComponent(1.0)
            if colorsMatchRGB(selColor, cmpColor) {
                NSColor.white.setStroke()
                let border = NSBezierPath(roundedRect: swatchRect.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
                border.lineWidth = 2
                border.stroke()
            }
        }
        cursorY -= presetSwatchesHeight

        // --- 2. Custom color slots (1 row of 8) ---
        cursorY -= padding
        customColorSlotRects = []
        let totalCustomWidth = CGFloat(customSlotCount) * customSlotSize + CGFloat(customSlotCount - 1) * customSlotSpacing
        let customStartX = colorPickerRect.minX + (pickerWidth - totalCustomWidth) / 2
        for i in 0..<customSlotCount {
            let slotX = customStartX + CGFloat(i) * (customSlotSize + customSlotSpacing)
            let slotY = cursorY - customSlotSize
            let slotRect = NSRect(x: slotX, y: slotY, width: customSlotSize, height: customSlotSize)
            customColorSlotRects.append(slotRect)

            let isSelected = selectedColorSlot == i

            if let savedColor = customColors[i] {
                // Filled slot
                savedColor.setFill()
                NSBezierPath(ovalIn: slotRect).fill()

                if isSelected {
                    NSColor.white.setStroke()
                    let border = NSBezierPath(ovalIn: slotRect.insetBy(dx: -2, dy: -2))
                    border.lineWidth = 2.5
                    border.stroke()
                }
            } else {
                // Empty slot
                if isSelected {
                    NSColor.white.withAlphaComponent(0.5).setStroke()
                    let border = NSBezierPath(ovalIn: slotRect.insetBy(dx: 1, dy: 1))
                    border.lineWidth = 2
                    border.stroke()
                } else {
                    NSColor.white.withAlphaComponent(0.2).setStroke()
                    let dashPath = NSBezierPath(ovalIn: slotRect.insetBy(dx: 1, dy: 1))
                    dashPath.lineWidth = 1
                    let dashPattern: [CGFloat] = [3, 3]
                    dashPath.setLineDash(dashPattern, count: 2, phase: 0)
                    dashPath.stroke()
                }
            }
        }
        cursorY -= customSlotSize

        // --- 3. Opacity slider ---
        cursorY -= padding
        do {
            let opacityX = colorPickerRect.minX + padding
            let opacityW = pickerWidth - padding * 2
            let oRect = NSRect(x: opacityX, y: cursorY - opacityBarHeight, width: opacityW, height: opacityBarHeight)
            opacitySliderRect = oRect

            // Checkerboard background
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

            // Gradient overlay
            let oPath = NSBezierPath(roundedRect: oRect, xRadius: 4, yRadius: 4)
            let oGrad = NSGradient(starting: currentColor.withAlphaComponent(0), ending: currentColor.withAlphaComponent(1))
            oGrad?.draw(in: oPath, angle: 0)

            // Border
            NSColor.white.withAlphaComponent(0.3).setStroke()
            let oBorder = NSBezierPath(roundedRect: oRect, xRadius: 4, yRadius: 4)
            oBorder.lineWidth = 0.5
            oBorder.stroke()

            // Thumb
            let thumbX = oRect.minX + currentColorOpacity * oRect.width
            let thumbH: CGFloat = opacityBarHeight + 4
            let thumbRect = NSRect(x: thumbX - 4, y: oRect.midY - thumbH / 2, width: 8, height: thumbH)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: thumbRect, xRadius: 3, yRadius: 3).fill()
            NSColor.black.withAlphaComponent(0.3).setStroke()
            let thumbBorder = NSBezierPath(roundedRect: thumbRect, xRadius: 3, yRadius: 3)
            thumbBorder.lineWidth = 0.5
            thumbBorder.stroke()

            // Opacity percentage label
            let opacityPct = Int(currentColorOpacity * 100)
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            ]
            let labelStr = "\(opacityPct)%" as NSString
            let labelSize = labelStr.size(withAttributes: labelAttrs)
            labelStr.draw(at: NSPoint(x: oRect.maxX - labelSize.width - 2, y: oRect.midY - labelSize.height / 2), withAttributes: labelAttrs)
        }
        cursorY -= opacityBarHeight

        // --- 4. HSB gradient (always visible) ---
        cursorY -= padding
        let gradientX = colorPickerRect.minX + padding
        let gradientW = pickerWidth - padding * 2
        let gradRect = NSRect(x: gradientX, y: cursorY - gradientSize, width: gradientW, height: gradientSize)
        customPickerGradientRect = gradRect

        drawHSBGradient(in: gradRect, brightness: customBrightness)

        // Crosshair indicator
        do {
            let cx = gradRect.minX + customPickerHue * gradRect.width
            let cy = gradRect.minY + customPickerSaturation * gradRect.height
            let crossSize: CGFloat = 10
            NSColor.black.withAlphaComponent(0.6).setStroke()
            let outerRing = NSBezierPath(ovalIn: NSRect(x: cx - crossSize/2, y: cy - crossSize/2, width: crossSize, height: crossSize))
            outerRing.lineWidth = 2
            outerRing.stroke()
            NSColor.white.setStroke()
            let innerRing = NSBezierPath(ovalIn: NSRect(x: cx - crossSize/2 + 1, y: cy - crossSize/2 + 1, width: crossSize - 2, height: crossSize - 2))
            innerRing.lineWidth = 1.5
            innerRing.stroke()
        }
        cursorY -= gradientSize

        // --- 5. Brightness slider ---
        cursorY -= padding
        let bSliderRect = NSRect(x: gradientX, y: cursorY - brightnessBarHeight, width: gradientW, height: brightnessBarHeight)
        customPickerBrightnessRect = bSliderRect

        let currentHS = NSColor(calibratedHue: customPickerHue,
                                 saturation: customPickerSaturation,
                                 brightness: 1.0, alpha: 1.0)
        let bPath = NSBezierPath(roundedRect: bSliderRect, xRadius: 4, yRadius: 4)
        let bGrad = NSGradient(starting: .black, ending: currentHS)
        bGrad?.draw(in: bPath, angle: 0)

        // Brightness thumb (same style as opacity slider)
        let bx = bSliderRect.minX + customBrightness * bSliderRect.width
        let bThumbH: CGFloat = brightnessBarHeight + 4
        let bThumbRect = NSRect(x: bx - 4, y: bSliderRect.midY - bThumbH / 2, width: 8, height: bThumbH)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: bThumbRect, xRadius: 3, yRadius: 3).fill()
        NSColor.black.withAlphaComponent(0.3).setStroke()
        let bThumbBorder = NSBezierPath(roundedRect: bThumbRect, xRadius: 3, yRadius: 3)
        bThumbBorder.lineWidth = 0.5
        bThumbBorder.stroke()
        cursorY -= brightnessBarHeight

        // --- 6. Hex display ---
        cursorY -= padding
        let hexY = cursorY - hexRowHeight
        let hexRect = NSRect(x: colorPickerRect.minX + padding, y: hexY, width: pickerWidth - padding * 2, height: hexRowHeight)
        hexDisplayRect = hexRect

        // Gray background
        NSColor(white: 0.2, alpha: 0.8).setFill()
        NSBezierPath(roundedRect: hexRect, xRadius: 4, yRadius: 4).fill()

        // Small colored circle preview
        let previewCircleSize: CGFloat = 12
        let previewCircleRect = NSRect(x: hexRect.minX + 6, y: hexRect.midY - previewCircleSize / 2,
                                        width: previewCircleSize, height: previewCircleSize)
        currentColor.withAlphaComponent(currentColorOpacity).setFill()
        NSBezierPath(ovalIn: previewCircleRect).fill()
        NSColor.white.withAlphaComponent(0.3).setStroke()
        let previewBorder = NSBezierPath(ovalIn: previewCircleRect)
        previewBorder.lineWidth = 0.5
        previewBorder.stroke()

        // "#" prefix (dimmer) + hex text
        let hashAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]
        let hashStr = "#" as NSString
        let hashSize = hashStr.size(withAttributes: hashAttrs)
        let hashX = previewCircleRect.maxX + 6
        hashStr.draw(at: NSPoint(x: hashX, y: hexRect.midY - hashSize.height / 2), withAttributes: hashAttrs)

        let hexStr = colorToHexString(currentColor)
        let hexAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let hexNS = hexStr as NSString
        hexNS.draw(at: NSPoint(x: hashX + hashSize.width, y: hexRect.midY - hashSize.height / 2), withAttributes: hexAttrs)

        cursorY -= hexRowHeight

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

    private func removeCustomColor(at index: Int) {
        guard index >= 0 && index < customColors.count else { return }
        customColors[index] = nil
        saveCustomColors()
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
        let pickerWidth: CGFloat = 200
        let pad: CGFloat = 8
        let labelH: CGFloat = 16
        let sliderH: CGFloat = 22
        let swatchSize: CGFloat = 26
        let swatchSpacing: CGFloat = 4
        let modeH: CGFloat = 28
        let sectionGap: CGFloat = 8

        // Calculate height: mode toggle + 4 sliders + swatch grid
        let swatchRows = Int(ceil(Double(styles.count) / 3.0))
        let swatchGridH = CGFloat(swatchRows) * (swatchSize + swatchSpacing)
        let pickerHeight = pad + modeH + sectionGap
            + (labelH + sliderH + sectionGap) * 4  // padding, corner, shadow, bg radius sliders
            + labelH + swatchGridH + pad

        // Anchor to the beautify button
        var anchorRect = NSRect.zero
        for btn in bottomButtons {
            if case .beautify = btn.action {
                anchorRect = btn.rect
                break
            }
        }

        let pickerX = max(bounds.minX + 4, min(anchorRect.midX - pickerWidth / 2, bounds.maxX - pickerWidth - 4))
        var pickerY = anchorRect.maxY + 4
        if pickerY + pickerHeight > bounds.maxY - 4 {
            pickerY = anchorRect.minY - pickerHeight - 4
        }
        pickerY = max(bounds.minY + 4, min(pickerY, bounds.maxY - pickerHeight - 4))

        let pickerRect = NSRect(x: pickerX, y: pickerY, width: pickerWidth, height: pickerHeight)
        beautifyPickerRect = pickerRect

        // Background
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: pickerRect, xRadius: 8, yRadius: 8).fill()

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]

        let insetX = pickerRect.minX + pad
        let contentW = pickerWidth - pad * 2
        var curY = pickerRect.maxY - pad

        // ── Mode toggle: Window / Rounded ──
        curY -= modeH
        let halfW = (contentW - 4) / 2
        let windowBtnRect = NSRect(x: insetX, y: curY, width: halfW, height: modeH)
        let roundedBtnRect = NSRect(x: insetX + halfW + 4, y: curY, width: halfW, height: modeH)
        beautifyModeWindowRect = windowBtnRect
        beautifyModeRoundedRect = roundedBtnRect

        let modeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]

        // Window button
        (beautifyMode == .window ? ToolbarLayout.accentColor.withAlphaComponent(0.6) : NSColor.white.withAlphaComponent(0.12)).setFill()
        NSBezierPath(roundedRect: windowBtnRect, xRadius: 5, yRadius: 5).fill()
        let wStr = "Window" as NSString
        let wSize = wStr.size(withAttributes: modeAttrs)
        wStr.draw(at: NSPoint(x: windowBtnRect.midX - wSize.width / 2, y: windowBtnRect.midY - wSize.height / 2), withAttributes: modeAttrs)

        // Rounded button
        (beautifyMode == .rounded ? ToolbarLayout.accentColor.withAlphaComponent(0.6) : NSColor.white.withAlphaComponent(0.12)).setFill()
        NSBezierPath(roundedRect: roundedBtnRect, xRadius: 5, yRadius: 5).fill()
        let rStr = "Rounded" as NSString
        let rSize = rStr.size(withAttributes: modeAttrs)
        rStr.draw(at: NSPoint(x: roundedBtnRect.midX - rSize.width / 2, y: roundedBtnRect.midY - rSize.height / 2), withAttributes: modeAttrs)

        curY -= sectionGap

        // ── Padding slider ──
        curY -= labelH
        ("Padding" as NSString).draw(at: NSPoint(x: insetX, y: curY), withAttributes: labelAttrs)
        curY -= sliderH
        beautifyPaddingSliderRect = NSRect(x: insetX, y: curY, width: contentW, height: sliderH)
        drawBeautifySlider(rect: beautifyPaddingSliderRect, value: beautifyPadding, min: 16, max: 96)
        curY -= sectionGap

        // ── Corner Radius slider ──
        curY -= labelH
        ("Corner Radius" as NSString).draw(at: NSPoint(x: insetX, y: curY), withAttributes: labelAttrs)
        curY -= sliderH
        beautifyCornerSliderRect = NSRect(x: insetX, y: curY, width: contentW, height: sliderH)
        drawBeautifySlider(rect: beautifyCornerSliderRect, value: beautifyCornerRadius, min: 0, max: 30)
        curY -= sectionGap

        // ── Shadow slider ──
        curY -= labelH
        ("Shadow" as NSString).draw(at: NSPoint(x: insetX, y: curY), withAttributes: labelAttrs)
        curY -= sliderH
        beautifyShadowSliderRect = NSRect(x: insetX, y: curY, width: contentW, height: sliderH)
        drawBeautifySlider(rect: beautifyShadowSliderRect, value: beautifyShadowRadius, min: 0, max: 40)
        curY -= sectionGap

        // ── Background swatches ──
        curY -= labelH
        ("Background" as NSString).draw(at: NSPoint(x: insetX, y: curY), withAttributes: labelAttrs)
        curY -= swatchSpacing

        beautifySwatchRects = []
        for (i, style) in styles.enumerated() {
            let col = i % 3
            let row = i / 3
            let sx = insetX + CGFloat(col) * (swatchSize + swatchSpacing)
            let sy = curY - CGFloat(row + 1) * (swatchSize + swatchSpacing)
            let swatchRect = NSRect(x: sx, y: sy, width: swatchSize, height: swatchSize)
            beautifySwatchRects.append(swatchRect)

            let swatchPath = NSBezierPath(roundedRect: swatchRect, xRadius: 5, yRadius: 5)
            drawStyleSwatch(style: style, path: swatchPath, rect: swatchRect)

            // Selection ring
            if i == beautifyStyleIndex % styles.count {
                ToolbarLayout.accentColor.setStroke()
                let ring = NSBezierPath(roundedRect: swatchRect.insetBy(dx: -2, dy: -2), xRadius: 6, yRadius: 6)
                ring.lineWidth = 2
                ring.stroke()
            }
        }
    }

    /// Draw a gradient swatch — uses mesh rendering on macOS 15+ for mesh styles, linear otherwise.
    private func drawStyleSwatch(style: BeautifyStyle, path: NSBezierPath, rect: NSRect) {
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

    private func drawBeautifySlider(rect: NSRect, value: CGFloat, min minVal: CGFloat, max maxVal: CGFloat) {
        let trackH: CGFloat = 4
        let knobR: CGFloat = 7
        let trackY = rect.midY - trackH / 2
        let trackRect = NSRect(x: rect.minX, y: trackY, width: rect.width, height: trackH)

        // Track background
        NSColor.white.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: 2, yRadius: 2).fill()

        // Filled portion
        let frac = (value - minVal) / (maxVal - minVal)
        let filledW = rect.width * frac
        let filledRect = NSRect(x: rect.minX, y: trackY, width: filledW, height: trackH)
        ToolbarLayout.accentColor.setFill()
        NSBezierPath(roundedRect: filledRect, xRadius: 2, yRadius: 2).fill()

        // Knob
        let knobX = rect.minX + filledW
        let knobCenter = NSPoint(x: knobX, y: rect.midY)
        let knobRect = NSRect(x: knobCenter.x - knobR, y: knobCenter.y - knobR, width: knobR * 2, height: knobR * 2)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
        NSColor.white.withAlphaComponent(0.4).setStroke()
        let knobBorder = NSBezierPath(ovalIn: knobRect.insetBy(dx: 0.5, dy: 0.5))
        knobBorder.lineWidth = 0.5
        knobBorder.stroke()
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

    private func drawToolOptionsRow() {
        let rowH: CGFloat = 34
        let gap: CGFloat = 2
        let rowY: CGFloat
        let belowY = bottomBarRect.minY - rowH - gap
        let aboveY = bottomBarRect.maxY + gap
        if bottomBarRect.midY < selectionRect.midY {
            // Prefer below, flip above if it would go off-screen
            rowY = belowY >= bounds.minY + 2 ? belowY : aboveY
        } else {
            // Prefer above, flip below if it would go off-screen
            rowY = aboveY + rowH <= bounds.maxY - 2 ? aboveY : belowY
        }

        let rowWidth = bottomBarRect.width
        let rowX = bottomBarRect.midX - rowWidth / 2
        let rowRect = NSRect(x: rowX, y: rowY, width: rowWidth, height: rowH)
        optionsRowRect = rowRect

        // Background — frosted glass style
        let bgRect = rowRect
        NSColor(white: 0.08, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: ToolbarLayout.cornerRadius, yRadius: ToolbarLayout.cornerRadius).fill()
        // Subtle top highlight (liquid glass effect)
        let highlightRect = NSRect(x: bgRect.minX + 1, y: bgRect.maxY - 1, width: bgRect.width - 2, height: 1)
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: highlightRect).fill()

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.4),
        ]
        let pad: CGFloat = 10
        var curX = rowRect.minX + pad

        optionsStrokeSliderRect = .zero
        optionsSmoothToggleRect = .zero
        optionsRoundedToggleRect = .zero
        optionsLineStyleRects = []
        optionsArrowStyleRects = []
        optionsRectFillStyleRects = []

        // Reset text option rects
        textBoldRect = .zero
        textItalicRect = .zero
        textUnderlineRect = .zero
        textStrikethroughRect = .zero
        textSizeDecRect = .zero
        textSizeIncRect = .zero
        textFontDropdownRect = .zero
        textConfirmRect = .zero
        textCancelRect = .zero
        textBgToggleRect = .zero
        textOutlineToggleRect = .zero
        textAlignLeftRect = .zero
        textAlignCenterRect = .zero
        textAlignRightRect = .zero

        if showBeautifyInOptionsRow {
            drawBeautifyOptionsRow(in: rowRect)
            return
        }

        if currentTool == .text {
            drawTextOptionsRow(in: rowRect)
            return
        }

        if currentTool == .measure {
            measureUnitToggleRect = .zero
            let pad: CGFloat = 10
            var curX = rowRect.minX + pad

            // px / pt segment toggle
            let segH: CGFloat = 22
            let segW: CGFloat = 32
            let segY = rowRect.midY - segH / 2
            let totalSegW = segW * 2
            let segBgRect = NSRect(x: curX, y: segY, width: totalSegW, height: segH)
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: segBgRect, xRadius: 5, yRadius: 5).fill()

            for (i, label) in ["px", "pt"].enumerated() {
                let btnRect = NSRect(x: curX + CGFloat(i) * segW, y: segY, width: segW, height: segH)
                if i == 0 { measureUnitToggleRect = btnRect }
                let isActive = (i == 0 && !currentMeasureInPoints) || (i == 1 && currentMeasureInPoints)
                if isActive {
                    ToolbarLayout.accentColor.withAlphaComponent(0.45).setFill()
                    NSBezierPath(roundedRect: btnRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4).fill()
                }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(isActive ? 0.9 : 0.35),
                ]
                let str = label as NSString
                let size = str.size(withAttributes: attrs)
                str.draw(at: NSPoint(x: btnRect.midX - size.width / 2, y: btnRect.midY - size.height / 2), withAttributes: attrs)
            }
            curX += totalSegW + 16

            // Hint text
            let hint = "Hold 1 auto-vertical  ·  Hold 2 auto-horizontal"
            let hintAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.5),
            ]
            let hintStr = hint as NSString
            let hintSize = hintStr.size(withAttributes: hintAttrs)
            hintStr.draw(at: NSPoint(x: curX, y: rowRect.midY - hintSize.height / 2), withAttributes: hintAttrs)
            return
        }

        if currentTool == .pixelate || currentTool == .blur {
            drawRedactOptionsRow(in: rowRect)
            return
        }

        if currentTool == .stamp {
            drawStampOptionsRow(in: rowRect)
            return
        }

        // Determine what to show
        let showStroke: Bool
        let showLineStyle: Bool
        switch currentTool {
        case .pencil:                       showStroke = true;  showLineStyle = true
        case .marker:                       showStroke = true;  showLineStyle = false
        case .line, .arrow:                 showStroke = true;  showLineStyle = true
        case .rectangle, .ellipse:          showStroke = true;  showLineStyle = true
        case .number, .loupe:               showStroke = true;  showLineStyle = false
        default:                            showStroke = false; showLineStyle = false
        }

        // ── Stepped slider with track ──
        if showStroke {
            let steps: [CGFloat] = currentTool == .loupe
                ? [60, 80, 100, 120, 160, 200, 250, 320]
                : [1, 2, 3, 5, 8, 12, 20]
            let activeWidth: CGFloat
            switch currentTool {
            case .number: activeWidth = currentNumberSize
            case .marker: activeWidth = currentMarkerSize
            case .loupe: activeWidth = currentLoupeSize
            default: activeWidth = currentStrokeWidth
            }

            let sliderW: CGFloat = CGFloat(steps.count - 1) * 16 + 14  // 16pt between steps
            let trackH: CGFloat = 2
            let trackY = rowRect.midY - trackH / 2

            // Track background
            let trackRect = NSRect(x: curX, y: trackY, width: sliderW, height: trackH)
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: trackRect, xRadius: 1, yRadius: 1).fill()

            // Find active index
            var activeIdx = 0
            for (i, s) in steps.enumerated() { if s == activeWidth { activeIdx = i } }

            // Filled portion
            let filledFrac = CGFloat(activeIdx) / CGFloat(steps.count - 1)
            let filledRect = NSRect(x: curX, y: trackY, width: sliderW * filledFrac, height: trackH)
            ToolbarLayout.accentColor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: filledRect, xRadius: 1, yRadius: 1).fill()

            // Step ticks and knob
            for (i, _) in steps.enumerated() {
                let frac = CGFloat(i) / CGFloat(steps.count - 1)
                let cx = curX + sliderW * frac
                let isActive = i == activeIdx

                // Small tick mark
                let tickR: CGFloat = isActive ? 0 : 2
                if tickR > 0 {
                    let tickRect = NSRect(x: cx - tickR, y: rowRect.midY - tickR, width: tickR * 2, height: tickR * 2)
                    NSColor.white.withAlphaComponent(i <= activeIdx ? 0.5 : 0.2).setFill()
                    NSBezierPath(ovalIn: tickRect).fill()
                }

                // Knob for active step
                if isActive {
                    let knobR: CGFloat = 7
                    let knobRect = NSRect(x: cx - knobR, y: rowRect.midY - knobR, width: knobR * 2, height: knobR * 2)
                    // Knob shadow
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
                    shadow.shadowBlurRadius = 3
                    shadow.shadowOffset = NSSize(width: 0, height: -1)
                    NSGraphicsContext.saveGraphicsState()
                    shadow.set()
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: knobRect).fill()
                    NSGraphicsContext.restoreGraphicsState()
                    // Redraw knob clean (over shadow)
                    NSColor.white.setFill()
                    NSBezierPath(ovalIn: knobRect).fill()
                }
            }

            // Size label
            // Fixed-width right-aligned size label (prevents layout shift on digit change)
            let sizeLabel = currentTool == .loupe ? "\(Int(activeWidth))" : "\(Int(activeWidth))px"
            let sizeStr = sizeLabel as NSString
            let sizeAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.5),
            ]
            let fixedLabelW: CGFloat = currentTool == .loupe ? 28 : 24  // fits "320" or "20px"
            let labelX = curX + sliderW + 12
            let sizeSize = sizeStr.size(withAttributes: sizeAttrs)
            sizeStr.draw(at: NSPoint(x: labelX + fixedLabelW - sizeSize.width, y: rowRect.midY - sizeSize.height / 2), withAttributes: sizeAttrs)

            optionsStrokeSliderRect = NSRect(x: curX - 4, y: rowRect.minY, width: sliderW + 8, height: rowH)
            curX += sliderW + 12 + fixedLabelW + 8

            // Separator
            if showLineStyle || currentTool == .pencil || currentTool == .rectangle {
                NSColor.white.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: NSRect(x: curX - 6, y: rowRect.minY + 7, width: 1, height: rowH - 14), xRadius: 0.5, yRadius: 0.5).fill()
            }
        }

        // ── Line style segment control ──
        if showLineStyle {
            let segH: CGFloat = 22
            let segW: CGFloat = 36
            let segY = rowRect.midY - segH / 2
            let totalW = segW * CGFloat(LineStyle.allCases.count)

            // Segment background
            let segBgRect = NSRect(x: curX, y: segY, width: totalW, height: segH)
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: segBgRect, xRadius: 5, yRadius: 5).fill()

            for (i, style) in LineStyle.allCases.enumerated() {
                let btnRect = NSRect(x: curX + CGFloat(i) * segW, y: segY, width: segW, height: segH)
                optionsLineStyleRects.append(btnRect)

                let isActive = currentLineStyle == style
                if isActive {
                    ToolbarLayout.accentColor.withAlphaComponent(0.45).setFill()
                    NSBezierPath(roundedRect: btnRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4).fill()
                }

                // Line style preview
                let previewPath = NSBezierPath()
                previewPath.lineWidth = 2
                previewPath.lineCapStyle = .round
                style.apply(to: previewPath)
                NSColor.white.withAlphaComponent(isActive ? 0.9 : 0.35).setStroke()
                previewPath.move(to: NSPoint(x: btnRect.minX + 7, y: btnRect.midY))
                previewPath.line(to: NSPoint(x: btnRect.maxX - 7, y: btnRect.midY))
                previewPath.stroke()
            }

            curX += totalW + 10

            // Separator
            if currentTool == .rectangle || currentTool == .ellipse || currentTool == .arrow {
                NSColor.white.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: NSRect(x: curX - 5, y: rowRect.minY + 7, width: 1, height: rowH - 14), xRadius: 0.5, yRadius: 0.5).fill()
            }
        }

        // ── Arrow style segment control ──
        if currentTool == .arrow {
            optionsArrowStyleRects = []
            let segH: CGFloat = 22
            let segW: CGFloat = 36
            let segY = rowRect.midY - segH / 2
            let totalW = segW * CGFloat(ArrowStyle.allCases.count)

            let segBgRect = NSRect(x: curX, y: segY, width: totalW, height: segH)
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: segBgRect, xRadius: 5, yRadius: 5).fill()

            for (i, style) in ArrowStyle.allCases.enumerated() {
                let btnRect = NSRect(x: curX + CGFloat(i) * segW, y: segY, width: segW, height: segH)
                optionsArrowStyleRects.append(btnRect)

                let isActive = currentArrowStyle == style
                if isActive {
                    ToolbarLayout.accentColor.withAlphaComponent(0.45).setFill()
                    NSBezierPath(roundedRect: btnRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4).fill()
                }

                drawArrowStylePreview(style: style, in: btnRect, active: isActive)
            }

            curX += totalW + 10
        }

        // ── Shape fill style segment control ──
        if currentTool == .rectangle || currentTool == .ellipse {
            optionsRectFillStyleRects = []
            let segH: CGFloat = 22
            let segW: CGFloat = 28
            let segY = rowRect.midY - segH / 2
            let totalW = segW * CGFloat(RectFillStyle.allCases.count)

            let segBgRect = NSRect(x: curX, y: segY, width: totalW, height: segH)
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: segBgRect, xRadius: 5, yRadius: 5).fill()

            for (i, style) in RectFillStyle.allCases.enumerated() {
                let btnRect = NSRect(x: curX + CGFloat(i) * segW, y: segY, width: segW, height: segH)
                optionsRectFillStyleRects.append(btnRect)

                let isActive = currentRectFillStyle == style
                if isActive {
                    ToolbarLayout.accentColor.withAlphaComponent(0.45).setFill()
                    NSBezierPath(roundedRect: btnRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 4, yRadius: 4).fill()
                }

                drawShapeFillStylePreview(style: style, in: btnRect, active: isActive, oval: currentTool == .ellipse)
            }

            curX += totalW + 10

            // Separator before corner radius (rect only)
            if currentTool == .rectangle {
                NSColor.white.withAlphaComponent(0.08).setFill()
                NSBezierPath(roundedRect: NSRect(x: curX - 5, y: rowRect.minY + 7, width: 1, height: rowH - 14), xRadius: 0.5, yRadius: 0.5).fill()
            }
        }

        // ── Pill toggles ──
        if currentTool == .pencil {
            curX = drawOptionsPillToggle(label: "Smooth", isOn: pencilSmoothEnabled, x: curX, rowRect: rowRect, targetRect: &optionsSmoothToggleRect)
        }

        // ── Corner radius slider (rect tools) ──
        if currentTool == .rectangle {
            let label = "Radius" as NSString
            let lblAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
            ]
            let lSize = label.size(withAttributes: lblAttrs)
            label.draw(at: NSPoint(x: curX, y: rowRect.midY - lSize.height / 2), withAttributes: lblAttrs)
            curX += lSize.width + 6

            let crSliderW: CGFloat = 70
            let crSliderRect = NSRect(x: curX, y: rowRect.minY + 4, width: crSliderW, height: rowH - 8)
            optionsCornerRadiusSliderRect = crSliderRect
            drawOptionsSlider(rect: crSliderRect, value: currentRectCornerRadius, min: 0, max: 30)

            // Value label
            let valStr = "\(Int(currentRectCornerRadius))" as NSString
            let valAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.5),
            ]
            let valSize = valStr.size(withAttributes: valAttrs)
            valStr.draw(at: NSPoint(x: curX + crSliderW + 10, y: rowRect.midY - valSize.height / 2), withAttributes: valAttrs)
            curX += crSliderW + 10 + valSize.width + 8
        }
    }

    /// Curated font families for the font picker
    private static let fontFamilies: [String] = {
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

    private func renderEmoji(_ emoji: String, size: CGFloat = 128) -> NSImage {
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

    private func loadStampImage() {
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

    private func drawEmojiPicker() {
        let cats = Self.emojiCategories
        guard emojiPickerCategoryIndex < cats.count else { return }
        let emojis = cats[emojiPickerCategoryIndex].1
        let cols = 8
        let rows = (emojis.count + cols - 1) / cols
        let cellSize: CGFloat = 32
        let padding: CGFloat = 8
        let tabH: CGFloat = 30
        let pickerW = padding * 2 + CGFloat(cols) * cellSize
        let pickerH = padding + tabH + CGFloat(rows) * cellSize + padding

        // Position above the "More" button
        let anchorRect = stampMoreRect.isEmpty ? optionsRowRect : stampMoreRect
        let pickerX = max(bounds.minX + 4, min(anchorRect.midX - pickerW / 2, bounds.maxX - pickerW - 4))
        var pickerY: CGFloat
        if optionsRowRect.midY < selectionRect.midY {
            pickerY = optionsRowRect.minY - pickerH - 4
            if pickerY < bounds.minY + 4 { pickerY = optionsRowRect.maxY + 4 }
        } else {
            pickerY = optionsRowRect.maxY + 4
            if pickerY + pickerH > bounds.maxY - 4 { pickerY = optionsRowRect.minY - pickerH - 4 }
        }
        pickerY = max(bounds.minY + 4, min(pickerY, bounds.maxY - pickerH - 4))

        let pRect = NSRect(x: pickerX, y: pickerY, width: pickerW, height: pickerH)
        emojiPickerRect = pRect

        // Background
        NSColor(white: 0.10, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: pRect, xRadius: 8, yRadius: 8).fill()
        NSColor.white.withAlphaComponent(0.1).setStroke()
        let border = NSBezierPath(roundedRect: pRect, xRadius: 8, yRadius: 8)
        border.lineWidth = 0.5
        border.stroke()

        // Category tabs
        emojiPickerCategoryRects = []
        let tabW = (pickerW - padding * 2) / CGFloat(cats.count)
        let tabY = pRect.maxY - padding - tabH
        for (i, cat) in cats.enumerated() {
            let tabRect = NSRect(x: pRect.minX + padding + CGFloat(i) * tabW, y: tabY, width: tabW, height: tabH)
            emojiPickerCategoryRects.append(tabRect)

            if i == emojiPickerCategoryIndex {
                ToolbarLayout.accentColor.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: tabRect.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
            }

            let tabStr = cat.0 as NSString
            let tabAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16)]
            let tabSize = tabStr.size(withAttributes: tabAttrs)
            tabStr.draw(at: NSPoint(x: tabRect.midX - tabSize.width / 2, y: tabRect.midY - tabSize.height / 2), withAttributes: tabAttrs)
        }

        // Separator
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: NSRect(x: pRect.minX + padding, y: tabY - 1, width: pickerW - padding * 2, height: 0.5)).fill()

        // Emoji grid
        emojiPickerItemRects = []
        for (i, emoji) in emojis.enumerated() {
            let col = i % cols
            let row = i / cols
            let cx = pRect.minX + padding + CGFloat(col) * cellSize
            let cy = tabY - 4 - cellSize - CGFloat(row) * cellSize
            let cellRect = NSRect(x: cx, y: cy, width: cellSize, height: cellSize)
            emojiPickerItemRects.append(cellRect)

            let str = emoji as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22)]
            let size = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: cellRect.midX - size.width / 2, y: cellRect.midY - size.height / 2), withAttributes: attrs)
        }
    }

    private func drawStampOptionsRow(in rowRect: NSRect) {
        stampEmojiRects = []
        stampMoreRect = .zero
        stampLoadRect = .zero

        let pad: CGFloat = 8
        var curX = rowRect.minX + pad
        let btnSize: CGFloat = 26
        let gap: CGFloat = 2
        let btnY = rowRect.midY - btnSize / 2

        // Common emoji buttons
        for emoji in Self.commonEmojis {
            let btnRect = NSRect(x: curX, y: btnY, width: btnSize, height: btnSize)
            stampEmojiRects.append(btnRect)

            // Highlight if this emoji is the current stamp
            if currentStampEmoji == emoji {
                ToolbarLayout.accentColor.withAlphaComponent(0.45).setFill()
                NSBezierPath(roundedRect: btnRect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
            }

            let str = emoji as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18)]
            let size = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: btnRect.midX - size.width / 2, y: btnRect.midY - size.height / 2), withAttributes: attrs)
            curX += btnSize + gap
        }

        // Separator
        curX += 4
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: NSRect(x: curX - 3, y: rowRect.minY + 7, width: 1, height: rowRect.height - 14), xRadius: 0.5, yRadius: 0.5).fill()
        curX += 4

        // "More" button (opens system emoji picker)
        let moreBtnW: CGFloat = 30
        let moreRect = NSRect(x: curX, y: btnY, width: moreBtnW, height: btnSize)
        stampMoreRect = moreRect
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: moreRect, xRadius: 4, yRadius: 4).fill()
        let moreStr = "☺︎" as NSString
        let moreAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]
        let moreSize = moreStr.size(withAttributes: moreAttrs)
        moreStr.draw(at: NSPoint(x: moreRect.midX - moreSize.width / 2, y: moreRect.midY - moreSize.height / 2), withAttributes: moreAttrs)
        curX += moreBtnW + gap

        // "Load Image" button
        let loadBtnW: CGFloat = 30
        let loadRect = NSRect(x: curX, y: btnY, width: loadBtnW, height: btnSize)
        stampLoadRect = loadRect
        NSColor.white.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: loadRect, xRadius: 4, yRadius: 4).fill()
        drawTopBarIcon("photo.badge.plus", in: loadRect, selected: false)
    }

    private func drawRedactOptionsRow(in rowRect: NSRect) {
        let btnH: CGFloat = 22
        let btnY = rowRect.midY - btnH / 2
        let btnRadius: CGFloat = 4
        var curX = rowRect.minX + 10

        let toolName = currentTool == .pixelate ? "Pixelate" : "Blur"
        let btnFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let btnAttrs: [NSAttributedString.Key: Any] = [.font: btnFont, .foregroundColor: NSColor.white]

        // "\(tool) All Text" button (first)
        let allLabel = "\(toolName) All Text" as NSString
        let allSize = allLabel.size(withAttributes: btnAttrs)
        let allBtnW = allSize.width + 14
        let allRect = NSRect(x: curX, y: btnY, width: allBtnW, height: btnH)
        redactAllTextBtnRect = allRect

        let allAlpha: CGFloat = pressedRedactBtn == 0 ? 1.0 : (hoveredRedactBtn == 0 ? 0.85 : 0.7)
        ToolbarLayout.accentColor.withAlphaComponent(allAlpha).setFill()
        NSBezierPath(roundedRect: allRect, xRadius: btnRadius, yRadius: btnRadius).fill()
        allLabel.draw(at: NSPoint(x: allRect.midX - allSize.width / 2, y: allRect.midY - allSize.height / 2),
                      withAttributes: btnAttrs)
        curX += allBtnW + 6

        // "Auto-Redact PII" button (second)
        let piiLabel = "Auto-Redact PII" as NSString
        let piiSize = piiLabel.size(withAttributes: btnAttrs)
        let piiBtnW = piiSize.width + 14
        let piiRect = NSRect(x: curX, y: btnY, width: piiBtnW, height: btnH)
        redactPIIBtnRect = piiRect

        let piiAlpha: CGFloat = pressedRedactBtn == 1 ? 0.25 : (hoveredRedactBtn == 1 ? 0.18 : 0.1)
        NSColor.white.withAlphaComponent(piiAlpha).setFill()
        NSBezierPath(roundedRect: piiRect, xRadius: btnRadius, yRadius: btnRadius).fill()
        piiLabel.draw(at: NSPoint(x: piiRect.midX - piiSize.width / 2, y: piiRect.midY - piiSize.height / 2),
                      withAttributes: btnAttrs)
        curX += piiBtnW + 8

        // Separator
        NSColor.white.withAlphaComponent(0.1).setFill()
        NSBezierPath(rect: NSRect(x: curX, y: rowRect.minY + 7, width: 0.5, height: rowRect.height - 14)).fill()
        curX += 8

        // Redact type dropdown button (shows what types are active)
        let enabledTypes = UserDefaults.standard.array(forKey: "enabledRedactTypes") as? [String]
            ?? OverlayView.redactTypeNames.map { $0.key }
        let activeCount = enabledTypes.count
        let totalCount = OverlayView.redactTypeNames.count
        let dropLabel = "\(activeCount)/\(totalCount) types ▾" as NSString
        let dropAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]
        let dropSize = dropLabel.size(withAttributes: dropAttrs)
        let dropBtnW = dropSize.width + 12
        let dropRect = NSRect(x: curX, y: btnY, width: dropBtnW, height: btnH)
        redactTypeDropdownRect = dropRect

        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: dropRect, xRadius: btnRadius, yRadius: btnRadius).fill()
        dropLabel.draw(at: NSPoint(x: dropRect.midX - dropSize.width / 2, y: dropRect.midY - dropSize.height / 2),
                       withAttributes: dropAttrs)
    }

    private func drawTextOptionsRow(in rowRect: NSRect) {
        let pad: CGFloat = 8
        var curX = rowRect.minX + pad
        let btnH: CGFloat = 22
        let btnW: CGFloat = 24
        let btnY = rowRect.midY - btnH / 2

        let activeColor = ToolbarLayout.accentColor
        let inactiveColor = NSColor.white.withAlphaComponent(0.6)

        // ── Font family dropdown ──
        let displayFamily = textFontFamily == "System" ? "System" : textFontFamily
        let ddAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let ddSize = (displayFamily as NSString).size(withAttributes: ddAttrs)
        let ddW = max(60, ddSize.width + 22)  // space for text + chevron
        let ddRect = NSRect(x: curX, y: btnY, width: ddW, height: btnH)
        textFontDropdownRect = ddRect

        // Background
        let ddBg = showFontPicker ? activeColor.withAlphaComponent(0.3) : NSColor.white.withAlphaComponent(0.08)
        ddBg.setFill()
        NSBezierPath(roundedRect: ddRect, xRadius: 4, yRadius: 4).fill()

        // Family name
        (displayFamily as NSString).draw(
            at: NSPoint(x: ddRect.minX + 6, y: ddRect.midY - ddSize.height / 2),
            withAttributes: ddAttrs)

        // Chevron
        let chevAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]
        let chevStr = "▼" as NSString
        let chevSize = chevStr.size(withAttributes: chevAttrs)
        chevStr.draw(at: NSPoint(x: ddRect.maxX - chevSize.width - 5, y: ddRect.midY - chevSize.height / 2), withAttributes: chevAttrs)

        curX += ddW + 8

        // ── Separator ──
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: NSRect(x: curX - 4, y: rowRect.minY + 7, width: 1, height: rowRect.height - 14), xRadius: 0.5, yRadius: 0.5).fill()

        // ── Bold ──
        let boldRect = NSRect(x: curX, y: btnY, width: btnW, height: btnH)
        textBoldRect = boldRect
        drawTextFormatButton(rect: boldRect, label: "B", font: NSFont.systemFont(ofSize: 12, weight: .bold),
                             active: textBold, activeColor: activeColor, inactiveColor: inactiveColor)
        curX += btnW + 2

        // ── Italic ──
        let italicRect = NSRect(x: curX, y: btnY, width: btnW, height: btnH)
        textItalicRect = italicRect
        let italicFont = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        drawTextFormatButton(rect: italicRect, label: "I", font: italicFont,
                             active: textItalic, activeColor: activeColor, inactiveColor: inactiveColor)
        curX += btnW + 2

        // ── Underline ──
        let ulRect = NSRect(x: curX, y: btnY, width: btnW, height: btnH)
        textUnderlineRect = ulRect
        drawTextFormatButtonAttributed(rect: ulRect, label: "U", font: NSFont.systemFont(ofSize: 12),
                                       active: textUnderline, activeColor: activeColor, inactiveColor: inactiveColor,
                                       extraAttrs: [.underlineStyle: NSUnderlineStyle.single.rawValue])
        curX += btnW + 2

        // ── Strikethrough ──
        let stRect = NSRect(x: curX, y: btnY, width: btnW, height: btnH)
        textStrikethroughRect = stRect
        drawTextFormatButtonAttributed(rect: stRect, label: "S", font: NSFont.systemFont(ofSize: 12),
                                       active: textStrikethrough, activeColor: activeColor, inactiveColor: inactiveColor,
                                       extraAttrs: [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
        curX += btnW + 8

        // ── Separator ──
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: NSRect(x: curX - 4, y: rowRect.minY + 7, width: 1, height: rowRect.height - 14), xRadius: 0.5, yRadius: 0.5).fill()

        // ── Alignment buttons ──
        textAlignLeftRect = .zero; textAlignCenterRect = .zero; textAlignRightRect = .zero
        let alignSymbols = [("text.alignleft", NSTextAlignment.left), ("text.aligncenter", NSTextAlignment.center), ("text.alignright", NSTextAlignment.right)]
        for (symbol, align) in alignSymbols {
            let aRect = NSRect(x: curX, y: btnY, width: btnW, height: btnH)
            if align == .left { textAlignLeftRect = aRect }
            else if align == .center { textAlignCenterRect = aRect }
            else { textAlignRightRect = aRect }
            let isActive = textAlignment == align
            if isActive {
                activeColor.setFill()
                NSBezierPath(roundedRect: aRect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            }
            drawTopBarIcon(symbol, in: aRect, selected: isActive)
            curX += btnW + 2
        }
        curX += 6

        // ── Separator ──
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: NSRect(x: curX - 4, y: rowRect.minY + 7, width: 1, height: rowRect.height - 14), xRadius: 0.5, yRadius: 0.5).fill()

        // ── Text background toggle ──
        curX = drawTextStyleToggle(label: "Fill", color: textBgColorValue, enabled: textBgEnabled,
                                   x: curX, rowRect: rowRect, targetRect: &textBgToggleRect)
        curX += 4

        // ── Text outline toggle ──
        curX = drawTextStyleToggle(label: "Outline", color: textOutlineColorValue, enabled: textOutlineEnabled,
                                   x: curX, rowRect: rowRect, targetRect: &textOutlineToggleRect)
        curX += 8

        // ── Separator ──
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: NSRect(x: curX - 4, y: rowRect.minY + 7, width: 1, height: rowRect.height - 14), xRadius: 0.5, yRadius: 0.5).fill()

        // ── Font size controls ──
        let minusRect = NSRect(x: curX, y: btnY, width: 20, height: btnH)
        textSizeDecRect = minusRect
        drawTextFormatButton(rect: minusRect, label: "−", font: NSFont.systemFont(ofSize: 14, weight: .medium),
                             active: false, activeColor: activeColor, inactiveColor: inactiveColor)
        curX += 20

        // Size label
        let sizeStr = "\(Int(textFontSize))" as NSString
        let sizeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]
        let sizeSize = sizeStr.size(withAttributes: sizeAttrs)
        let sizeLabelW: CGFloat = 26
        sizeStr.draw(at: NSPoint(x: curX + (sizeLabelW - sizeSize.width) / 2, y: rowRect.midY - sizeSize.height / 2), withAttributes: sizeAttrs)
        curX += sizeLabelW

        let plusRect = NSRect(x: curX, y: btnY, width: 20, height: btnH)
        textSizeIncRect = plusRect
        drawTextFormatButton(rect: plusRect, label: "+", font: NSFont.systemFont(ofSize: 14, weight: .medium),
                             active: false, activeColor: activeColor, inactiveColor: inactiveColor)
        curX += 20 + 8

        // ── Separator ──
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: NSRect(x: curX - 4, y: rowRect.minY + 7, width: 1, height: rowRect.height - 14), xRadius: 0.5, yRadius: 0.5).fill()

        // ── Cancel / Confirm (only when editing) ──
        if textEditView != nil {
            let cancelRect = NSRect(x: curX, y: btnY, width: btnW, height: btnH)
            textCancelRect = cancelRect
            drawTextFormatButton(rect: cancelRect, label: "✕", font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                 active: false, activeColor: .systemRed, inactiveColor: .systemRed.withAlphaComponent(0.7))
            curX += btnW + 2

            let confirmRect = NSRect(x: curX, y: btnY, width: btnW, height: btnH)
            textConfirmRect = confirmRect
            drawTextFormatButton(rect: confirmRect, label: "✓", font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                 active: false, activeColor: .systemGreen, inactiveColor: .systemGreen.withAlphaComponent(0.7))
        }

        // ── Font picker dropdown ──
        if showFontPicker {
            drawFontPickerDropdown()
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
            let downY = optionsRowRect.minY - pickerH - 2
            pickerY = downY >= bounds.minY + 4 ? downY : optionsRowRect.maxY + 2
        } else {
            // Toolbar is above selection — try opening upward
            let upY = optionsRowRect.maxY + 2
            pickerY = (upY + pickerH) <= bounds.maxY - 4 ? upY : optionsRowRect.minY - pickerH - 2
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
    @discardableResult
    private func drawOptionsPillToggle(label: String, isOn: Bool, x: CGFloat, rowRect: NSRect, targetRect: inout NSRect) -> CGFloat {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]
        var curX = x
        let lStr = label as NSString
        let lSize = lStr.size(withAttributes: labelAttrs)
        lStr.draw(at: NSPoint(x: curX, y: rowRect.midY - lSize.height / 2), withAttributes: labelAttrs)
        curX += lSize.width + 5

        // Pill switch
        let pillW: CGFloat = 28
        let pillH: CGFloat = 16
        let pillRect = NSRect(x: curX, y: rowRect.midY - pillH / 2, width: pillW, height: pillH)
        targetRect = pillRect

        // Track
        let trackColor = isOn ? ToolbarLayout.accentColor : NSColor.white.withAlphaComponent(0.15)
        trackColor.setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: pillH / 2, yRadius: pillH / 2).fill()

        // Knob
        let knobInset: CGFloat = 2
        let knobD = pillH - knobInset * 2
        let knobX = isOn ? pillRect.maxX - knobD - knobInset : pillRect.minX + knobInset
        let knobRect = NSRect(x: knobX, y: pillRect.minY + knobInset, width: knobD, height: knobD)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()

        curX += pillW + 10
        return curX
    }

    private func drawArrowStylePreview(style: ArrowStyle, in rect: NSRect, active: Bool) {
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

    private func drawShapeFillStylePreview(style: RectFillStyle, in rect: NSRect, active: Bool, oval: Bool) {
        let color = NSColor.white.withAlphaComponent(active ? 0.9 : 0.35)
        let inset: CGFloat = 6
        let previewRect = rect.insetBy(dx: inset, dy: inset + 1)

        func shapePath() -> NSBezierPath {
            oval ? NSBezierPath(ovalIn: previewRect) : NSBezierPath(roundedRect: previewRect, xRadius: 2, yRadius: 2)
        }

        switch style {
        case .stroke:
            color.setStroke()
            let path = shapePath()
            path.lineWidth = 1.5
            path.stroke()

        case .strokeAndFill:
            color.withAlphaComponent((active ? 0.9 : 0.35) * 0.4).setFill()
            shapePath().fill()
            color.setStroke()
            let path = shapePath()
            path.lineWidth = 1.5
            path.stroke()

        case .fill:
            color.setFill()
            shapePath().fill()
        }
    }

    private func drawBeautifyOptionsRow(in rowRect: NSRect) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]
        let pad: CGFloat = 8
        var curX = rowRect.minX + pad

        // Mode toggle: W / R
        let modeW: CGFloat = 26
        let modeH: CGFloat = 20
        let modeY = rowRect.midY - modeH / 2

        let wRect = NSRect(x: curX, y: modeY, width: modeW, height: modeH)
        beautifyModeWindowRect = wRect
        (beautifyMode == .window ? ToolbarLayout.accentColor.withAlphaComponent(0.6) : NSColor.white.withAlphaComponent(0.12)).setFill()
        NSBezierPath(roundedRect: wRect, xRadius: 4, yRadius: 4).fill()
        let wAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.white]
        let wStr = "W" as NSString
        let wSize = wStr.size(withAttributes: wAttrs)
        wStr.draw(at: NSPoint(x: wRect.midX - wSize.width / 2, y: wRect.midY - wSize.height / 2), withAttributes: wAttrs)
        curX += modeW + 2

        let rRect = NSRect(x: curX, y: modeY, width: modeW, height: modeH)
        beautifyModeRoundedRect = rRect
        (beautifyMode == .rounded ? ToolbarLayout.accentColor.withAlphaComponent(0.6) : NSColor.white.withAlphaComponent(0.12)).setFill()
        NSBezierPath(roundedRect: rRect, xRadius: 4, yRadius: 4).fill()
        let rStr = "R" as NSString
        let rSize = rStr.size(withAttributes: wAttrs)
        rStr.draw(at: NSPoint(x: rRect.midX - rSize.width / 2, y: rRect.midY - rSize.height / 2), withAttributes: wAttrs)
        curX += modeW + 8

        // Separator
        NSColor.white.withAlphaComponent(0.2).setFill()
        NSBezierPath(rect: NSRect(x: curX, y: rowRect.minY + 6, width: 1, height: rowRect.height - 12)).fill()
        curX += 6

        // Compact sliders: Pad, Radius, Shadow, BgR
        let sliderW: CGFloat = 60
        let sliderH: CGFloat = rowRect.height - 8
        let sliderY = rowRect.minY + 4

        let sliderDefs: [(String, CGFloat, CGFloat, CGFloat)] = [
            ("Padding", beautifyPadding, 16, 96),
            ("Radius", beautifyCornerRadius, 0, 30),
            ("Shadow", beautifyShadowRadius, 0, 40),
        ]

        var sliderRects: [NSRect] = []
        for (label, value, minV, maxV) in sliderDefs {
            let lStr = label as NSString
            let lSize = lStr.size(withAttributes: labelAttrs)
            lStr.draw(at: NSPoint(x: curX, y: rowRect.midY - lSize.height / 2), withAttributes: labelAttrs)
            curX += lSize.width + 5
            let sr = NSRect(x: curX, y: sliderY, width: sliderW, height: sliderH)
            sliderRects.append(sr)
            drawOptionsSlider(rect: sr, value: value, min: minV, max: maxV)
            curX += sliderW + 10
        }
        beautifyPaddingSliderRect = sliderRects[0]
        beautifyCornerSliderRect = sliderRects[1]
        beautifyShadowSliderRect = sliderRects[2]

        // Separator
        NSColor.white.withAlphaComponent(0.2).setFill()
        NSBezierPath(rect: NSRect(x: curX, y: rowRect.minY + 6, width: 1, height: rowRect.height - 12)).fill()
        curX += 6

        // Gradient picker button — shows current gradient, opens grid popover on click
        let btnSize: CGFloat = 22
        let btnRect = NSRect(x: curX, y: rowRect.midY - btnSize / 2, width: btnSize, height: btnSize)

        let currentStyle = BeautifyRenderer.styles[beautifyStyleIndex % BeautifyRenderer.styles.count]
        let btnPath = NSBezierPath(roundedRect: btnRect, xRadius: 5, yRadius: 5)
        drawStyleSwatch(style: currentStyle, path: btnPath, rect: btnRect)
        // Selection ring
        ToolbarLayout.accentColor.setStroke()
        let ring = NSBezierPath(roundedRect: btnRect.insetBy(dx: -1.5, dy: -1.5), xRadius: 6, yRadius: 6)
        ring.lineWidth = 1.5
        ring.stroke()

        // Dropdown triangle
        let triAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]
        let triStr = "▾" as NSString
        let triSize = triStr.size(withAttributes: triAttrs)
        let triX = btnRect.maxX + 6
        triStr.draw(at: NSPoint(x: triX, y: btnRect.midY - triSize.height / 2), withAttributes: triAttrs)

        // Hit rect covers swatch + triangle
        beautifyGradientBtnRect = NSRect(x: btnRect.minX, y: btnRect.minY, width: triX + triSize.width - btnRect.minX, height: btnRect.height)

        // On/off toggle switch — far right
        let toggleW: CGFloat = 36
        let toggleH: CGFloat = 20
        let toggleX = rowRect.maxX - pad - toggleW
        let toggleY = rowRect.midY - toggleH / 2
        let toggleRect = NSRect(x: toggleX, y: toggleY, width: toggleW, height: toggleH)
        beautifyToggleRect = toggleRect

        let trackPath = NSBezierPath(roundedRect: toggleRect, xRadius: toggleH / 2, yRadius: toggleH / 2)
        (beautifyEnabled ? ToolbarLayout.accentColor : NSColor.white.withAlphaComponent(0.2)).setFill()
        trackPath.fill()

        let knobInset: CGFloat = 2
        let knobD = toggleH - knobInset * 2
        let knobX = beautifyEnabled ? toggleRect.maxX - knobD - knobInset : toggleRect.minX + knobInset
        let knobRect = NSRect(x: knobX, y: toggleY + knobInset, width: knobD, height: knobD)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }

    private func drawBeautifyGradientPicker() {
        let styles = BeautifyRenderer.styles
        let cols = 6
        let rows = (styles.count + cols - 1) / cols
        let swSize: CGFloat = 28
        let padding: CGFloat = 8
        let gap: CGFloat = 4
        let pickerW = padding * 2 + CGFloat(cols) * swSize + CGFloat(cols - 1) * gap
        let pickerH = padding * 2 + CGFloat(rows) * swSize + CGFloat(rows - 1) * gap

        // Position above/below the gradient button
        let anchorRect = beautifyGradientBtnRect
        let pickerX = max(bounds.minX + 4, min(anchorRect.midX - pickerW / 2, bounds.maxX - pickerW - 4))
        var pickerY: CGFloat
        if optionsRowRect.midY < selectionRect.midY {
            pickerY = optionsRowRect.minY - pickerH - 4
            if pickerY < bounds.minY + 4 { pickerY = optionsRowRect.maxY + 4 }
        } else {
            pickerY = optionsRowRect.maxY + 4
            if pickerY + pickerH > bounds.maxY - 4 { pickerY = optionsRowRect.minY - pickerH - 4 }
        }
        pickerY = max(bounds.minY + 4, min(pickerY, bounds.maxY - pickerH - 4))

        let pRect = NSRect(x: pickerX, y: pickerY, width: pickerW, height: pickerH)
        beautifyGradientPickerRect = pRect

        // Background
        NSColor(white: 0.10, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: pRect, xRadius: 8, yRadius: 8).fill()
        NSColor.white.withAlphaComponent(0.1).setStroke()
        let border = NSBezierPath(roundedRect: pRect, xRadius: 8, yRadius: 8)
        border.lineWidth = 0.5
        border.stroke()

        // Draw gradient swatches in grid
        beautifySwatchRects = []
        for (i, style) in styles.enumerated() {
            let col = i % cols
            let row = i / cols
            let sx = pRect.minX + padding + CGFloat(col) * (swSize + gap)
            let sy = pRect.maxY - padding - swSize - CGFloat(row) * (swSize + gap)
            let sr = NSRect(x: sx, y: sy, width: swSize, height: swSize)
            beautifySwatchRects.append(sr)

            let path = NSBezierPath(roundedRect: sr, xRadius: 6, yRadius: 6)
            drawStyleSwatch(style: style, path: path, rect: sr)

            if i == beautifyStyleIndex % styles.count {
                ToolbarLayout.accentColor.setStroke()
                let selRing = NSBezierPath(roundedRect: sr.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7)
                selRing.lineWidth = 2
                selRing.stroke()
            }
        }
    }

    private func drawOptionsSlider(rect: NSRect, value: CGFloat, min minVal: CGFloat, max maxVal: CGFloat) {
        let trackH: CGFloat = 3
        let knobR: CGFloat = 6
        let trackY = rect.midY - trackH / 2
        let trackRect = NSRect(x: rect.minX, y: trackY, width: rect.width, height: trackH)

        NSColor.white.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: 1.5, yRadius: 1.5).fill()

        let frac = max(0, min(1, (value - minVal) / (maxVal - minVal)))
        let filledW = rect.width * frac
        let filledRect = NSRect(x: rect.minX, y: trackY, width: filledW, height: trackH)
        ToolbarLayout.accentColor.setFill()
        NSBezierPath(roundedRect: filledRect, xRadius: 1.5, yRadius: 1.5).fill()

        let knobX = rect.minX + filledW
        let knobRect = NSRect(x: knobX - knobR, y: rect.midY - knobR, width: knobR * 2, height: knobR * 2)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }

    @discardableResult
    private func drawOptionsToggle(label: String, isOn: Bool, x: CGFloat, rowRect: NSRect, targetRect: inout NSRect) -> CGFloat {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ]
        var curX = x
        let lStr = label as NSString
        let lSize = lStr.size(withAttributes: labelAttrs)
        lStr.draw(at: NSPoint(x: curX, y: rowRect.midY - lSize.height / 2), withAttributes: labelAttrs)
        curX += lSize.width + 4

        let checkSize: CGFloat = 14
        let checkRect = NSRect(x: curX, y: rowRect.midY - checkSize / 2, width: checkSize, height: checkSize)
        targetRect = checkRect

        NSColor.white.withAlphaComponent(isOn ? 0.9 : 0.25).setFill()
        NSBezierPath(roundedRect: checkRect, xRadius: 3, yRadius: 3).fill()
        if isOn {
            let tickAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
            let tick = "✓" as NSString
            let tickSize = tick.size(withAttributes: tickAttrs)
            tick.draw(at: NSPoint(x: checkRect.midX - tickSize.width / 2, y: checkRect.midY - tickSize.height / 2), withAttributes: tickAttrs)
        }
        curX += checkSize + 10
        return curX
    }

    private func updateOptionsStrokeSlider(at point: NSPoint) {
        let steps: [CGFloat] = currentTool == .loupe
            ? [60, 80, 100, 120, 160, 200, 250, 320]
            : [1, 2, 3, 5, 8, 12, 20]

        let sr = optionsStrokeSliderRect
        guard sr.width > 0 else { return }

        // Map position to nearest step
        let frac = max(0, min(1, (point.x - sr.minX - 4) / (sr.width - 8)))
        let idx = Int((frac * CGFloat(steps.count - 1)).rounded())
        let bestIdx = max(0, min(steps.count - 1, idx))
        let value = steps[bestIdx]
        switch currentTool {
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

    private func updateOptionsCornerRadius(at point: NSPoint) {
        let sr = optionsCornerRadiusSliderRect
        guard sr.width > 0 else { return }
        let frac = max(0, min(1, (point.x - sr.minX) / sr.width))
        let value = (frac * 30).rounded()
        currentRectCornerRadius = value
        UserDefaults.standard.set(Double(value), forKey: "currentRectCornerRadius")
        needsDisplay = true
    }

    private func startBeautifyToolbarAnimation() {
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

    private func updateBeautifySlider(at point: NSPoint) {
        let sliderRect: NSRect
        let minVal: CGFloat
        let maxVal: CGFloat
        let key: String

        switch activeBeautifySlider {
        case 0: sliderRect = beautifyPaddingSliderRect; minVal = 16; maxVal = 96; key = "beautifyPadding"
        case 1: sliderRect = beautifyCornerSliderRect; minVal = 0; maxVal = 30; key = "beautifyCornerRadius"
        case 2: sliderRect = beautifyShadowSliderRect; minVal = 0; maxVal = 40; key = "beautifyShadowRadius"
        default: return
        }

        let frac = max(0, min(1, (point.x - sliderRect.minX) / sliderRect.width))
        let value = minVal + frac * (maxVal - minVal)
        let rounded = (value * 2).rounded() / 2  // snap to 0.5 increments

        switch activeBeautifySlider {
        case 0: beautifyPadding = rounded
        case 1: beautifyCornerRadius = rounded
        case 2: beautifyShadowRadius = rounded
        default: break
        }

        UserDefaults.standard.set(Double(rounded), forKey: key)
        needsDisplay = true
    }

    private func drawStrokePicker() {
        let widths: [CGFloat] = [1, 2, 3, 5, 8, 12, 20]
        let rowH: CGFloat = 30
        let pickerWidth: CGFloat = 140
        let padding: CGFloat = 6
        let showSmoothToggle = (currentTool == .pencil)
        let showRoundedToggle = (currentTool == .rectangle)
        let showWidthRows = true
        let hasToggle = showSmoothToggle || showRoundedToggle
        let toggleRowH: CGFloat = hasToggle ? 32 : 0
        let separatorH: CGFloat = (hasToggle && showWidthRows) ? 5 : 0
        let widthRowsHeight = showWidthRows ? rowH * CGFloat(widths.count) : 0
        let pickerHeight = widthRowsHeight + padding * 2 + separatorH + toggleRowH

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

        if showWidthRows {
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

        // Rounded corners toggle (rectangle / filled rectangle)
        if showRoundedToggle {
            let sepY = pickerRect.minY + toggleRowH
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(rect: NSRect(x: pickerRect.minX + 8, y: sepY, width: pickerRect.width - 16, height: 1)).fill()

            let toggleRowRect = NSRect(x: pickerRect.minX, y: pickerRect.minY, width: pickerRect.width, height: toggleRowH)
            roundedRectToggleRect = toggleRowRect

            if hoveredStrokeRow == 99 {
                NSColor.white.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: toggleRowRect.insetBy(dx: 3, dy: 2), xRadius: 4, yRadius: 4).fill()
            }

            let toggleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let label = "Rounded corners" as NSString
            let labelSize = label.size(withAttributes: toggleAttrs)
            label.draw(at: NSPoint(x: toggleRowRect.minX + 10, y: toggleRowRect.midY - labelSize.height / 2), withAttributes: toggleAttrs)

            let checkSize: CGFloat = 14
            let checkX = toggleRowRect.maxX - checkSize - 10
            let checkY = toggleRowRect.midY - checkSize / 2
            let checkRect = NSRect(x: checkX, y: checkY, width: checkSize, height: checkSize)
            NSColor.white.withAlphaComponent(roundedRectEnabled ? 0.9 : 0.25).setFill()
            NSBezierPath(roundedRect: checkRect, xRadius: 3, yRadius: 3).fill()
            if roundedRectEnabled {
                let checkAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.black,
                ]
                let tick = "✓" as NSString
                let tickSize = tick.size(withAttributes: checkAttrs)
                tick.draw(at: NSPoint(x: checkRect.midX - tickSize.width / 2, y: checkRect.midY - tickSize.height / 2), withAttributes: checkAttrs)
            }
        } else {
            roundedRectToggleRect = .zero
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
            let tinted = NSImage(size: img.size, flipped: false) { rect in
                img.draw(in: rect)
                tintColor.setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
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
        let provider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"
        let titleText: String
        switch provider {
        case "gdrive": titleText = "Upload to Google Drive?"
        case "s3": titleText = "Upload to S3?"
        default: titleText = "Upload to imgbb.com?"
        }
        let title = titleText as NSString
        let titleSize = title.size(withAttributes: titleAttrs)
        title.draw(at: NSPoint(x: dialogRect.midX - titleSize.width / 2, y: dialogRect.maxY - 30), withAttributes: titleAttrs)

        // Subtitle
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]
        let subText: String
        switch provider {
        case "gdrive": subText = "Your screenshot will be saved to your Google Drive"
        case "s3": subText = "Your screenshot will be uploaded to your S3 bucket"
        default: subText = "Your screenshot will be sent to imgbb.com"
        }
        let sub = subText as NSString
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

        // Anchor to the dropdown button in the options row (or fallback to options row center)
        let anchorRect = redactTypeDropdownRect != .zero ? redactTypeDropdownRect : optionsRowRect

        let pickerX = max(bounds.minX + 4, anchorRect.midX - pickerWidth / 2)
        var pickerY: CGFloat
        if optionsRowRect.minY < selectionRect.midY {
            // Options row is below selection — open picker below dropdown
            pickerY = anchorRect.minY - pickerHeight - 4
            if pickerY < bounds.minY + 4 { pickerY = anchorRect.maxY + 4 }
        } else {
            // Options row is above selection — open picker above dropdown
            pickerY = anchorRect.maxY + 4
            if pickerY + pickerHeight > bounds.maxY - 4 { pickerY = anchorRect.minY - pickerHeight - 4 }
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
                let tinted = NSImage(size: img.size, flipped: false) { rect in
                    img.draw(in: rect)
                    tintColor.setFill()
                    rect.fill(using: .sourceAtop)
                    return true
                }
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

    private func copyColorAtSamplerPoint() {
        guard let screenshot = screenshotImage,
              let result = sampleColor(from: screenshot, at: colorSamplerPoint) else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.hex, forType: .string)
        showOverlayError("Copied \(result.hex)")
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
        // In editor mode, subtract the canvas centering offset
        var q = adjustPointForEditor(p)
        if zoomLevel == 1.0 && zoomAnchorCanvas == .zero && zoomAnchorView == .zero { return q }
        guard zoomAnchorCanvas != .zero || zoomAnchorView != .zero else { return q }
        return NSPoint(
            x: zoomAnchorCanvas.x + (q.x - zoomAnchorView.x) / zoomLevel,
            y: zoomAnchorCanvas.y + (q.y - zoomAnchorView.y) / zoomLevel
        )
    }

    func applyZoomTransform(to context: NSGraphicsContext) {
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
        editorCanvasOffset = .zero  // force recalculation on next draw
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

    func rebuildToolbarLayout() {
        let movableAnnotations = annotations.contains { $0.isMovable }
        bottomButtons = ToolbarLayout.bottomButtons(selectedTool: currentTool, selectedColor: currentColor, beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex, hasAnnotations: movableAnnotations, isRecording: isRecording, isAnnotating: isAnnotating)
        // When beautify options row is showing, deselect all tools and highlight beautify instead
        if showBeautifyInOptionsRow {
            for i in bottomButtons.indices {
                if case .tool = bottomButtons[i].action {
                    bottomButtons[i].isSelected = false
                } else if case .beautify = bottomButtons[i].action {
                    bottomButtons[i].isSelected = true
                }
            }
        }
        rightButtons = ToolbarLayout.rightButtons(delaySeconds: delaySeconds, beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex, hasAnnotations: movableAnnotations, translateEnabled: translateEnabled, isRecording: isRecording, isCapturingVideo: isCapturingVideo, isAnnotating: isAnnotating, isEditorMode: isEditorMode)

        // When beautify is active, anchor toolbars to the expanded preview frame
        // so they don't overlap the gradient/shadow chrome.
        // Animate the transition with easeOut interpolation.
        // Always compute the expanded anchor (for animation purposes — even when beautify is off)
        let config = beautifyConfig
        let pad = config.padding
        let titleBarH: CGFloat = config.mode == .window ? 28 : 0
        let expandedAnchor = NSRect(
            x: selectionRect.minX - pad,
            y: selectionRect.minY - pad,
            width: selectionRect.width + pad * 2,
            height: selectionRect.height + titleBarH + pad * 2
        )
        let showBeautifyFrame = beautifyEnabled && state == .selected && !isScrollCapturing && !isRecording

        // Interpolate between selectionRect and expandedAnchor during animation
        let anchorRect: NSRect
        if beautifyToolbarAnimProgress < 1.0 {
            // EaseOut: t' = 1 - (1-t)^2
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
        } else if showBeautifyFrame {
            anchorRect = expandedAnchor
        } else {
            anchorRect = selectionRect
        }

        // Place each toolbar inside if it would go off-screen
        let bottomMargin: CGFloat = 50  // toolbar height + gap
        let rightMargin: CGFloat = 50

        let bottomFits = anchorRect.minY > bounds.minY + bottomMargin
        let topFits = anchorRect.maxY < bounds.maxY - bottomMargin
        let bottomOutside = bottomFits || topFits  // layoutBottom handles flipping above if below doesn't fit

        // When placing toolbars "inside", use the actual selectionRect (not the
        // beautify-expanded anchorRect) so they stay within the visible area.
        let insideAnchor = selectionRect

        if bottomOutside {
            bottomBarRect = ToolbarLayout.layoutBottom(buttons: &bottomButtons, selectionRect: anchorRect, viewBounds: bounds)
        } else {
            bottomBarRect = ToolbarLayout.layoutBottomInside(buttons: &bottomButtons, selectionRect: insideAnchor, viewBounds: bounds)
        }

        let rightFits = anchorRect.maxX < bounds.maxX - rightMargin
        let leftFits = anchorRect.minX > bounds.minX + rightMargin
        let rightOutside = rightFits || leftFits  // layoutRight handles flipping to left if right doesn't fit

        if rightOutside {
            rightBarRect = ToolbarLayout.layoutRight(buttons: &rightButtons, selectionRect: anchorRect, viewBounds: bounds, bottomBarRect: bottomBarRect)
        } else {
            rightBarRect = ToolbarLayout.layoutRightInside(buttons: &rightButtons, selectionRect: insideAnchor, viewBounds: bounds, bottomBarRect: bottomBarRect)
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
        if isEditorMode {
            positionToolbarsForEditor()
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

        // Editor top bar button clicks
        if handleTopChromeClick(at: point) {
            return
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
            if customPickerGradientRect.contains(point) {
                isDraggingHSBGradient = true
                let color = colorFromHSBGradient(at: point)
                applyPickedColor(color)
                return
            }
            // Check brightness slider drag start
            if customPickerBrightnessRect.contains(point) {
                isDraggingBrightnessSlider = true
                updateBrightnessFromPoint(point)
                return
            }

            if let color = hitTestColorPicker(at: point) {
                applyPickedColor(color)
                if isTextEditing {
                    window?.makeFirstResponder(textEditView)
                }
                return
            }
            // If click is inside the color picker rect, don't dismiss
            if colorPickerRect.contains(point) {
                needsDisplay = true
                return
            }
            // If click is on the color button itself, let the toggle in handleToolbarAction handle it
            if let action = ToolbarLayout.hitTest(point: point, buttons: bottomButtons), case .color = action {
                // fall through — don't dismiss here, the button's .toggle() will close it
            } else if let bottomAction = ToolbarLayout.hitTest(point: point, buttons: bottomButtons),
                      case .tool(let t) = bottomAction, t == .colorSampler {
                // Clicked the color sampler tool — keep picker open, let the button handle tool switch
            } else if ToolbarLayout.hitTest(point: point, buttons: bottomButtons) != nil
                      || ToolbarLayout.hitTest(point: point, buttons: rightButtons) != nil {
                // Clicked a different toolbar button — close picker and let the button handle it
                showColorPicker = false
                colorPickerTarget = .drawColor
                needsDisplay = true
            } else {
                // Clicked on the screenshot — sample color, keep picker open
                if let screenshot = screenshotImage,
                   let result = sampleColor(from: screenshot, at: viewToCanvas(point)) {
                    applyPickedColor(result.color)
                    if selectedColorSlot >= 0 && selectedColorSlot < customColors.count - 1 {
                        selectedColorSlot += 1
                    }
                    showOverlayError("Set color \(result.hex)")
                }
                needsDisplay = true
                return
            }
        }

        // Beautify picker dismissal / selection
        if showBeautifyPicker {
            if beautifyPickerRect.contains(point) {
                // Mode buttons
                if beautifyModeWindowRect.contains(point) {
                    beautifyMode = .window
                    UserDefaults.standard.set(beautifyMode.rawValue, forKey: "beautifyMode")
                    needsDisplay = true
                    return
                }
                if beautifyModeRoundedRect.contains(point) {
                    beautifyMode = .rounded
                    UserDefaults.standard.set(beautifyMode.rawValue, forKey: "beautifyMode")
                    needsDisplay = true
                    return
                }
                // Sliders — start dragging
                if beautifyPaddingSliderRect.contains(point) {
                    isDraggingBeautifySlider = true
                    activeBeautifySlider = 0
                    updateBeautifySlider(at: point)
                    return
                }
                if beautifyCornerSliderRect.contains(point) {
                    isDraggingBeautifySlider = true
                    activeBeautifySlider = 1
                    updateBeautifySlider(at: point)
                    return
                }
                if beautifyShadowSliderRect.contains(point) {
                    isDraggingBeautifySlider = true
                    activeBeautifySlider = 2
                    updateBeautifySlider(at: point)
                    return
                }
                // Background swatches — use stored rects from draw
                for (i, swatchRect) in beautifySwatchRects.enumerated() {
                    if swatchRect.contains(point) {
                        beautifyStyleIndex = i
                        UserDefaults.standard.set(beautifyStyleIndex, forKey: "beautifyStyleIndex")
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
                // Rounded corners toggle (rectangle / filled rectangle)
                if currentTool == .rectangle && roundedRectToggleRect.contains(point) {
                    roundedRectEnabled.toggle()
                    UserDefaults.standard.set(roundedRectEnabled, forKey: "roundedRectEnabled")
                    needsDisplay = true
                    return
                }
                let widths: [CGFloat] = [1, 2, 3, 5, 8, 12, 20]
                let rowH: CGFloat = 30
                let padding: CGFloat = 2
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
                let padding: CGFloat = 2
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
                let padding: CGFloat = 2
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
                let padding: CGFloat = 2
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
            needsDisplay = true
            // If click was on the dropdown button, consume it so the toggle below doesn't reopen
            if redactTypeDropdownRect.contains(point) {
                return
            }
        }

        // Beautify gradient picker dismissal / selection
        if showBeautifyGradientPicker {
            if beautifyGradientPickerRect.contains(point) {
                for (i, sr) in beautifySwatchRects.enumerated() {
                    if sr.insetBy(dx: -2, dy: -2).contains(point) {
                        beautifyStyleIndex = i
                        UserDefaults.standard.set(beautifyStyleIndex, forKey: "beautifyStyleIndex")
                        // Don't close picker — let user try gradients quickly
                        needsDisplay = true
                        return
                    }
                }
                return  // clicked in picker but not on a swatch
            }
            showBeautifyGradientPicker = false
            needsDisplay = true
            if beautifyGradientBtnRect.insetBy(dx: -4, dy: -4).contains(point) {
                return  // consume so toggle doesn't reopen
            }
        }

        // Emoji picker dismissal / selection
        if showEmojiPicker {
            if emojiPickerRect.contains(point) {
                // Category tabs
                for (i, tabRect) in emojiPickerCategoryRects.enumerated() {
                    if tabRect.contains(point) {
                        emojiPickerCategoryIndex = i
                        needsDisplay = true
                        return
                    }
                }
                // Emoji cells
                let emojis = Self.emojiCategories[emojiPickerCategoryIndex].1
                for (i, cellRect) in emojiPickerItemRects.enumerated() {
                    if cellRect.contains(point), i < emojis.count {
                        currentStampImage = renderEmoji(emojis[i])
                        currentStampEmoji = emojis[i]
                        showEmojiPicker = false
                        needsDisplay = true
                        return
                    }
                }
                return  // clicked in picker but not on an item
            }
            showEmojiPicker = false
            needsDisplay = true
            if stampMoreRect.insetBy(dx: -4, dy: -4).contains(point) {
                return  // consume so toggle doesn't reopen
            }
        }

        // Translate language picker dismissal / selection
        if showTranslatePicker {
            if translatePickerRect.contains(point) {
                let langs = TranslationService.availableLanguages
                let rowH: CGFloat = 26
                let padding: CGFloat = 2
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
            (optionsRowRect.contains(point) || (showFontPicker && fontPickerRect.contains(point)))
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

                // Tool options row click handling
                if optionsRowRect.contains(point) {
                    // Beautify toggle & controls (check first — overrides tool options)
                    if showBeautifyInOptionsRow {
                        if beautifyToggleRect != .zero && beautifyToggleRect.insetBy(dx: -4, dy: -4).contains(point) {
                            beautifyEnabled.toggle()
                            UserDefaults.standard.set(beautifyEnabled, forKey: "beautifyEnabled")
                            startBeautifyToolbarAnimation()
                            needsDisplay = true
                            return
                        }
                        if beautifyModeWindowRect.contains(point) {
                            beautifyMode = .window; UserDefaults.standard.set(beautifyMode.rawValue, forKey: "beautifyMode"); needsDisplay = true; return
                        }
                        if beautifyModeRoundedRect.contains(point) {
                            beautifyMode = .rounded; UserDefaults.standard.set(beautifyMode.rawValue, forKey: "beautifyMode"); needsDisplay = true; return
                        }
                        for (idx, sr) in [beautifyPaddingSliderRect, beautifyCornerSliderRect, beautifyShadowSliderRect, beautifyBgRadiusSliderRect].enumerated() {
                            if sr != .zero && sr.insetBy(dx: -4, dy: -4).contains(point) {
                                isDraggingBeautifySlider = true
                                activeBeautifySlider = idx
                                updateBeautifySlider(at: point)
                                return
                            }
                        }
                        if beautifyGradientBtnRect != .zero && beautifyGradientBtnRect.insetBy(dx: -4, dy: -4).contains(point) {
                            showBeautifyGradientPicker.toggle()
                            needsDisplay = true
                            return
                        }
                        return  // consumed by beautify options row
                    }
                    // Measure unit toggle (px/pt)
                    if currentTool == .measure && measureUnitToggleRect != .zero {
                        let pxRect = measureUnitToggleRect
                        let ptRect = NSRect(x: pxRect.maxX, y: pxRect.minY, width: pxRect.width, height: pxRect.height)
                        if pxRect.contains(point) && currentMeasureInPoints {
                            currentMeasureInPoints = false
                            UserDefaults.standard.set(false, forKey: "measureInPoints")
                            needsDisplay = true; return
                        }
                        if ptRect.contains(point) && !currentMeasureInPoints {
                            currentMeasureInPoints = true
                            UserDefaults.standard.set(true, forKey: "measureInPoints")
                            needsDisplay = true; return
                        }
                    }
                    // Stroke slider
                    if optionsStrokeSliderRect != .zero && optionsStrokeSliderRect.insetBy(dx: -4, dy: -4).contains(point) {
                        isDraggingOptionsStroke = true
                        updateOptionsStrokeSlider(at: point)
                        return
                    }
                    // Smooth toggle
                    if optionsSmoothToggleRect != .zero && optionsSmoothToggleRect.insetBy(dx: -4, dy: -4).contains(point) {
                        pencilSmoothEnabled.toggle()
                        UserDefaults.standard.set(pencilSmoothEnabled, forKey: "pencilSmoothEnabled")
                        needsDisplay = true
                        return
                    }
                    // Rounded toggle
                    if optionsRoundedToggleRect != .zero && optionsRoundedToggleRect.insetBy(dx: -4, dy: -4).contains(point) {
                        roundedRectEnabled.toggle()
                        UserDefaults.standard.set(roundedRectEnabled, forKey: "roundedRectEnabled")
                        needsDisplay = true
                        return
                    }
                    // Corner radius slider
                    if optionsCornerRadiusSliderRect != .zero && optionsCornerRadiusSliderRect.insetBy(dx: -4, dy: -4).contains(point) {
                        isDraggingOptionsCornerRadius = true
                        updateOptionsCornerRadius(at: point)
                        return
                    }
                    // Line style buttons
                    for (i, sr) in optionsLineStyleRects.enumerated() {
                        if sr.contains(point), let style = LineStyle(rawValue: i) {
                            currentLineStyle = style
                            UserDefaults.standard.set(style.rawValue, forKey: "currentLineStyle")
                            needsDisplay = true
                            return
                        }
                    }
                    // Arrow style buttons
                    for (i, sr) in optionsArrowStyleRects.enumerated() {
                        if sr.contains(point), let style = ArrowStyle(rawValue: i) {
                            currentArrowStyle = style
                            UserDefaults.standard.set(style.rawValue, forKey: "currentArrowStyle")
                            needsDisplay = true
                            return
                        }
                    }
                    // Rect fill style buttons
                    for (i, sr) in optionsRectFillStyleRects.enumerated() {
                        if sr.contains(point), let style = RectFillStyle(rawValue: i) {
                            currentRectFillStyle = style
                            UserDefaults.standard.set(style.rawValue, forKey: "currentRectFillStyle")
                            needsDisplay = true
                            return
                        }
                    }
                    // Stamp emoji/load buttons
                    if currentTool == .stamp {
                        for (i, sr) in stampEmojiRects.enumerated() {
                            if sr.contains(point), i < Self.commonEmojis.count {
                                currentStampImage = renderEmoji(Self.commonEmojis[i])
                                currentStampEmoji = Self.commonEmojis[i]
                                needsDisplay = true
                                return
                            }
                        }
                        if stampMoreRect.contains(point) {
                            showEmojiPicker.toggle()
                            needsDisplay = true
                            return
                        }
                        if stampLoadRect.contains(point) {
                            loadStampImage()
                            return
                        }
                    }
                    // Text formatting buttons
                    if currentTool == .text {
                        if textBoldRect != .zero && textBoldRect.contains(point) {
                            toggleTextBold(); return
                        }
                        if textItalicRect != .zero && textItalicRect.contains(point) {
                            toggleTextItalic(); return
                        }
                        if textUnderlineRect != .zero && textUnderlineRect.contains(point) {
                            toggleTextUnderline(); return
                        }
                        if textStrikethroughRect != .zero && textStrikethroughRect.contains(point) {
                            toggleTextStrikethrough(); return
                        }
                        // Alignment buttons
                        for (rect, align) in [(textAlignLeftRect, NSTextAlignment.left),
                                               (textAlignCenterRect, NSTextAlignment.center),
                                               (textAlignRightRect, NSTextAlignment.right)] {
                            if rect != .zero && rect.contains(point) {
                                textAlignment = align
                                applyAlignmentToText()
                                needsDisplay = true; return
                            }
                        }
                        if textBgToggleRect != .zero && textBgToggleRect.contains(point) {
                            textBgEnabled.toggle()
                            UserDefaults.standard.set(textBgEnabled, forKey: "textBgEnabled")
                            needsDisplay = true; return
                        }
                        if textOutlineToggleRect != .zero && textOutlineToggleRect.contains(point) {
                            textOutlineEnabled.toggle()
                            UserDefaults.standard.set(textOutlineEnabled, forKey: "textOutlineEnabled")
                            needsDisplay = true; return
                        }
                        if textSizeDecRect != .zero && textSizeDecRect.contains(point) {
                            textFontSize = max(10, textFontSize - 2)
                            applyFontSizeToSelection()
                            needsDisplay = true; return
                        }
                        if textSizeIncRect != .zero && textSizeIncRect.contains(point) {
                            textFontSize = min(72, textFontSize + 2)
                            applyFontSizeToSelection()
                            needsDisplay = true; return
                        }
                        if textFontDropdownRect != .zero && textFontDropdownRect.contains(point) {
                            showFontPicker.toggle()
                            needsDisplay = true; return
                        }
                        if textCancelRect != .zero && textCancelRect.contains(point) {
                            cancelTextEditing(); return
                        }
                        if textConfirmRect != .zero && textConfirmRect.contains(point) {
                            commitTextFieldIfNeeded(); return
                        }
                    }
                    // Redact buttons (blur/pixelate options row)
                    if currentTool == .pixelate || currentTool == .blur {
                        if redactAllTextBtnRect != .zero && redactAllTextBtnRect.contains(point) {
                            pressedRedactBtn = 0; needsDisplay = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                                self?.pressedRedactBtn = -1; self?.needsDisplay = true
                                self?.performRedactAllText()
                            }
                            return
                        }
                        if redactPIIBtnRect != .zero && redactPIIBtnRect.contains(point) {
                            pressedRedactBtn = 1; needsDisplay = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                                self?.pressedRedactBtn = -1; self?.needsDisplay = true
                                self?.performAutoRedact()
                            }
                            return
                        }
                        if redactTypeDropdownRect != .zero && redactTypeDropdownRect.contains(point) {
                            showRedactTypePicker.toggle()
                            needsDisplay = true
                            return
                        }
                    }
                    return  // consumed by options row
                }

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

        // Handle options row slider dragging
        if isDraggingOptionsStroke {
            updateOptionsStrokeSlider(at: point)
            return
        }
        if isDraggingOptionsCornerRadius {
            updateOptionsCornerRadius(at: point)
            return
        }
        // Handle beautify slider dragging
        if isDraggingBeautifySlider {
            updateBeautifySlider(at: point)
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
            applyPickedColor(color)
            return
        }
        // Handle brightness slider dragging
        if isDraggingBrightnessSlider {
            updateBrightnessFromPoint(point)
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

                // Arrow/line/measure: .bottomLeft = startPoint, .topRight = endPoint, .top = controlPoint
                if annotation.tool == .arrow || annotation.tool == .line || annotation.tool == .measure {
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

        if isDraggingBottomBar {
            isDraggingBottomBar = false
            return
        }
        if isDraggingRightBar {
            isDraggingRightBar = false
            return
        }
        if isResizingTextBox {
            isResizingTextBox = false
            return
        }
        if isDraggingOptionsStroke {
            isDraggingOptionsStroke = false
            return
        }
        if isDraggingOptionsCornerRadius {
            isDraggingOptionsCornerRadius = false
            return
        }
        if isDraggingBeautifySlider {
            isDraggingBeautifySlider = false
            activeBeautifySlider = -1
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

        // Right-click on custom color slot: clear it
        if showColorPicker {
            for (i, slotRect) in customColorSlotRects.enumerated() {
                if slotRect.contains(point) {
                    removeCustomColor(at: i)
                    needsDisplay = true
                    return
                }
            }
        }

        // Right-click on text Fill/Outline swatches: open color picker targeting that property
        if currentTool == .text {
            if textBgToggleRect != .zero && textBgToggleRect.insetBy(dx: -2, dy: -2).contains(point) {
                if !textBgEnabled { textBgEnabled = true; UserDefaults.standard.set(true, forKey: "textBgEnabled") }
                colorPickerTarget = .textBg
                showColorPicker = true
                needsDisplay = true; return
            }
            if textOutlineToggleRect != .zero && textOutlineToggleRect.insetBy(dx: -2, dy: -2).contains(point) {
                if !textOutlineEnabled { textOutlineEnabled = true; UserDefaults.standard.set(true, forKey: "textOutlineEnabled") }
                colorPickerTarget = .textOutline
                showColorPicker = true
                needsDisplay = true; return
            }
        }

        // Check toolbar button right-clicks first
        if state == .selected && showToolbars {
            if let action = ToolbarLayout.hitTest(point: point, buttons: bottomButtons) {
                // Tool right-click menus removed — options now in the tool options row
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
                if case .save = action {
                    let menu = NSMenu()
                    let saveAsItem = NSMenuItem(title: "Save As...", action: #selector(saveAsMenuAction), keyEquivalent: "")
                    saveAsItem.target = self
                    menu.addItem(saveAsItem)
                    NSMenu.popUpContextMenu(menu, with: event, for: self)
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
                // Record button right-click removed — toggles are in recording toolbar
                return
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
            case .annotationMode, .startRecord, .stopRecord, .mouseHighlight, .systemAudio:
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
            showEmojiPicker = false
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
            colorPickerTarget = .drawColor
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
            overlayDelegate?.overlayViewDidRequestQuickSave()
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
        case .invertColors:
            invertImageColors()
        case .beautify:
            commitTextFieldIfNeeded()
            showFontPicker = false
            showEmojiPicker = false
            stampPreviewPoint = nil
            loupeCursorPoint = .zero
            showBeautifyInOptionsRow = true
            // Auto-enable beautify on first click in this session
            if !beautifyEnabled {
                beautifyEnabled = true
                UserDefaults.standard.set(true, forKey: "beautifyEnabled")
                startBeautifyToolbarAnimation()
            }
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

        // Preset swatches
        for (i, color) in availableColors.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = colorPickerRect.minX + padding + CGFloat(col) * (swatchSize + padding)
            let y = colorPickerRect.maxY - padding - swatchSize - CGFloat(row) * (swatchSize + padding)
            let swatchRect = NSRect(x: x, y: y, width: swatchSize, height: swatchSize)
            if swatchRect.contains(point) {
                // Update HSB tracker to match selected preset
                if let hsb = color.usingColorSpace(.deviceRGB) {
                    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    hsb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                    customPickerHue = h
                    customPickerSaturation = s
                    customBrightness = b
                    customHSBCachedImage = nil
                }
                return color
            }
        }

        // Custom color slots — left click selects the slot
        for (i, slotRect) in customColorSlotRects.enumerated() {
            if slotRect.contains(point) {
                selectedColorSlot = i
                needsDisplay = true
                return nil
            }
        }

        // HSB gradient area
        if customPickerGradientRect.contains(point) {
            let color = colorFromHSBGradient(at: point)
            return color
        }

        // Brightness slider
        if customPickerBrightnessRect.contains(point) {
            updateBrightnessFromPoint(point)
            return nil
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
        let color = NSColor(calibratedHue: customPickerHue, saturation: customPickerSaturation, brightness: customBrightness, alpha: 1.0)
        applyPickedColor(color)
    }

    private func updateOpacityFromPoint(_ point: NSPoint) {
        currentColorOpacity = max(0.05, min(1, (point.x - opacitySliderRect.minX) / opacitySliderRect.width))
        OverlayView.lastUsedOpacity = currentColorOpacity
        applyColorToSelectedAnnotation()
        needsDisplay = true
    }

    private func applyPickedColor(_ color: NSColor) {
        // Save to selected custom slot only when using color sampler tool
        if currentTool == .colorSampler && selectedColorSlot >= 0 && selectedColorSlot < customColors.count {
            customColors[selectedColorSlot] = color.withAlphaComponent(1.0)
            saveCustomColors()
        }

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
                for (handle, rect) in annotationResizeHandleRects {
                    if rect.insetBy(dx: -4, dy: -4).contains(handleTestPoint) {
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
            for (handle, rect) in annotationResizeHandleRects {
                if rect.insetBy(dx: -4, dy: -4).contains(hoverHandlePoint) {
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
            loupeAnnotation.sourceImage = compositedImage()
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
            annotation.number = numberCounter
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

    private func toggleTextBold() {
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

    private func toggleTextItalic() {
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

    private func toggleTextUnderline() {
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

    private func toggleTextStrikethrough() {
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

    private func applyAlignmentToText() {
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

    private func cancelTextEditing() {
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

    private func commitTextFieldIfNeeded() {
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

    // MARK: - Context Menu Actions

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
            } else if showColorPicker {
                showColorPicker = false
                needsDisplay = true
            } else if showUploadConfirmDialog {
                showUploadConfirmDialog = false
                needsDisplay = true
            } else if showEmojiPicker {
                showEmojiPicker = false
                needsDisplay = true
            } else if showBeautifyPicker || showStrokePicker || showLoupeSizePicker || showDelayPicker || showUploadConfirmPicker || showRedactTypePicker || showBeautifyGradientPicker {
                showBeautifyPicker = false
                showStrokePicker = false
                showLoupeSizePicker = false
                showDelayPicker = false
                showUploadConfirmPicker = false
                showRedactTypePicker = false
                showTranslatePicker = false
                showBeautifyGradientPicker = false
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

    private func performAutoRedact() {
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
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

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

        let request = VNRecognizeTextRequest { [weak self] request, error in
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
        cursorTimer?.invalidate()
        cursorTimer = nil
        needsDisplay = true
    }

    func applyFullScreenSelection() {
        selectionRect = bounds
        selectionStart = bounds.origin
        state = .selected
        showToolbars = true
        cursorTimer?.invalidate()
        cursorTimer = nil
        scheduleBarcodeDetection()
        overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
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
        showBeautifyGradientPicker = false
        showEmojiPicker = false
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
        isRightClickSelecting = false
        delaySeconds = 0
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
        cursorTimer?.invalidate()
        cursorTimer = nil
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
