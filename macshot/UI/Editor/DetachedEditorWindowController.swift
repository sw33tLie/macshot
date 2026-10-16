import Cocoa
import Vision
import CoreImage

/// Editor window that intercepts Cmd+Q to close itself instead of quitting the app.
/// Uses performClose so windowShouldClose is called (triggers unsaved changes warning).
private class EditorWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if KeyboardShortcutMatcher.matches(event, character: "q", modifiers: .command) {
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
    /// Identifies the saved undo branch, including edits made after an undo.
    private var lastSavedUndoState: UUID?
    private var contentRevision: UInt64 = 0
    private var newestHistorySaveRevision: UInt64 = 0
    /// Snapshot of the post-processing (beautify/effects) state when last saved.
    /// Compared by value (Equatable) rather than via re-serialized bytes — the old
    /// string signature re-encoded PNGs / float JSON, which was unstable and caused
    /// spurious "Save changes?" prompts on close with no edits.
    private var lastSavedEditState: CaptureEditState = CaptureEditState()
    /// True if the image has never been output (copied, saved, etc.) — closing would lose the capture.
    /// Set to false on first output action. Editors opened from files start false.
    private var screenshotNeverOutput: Bool = true
    /// When true, force beautify off on open (image already has beautify baked in).
    private var disableBeautifyOnOpen: Bool = false
    private var initialEditState: CaptureEditState?

