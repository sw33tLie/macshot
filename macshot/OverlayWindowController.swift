import Cocoa
import UniformTypeIdentifiers
import Vision
import CoreImage

@MainActor
protocol OverlayWindowControllerDelegate: AnyObject {
    func overlayDidCancel(_ controller: OverlayWindowController)
    func overlayDidConfirm(_ controller: OverlayWindowController, capturedImage: NSImage?)
    func overlayDidRequestPin(_ controller: OverlayWindowController, image: NSImage)
    func overlayDidRequestOCR(_ controller: OverlayWindowController, text: String, image: NSImage?)
    func overlayDidRequestDelayCapture(_ controller: OverlayWindowController, seconds: Int, selectionRect: NSRect)
    func overlayDidRequestUpload(_ controller: OverlayWindowController, image: NSImage)
    func overlayDidRequestStartRecording(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen)
    func overlayDidRequestStopRecording(_ controller: OverlayWindowController)
    func overlayDidRequestScrollCapture(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen)
    func overlayDidRequestStopScrollCapture(_ controller: OverlayWindowController)
}

/// Manages one fullscreen overlay per screen.
/// Does NOT subclass NSWindowController to avoid AppKit retain-cycle issues.
@MainActor
class OverlayWindowController {

    weak var overlayDelegate: OverlayWindowControllerDelegate?

    private var overlayView: OverlayView?
    private var overlayWindow: OverlayWindow?
    private var recordingControlWindow: NSWindow?
    private var recordingControlView: RecordingControlView?
    var windowNumber: CGWindowID { overlayWindow.map { CGWindowID($0.windowNumber) } ?? CGWindowID.max }
    private(set) var screen: NSScreen = NSScreen.main!

    init(capture: ScreenCapture) {
        let screen = capture.screen
        self.screen = screen

        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar + 1
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

        view.onAnnotationModeChanged = { [weak self] isAnnotating in
            self?.updateAnnotationMode(isAnnotating: isAnnotating)
        }
    }

    func showOverlay() {
        guard let window = overlayWindow else { return }
        window.makeKeyAndOrderFront(nil)
        if let view = overlayView {
            window.makeFirstResponder(view)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applySelection(_ rect: NSRect) {
        overlayView?.applySelection(rect)
    }

    /// Auto-select the full screen (as if user clicked without dragging).
    func applyFullScreenSelection() {
        overlayView?.applyFullScreenSelection()
    }

    /// Set flag so overlay enters recording mode after user makes a selection.
    func setAutoRecordMode() {
        overlayView?.autoEnterRecordingMode = true
    }

    /// Enter recording mode — pass-through, control window, app underneath gets focus.
    func enterRecordingMode() {
        overlayView?.isRecording = true
        overlayView?.startPassThroughMode()
        overlayView?.rebuildToolbarLayout()
        overlayView?.needsDisplay = true
        showRecordingControlWindow()
    }

    func setRecordingState(isRecording: Bool, elapsedSeconds: Int = 0) {
        overlayView?.isRecording = isRecording
        overlayView?.recordingElapsedSeconds = elapsedSeconds
        if isRecording {
            overlayView?.startPassThroughMode()
            showRecordingControlWindow()
        } else {
            dismissRecordingControlWindow()
        }
        overlayView?.rebuildToolbarLayout()
        overlayView?.needsDisplay = true
    }

    private func showRecordingControlWindow() {
        dismissRecordingControlWindow()
        guard let overlayView = overlayView, let overlayWindow = overlayWindow else { return }

        // Wait one run-loop tick for rebuildToolbarLayout to compute rightBarRect
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let overlayView = self.overlayView else { return }
            let rightBarLocal = overlayView.rightBarRect
            guard rightBarLocal != .zero else { return }
            let rightBarScreen = overlayWindow.convertToScreen(
                overlayView.convert(rightBarLocal, to: nil)
            )

            let win = RecordingControlWindow(
                contentRect: rightBarScreen,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.level = .statusBar + 2
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.ignoresMouseEvents = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.isReleasedWhenClosed = false

            let cv = RecordingControlView(frame: NSRect(origin: .zero, size: rightBarScreen.size))
            cv.overlayView = overlayView
            win.contentView = cv
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(cv)

            self.recordingControlWindow = win
            self.recordingControlView = cv
        }
    }

    private func dismissRecordingControlWindow() {
        recordingControlWindow?.orderOut(nil)
        recordingControlWindow?.close()
        recordingControlWindow = nil
        recordingControlView = nil
    }

    func updateRecordingProgress(seconds: Int) {
        overlayView?.recordingElapsedSeconds = seconds
        overlayView?.needsDisplay = true
        recordingControlView?.needsDisplay = true
    }

    func updateAnnotationMode(isAnnotating: Bool) {
        // When annotating: hide control window, show main overlay interactive
        // When not annotating: show control window, main overlay ignores events
        if isAnnotating {
            recordingControlWindow?.orderOut(nil)
        } else {
            recordingControlWindow?.orderFront(nil)
        }
    }

    func setScrollCaptureState(isActive: Bool, stripCount: Int = 0, pixelSize: CGSize = .zero) {
        if isActive {
            overlayView?.startScrollCaptureMode()
        } else {
            overlayView?.stopScrollCaptureMode()
        }
        overlayView?.scrollCaptureStripCount = stripCount
        overlayView?.scrollCapturePixelSize  = pixelSize
        overlayView?.needsDisplay = true
    }

    func updateScrollCaptureProgress(stripCount: Int, pixelSize: CGSize) {
        overlayView?.scrollCaptureStripCount = stripCount
        overlayView?.scrollCapturePixelSize  = pixelSize
        overlayView?.needsDisplay = true
    }

    func dismiss() {
        dismissRecordingControlWindow()
        saveSelectionIfNeeded()
        overlayView?.reset()
        overlayView?.screenshotImage = nil
        overlayView?.overlayDelegate = nil
        overlayWindow?.contentView = nil
        overlayView = nil
        overlayWindow?.orderOut(nil)
        overlayWindow?.close()
        overlayWindow = nil
    }

    private func saveSelectionIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "rememberLastSelection"),
              let view = overlayView, view.state == .selected,
              view.selectionRect.width > 1, view.selectionRect.height > 1 else { return }
        UserDefaults.standard.set(NSStringFromRect(view.selectionRect), forKey: "lastSelectionRect")
        UserDefaults.standard.set(NSStringFromRect(screen.frame), forKey: "lastSelectionScreenFrame")
    }

