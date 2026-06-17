import Cocoa
import CoreImage
import UniformTypeIdentifiers
import Vision

/// Editable annotation data bundled with a confirmed capture.
struct CaptureAnnotationData {
    let rawImage: NSImage       // screenshot without annotations
    let annotations: [Annotation]
}

private final class ScreenshotOverlayRootView: NSView {
    private let previewLayer = CALayer()
    let overlayView: OverlayView

    init(frame: NSRect, overlayView: OverlayView) {
        self.overlayView = overlayView
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        previewLayer.contentsGravity = .resize
        previewLayer.masksToBounds = true
        layer?.addSublayer(previewLayer)
        overlayView.frame = bounds
        overlayView.autoresizingMask = [.width, .height]
        addSubview(overlayView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    func setScreenshotPreviewImage(_ cgImage: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        previewLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        previewLayer.contents = cgImage
        CATransaction.commit()
        overlayView.usesExternalScreenshotPreview = true
    }

    func clearScreenshotPreview() {
        previewLayer.contents = nil
        overlayView.usesExternalScreenshotPreview = false
    }
}

@MainActor
protocol OverlayWindowControllerDelegate: AnyObject {
    func overlayDidCancel(_ controller: OverlayWindowController)
    func overlayDidConfirm(_ controller: OverlayWindowController, capturedImage: NSImage?, annotationData: CaptureAnnotationData?)
    func overlayDidRequestPin(_ controller: OverlayWindowController, image: NSImage)
    func overlayDidRequestOCR(_ controller: OverlayWindowController, result: OCRScanResult, image: NSImage?)
    func overlayDidRequestUpload(_ controller: OverlayWindowController, image: NSImage)
    func overlayDidRequestStartRecording(
        _ controller: OverlayWindowController, rect: NSRect, screen: NSScreen)
    func overlayDidRequestStopRecording(_ controller: OverlayWindowController)
    func overlayDidRequestScrollCapture(
        _ controller: OverlayWindowController, rect: NSRect, screen: NSScreen)
    func overlayDidRequestStopScrollCapture(_ controller: OverlayWindowController)
    func overlayDidRequestToggleAutoScroll(_ controller: OverlayWindowController)
    func overlayDidRequestAccessibilityPermission(_ controller: OverlayWindowController)
    func overlayDidRequestInputMonitoringPermission(_ controller: OverlayWindowController)
    func overlayDidBeginSelection(_ controller: OverlayWindowController)
    func overlayDidChangeSelection(_ controller: OverlayWindowController, globalRect: NSRect)
    func overlayDidRemoteResizeSelection(_ controller: OverlayWindowController, globalRect: NSRect)
    func overlayDidFinishRemoteResize(_ controller: OverlayWindowController, globalRect: NSRect)
    func overlayCrossScreenImage(_ controller: OverlayWindowController) -> NSImage?
    func overlayDidChangeWindowSnapState(_ controller: OverlayWindowController)
}

/// Manages one fullscreen overlay per screen.
/// Does NOT subclass NSWindowController to avoid AppKit retain-cycle issues.
@MainActor
class OverlayWindowController {

    weak var overlayDelegate: OverlayWindowControllerDelegate?
    var capturedWindowTitle: String?
    var timingMark: ((String) -> Void)? {
        didSet {
            overlayView?.timingMark = timingMark
        }
    }

    private var overlayView: OverlayView?
    private var rootView: ScreenshotOverlayRootView?
    private var overlayWindow: OverlayWindow?
    private var shareDelegate: SharePickerDelegate?
    private var shareDismissTime: Date = .distantPast
    var windowNumber: CGWindowID {
        overlayWindow.map { CGWindowID($0.windowNumber) } ?? CGWindowID.max
    }
    private(set) var screen: NSScreen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    var screenshotImage: NSImage? { overlayView?.screenshotImage }
    var selectionRect: NSRect { overlayView?.selectionRect ?? .zero }
    var remoteSelectionRect: NSRect { overlayView?.remoteSelectionRect ?? .zero }

    // Session recording overrides (from toolbar popover, nil = use UserDefaults default)
    var sessionRecordingFPS: Int? { overlayView?.sessionRecordingFPS }
    var sessionRecordingOnStop: String? { overlayView?.sessionRecordingOnStop }
    var sessionRecordingDelay: Int? { overlayView?.sessionRecordingDelay }
    var sessionHideRecordingHUD: Bool? { overlayView?.sessionHideRecordingHUD }
    /// Create an overlay pre-populated with a screenshot. Visible immediately on showOverlay().
    init(capture: ScreenCapture) {
        let screen = capture.screen
        self.screen = screen
        setupWindow(screen: screen)
        installScreenshot(capture.image)
    }

    /// Create an empty overlay. Stays transparent (showing the live desktop) until
    /// setScreenshot() is called with the captured image.
    init(screen: NSScreen) {
        self.screen = screen
        setupWindow(screen: screen)
    }

    private func setupWindow(screen: NSScreen) {
        // .nonactivatingPanel lets the overlay become key without activating the
        // macshot app — no NSApp.activate, no focus dance with the previous app.
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(257)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Idle/warmed panels are click-through by invariant. Mouse events are
        // enabled only when a real capture is presented (showOverlay/makeKey).
        // This guarantees that a stranded warm panel — e.g. if warmPanel()'s
        // deferred orderOut is delayed across a sleep/wake or display
        // reconfigure — can never swallow clicks (see issue #231).
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        // No automatic appearance animation when the overlay is ordered front.
        // With the default behavior, AppKit auto-animates window appearance —
        // and under the system "Reduce Motion" setting that becomes a brief
        // scale/zoom-in, visible at the screenshot edges (issue #205). The
        // overlay must appear instantly so its screenshot lines up 1:1 with
        // the real screen.
        window.animationBehavior = .none

        let view = OverlayView()
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        view.overlayDelegate = self
        view.timingMark = timingMark

        let rootView = ScreenshotOverlayRootView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            overlayView: view)
        view.externalScreenshotPreviewUpdater = { [weak rootView] cgImage in
            if let cgImage {
                rootView?.setScreenshotPreviewImage(cgImage)
            } else {
                rootView?.clearScreenshotPreview()
            }
        }

        window.contentView = rootView
        self.overlayWindow = window
        self.rootView = rootView
        self.overlayView = view
    }

    /// Install the screenshot into the overlay's backing layer. Once set, the
    /// window becomes opaque (dark dim) and the overlay can render annotations.
    private func installScreenshot(_ image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: screen.frame.size)
        overlayView?.captureSourceImage = nsImage
        overlayView?.screenshotImage = nsImage
        rootView?.setScreenshotPreviewImage(image)
        overlayWindow?.isOpaque = true
        overlayWindow?.backgroundColor = .black
    }

