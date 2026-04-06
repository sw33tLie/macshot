import Cocoa
import CoreImage
import UniformTypeIdentifiers
import Vision

/// Editable annotation data bundled with a confirmed capture.
struct CaptureAnnotationData {
    let rawImage: NSImage       // screenshot without annotations
    let annotations: [Annotation]
}

@MainActor
protocol OverlayWindowControllerDelegate: AnyObject {
    func overlayDidCancel(_ controller: OverlayWindowController)
    func overlayDidConfirm(_ controller: OverlayWindowController, capturedImage: NSImage?, annotationData: CaptureAnnotationData?)
    func overlayDidRequestPin(_ controller: OverlayWindowController, image: NSImage)
    func overlayDidRequestOCR(_ controller: OverlayWindowController, text: String, image: NSImage?)
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
}

/// Manages one fullscreen overlay per screen.
/// Does NOT subclass NSWindowController to avoid AppKit retain-cycle issues.
@MainActor
class OverlayWindowController {

    weak var overlayDelegate: OverlayWindowControllerDelegate?
    var capturedWindowTitle: String?

    private var overlayView: OverlayView?
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
    var sessionRecordingFormat: String? { overlayView?.sessionRecordingFormat }
    var sessionRecordingFPS: Int? { overlayView?.sessionRecordingFPS }
    var sessionRecordingOnStop: String? { overlayView?.sessionRecordingOnStop }
    var sessionRecordingDelay: Int? { overlayView?.sessionRecordingDelay }

    init(capture: ScreenCapture) {
        let screen = capture.screen
        self.screen = screen

        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(257)  // above modal panels, alerts, and security popups
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let view = OverlayView()
        let nsImage = NSImage(cgImage: capture.image, size: screen.frame.size)
        view.screenshotImage = nsImage
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        view.overlayDelegate = self

        window.contentView = view
        self.overlayWindow = window
        self.overlayView = view
    }

    func showOverlay() {
        guard let window = overlayWindow else { return }
        // Force the view to render into its backing store before showing the window.
        // This ensures the screenshot is fully drawn when the window appears,
        // preventing a flash of the deactivating app underneath.
        if let view = overlayView {
            view.displayIfNeeded()
        }
        window.makeKeyAndOrderFront(nil)
        if let view = overlayView {
            window.makeFirstResponder(view)
        }
    }

    func makeKey() {
        overlayWindow?.makeKeyAndOrderFront(nil)
        if let view = overlayView {
            overlayWindow?.makeFirstResponder(view)
        }
    }

    func applySelection(_ rect: NSRect) {
        overlayView?.applySelection(rect)
    }

    func clearSelection() {
        overlayView?.clearSelection()
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
            overlayView?.startScrollCaptureMode()
        } else {
            overlayView?.stopScrollCaptureMode()
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

    func dismiss() {
        saveSelectionIfNeeded()
        overlayView?.reset()
        overlayView?.screenshotImage = nil
        overlayView?.overlayDelegate = nil
        overlayWindow?.contentView = nil
        overlayView = nil
        overlayWindow?.orderOut(nil)
        overlayWindow?.close()
        overlayWindow = nil
        NSCursor.arrow.set()
    }

    private func saveSelectionIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "rememberLastSelection"),
            let view = overlayView, view.state == .selected,
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

    static func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}

// MARK: - OverlayViewDelegate