    private func playCopySound() {
        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        guard soundEnabled else { return }
        AppDelegate.captureSound?.stop()
        AppDelegate.captureSound?.play()
    }

    private func applyBeautifyIfNeeded(_ image: NSImage?) -> NSImage? {
        guard let image = image, let view = overlayView, view.beautifyEnabled else { return image }
        return BeautifyRenderer.render(image: image, config: view.beautifyConfig)
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
    }

    func overlayViewDidCancel() {
        dismiss()
        overlayDelegate?.overlayDidCancel(self)
    }

    func overlayViewDidConfirm() {
        let autoCopy = UserDefaults.standard.object(forKey: "autoCopyToClipboard") as? Bool ?? true

        // Capture image BEFORE dismiss destroys the view
        var capturedImage = overlayView?.captureSelectedRegion()
        capturedImage = applyBeautifyIfNeeded(capturedImage)

        if autoCopy, let image = capturedImage {
            copyImageToClipboard(image)
        }

        playCopySound()
        dismiss()
        overlayDelegate?.overlayDidConfirm(self, capturedImage: capturedImage)
    }

    func overlayViewDidRequestPin() {
        guard var image = overlayView?.captureSelectedRegion() else { return }
        image = applyBeautifyIfNeeded(image) ?? image
        playCopySound()
        dismiss()
        overlayDelegate?.overlayDidRequestPin(self, image: image)
    }

