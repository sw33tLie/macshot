import Cocoa
import UniformTypeIdentifiers
import Vision

protocol OverlayWindowControllerDelegate: AnyObject {
    func overlayDidCancel(_ controller: OverlayWindowController)
    func overlayDidConfirm(_ controller: OverlayWindowController, capturedImage: NSImage?)
    func overlayDidRequestPin(_ controller: OverlayWindowController, image: NSImage)
    func overlayDidRequestOCR(_ controller: OverlayWindowController, text: String)
}

/// Manages one fullscreen overlay per screen.
/// Does NOT subclass NSWindowController to avoid AppKit retain-cycle issues.
class OverlayWindowController {

    weak var overlayDelegate: OverlayWindowControllerDelegate?

    private var overlayView: OverlayView?
    private var overlayWindow: OverlayWindow?

    init(capture: ScreenCapture) {
        let screen = capture.screen

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
    }

    func showOverlay() {
        guard let window = overlayWindow else { return }
        window.makeKeyAndOrderFront(nil)
        if let view = overlayView {
            window.makeFirstResponder(view)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        overlayView?.reset()
        overlayView?.screenshotImage = nil
        overlayView?.overlayDelegate = nil
        overlayWindow?.contentView = nil
        overlayView = nil
        overlayWindow?.orderOut(nil)
        overlayWindow?.close()
        overlayWindow = nil
    }

    private func playCopySound() {
        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        guard soundEnabled else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if let sound = NSSound(contentsOfFile: path, byReference: true) {
            sound.play()
        } else {
            NSSound(named: "Tink")?.play()
        }
    }

    private func applyBeautifyIfNeeded(_ image: NSImage?) -> NSImage? {
        guard let image = image, let view = overlayView, view.beautifyEnabled else { return image }
        return BeautifyRenderer.render(image: image, styleIndex: view.beautifyStyleIndex)
    }

    private func copyImageToClipboard(_ image: NSImage) {
        guard let tiffData = image.tiffRepresentation else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(tiffData, forType: .tiff)
        if let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            pasteboard.setData(pngData, forType: .png)
        }
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
            DispatchQueue.main.async {
                self.playCopySound()
                self.dismiss()
                self.overlayDelegate?.overlayDidRequestOCR(self, text: text)
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }

    func overlayViewDidRequestSave() {
        guard var image = overlayView?.captureSelectedRegion() else { return }
        image = applyBeautifyIfNeeded(image) ?? image
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType.png]
        savePanel.nameFieldStringValue = "macshot_\(Self.formattedTimestamp()).png"
        savePanel.level = .statusBar + 3

        if let savedPath = UserDefaults.standard.string(forKey: "saveDirectory") {
            savePanel.directoryURL = URL(fileURLWithPath: savedPath)
        } else {
            savePanel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }

        savePanel.begin { [weak self] response in
            guard let self = self else { return }
            if response == .OK, let url = savePanel.url {
                try? pngData.write(to: url)
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
