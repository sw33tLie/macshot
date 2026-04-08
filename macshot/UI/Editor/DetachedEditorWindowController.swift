import Cocoa
import Vision
import CoreImage

/// Editor window that intercepts Cmd+Q to close itself instead of quitting the app.
/// Uses performClose so windowShouldClose is called (triggers unsaved changes warning).
private class EditorWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Hosts a captured screenshot in a standalone editor window.
/// The image (with any overlay annotations baked in) is displayed in a fresh OverlayView
/// that fills the entire window. selectionRect == bounds == image size, so all coordinate
/// systems align trivially. No translation math needed.
@MainActor
class DetachedEditorWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var overlayView: OverlayView?
    private var topBar: EditorTopBarView?
    private var addCaptureHandler: AddCaptureOverlayHandler?
    private var ocrController: OCRResultController?
    private static var activeControllers: [DetachedEditorWindowController] = []

    /// History entry ID — when set, "Done" button appears and commits edits back to history.
    private var historyEntryID: String?
    /// Snapshot of undo stack depth when last saved, to detect changes.
    private var lastSavedUndoDepth: Int = 0
    /// True if the image has never been output (copied, saved, etc.) — closing would lose the capture.
    /// Set to false on first output action. Editors opened from files start false.
    private var screenshotNeverOutput: Bool = true

    /// Open an editor window with the given image (typically from captureSelectedRegion).
    static func open(image: NSImage, tool: AnnotationTool = .arrow, color: NSColor = .systemRed, strokeWidth: CGFloat = 3, annotations: [Annotation] = [], historyEntryID: String? = nil, fromCapture: Bool = false) {
        let controller = DetachedEditorWindowController()
        controller.historyEntryID = historyEntryID
        // Only warn about unsaved capture if the image came from a live capture (not a file on disk)
        controller.screenshotNeverOutput = fromCapture && historyEntryID == nil
        controller.show(image: image, tool: tool, color: color, strokeWidth: strokeWidth, annotations: annotations)
        activeControllers.append(controller)
        if activeControllers.count == 1 {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func show(image: NSImage, tool: AnnotationTool, color: NSColor, strokeWidth: CGFloat, annotations: [Annotation]) {
        let imgSize = image.size
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame

        let minW: CGFloat = 800
        let minH: CGFloat = 400
        let maxW = screenFrame.width * 0.9
        let maxH = screenFrame.height * 0.9
        // Add space for top bar (32), bottom toolbar (44), options row (40), right toolbar (46), padding
        let chromeW: CGFloat = 46 + 60    // right toolbar + horizontal padding
        let chromeH: CGFloat = 32 + 44 + 40 + 40  // top bar + bottom toolbar + options row + padding
        let winW = min(maxW, max(minW, imgSize.width + chromeW))
        let winH = min(maxH, max(minH, imgSize.height + chromeH))

        let win = EditorWindow(
            contentRect: NSRect(x: screenFrame.midX - winW/2,
                                y: screenFrame.midY - winH/2,
                                width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "macshot Editor"
        win.minSize = NSSize(width: minW, height: minH)
        win.maxSize = NSSize(width: screenFrame.width, height: screenFrame.height)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.fullScreenAuxiliary]

        // Create EditorView as the document view inside an NSScrollView
        let view = EditorView()
        view.frame = NSRect(origin: .zero, size: imgSize)
        view.autoresizingMask = []  // fixed size — scroll view handles viewport
        view.screenshotImage = image
        view.overlayDelegate = self
        view.currentTool = tool
        view.currentColor = color
        view.currentStrokeWidth = strokeWidth

        // NSScrollView for native zoom/pan/centering.
        // The scroll view is inset from the top by the top bar height (32pt) so the
        // scrollbar and content don't go behind the top bar. Bottom/right toolbars
        // are handled via content insets since their sizes are dynamic.
        let topBarHeight: CGFloat = 32
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: winW, height: winH - topBarHeight))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.15, alpha: 1.0)
        // We handle magnification ourselves in OverlayView.scrollWheel/magnify
        // to avoid NSScrollView's internal elastic physics at the zoom boundary.
        // Setting allowsMagnification=false prevents NSScrollView from fighting our zoom.
        scrollView.allowsMagnification = false
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8.0
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = false
        // Insets so user can scroll past document edges to see content behind toolbars:
        // bottom=80 (bottom toolbar + options row), right=46 (right toolbar)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 84, right: 50)
        // Extend scrollbar tracks to window edges (negate content insets effect on scrollers)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: -84, right: -50)

        let clipView = CenteringClipView(frame: scrollView.contentView.frame)
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = view

        // Container holds scroll view + toolbars (toolbars are siblings, not inside scroll view)
        let container = NSView(frame: NSRect(origin: .zero, size: NSSize(width: winW, height: winH)))
        container.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)

        // Top bar — real NSView pinned to top of container
        let topBar = EditorTopBarView(frame: NSRect(x: 0, y: winH - 32, width: winW, height: 32))
        topBar.overlayView = view
        container.addSubview(topBar)
        self.topBar = topBar

        // Show "Done" button when editing a history entry
        if historyEntryID != nil {
            topBar.showDoneButton()
            topBar.onDone = { [weak self] in self?.commitToHistory() }
        }
        if let scale = NSScreen.main?.backingScaleFactor,
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            topBar.updateSizeLabel(width: cg.width, height: cg.height)
        }

        // Observe scroll view magnification for zoom label
        let updateZoom = { [weak topBar, weak scrollView] (_: Notification) in
            if let mag = scrollView?.magnification { topBar?.updateZoom(mag) }
        }
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scrollView, queue: .main, using: updateZoom)
        NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scrollView, queue: .main, using: updateZoom)

        // Set chrome parent BEFORE applySelection so toolbars are added to container, not documentView
        view.chromeParentView = container

        view.applySelection(NSRect(origin: .zero, size: imgSize))
        if !annotations.isEmpty { view.setAnnotations(annotations) }

        // Snapshot undo depth as the "clean" state for unsaved changes detection
        lastSavedUndoDepth = view.undoStack.count

        win.contentView = container
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        // Scroll to top so tall images start at the top, not the bottom
        if let docView = scrollView.documentView {
            docView.scroll(NSPoint(x: 0, y: docView.frame.maxY))
        }

        self.window = win
        self.overlayView = view
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let view = overlayView else { return true }

        // Determine if there are unsaved changes worth warning about
        let hasChanges: Bool
        if historyEntryID != nil {
            // Linked to history — check if undo stack changed since last save
            hasChanges = view.undoStack.count != lastSavedUndoDepth
        } else {
            // Not in history — warn if the image has never been saved/copied
            // (the capture would be lost entirely on close)
            hasChanges = view.undoStack.count > lastSavedUndoDepth
                || view.annotations.contains(where: { $0.isMovable })
                || screenshotNeverOutput
        }

        guard hasChanges else { return true }

        let alert = NSAlert()
        alert.messageText = L("Save changes?")
        alert.informativeText = L("Your annotations will be lost if you close without saving.")
        alert.addButton(withTitle: L("Save & Close"))
        alert.addButton(withTitle: L("Discard"))
        alert.addButton(withTitle: L("Cancel"))
        alert.alertStyle = .warning

        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self = self else { return }
            switch response {
            case .alertFirstButtonReturn:
                // Save & Close — create history entry if needed, then save
                if self.historyEntryID == nil, let composited = view.captureSelectedRegion() {
                    let image = self.applyPostProcessing(composited)
                    self.ensureInHistory(compositedImage: image)
                }
                self.saveToHistory()
                sender.close()
            case .alertSecondButtonReturn:
                // Discard — close without saving, suppress re-triggering the warning
                self.historyEntryID = nil
                self.screenshotNeverOutput = false
                self.lastSavedUndoDepth = view.undoStack.count
                sender.close()
            default:
                break  // Cancel
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        overlayView?.reset()
        overlayView?.overlayDelegate = nil
        window?.contentView = nil
        overlayView = nil
        let closingWindow = window
        window = nil
        Self.activeControllers.removeAll { $0 === self }
        if Self.activeControllers.isEmpty {
            let hasOtherWindows = NSApp.windows.contains { $0 !== closingWindow && $0.isVisible && $0.styleMask.contains(.titled) }
            if !hasOtherWindows {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// Save current editor state to the linked history entry (without closing).
    private func saveToHistory() {
        guard let entryID = historyEntryID, let view = overlayView else { return }
        guard let composited = view.captureSelectedRegion() else { return }
        let finalImage = applyPostProcessing(composited)
        let annotations = view.annotations.filter { $0.isMovable }
        let rawImage: NSImage? = annotations.isEmpty ? nil : view.captureSelectedRegionRaw()
        ScreenshotHistory.shared.updateEntry(
            id: entryID,
            compositedImage: finalImage,
            rawImage: rawImage,
            annotations: annotations.isEmpty ? nil : annotations)
        lastSavedUndoDepth = view.undoStack.count
    }

    /// Commit current editor state back to the history entry, then close.
    private func commitToHistory() {
        saveToHistory()
        window?.close()
    }

    /// Called by output actions (copy, save, etc.) to persist changes to history.
    private func autoSaveToHistoryIfNeeded(compositedImage: NSImage) {
        screenshotNeverOutput = false
        ensureInHistory(compositedImage: compositedImage)
        if historyEntryID != nil {
            saveToHistory()
        }
    }

    /// Apply image effects and beautify to the captured image.
    private func applyPostProcessing(_ image: NSImage) -> NSImage {
        var result = image
        if let view = overlayView, view.effectsActive {
            result = ImageEffects.apply(to: result, config: view.effectsConfig)
        }
        if let view = overlayView, view.beautifyEnabled {
            result = BeautifyRenderer.render(image: result, config: view.beautifyConfig)
        }
        return result
    }
}

// MARK: - OverlayViewDelegate

extension DetachedEditorWindowController: OverlayViewDelegate {
    func overlayViewDidFinishSelection(_ rect: NSRect) {}
    func overlayViewSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidBeginSelection() {}
    func overlayViewRemoteSelectionDidChange(_ rect: NSRect) {}
    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect) {}
    func overlayViewDidCancel() { window?.performClose(nil) }

    func overlayViewDidConfirm() {
        guard let raw = overlayView?.captureSelectedRegion() else { return }
        let image = applyPostProcessing(raw)
        ImageEncoder.copyToClipboard(image)
        playCopySound()
        (NSApp.delegate as? AppDelegate)?.showFloatingThumbnail(image: image)
        autoSaveToHistoryIfNeeded(compositedImage: image)
    }

    func overlayViewDidRequestSave() {
        guard let view = overlayView,
              let raw = view.captureSelectedRegion() else { return }
        let image = applyPostProcessing(raw)
        guard let imageData = ImageEncoder.encode(image) else { return }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [ImageEncoder.utType]
        savePanel.nameFieldStringValue = "macshot_\(OverlayWindowController.formattedTimestamp()).\(ImageEncoder.fileExtension)"
        savePanel.directoryURL = SaveDirectoryAccess.directoryHint()
        savePanel.beginSheetModal(for: window!) { [weak self] response in
            if response == .OK, let url = savePanel.url {
                try? imageData.write(to: url)
                SaveDirectoryAccess.save(url: url.deletingLastPathComponent())
                self?.playCopySound()
                self?.autoSaveToHistoryIfNeeded(compositedImage: image)
            }
        }
    }

    func overlayViewDidRequestPin() {
        guard let raw = overlayView?.captureSelectedRegion() else { return }
        let image = applyPostProcessing(raw)
        playCopySound()
        (NSApp.delegate as? AppDelegate)?.showPin(image: image)
        autoSaveToHistoryIfNeeded(compositedImage: image)
    }

    func overlayViewDidRequestOCR() {
        guard let image = overlayView?.captureSelectedRegion(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let request = VisionOCR.makeTextRecognitionRequest { [weak self] req, _ in
            let lines = (req.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async {
                guard let self = self else { return }
                // OCR action: 0 = window + copy, 1 = window only, 2 = copy only
                let ocrAction = UserDefaults.standard.integer(forKey: "ocrAction")
                let shouldCopy = ocrAction == 0 || ocrAction == 2
                let shouldShowWindow = ocrAction == 0 || ocrAction == 1

                if shouldCopy && !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                if shouldShowWindow {
                    self.ocrController?.close()
                    let ocr = OCRResultController(text: text, image: image)
                    self.ocrController = ocr
                    ocr.show()
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }
    }

    func overlayViewDidRequestQuickSave() {
        guard let view = overlayView,
              let raw = view.captureSelectedRegion() else { return }
        let image = applyPostProcessing(raw)

        // quickCaptureMode: 0=save, 1=copy, 2=both, 3=do nothing (thumbnail only)
        let mode = UserDefaults.standard.object(forKey: "quickCaptureMode") as? Int ?? 1

        if mode == 1 || mode == 2 {
            ImageEncoder.copyToClipboard(image)
        }
        if mode == 0 || mode == 2 {
            saveImageToDirectory(image)
        }
        playCopySound()
        (NSApp.delegate as? AppDelegate)?.showFloatingThumbnail(image: image)

        autoSaveToHistoryIfNeeded(compositedImage: image)
    }

    func overlayViewDidRequestFileSave() {
        guard let raw = overlayView?.captureSelectedRegion() else { return }
        let image = applyPostProcessing(raw)
        saveImageToDirectory(image)
        playCopySound()
        autoSaveToHistoryIfNeeded(compositedImage: image)
    }

    /// Ensure the current editor content is in screenshot history.
    /// Creates a history entry if one doesn't exist yet, and shows the Done button.
    private func ensureInHistory(compositedImage: NSImage) {
        guard historyEntryID == nil, let view = overlayView else { return }
        let annotations = view.annotations.filter { $0.isMovable }
        let rawImage: NSImage? = annotations.isEmpty ? nil : view.captureSelectedRegionRaw()
        ScreenshotHistory.shared.add(
            image: compositedImage,
            rawImage: rawImage,
            annotations: annotations.isEmpty ? nil : annotations)
        historyEntryID = ScreenshotHistory.shared.entries.first?.id
        if historyEntryID != nil {
            topBar?.showDoneButton()
            topBar?.onDone = { [weak self] in self?.commitToHistory() }
        }
    }

    private func saveImageToDirectory(_ image: NSImage) {
        let dirURL = SaveDirectoryAccess.resolve()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let filename = "Screenshot \(formatter.string(from: Date())).\(ImageEncoder.fileExtension)"
        let fileURL = dirURL.appendingPathComponent(filename)

        DispatchQueue.global(qos: .userInitiated).async {
            guard let imageData = ImageEncoder.encode(image) else { return }
            try? imageData.write(to: fileURL)
            SaveDirectoryAccess.stopAccessing(url: dirURL)
        }
    }
    func overlayViewDidRequestUpload() {
        guard let raw = overlayView?.captureSelectedRegion() else { return }
        let image = applyPostProcessing(raw)
        playCopySound()
        (NSApp.delegate as? AppDelegate)?.uploadImage(image)
        autoSaveToHistoryIfNeeded(compositedImage: image)
    }

    func overlayViewDidRequestShare(anchorView: NSView?) {
        guard let raw = overlayView?.captureSelectedRegion() else { return }
        let image = applyPostProcessing(raw)
        guard let imageData = ImageEncoder.encode(image) else { return }
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macshot_\(OverlayWindowController.formattedTimestamp()).\(ImageEncoder.fileExtension)")
        try? imageData.write(to: tempURL)

        let picker = NSSharingServicePicker(items: [tempURL])
        if let anchor = anchorView {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minX)
        } else if let view = overlayView {
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
        autoSaveToHistoryIfNeeded(compositedImage: image)
    }

    @available(macOS 14.0, *)
    func overlayViewDidRequestRemoveBackground() {
        guard let image = overlayView?.captureSelectedRegion(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
                guard let result = request.results?.first else { return }
                let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
                let orig = CIImage(cgImage: cgImage)
                guard let filter = CIFilter(name: "CIBlendWithMask") else { return }
                filter.setValue(orig, forKey: kCIInputImageKey)
                filter.setValue(CIImage(cvPixelBuffer: mask), forKey: kCIInputMaskImageKey)
                filter.setValue(CIImage(color: .clear).cropped(to: orig.extent), forKey: kCIInputBackgroundImageKey)
                guard let out = filter.outputImage,
                      let cg = CIContext().createCGImage(out, from: out.extent) else { return }
                DispatchQueue.main.async {
                    let finalImage = NSImage(cgImage: cg, size: image.size)
                    ImageEncoder.copyToClipboard(finalImage)
                    self.playCopySound()
                    (NSApp.delegate as? AppDelegate)?.showFloatingThumbnail(image: finalImage)
                }
            } catch {}
        }
    }

    func overlayViewDidRequestEnterRecordingMode() {}
    func overlayViewDidRequestStartRecording(rect: NSRect) {}
    func overlayViewDidRequestStopRecording() {}
    func overlayViewDidRequestDetach() {}
    func overlayViewDidRequestScrollCapture(rect: NSRect) {}
    func overlayViewDidRequestStopScrollCapture() {}
    func overlayViewDidRequestToggleAutoScroll() {}
    func overlayViewDidRequestAccessibilityPermission() {}
    func overlayViewDidRequestInputMonitoringPermission() {}

    func overlayViewDidRequestAddCapture() {
        guard let editorWindow = window else { return }

        // Hide editor window while capturing
        editorWindow.orderOut(nil)

        ScreenCaptureManager.captureAllScreens { [weak self] captures in
            guard let self = self else { return }
            guard !captures.isEmpty else {
                editorWindow.makeKeyAndOrderFront(nil)
                return
            }

            let handler = AddCaptureOverlayHandler()
            handler.onCapture = { [weak self] image in
                guard let self = self else { return }
                self.addCapturedImage(image)
                self.addCaptureHandler = nil
            }
            handler.onCancel = { [weak self] in
                self?.window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                self?.addCaptureHandler = nil
            }
            self.addCaptureHandler = handler

            NSApp.activate(ignoringOtherApps: true)
            for capture in captures {
                let controller = OverlayWindowController(capture: capture)
                controller.overlayDelegate = handler
                controller.setAutoConfirmMode()  // no toolbars, auto-confirm on selection
                controller.showOverlay()
                handler.overlayControllers.append(controller)
            }
        }
    }

    private func addCapturedImage(_ image: NSImage) {
        guard let view = overlayView else { return }

        view.addCaptureImage(image)

        // Update top bar size label
        if let cg = view.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let container = window?.contentView {
            for sub in container.subviews {
                if let topBar = sub as? EditorTopBarView {
                    topBar.updateSizeLabel(width: cg.width, height: cg.height)
                    break
                }
            }
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(view)
    }

    private func playCopySound() {
        let enabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        guard enabled else { return }
        AppDelegate.captureSound?.stop()
        AppDelegate.captureSound?.play()
    }
}

// MARK: - Add Capture Overlay Handler

/// Lightweight delegate that handles the temporary overlay lifecycle during "Add Capture".
/// Captures the selected region and returns it to the editor controller.
@MainActor
private class AddCaptureOverlayHandler: NSObject, OverlayWindowControllerDelegate {

    var overlayControllers: [OverlayWindowController] = []
    var onCapture: ((NSImage) -> Void)?
    var onCancel: (() -> Void)?

    private func dismissOverlays() {
        for controller in overlayControllers {
            controller.dismiss()
        }
        overlayControllers.removeAll()
    }

    func overlayDidCancel(_ controller: OverlayWindowController) {
        dismissOverlays()
        onCancel?()
    }

    func overlayDidConfirm(_ controller: OverlayWindowController, capturedImage: NSImage?, annotationData: CaptureAnnotationData?) {
        let image = capturedImage ?? overlayCrossScreenImage(controller)
        dismissOverlays()
        if let image = image {
            onCapture?(image)
        } else {
            onCancel?()
        }
    }

    func overlayDidRequestPin(_ controller: OverlayWindowController, image: NSImage) {
        dismissOverlays()
        onCapture?(image)
    }
    func overlayDidRequestOCR(_ controller: OverlayWindowController, text: String, image: NSImage?) {}
    func overlayDidRequestUpload(_ controller: OverlayWindowController, image: NSImage) {}
    func overlayDidRequestStartRecording(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {}
    func overlayDidRequestStopRecording(_ controller: OverlayWindowController) {}
    func overlayDidRequestScrollCapture(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {}
    func overlayDidRequestStopScrollCapture(_ controller: OverlayWindowController) {}
    func overlayDidRequestToggleAutoScroll(_ controller: OverlayWindowController) {}
    func overlayDidRequestAccessibilityPermission(_ controller: OverlayWindowController) {}
    func overlayDidRequestInputMonitoringPermission(_ controller: OverlayWindowController) {}
    func overlayDidBeginSelection(_ controller: OverlayWindowController) {
        // Clear selections on other overlays
        for other in overlayControllers where other !== controller {
            other.clearSelection()
            other.setRemoteSelection(.zero)
        }
    }
    func overlayDidChangeSelection(_ controller: OverlayWindowController, globalRect: NSRect) {
        for other in overlayControllers where other !== controller {
            let otherOrigin = other.screen.frame.origin
            let localRect = NSRect(x: globalRect.origin.x - otherOrigin.x,
                                   y: globalRect.origin.y - otherOrigin.y,
                                   width: globalRect.width, height: globalRect.height)
            let clipped = localRect.intersection(NSRect(origin: .zero, size: other.screen.frame.size))
            other.setRemoteSelection(clipped.isEmpty ? .zero : clipped, fullRect: localRect)
        }
    }
    func overlayDidRemoteResizeSelection(_ controller: OverlayWindowController, globalRect: NSRect) {}
    func overlayDidFinishRemoteResize(_ controller: OverlayWindowController, globalRect: NSRect) {}

    func overlayCrossScreenImage(_ controller: OverlayWindowController) -> NSImage? {
        let others = overlayControllers.filter { $0 !== controller && $0.remoteSelectionRect.width >= 1 }
        guard !others.isEmpty else { return nil }
        // Use AppDelegate's stitch method via direct replication (avoid tight coupling)
        let primaryOrigin = controller.screen.frame.origin
        let primarySel = controller.selectionRect
        let globalRect = NSRect(x: primarySel.origin.x + primaryOrigin.x,
                                y: primarySel.origin.y + primaryOrigin.y,
                                width: primarySel.width, height: primarySel.height)
        let scale = controller.screen.backingScaleFactor
        let pixelW = Int(globalRect.width * scale)
        let pixelH = Int(globalRect.height * scale)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let cgCtx = CGContext(data: nil, width: pixelW, height: pixelH,
                                     bitsPerComponent: 8, bytesPerRow: pixelW * 4,
                                     space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cgCtx.scaleBy(x: scale, y: scale)
        let allControllers = [controller] + others
        for c in allControllers {
            guard let screenshot = c.screenshotImage else { continue }
            let screenFrame = c.screen.frame
            let drawX = screenFrame.origin.x - globalRect.origin.x
            let drawY = screenFrame.origin.y - globalRect.origin.y
            let drawRect = NSRect(x: drawX, y: drawY, width: screenFrame.width, height: screenFrame.height)
            cgCtx.saveGState()
            cgCtx.clip(to: CGRect(x: 0, y: 0, width: globalRect.width, height: globalRect.height))
            let nsContext = NSGraphicsContext(cgContext: cgCtx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            screenshot.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
            cgCtx.restoreGState()
        }
        guard let cgImage = cgCtx.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: globalRect.size)
    }
}