    func overlayViewDidRequestOCR() {
        guard let image = overlayView?.captureSelectedRegion() else { return }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let request = VNRecognizeTextRequest { [weak self] request, error in
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
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    func overlayViewDidRequestDelayCapture(seconds: Int, selectionRect: NSRect) {
        overlayDelegate?.overlayDidRequestDelayCapture(self, seconds: seconds, selectionRect: selectionRect)
    }

    func overlayViewDidRequestUpload() {
        guard var image = overlayView?.captureSelectedRegion() else { return }
        image = applyBeautifyIfNeeded(image) ?? image
        playCopySound()
        dismiss()
        overlayDelegate?.overlayDidRequestUpload(self, image: image)
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

    func overlayViewDidRequestDetach() {
        guard let view = overlayView else { return }
        let sel = view.selectionRect

        // Crop just the raw screenshot (no annotations) to the selection area.
        let croppedImage: NSImage? = {
            guard let src = view.screenshotImage else { return nil }
            let img = NSImage(size: sel.size)
            img.lockFocus()
            src.draw(in: NSRect(origin: .zero, size: sel.size),
                     from: sel, operation: .copy, fraction: 1.0)
            img.unlockFocus()
            return img
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
        DetachedEditorWindowController.open(image: image, tool: tool, color: color, strokeWidth: stroke, annotations: shiftedAnnotations)
    }

    @available(macOS 14.0, *)
    func overlayViewDidRequestRemoveBackground() {
        guard var image = overlayView?.captureSelectedRegion() else { return }
        image = applyBeautifyIfNeeded(image) ?? image
        
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
                guard let result = request.results?.first else { throw NSError(domain: "Macshot", code: 1) }
                
                let maskPixelBuffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
                
                let originalCIImage = CIImage(cgImage: cgImage)
                let maskCIImage = CIImage(cvPixelBuffer: maskPixelBuffer)
                
                // Blend original with mask
                guard let filter = CIFilter(name: "CIBlendWithMask") else { throw NSError(domain: "Macshot", code: 2) }
                filter.setValue(originalCIImage, forKey: kCIInputImageKey)
                filter.setValue(maskCIImage, forKey: kCIInputMaskImageKey)
                filter.setValue(CIImage(color: .clear).cropped(to: originalCIImage.extent), forKey: kCIInputBackgroundImageKey)
                
                guard let outputCIImage = filter.outputImage else { throw NSError(domain: "Macshot", code: 3) }
                
                let context = CIContext()
                guard let finalCGImage = context.createCGImage(outputCIImage, from: outputCIImage.extent) else { throw NSError(domain: "Macshot", code: 4) }
                
                let finalNSImage = NSImage(cgImage: finalCGImage, size: image.size)
                
                DispatchQueue.main.async {
                    let autoCopy = UserDefaults.standard.object(forKey: "autoCopyToClipboard") as? Bool ?? true
                    if autoCopy {
                        self.copyImageToClipboard(finalNSImage)
                    }
                    self.playCopySound()
                    self.dismiss()
                    self.overlayDelegate?.overlayDidConfirm(self, capturedImage: finalNSImage)
                }
            } catch {
                print("Vision background removal error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.overlayView?.showOverlayError("Background removal failed — no clear subject found.")
                }
            }
        }
    }

    func overlayViewDidRequestQuickSave() {
        guard let image = overlayView?.captureSelectedRegion() else {
            dismiss()
            overlayDelegate?.overlayDidCancel(self)
            return
        }

        let copyMode = UserDefaults.standard.object(forKey: "quickModeCopyToClipboard") as? Bool ?? false

        if copyMode {
            copyImageToClipboard(image)
            playCopySound()
            dismiss()
            overlayDelegate?.overlayDidConfirm(self, capturedImage: image)
        } else {
            // Dismiss immediately for responsiveness, then save in background
            playCopySound()
            dismiss()
            overlayDelegate?.overlayDidConfirm(self, capturedImage: image)

            let dirURL: URL
            if let savedPath = UserDefaults.standard.string(forKey: "saveDirectory") {
                dirURL = URL(fileURLWithPath: savedPath)
            } else {
                dirURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                    ?? FileManager.default.homeDirectoryForCurrentUser
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let filename = "Screenshot \(formatter.string(from: Date())).\(ImageEncoder.fileExtension)"
            let fileURL = dirURL.appendingPathComponent(filename)

            DispatchQueue.global(qos: .userInitiated).async {
                guard let imageData = ImageEncoder.encode(image) else { return }
                try? imageData.write(to: fileURL)
            }
        }
    }

    func overlayViewDidRequestSave() {
        guard var image = overlayView?.captureSelectedRegion() else { return }
        image = applyBeautifyIfNeeded(image) ?? image
        guard let imageData = ImageEncoder.encode(image) else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [ImageEncoder.utType]
        savePanel.nameFieldStringValue = "macshot_\(Self.formattedTimestamp()).\(ImageEncoder.fileExtension)"
        savePanel.level = .statusBar + 3

        if let savedPath = UserDefaults.standard.string(forKey: "saveDirectory") {
            savePanel.directoryURL = URL(fileURLWithPath: savedPath)
        } else {
            savePanel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        }

        savePanel.begin { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = savePanel.url {
                try? imageData.write(to: url)
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "saveDirectory")
                self.playCopySound()
                self.dismiss()
                self.overlayDelegate?.overlayDidConfirm(self, capturedImage: nil)
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
