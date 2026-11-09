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
        layer?.cornerRadius = ToolbarLayout.cornerRadius
        layer?.backgroundColor = ToolbarLayout.bgColor.cgColor

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
        // Above the overlay window (which sits at NSWindow.Level(257)).
        // Must stay above 257 or the HUD gets hidden behind the overlay.
        level = NSWindow.Level(258)
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        let container = NSView()
        contentView = container
        container.addSubview(hudView)
    }

    // Never become key: clicking the HUD shouldn't steal focus from the app
    // underneath (matches RecordingHUDPanel). Buttons still work via the
    // nonactivating panel + acceptsFirstMouse.
    override var canBecomeKey: Bool { false }

    /// Where the HUD goes for a given selection.
    ///
    /// Below the selection when there's room, above it otherwise — and always
    /// on screen and clear of the camera housing. A full-height selection (the
    /// common case for scroll capture) leaves no room either side, and the
    /// fallback used to put the HUD at the very top of the display, where the
    /// notch swallowed the Auto Scroll and Stop buttons.
    ///
    /// `topInset` is the display's `safeAreaInsets.top`: 0 on a display with no
    /// notch, the height of the camera housing otherwise.
    static func hudFrame(size: NSSize,
                         selectionScreenRect selection: NSRect,
                         screenFrame: NSRect,
                         visibleFrame: NSRect,
                         topInset: CGFloat) -> NSRect {
        let margin: CGFloat = 4
        let gap: CGFloat = 6

        var y = selection.minY - size.height - gap
        if y < visibleFrame.minY + margin {
            y = selection.maxY + gap
        }

        // The highest the HUD may reach: below the notch band when there is
        // one, otherwise just under the menu bar.
        let topLimit = topInset > 0
            ? screenFrame.maxY - topInset - margin
            : visibleFrame.maxY - margin
        y = min(y, topLimit - size.height)
        y = max(y, visibleFrame.minY + margin)

        var x = selection.midX - size.width / 2
        x = max(visibleFrame.minX + margin, min(x, visibleFrame.maxX - size.width - margin))

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func position(relativeTo selectionRect: NSRect, in overlayWindow: NSWindow) {
        hudView.layoutSubviews()
        let hudSize = hudView.frame.size
        let selScreen = overlayWindow.convertToScreen(selectionRect)
        let screen = overlayWindow.screen ?? NSScreen.main

        let frame = Self.hudFrame(
            size: hudSize,
            selectionScreenRect: selScreen,
            screenFrame: screen?.frame ?? selScreen,
            visibleFrame: screen?.visibleFrame ?? selScreen,
            topInset: screen?.safeAreaInsets.top ?? 0)

        setFrame(frame, display: true)

        // Layout inside content view
        hudView.frame.origin = .zero
        contentView?.frame = NSRect(origin: .zero, size: frame.size)
    }
}
