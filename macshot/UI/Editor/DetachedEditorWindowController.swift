import Cocoa
import Vision
import CoreImage

/// Editor window that intercepts Cmd+Q to close itself instead of quitting the app.
private class EditorWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q" {
            close()
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
    private var addCaptureHandler: AddCaptureOverlayHandler?
    private static var activeControllers: [DetachedEditorWindowController] = []

    /// Open an editor window with the given image (typically from captureSelectedRegion).
    static func open(image: NSImage, tool: AnnotationTool = .arrow, color: NSColor = .systemRed, strokeWidth: CGFloat = 3, annotations: [Annotation] = []) {
        let controller = DetachedEditorWindowController()
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
        let winW = min(maxW, max(minW, imgSize.width + 100))
        let winH = min(maxH, max(minH, imgSize.height + 100))

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

        // NSScrollView for native zoom/pan/centering
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: NSSize(width: winW, height: winH)))
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
        // top=32 (top bar), bottom=80 (bottom toolbar + options row), right=46 (right toolbar)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 36, left: 0, bottom: 84, right: 50)
        // Extend scrollbar tracks to window edges (negate content insets effect on scrollers)
        scrollView.scrollerInsets = NSEdgeInsets(top: -36, left: 0, bottom: -84, right: -50)

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

        win.contentView = container
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
        self.overlayView = view
    }

    // MARK: - NSWindowDelegate

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
    func overlayViewDidCancel() { window?.close() }

    func overlayViewDidConfirm() {
        guard let raw = overlayView?.captureSelectedRegion() else { return }
        let image = applyPostProcessing(raw)
        ImageEncoder.copyToClipboard(image)
        playCopySound()
        (NSApp.delegate as? AppDelegate)?.showFloatingThumbnail(image: image)
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
        savePanel.beginSheetModal(for: window!) { response in
            if response == .OK, let url = savePanel.url {
                try? imageData.write(to: url)
                SaveDirectoryAccess.save(url: url.deletingLastPathComponent())
                self.playCopySound()
            }
        }
    }

    func overlayViewDidRequestPin() {
        guard let raw = overlayView?.captureSelectedRegion() else { return }
        let image = applyPostProcessing(raw)
        playCopySound()
        (NSApp.delegate as? AppDelegate)?.showPin(image: image)
    }

    func overlayViewDidRequestOCR() {
        guard let image = overlayView?.captureSelectedRegion(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let request = VisionOCR.makeTextRecognitionRequest { [weak self] req, _ in
            let lines = (req.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
            DispatchQueue.main.async {
                guard self != nil else { return }
                OCRResultController(text: lines.joined(separator: "\n"), image: image).show()
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
        playCopySound()

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
    func overlayViewDidRequestFileSave() {
        overlayViewDidRequestQuickSave()
    }
    func overlayViewDidRequestUpload() {
        guard let raw = overlayView?.captureSelectedRegion() else { return }
        let image = applyPostProcessing(raw)
        playCopySound()
        (NSApp.delegate as? AppDelegate)?.uploadImage(image)
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

    func overlayDidConfirm(_ controller: OverlayWindowController, capturedImage: NSImage?) {
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
