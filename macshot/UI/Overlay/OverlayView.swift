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
    func overlayViewDidRequestFileSave()
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
    func overlayViewDidRequestToggleAutoScroll()
    func overlayViewDidRequestAccessibilityPermission()
    func overlayViewDidRequestInputMonitoringPermission()
    func overlayViewDidBeginSelection()
    func overlayViewRemoteSelectionDidChange(_ rect: NSRect)
    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect)
    func overlayViewDidRequestAddCapture()
}

/// An entry in the undo/redo history.
enum UndoEntry {
    case added(Annotation)  // annotation was added; undo removes it
    case deleted(Annotation, Int)  // annotation was deleted at index; undo re-inserts it
    /// Image transform (crop/flip): stores the previous image and annotation offsets to restore.
    case imageTransform(previousImage: NSImage, annotationOffsets: [(Annotation, CGFloat, CGFloat)])
    /// Property change: stores the annotation and a snapshot taken before the edit.
    case propertyChange(annotation: Annotation, snapshot: Annotation)

    var annotation: Annotation {
        switch self {
        case .added(let a), .deleted(let a, _): return a
        case .propertyChange(let a, _): return a
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
    var effectsPreset: ImageEffectPreset
    var effectsBrightness: Float
    var effectsContrast: Float
    var effectsSaturation: Float
    var effectsSharpness: Float
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
    /// The full (unclipped) remote selection in this view's local coords — used for resize anchor calculation.
    var remoteSelectionFullRect: NSRect = .zero
    private var isResizingRemoteSelection: Bool = false
    private var remoteResizeHandle: ResizeHandle = .none
    private var remoteResizeAnchor: NSPoint = .zero  // the fixed corner during remote resize
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
            cachedEffectsScreenshot = nil
            // Update move button enabled state when annotations change
            if showToolbars { rebuildToolbarLayout() }
        }
    }
    var undoStack: [UndoEntry] = []
    var redoStack: [UndoEntry] = []
    private var currentAnnotation: Annotation?
    /// Whether the user is actively drawing/dragging a new annotation.
    var isActivelyDrawing: Bool { currentAnnotation != nil }

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
            LoupeToolHandler(),
            MeasureToolHandler(),
            NumberToolHandler(),
            StampToolHandler(),
        ]
        return Dictionary(uniqueKeysWithValues: handlers.map { ($0.tool, $0) })
    }()
    /// Last tool the user explicitly picked — shared across overlay instances within one app session.
    private static var lastUsedTool: AnnotationTool = .arrow
    var currentTool: AnnotationTool = {
        let remember = UserDefaults.standard.object(forKey: "rememberLastTool") as? Bool ?? true
        return remember ? OverlayView.lastUsedTool : .arrow
    }() {
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
    /// All currently selected annotations (supports multi-select via Shift+Click).
    private var selectedAnnotations: [Annotation] = [] {
        didSet {
            let oldSingle = oldValue.first
            let newSingle = selectedAnnotations.first
            if newSingle !== oldSingle || oldValue.count != selectedAnnotations.count {
                toolOptionsRowView?.clearEditingAnnotation()

                if selectedAnnotations.count == 1, let ann = newSingle {
                    toolOptionsRowView?.rebuild(forAnnotation: ann)
                    repositionToolbars()
                } else if selectedAnnotations.isEmpty {
                    if let tool = currentTool as AnnotationTool? {
                        toolOptionsRowView?.rebuild(for: tool)
                        repositionToolbars()
                    }
                } else {
                    // Multi-select: revert to tool options (no per-annotation editing)
                    if let tool = currentTool as AnnotationTool? {
                        toolOptionsRowView?.rebuild(for: tool)
                        repositionToolbars()
                    }
                }
            }
        }
    }

    /// Convenience: the single selected annotation (nil if 0 or 2+ selected).
    private var selectedAnnotation: Annotation? {
        get { selectedAnnotations.count == 1 ? selectedAnnotations.first : nil }
        set {
            if let ann = newValue {
                selectedAnnotations = [ann]
            } else {
                selectedAnnotations = []
            }
        }
    }

    /// Whether an annotation is in the current selection.
    private func isSelected(_ annotation: Annotation) -> Bool {
        selectedAnnotations.contains(where: { $0 === annotation })
    }
    private var isDraggingAnnotation: Bool = false
    private var didMoveAnnotation: Bool = false
    private var annotationDragStart: NSPoint = .zero
    /// When shift+clicking an already-selected annotation, defer the deselect
    /// to mouseUp so the user can still drag the full multi-selection.
    private weak var shiftClickPendingDeselect: Annotation?
    // Long-press-to-select for pencil/marker tools
    private var longPressTimer: Timer?
    private var longPressPoint: NSPoint = .zero
    private var longPressTriggered: Bool = false
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
            bgRadius: 0,
            isWindowSnap: selectionIsWindowSnap
        )
    }

    var showBeautifyInOptionsRow: Bool = false

    // Image effects
    var effectsPreset: ImageEffectPreset =
        ImageEffectPreset(rawValue: UserDefaults.standard.integer(forKey: "effectsPreset")) ?? .none
    var effectsBrightness: Float = {
        let v = UserDefaults.standard.object(forKey: "effectsBrightness") as? Double
        return v != nil ? Float(v!) : 0
    }()
    var effectsContrast: Float = {
        let v = UserDefaults.standard.object(forKey: "effectsContrast") as? Double
        return v != nil ? Float(v!) : 1.0
    }()
    var effectsSaturation: Float = {
        let v = UserDefaults.standard.object(forKey: "effectsSaturation") as? Double
        return v != nil ? Float(v!) : 1.0
    }()
    var effectsSharpness: Float = {
        let v = UserDefaults.standard.object(forKey: "effectsSharpness") as? Double
        return v != nil ? Float(v!) : 0
    }()

    var effectsConfig: ImageEffectsConfig {
        ImageEffectsConfig(
            preset: effectsPreset,
            brightness: effectsBrightness,
            contrast: effectsContrast,
            saturation: effectsSaturation,
            sharpness: effectsSharpness
        )
    }
    var effectsActive: Bool { !effectsConfig.isIdentity }

    /// Cached effects-processed screenshot for live preview. Invalidated when effects or annotations change.
    var cachedEffectsScreenshot: NSImage?

    // Color picker target
    enum ColorPickerTarget { case drawColor, textBg, textOutline, annotationOutline }
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
    var arrowReversed: Bool =
        UserDefaults.standard.bool(forKey: "arrowReversed")
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

    var pencilSmoothMode: Int = {
        // Migrate old bool to new mode: true → 1 (Smooth), false → 0 (None)
        if let old = UserDefaults.standard.object(forKey: "pencilSmoothEnabled") as? Bool {
            UserDefaults.standard.removeObject(forKey: "pencilSmoothEnabled")
            let mode = old ? 1 : 0
            UserDefaults.standard.set(mode, forKey: "pencilSmoothMode")
            return mode
        }
        return UserDefaults.standard.object(forKey: "pencilSmoothMode") as? Int ?? 1
    }()
    var smartMarkerEnabled: Bool =
        UserDefaults.standard.object(forKey: "smartMarkerEnabled") as? Bool ?? false
    private var roundedRectEnabled: Bool =
        UserDefaults.standard.object(forKey: "roundedRectEnabled") as? Bool ?? false

    var currentLoupeSize: CGFloat = {
        let saved = UserDefaults.standard.object(forKey: "loupeSize") as? Double
        return saved != nil ? CGFloat(saved!) : 120.0
    }()
    private var loupeCursorPoint: NSPoint = .zero
    var drawingCursorPoint: NSPoint = .zero
    private var smartMarkerLineHeight: CGFloat?  // detected text line height at cursor (smart marker)
    private var colorSamplerPoint: NSPoint = .zero  // canvas space, for color picker tool
    private var colorSamplerBitmap: NSBitmapImageRep?  // cached bitmap for fast pixel sampling
    // Auto-measure preview (live while holding 1 or 2 key)
    private var autoMeasurePreview: Annotation?  // temporary, drawn but not in annotations[]
    private var autoMeasureVertical: Bool = true  // true = "1" key, false = "2" key
    private var autoMeasureKeyHeld: Bool = false  // true while 1 or 2 is held down
    private var autoMeasureBitmapCtx: CGContext?  // cached pixel data for fast scanning
    private var autoMeasureBitmapW: Int = 0
    private var autoMeasureBitmapH: Int = 0
    // Snap/alignment guides
    var snapGuideX: CGFloat? = nil  // vertical guide line X
    var snapGuideY: CGFloat? = nil  // horizontal guide line Y
    private let snapThreshold: CGFloat = 5
    private var snapGuidesEnabled: Bool {
        UserDefaults.standard.object(forKey: "snapGuidesEnabled") as? Bool ?? true
    }

    var cachedCompositedImage: NSImage? = nil  // invalidated when annotations change
    private var cachedOpaqueRect: NSRect?  // cached opaque content bounds of screenshotImage

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
    private var editorTooltipView: NSView?
    private var overlayErrorTimer: Timer? = nil

    // Barcode / QR detection
    private let barcodeDetector = BarcodeDetector()

    // Recording state
    var isRecording: Bool = false {  // true when recording toolbar is shown (pre-recording setup)
        didSet {
            if isRecording {
                // Clear drawing previews so they don't linger from screenshot mode
                commitTextFieldIfNeeded()
                stampPreviewPoint = nil
                loupeCursorPoint = .zero
                drawingCursorPoint = .zero
                autoMeasurePreview = nil
                hoveredAnnotation = nil
                selectedAnnotation = nil
                needsDisplay = true
                // Pre-check Input Monitoring permission if keystroke overlay is enabled
                if UserDefaults.standard.bool(forKey: "recordKeystroke") && !KeystrokeOverlay.hasInputMonitoringPermission {
                    UserDefaults.standard.set(false, forKey: "recordKeystroke")
                    rebuildToolbarLayout()
                    overlayDelegate?.overlayViewDidRequestInputMonitoringPermission()
                }

                // Pre-check mic + camera permissions sequentially so dialogs don't overlap
                preCheckRecordingPermissions()
            } else {
                stopMicLevelMonitor()
                dismissWebcamSetupPreview()
            }
        }
    }
    var autoEnterRecordingMode: Bool = false  // set by "Record Screen" menu — enters recording mode after selection
    var autoOCRMode: Bool = false  // set by "Capture OCR" menu — triggers OCR immediately after selection
    var autoQuickSaveMode: Bool = false  // set by "Quick Capture" menu — quick-saves immediately after selection
    var autoScrollCaptureMode: Bool = false  // set by "Scroll Capture" menu — triggers scroll capture immediately after selection
    var autoConfirmMode: Bool = false  // set by "Add Capture" — auto-confirms selection (no toolbars, no save)

    // Recording session overrides (popover settings — nil means use UserDefaults default)
    var sessionRecordingFormat: String?
    var sessionRecordingFPS: Int?
    var sessionRecordingOnStop: String?
    var sessionRecordingDelay: Int?

    // Scroll capture state
    var isScrollCapturing: Bool = false
    var scrollCaptureStripCount: Int = 0
    var scrollCapturePixelSize: CGSize = .zero
    var scrollCaptureMaxHeight: Int = 0
    var scrollCaptureAutoScrolling: Bool = false
    private var scrollCaptureHUDPanel: ScrollCaptureHUDPanel?
    private var scrollCaptureMouseTap: CFMachPort?
    private var scrollCaptureMouseTapSource: CFRunLoopSource?
    private var scrollCaptureKeyMonitor: Any?
    private var scrollCaptureLocalKeyMonitor: Any?
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

    func startScrollCaptureMode() {
        isScrollCapturing = true
        scrollCaptureStripCount = 0
        scrollCapturePixelSize = .zero
        scrollCaptureAutoScrolling = false

        activateAppUnderSelection()
        window?.ignoresMouseEvents = true

        // Suppress mouse-moved events via CGEvent tap so hover effects in the
        // target app don't break stitch detection. Requires Accessibility permission
        // (checked before entering scroll capture mode).
        if AXIsProcessTrusted() {
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(1 << CGEventType.mouseMoved.rawValue),
                callback: { _, _, _, _ in nil },
                userInfo: nil)
            if let tap = tap {
                let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                scrollCaptureMouseTap = tap
                scrollCaptureMouseTapSource = source
            }
        }

        // Escape key monitor — global catches when another app has focus; local when macshot has focus.
        let handleScrollKey: (NSEvent) -> Void = { [weak self] event in
            guard let self = self, self.isScrollCapturing else { return }
            if event.keyCode == 53 {  // Escape
                self.overlayDelegate?.overlayViewDidRequestStopScrollCapture()
            }
        }
        scrollCaptureKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            handleScrollKey(event)
        }
        scrollCaptureLocalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleScrollKey(event)
            if event.keyCode == 53 { return nil }  // consume
            return event
        }

        // Show real NSPanel-based HUD (receives clicks independently of overlay window)
        let panel = ScrollCaptureHUDPanel()
        panel.hudView.onStop = { [weak self] in
            self?.overlayDelegate?.overlayViewDidRequestStopScrollCapture()
        }
        panel.hudView.onToggleAutoScroll = { [weak self] in
            self?.overlayDelegate?.overlayViewDidRequestToggleAutoScroll()
        }
        panel.hudView.update(
            stripCount: 0, pixelSize: .zero,
            backingScale: window?.backingScaleFactor ?? 2,
            maxScrollHeight: scrollCaptureMaxHeight,
            autoScrolling: scrollCaptureAutoScrolling)
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
        scrollCaptureAutoScrolling = false

        if let m = scrollCaptureKeyMonitor { NSEvent.removeMonitor(m); scrollCaptureKeyMonitor = nil }
        if let m = scrollCaptureLocalKeyMonitor { NSEvent.removeMonitor(m); scrollCaptureLocalKeyMonitor = nil }
        if let tap = scrollCaptureMouseTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = scrollCaptureMouseTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            scrollCaptureMouseTap = nil
            scrollCaptureMouseTapSource = nil
        }
        scrollCaptureHUDPanel?.close()
        scrollCaptureHUDPanel = nil
        window?.ignoresMouseEvents = false

        needsDisplay = true
    }

    /// Update the scroll capture HUD with new strip count and pixel size.
    func updateScrollCaptureHUD() {
        scrollCaptureHUDPanel?.hudView.update(
            stripCount: scrollCaptureStripCount,
            pixelSize: scrollCapturePixelSize,
            backingScale: window?.backingScaleFactor ?? 2,
            maxScrollHeight: scrollCaptureMaxHeight,
            autoScrolling: scrollCaptureAutoScrolling)
        if let win = window {
            scrollCaptureHUDPanel?.position(relativeTo: selectionRect, in: win)
        }
    }

    var isAnnotating: Bool = false

    // Window snapping
    var windowSnapEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "windowSnapEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "windowSnapEnabled") }
    }
    var hoveredWindowRect: NSRect? = nil
    var hoveredWindowID: CGWindowID? = nil
    private var windowSnapCooldown: Bool = true  // true until overlay has rendered
    /// True when the current selection was made via window snap (click without drag).
    /// Cleared when the user manually resizes the selection.
    var selectionIsWindowSnap: Bool = false
    var snappedWindowID: CGWindowID? = nil
    /// Independently captured window image (with transparent corners) for beautify snap mode.
    var snappedWindowImage: NSImage? = nil
    private var windowSnapQueryInFlight: Bool = false

    // Mic level monitor (volume meter shown when mic is enabled before recording)
    private var micLevelEngine: AVAudioEngine?
    private var micLevelTimer: Timer?

    private var customColors: [NSColor?] = Array(repeating: nil, count: 7)
    private var selectedColorSlot: Int = 0  // which custom slot is selected for saving colors
    private static var lastUsedOpacity: CGFloat = 1.0
    private var currentColorOpacity: CGFloat = OverlayView.lastUsedOpacity

    // Radial color wheel (right-click in drawing mode)
    private let colorWheel = ColorWheelRenderer()

    // Webcam setup preview (shown during recording setup when webcam is enabled)
    private var webcamSetupPreview: WebcamOverlay?

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
            rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)

        // Let the overlay render before starting expensive window snap queries
        windowSnapCooldown = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.windowSnapCooldown = false
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleToolbarColorsChanged),
            name: .toolbarColorsDidChange, object: nil)
    }

    @objc private func handleToolbarColorsChanged() {
        // Rebuild toolbars and options row with new colors
        toolOptionsRowView?.layer?.backgroundColor = ToolbarLayout.bgColor.cgColor
        rebuildToolbarLayout()
        if let tool = toolOptionsRowView?.currentTool {
            toolOptionsRowView?.rebuild(for: tool)
        }
        needsDisplay = true
    }

    /// Invalidate only the rect around a cursor preview (old + new position) instead of the whole view.
    private func invalidateCursorPreview(oldCanvas: NSPoint, newCanvas: NSPoint, radius: CGFloat) {
        let margin: CGFloat = 4
        // Scale canvas-space radius to view-space pixels (zoom factor)
        let r = (radius + margin) * zoomLevel
        if oldCanvas != .zero {
            let oldView = canvasToView(oldCanvas)
            setNeedsDisplay(NSRect(x: oldView.x - r, y: oldView.y - r, width: r * 2, height: r * 2))
        }
        let newView = canvasToView(newCanvas)
        setNeedsDisplay(NSRect(x: newView.x - r, y: newView.y - r, width: r * 2, height: r * 2))
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
                let oldPt = stampPreviewPoint ?? .zero
                stampPreviewPoint = canvasStampPt
                invalidateCursorPreview(oldCanvas: oldPt, newCanvas: canvasStampPt, radius: 40)
            }
        } else if stampPreviewPoint != nil {
            let oldPt = stampPreviewPoint!
            stampPreviewPoint = nil
            invalidateCursorPreview(oldCanvas: oldPt, newCanvas: oldPt, radius: 40)
        }

        // Update cursor on every mouse move
        updateCursorForPoint(point)

        // Auto-measure: update preview as cursor moves while key is held
        if autoMeasureKeyHeld {
            updateAutoMeasurePreview()
        }

        // Window snap: highlight hovered window in idle state.
        // CGWindowListCopyWindowInfo is expensive — run it on a background thread,
        // skipping new queries while one is already in flight.
        // Delay window snap queries briefly after overlay appears so the overlay
        // renders without competing with CGWindowListCopyWindowInfo for the window server
        if windowSnapCooldown { return }
        if state == .idle && windowSnapEnabled && !windowSnapQueryInFlight
            && !(remoteSelectionRect.width >= 1 && remoteSelectionRect.height >= 1)
        {
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
                let result = Self.windowRectOnBackground(
                    screenPoint: screenPoint,
                    overlayWindowNumber: overlayWindowNumber,
                    windowOrigin: windowOrigin,
                    viewBounds: viewBounds,
                    screenH: screenH
                )
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.windowSnapQueryInFlight = false
                    let newRect = result?.rect
                    if newRect != self.hoveredWindowRect {
                        self.hoveredWindowRect = newRect
                        self.hoveredWindowID = result?.windowID
                        self.needsDisplay = true
                    }
                }
            }
        }

        // Track cursor for loupe live preview (use canvas space for zoom correctness)
        if state == .selected && currentTool == .loupe && !isRecording && !showBeautifyInOptionsRow {
            let newPoint = viewToCanvas(convert(event.locationInWindow, from: nil))
            if newPoint != loupeCursorPoint {
                let oldPt = loupeCursorPoint
                loupeCursorPoint = newPoint
                let r = currentLoupeSize / 2 + 4
                invalidateCursorPreview(oldCanvas: oldPt, newCanvas: newPoint, radius: r)
            }
        }

        // Track cursor for pencil/marker dot preview (canvas space so it scales with zoom)
        let showDrawingCursor = state == .selected && !isRecording
            && (currentTool == .pencil || currentTool == .marker)
        if showDrawingCursor {
            let canvasPoint = viewToCanvas(point)
            if canvasPoint != drawingCursorPoint {
                let oldPt = drawingCursorPoint
                let oldR = drawingCursorRadius
                drawingCursorPoint = canvasPoint
                // Smart marker: query line height at cursor and update preview size
                if currentTool == .marker && smartMarkerEnabled {
                    if let handler = toolHandlers[.marker] as? MarkerToolHandler {
                        handler.ensureOCRCache(canvas: self)
                        smartMarkerLineHeight = handler.textLineHeight(at: canvasPoint, canvas: self)
                    }
                }
                // Invalidate both old and new positions with the larger radius
                let newR = drawingCursorRadius
                let r = max(oldR, newR) + 4
                invalidateCursorPreview(oldCanvas: oldPt, newCanvas: canvasPoint, radius: r)
            }
        } else if drawingCursorPoint != .zero {
            let oldPt = drawingCursorPoint
            let r = drawingCursorRadius + 4
            drawingCursorPoint = .zero
            smartMarkerLineHeight = nil
            invalidateCursorPreview(oldCanvas: oldPt, newCanvas: oldPt, radius: r)
        }

        // Track cursor for color sampler tool (canvas space)
        if state == .selected && currentTool == .colorSampler && !isRecording {
            let canvasPoint = viewToCanvas(point)
            if canvasPoint != colorSamplerPoint {
                let oldPt = colorSamplerPoint
                colorSamplerPoint = canvasPoint
                invalidateCursorPreview(oldCanvas: oldPt, newCanvas: canvasPoint, radius: 200)
            }
        } else if colorSamplerPoint != .zero {
            let oldPt = colorSamplerPoint
            colorSamplerPoint = .zero
            colorSamplerBitmap = nil
            invalidateCursorPreview(oldCanvas: oldPt, newCanvas: oldPt, radius: 200)
        }

        // Toolbar hover handled by ToolbarButtonView (real NSView subviews)
    }

    // Custom cursors
    /// Transparent 1x1 cursor used to hide the system cursor while the drawing dot preview is shown.
    private static let invisibleCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: img, hotSpot: .zero)
    }()

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
        // Intentionally empty — cursor management is handled imperatively in mouseMoved
        // via updateCursorForPoint(). Overriding prevents AppKit's default cursorUpdate
        // from resetting our custom cursors.
    }

    override func resetCursorRects() {
        // Handled imperatively in mouseMoved
    }

    /// Imperative cursor management. Called from mouseMoved and a 30fps timer.
    /// Simplified: arrow for chrome, resize cursors for handles, tool cursor for canvas.
    private func updateCursorForPoint(_ point: NSPoint) {
        // Arrow cursor when mouse is over an open popover
        if PopoverHelper.isMouseInsidePopover {
            NSCursor.arrow.set()
            return
        }

        // Non-interactive states — simple cursors
        if textEditView != nil {
            NSCursor.arrow.set()
            return
        }
        if state == .idle || state == .selecting {
            // Recording mode: arrow cursor (no selection interaction)
            if isRecording {
                NSCursor.arrow.set()
                return
            }
            // Show resize cursor for remote selection handles
            if state == .idle && remoteSelectionRect.width >= 1 && remoteSelectionRect.height >= 1 {
                let remoteHandle = hitTestRemoteHandle(at: point)
                if remoteHandle != .none {
                    cursorForHandle(remoteHandle).set()
                    return
                }
            }
            NSCursor.crosshair.set()
            return
        }
        guard state == .selected else { return }

        // Chrome areas — arrow
        if isPointOnChrome(point) {
            NSCursor.arrow.set()
            return
        }

        // Selection resize handles (overlay only, not during scroll capture)
        if !isEditorMode && !isScrollCapturing, let handleCursor = resizeHandleCursor(at: point) {
            handleCursor.set()
            return
        }

        // Annotation control cursors (resize handles, rotation, delete, body)
        if state == .selected && !isDraggingAnnotation && !isResizingAnnotation && !isRotatingAnnotation {
            // Check selected annotation's handles first
            if selectedAnnotation != nil {
                // Unrotate point for handle hit test
                let handlePoint: NSPoint
                if let ann = selectedAnnotation, ann.rotation != 0 && ann.supportsRotation {
                    let center = NSPoint(x: ann.boundingRect.midX, y: ann.boundingRect.midY)
                    let cos_r = cos(-ann.rotation)
                    let sin_r = sin(-ann.rotation)
                    let dx = point.x - center.x
                    let dy = point.y - center.y
                    handlePoint = NSPoint(x: center.x + dx * cos_r - dy * sin_r,
                                          y: center.y + dx * sin_r + dy * cos_r)
                } else {
                    handlePoint = point
                }

                // Resize handles — directional cursors for shapes, open hand for line/arrow points
                let isShapeTool = [AnnotationTool.rectangle, .filledRectangle, .ellipse, .text,
                                   .number, .pixelate, .stamp].contains(selectedAnnotation?.tool)
                for (_, handleEntry) in annotationResizeHandleRects.enumerated() {
                    let (handle, rect) = handleEntry
                    if rect.insetBy(dx: -4, dy: -4).contains(handlePoint) {
                        if isShapeTool {
                            switch handle {
                            case .topLeft, .bottomRight: Self.nwseCursor.set()
                            case .topRight, .bottomLeft: Self.neswCursor.set()
                            case .top, .bottom: NSCursor.resizeUpDown.set()
                            case .left, .right: NSCursor.resizeLeftRight.set()
                            default: NSCursor.openHand.set()
                            }
                        } else {
                            NSCursor.openHand.set()
                        }
                        return
                    }
                }

                // Rotation handle
                if annotationRotateHandleRect != .zero
                    && annotationRotateHandleRect.insetBy(dx: -6, dy: -6).contains(point) {
                    // Use a rotation-style cursor (crosshair works as a generic grab indicator)
                    NSCursor.openHand.set()
                    return
                }

                // Delete button
                if annotationDeleteButtonRect.contains(point) {
                    NSCursor.arrow.set()
                    return
                }

                // Edit button
                if annotationEditButtonRect != .zero && annotationEditButtonRect.contains(point) {
                    NSCursor.arrow.set()
                    return
                }
            }

            // Body hover — open hand (skip for pencil/marker where click always draws)
            if currentTool != .pencil && currentTool != .marker {
                let canvasPoint = viewToCanvas(point)
                if let selected = selectedAnnotation, selected.hitTest(point: canvasPoint) {
                    NSCursor.openHand.set()
                    return
                }
                if annotations.reversed().contains(where: { $0.isMovable && $0.hitTest(point: canvasPoint) }) {
                    NSCursor.openHand.set()
                    return
                }
            }
        }

        // Tool cursor — use handler's state-aware cursor if available, else legacy switch
        // Pencil/marker: hide system cursor when dot preview is active (the dot IS the cursor)
        if (currentTool == .pencil || currentTool == .marker)
            && state == .selected && drawingCursorPoint != .zero {
            Self.invisibleCursor.set()
        } else if let handler = toolHandlers[currentTool], let cursor = handler.cursorForCanvas(self) {
            cursor.set()
        } else {
            switch currentTool {
            case .select: NSCursor.arrow.set()
            default: NSCursor.crosshair.set()
            }
        }
    }

    /// Re-evaluate the cursor for the current tool (e.g. after toggling smart marker).
    /// Find the EditorTopBarView in the chrome parent (for updating zoom label from keyboard shortcuts).
    private func findTopBar() -> EditorTopBarView? {
        chromeParentView?.subviews.compactMap { $0 as? EditorTopBarView }.first
    }

    func updateCursorForCurrentTool() {
        guard let win = window else { return }
        let point = convert(win.mouseLocationOutsideOfEventStream, from: nil)
        updateCursorForPoint(point)
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let real NSView subviews (toolbar strips, options row) handle their own events.
        // This prevents our mouseDown override from intercepting slider drags etc.
        // In editor mode the strips live in chromeParentView (a sibling container), not in
        // this view — AppKit's normal hit testing on the container handles them. Routing them
        // here would compare coordinates in different spaces and cause false matches.
        if !isEditorMode {
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
        }
        return super.hitTest(point)
    }

    /// Returns true if the point is over any chrome element (toolbars, options row, popovers, labels).
    private func isPointOnChrome(_ point: NSPoint) -> Bool {
        // In editor mode, strips are in chromeParentView — different coordinate space.
        // Don't check them here; they handle their own hit testing as container subviews.
        if showToolbars && !isEditorMode {
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

    private func cursorForHandle(_ handle: ResizeHandle) -> NSCursor {
        switch handle {
        case .topLeft, .bottomRight: return Self.nwseCursor
        case .topRight, .bottomLeft: return Self.neswCursor
        case .top, .bottom: return .resizeUpDown
        case .left, .right: return .resizeLeftRight
        case .none, .move: return .arrow
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

    /// Override to control whether selection resize handles are active. Base returns true when not in editor mode or scroll capturing.
    func shouldAllowSelectionResize() -> Bool { !isEditorMode && !isScrollCapturing }

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
        } else if !isRecording {
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

            // Resize handles for remote selection
            drawRemoteResizeHandles()
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
                if !isScrollCapturing, !isRecording, let image = screenshotImage {
                    image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
                }
                context.restoreGraphicsState()
            }

            // Skip annotation drawing if the editor already drew them via the cached composite.
            let editorDrawnFromCache = (self as? EditorView)?.drewFromCompositeCache ?? false

            if !editorDrawnFromCache {
                // Draw translate overlays clipped to selection (they must stay inside).
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
                NSBezierPath(rect: selectionRect).setClip()
                for annotation in annotations where annotation.tool == .translateOverlay {
                    annotation.draw(in: context)
                }
                context.restoreGraphicsState()

                // Draw user annotations unclipped — strokes can continue past the selection border.
                // Censor annotations (pixelate/blur) render first so other annotations
                // always appear on top of blurred regions.
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
                for annotation in annotations where annotation.tool != .translateOverlay && annotation.tool == .pixelate {
                    annotation.draw(in: context)
                }
                for annotation in annotations where annotation.tool != .translateOverlay && annotation.tool != .pixelate {
                    annotation.draw(in: context)
                }
            } else {
                // Still need the canvas transform for active drawing and overlays below
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
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

            // Draw selection highlight for selected annotations
            // Suppressed during recording so annotations are purely visual overlays.
            if !isRecording {
                for selected in selectedAnnotations {
                    // Only draw full controls (handles, buttons) for single selection
                    drawAnnotationControls(for: selected, fullControls: selectedAnnotations.count == 1)
                }
            }

            // Pencil/marker cursor dot preview inside zoom transform so it scales with zoom
            if (currentTool == .pencil || currentTool == .marker) && drawingCursorPoint != .zero && currentAnnotation == nil && !isDraggingAnnotation && !isResizingAnnotation && !isRotatingAnnotation {
                drawDrawingCursorPreview(at: drawingCursorPoint)
            }

            // Snap alignment guides
            drawSnapGuides()

            context.restoreGraphicsState()

            // Live beautify preview — draw gradient background, shadow, and rounded image around selection
            let showBeautifyPreview = beautifyEnabled && state == .selected && !isScrollCapturing && !isRecording
            let showEffectsPreview = effectsActive && state == .selected && !isScrollCapturing && !isRecording && !beautifyEnabled

            if showBeautifyPreview {
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
                drawBeautifyPreview(context: context)
                context.restoreGraphicsState()

                // Re-draw in-progress annotation on top of beautify so it stays visible
                if currentAnnotation != nil || autoMeasurePreview != nil {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    currentAnnotation?.draw(in: context)
                    autoMeasurePreview?.draw(in: context)
                    context.restoreGraphicsState()
                }

                // Re-draw annotation controls on top of the beautify preview so they stay visible.
                if !isRecording && !selectedAnnotations.isEmpty {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    for selected in selectedAnnotations {
                        drawAnnotationControls(for: selected, fullControls: selectedAnnotations.count == 1)
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

                // Re-draw drawing cursor dot preview on top of beautify
                if (currentTool == .pencil || currentTool == .marker) && drawingCursorPoint != .zero && currentAnnotation == nil && !isDraggingAnnotation && !isResizingAnnotation && !isRotatingAnnotation
                {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawDrawingCursorPreview(at: drawingCursorPoint)
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

            // Effects-only preview (no beautify) — draw effects-processed screenshot in selection
            if showEffectsPreview, let screenshot = screenshotImage {
                context.saveGraphicsState()
                applyCanvasTransform(to: context)
                NSBezierPath(rect: selectionRect).setClip()
                let effectsImage = effectsProcessedScreenshot(screenshot)
                effectsImage.draw(in: captureDrawRect, from: .zero, operation: .copy, fraction: 1.0)
                // Re-draw annotations on top (censor first, then everything else)
                for annotation in annotations where annotation.tool == .pixelate { annotation.draw(in: context) }
                for annotation in annotations where annotation.tool != .pixelate { annotation.draw(in: context) }
                currentAnnotation?.draw(in: context)
                context.restoreGraphicsState()

                // Re-draw overlays on top of effects preview
                if !selectedAnnotations.isEmpty {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    for selected in selectedAnnotations {
                        drawAnnotationControls(for: selected, fullControls: selectedAnnotations.count == 1)
                    }
                    context.restoreGraphicsState()
                }
                if currentTool == .loupe && selectionRect.contains(loupeCursorPoint) && loupeCursorPoint != .zero {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawLoupePreview(at: loupeCursorPoint)
                    context.restoreGraphicsState()
                }
                if currentTool == .colorSampler && colorSamplerPoint != .zero {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawColorSamplerPreview(at: colorSamplerPoint)
                    context.restoreGraphicsState()
                }
                if (currentTool == .pencil || currentTool == .marker) && drawingCursorPoint != .zero && currentAnnotation == nil && !isDraggingAnnotation && !isResizingAnnotation && !isRotatingAnnotation {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawDrawingCursorPreview(at: drawingCursorPoint)
                    context.restoreGraphicsState()
                }
                if snapGuideX != nil || snapGuideY != nil {
                    context.saveGraphicsState()
                    applyCanvasTransform(to: context)
                    drawSnapGuides()
                    context.restoreGraphicsState()
                }
            }

            // Selection border — hidden in editor mode and when beautify/effects preview is active,
            // red during scroll capture, purple otherwise
            if shouldDrawSelectionBorder()
                && !showBeautifyPreview && !showEffectsPreview
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
            }

            // Resize handles (drawn even in recording setup mode, but not during scroll capture)
            if state == .selected && !isEditorMode && !isScrollCapturing {
                drawResizeHandles()
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

            // Toolbars — reposition only when selection/layout changes (not every draw).
            // In editor mode toolbars have autoresizingMask, so they only need repositioning
            // on explicit layout changes (handled by rebuildToolbarLayout).
            // In overlay mode the selection rect moves, so we must reposition here.
            if showToolbars && state == .selected && !isScrollCapturing {
                if !isEditorMode { repositionToolbars() }
                // Toolbars are real NSView subviews (ToolbarStripView) — no custom drawing needed.
                // Tool options row handled by ToolOptionsRowView (real NSView subview)
                if !toolHasOptionsRow || isRecording {
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


        // Instant tooltip for hovered toolbar button
        drawHoveredTooltip()

    }
    private static let helperFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let helperSmallFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    private static let helperSmallBoldFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let helperDimColor = NSColor.white.withAlphaComponent(0.7)

    private func drawIdleHelperText() {
        let line1 =
            windowSnapEnabled
            ? L("Click a window  ·  Drag for custom area  ·  F for full screen")
            : L("Drag to select  ·  Click for full screen")
        let snapOn = windowSnapEnabled
        let line3prefix = L("Window snap: ")
        let line3state = snapOn ? L("ON") : L("OFF")
        let line3suffix = L("  (Tab to toggle)")

        let snapColor = snapOn ? NSColor.systemGreen : NSColor.systemOrange

        let attrs1: [NSAttributedString.Key: Any] = [.font: Self.helperFont, .foregroundColor: NSColor.white]
        let attrs2prefix: [NSAttributedString.Key: Any] = [
            .font: Self.helperSmallFont, .foregroundColor: Self.helperDimColor,
        ]
        let attrs2state: [NSAttributedString.Key: Any] = [
            .font: Self.helperSmallBoldFont, .foregroundColor: snapColor,
        ]
        let attrs2suffix: [NSAttributedString.Key: Any] = [
            .font: Self.helperSmallFont, .foregroundColor: Self.helperDimColor,
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

    private static let helperTextAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white,
    ]

    private func drawSelectingHelperText() {
        guard selectionRect.width >= 1, selectionRect.height >= 1 else { return }

        let text = L("Release to annotate and edit")
        let attrs = Self.helperTextAttrs
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

    private static let sizeLabelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let sizeLabelAttrs: [NSAttributedString.Key: Any] = [
        .font: sizeLabelFont,
        .foregroundColor: NSColor.white,
    ]

    private func drawSizeLabel() {
        guard sizeInputField == nil else { return }  // don't draw while editing

        // Get pixel dimensions (account for Retina)
        let scale = window?.backingScaleFactor ?? 2.0
        let pixelW = Int(selectionRect.width * scale)
        let pixelH = Int(selectionRect.height * scale)
        let text = "\(pixelW) \u{00D7} \(pixelH)"

        let attrs = Self.sizeLabelAttrs
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
            .font: Self.sizeLabelFont,
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
        let titleBarH: CGFloat = (config.mode == .window && !config.isWindowSnap) ? 28 : 0
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
        let cornerRadius = config.isWindowSnap ? 10 : config.cornerRadius  // native macOS corner radius for snapped windows
        let shadowRadius = config.shadowRadius
        let shadowOffset = min(shadowRadius * 0.4, 10)

        // Compute the expanded frame around the selection.
        // Shadow extends downward (negative Y in AppKit), so expand the origin down.
        let shadowBleed = shadowRadius + shadowOffset
        let expandedRect: NSRect
        if config.mode == .window && !config.isWindowSnap {
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
        if config.mode == .window && !config.isWindowSnap {
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

        if config.mode == .window && !config.isWindowSnap {
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

        // Drop shadow (not for snapped windows — handled via transparency layer below)
        if shadowRadius > 0 && !config.isWindowSnap {
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

        if config.isWindowSnap {
            // Snapped window: use independently captured window image (has real transparent corners).
            // Draw it directly on top of the gradient — transparent corners reveal the gradient.
            context.cgContext.saveGState()

            // Drop shadow from the window shape
            if shadowRadius > 0 {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                shadow.shadowBlurRadius = shadowRadius
                shadow.shadowOffset = NSSize(width: 0, height: -shadowOffset)
                shadow.set()
            }

            if let windowImg = snappedWindowImage {
                windowImg.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            } else if let image = screenshotImage {
                // Fallback: crop from screenshot (before window capture completes)
                let drawImage = effectsActive ? effectsProcessedScreenshot(image) : image
                drawImage.draw(
                    in: imageRect, from: selectionRect, operation: .sourceOver, fraction: 1.0)
            }

            // Draw annotations shifted to the preview position
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
        } else if config.mode == .window {
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

            // Draw screenshot in content area (clipped to window shape), with effects if active
            if let image = screenshotImage {
                let drawImage = effectsActive ? effectsProcessedScreenshot(image) : image
                drawImage.draw(
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
                let drawImage = effectsActive ? effectsProcessedScreenshot(image) : image
                drawImage.draw(in: imageRect, from: selectionRect, operation: .copy, fraction: 1.0)
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
        // Show options row for a selected annotation's tool even when currentTool is .select
        if selectedAnnotation != nil && toolOptionsRowView?.editingAnnotation != nil {
            return true
        }
        switch currentTool {
        case .pencil, .line, .arrow, .rectangle, .ellipse, .marker, .number, .loupe, .measure,
            .pixelate, .stamp:
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
        let copyText = L("Right-click to copy")
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

    /// Add a captured image as a draggable stamp annotation, placed below the current canvas.
    /// The canvas auto-expands to fit. Used by "Add Capture" in the editor.
    func addCaptureImage(_ newImage: NSImage) {
        let imgW = newImage.size.width
        let imgH = newImage.size.height

        // Place below the current canvas, left-aligned
        let placeY = -imgH  // just below origin (canvas will expand)

        let ann = Annotation(
            tool: .stamp,
            startPoint: NSPoint(x: 0, y: placeY),
            endPoint: NSPoint(x: imgW, y: placeY + imgH),
            color: NSColor.white.withAlphaComponent(0),
            strokeWidth: 0)
        ann.stampImage = newImage

        annotations.append(ann)
        undoStack.append(.added(ann))
        redoStack.removeAll()

        // Auto-select so user can move/resize immediately
        currentTool = .select
        selectedAnnotation = ann
        cachedCompositedImage = nil

        // Expand the canvas to fit the new annotation
        expandCanvasToFitAnnotations()
        rebuildToolbarLayout()
        needsDisplay = true
    }

    /// Resizes the canvas to tightly fit the original image content plus all annotations.
    /// Grows or shrinks as needed. Shifts everything so origin stays at (0,0).
    /// Only runs the expensive pixel scan when add-capture stamps are present.
    func expandCanvasToFitAnnotations() {
        guard isEditorMode, let original = screenshotImage,
              let oldCG = original.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }

        // Only resize canvas when there are add-capture image stamps that might be outside bounds.
        // Normal annotations (arrows, text, etc.) don't need canvas resizing.
        let hasImageStamps = annotations.contains { $0.tool == .stamp && $0.stampImage != nil }
        guard hasImageStamps else { return }

        let scale = CGFloat(oldCG.width) / original.size.width

        // Detect the non-transparent bounding box of the original image.
        let opaqueRect: NSRect
        if let cached = cachedOpaqueRect {
            opaqueRect = cached
        } else {
            opaqueRect = opaqueContentRect(of: oldCG, scale: scale)
            cachedOpaqueRect = opaqueRect
        }

        // Compute bounding box of opaque image content + all annotations
        var minX: CGFloat = opaqueRect.minX
        var minY: CGFloat = opaqueRect.minY
        var maxX: CGFloat = opaqueRect.maxX
        var maxY: CGFloat = opaqueRect.maxY

        for ann in annotations {
            let r = ann.boundingRect
            guard r.width > 0, r.height > 0 else { continue }
            minX = min(minX, r.minX)
            minY = min(minY, r.minY)
            maxX = max(maxX, r.maxX)
            maxY = max(maxY, r.maxY)
        }

        let targetRect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // If canvas already matches, nothing to do
        if abs(minX) < 1 && abs(minY) < 1
            && abs(maxX - selectionRect.width) < 1 && abs(maxY - selectionRect.height) < 1 {
            return
        }

        let newPtW = targetRect.width
        let newPtH = targetRect.height
        let newPxW = max(1, Int(newPtW * scale))
        let newPxH = max(1, Int(newPtH * scale))

        let cs = oldCG.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: newPxW, height: newPxH,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        // Draw old image offset so that targetRect.origin maps to (0,0)
        let drawX = -targetRect.origin.x * scale
        let drawY = -targetRect.origin.y * scale
        ctx.draw(oldCG, in: CGRect(x: drawX, y: drawY, width: CGFloat(oldCG.width), height: CGFloat(oldCG.height)))

        guard let newCG = ctx.makeImage() else { return }
        let prevImage = original.copy() as! NSImage
        let shiftDx = -targetRect.origin.x
        let shiftDy = -targetRect.origin.y
        let offsets = annotations.map { ($0, shiftDx, shiftDy) }
        undoStack.append(.imageTransform(previousImage: prevImage, annotationOffsets: offsets))

        screenshotImage = NSImage(cgImage: newCG, size: NSSize(width: newPtW, height: newPtH))
        cachedOpaqueRect = nil  // invalidate — image content changed

        // Shift all annotations so they align with the new origin
        if shiftDx != 0 || shiftDy != 0 {
            for ann in annotations {
                ann.move(dx: shiftDx, dy: shiftDy)
            }
        }

        selectionRect = NSRect(origin: .zero, size: NSSize(width: newPtW, height: newPtH))
        frame.size = NSSize(width: newPtW, height: newPtH)
        cachedCompositedImage = nil
    }

    /// Returns the bounding rect (in point coords) of non-transparent pixels in the image.
    /// Uses fast row/column scanning on the raw pixel data.
    private func opaqueContentRect(of cgImage: CGImage, scale: CGFloat) -> NSRect {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0,
              let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else {
            return NSRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        }

        let bytesPerRow = cgImage.bytesPerRow
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard bytesPerPixel >= 4 else {
            return NSRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        }

        // Alpha channel offset depends on bitmap info
        let alphaInfo = CGImageAlphaInfo(rawValue: cgImage.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        let alphaOffset: Int
        switch alphaInfo {
        case .premultipliedFirst, .first, .noneSkipFirst: alphaOffset = 0
        case .premultipliedLast, .last, .noneSkipLast: alphaOffset = 3
        default: alphaOffset = 3
        }

        var minRow = h, maxRow = 0, minCol = w, maxCol = 0

        for row in 0..<h {
            let rowBase = row * bytesPerRow
            for col in 0..<w {
                let alpha = ptr[rowBase + col * bytesPerPixel + alphaOffset]
                if alpha > 0 {
                    if row < minRow { minRow = row }
                    if row > maxRow { maxRow = row }
                    if col < minCol { minCol = col }
                    if col > maxCol { maxCol = col }
                }
            }
        }

        if minRow > maxRow {
            // Fully transparent — return full rect
            return NSRect(x: 0, y: 0, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
        }

        // CGImage rows are top-to-bottom, convert to AppKit bottom-left origin
        let ptMinX = CGFloat(minCol) / scale
        let ptMinY = CGFloat(h - 1 - maxRow) / scale
        let ptMaxX = CGFloat(maxCol + 1) / scale
        let ptMaxY = CGFloat(h - minRow) / scale
        return NSRect(x: ptMinX, y: ptMinY, width: ptMaxX - ptMinX, height: ptMaxY - ptMinY)
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

        let w = cgImage.width
        let h = cgImage.height

        let pixelX = Int(normX * CGFloat(w))
        let pixelY = Int((1.0 - normY) * CGFloat(h))

        guard pixelX >= 0, pixelX < w, pixelY >= 0, pixelY < h else {
            return nil
        }

        // Cache the bitmap context — only recreate if the image dimensions changed
        if autoMeasureBitmapCtx == nil || autoMeasureBitmapW != w || autoMeasureBitmapH != h {
            let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: srgb,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            autoMeasureBitmapCtx = ctx
            autoMeasureBitmapW = w
            autoMeasureBitmapH = h
        }

        guard let data = autoMeasureBitmapCtx?.data else { return nil }
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

    /// Half-extent of the drawing cursor preview (used for dirty rect invalidation).
    private var drawingCursorRadius: CGFloat {
        if currentTool == .marker {
            if smartMarkerEnabled {
                // Smart marker pill: height is the dominant dimension
                let h = smartMarkerLineHeight ?? (currentMarkerSize * 6)
                return h / 2
            }
            return (currentMarkerSize * 6) / 2
        } else {
            return max(currentStrokeWidth / 2, 2)
        }
    }

    private func drawDrawingCursorPreview(at center: NSPoint) {
        if currentTool == .marker && smartMarkerEnabled {
            // Smart marker: vertical pill that scales to text line height
            let h = smartMarkerLineHeight ?? (currentMarkerSize * 6)
            let w: CGFloat = min(h * 0.55, 14)
            let pillRect = NSRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: w / 2, yRadius: w / 2)
            currentColor.withAlphaComponent(0.45).setFill()
            pill.fill()
            currentColor.withAlphaComponent(0.8).setStroke()
            pill.lineWidth = 1.0
            pill.stroke()
        } else if currentTool == .marker {
            // Normal marker: circle at marker stroke size
            let radius = drawingCursorRadius
            let circleRect = NSRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let path = NSBezierPath(ovalIn: circleRect)
            currentColor.withAlphaComponent(0.35).setFill()
            path.fill()
            currentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1.0
            path.stroke()
        } else {
            // Pencil: solid dot at stroke width
            let radius = drawingCursorRadius
            let circleRect = NSRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let path = NSBezierPath(ovalIn: circleRect)
            annotationColor.setFill()
            path.fill()
            let border = NSBezierPath(ovalIn: circleRect.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1.0
            NSColor.white.withAlphaComponent(0.6).setStroke()
            border.stroke()
            let inner = NSBezierPath(ovalIn: circleRect.insetBy(dx: 0.5, dy: 0.5))
            inner.lineWidth = 0.5
            NSColor.black.withAlphaComponent(0.3).setStroke()
            inner.stroke()
        }
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

    private func drawAnnotationControls(for annotation: Annotation, fullControls: Bool = true) {
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

        // Draw accent highlight on the annotation's actual shape
        let accentHighlight = ToolbarLayout.accentColor.withAlphaComponent(0.55)
        accentHighlight.setStroke()
        switch annotation.tool {
        case .pencil, .marker:
            // Trace the actual stroke path with a glow, using a transparency layer
            // to prevent alpha compounding at self-intersections and line joins
            if let points = annotation.points, points.count >= 2 {
                let ctx = NSGraphicsContext.current?.cgContext
                ctx?.saveGState()
                ctx?.setAlpha(0.55)
                ctx?.beginTransparencyLayer(auxiliaryInfo: nil)
                let path = NSBezierPath()
                path.move(to: points[0])
                for i in 1..<points.count { path.line(to: points[i]) }
                let effectiveWidth = annotation.tool == .marker ? annotation.strokeWidth * 6 : annotation.strokeWidth
                path.lineWidth = effectiveWidth + 6
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                ToolbarLayout.accentColor.setStroke()
                path.stroke()
                ctx?.endTransparencyLayer()
                ctx?.restoreGState()
            }
        case .rectangle, .filledRectangle:
            let r = annotation.rectCornerRadius
            let shapePath = NSBezierPath(roundedRect: annotation.boundingRect, xRadius: r, yRadius: r)
            shapePath.lineWidth = annotation.strokeWidth + 6
            shapePath.lineCapStyle = .round
            shapePath.lineJoinStyle = .round
            shapePath.stroke()
        case .ellipse:
            let shapePath = NSBezierPath(ovalIn: annotation.boundingRect)
            shapePath.lineWidth = annotation.strokeWidth + 6
            shapePath.lineCapStyle = .round
            shapePath.lineJoinStyle = .round
            shapePath.stroke()
        default:
            let shapePath = NSBezierPath(roundedRect: padded, xRadius: 2, yRadius: 2)
            shapePath.lineWidth = annotation.strokeWidth + 6
            shapePath.lineCapStyle = .round
            shapePath.lineJoinStyle = .round
            shapePath.stroke()
        }

        // Skip handles, rotate, and delete buttons for multi-select (just show the glow)
        guard fullControls else {
            if annotation.rotation != 0 && annotation.supportsRotation {
                NSGraphicsContext.current?.cgContext.restoreGState()
            }
            return
        }

        // Draw resize handles (8 positions) — loupe/pencil/marker don't support resize
        if annotation.tool != .loupe && annotation.tool != .pencil && annotation.tool != .marker {
            let handles = annotationAllHandleRects(for: padded)
            annotationResizeHandleRects = handles
            for (_, rect) in handles {
                NSColor.white.setFill()
                NSBezierPath(ovalIn: rect).fill()
                ToolbarLayout.accentColor.setStroke()
                let border = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1.5
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
        // Clear tooltip before rebuilding — old button views are about to be destroyed
        hoveredTooltip = nil
        hoveredTooltipButtonView = nil

        let movableAnnotations = annotations.contains { $0.isMovable }
        bottomButtons = ToolbarLayout.bottomButtons(
            selectedTool: currentTool, selectedColor: currentColor,
            beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex,
            hasAnnotations: movableAnnotations, isRecording: isRecording,
            effectsActive: effectsActive
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
            isRecording: isRecording,
            isEditorMode: isEditorMode)

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

        // Update existing buttons if count matches, rebuild only if structure changed
        if bottomStripView?.buttonViews.count == bottomButtons.count && bottomStripView?.buttonViews.count ?? 0 > 0 {
            bottomStripView?.updateState(from: bottomButtons)
        } else {
            bottomStripView?.setButtons(bottomButtons)
            bottomStripView?.onClick = { [weak self] action in self?.handleToolbarAction(action) }
            bottomStripView?.onRightClick = { [weak self] action, view in
                self?.handleToolbarButtonRightClick(action, anchorView: view)
            }
            bottomStripView?.onHover = { [weak self] action, hovered in
                self?.handleToolbarButtonHover(action, hovered: hovered, strip: self?.bottomStripView)
            }
        }
        if rightStripView?.buttonViews.count == rightButtons.count && rightStripView?.buttonViews.count ?? 0 > 0 {
            rightStripView?.updateState(from: rightButtons)
        } else {
            rightStripView?.setButtons(rightButtons)
            rightStripView?.onClick = { [weak self] action in self?.handleToolbarAction(action) }
            rightStripView?.onRightClick = { [weak self] action, view in
                self?.handleToolbarButtonRightClick(action, anchorView: view)
            }
            rightStripView?.onHover = { [weak self] action, hovered in
                self?.handleToolbarButtonHover(action, hovered: hovered, strip: self?.rightStripView)
            }
        }
        // Move button needs onMouseDown for press-and-drag (synchronous tracking loop)
        for bv in rightStripView?.buttonViews ?? [] {
            if case .moveSelection = bv.action, bv.onMouseDown == nil {
                bv.onMouseDown = { [weak self] _ in self?.handleToolbarAction(.moveSelection) }
            }
        }

        // Rebuild options row content
        if toolHasOptionsRow {
            if toolOptionsRowView == nil {
                let row = ToolOptionsRowView()
                row.overlayView = self
                parent.addSubview(row)
                toolOptionsRowView = row
            }
            // Don't overwrite annotation-specific options when editing a selected annotation
            if let ann = selectedAnnotation, toolOptionsRowView?.editingAnnotation === ann {
                // Already showing this annotation's options — skip rebuild
            } else {
                toolOptionsRowView?.rebuild(for: currentTool)
            }
        }

        repositionToolbars()

    }

    /// Reposition toolbar strips based on current selection/bounds. Cheap — safe to call from draw().
    private func repositionToolbars() {
        guard let bottomStrip = bottomStripView, let rightStrip = rightStripView else { return }

        // In editor mode, let toolbar gap clicks pass through to the image beneath
        bottomStrip.passesThrough = isEditorMode
        rightStrip.passesThrough = isEditorMode

        let visible = showToolbars && state == .selected && !isScrollCapturing
        let bottomHasButtons = bottomStrip.buttonViews.count > 0
        bottomStrip.isHidden = !visible || !bottomHasButtons
        let rightHasButtons = rightStrip.buttonViews.count > 0
        rightStrip.isHidden = !visible || !rightHasButtons
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
            bottomStrip.frame.origin = NSPoint(x: cb.midX - bottomSize.width / 2, y: 20)
            bottomStrip.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
            rightStrip.frame.origin = NSPoint(
                x: cb.maxX - rightSize.width - 20, y: cb.maxY - rightSize.height - 36)
            rightStrip.autoresizingMask = [.minXMargin, .minYMargin]
        } else {
            let optRowH: CGFloat = 38  // options row height + gap

            // ── 1. Position right bar (anchored to selection edge) ──
            let rightMargin: CGFloat = 50
            let rightFitsRight = anchorRect.maxX < bounds.maxX - rightMargin
            let rightFitsLeft = anchorRect.minX > bounds.minX + rightMargin

            // For very narrow selections, put the right bar below instead of to the side
            let selectionTooNarrow = !rightFitsRight && !rightFitsLeft
                && anchorRect.width < bounds.width * 0.5

            var rx: CGFloat
            var ry: CGFloat

            if selectionTooNarrow {
                // Place right bar below the selection, right-aligned
                rx = anchorRect.maxX - rightSize.width
                rx = max(bounds.minX + 4, min(rx, bounds.maxX - rightSize.width - 4))
                ry = anchorRect.minY - rightSize.height - 6
                ry = max(bounds.minY + 4, min(ry, bounds.maxY - rightSize.height - 4))
            } else {
                if rightFitsRight {
                    rx = anchorRect.maxX + 6
                } else if rightFitsLeft {
                    rx = anchorRect.minX - rightSize.width - 6
                } else {
                    rx = selectionRect.maxX - rightSize.width - 6
                }
                rx = max(bounds.minX + 4, min(rx, bounds.maxX - rightSize.width - 4))

                ry = anchorRect.maxY - rightSize.height
                ry = max(bounds.minY + 4, min(ry, bounds.maxY - rightSize.height - 4))
            }

            // ── 2. Choose bottom bar Y, preferring positions that don't overlap right bar ──
            let belowY = anchorRect.minY - bottomSize.height - 6
            let belowFits = (belowY - optRowH) >= bounds.minY + 4
            let aboveY = anchorRect.maxY + optRowH + 6
            let aboveFits = (aboveY + bottomSize.height) <= bounds.maxY - 4

            // Helper: does a bottom bar at candidate Y (centered) overlap the right bar?
            let centeredBx = anchorRect.midX - bottomSize.width / 2
            let clampedCenteredBx = max(bounds.minX + 4, min(centeredBx, bounds.maxX - bottomSize.width - 4))
            func wouldOverlapRight(candidateY: CGFloat) -> Bool {
                let bMinY = candidateY - optRowH
                let bMaxY = candidateY + bottomSize.height
                guard bMaxY > ry && bMinY < ry + rightSize.height else { return false }
                let bMaxX = clampedCenteredBx + bottomSize.width
                let bMinX = clampedCenteredBx
                return bMaxX > rx && bMinX < rx + rightSize.width
            }

            var by: CGFloat
            if belowFits && !wouldOverlapRight(candidateY: belowY) {
                by = belowY
            } else if aboveFits && !wouldOverlapRight(candidateY: aboveY) {
                by = aboveY
            } else if belowFits {
                by = belowY  // overlaps but at least fits vertically
            } else if aboveFits {
                by = aboveY
            } else {
                by = selectionRect.minY + optRowH + 6
                by = max(bounds.minY + optRowH + 4, min(by, bounds.maxY - bottomSize.height - 4))
            }

            // ── 3. Position bottom bar X, avoiding right bar if they overlap vertically ──
            var bx = clampedCenteredBx
            let bottomMinY = by - optRowH
            let bottomMaxY = by + bottomSize.height
            let overlapsVertically = bottomMaxY > ry && bottomMinY < ry + rightSize.height

            if overlapsVertically {
                // Check if centered bottom bar already clears the right bar horizontally
                if bx + bottomSize.width <= rx - 4 || bx >= rx + rightSize.width + 4 {
                    // No overlap — keep both as-is
                } else {
                    // Overlap: move the RIGHT bar out of the way, keep bottom bar centered.
                    // Try pushing right bar further right (past bottom bar's right edge).
                    let pushRight = bx + bottomSize.width + 4
                    // Try pushing right bar to the left (before bottom bar's left edge).
                    let pushLeft = bx - rightSize.width - 4

                    if pushRight + rightSize.width <= bounds.maxX - 4 {
                        rx = pushRight
                    } else if pushLeft >= bounds.minX + 4 {
                        rx = pushLeft
                    } else {
                        // Right bar can't dodge horizontally — push it vertically.
                        // Try below the bottom bar + options row zone.
                        let rightPushDown = by - optRowH - rightSize.height - 4
                        if rightPushDown >= bounds.minY + 4 {
                            ry = rightPushDown
                        } else {
                            // Try above the bottom bar
                            let rightPushUp = by + bottomSize.height + 4
                            if rightPushUp + rightSize.height <= bounds.maxY - 4 {
                                ry = rightPushUp
                            }
                            // else: truly no room, accept overlap
                        }
                    }
                }
            }
            bx = max(bounds.minX + 4, min(bx, bounds.maxX - bottomSize.width - 4))

            bottomStrip.frame.origin = NSPoint(x: bx, y: by)
            rightStrip.frame.origin = NSPoint(x: rx, y: ry)
        }

        bottomBarRect = bottomStrip.frame
        rightBarRect = rightStrip.frame

        // Position options row — above bottom bar in editor, below in overlay
        if let row = toolOptionsRowView, !row.isHidden {
            // Use the wider of the bottom bar and the row's natural content width
            let rowW = max(bottomBarRect.width, row.contentWidth)
            row.frame.size.width = rowW
            let rowY: CGFloat
            if isEditorMode {
                // In editor mode, center the options row the same way as the bottom bar
                let cb = chromeParentView?.bounds ?? bounds
                let rowX = max(4, cb.midX - rowW / 2)
                row.frame.origin = NSPoint(x: rowX, y: bottomBarRect.maxY + 2)
                row.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
            } else {
                // Center the options row relative to the bottom bar, clamped to view bounds
                var rowX = bottomBarRect.midX - rowW / 2
                rowX = max(4, min(rowX, bounds.maxX - rowW - 4))
                rowY = bottomBarRect.minY - row.frame.height - 2
                row.frame.origin = NSPoint(x: rowX, y: rowY)
            }
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

    private func handleRectsForRect(_ r: NSRect) -> [(ResizeHandle, NSRect)] {
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

    private func hitTestRemoteHandle(at point: NSPoint) -> ResizeHandle {
        let r = remoteSelectionRect
        guard r.width >= 1, r.height >= 1 else { return .none }
        let hitPad: CGFloat = 2
        for (handle, rect) in handleRectsForRect(r) {
            switch handle {
            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                if rect.insetBy(dx: -hitPad, dy: -hitPad).contains(point) { return handle }
            default: break
            }
        }
        let edgeThickness: CGFloat = 6
        if NSRect(x: r.minX, y: r.maxY - edgeThickness / 2, width: r.width, height: edgeThickness).contains(point) { return .top }
        if NSRect(x: r.minX, y: r.minY - edgeThickness / 2, width: r.width, height: edgeThickness).contains(point) { return .bottom }
        if NSRect(x: r.minX - edgeThickness / 2, y: r.minY, width: edgeThickness, height: r.height).contains(point) { return .left }
        if NSRect(x: r.maxX - edgeThickness / 2, y: r.minY, width: edgeThickness, height: r.height).contains(point) { return .right }
        return .none
    }

    private func drawRemoteResizeHandles() {
        for (_, rect) in handleRectsForRect(remoteSelectionRect) {
            ToolbarLayout.handleColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    /// Returns the anchor point (fixed corner) for a given resize handle on a rect.
    private func anchorForHandle(_ handle: ResizeHandle, in r: NSRect) -> NSPoint {
        switch handle {
        case .topLeft:     return NSPoint(x: r.maxX, y: r.minY)
        case .topRight:    return NSPoint(x: r.minX, y: r.minY)
        case .bottomLeft:  return NSPoint(x: r.maxX, y: r.maxY)
        case .bottomRight: return NSPoint(x: r.minX, y: r.maxY)
        case .top:         return NSPoint(x: r.midX, y: r.minY)
        case .bottom:      return NSPoint(x: r.midX, y: r.maxY)
        case .left:        return NSPoint(x: r.maxX, y: r.midY)
        case .right:       return NSPoint(x: r.minX, y: r.midY)
        case .none, .move:  return .zero
        }
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Auto-measure: click to commit the preview annotation
        if autoMeasureKeyHeld, let preview = autoMeasurePreview {
            annotations.append(preview)
            undoStack.append(.added(preview))
            redoStack.removeAll()
            autoMeasurePreview = nil
            cachedCompositedImage = nil
            // Recompute a new preview at the current position
            updateAutoMeasurePreview()
            return
        }

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
                showOverlayError(String(format: L("Copied %@"), result.hex))
                needsDisplay = true
            }
            return
        }

        // Control-click on line/arrow: add anchor point (same as right-click)
        if event.modifierFlags.contains(.control) && state == .selected {
            if let ann = selectedAnnotation,
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
            // Check remote selection handles for cross-screen resize
            if remoteSelectionRect.width >= 1 && remoteSelectionRect.height >= 1 {
                let remoteHandle = hitTestRemoteHandle(at: point)
                if remoteHandle != .none {
                    isResizingRemoteSelection = true
                    remoteResizeHandle = remoteHandle
                    remoteResizeAnchor = anchorForHandle(remoteHandle, in: remoteSelectionFullRect)
                    return
                }
                return
            }
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

            // Check handles (disabled in editor)
            if shouldAllowSelectionResize() {
                let handle = hitTestHandle(at: point)
                if handle != .none {
                    isResizingSelection = true
                    selectionIsWindowSnap = false
                    snappedWindowID = nil
                    snappedWindowImage = nil
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

        // Cancel long-press timer if the user moved more than 3px (they're drawing, not selecting)
        if longPressTimer != nil {
            let dx = point.x - longPressPoint.x
            let dy = point.y - longPressPoint.y
            if dx * dx + dy * dy > 9 {
                longPressTimer?.invalidate()
                longPressTimer = nil
            }
        }

        // If long-press already triggered selection, handle as annotation drag
        if longPressTriggered && isDraggingAnnotation {
            // Fall through to the annotation drag handling below
        }

        // Remote selection resize (cross-screen)
        if isResizingRemoteSelection {
            let anchor = remoteResizeAnchor
            let fullRect = remoteSelectionFullRect
            var newRect = NSRect(
                x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
            // For edge handles, preserve the dimension that shouldn't change
            switch remoteResizeHandle {
            case .top, .bottom:
                newRect.origin.x = fullRect.origin.x
                newRect.size.width = fullRect.width
            case .left, .right:
                newRect.origin.y = fullRect.origin.y
                newRect.size.height = fullRect.height
            default: break
            }
            // Update full rect and clip for local display
            remoteSelectionFullRect = newRect
            let screenBounds = NSRect(origin: .zero, size: bounds.size)
            let clipped = newRect.intersection(screenBounds)
            remoteSelectionRect = clipped.isEmpty ? .zero : clipped
            // Update primary + other screens
            overlayDelegate?.overlayViewRemoteSelectionDidChange(newRect)
            needsDisplay = true
            return
        }

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
                // Shift: snap to 45° steps
                if NSEvent.modifierFlags.contains(.shift) {
                    let step = CGFloat.pi / 4
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
                if annotation.tool == .pixelate { annotation.bakedBlurNSImage = nil }
                cachedCompositedImage = nil
                needsDisplay = true
            } else if isDraggingAnnotation, !selectedAnnotations.isEmpty {
                let rawDx = canvasPoint.x - annotationDragStart.x
                let rawDy = canvasPoint.y - annotationDragStart.y
                // For single selection, apply snap; for multi, just move raw
                let finalDx: CGFloat
                let finalDy: CGFloat
                if selectedAnnotations.count == 1, let annotation = selectedAnnotations.first {
                    let movedRect = annotation.boundingRect.offsetBy(dx: rawDx, dy: rawDy)
                    let snap = snapRectDelta(rect: movedRect, excluding: annotation)
                    finalDx = rawDx + snap.dx
                    finalDy = rawDy + snap.dy
                    annotationDragStart = NSPoint(
                        x: canvasPoint.x + snap.dx, y: canvasPoint.y + snap.dy)
                } else {
                    finalDx = rawDx
                    finalDy = rawDy
                    annotationDragStart = canvasPoint
                }
                for annotation in selectedAnnotations {
                    annotation.move(dx: finalDx, dy: finalDy)
                }
                didMoveAnnotation = true
                cachedCompositedImage = nil
                needsDisplay = true
            } else if isDraggingSelection {
                selectionRect.origin = NSPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y)
                needsDisplay = true
            } else if isResizingSelection {
                resizeSelection(to: point)
                overlayDelegate?.overlayViewSelectionDidChange(selectionRect)
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

        // Clean up long-press timer
        longPressTimer?.invalidate()
        longPressTimer = nil
        longPressTriggered = false

        // Finish remote selection resize — final sync + transfer focus to the primary
        if isResizingRemoteSelection {
            isResizingRemoteSelection = false
            remoteResizeHandle = .none
            overlayDelegate?.overlayViewRemoteSelectionDidFinish(remoteSelectionFullRect)
            return
        }

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
            NSCursor.openHand.set()
            needsDisplay = true
            return
        }
        if isResizingAnnotation {
            isResizingAnnotation = false
            annotationResizeHandle = .none
            if let ann = selectedAnnotation {
                if ann.tool == .loupe { ann.bakeLoupe() }
                if ann.tool == .pixelate { ann.bakedBlurNSImage = nil; ann.bakePixelate() }
            }
            NSCursor.openHand.set()
            needsDisplay = true
            return
        }
        lastDragPoint = nil
        switch state {
        case .selecting:
            if selectionRect.width > 5 || selectionRect.height > 5 {
                // Real drag — use drawn rect as-is
                state = .selected
                if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode { showToolbars = true }
                overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
            } else if windowSnapEnabled, let snapRect = hoveredWindowRect, !snapRect.isEmpty {
                // Click (no drag) with snap on — snap to hovered window
                selectionRect = snapRect
                selectionIsWindowSnap = true
                snappedWindowID = hoveredWindowID
                // Capture the window independently for beautify (transparent corners)
                if let wid = hoveredWindowID, let screen = window?.screen {
                    Task {
                        if let cgImage = await ScreenCaptureManager.captureWindow(windowID: wid, screen: screen) {
                            self.snappedWindowImage = NSImage(cgImage: cgImage,
                                size: NSSize(width: CGFloat(cgImage.width) / screen.backingScaleFactor,
                                             height: CGFloat(cgImage.height) / screen.backingScaleFactor))
                            self.needsDisplay = true
                        }
                    }
                }
                state = .selected
                if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode { showToolbars = true }
                overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
            } else {
                // Click (no drag), snap off — expand to full screen
                selectionRect = bounds
                state = .selected
                if !autoOCRMode && !autoQuickSaveMode && !autoScrollCaptureMode && !autoConfirmMode { showToolbars = true }
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
            // Auto-trigger scroll capture if triggered from "Scroll Capture"
            if autoScrollCaptureMode {
                autoScrollCaptureMode = false
                overlayDelegate?.overlayViewDidRequestScrollCapture(rect: selectionRect)
            }
            // Auto-confirm for "Add Capture" — just confirm selection, no save/copy
            if autoConfirmMode {
                autoConfirmMode = false
                overlayDelegate?.overlayViewDidConfirm()
            }
            needsDisplay = true

        case .selected:
            if isDraggingAnnotation {
                // Deferred shift+click deselect: only remove the annotation if
                // the user didn't drag (i.e. it was a click, not a move).
                if let pending = shiftClickPendingDeselect {
                    shiftClickPendingDeselect = nil
                    if !didMoveAnnotation {
                        if let idx = selectedAnnotations.firstIndex(where: { $0 === pending }) {
                            selectedAnnotations.remove(at: idx)
                        }
                    }
                }
                isDraggingAnnotation = false
                didMoveAnnotation = false
                snapGuideX = nil
                snapGuideY = nil
                NSCursor.openHand.set()
                for ann in selectedAnnotations {
                    if ann.tool == .loupe { ann.bakeLoupe() }
                    if ann.tool == .pixelate { ann.bakedBlurNSImage = nil; ann.bakePixelate() }
                }
                // Auto-expand canvas if annotation was dragged outside bounds (editor mode)
                expandCanvasToFitAnnotations()
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

        // Right-click on a line/arrow/measure: add anchor point.
        // Auto-selects the annotation if it isn't selected yet.
        if state == .selected {
            let canvasPoint = viewToCanvas(point)
            // Check already-selected annotation first
            if let ann = selectedAnnotation,
                (ann.tool == .arrow || ann.tool == .line || ann.tool == .measure),
                ann.hitTest(point: canvasPoint)
            {
                addAnchorPoint(to: ann, at: canvasPoint)
                cachedCompositedImage = nil
                needsDisplay = true
                return
            }
            // Check any unselected line/arrow/measure under the cursor
            if let ann = annotations.reversed().first(where: {
                ($0.tool == .arrow || $0.tool == .line || $0.tool == .measure)
                && $0.hitTest(point: canvasPoint)
            }) {
                selectedAnnotation = ann
                addAnchorPoint(to: ann, at: canvasPoint)
                cachedCompositedImage = nil
                needsDisplay = true
                return
            }
        }

        if state == .selected && currentTool == .colorSampler {
            // Right-click with color sampler: copy hex to clipboard
            if let screenshot = screenshotImage,
                let result = sampleColor(from: screenshot, at: viewToCanvas(point))
            {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.hex, forType: .string)
                showOverlayError(String(format: L("Copied %@"), result.hex))
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
                rebuildToolbarLayout()
            }
            colorWheel.dismiss()
            colorWheel.hoveredIndex = -1
            needsDisplay = true
            return
        }
    }

    // MARK: - Zoom (scroll wheel + trackpad pinch)

    private var editorZoomRedrawTimer: Timer?

    /// Perform cursor-centered zoom on the enclosing scroll view.
    /// Uses NSScrollView's own setMagnification(_:centeredAt:) which handles all the
    /// coordinate math correctly, but we disable allowsMagnification so it doesn't
    /// apply its own elastic physics on top.
    // Animated zoom state for smooth mouse wheel zooming
    private var editorZoomTarget: CGFloat = 1.0
    private var editorZoomAnimTimer: Timer?
    private var editorZoomCursorDoc: NSPoint = .zero

    func editorZoom(by factor: CGFloat, cursorInWindow: NSPoint, animated: Bool = false) {
        guard let sv = enclosingScrollView else { return }

        if animated {
            // Accumulate target and animate toward it
            if editorZoomAnimTimer == nil {
                editorZoomTarget = sv.magnification
            }
            editorZoomTarget = max(sv.minMagnification, min(sv.maxMagnification, editorZoomTarget * factor))
            editorZoomCursorDoc = convert(cursorInWindow, from: nil)

            if editorZoomAnimTimer == nil {
                editorZoomAnimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                    guard let self = self, let sv = self.enclosingScrollView else {
                        timer.invalidate()
                        return
                    }
                    let current = sv.magnification
                    let target = self.editorZoomTarget
                    let diff = target - current
                    if abs(diff) < 0.001 {
                        sv.setMagnification(target, centeredAt: self.editorZoomCursorDoc)
                        timer.invalidate()
                        self.editorZoomAnimTimer = nil
                        self.needsDisplay = true
                        if let topBar = sv.superview?.subviews.compactMap({ $0 as? EditorTopBarView }).first {
                            topBar.updateZoom(target)
                        }
                        return
                    }
                    // Ease toward target: move 25% of remaining distance per frame
                    let next = current + diff * 0.25
                    sv.setMagnification(next, centeredAt: self.editorZoomCursorDoc)
                    if let topBar = sv.superview?.subviews.compactMap({ $0 as? EditorTopBarView }).first {
                        topBar.updateZoom(next)
                    }
                }
            }
            return
        }

        let oldMag = sv.magnification
        let newMag = max(sv.minMagnification, min(sv.maxMagnification, oldMag * factor))
        guard newMag != oldMag else { return }

        // Convert cursor from window coords to document view (unscaled) coords
        let cursorInDoc = convert(cursorInWindow, from: nil)
        sv.setMagnification(newMag, centeredAt: cursorInDoc)

        // During active zooming, let the GPU-scaled layer handle the visual — it's instant.
        // Debounce the full-resolution redraw to when zooming stops (150ms idle).
        editorZoomRedrawTimer?.invalidate()
        editorZoomRedrawTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.needsDisplay = true
        }

        if let topBar = sv.superview?.subviews.compactMap({ $0 as? EditorTopBarView }).first {
            topBar.updateZoom(newMag)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // Editor mode: all scroll handling is done by CenteringClipView
        if isInsideScrollView {
            enclosingScrollView?.scrollWheel(with: event)
            return
        }
        guard state == .selected else { return }
        let isTrackpadPhased = event.phase != [] || event.momentumPhase != []
        let isCommandScroll = event.modifierFlags.contains(.command)

        // Phase-based (trackpad) scroll without Cmd → pan only, never zoom
        // Suppress panning while actively drawing to prevent pan+draw conflict (Apple Pencil / Sidecar)
        if isTrackpadPhased && !isCommandScroll && currentAnnotation != nil { return }
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
            editorZoom(by: 1.0 + event.magnification, cursorInWindow: event.locationInWindow)
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
        // In editor mode, tooltips are drawn via a floating NSView in the chrome parent
        if isEditorMode {
            updateEditorTooltipView()
            return
        }

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

    /// In editor mode, show tooltip as a floating NSView in the chrome parent (container),
    /// since EditorView's draw() can only paint within the image bounds.
    private func updateEditorTooltipView() {
        guard let parent = chromeParentView else {
            editorTooltipView?.removeFromSuperview()
            editorTooltipView = nil
            return
        }

        guard let tooltip = hoveredTooltip, !tooltip.isEmpty,
              let btn = hoveredTooltipButtonView,
              !PopoverHelper.isVisible else {
            editorTooltipView?.removeFromSuperview()
            editorTooltipView = nil
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = tooltip as NSString
        let textSize = str.size(withAttributes: attrs)
        let pad: CGFloat = 6
        let tipW = textSize.width + pad * 2
        let tipH = textSize.height + pad

        let btnFrame = btn.convert(btn.bounds, to: parent)
        let isBottomBar = btn.superview === bottomStripView
        let tipRect: NSRect

        if isBottomBar {
            let stripFrame = bottomStripView?.frame ?? .zero
            var tipY = stripFrame.maxY + 4
            if tipY + tipH > parent.bounds.maxY - 2 { tipY = stripFrame.minY - tipH - 4 }
            tipRect = NSRect(x: btnFrame.midX - tipW / 2, y: tipY, width: tipW, height: tipH)
        } else {
            tipRect = NSRect(x: btnFrame.minX - tipW - 6, y: btnFrame.midY - tipH / 2, width: tipW, height: tipH)
        }

        let clamped = NSRect(
            x: max(parent.bounds.minX + 2, min(tipRect.minX, parent.bounds.maxX - tipW - 2)),
            y: max(parent.bounds.minY + 2, min(tipRect.minY, parent.bounds.maxY - tipH - 2)),
            width: tipW, height: tipH)

        let tip: TooltipBackgroundView
        if let existing = editorTooltipView as? TooltipBackgroundView {
            tip = existing
        } else {
            editorTooltipView?.removeFromSuperview()
            tip = TooltipBackgroundView(frame: clamped)
            parent.addSubview(tip)
            editorTooltipView = tip
        }
        tip.frame = clamped
        tip.text = tooltip
        tip.needsDisplay = true
    }

    private func handleToolbarButtonRightClick(_ action: ToolbarButtonAction, anchorView: NSView) {
        switch action {
        case .autoRedact:
            showRedactTypePopover(
                anchorRect: anchorView.convert(anchorView.bounds, to: self), anchorView: anchorView)
        case .save:
            let menu = NSMenu()
            let saveAsItem = NSMenuItem(
                title: L("Save As..."), action: #selector(saveAsMenuAction), keyEquivalent: "")
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
        case .micAudio:
            showMicDeviceMenu(anchorView: anchorView)
        case .showKeystrokes:
            showKeystrokeModeMenu(anchorView: anchorView)
        case .webcam:
            showWebcamDeviceMenu(anchorView: anchorView)
        default:
            break
        }
    }

    private func showKeystrokeModeMenu(anchorView: NSView) {
        let menu = NSMenu()
        let allKeys = UserDefaults.standard.bool(forKey: "keystrokeShowAll")

        let shortcutsItem = NSMenuItem(title: L("Shortcuts Only"), action: #selector(keystrokeModeShortcuts), keyEquivalent: "")
        shortcutsItem.target = self
        if !allKeys { shortcutsItem.state = .on }
        menu.addItem(shortcutsItem)

        let allItem = NSMenuItem(title: L("All Keystrokes"), action: #selector(keystrokeModeAll), keyEquivalent: "")
        allItem.target = self
        if allKeys { allItem.state = .on }
        menu.addItem(allItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height), in: anchorView)
    }

    @objc private func keystrokeModeShortcuts() {
        UserDefaults.standard.set(false, forKey: "keystrokeShowAll")
    }

    @objc private func keystrokeModeAll() {
        UserDefaults.standard.set(true, forKey: "keystrokeShowAll")
    }

    private func showMicDeviceMenu(anchorView: NSView) {
        let menu = NSMenu()
        let savedUID = UserDefaults.standard.string(forKey: "selectedMicDeviceUID")
        let micOn = UserDefaults.standard.bool(forKey: "recordMicAudio")

        // "None" option — turns off mic recording
        let noneItem = NSMenuItem(title: L("None"), action: #selector(micMenuNone), keyEquivalent: "")
        noneItem.target = self
        if !micOn { noneItem.state = .on }
        menu.addItem(noneItem)
        menu.addItem(NSMenuItem.separator())

        // List available audio input devices (filter out virtual aggregate devices)
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio, position: .unspecified).devices
            .filter { !$0.uniqueID.contains("CADefaultDeviceAggregate") }
        for device in devices {
            let item = NSMenuItem(title: device.localizedName, action: #selector(micMenuSelectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID
            if micOn && (savedUID == device.uniqueID || (savedUID == nil && device == AVCaptureDevice.default(for: .audio))) {
                item.state = .on
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height), in: anchorView)
    }

    @objc private func micMenuNone() {
        UserDefaults.standard.set(false, forKey: "recordMicAudio")
        stopMicLevelMonitor()
        rebuildToolbarLayout()
    }

    @objc private func micMenuSelectDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        UserDefaults.standard.set(uid, forKey: "selectedMicDeviceUID")
        UserDefaults.standard.set(true, forKey: "recordMicAudio")
        rebuildToolbarLayout()
        startMicLevelMonitor()
    }

    // MARK: - Recording Permission Pre-checks

    /// Sequentially request mic and camera permissions so system dialogs don't overlap behind the overlay.
    private func preCheckRecordingPermissions() {
        checkMicPermission { [weak self] in
            self?.checkCameraPermission()
        }
    }

    private func checkMicPermission(then next: @escaping () -> Void) {
        guard UserDefaults.standard.bool(forKey: "recordMicAudio") else { next(); return }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            startMicLevelMonitor()
            next()
        } else if status == .notDetermined {
            let savedLevel = window?.level
            window?.level = .normal
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if let saved = savedLevel { self?.window?.level = saved }
                    if granted {
                        self?.startMicLevelMonitor()
                    } else {
                        UserDefaults.standard.set(false, forKey: "recordMicAudio")
                        self?.rebuildToolbarLayout()
                    }
                    next()
                }
            }
        } else {
            UserDefaults.standard.set(false, forKey: "recordMicAudio")
            rebuildToolbarLayout()
            showMicPermissionAlert()
            next()
        }
    }

    private func checkCameraPermission() {
        guard UserDefaults.standard.bool(forKey: "recordWebcam") else { return }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized {
            showWebcamSetupPreview()
        } else if status == .notDetermined {
            let savedLevel = window?.level
            window?.level = .normal
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if let saved = savedLevel { self?.window?.level = saved }
                    if granted {
                        self?.showWebcamSetupPreview()
                    } else {
                        UserDefaults.standard.set(false, forKey: "recordWebcam")
                        self?.rebuildToolbarLayout()
                    }
                }
            }
        } else {
            UserDefaults.standard.set(false, forKey: "recordWebcam")
            rebuildToolbarLayout()
        }
    }

    // MARK: - Webcam Toggle & Device Menu

    private func toggleWebcamOverlay() {
        let current = UserDefaults.standard.bool(forKey: "recordWebcam")
        if current {
            UserDefaults.standard.set(false, forKey: "recordWebcam")
            dismissWebcamSetupPreview()
            rebuildToolbarLayout()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            UserDefaults.standard.set(true, forKey: "recordWebcam")
            rebuildToolbarLayout()
            showWebcamSetupPreview()
        case .notDetermined:
            let savedLevel = window?.level
            window?.level = .normal
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if let saved = savedLevel { self?.window?.level = saved }
                    if granted {
                        UserDefaults.standard.set(true, forKey: "recordWebcam")
                        self?.showWebcamSetupPreview()
                    }
                    self?.rebuildToolbarLayout()
                }
            }
        case .denied, .restricted:
            showCameraPermissionAlert()
        @unknown default:
            break
        }
    }

    private func showWebcamSetupPreview() {
        guard webcamSetupPreview == nil else { return }
        guard let screen = window?.screen ?? NSScreen.main else { return }

        let overlay = WebcamOverlay(screen: screen)
        let position = WebcamPosition(rawValue: UserDefaults.standard.string(forKey: "webcamPosition") ?? "bottomRight") ?? .bottomRight
        let size = WebcamSize(rawValue: UserDefaults.standard.string(forKey: "webcamSize") ?? "medium") ?? .medium
        let shape = WebcamShape(rawValue: UserDefaults.standard.string(forKey: "webcamShape") ?? "circle") ?? .circle

        let screenOrigin = screen.frame.origin
        let screenRect = NSRect(
            x: selectionRect.origin.x + screenOrigin.x,
            y: selectionRect.origin.y + screenOrigin.y,
            width: selectionRect.width,
            height: selectionRect.height)

        overlay.configure(position: position, size: size, shape: shape, recordingRect: screenRect)
        overlay.startPreview(deviceUID: UserDefaults.standard.string(forKey: "selectedCameraDeviceUID"))
        overlay.setDraggable(true)
        overlay.orderFront(nil)
        webcamSetupPreview = overlay
    }

    private func dismissWebcamSetupPreview() {
        webcamSetupPreview?.stopPreview()
        webcamSetupPreview?.close()
        webcamSetupPreview = nil
    }

    /// Detach the setup preview so it can be reused during recording (avoids camera restart).
    func detachWebcamSetupPreview() -> WebcamOverlay? {
        let overlay = webcamSetupPreview
        webcamSetupPreview = nil
        return overlay
    }

    func updateWebcamSetupPreview() {
        guard webcamSetupPreview != nil else { return }
        dismissWebcamSetupPreview()
        if UserDefaults.standard.bool(forKey: "recordWebcam") {
            showWebcamSetupPreview()
        }
    }

    private func showCameraPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = L("Camera Access Required")
        alert.informativeText = L("macshot needs camera permission for the webcam overlay. Open System Settings to grant access.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showWebcamDeviceMenu(anchorView: NSView) {
        let menu = NSMenu()
        let savedUID = UserDefaults.standard.string(forKey: "selectedCameraDeviceUID")
        let webcamOn = UserDefaults.standard.bool(forKey: "recordWebcam")

        let noneItem = NSMenuItem(title: L("None"), action: #selector(webcamMenuNone), keyEquivalent: "")
        noneItem.target = self
        if !webcamOn { noneItem.state = .on }
        menu.addItem(noneItem)
        menu.addItem(NSMenuItem.separator())

        let devices = WebcamOverlay.availableCameras
        for device in devices {
            let item = NSMenuItem(title: device.localizedName, action: #selector(webcamMenuSelectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID
            if webcamOn && (savedUID == device.uniqueID || (savedUID == nil && device == AVCaptureDevice.default(for: .video))) {
                item.state = .on
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height), in: anchorView)
    }

    @objc private func webcamMenuNone() {
        UserDefaults.standard.set(false, forKey: "recordWebcam")
        dismissWebcamSetupPreview()
        rebuildToolbarLayout()
    }

    @objc private func webcamMenuSelectDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        UserDefaults.standard.set(uid, forKey: "selectedCameraDeviceUID")
        UserDefaults.standard.set(true, forKey: "recordWebcam")
        rebuildToolbarLayout()
        updateWebcamSetupPreview()
    }

    func handleToolbarAction(_ action: ToolbarButtonAction, mousePoint: NSPoint = .zero) {
        switch action {
        case .tool(let tool):
            if tool == .select && !annotations.contains(where: { $0.isMovable }) {
                showOverlayError(L("Draw something first to use the move tool."))
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
            guard let win = window else { break }
            // Moving breaks window snap — revert to normal beautify mode
            if selectionIsWindowSnap {
                selectionIsWindowSnap = false
                snappedWindowID = nil
                snappedWindowImage = nil
                rebuildToolbarLayout()
            }
            // Show drag hint tooltip
            hoveredTooltip = L("Drag to reposition")
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
            // Restore original tooltip and reset button pressed state
            hoveredTooltip = hoveredTooltipButtonView?.tooltipText
            if let moveBtn = rightStripView?.buttonViews.first(where: { if case .moveSelection = $0.action { return true }; return false }) {
                moveBtn.isPressed = false
                moveBtn.needsDisplay = true
            }
            scheduleBarcodeDetection()
            updateWebcamSetupPreview()
            needsDisplay = true
        case .undo:
            undo()
        case .redo:
            redo()
        case .copy:
            overlayDelegate?.overlayViewDidConfirm()
        case .save:
            overlayDelegate?.overlayViewDidRequestFileSave()
        case .upload:
            let confirmEnabled = UserDefaults.standard.bool(forKey: "uploadConfirmEnabled")
            if confirmEnabled {
                let provider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"
                let title: String
                switch provider {
                case "gdrive": title = L("Upload to Google Drive?")
                case "s3": title = L("Upload to S3?")
                default: title = L("Upload to imgbb.com?")
                }
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = L("Your screenshot will be uploaded.")
                alert.addButton(withTitle: L("Upload"))
                alert.addButton(withTitle: L("Cancel"))
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
        case .effects:
            let btn = bottomStripView?.buttonViews.first { if case .effects = $0.action { return true }; return false }
            showEffectsPopover(anchorView: btn)
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
            // Enter recording mode — shows recording setup toolbar
            overlayDelegate?.overlayViewDidRequestEnterRecordingMode()
        case .startRecord:
            // Start recording — overlay will be dismissed by AppDelegate
            overlayDelegate?.overlayViewDidRequestStartRecording(rect: selectionRect)
        case .stopRecord:
            // Exit recording mode — dismiss overlay entirely (user changed mind)
            isRecording = false
            overlayDelegate?.overlayViewDidCancel()
        case .mouseHighlight:
            let current = UserDefaults.standard.bool(forKey: "recordMouseHighlight")
            UserDefaults.standard.set(!current, forKey: "recordMouseHighlight")
            rebuildToolbarLayout()
        case .showKeystrokes:
            toggleKeystrokeOverlay()
        case .systemAudio:
            let current = UserDefaults.standard.bool(forKey: "recordSystemAudio")
            UserDefaults.standard.set(!current, forKey: "recordSystemAudio")
            rebuildToolbarLayout()
        case .micAudio:
            toggleMicAudio()
        case .webcam:
            toggleWebcamOverlay()
        case .cancel:
            overlayDelegate?.overlayViewDidCancel()
        case .detach:
            overlayDelegate?.overlayViewDidRequestDetach()
        case .scrollCapture:
            overlayDelegate?.overlayViewDidRequestScrollCapture(rect: selectionRect)
        case .addCapture:
            overlayDelegate?.overlayViewDidRequestAddCapture()
        case .recordSettings:
            let gearBtn = rightStripView?.buttonViews.first { if case .recordSettings = $0.action { return true }; return false }
            showRecordingSettingsPopover(anchorView: gearBtn)
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

    /// Push a property change undo entry. Called by ToolOptionsRowView when editing completes.
    func updateBeautifySwatch(styleIndex: Int) {
        toolOptionsRowView?.updateBeautifySwatch(styleIndex: styleIndex)
    }

    func pushPropertyChangeUndo(annotation: Annotation, snapshot: Annotation) {
        undoStack.append(.propertyChange(annotation: annotation, snapshot: snapshot))
        redoStack.removeAll()
        cachedCompositedImage = nil
    }

    private func applyColorToSelectedAnnotation() {
        guard !selectedAnnotations.isEmpty else { return }
        for ann in selectedAnnotations {
            ann.color = opacityAppliedColor(for: ann.tool)
        }
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
        // No drawing in recording setup mode
        guard !isRecording else { return }

        // Click-to-select: if clicking on an existing annotation, select it instead of
        // starting a new annotation. Pencil and marker use long-press instead (so taps
        // and drags always draw, even single dots).
        let isPencilOrMarker = currentTool == .pencil || currentTool == .marker

        // Always check selected annotation controls (delete, resize, etc.) for all tools
        if currentTool != .colorSampler && currentTool != .text {
            if let selected = selectedAnnotation {
                if handleSelectedAnnotationClick(selected, at: point) { return }
            }
        }

        // Click-to-select body: for pencil/marker, only instant-select when Shift is held
        // (otherwise they use long-press below to avoid accidental selection while drawing).
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        let useInstantSelect = currentTool != .colorSampler && currentTool != .text
            && (!isPencilOrMarker || shiftHeld)
        if useInstantSelect {
            if let clicked = annotations.reversed().first(where: { $0.isMovable && $0.hitTest(point: point) }) {
                shiftClickPendingDeselect = nil
                if shiftHeld {
                    if isSelected(clicked) {
                        // Defer deselect to mouseUp — allows dragging the full
                        // multi-selection even when shift+clicking a selected item.
                        shiftClickPendingDeselect = clicked
                    } else {
                        selectedAnnotations.append(clicked)
                    }
                } else if !isSelected(clicked) {
                    // Not Shift, not already selected: replace selection
                    selectedAnnotation = clicked
                }
                // If already selected without Shift: keep current selection (allows multi-drag)
                isDraggingAnnotation = true
                didMoveAnnotation = false
                annotationDragStart = point
                NSCursor.closedHand.set()
                needsDisplay = true
                return
            }
        }

        // Pencil/marker without Shift: start a long-press timer. If the user holds
        // still for 300ms on an annotation, select it. Otherwise drawing starts
        // normally (the timer is cancelled in mouseDragged when movement exceeds 3px).
        if isPencilOrMarker && !shiftHeld {
            let hasAnnotationUnder = annotations.reversed().contains(where: { $0.isMovable && $0.hitTest(point: point) })
            if hasAnnotationUnder {
                longPressPoint = point
                longPressTriggered = false
                longPressTimer?.invalidate()
                longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.longPressTriggered = true
                    self.longPressTimer = nil
                    // Select the annotation under the long-press point
                    if let clicked = self.annotations.reversed().first(where: { $0.isMovable && $0.hitTest(point: point) }) {
                        self.shiftClickPendingDeselect = nil
                        if NSEvent.modifierFlags.contains(.shift) {
                            if self.isSelected(clicked) {
                                self.shiftClickPendingDeselect = clicked
                            } else {
                                self.selectedAnnotations.append(clicked)
                            }
                        } else if !self.isSelected(clicked) {
                            self.selectedAnnotation = clicked
                        }
                        self.isDraggingAnnotation = true
                        self.didMoveAnnotation = false
                        self.annotationDragStart = point
                        // Cancel any in-progress pencil stroke
                        self.currentAnnotation = nil
                        NSCursor.closedHand.set()
                        self.needsDisplay = true
                    }
                }
            }
        }

        // Clicking empty space — clear selection and start new annotation
        if !selectedAnnotations.isEmpty { selectedAnnotations = [] }

        // Dispatch to extracted tool handler if available
        if let handler = toolHandlers[currentTool] {
            if let annotation = handler.start(at: point, canvas: self) {
                // Apply outline color from settings for supported tools
                let outlineTools: [AnnotationTool] = [.arrow, .line, .rectangle, .ellipse, .number]
                if outlineTools.contains(currentTool) && UserDefaults.standard.bool(forKey: "annotationOutlineEnabled") {
                    annotation.outlineColor = ToolOptionsRowView.savedOutlineColor
                }
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
                showOverlayError(String(format: L("Set color %@"), result.hex))
                needsDisplay = true
            }
            return
        }

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

    /// Handle click on the selected annotation's controls (resize handles, rotation, delete).
    /// Returns true if the click was consumed. Does NOT check the annotation body — that's
    /// handled by the caller's hit-test loop.
    private func handleSelectedAnnotationClick(_ selected: Annotation, at point: NSPoint) -> Bool {
        // Unrotate point for resize handle hit test
        let handleTestPoint: NSPoint
        if selected.rotation != 0 && selected.supportsRotation {
            let center = NSPoint(x: selected.boundingRect.midX, y: selected.boundingRect.midY)
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
        // Check resize handles (populated by drawAnnotationControls)
        for (handleIdx, handleEntry) in annotationResizeHandleRects.enumerated() {
            let (handle, rect) = handleEntry
            if rect.insetBy(dx: -4, dy: -4).contains(handleTestPoint) {
                isResizingAnnotation = true
                annotationResizeHandle = handle
                annotationResizeOrigStart = selected.startPoint
                annotationResizeOrigEnd = selected.endPoint
                annotationResizeOrigTextOrigin = selected.textDrawRect.origin
                annotationResizeMouseStart = point
                annotationResizeAnchorIndex = -1
                if let anchors = selected.anchorPoints, anchors.count >= 3, handleIdx >= 2 {
                    let anchorIdx = handleIdx - 2 + 1
                    if anchorIdx > 0 && anchorIdx < anchors.count - 1 {
                        annotationResizeAnchorIndex = anchorIdx
                        annotationResizeOrigControlPoint = anchors[anchorIdx]
                    }
                } else if handle == .none || (handle != .bottomLeft && handle != .topRight) {
                    if annotationResizeAnchorIndex < 0 {
                        annotationResizeOrigControlPoint =
                            selected.controlPoint
                            ?? NSPoint(
                                x: (selected.startPoint.x + selected.endPoint.x) / 2,
                                y: (selected.startPoint.y + selected.endPoint.y) / 2
                            )
                    }
                }
                NSCursor.closedHand.set()
                needsDisplay = true
                return true
            }
        }
        // Check rotation handle
        if annotationRotateHandleRect != .zero
            && annotationRotateHandleRect.insetBy(dx: -6, dy: -6).contains(point)
        {
            isRotatingAnnotation = true
            let center = NSPoint(x: selected.boundingRect.midX, y: selected.boundingRect.midY)
            rotationStartAngle = atan2(point.x - center.x, point.y - center.y)
            rotationOriginal = selected.rotation
            NSCursor.closedHand.set()
            needsDisplay = true
            return true
        }
        // Check edit button (text annotations)
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
            return true
        }
        // Check delete button
        if annotationDeleteButtonRect.contains(point) {
            if let idx = annotations.firstIndex(where: { $0 === selected }) {
                annotations.remove(at: idx)
                undoStack.append(.deleted(selected, idx))
                redoStack.removeAll()
            }
            selectedAnnotation = nil
            needsDisplay = true
            return true
        }
        // Click on the annotation body — start drag (annotation already selected)
        if selected.hitTest(point: point) {
            isDraggingAnnotation = true
            didMoveAnnotation = false
            annotationDragStart = point
            NSCursor.closedHand.set()
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

    private func toggleKeystrokeOverlay() {
        let current = UserDefaults.standard.bool(forKey: "recordKeystroke")
        if current {
            UserDefaults.standard.set(false, forKey: "recordKeystroke")
            rebuildToolbarLayout()
            return
        }
        // Requires Input Monitoring permission for CGEvent tap
        if KeystrokeOverlay.hasInputMonitoringPermission {
            UserDefaults.standard.set(true, forKey: "recordKeystroke")
            rebuildToolbarLayout()
        } else {
            overlayDelegate?.overlayViewDidRequestInputMonitoringPermission()
        }
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
            stopMicLevelMonitor()
            rebuildToolbarLayout()
            return
        }
        // Turning on — check mic permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            UserDefaults.standard.set(true, forKey: "recordMicAudio")
            rebuildToolbarLayout()
            startMicLevelMonitor()
        case .notDetermined:
            // Lower overlay so the system permission dialog is clickable
            let savedLevel = window?.level
            window?.level = .normal
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if let saved = savedLevel { self?.window?.level = saved }
                    if granted {
                        UserDefaults.standard.set(true, forKey: "recordMicAudio")
                        self?.startMicLevelMonitor()
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
        alert.messageText = L("Microphone Access Required")
        alert.informativeText =
            L("macshot needs microphone permission to record voice audio. Open System Settings to grant access.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Open Settings"))
        alert.addButton(withTitle: L("Cancel"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Mic Level Monitor

    func startMicLevelMonitor() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        stopMicLevelMonitor()

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else { return }

        var peakLevel: Float = 0
        let lock = NSLock()

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            var peak: Float = 0
            for i in 0..<frames {
                let val = abs(channelData[0][i])
                if val > peak { peak = val }
            }
            lock.lock()
            peakLevel = peak
            lock.unlock()
        }

        do {
            try engine.start()
        } catch {
            return
        }
        micLevelEngine = engine

        // Poll level at ~20fps and drive the mic button's built-in level meter
        var displayLevel: Float = 0
        micLevelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            lock.lock()
            let level = peakLevel
            peakLevel = 0
            lock.unlock()
            // Smooth: fast attack, slow release
            displayLevel = level > displayLevel ? level : displayLevel * 0.8 + level * 0.2
            self?.setMicButtonLevel(displayLevel)
        }
    }

    func stopMicLevelMonitor() {
        micLevelTimer?.invalidate()
        micLevelTimer = nil
        micLevelEngine?.inputNode.removeTap(onBus: 0)
        micLevelEngine?.stop()
        micLevelEngine = nil
        setMicButtonLevel(0)
    }

    private func setMicButtonLevel(_ level: Float) {
        // Find mic button in both toolbar strips
        let strips: [ToolbarStripView?] = [bottomStripView, rightStripView]
        for strip in strips {
            if let btn = strip?.buttonViews.first(where: {
                if case .micAudio = $0.action { return true }; return false
            }) {
                btn.micLevel = level
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
        // In recording mode, only allow Escape (to exit recording mode)
        if isRecording {
            if event.keyCode == 53 { // Escape
                handleToolbarAction(.stopRecord)
            }
            return
        }

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
            if textEditView != nil {
                cancelTextEditing()
            } else if PopoverHelper.isVisible {
                PopoverHelper.dismiss()
            } else if !selectedAnnotations.isEmpty {
                selectedAnnotations = []
                needsDisplay = true
            } else {
                overlayDelegate?.overlayViewDidCancel()
            }
        case 48:  // Tab
            if state == .idle {
                // Toggle window snapping in idle state
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
        case 36:  // Return/Enter — quick capture (respects quickCaptureMode setting)
            if textEditView == nil, state == .selected {
                overlayDelegate?.overlayViewDidRequestQuickSave()
            }
        case 51:  // Backspace/Delete — remove selected annotation(s)
            guard textEditView == nil, state == .selected, !selectedAnnotations.isEmpty else { break }
            for ann in selectedAnnotations {
                if let idx = annotations.firstIndex(where: { $0 === ann }) {
                    annotations.remove(at: idx)
                    undoStack.append(.deleted(ann, idx))
                }
            }
            redoStack.removeAll()
            selectedAnnotations = []
            cachedCompositedImage = nil
            needsDisplay = true
        default:
            // Auto-measure: hold "1" = vertical preview, hold "2" = horizontal preview
            if state == .selected && currentTool == .measure && textEditView == nil
                && !event.modifierFlags.contains(.command)
            {
                if let char = event.charactersIgnoringModifiers {
                    if char == "1" || char == "2" {
                        autoMeasureVertical = (char == "1")
                        if !autoMeasureKeyHeld {
                            autoMeasureKeyHeld = true
                            updateAutoMeasurePreview()
                        }
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
                    case "b", "x":
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
                    if isInsideScrollView, let sv = enclosingScrollView {
                        sv.magnification = 1.0
                        findTopBar()?.updateZoom(1.0)
                    } else if state == .selected && zoomLevel != 1.0 {
                        resetZoom()
                        showZoomLabel()
                        needsDisplay = true
                    }
                    return
                }
                if isInsideScrollView {
                    if event.charactersIgnoringModifiers == "=" || event.charactersIgnoringModifiers == "+" {
                        if let sv = enclosingScrollView, let doc = sv.documentView {
                            let newMag = min(sv.maxMagnification, sv.magnification * 1.25)
                            sv.setMagnification(newMag, centeredAt: NSPoint(x: doc.bounds.midX, y: doc.bounds.midY))
                            findTopBar()?.updateZoom(newMag)
                        }
                        return
                    }
                    if event.charactersIgnoringModifiers == "-" {
                        if let sv = enclosingScrollView, let doc = sv.documentView {
                            let newMag = max(sv.minMagnification, sv.magnification / 1.25)
                            sv.setMagnification(newMag, centeredAt: NSPoint(x: doc.bounds.midX, y: doc.bounds.midY))
                            findTopBar()?.updateZoom(newMag)
                        }
                        return
                    }
                    if event.charactersIgnoringModifiers == "1" {
                        if let sv = enclosingScrollView, let doc = sv.documentView {
                            let unscaledW = doc.frame.width / sv.magnification
                            let unscaledH = doc.frame.height / sv.magnification
                            guard unscaledW > 0, unscaledH > 0 else { return }
                            let clipSize = sv.contentView.bounds.size
                            let fitMag = min(clipSize.width / unscaledW, clipSize.height / unscaledH)
                            let clamped = max(sv.minMagnification, min(sv.maxMagnification, fitMag))
                            sv.magnification = clamped
                            findTopBar()?.updateZoom(clamped)
                        }
                        return
                    }
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
        // Clear auto-measure preview on key release (click to commit instead)
        if let char = event.charactersIgnoringModifiers, char == "1" || char == "2" {
            if autoMeasureKeyHeld {
                autoMeasureKeyHeld = false
                autoMeasurePreview = nil
                autoMeasureBitmapCtx = nil  // free cached bitmap
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
                if ann.tool == .translateOverlay { translateEnabled = false; rebuildToolbarLayout() }
                redoStack.append(contentsOf: batch)
                clearHoverIfNeeded(batch.map { $0.annotation })
            } else {
                annotations.removeAll { $0 === ann }
                if ann.tool == .number { numberCounter = max(0, numberCounter - 1) }
                if ann.tool == .translateOverlay { translateEnabled = false; rebuildToolbarLayout() }
                redoStack.append(.added(ann))
                clearHoverIfNeeded([ann])
            }
        case .deleted(let ann, let idx):
            // Undo a deletion — re-insert at original position
            let safeIdx = min(idx, annotations.count)
            annotations.insert(ann, at: safeIdx)
            if ann.tool == .number { numberCounter += 1 }
            redoStack.append(.deleted(ann, idx))
        case .propertyChange(let ann, let snapshot):
            // Undo property change — swap current state with snapshot
            let currentSnapshot = ann.clone()
            ann.copyProperties(from: snapshot)
            redoStack.append(.propertyChange(annotation: ann, snapshot: currentSnapshot))
            cachedCompositedImage = nil
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
        let beforeCount = selectedAnnotations.count
        selectedAnnotations.removeAll { ann in removed.contains(where: { $0 === ann }) }
        if selectedAnnotations.count != beforeCount {
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
        case .propertyChange(let ann, let snapshot):
            // Redo property change — swap again
            let currentSnapshot = ann.clone()
            ann.copyProperties(from: snapshot)
            undoStack.append(.propertyChange(annotation: ann, snapshot: currentSnapshot))
            cachedCompositedImage = nil
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
            // Censor annotations render first so other annotations appear on top
            for annotation in annotationsCopy where annotation.tool == .pixelate {
                annotation.draw(in: context)
            }
            for annotation in annotationsCopy where annotation.tool != .pixelate {
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
        return renderSelectedRegion(includeAnnotations: true)
    }

    /// Capture the selected region WITHOUT annotations — just the raw screenshot.
    /// Used for editable history: the raw image is stored alongside annotation data.
    func captureSelectedRegionRaw() -> NSImage? {
        return renderSelectedRegion(includeAnnotations: false)
    }

    private func renderSelectedRegion(includeAnnotations: Bool) -> NSImage? {
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
        // Use the source image's color space to avoid expensive color conversion on render.
        // Fall back to sRGB if unavailable.
        let cs: CGColorSpace
        if let screenshot = screenshotImage,
           let cg = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let srcCS = cg.colorSpace {
            cs = srcCS
        } else {
            cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
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

        if includeAnnotations {
            for annotation in annotations {
                annotation.draw(in: nsContext)
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = cgCtx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: selectionRect.size)
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
            beautifyStyleIndex: beautifyStyleIndex,
            effectsPreset: effectsPreset,
            effectsBrightness: effectsBrightness,
            effectsContrast: effectsContrast,
            effectsSaturation: effectsSaturation,
            effectsSharpness: effectsSharpness
        )
    }

    /// Restore editor state.
    /// Translates annotation coordinates by `offset` (the selection origin in the original view).
    func setAnnotations(_ anns: [Annotation]) {
        // Set sourceImage on loupe annotations so they can re-bake from the editor's image.
        // Also set it on pixelate/blur without a baked result (shouldn't happen, but defensive).
        if let img = screenshotImage {
            let bounds = captureDrawRect
            for ann in anns {
                if ann.tool == .loupe || ((ann.tool == .pixelate || ann.tool == .blur) && ann.bakedBlurNSImage == nil) {
                    ann.sourceImage = img
                    ann.sourceImageBounds = bounds
                    if ann.tool == .loupe { ann.bakeLoupe() }
                    if ann.tool == .pixelate { ann.bakePixelate() }
                }
            }
        }
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
        remoteSelectionFullRect = .zero
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
        case .annotationOutline:
            if let data = UserDefaults.standard.data(forKey: "annotationOutlineColor"),
               let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
                initialColor = c
            } else {
                initialColor = .white
            }
        }
        picker.setColor(initialColor, opacity: currentColorOpacity)
        picker.customColors = customColors
        picker.selectedColorSlot = selectedColorSlot

        picker.onColorChanged = { [weak self] color in
            guard let self = self else { return }
            self.applyPickedColor(color)
            picker.saveToSelectedSlot(color)
            // Update toolbar color swatches without rebuilding (which destroys the popover anchor)
            self.toolOptionsRowView?.updateSwatchColors()
            self.needsDisplay = true
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
            PopoverHelper.show(picker, size: size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
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
        case .annotationOutline:
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "annotationOutlineColor")
            }
            // Apply to selected annotations
            for ann in selectedAnnotations {
                ann.outlineColor = color
            }
            cachedCompositedImage = nil
        }
        needsDisplay = true
    }

    func reset() {
        state = .idle
        selectionRect = .zero
        selectionIsWindowSnap = false
        snappedWindowID = nil
        snappedWindowImage = nil
        remoteSelectionRect = .zero
        remoteSelectionFullRect = .zero
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
        editorTooltipView?.removeFromSuperview()
        editorTooltipView = nil
        isTranslating = false
        translateEnabled = false
        autoMeasurePreview = nil
        autoMeasureKeyHeld = false
        autoMeasureBitmapCtx = nil
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

// MARK: - Image Effects helpers

extension OverlayView {
    /// Returns the effects-processed screenshot, cached for performance during draw().
    func effectsProcessedScreenshot(_ screenshot: NSImage) -> NSImage {
        if let cached = cachedEffectsScreenshot { return cached }
        let config = effectsConfig
        guard !config.isIdentity else { return screenshot }
        let processed = ImageEffects.apply(to: screenshot, config: config)
        cachedEffectsScreenshot = processed
        return processed
    }
}

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

/// Small rounded-rect tooltip view used for editor mode toolbar hover labels.
private class TooltipBackgroundView: NSView {
    var text: String = ""

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let pad: CGFloat = 6
        (text as NSString).draw(at: NSPoint(x: pad, y: pad / 2), withAttributes: attrs)
    }
}