extension OverlayWindowController: OverlayViewDelegate {
    func overlayViewDidFinishSelection(_ rect: NSRect) {
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

        // Snapshot annotation data using the raw screenshot (without annotations).
        // Only capture the raw image if there are annotations worth saving.
        let hasAnnotations = overlayView?.annotations.contains(where: { $0.isMovable }) ?? false
        let annotationData: CaptureAnnotationData?
        if hasAnnotations, let rawImage = overlayView?.captureSelectedRegionRaw() {
            annotationData = snapshotAnnotationData(rawImage: rawImage)
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
            let beautifyInput = (beautifyCfg.isWindowSnap && snapWindowImg != nil) ? snapWindowImg! : finalImage
            finalImage = BeautifyRenderer.render(image: beautifyInput, config: beautifyCfg)
        }

        // Copy button / Cmd+C always copies to clipboard
        ImageEncoder.copyToClipboard(finalImage)

        // Don't save annotation data if effects/beautify were applied — the raw image
        // wouldn't match what the user sees, making annotation re-editing confusing.
        let effectiveAnnotationData = (hasEffects || hasBeautify) ? nil : annotationData
        overlayDelegate?.overlayDidConfirm(self, capturedImage: finalImage, annotationData: effectiveAnnotationData)
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

        let request = VisionOCR.makeTextRecognitionRequest { [weak self] request, error in
            guard let self = self else { return }
            var lines: [String] = []
            if let observations = request.results as? [VNRecognizedTextObservation] {
                for observation in observations {
                    if let candidate = observation.topCandidates(1).first {
                        lines.append(candidate.string)
                    }
                }
            }
            let text = lines.joined(separator: "\n")
            let capturedImage = image  // capture before dismiss
            DispatchQueue.main.async {
                self.playCopySound()
                self.dismiss()
                self.overlayDelegate?.overlayDidRequestOCR(self, text: text, image: capturedImage)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
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
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "macshot_\(Self.formattedTimestamp()).\(ImageEncoder.fileExtension)")
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
                let cs = CGColorSpaceCreateDeviceRGB()
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
            annotations: shiftedAnnotations)
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

        // Snapshot annotation data using the raw screenshot (single extra render only if needed)
        let hasAnnotations = overlayView?.annotations.contains(where: { $0.isMovable }) ?? false
        let annotationData: CaptureAnnotationData?
        if hasAnnotations, let rawImage = overlayView?.captureSelectedRegionRaw() {
            annotationData = snapshotAnnotationData(rawImage: rawImage)
        } else {
            annotationData = nil
        }

        dismiss()

        // Apply post-processing
        var image = compositedImage
        if hasEffects { image = ImageEffects.apply(to: image, config: effectsCfg) }
        if hasBeautify {
            let beautifyInput = (beautifyCfg.isWindowSnap && snapWindowImg != nil) ? snapWindowImg! : image
            image = BeautifyRenderer.render(image: beautifyInput, config: beautifyCfg)
        }

        // quickCaptureMode: 0=save, 1=copy, 2=both, 3=do nothing (thumbnail only)
        let mode = UserDefaults.standard.object(forKey: "quickCaptureMode") as? Int ?? 1

        if mode == 1 || mode == 2 {
            ImageEncoder.copyToClipboard(image)
        }
        playCopySound()

        let effectiveAnnotationData = (hasEffects || hasBeautify) ? nil : annotationData
        overlayDelegate?.overlayDidConfirm(self, capturedImage: image, annotationData: effectiveAnnotationData)

        if mode == 0 || mode == 2 {
            saveImageToDirectory(image)
        }
        // mode 3: do nothing — image is passed to delegate which shows the thumbnail
    }

    func overlayViewDidRequestFileSave() {
        // Snapshot post-processing config before dismissing
        let hasEffects = overlayView?.effectsActive ?? false
        let effectsCfg = overlayView?.effectsConfig ?? ImageEffectsConfig()
        let hasBeautify = overlayView?.beautifyEnabled ?? false
        let beautifyCfg = overlayView?.beautifyConfig ?? BeautifyConfig()
        let snapWindowImg = overlayView?.snappedWindowImage

        guard let rawImage = captureRegion() else {
            dismiss()
            overlayDelegate?.overlayDidCancel(self)
            return
        }

        playCopySound()
        dismiss()

        // Apply post-processing
        var image = rawImage
        if hasEffects { image = ImageEffects.apply(to: image, config: effectsCfg) }
        if hasBeautify {
            let beautifyInput = (beautifyCfg.isWindowSnap && snapWindowImg != nil) ? snapWindowImg! : image
            image = BeautifyRenderer.render(image: beautifyInput, config: beautifyCfg)
        }

        overlayDelegate?.overlayDidConfirm(self, capturedImage: image, annotationData: nil)
        saveImageToDirectory(image)
    }

    private func saveImageToDirectory(_ image: NSImage) {
        let dirURL = SaveDirectoryAccess.resolve()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let timestamp = formatter.string(from: Date())
        let useWindowTitle = UserDefaults.standard.bool(forKey: "useWindowTitleInFilename")
        let filename: String
        if useWindowTitle, let title = capturedWindowTitle {
            let safe = title.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            filename = "Screenshot \(timestamp) — \(safe).\(ImageEncoder.fileExtension)"
        } else {
            filename = "Screenshot \(timestamp).\(ImageEncoder.fileExtension)"
        }
        let fileURL = dirURL.appendingPathComponent(filename)

        DispatchQueue.global(qos: .userInitiated).async {
            guard let imageData = ImageEncoder.encode(image) else { return }
            try? imageData.write(to: fileURL)
            SaveDirectoryAccess.stopAccessing(url: dirURL)
        }
    }

    func overlayViewDidRequestSave() {
        guard var image = captureRegion() else { return }
        image = applyBeautifyIfNeeded(image) ?? image
        guard let imageData = ImageEncoder.encode(image) else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [ImageEncoder.utType]
        savePanel.nameFieldStringValue =
            "macshot_\(Self.formattedTimestamp()).\(ImageEncoder.fileExtension)"
        savePanel.level = NSWindow.Level(258)

        savePanel.directoryURL = SaveDirectoryAccess.directoryHint()

        savePanel.begin { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = savePanel.url {
                try? imageData.write(to: url)
                SaveDirectoryAccess.save(url: url.deletingLastPathComponent())
                self.playCopySound()
                self.dismiss()
                self.overlayDelegate?.overlayDidConfirm(self, capturedImage: nil, annotationData: nil)
            } else {
                self.overlayWindow?.makeKeyAndOrderFront(nil)
                if let view = self.overlayView {
                    self.overlayWindow?.makeFirstResponder(view)
                }
            }
        }
    }
}

// MARK: - Custom Window subclass

class OverlayWindow: NSWindow {
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
