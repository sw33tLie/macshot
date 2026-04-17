import Cocoa
import UniformTypeIdentifiers

@MainActor
protocol PinWindowControllerDelegate: AnyObject {
    func pinWindowDidClose(_ controller: PinWindowController)
}

@MainActor
class PinWindowController {

    weak var delegate: PinWindowControllerDelegate?

    private var window: NSPanel?
    private var pinView: PinView?
    private let image: NSImage
    private let initialWindowSize: NSSize
    private static let minScale: CGFloat = 0.1
    private static let maxScale: CGFloat = 5.0

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
        self.initialWindowSize = windowSize

        let origin = NSPoint(
            x: screenFrame.midX - windowSize.width / 2,
            y: screenFrame.midY - windowSize.height / 2
        )

        let panel = PinPanel(
            contentRect: NSRect(origin: origin, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentAspectRatio = size
        // Allow scroll/magnify events to reach the view even when panel is not key
        panel.becomesKeyOnlyIfNeeded = true

        let view = PinView(image: image)
        view.frame = NSRect(origin: .zero, size: windowSize)
        view.autoresizingMask = [.width, .height]
        view.onClose = { [weak self] in
            self?.close()
        }
        view.onEdit = { [weak self] in
            self?.openInEditor()
        }
        view.onZoom = { [weak self] factor, viewPoint in
            self?.zoom(by: factor, around: viewPoint)
        }
        view.onResetZoom = { [weak self] in
            self?.resetZoom()
        }

        panel.contentView = view
        self.window = panel
        self.pinView = view
    }

    private func zoom(by factor: CGFloat, around viewPoint: NSPoint) {
        guard let window = window else { return }
        let oldFrame = window.frame
        let oldSize = oldFrame.size

        // Compute new size, clamped
        let currentScale = oldSize.width / initialWindowSize.width
        let newScale = min(Self.maxScale, max(Self.minScale, currentScale * factor))
        if abs(newScale - currentScale) < 0.001 { return }

        let newSize = NSSize(
            width: round(initialWindowSize.width * newScale),
            height: round(initialWindowSize.height * newScale)
        )

        // Anchor: the screen point under the cursor stays fixed
        let cursorScreenPoint = NSPoint(
            x: oldFrame.origin.x + viewPoint.x,
            y: oldFrame.origin.y + viewPoint.y
        )
        let fractionX = viewPoint.x / oldSize.width
        let fractionY = viewPoint.y / oldSize.height
        let newOrigin = NSPoint(
            x: cursorScreenPoint.x - fractionX * newSize.width,
            y: cursorScreenPoint.y - fractionY * newSize.height
        )

        window.setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
        pinView?.zoomPercent = Int(round(newScale * 100))
    }

    private func resetZoom() {
        guard let window = window else { return }
        let oldFrame = window.frame
        let centerX = oldFrame.midX
        let centerY = oldFrame.midY
        let newOrigin = NSPoint(
            x: centerX - initialWindowSize.width / 2,
            y: centerY - initialWindowSize.height / 2
        )
        window.setFrame(NSRect(origin: newOrigin, size: initialWindowSize), display: true)
        pinView?.zoomPercent = 100
    }

    func show() {
        window?.orderFrontRegardless()
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

// MARK: - Pin Panel (receives gesture events without activating the app)

private class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    // Don't let Cmd+Q propagate to the app — just close the pin
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.keyCode == 12 {  // Q
            (contentView as? PinView)?.onClose?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Pin Content View

private class PinView: NSView {

    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?
    var onZoom: ((CGFloat, NSPoint) -> Void)?
    var onResetZoom: (() -> Void)?

    private let image: NSImage
    private var closeButton: NSButton?
    private var editButton: NSButton?
    private var zoomLabel: NSTextField?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    var zoomPercent: Int = 100 {
        didSet {
            zoomLabel?.stringValue = "\(zoomPercent)%"
            zoomLabel?.sizeToFit()
            needsLayout = true
        }
    }

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

        let label = VerticallyCenteredTextField(labelWithString: "100%")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 12
        label.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        label.alignment = .center
        label.isHidden = true
        addSubview(label)
        zoomLabel = label
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
        isHovering = true
        editButton?.isHidden = false
        closeButton?.isHidden = false
        zoomLabel?.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        editButton?.isHidden = true
        closeButton?.isHidden = true
        zoomLabel?.isHidden = true
    }

    override func layout() {
        super.layout()
        // Close button top-right, edit button to its left, zoom label to its left
        let btnSize: CGFloat = 24
        let btnY = bounds.maxY - 30
        let btnCenterY = btnY + btnSize / 2
        closeButton?.frame = NSRect(x: bounds.maxX - 30, y: btnY, width: btnSize, height: btnSize)
        editButton?.frame  = NSRect(x: bounds.maxX - 58, y: btnY, width: btnSize, height: btnSize)
        if let label = zoomLabel {
            let labelW = max(label.intrinsicContentSize.width + 14, 42)
            label.frame = NSRect(
                x: bounds.maxX - 58 - labelW - 6,
                y: btnY,
                width: labelW,
                height: btnSize
            )
        }
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
        savePanel.nameFieldStringValue = FilenameFormatter.defaultImageFilename()

        savePanel.directoryURL = SaveDirectoryAccess.directoryHint()

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                try? imageData.write(to: url)
                SaveDirectoryAccess.save(url: url.deletingLastPathComponent())
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if let label = zoomLabel, !label.isHidden, label.frame.contains(loc) {
            onResetZoom?()
            return
        }
        super.mouseDown(with: event)
    }

    // Scroll to zoom (mouse wheel and trackpad two-finger scroll)
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        // Trackpad sends fine-grained deltas; mouse wheel sends larger discrete steps
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.005 : 0.03
        let factor: CGFloat = 1.0 + delta * sensitivity
        let loc = convert(event.locationInWindow, from: nil)
        onZoom?(factor, loc)
    }

    // Pinch to zoom
    override func magnify(with event: NSEvent) {
        let factor = 1.0 + event.magnification
        let loc = convert(event.locationInWindow, from: nil)
        onZoom?(factor, loc)
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

// MARK: - Vertically centered NSTextField

private class VerticallyCenteredCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let textSize = cellSize(forBounds: rect)
        let y = max(0, (rect.height - textSize.height) / 2)
        return NSRect(x: rect.origin.x, y: rect.origin.y + y, width: rect.width, height: textSize.height)
    }
}

private class VerticallyCenteredTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { VerticallyCenteredCell.self }
        set {}
    }
}