    /// Show the overlay. Becomes key + first responder immediately. If a
    /// screenshot was pre-installed, it's visible on the first frame; otherwise
    /// the overlay is transparent (live desktop visible through it) and waits
    /// for setScreenshot() to install one.
    func showOverlay() {
        guard let window = overlayWindow else { return }
        timingMark?("showOverlay begin appActive=\(NSApp.isActive)")
        // A real capture is being presented — enable mouse interaction.
        // (Idle/warmed panels are click-through; see setupWindow.)
        window.ignoresMouseEvents = false
        rootView?.layoutSubtreeIfNeeded()
        timingMark?("after layoutSubtreeIfNeeded")
        overlayView?.displayIfNeeded()
        timingMark?("after displayIfNeeded")
        window.makeKeyAndOrderFront(nil)
        timingMark?("after makeKeyAndOrderFront isVisible=\(window.isVisible) isKey=\(window.isKeyWindow)")
        if let view = overlayView {
            window.makeFirstResponder(view)
        }
        timingMark?("after makeFirstResponder")
        // Window is now key — resetCursorRects (called by AppKit on key change)
        // installs the crosshair rect. No need to NSCursor.set() imperatively.
    }

    /// Install the captured screenshot after showOverlay() has already made the
    /// window key. The overlay was previously transparent; this is the moment
    /// it becomes screenshot-backed with the dim mask.
    func setScreenshot(_ image: CGImage) {
        installScreenshot(image)
        if let view = overlayView {
            overlayWindow?.invalidateCursorRects(for: view)
        }
    }

    func makeKey() {
        overlayWindow?.ignoresMouseEvents = false
        overlayWindow?.makeKeyAndOrderFront(nil)
        if let view = overlayView {
            overlayWindow?.makeFirstResponder(view)
        }
    }

