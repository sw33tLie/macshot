import Cocoa
import UniformTypeIdentifiers

protocol OverlayWindowControllerDelegate: AnyObject {
    func overlayDidCancel(_ controller: OverlayWindowController)
    func overlayDidConfirm(_ controller: OverlayWindowController)
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
        window.isReleasedWhenClosed = false  // ARC manages lifetime

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
        // 1. Tear down view contents (annotations, subviews, images)
        overlayView?.reset()
        overlayView?.screenshotImage = nil
        overlayView?.overlayDelegate = nil

        // 2. Detach view from window
        overlayWindow?.contentView = nil
        overlayView = nil

        // 3. Close and release the window (frees backing store)
        overlayWindow?.orderOut(nil)
        overlayWindow?.close()
        overlayWindow = nil
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
        if autoCopy {
            overlayView?.copyToClipboard()
        }
        dismiss()
        overlayDelegate?.overlayDidConfirm(self)
    }

    func overlayViewDidRequestSave() {
        guard let image = overlayView?.captureSelectedRegion() else { return }
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
                self.dismiss()
                self.overlayDelegate?.overlayDidConfirm(self)
            } else {
                // User cancelled save — restore overlay focus
                self.overlayWindow?.makeKeyAndOrderFront(nil)
                if let view = self.overlayView {
                    self.overlayWindow?.makeFirstResponder(view)
                }
            }
        }
    }

    private static func formattedTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
}

// MARK: - Custom Window subclass

class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
