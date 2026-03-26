import Cocoa
import Vision
import CoreImage

/// Hosts a captured screenshot in a standalone editor window.
/// The image (with any overlay annotations baked in) is displayed in a fresh OverlayView
/// that fills the entire window. selectionRect == bounds == image size, so all coordinate
/// systems align trivially. No translation math needed.
@MainActor
class DetachedEditorWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var overlayView: OverlayView?
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

        // Toolbar padding: must match the values in EditorView's draw block
        let padH: CGFloat = 8 + 52   // left + right toolbar
        let padV: CGFloat = 56 + 36 + 36  // bottom toolbar + gap + options row (34+2 gap) + top bar (32+4)
        // Extra space for beautify preview — use max possible values so it always fits
        let beautifyExtra: CGFloat = (96 + 40 + 16) * 2  // max padding (96) + max shadow (40) + offset, both sides
        let minW: CGFloat = 800  // enough width for all bottom toolbar buttons
        let minH: CGFloat = 400  // enough height for right toolbar buttons

        // Size window to fit image + padding + beautify space, capped to 80% of screen
        let maxW = screenFrame.width * 0.8
        let maxH = screenFrame.height * 0.8
        let winW = min(maxW, max(minW, imgSize.width + padH + beautifyExtra))
        let winH = min(maxH, max(minH, imgSize.height + padV + beautifyExtra))

        let win = NSWindow(
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

        // Create an EditorView (subclass of OverlayView) for the standalone editor.
        let view = EditorView()
        view.frame = NSRect(origin: .zero, size: imgSize)
        view.autoresizingMask = [.width, .height]
        view.screenshotImage = image
        view.overlayDelegate = self
        view.currentTool = tool
        view.currentColor = color
        view.currentStrokeWidth = strokeWidth

        // Force the view into selected state with selection covering the full image.
        view.applySelection(NSRect(origin: .zero, size: imgSize))

        // Add transferred annotations (already shifted to image-relative coords).
        if !annotations.isEmpty {
            view.setAnnotations(annotations)
        }

        win.contentView = view
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
}

// MARK: - OverlayViewDelegate

extension DetachedEditorWindowController: OverlayViewDelegate {
    func overlayViewDidFinishSelection(_ rect: NSRect) {}
    func overlayViewSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidCancel() { window?.close() }

    func overlayViewDidConfirm() {
        guard var image = overlayView?.captureSelectedRegion() else { return }
        if overlayView?.beautifyEnabled == true {
            image = BeautifyRenderer.render(image: image, config: overlayView?.beautifyConfig ?? BeautifyConfig()) ?? image
        }
        let autoCopy = UserDefaults.standard.object(forKey: "autoCopyToClipboard") as? Bool ?? true
        if autoCopy { ImageEncoder.copyToClipboard(image) }
        playCopySound()
        (NSApp.delegate as? AppDelegate)?.showFloatingThumbnail(image: image)
    }

    func overlayViewDidRequestSave() {
        guard let view = overlayView,
              var image = view.captureSelectedRegion() else { return }
        if view.beautifyEnabled {
            image = BeautifyRenderer.render(image: image, config: view.beautifyConfig)
        }
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
        guard var image = overlayView?.captureSelectedRegion() else { return }
        if overlayView?.beautifyEnabled == true {
            image = BeautifyRenderer.render(image: image, config: overlayView?.beautifyConfig ?? BeautifyConfig()) ?? image
        }
        playCopySound()
        (NSApp.delegate as? AppDelegate)?.showPin(image: image)
    }

    func overlayViewDidRequestOCR() {
        guard let image = overlayView?.captureSelectedRegion(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let request = VNRecognizeTextRequest { [weak self] req, _ in
            let lines = (req.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
            DispatchQueue.main.async {
                guard self != nil else { return }
                OCRResultController(text: lines.joined(separator: "\n"), image: image).show()
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }
    }

    func overlayViewDidRequestQuickSave() {
        guard let view = overlayView,
              var image = view.captureSelectedRegion() else { return }
        if view.beautifyEnabled {
            image = BeautifyRenderer.render(image: image, config: view.beautifyConfig)
        }
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
    func overlayViewDidRequestUpload() {
        guard var image = overlayView?.captureSelectedRegion() else { return }
        if overlayView?.beautifyEnabled == true {
            image = BeautifyRenderer.render(image: image, config: overlayView?.beautifyConfig ?? BeautifyConfig()) ?? image
        }
        playCopySound()
        (NSApp.delegate as? AppDelegate)?.uploadImage(image)
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

    private func playCopySound() {
        let enabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        guard enabled else { return }
        AppDelegate.captureSound?.stop()
        AppDelegate.captureSound?.play()
    }
}
