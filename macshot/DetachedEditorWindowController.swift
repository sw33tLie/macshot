import Cocoa
import Vision
import CoreImage

/// A persistent editor window that lives independently of the fullscreen overlay.
/// Created when the user clicks "Open in Editor Window" in the right toolbar.
class DetachedEditorWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var overlayView: OverlayView?

    // Keep a global list so windows aren't released while open.
    private static var activeControllers: [DetachedEditorWindowController] = []

    static func open(with state: OverlayEditorState, offset: NSPoint) {
        let controller = DetachedEditorWindowController()
        controller.show(state: state, offset: offset)
        activeControllers.append(controller)
        if activeControllers.count == 1 {
            NSApp.setActivationPolicy(.regular)
        }
    }

    private func show(state: OverlayEditorState, offset: NSPoint) {
        let sz = state.selectionRect.size
        let contentSize = (sz.width < 1 || sz.height < 1) ? NSSize(width: 600, height: 400) : sz

        // Min image area size
        let minImgW: CGFloat = 300
        let minImgH: CGFloat = 220
        let imgW = max(contentSize.width, minImgW)
        let imgH = max(contentSize.height, minImgH)

        // Extra strips: right toolbar, bottom toolbar, left/top padding (symmetric margins)
        let rightPad: CGFloat  = 52
        let bottomPad: CGFloat = 52
        let leftPad: CGFloat   = 52
        let topPad: CGFloat    = 36

        let winW = imgW + leftPad + rightPad
        let winH = imgH + bottomPad + topPad

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame
        let winX = screenFrame.midX - winW / 2
        let winY = screenFrame.midY - winH / 2

        let win = NSWindow(
            contentRect: NSRect(x: winX, y: winY, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "macshot Editor"
        win.minSize = NSSize(width: minImgW + leftPad + rightPad, height: minImgH + bottomPad + topPad)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.fullScreenAuxiliary]

        let view = OverlayView()
        view.frame = NSRect(origin: .zero, size: NSSize(width: winW, height: winH))
        view.autoresizingMask = [.width, .height]
        view.isDetached = true
        view.detachedRightPad = rightPad
        view.detachedBottomPad = bottomPad
        view.detachedLeftPad = leftPad
        view.detachedTopPad = topPad
        view.overlayDelegate = self

        // Apply state — translate annotations so they're in the view's coordinate space
        view.applyEditorState(state, translatingBy: offset)

        // Prime the selection rect so applyEditorState's annotation coordinates are valid.
        // The draw loop will recompute this on every frame to handle resize.
        let imageRect = NSRect(x: leftPad, y: bottomPad, width: imgW, height: imgH)
        view.applySelection(imageRect)

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
        window = nil
        Self.activeControllers.removeAll { $0 === self }
        if Self.activeControllers.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - OverlayViewDelegate

extension DetachedEditorWindowController: OverlayViewDelegate {
    func overlayViewDidFinishSelection(_ rect: NSRect) {}
    func overlayViewSelectionDidChange(_ rect: NSRect) {}

    func overlayViewDidCancel() {
        window?.close()
    }

    func overlayViewDidConfirm() {
        guard let image = overlayView?.captureSelectedRegion() else { return }
        let autoCopy = UserDefaults.standard.object(forKey: "autoCopyToClipboard") as? Bool ?? true
        if autoCopy { ImageEncoder.copyToClipboard(image) }
        playCopySound()
    }

    func overlayViewDidRequestSave() {
        guard let view = overlayView,
              var image = view.captureSelectedRegion() else { return }
        if view.beautifyEnabled {
            image = BeautifyRenderer.render(image: image, styleIndex: view.beautifyStyleIndex) ?? image
        }
        guard let imageData = ImageEncoder.encode(image) else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [ImageEncoder.utType]
        savePanel.nameFieldStringValue = "macshot_\(OverlayWindowController.formattedTimestamp()).\(ImageEncoder.fileExtension)"
        if let savedPath = UserDefaults.standard.string(forKey: "saveDirectory") {
            savePanel.directoryURL = URL(fileURLWithPath: savedPath)
        } else {
            savePanel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        }
        savePanel.beginSheetModal(for: window!) { response in
            if response == .OK, let url = savePanel.url {
                try? imageData.write(to: url)
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "saveDirectory")
                self.playCopySound()
            }
        }
    }

    func overlayViewDidRequestPin() {
        guard var image = overlayView?.captureSelectedRegion() else { return }
        if overlayView?.beautifyEnabled == true {
            image = BeautifyRenderer.render(image: image, styleIndex: overlayView?.beautifyStyleIndex ?? 0) ?? image
        }
        playCopySound()
        // Hand ownership to AppDelegate so the pin survives this window closing.
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.showPin(image: image)
        } else {
            let pinController = PinWindowController(image: image)
            pinController.show()
        }
        window?.close()
    }

    func overlayViewDidRequestOCR() {
        guard let image = overlayView?.captureSelectedRegion(),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let request = VNRecognizeTextRequest { [weak self] req, _ in
            let lines = (req.results as? [VNRecognizedTextObservation])?.compactMap { $0.topCandidates(1).first?.string } ?? []
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async {
                guard self != nil else { return }
                let vc = OCRResultController(text: text, image: image)
                vc.show()
            }
        }
        request.recognitionLevel = VNRequestTextRecognitionLevel.accurate
        request.usesLanguageCorrection = true
        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }
    }

    func overlayViewDidRequestQuickSave() {
        overlayViewDidConfirm()
    }

    func overlayViewDidRequestDelayCapture(seconds: Int, selectionRect: NSRect) {
        // Delay capture doesn't apply in detached mode — ignore
    }

    func overlayViewDidRequestUpload() {
        guard var image = overlayView?.captureSelectedRegion() else { return }
        if overlayView?.beautifyEnabled == true {
            image = BeautifyRenderer.render(image: image, styleIndex: overlayView?.beautifyStyleIndex ?? 0) ?? image
        }
        playCopySound()
        // Delegate upload to AppDelegate
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.uploadImage(image)
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
                let maskPixelBuffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
                let orig = CIImage(cgImage: cgImage)
                let mask = CIImage(cvPixelBuffer: maskPixelBuffer)
                guard let filter = CIFilter(name: "CIBlendWithMask") else { return }
                filter.setValue(orig, forKey: kCIInputImageKey)
                filter.setValue(mask, forKey: kCIInputMaskImageKey)
                filter.setValue(CIImage(color: .clear).cropped(to: orig.extent), forKey: kCIInputBackgroundImageKey)
                guard let out = filter.outputImage,
                      let final = CIContext().createCGImage(out, from: out.extent) else { return }
                let finalImg = NSImage(cgImage: final, size: image.size)
                DispatchQueue.main.async {
                    ImageEncoder.copyToClipboard(finalImg)
                    self.playCopySound()
                }
            } catch {}
        }
    }

    func overlayViewDidRequestStartRecording(rect: NSRect) {
        // Recording from the detached window — not supported in v1 of this feature
        overlayView?.showOverlayError("Recording is only available in the overlay mode.")
    }

    func overlayViewDidRequestStopRecording() {}

    func overlayViewDidRequestDetach() {
        // Already detached — ignore
    }

    func overlayViewDidRequestScrollCapture(rect: NSRect) {
        // Scroll capture is not available in the detached editor
    }

    func overlayViewDidRequestStopScrollCapture() {
        // Not available in the detached editor
    }

    // MARK: - Helpers

    private func playCopySound() {
        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        guard soundEnabled else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        let sound = NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink")
        sound?.stop()
        sound?.play()
    }
}