    /// One-shot warmup: briefly order the (currently empty) panel front so
    /// WindowServer allocates its surface and composes one frame. We
    /// immediately order it out — but the CGSWindow stays alive and so does
    /// WindowServer's per-window composition cache. Next real `showOverlay()`
    /// hits the warm path. Pair with the overlay controller pool that keeps
    /// the panel alive across capture sessions.
    func warmPanel() {
        guard let panel = overlayWindow else { return }
        // Use a barely-visible alpha so WindowServer doesn't optimize the
        // window away as a transparent no-op. Restore after we order out.
        let savedAlpha = panel.alphaValue
        // Keep the warm panel click-through. Even if the deferred orderOut
        // below is stranded (e.g. across a sleep/wake or display reconfigure),
        // an invisible click-through window can't lock out input (issue #231).
        panel.ignoresMouseEvents = true
        panel.alphaValue = 0.001
        panel.orderFrontRegardless()
        rootView?.layoutSubtreeIfNeeded()
        overlayView?.displayIfNeeded()
        CATransaction.flush()
        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            panel.orderOut(nil)
            panel.alphaValue = savedAlpha
            panel.ignoresMouseEvents = true
        }
    }

    func applySelection(_ rect: NSRect) {
        overlayView?.applySelection(rect)
    }

    func clearSelection() {
        overlayView?.clearSelection()
    }

    func triggerRedraw() {
        overlayView?.needsDisplay = true
    }

    func setRemoteSelection(_ rect: NSRect, fullRect: NSRect = .zero) {
        overlayView?.remoteSelectionRect = rect
        overlayView?.remoteSelectionFullRect = fullRect.width >= 1 ? fullRect : rect
        if rect.width >= 1 && rect.height >= 1 {
            overlayView?.hoveredWindowRect = nil
        }
        overlayView?.needsDisplay = true
    }

    /// Auto-select the full screen (as if user clicked without dragging).
    func applyFullScreenSelection() {
        overlayView?.applyFullScreenSelection()
    }

    /// Set flag so overlay enters recording mode after user makes a selection.
    func setAutoRecordMode() {
        overlayView?.autoEnterRecordingMode = true
    }

    /// Set flag so overlay triggers OCR immediately after user makes a selection.
    func setAutoOCRMode() {
        overlayView?.autoOCRMode = true
    }

    /// Set flag so overlay quick-saves immediately after user makes a selection.
    func setAutoQuickSaveMode() {
        overlayView?.autoQuickSaveMode = true
    }

    /// Set flag so overlay triggers scroll capture immediately after user makes a selection.
    func setAutoScrollCaptureMode() {
        overlayView?.autoScrollCaptureMode = true
    }

    /// Set flag so overlay auto-confirms immediately after selection (no toolbars, no save).
    func setAutoConfirmMode() {
        overlayView?.autoConfirmMode = true
    }

    /// Enter recording mode — shows recording toolbar buttons in the normal toolbar.
    func enterRecordingMode() {
        overlayView?.isRecording = true
        overlayView?.rebuildToolbarLayout()
        overlayView?.needsDisplay = true
    }

    /// Auto-start recording immediately (used when timer + fullscreen record).
    func autoStartRecording() {
        overlayView?.overlayDelegate?.overlayViewDidRequestStartRecording(
            rect: overlayView?.selectionRect ?? .zero)
    }

    func setScrollCaptureState(isActive: Bool, stripCount: Int = 0, pixelSize: CGSize = .zero,
                               maxHeight: Int = 0) {
        overlayView?.scrollCaptureMaxHeight = maxHeight
        if isActive {
            // Make the overlay window fully transparent + pass-through so the
            // user sees AND interacts with the live app underneath. We must:
            //   1) Clear the rootView's previewLayer (which holds the frozen
            //      screenshot independent of OverlayView's drawing).
            //   2) Mark the window non-opaque + clear background so AppKit
            //      doesn't paint a solid backing behind the layer.
            //   3) ignoresMouseEvents = true so scroll/click events fall
            //      through to the app beneath (the HUD has its own panel).
            rootView?.clearScreenshotPreview()
            overlayWindow?.isOpaque = false
            overlayWindow?.backgroundColor = .clear
            overlayView?.startScrollCaptureMode()
        } else {
            overlayView?.stopScrollCaptureMode()
            // Restore the screenshot-backed opaque overlay so the next
            // action (selection adjustment, confirm, etc.) sees the screenshot.
            if let img = overlayView?.captureSourceImage,
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                rootView?.setScreenshotPreviewImage(cg)
                overlayWindow?.isOpaque = true
                overlayWindow?.backgroundColor = .black
            }
        }
        overlayView?.scrollCaptureStripCount = stripCount
        overlayView?.scrollCapturePixelSize = pixelSize
        overlayView?.needsDisplay = true
    }

    func updateScrollCaptureProgress(stripCount: Int, pixelSize: CGSize,
                                     autoScrolling: Bool = false) {
        overlayView?.scrollCaptureStripCount = stripCount
        overlayView?.scrollCapturePixelSize = pixelSize
        overlayView?.scrollCaptureAutoScrolling = autoScrolling
        overlayView?.updateScrollCaptureHUD()
        overlayView?.needsDisplay = true
    }

    /// End the current capture session. The window/view/panel are KEPT ALIVE
    /// and returned to a clean idle state, so the next session can reuse this
    /// same controller (and crucially, the same NSPanel CGSWindow — which is
    /// what makes the next capture instant, since WindowServer's per-window
    /// composition cache survives `orderOut`).
    func dismiss() {
        saveSelectionIfNeeded()
        overlayView?.reset()
        overlayView?.screenshotImage = nil
        overlayView?.captureSourceImage = nil
        rootView?.clearScreenshotPreview()
        // Restore the window's transparent state so the next session starts
        // with the same defaults as a fresh install.
        overlayWindow?.isOpaque = false
        overlayWindow?.backgroundColor = .clear
        // Return to the idle click-through invariant before ordering out.
        overlayWindow?.ignoresMouseEvents = true
        overlayWindow?.orderOut(nil)
        NSCursor.arrow.set()
        // Note: overlayDelegate is intentionally NOT cleared here; the
        // controller-pool owner re-assigns it before each session.
        // overlayWindow/rootView/overlayView remain alive for the next session.
    }

    /// Fully tear down the controller. Used when the screen config changes
    /// (display added/removed), or app shutdown. After this the controller is
    /// dead and a new one must be constructed.
    func tearDown() {
        overlayView?.reset()
        overlayView?.overlayDelegate = nil
        overlayWindow?.contentView = nil
        rootView = nil
        overlayView = nil
        overlayWindow?.ignoresMouseEvents = true
        overlayWindow?.orderOut(nil)
        overlayWindow?.close()
        overlayWindow = nil
    }

    private func saveSelectionIfNeeded() {
        guard let view = overlayView, view.state == .selected,
            view.selectionRect.width > 1, view.selectionRect.height > 1
        else { return }
        UserDefaults.standard.set(NSStringFromRect(view.selectionRect), forKey: "lastSelectionRect")
        UserDefaults.standard.set(
            NSStringFromRect(screen.frame), forKey: "lastSelectionScreenFrame")
    }

    private func playCopySound() {
        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        guard soundEnabled else { return }
        AppDelegate.captureSound?.stop()
        AppDelegate.captureSound?.play()
    }

    private func captureRegion() -> NSImage? {
        return overlayDelegate?.overlayCrossScreenImage(self)
            ?? overlayView?.captureSelectedRegion()
    }

    /// Snapshot annotations for editable history, using a pre-captured raw image.
    /// Returns nil if there are no movable annotations.
    private func snapshotAnnotationData(rawImage: NSImage) -> CaptureAnnotationData? {
        guard let view = overlayView else { return nil }
        let annotations = view.annotations.filter { $0.isMovable }
        guard !annotations.isEmpty else { return nil }

        let sel = view.selectionRect
        let shifted = annotations.map { ann -> Annotation in
            let c = ann.clone()
            c.move(dx: -sel.origin.x, dy: -sel.origin.y)
            return c
        }
        return CaptureAnnotationData(rawImage: rawImage, annotations: shifted)
    }

    /// Composite annotations onto the snapped window image (preserving transparency).
    private func compositeAnnotationsOnSnappedWindow(_ windowImage: NSImage, annotations: [Annotation], selectionRect: NSRect) -> NSImage {
        guard !annotations.isEmpty else { return windowImage }
        let sel = selectionRect
        let size = windowImage.size
        let result = NSImage(size: size, flipped: false) { _ in
            windowImage.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1.0)
            guard let ctx = NSGraphicsContext.current else { return true }
            // Translate so annotation coords (relative to selectionRect) map to image coords
            ctx.cgContext.translateBy(x: -sel.origin.x, y: -sel.origin.y)
            for annotation in annotations {
                annotation.draw(in: ctx)
            }
            return true
        }
        return result
    }

    private func applyBeautifyIfNeeded(_ image: NSImage?) -> NSImage? {
        guard let image = image, let view = overlayView else { return image }
        var result = image
        // Apply image effects first (non-destructive CIFilter adjustments)
        if view.effectsActive {
            result = ImageEffects.apply(to: result, config: view.effectsConfig)
        }
        // Apply beautify second (gradient background wrapping)
        if view.beautifyEnabled {
            result = BeautifyRenderer.render(image: result, config: view.beautifyConfig)
        }
        return result
    }

    private func copyImageToClipboard(_ image: NSImage) {
        ImageEncoder.copyToClipboard(image)
    }

}