    /// Open an editor window with the given image (typically from captureSelectedRegion).
    /// When `disableBeautify` is true, beautify starts off regardless of UserDefaults
    /// (used when the image already has beautify baked in).
    ///
    /// `tool`, `color`, and `strokeWidth` are nil by default — when nil, the new
    /// EditorView keeps whatever its property initializers loaded from
    /// UserDefaults (the user's last-used choices). Pass explicit values only
    /// when a caller needs to force a specific state. Don't restore defaults
    /// here: writing `view.currentTool = .arrow` triggers the didSet that
    /// persists "arrow" globally, wiping the user's last-tool memory across
    /// the whole app.
    static func open(image: NSImage, tool: AnnotationTool? = nil, color: NSColor? = nil, strokeWidth: CGFloat? = nil, annotations: [Annotation] = [], historyEntryID: String? = nil, fromCapture: Bool = false, disableBeautify: Bool = false, editState: CaptureEditState? = nil) {
        let controller = DetachedEditorWindowController()
        controller.historyEntryID = historyEntryID
        controller.disableBeautifyOnOpen = disableBeautify
        controller.initialEditState = editState
        // Only warn about unsaved capture if the image came from a live capture (not a file on disk)
        controller.screenshotNeverOutput = fromCapture && historyEntryID == nil
        controller.show(image: image, tool: tool, color: color, strokeWidth: strokeWidth, annotations: annotations)
        activeControllers.append(controller)
        if activeControllers.count == 1 {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func show(image: NSImage, tool: AnnotationTool?, color: NSColor?, strokeWidth: CGFloat?, annotations: [Annotation]) {
        let imgSize = image.size
        // screens can be empty while displays are asleep; a force unwrap here
        // would take the app down rather than open the editor.
        let screenFrame = NSScreen.preferredVisibleFrame

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
        // Timestamp suffix so multiple editor windows are distinguishable
        // in the Dock menu, Window menu, and Mission Control.
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "HH:mm:ss"
        win.title = "macshot Editor · \(dateFmt.string(from: Date()))"
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
        // Only override the EditorView's own initializers when the caller
        // explicitly passed values — otherwise the user's persisted choices
        // (loaded from UserDefaults during EditorView init) survive intact.
        if let tool = tool { view.currentTool = tool }
        if let color = color { view.currentColor = color }
        if let strokeWidth = strokeWidth { view.currentStrokeWidth = strokeWidth }
        if disableBeautifyOnOpen {
            view.beautifyEnabled = false
        }

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

        // "Done" commits edits back to history. It's only revealed once the user
        // actually edits something (matching the overlay → editor flow, which has
        // no Done until you draw). Wire the action now; visibility is driven by
        // refreshDoneButtonVisibility() via the view's onContentChanged hook.
        topBar.onDone = { [weak self] in self?.commitToHistory() }
        view.onContentChanged = { [weak self] in
            self?.contentRevision &+= 1
            self?.refreshDoneButtonVisibility()
        }
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            topBar.updateSizeLabel(width: cg.width, height: cg.height)
        }

        // Observe scroll view magnification for zoom label
        NotificationCenter.default.addObserver(self, selector: #selector(scrollPositionDidChange(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollPositionDidChange(_:)),
            name: NSScrollView.didLiveScrollNotification, object: scrollView)

        // Set chrome parent BEFORE applySelection so toolbars are added to container, not documentView
        view.chromeParentView = container

        view.applySelection(NSRect(origin: .zero, size: imgSize))
        if !annotations.isEmpty { view.setAnnotations(annotations) }
        if let editState = initialEditState {
            view.applyCaptureEditState(editState)
        }

        // Settle any deferred state before snapshotting the clean baseline, so a
        // later draw can't mutate it and trigger a spurious "Save changes?" on
        // close. (The custom beautify background used to lazy-load inside the
        // beautifyConfig getter on first draw.)
        view.ensureCustomBeautifyBackgroundLoaded()

        // Snapshot the clean baseline for unsaved-changes detection.
        captureCleanBaseline(view)

        win.contentView = container
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        // Fit-to-window for large images: compute the magnification that makes
        // the image just fit the visible scroll viewport, capped at 1.0 so we
        // never zoom small images up. Without this, opening (e.g.) a 4284x5712
        // photo on a typical screen shows only the top-left corner at 1x (#161).
        // The scrollView's contentView bounds are valid after layout, which
        // happens during makeKeyAndOrderFront. clipView.bounds reflects the
        // inset-aware visible area.
        scrollView.layoutSubtreeIfNeeded()
        let visible = scrollView.contentView.bounds.size
        if imgSize.width > 0, imgSize.height > 0, visible.width > 0, visible.height > 0 {
            let fitMag = min(visible.width / imgSize.width, visible.height / imgSize.height)
            // Only scale down — leave small images at 1x.
            let initialMag = min(1.0, fitMag)
            // Clamp into the scroll view's allowed range.
            let clamped = max(scrollView.minMagnification, min(scrollView.maxMagnification, initialMag))
            if clamped < 0.999 {
                scrollView.magnification = clamped
                topBar.updateZoom(clamped)
            }
        }

        // Scroll to top so tall images start at the top, not the bottom.
        // Skipped when we fit-to-window because the centering clip view
        // already presents the whole image in view.
        if let docView = scrollView.documentView, scrollView.magnification >= 0.999 {
            docView.scroll(NSPoint(x: 0, y: docView.frame.maxY))
        }

        self.window = win
        self.overlayView = view
    }

    /// Record the current state as the "clean" baseline against which a close
    /// prompts (or doesn't). Call after open and after every save.
    private func captureCleanBaseline(_ view: OverlayView) {
        lastSavedUndoState = view.undoStateIdentity
        lastSavedEditState = view.captureEditState()
        refreshDoneButtonVisibility()
    }

    /// True if the user has edited anything since the clean baseline.
    private func isDirty() -> Bool {
        guard let view = overlayView else { return false }
        return screenshotNeverOutput || view.undoStateIdentity != lastSavedUndoState
            || view.captureEditState() != lastSavedEditState
    }

    /// Show the "Done" (commit-to-history) button only when there are unsaved
    /// edits — like the overlay → editor flow, which has no Done until you draw.
    private func refreshDoneButtonVisibility() {
        if isDirty() {
            topBar?.showDoneButton()
        } else {
            topBar?.hideDoneButton()
        }
    }

    // MARK: - NSWindowDelegate

    @objc private func scrollPositionDidChange(_ notification: Notification) {
        if let scrollView = notification.object as? NSScrollView { topBar?.updateZoom(scrollView.magnification) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let view = overlayView else { return true }

        // Only warn when the user actually changed something since the editor's
        // clean baseline (captured at open, after existing annotations + edit
        // state were applied). Annotation/image edits change the undo identity; beautify
        // and effects changes show up in the edit state, compared by value. We do
        // NOT byte-compare re-serialized state — that was unstable (re-encoded
        // PNGs / float JSON) and nagged on a pristine close. Same rule whether or
        // not the entry is linked to history.
        let hasChanges = isDirty()

        guard hasChanges else { return true }

        let alert = NSAlert()
        alert.messageText = L("Save changes?")
        alert.informativeText = L("Your annotations will be lost if you close without saving.")
        alert.addButton(withTitle: L("Save & Close"))
        alert.addButton(withTitle: L("Discard"))
        alert.addButton(withTitle: L("Cancel"))
        alert.alertStyle = .warning

        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self = self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.saveToHistory { [weak self, weak sender] success in
                    guard success, let self, !self.isDirty() else { return }
                    sender?.close()
                }
            case .alertSecondButtonReturn:
                // Discard — close without saving, suppress re-triggering the warning
                self.historyEntryID = nil
                self.screenshotNeverOutput = false
                self.captureCleanBaseline(view)
                sender?.close()
            default:
                break  // Cancel
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        overlayView?.reset()
        overlayView?.overlayDelegate = nil
        window?.contentView = nil
        overlayView = nil
        window = nil
        Self.activeControllers.removeAll { $0 === self }
        if Self.activeControllers.isEmpty {
            (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
        }
    }

    /// One output action owns its image, editable data and clean-state marker.
    /// A file-save completion must not combine that image with later edits.
    private struct HistorySave {
        let image: NSImage
        let annotationData: CaptureAnnotationData?
        let undoState: UUID
        let editState: CaptureEditState
        let revision: UInt64
    }

    private func captureHistorySave() -> HistorySave? {
        guard let view = overlayView, let composited = view.captureSelectedRegion() else { return nil }
        return HistorySave(image: applyPostProcessing(composited), annotationData: currentAnnotationData(),
            undoState: view.undoStateIdentity, editState: view.captureEditState(), revision: contentRevision)
    }

    /// Save current editor state to the linked history entry (without closing).
    private func saveToHistory(completion: ((Bool) -> Void)? = nil) {
        guard let save = captureHistorySave() else { completion?(false); return }
        saveToHistory(save, completion: completion)
    }

    private func saveToHistory(_ save: HistorySave, completion: ((Bool) -> Void)? = nil) {
        // File-save callbacks may arrive in a different order from the user's
        // output actions. Never replace an already submitted newer edit.
        guard save.revision >= newestHistorySaveRevision else { completion?(false); return }
        newestHistorySaveRevision = save.revision
        let finalImage = save.image
        let data = save.annotationData
        let finished: (Bool) -> Void = { [weak self] success in
            guard let self else { completion?(success); return }
            let unchanged = self.overlayView?.undoStateIdentity == save.undoState
                && self.overlayView?.captureEditState() == save.editState
            if success {
                self.screenshotNeverOutput = false
                self.lastSavedUndoState = save.undoState
                self.lastSavedEditState = save.editState
                self.refreshDoneButtonVisibility()
                if let id = self.historyEntryID {
                    (NSApp.delegate as? AppDelegate)?.refreshThumbnail(for: id, image: finalImage, annotationData: data)
                }
            }
            completion?(success && unchanged)
        }
        let history = ScreenshotHistory.shared
        guard history.maxEntries > 0 else {
            // Save & Close still needs a durable destination when the user has
            // disabled history. Honour the normal save preference/sheet.
            historyEntryID = nil
            ImageSaveService.save(finalImage, sheetWindow: window, completion: finished)
            return
        }
        if let id = historyEntryID, history.containsEntry(id: id) {
            history.updateEntry(id: id, compositedImage: finalImage, rawImage: data?.rawImage,
                annotations: data?.annotations, editState: data?.editState, completion: finished)
        } else {
            historyEntryID = history.add(image: finalImage, rawImage: data?.rawImage,
                annotations: data?.annotations, editState: data?.editState, completion: finished)
            if historyEntryID != nil {
                topBar?.onDone = { [weak self] in self?.commitToHistory() }
            }
        }
    }

    /// Commit current editor state back to the history entry, then close.
    private func commitToHistory() {
        guard let save = captureHistorySave() else { return }
        saveToHistory(save) { [weak self] success in
            guard success, let self, !self.isDirty() else { return }
            self.window?.close()
            if let entryID = self.historyEntryID {
                (NSApp.delegate as? AppDelegate)?.showFloatingThumbnail(image: save.image, annotationData: save.annotationData, historyEntryID: entryID)
            }
        }
    }

    /// Called by output actions (copy, save, etc.) to persist changes to history.
    private func autoSaveToHistoryIfNeeded(_ save: HistorySave) {
        screenshotNeverOutput = false
        guard ScreenshotHistory.shared.maxEntries > 0 else { return }
        saveToHistory(save)
    }

    private func currentAnnotationData() -> CaptureAnnotationData? {
        guard let view = overlayView else { return nil }
        let annotations = view.annotations.filter { $0.isMovable }.map { $0.clone() }
        let editState = view.captureEditState()
        guard !annotations.isEmpty || editState.hasPostProcessing,
              let rawImage = view.captureSelectedRegionRaw() else { return nil }
        return CaptureAnnotationData(
            rawImage: rawImage,
            annotations: annotations,
            editState: editState.hasPostProcessing ? editState : nil
        )
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
        guard let save = captureHistorySave() else { return }
        ImageEncoder.copyToClipboard(save.image)
        playCopySound()
        autoSaveToHistoryIfNeeded(save)
        if UserDefaults.standard.bool(forKey: "closeEditorAfterCopy") {
            window?.close()
        }
        (NSApp.delegate as? AppDelegate)?.showFloatingThumbnail(image: save.image, annotationData: save.annotationData, historyEntryID: historyEntryID)
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
        guard let save = captureHistorySave() else { return }
        ImageSaveService.showSavePanel(for: save.image, sheetWindow: window) { [weak self] success in
            if success {
                self?.playCopySound()
                self?.autoSaveToHistoryIfNeeded(save)
            }
        }
    }

    func overlayViewDidRequestPin() {
        guard let save = captureHistorySave() else { return }
        playCopySound()
        (NSApp.delegate as? AppDelegate)?.showPin(image: save.image)
        autoSaveToHistoryIfNeeded(save)
    }

    func overlayViewDidRequestOCR() {
        guard let image = overlayView?.captureSelectedRegion(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            VisionOCR.performTextAndQRCodeRecognition(cgImage: cgImage) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // OCR & QR action: 0 = window + copy, 1 = window only, 2 = copy only
                    let ocrAction = UserDefaults.standard.integer(forKey: "ocrAction")
                    let shouldCopy = ocrAction == 0 || ocrAction == 2
                    let shouldShowWindow = ocrAction == 0 || ocrAction == 1

                    if shouldCopy && !result.copyText.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.copyText, forType: .string)
                    }
                    if shouldShowWindow {
                        self.ocrController?.close()
                        let ocr = OCRResultController(text: result.text, image: image, qrCodes: result.qrCodes)
                        ocr.onClose = { [weak self, weak ocr] in
                            if self?.ocrController === ocr { self?.ocrController = nil }
                        }
                        self.ocrController = ocr
                        ocr.show()
                    }
                }
            }
        }
    }

    func overlayViewDidRequestQuickSave() {
        guard let save = captureHistorySave() else { return }

        let mode = QuickCaptureMode.current

        if mode.shouldCopyImage {
            ImageEncoder.copyToClipboard(save.image)
        }
        if mode.shouldSave {
            ImageSaveService.saveToConfiguredFolder(
                save.image,
                sheetWindow: window,
                copyPathToClipboard: mode.copyPathOverride)
        }
        playCopySound()
        autoSaveToHistoryIfNeeded(save)
        (NSApp.delegate as? AppDelegate)?.showFloatingThumbnail(image: save.image, annotationData: save.annotationData, historyEntryID: historyEntryID)
    }

    func overlayViewDidRequestFileSave() {
        guard let save = captureHistorySave() else { return }
        ImageSaveService.saveToConfiguredFolder(save.image, sheetWindow: window) { [weak self] success in
            if success {
                self?.playCopySound()
                self?.autoSaveToHistoryIfNeeded(save)
            }
        }
    }

    func overlayViewDidRequestUpload() {
        #if !OFFLINE
        guard let save = captureHistorySave() else { return }
        playCopySound()
        (NSApp.delegate as? AppDelegate)?.uploadImage(save.image)
        autoSaveToHistoryIfNeeded(save)
        #endif
    }

    func overlayViewDidRequestShare(anchorView: NSView?) {
        guard let save = captureHistorySave(), let imageData = ImageEncoder.encode(save.image) else { return }
        let tempURL = TmpScratchDirectory.makeURL(filename: FilenameFormatter.defaultImageFilename())
        try? imageData.write(to: tempURL)

        let picker = NSSharingServicePicker(items: [tempURL])
        if let anchor = anchorView {
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minX)
        } else if let view = overlayView {
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
        autoSaveToHistoryIfNeeded(save)
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
    func overlayViewDidRequestCancelScrollCapture() {}
    func overlayViewDidRequestToggleAutoScroll() {}
    func overlayViewDidRequestAccessibilityPermission() {}
    func overlayViewDidRequestInputMonitoringPermission() {}
    func overlayViewDidChangeSnapMode() {}  // Not applicable in editor mode

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

    func overlayDidRequestPin(_ controller: OverlayWindowController, image: NSImage, annotationData: CaptureAnnotationData?, source: PinSource?) {
        dismissOverlays()
        onCapture?(image)
    }
    func overlayDidRequestOCR(_ controller: OverlayWindowController, result: OCRScanResult, image: NSImage?) {}
    func overlayDidRequestUpload(_ controller: OverlayWindowController, image: NSImage, annotationData: CaptureAnnotationData?) {}
    func overlayDidRequestStartRecording(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {}
    func overlayDidRequestStopRecording(_ controller: OverlayWindowController) {}
    func overlayDidRequestScrollCapture(_ controller: OverlayWindowController, rect: NSRect, screen: NSScreen) {}
    func overlayDidRequestStopScrollCapture(_ controller: OverlayWindowController) {}
    func overlayDidRequestCancelScrollCapture(_ controller: OverlayWindowController) {}
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
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
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

    func overlayDidChangeSnapMode(_ controller: OverlayWindowController) {
        // Notify all other overlays to redraw (for multi-monitor setups during "Add Capture" in editor)
        for other in overlayControllers where other !== controller {
            other.refreshSnapMode()
        }
    }
}
