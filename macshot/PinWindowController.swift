import Cocoa
import UniformTypeIdentifiers

protocol PinWindowControllerDelegate: AnyObject {
    func pinWindowDidClose(_ controller: PinWindowController)
}

class PinWindowController {

    weak var delegate: PinWindowControllerDelegate?

    private var window: NSPanel?
    private var pinView: PinView?
    private let image: NSImage

    init(image: NSImage) {
        self.image = image

        let size = image.size
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame

        // Center on screen, cap at 80% of screen size
        let maxW = screenFrame.width * 0.8
        let maxH = screenFrame.height * 0.8
        let scale = min(1.0, min(maxW / size.width, maxH / size.height))
        let windowSize = NSSize(width: size.width * scale, height: size.height * scale)

        let origin = NSPoint(
            x: screenFrame.midX - windowSize.width / 2,
            y: screenFrame.midY - windowSize.height / 2
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = size

        let view = PinView(image: image)
        view.frame = NSRect(origin: .zero, size: windowSize)
        view.autoresizingMask = [.width, .height]
        view.onClose = { [weak self] in
            self?.close()
        }
        view.onEdit = { [weak self] in
            self?.openInEditor()
        }

        panel.contentView = view
        self.window = panel
        self.pinView = view
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        pinView = nil
        delegate?.pinWindowDidClose(self)
    }

    private func openInEditor() {
        DetachedEditorWindowController.open(image: image)
        close()
    }
}

// MARK: - Pin Content View

private class PinView: NSView {

    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?

    private let image: NSImage
    private var closeButton: NSButton?
    private var editButton: NSButton?
    private var trackingArea: NSTrackingArea?

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        setupButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeOverlayButton(symbol: String, action: Selector) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        btn.bezelStyle = .circular
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 12
        btn.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        btn.image = img
        btn.contentTintColor = .white
        btn.target = self
        btn.action = action
        btn.isHidden = true
        return btn
    }

    private func setupButtons() {
        let edit = makeOverlayButton(symbol: "pencil", action: #selector(editClicked))
        addSubview(edit)
        editButton = edit

        let close = makeOverlayButton(symbol: "xmark", action: #selector(closeClicked))
        addSubview(close)
        closeButton = close
    }

    @objc private func closeClicked() {
        onClose?()
    }

    @objc private func editClicked() {
        onEdit?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        editButton?.isHidden = false
        closeButton?.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        editButton?.isHidden = true
        closeButton?.isHidden = true
    }

    override func layout() {
        super.layout()
        // Close button top-right, edit button to its left
        closeButton?.frame = NSRect(x: bounds.maxX - 30, y: bounds.maxY - 30, width: 24, height: 24)
        editButton?.frame  = NSRect(x: bounds.maxX - 58, y: bounds.maxY - 30, width: 24, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        path.addClip()
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)

        // Subtle border
        NSColor.white.withAlphaComponent(0.3).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        border.lineWidth = 1
        border.stroke()
    }

    // Right-click context menu
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy to Clipboard", action: #selector(copyImage), keyEquivalent: "c")
        menu.addItem(withTitle: "Save As...", action: #selector(saveImage), keyEquivalent: "s")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Close", action: #selector(closeClicked), keyEquivalent: "")
        for item in menu.items {
            item.target = self
        }
        return menu
    }

    @objc private func copyImage() {
        ImageEncoder.copyToClipboard(image)
    }

    @objc private func saveImage() {
        guard let imageData = ImageEncoder.encode(image) else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [ImageEncoder.utType]
        savePanel.nameFieldStringValue = "macshot_\(OverlayWindowController.formattedTimestamp()).\(ImageEncoder.fileExtension)"

        if let savedPath = UserDefaults.standard.string(forKey: "saveDirectory") {
            savePanel.directoryURL = URL(fileURLWithPath: savedPath)
        } else {
            savePanel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        }

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                try? imageData.write(to: url)
                UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: "saveDirectory")
            }
        }
    }

    // Keyboard: Escape to close
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onClose?()
        } else {
            super.keyDown(with: event)
        }
    }
}
