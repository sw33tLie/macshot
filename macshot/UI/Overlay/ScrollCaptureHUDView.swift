import Cocoa

/// Real NSView-based HUD for scroll capture. Hosted in its own NSPanel so it receives
/// mouse events independently of the overlay window (which has ignoresMouseEvents = true).
class ScrollCaptureHUDView: NSView {

    private let infoLabel = NSTextField(labelWithString: "")
    private let autoScrollButton = NSButton()
    private let stopButton = NSButton()
    private var isAutoScrolling = false

    var onStop: (() -> Void)?
    var onToggleAutoScroll: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ToolbarLayout.bgColor.cgColor
        layer?.cornerRadius = ToolbarLayout.cornerRadius

        infoLabel.font = .systemFont(ofSize: 12, weight: .medium)
        infoLabel.textColor = ToolbarLayout.iconColor
        infoLabel.isEditable = false
        infoLabel.isBordered = false
        infoLabel.drawsBackground = false
        infoLabel.lineBreakMode = .byTruncatingTail
        addSubview(infoLabel)

        autoScrollButton.title = L("Auto Scroll")
        autoScrollButton.bezelStyle = .recessed
        autoScrollButton.isBordered = false
        autoScrollButton.wantsLayer = true
        autoScrollButton.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
        autoScrollButton.layer?.cornerRadius = 12
        autoScrollButton.contentTintColor = .white
        autoScrollButton.font = .systemFont(ofSize: 12, weight: .semibold)
        autoScrollButton.target = self
        autoScrollButton.action = #selector(autoScrollClicked)
        addSubview(autoScrollButton)

        stopButton.title = L("Stop")
        stopButton.bezelStyle = .recessed
        stopButton.isBordered = false
        stopButton.wantsLayer = true
        stopButton.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        stopButton.layer?.cornerRadius = 12
        stopButton.contentTintColor = .white
        stopButton.font = .systemFont(ofSize: 12, weight: .semibold)
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        addSubview(stopButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(stripCount: Int, pixelSize: CGSize, backingScale: CGFloat,
                maxScrollHeight: Int = 0, autoScrolling: Bool = false) {
        let pw = Int(pixelSize.width)
        let ph = Int(pixelSize.height)
        let ptW = Int(CGFloat(pw) / backingScale)
        let ptH = Int(CGFloat(ph) / backingScale)

        if ptW > 0 && ptH > 0 {
            infoLabel.stringValue = "\(L("Scroll Capture"))  ·  \(ptW)×\(ptH)"
        } else {
            infoLabel.stringValue = L("Scroll Capture")
        }

        updateAutoScrollState(autoScrolling)
        infoLabel.sizeToFit()
        layoutSubviews()
    }

    private func updateAutoScrollState(_ active: Bool) {
        isAutoScrolling = active
        if active {
            autoScrollButton.title = L("Scrolling...")
            autoScrollButton.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.85).cgColor
        } else {
            autoScrollButton.title = L("Auto Scroll")
            autoScrollButton.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
        }
    }

    func layoutSubviews() {
        let pad: CGFloat = 8
        let stopBtnW: CGFloat = 56
        let autoBtnW: CGFloat = isAutoScrolling ? 90 : 86
        let btnH: CGFloat = 24
        let barH: CGFloat = 36

        let infoW = infoLabel.frame.width
        let totalW = pad + infoW + pad + autoBtnW + pad + stopBtnW + pad

        frame.size = NSSize(width: totalW, height: barH)

        let infoH = infoLabel.frame.height
        let infoY = (barH - infoH) / 2
        infoLabel.frame.origin = NSPoint(x: pad, y: infoY)

        autoScrollButton.frame = NSRect(
            x: pad + infoW + pad, y: (barH - btnH) / 2, width: autoBtnW, height: btnH)
        stopButton.frame = NSRect(
            x: totalW - pad - stopBtnW, y: (barH - btnH) / 2, width: stopBtnW, height: btnH)
    }

    @objc private func autoScrollClicked() {
        onToggleAutoScroll?()
    }

    @objc private func stopClicked() {
        onStop?()
    }

}

/// Floating panel that hosts the scroll capture HUD. Uses its own window so it receives
/// mouse events even when the overlay window has ignoresMouseEvents = true.
class ScrollCaptureHUDPanel: NSPanel {

    let hudView = ScrollCaptureHUDView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 2  // above the overlay window
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        let container = NSView()
        contentView = container
        container.addSubview(hudView)
    }

    func position(relativeTo selectionRect: NSRect, in overlayWindow: NSWindow) {
        hudView.layoutSubviews()
        let hudSize = hudView.frame.size

        let totalH = hudSize.height
        let totalW = hudSize.width

        // Convert selection rect to screen coords
        let selScreen = overlayWindow.convertToScreen(selectionRect)

        // Position below selection
        var barX = selScreen.midX - totalW / 2
        var barY = selScreen.minY - totalH - 6

        // If below screen, put above selection
        if let screen = overlayWindow.screen {
            if barY < screen.visibleFrame.minY + 4 {
                barY = selScreen.maxY + 6
            }
            barX = max(
                screen.visibleFrame.minX + 4, min(barX, screen.visibleFrame.maxX - totalW - 4))
        }

        setFrame(NSRect(x: barX, y: barY, width: totalW, height: totalH), display: true)

        // Layout inside content view
        hudView.frame.origin = NSPoint(x: (totalW - hudSize.width) / 2, y: 0)

        contentView?.frame = NSRect(origin: .zero, size: NSSize(width: totalW, height: totalH))
    }
}