// MARK: - OverlayViewDelegate

extension OverlayWindowController: OverlayViewDelegate {
    func overlayViewDidFinishSelection(_ rect: NSRect) {
        // No-op: window is already key (.nonactivatingPanel + makeKeyAndOrderFront).
    }

    func overlayViewSelectionDidChange(_ rect: NSRect) {
        let screenOrigin = screen.frame.origin
        let globalRect = NSRect(
            x: rect.origin.x + screenOrigin.x,
            y: rect.origin.y + screenOrigin.y,
            width: rect.width, height: rect.height)
        overlayDelegate?.overlayDidChangeSelection(self, globalRect: globalRect)
    }

    func overlayViewDidCancel() {
        dismiss()
        overlayDelegate?.overlayDidCancel(self)
    }

    func overlayViewDidConfirm() {
        // Snapshot post-processing config before dismissing (view will be torn down)
        let hasEffects = overlayView?.effectsActive ?? false
        let effectsCfg = overlayView?.effectsConfig ?? ImageEffectsConfig()
        let hasBeautify = overlayView?.beautifyEnabled ?? false
        let beautifyCfg = overlayView?.beautifyConfig ?? BeautifyConfig()
        let snapWindowImg = overlayView?.snappedWindowImage

        // Capture the composited image (screenshot + annotations baked in).
        // This is a single render — no double capture.
        guard let compositedImage = captureRegion() else {
            dismiss()
            overlayDelegate?.overlayDidCancel(self)
            return
        }

        // Snapshot annotations + selection rect before dismiss (view will be torn down)
        let snapshotAnnotations = overlayView?.annotations ?? []
        let snapshotSelRect = overlayView?.selectionRect ?? .zero

        // Snapshot annotation data using the raw screenshot (without annotations).
        // For window snaps, use the independently captured window image (transparent corners)
        // so the editor shows clean corners when re-editing.
        let hasAnnotations = overlayView?.annotations.contains(where: { $0.isMovable }) ?? false
        let annotationData: CaptureAnnotationData?
        if hasAnnotations {
            let rawImage: NSImage? = (beautifyCfg.isWindowSnap && snapWindowImg != nil)
                ? snapWindowImg : overlayView?.captureSelectedRegionRaw()
            if let raw = rawImage {
                annotationData = snapshotAnnotationData(rawImage: raw)
            } else {
                annotationData = nil
            }
        } else {
            annotationData = nil
        }

        // Dismiss immediately — user is free to continue working
        playCopySound()
        dismiss()

        // Apply post-processing if needed
        var finalImage = compositedImage
        if hasEffects {
            finalImage = ImageEffects.apply(to: finalImage, config: effectsCfg)
        }
        if hasBeautify {
            // For snapped windows, use the independently captured window image (transparent corners)
            // with annotations composited on top (using pre-dismiss snapshot)
            let beautifyInput = (beautifyCfg.isWindowSnap && snapWindowImg != nil)
                ? compositeAnnotationsOnSnappedWindow(snapWindowImg!, annotations: snapshotAnnotations, selectionRect: snapshotSelRect)
                : finalImage
            finalImage = BeautifyRenderer.render(image: beautifyInput, config: beautifyCfg)
        }

        // Copy button / Cmd+C always copies to clipboard
        ImageEncoder.copyToClipboard(finalImage)

        // Don't save annotation data if effects/beautify were applied — the raw image
        // wouldn't match what the user sees, making annotation re-editing confusing.
        overlayDelegate?.overlayDidConfirm(self, capturedImage: finalImage, annotationData: annotationData)
    }

