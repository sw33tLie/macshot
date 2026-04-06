import Cocoa

/// Real NSView top bar for the editor window. Pinned to top of container.
/// Contains: pixel dimensions, crop/flip/add-capture buttons, zoom dropdown.
class EditorTopBarView: NSView {

    weak var overlayView: OverlayView?
    private var sizeLabel: NSTextField!
    private var zoomButton: NSButton!
    private var doneButton: NSButton?
    var onDone: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1.0).cgColor
        autoresizingMask = [.width, .minYMargin]  // pin to top, stretch width

        sizeLabel = makeLabel("")
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = NSColor.white.withAlphaComponent(0.45)

        let cropBtn = makeButton("crop", tooltip: L("Crop"), action: #selector(cropClicked))
        let flipHBtn = makeButton("arrow.left.and.right.righttriangle.left.righttriangle.right", tooltip: L("Flip Horizontal"), action: #selector(flipHClicked))
        let flipVBtn = makeButton("arrow.up.and.down.righttriangle.up.righttriangle.down", tooltip: L("Flip Vertical"), action: #selector(flipVClicked))
        let addCaptureBtn = makeButton("rectangle.badge.plus", tooltip: L("Add Capture"), action: #selector(addCaptureClicked))

        // Zoom dropdown button
        zoomButton = NSButton()
        zoomButton.bezelStyle = .recessed
        zoomButton.isBordered = false
        zoomButton.title = "100% ▾"
        zoomButton.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomButton.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        zoomButton.target = self
        zoomButton.action = #selector(zoomButtonClicked)

        // Bottom border
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1.0).cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        // Layout with constraints
        for v: NSView in [sizeLabel, cropBtn, flipHBtn, flipVBtn, addCaptureBtn, zoomButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),

            sizeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            cropBtn.leadingAnchor.constraint(equalTo: sizeLabel.trailingAnchor, constant: 16),
            cropBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            cropBtn.widthAnchor.constraint(equalToConstant: 24),
            cropBtn.heightAnchor.constraint(equalToConstant: 22),

            flipHBtn.leadingAnchor.constraint(equalTo: cropBtn.trailingAnchor, constant: 4),
            flipHBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            flipHBtn.widthAnchor.constraint(equalToConstant: 24),
            flipHBtn.heightAnchor.constraint(equalToConstant: 22),

            flipVBtn.leadingAnchor.constraint(equalTo: flipHBtn.trailingAnchor, constant: 4),
            flipVBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            flipVBtn.widthAnchor.constraint(equalToConstant: 24),
            flipVBtn.heightAnchor.constraint(equalToConstant: 22),

            addCaptureBtn.leadingAnchor.constraint(equalTo: flipVBtn.trailingAnchor, constant: 12),
            addCaptureBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            addCaptureBtn.widthAnchor.constraint(equalToConstant: 24),
            addCaptureBtn.heightAnchor.constraint(equalToConstant: 22),

            zoomButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            zoomButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeButton(_ symbol: String, tooltip: String, action: Selector) -> NSButton {
        let btn = NSButton()
        btn.bezelStyle = .recessed
        btn.isBordered = false
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        btn.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        btn.toolTip = tooltip
        btn.target = self
        btn.action = action
        return btn
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.isEditable = false
        label.isBezeled = false
        label.drawsBackground = false
        return label
    }

    func updateSizeLabel(width: Int, height: Int) {
        sizeLabel.stringValue = "\(width) × \(height)"
    }

    func updateZoom(_ magnification: CGFloat) {
        zoomButton.title = "\(Int(magnification * 100))% ▾"
    }

    // MARK: - Zoom dropdown

    @objc private func zoomButtonClicked() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let zoomIn = NSMenuItem(title: L("Zoom In"), action: #selector(zoomInAction), keyEquivalent: "+")
        zoomIn.keyEquivalentModifierMask = .command
        zoomIn.target = self
        menu.addItem(zoomIn)

        let zoomOut = NSMenuItem(title: L("Zoom Out"), action: #selector(zoomOutAction), keyEquivalent: "-")
        zoomOut.keyEquivalentModifierMask = .command
        zoomOut.target = self
        menu.addItem(zoomOut)

        menu.addItem(.separator())

        let fitCanvas = NSMenuItem(title: L("Fit Canvas"), action: #selector(fitCanvasAction), keyEquivalent: "1")
        fitCanvas.keyEquivalentModifierMask = .command
        fitCanvas.target = self
        menu.addItem(fitCanvas)

        menu.addItem(.separator())

        let presets: [(String, CGFloat, String)] = [
            ("50%", 0.5, ""),
            ("100%", 1.0, "0"),
            ("200%", 2.0, ""),
        ]
        let currentMag = overlayView?.enclosingScrollView?.magnification ?? 1.0
        for (title, mag, key) in presets {
            let item = NSMenuItem(title: title, action: #selector(zoomPresetAction(_:)), keyEquivalent: key)
            if !key.isEmpty { item.keyEquivalentModifierMask = .command }
            item.target = self
            item.tag = Int(mag * 100)
            if abs(currentMag - mag) < 0.01 { item.state = .on }
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: zoomButton.bounds.height + 2), in: zoomButton)
    }

    @objc private func zoomInAction() {
        guard let sv = overlayView?.enclosingScrollView, let doc = sv.documentView else { return }
        let newMag = min(sv.maxMagnification, sv.magnification * 1.25)
        sv.setMagnification(newMag, centeredAt: NSPoint(x: doc.bounds.midX, y: doc.bounds.midY))
        updateZoom(newMag)
    }

    @objc private func zoomOutAction() {
        guard let sv = overlayView?.enclosingScrollView, let doc = sv.documentView else { return }
        let newMag = max(sv.minMagnification, sv.magnification / 1.25)
        sv.setMagnification(newMag, centeredAt: NSPoint(x: doc.bounds.midX, y: doc.bounds.midY))
        updateZoom(newMag)
    }

    @objc private func fitCanvasAction() {
        guard let sv = overlayView?.enclosingScrollView, let doc = sv.documentView else { return }
        let docUnscaledW = doc.frame.width / sv.magnification
        let docUnscaledH = doc.frame.height / sv.magnification
        guard docUnscaledW > 0, docUnscaledH > 0 else { return }
        let clipSize = sv.contentView.bounds.size
        let fitMag = min(clipSize.width / docUnscaledW, clipSize.height / docUnscaledH)
        let clamped = max(sv.minMagnification, min(sv.maxMagnification, fitMag))
        sv.magnification = clamped
        updateZoom(clamped)
    }

    @objc private func zoomPresetAction(_ sender: NSMenuItem) {
        let mag = CGFloat(sender.tag) / 100.0
        guard let sv = overlayView?.enclosingScrollView else { return }
        sv.magnification = mag
        updateZoom(mag)
    }

    // MARK: - Top bar actions

    /// Show a "Done" button for committing edits back to history.
    func showDoneButton() {
        let btn = NSButton()
        btn.bezelStyle = .recessed
        btn.isBordered = true
        btn.title = L("Done")
        btn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        btn.contentTintColor = ToolbarLayout.accentColor
        btn.target = self
        btn.action = #selector(doneClicked)
        btn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(btn)
        NSLayoutConstraint.activate([
            btn.trailingAnchor.constraint(equalTo: zoomButton.leadingAnchor, constant: -12),
            btn.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        doneButton = btn
    }

    @objc private func doneClicked() { onDone?() }

    @objc private func cropClicked() {
        guard let ov = overlayView else { return }
        ov.currentTool = ov.currentTool == .crop ? .arrow : .crop
        ov.rebuildToolbarLayout()
        ov.needsDisplay = true
    }

    @objc private func flipHClicked() { overlayView?.flipImageHorizontally() }
    @objc private func flipVClicked() { overlayView?.flipImageVertically() }
    @objc private func addCaptureClicked() { overlayView?.overlayDelegate?.overlayViewDidRequestAddCapture() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}