    func overlayViewDidRequestPin() {
        guard var image = captureRegion() else { return }
        image = applyBeautifyIfNeeded(image) ?? image
        playCopySound()
        dismiss()
        overlayDelegate?.overlayDidRequestPin(self, image: image)
    }

    func overlayViewDidRequestOCR() {
        guard let image = captureRegion() else { return }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            VisionOCR.performTextAndQRCodeRecognition(cgImage: cgImage) { [weak self] result in
                guard let self = self else { return }
                let capturedImage = image  // capture before dismiss
                DispatchQueue.main.async {
                    self.playCopySound()
                    self.dismiss()
                    self.overlayDelegate?.overlayDidRequestOCR(self, result: result, image: capturedImage)
                }
            }
        }
    }

    func overlayViewDidRequestUpload() {
        guard var image = captureRegion() else { return }
        image = applyBeautifyIfNeeded(image) ?? image
        playCopySound()
        dismiss()
        overlayDelegate?.overlayDidRequestUpload(self, image: image)
    }

    func overlayViewDidRequestShare(anchorView: NSView?) {
        // Prevent re-entry: if a share session is active or was just dismissed, ignore
        if shareDelegate != nil { return }
        if Date().timeIntervalSince(shareDismissTime) < 0.5 {
            return
        }

        guard var image = captureRegion() else { return }
        image = applyBeautifyIfNeeded(image) ?? image
        guard let imageData = ImageEncoder.encode(image) else { return }
        let tempURL = TmpScratchDirectory.makeURL(
            filename: FilenameFormatter.defaultImageFilename(windowTitle: capturedWindowTitle))
        try? imageData.write(to: tempURL)

        // Get the screen position of the share button
        let screenRect: NSRect
        if let anchor = anchorView, let win = anchor.window {
            let viewRect = anchor.convert(anchor.bounds, to: nil)
            screenRect = win.convertToScreen(viewRect)
        } else {
            let mid = NSScreen.main?.frame ?? NSRect(x: 400, y: 400, width: 100, height: 100)
            screenRect = NSRect(x: mid.midX - 20, y: mid.midY - 20, width: 40, height: 40)
        }

        // Temporarily lower the overlay so the system share picker popover appears on top.
        // NSSharingServicePicker creates its own window at a standard level that we can't control.
        let savedLevel = overlayWindow?.level ?? NSWindow.Level(257)
        overlayWindow?.level = .floating

        let picker = NSSharingServicePicker(items: [tempURL])
        let delegate = SharePickerDelegate(
            onPick: { [weak self] in
                guard let self = self else { return }
                self.overlayWindow?.level = savedLevel
                self.shareDelegate = nil
                self.playCopySound()
                let img = image
                self.dismiss()
                self.overlayDelegate?.overlayDidConfirm(self, capturedImage: img, annotationData: nil)
            },
            onDismiss: { [weak self] in
                self?.overlayWindow?.level = savedLevel
                self?.shareDelegate = nil
                self?.shareDismissTime = Date()
            }
        )
        shareDelegate = delegate
        picker.delegate = delegate

        // Show anchored to the button in the overlay view
        if let anchor = anchorView {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if let view = overlayView {
            let center = NSRect(x: view.bounds.midX - 1, y: view.bounds.midY - 1, width: 2, height: 2)
            picker.show(relativeTo: center, of: view, preferredEdge: .minY)
        }
    }

    func overlayViewDidRequestEnterRecordingMode() {
        enterRecordingMode()
    }

    func overlayViewDidRequestStartRecording(rect: NSRect) {
        // Convert overlay-local rect to screen coordinates
        let screenRect = NSRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.minY + rect.minY,
            width: rect.width,
            height: rect.height
        )
        overlayDelegate?.overlayDidRequestStartRecording(self, rect: screenRect, screen: screen)
    }

    /// Detach the webcam setup preview so it can be reused during recording.
    func detachWebcamPreview() -> WebcamOverlay? {
        overlayView?.detachWebcamSetupPreview()
    }

    func overlayViewDidRequestStopRecording() {
        overlayDelegate?.overlayDidRequestStopRecording(self)
    }

    func overlayViewDidRequestScrollCapture(rect: NSRect) {
        let screenRect = NSRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.minY + rect.minY,
            width: rect.width,
            height: rect.height
        )
        overlayDelegate?.overlayDidRequestScrollCapture(self, rect: screenRect, screen: screen)
    }

    func overlayViewDidRequestStopScrollCapture() {
        overlayDelegate?.overlayDidRequestStopScrollCapture(self)
    }

    func overlayViewDidRequestToggleAutoScroll() {
        overlayDelegate?.overlayDidRequestToggleAutoScroll(self)
    }

    func overlayViewDidRequestAccessibilityPermission() {
        overlayDelegate?.overlayDidRequestAccessibilityPermission(self)
    }

    func overlayViewDidRequestInputMonitoringPermission() {
        overlayDelegate?.overlayDidRequestInputMonitoringPermission(self)
    }

    func overlayViewDidBeginSelection() {
        overlayDelegate?.overlayDidBeginSelection(self)
    }

    func overlayViewDidChangeWindowSnapState() {
        overlayDelegate?.overlayDidChangeWindowSnapState(self)
    }

    func overlayViewDidRequestAddCapture() {}  // editor-only

    func overlayViewRemoteSelectionDidChange(_ rect: NSRect) {
        // Convert local rect to global screen coords and forward to delegate
        let screenOrigin = screen.frame.origin
        let globalRect = NSRect(
            x: rect.origin.x + screenOrigin.x,
            y: rect.origin.y + screenOrigin.y,
            width: rect.width, height: rect.height)
        overlayDelegate?.overlayDidRemoteResizeSelection(self, globalRect: globalRect)
    }

    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect) {
        let screenOrigin = screen.frame.origin
        let globalRect = NSRect(
            x: rect.origin.x + screenOrigin.x,
            y: rect.origin.y + screenOrigin.y,
            width: rect.width, height: rect.height)
        overlayDelegate?.overlayDidFinishRemoteResize(self, globalRect: globalRect)
    }

    func overlayViewDidRequestDetach() {
        guard let view = overlayView else { return }
        let sel = view.selectionRect

        // Use stitched cross-screen image if available, otherwise crop from single screen.
        let croppedImage: NSImage? =
            overlayDelegate?.overlayCrossScreenImage(self)
            ?? {
                guard let src = view.screenshotImage else { return nil }
                // Render the crop into a concrete 8-bit bitmap now, so the editor
                // doesn't hit a 16-bit float conversion on first draw.
                let scale = view.window?.backingScaleFactor ?? 2.0
                let pxW = Int(sel.width * scale)
                let pxH = Int(sel.height * scale)
                // Preserve the source image's color space so the editor and saved
                // files render correct colors on every display.
                let srcCG = src.cgImage(forProposedRect: nil, context: nil, hints: nil)
                let cs = srcCG?.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
                let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                guard let ctx = CGContext(
                    data: nil, width: pxW, height: pxH,
                    bitsPerComponent: 8, bytesPerRow: pxW * 4,
                    space: cs, bitmapInfo: bitmapInfo
                ) else { return nil }
                let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = gctx
                src.draw(
                    in: NSRect(origin: .zero, size: NSSize(width: pxW, height: pxH)),
                    from: sel, operation: .copy, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()
                guard let cgImage = ctx.makeImage() else { return nil }
                return NSImage(cgImage: cgImage, size: sel.size)
            }()
        guard let image = croppedImage else { return }

        // Clone annotations and shift them from overlay coords to image-relative (0,0) origin.
        let state = view.snapshotEditorState()
        let shiftedAnnotations = state.annotations.map { ann -> Annotation in
            let c = ann.clone()
            c.move(dx: -sel.origin.x, dy: -sel.origin.y)
            return c
        }

        let tool = view.currentTool
        let color = view.currentColor
        let stroke = view.currentStrokeWidth

        dismiss()
        overlayDelegate?.overlayDidCancel(self)
        DetachedEditorWindowController.open(
            image: image, tool: tool, color: color, strokeWidth: stroke,
            annotations: shiftedAnnotations, fromCapture: true)
    }

    @available(macOS 14.0, *)
    func overlayViewDidRequestRemoveBackground() {
        guard var image = captureRegion() else { return }
        image = applyBeautifyIfNeeded(image) ?? image

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
                guard let result = request.results?.first else {
                    throw NSError(domain: "Macshot", code: 1)
                }

                let maskPixelBuffer = try result.generateScaledMaskForImage(
                    forInstances: result.allInstances, from: handler)

                let originalCIImage = CIImage(cgImage: cgImage)
                let maskCIImage = CIImage(cvPixelBuffer: maskPixelBuffer)

                // Blend original with mask
                guard let filter = CIFilter(name: "CIBlendWithMask") else {
                    throw NSError(domain: "Macshot", code: 2)
                }
                filter.setValue(originalCIImage, forKey: kCIInputImageKey)
                filter.setValue(maskCIImage, forKey: kCIInputMaskImageKey)
                filter.setValue(
                    CIImage(color: .clear).cropped(to: originalCIImage.extent),
                    forKey: kCIInputBackgroundImageKey)

                guard let outputCIImage = filter.outputImage else {
                    throw NSError(domain: "Macshot", code: 3)
                }

                let context = CIContext()
                guard
                    let finalCGImage = context.createCGImage(
                        outputCIImage, from: outputCIImage.extent)
                else { throw NSError(domain: "Macshot", code: 4) }

                let finalNSImage = NSImage(cgImage: finalCGImage, size: image.size)

                DispatchQueue.main.async {
                    // quickCaptureMode: 0=save, 1=copy, 2=both, 3=do nothing
                    let mode = UserDefaults.standard.object(forKey: "quickCaptureMode") as? Int ?? 1
                    if mode == 1 || mode == 2 {
                        self.copyImageToClipboard(finalNSImage)
                    }
                    self.playCopySound()
                    self.dismiss()
                    self.overlayDelegate?.overlayDidConfirm(self, capturedImage: finalNSImage, annotationData: nil)
                }
            } catch {
                #if DEBUG
                    print("Vision background removal error: \(error.localizedDescription)")
                #endif
                DispatchQueue.main.async {
                    self.overlayView?.showOverlayError(
                        "Background removal failed — no clear subject found.")
                }
            }
        }
    }

    func overlayViewDidRequestQuickSave() {
        // Snapshot post-processing config before dismissing
        let hasEffects = overlayView?.effectsActive ?? false
        let effectsCfg = overlayView?.effectsConfig ?? ImageEffectsConfig()
        let hasBeautify = overlayView?.beautifyEnabled ?? false
        let beautifyCfg = overlayView?.beautifyConfig ?? BeautifyConfig()
        let snapWindowImg = overlayView?.snappedWindowImage

        guard let compositedImage = captureRegion() else {
            dismiss()
            overlayDelegate?.overlayDidCancel(self)
            return
        }

        // Snapshot annotations + selection rect before dismiss
        let snapshotAnns = overlayView?.annotations ?? []
        let snapshotSel = overlayView?.selectionRect ?? .zero

        // Snapshot annotation data — use snapped window image for clean corners
        let hasAnnotations = overlayView?.annotations.contains(where: { $0.isMovable }) ?? false
        let annotationData: CaptureAnnotationData?
        if hasAnnotations {
            let rawImage: NSImage? = (beautifyCfg.isWindowSnap && snapWindowImg != nil)
                ? snapWindowImg : overlayView?.captureSelectedRegionRaw()
            if let raw = rawImage {
                annotationData = snapshotAnnotationData(rawImage: raw)
            } else {
                annotationData = nil
            }
        } else {
            annotationData = nil
        }

        dismiss()

        // Apply post-processing
        var image = compositedImage
        if hasEffects { image = ImageEffects.apply(to: image, config: effectsCfg) }
        if hasBeautify {
            let beautifyInput = (beautifyCfg.isWindowSnap && snapWindowImg != nil)
                ? compositeAnnotationsOnSnappedWindow(snapWindowImg!, annotations: snapshotAnns, selectionRect: snapshotSel)
                : image
            image = BeautifyRenderer.render(image: beautifyInput, config: beautifyCfg)
        }

        // quickCaptureMode: 0=save, 1=copy, 2=both, 3=do nothing (thumbnail only)
        let mode = UserDefaults.standard.object(forKey: "quickCaptureMode") as? Int ?? 1

        if mode == 1 || mode == 2 {
            ImageEncoder.copyToClipboard(image)
        }
        playCopySound()

        overlayDelegate?.overlayDidConfirm(self, capturedImage: image, annotationData: annotationData)

        if mode == 0 || mode == 2 {
            ImageSaveService.saveToConfiguredFolder(image, windowTitle: capturedWindowTitle)
        }
        // mode 3: do nothing — image is passed to delegate which shows the thumbnail
    }

    func overlayViewDidRequestFileSave() {
        guard let image = captureImageForSave() else {
            dismiss()
            overlayDelegate?.overlayDidCancel(self)
            return
        }

        dismiss()
        overlayDelegate?.overlayDidConfirm(self, capturedImage: image, annotationData: nil)
        ImageSaveService.saveToConfiguredFolder(
            image,
            windowTitle: capturedWindowTitle,
            panelLevel: NSWindow.Level(258)
        ) { [weak self] success in
            if success {
                self?.playCopySound()
            }
        }
    }

    func overlayViewDidRequestSave() {
        switch SaveActionPreference.current {
        case .saveToFolder:
            overlayViewDidRequestFileSave()
        case .askWhereToSave:
            overlayViewDidRequestSaveAs()
        }
    }

    func overlayViewDidRequestSaveAs() {
        guard let image = captureImageForSave() else { return }

        ImageSaveService.showSavePanel(
            for: image,
            windowTitle: capturedWindowTitle,
            panelLevel: NSWindow.Level(258)
        ) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.playCopySound()
                self.dismiss()
                self.overlayDelegate?.overlayDidConfirm(self, capturedImage: nil, annotationData: nil)
            } else {
                // Save cancelled — return to the active capture, mouse-interactive.
                self.overlayWindow?.ignoresMouseEvents = false
                self.overlayWindow?.makeKeyAndOrderFront(nil)
                if let view = self.overlayView {
                    self.overlayWindow?.makeFirstResponder(view)
                }
            }
        }
    }

    private func captureImageForSave() -> NSImage? {
        let hasEffects = overlayView?.effectsActive ?? false
        let effectsCfg = overlayView?.effectsConfig ?? ImageEffectsConfig()
        let hasBeautify = overlayView?.beautifyEnabled ?? false
        let beautifyCfg = overlayView?.beautifyConfig ?? BeautifyConfig()
        let snapWindowImg = overlayView?.snappedWindowImage
        let snapshotAnns = overlayView?.annotations ?? []
        let snapshotSel = overlayView?.selectionRect ?? .zero

        guard var image = captureRegion() else { return nil }
        if hasEffects {
            image = ImageEffects.apply(to: image, config: effectsCfg)
        }
        if hasBeautify {
            let beautifyInput = (beautifyCfg.isWindowSnap && snapWindowImg != nil)
                ? compositeAnnotationsOnSnappedWindow(snapWindowImg!, annotations: snapshotAnns, selectionRect: snapshotSel)
                : image
            image = BeautifyRenderer.render(image: beautifyInput, config: beautifyCfg)
        }
        return image
    }
}

// MARK: - Custom Window subclass

class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Retained delegate for NSSharingServicePicker — dismisses overlay only when user picks a service.
private class SharePickerDelegate: NSObject, NSSharingServicePickerDelegate {
    let onPick: () -> Void
    let onDismiss: () -> Void
    init(onPick: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onPick = onPick
        self.onDismiss = onDismiss
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?
    ) {
        if service != nil {
            onPick()
        } else {
            onDismiss()
        }
    }
}
