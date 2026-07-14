import Cocoa

/// Bottom options panel for the currently selected video text segment — a
/// full inspector row with real AppKit controls (font family, size,
/// bold/italic, colors, background style, glyph outline, alignment). It
/// replaces the old custom-drawn mini inspector in the editor's buttons row.
///
/// Pure UI: `configure(with:)` pushes segment state into the controls and
/// every user edit is reported through `onChange` — the panel never reads or
/// mutates the model itself.
final class VideoTextOptionsPanel: NSView {

    /// A single user edit made in the panel.
    enum Change {
        case fontFamily(String)
        case fontSize(CGFloat)
        case bold(Bool)
        case italic(Bool)
        case bgStyle(VideoTextSegment.BackgroundStyle)
        case alignment(VideoTextSegment.Alignment)
        case outlineEnabled(Bool)
        case outlineWidth(CGFloat)
        case pickTextColor
        case pickBgColor
        case pickOutlineColor
    }

    var onChange: ((Change) -> Void)?

    /// Height the editor gives the panel while it's visible.
    static let preferredHeight: CGFloat = 34

    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeSlider = NSSlider()
    private let sizeLabel = NSTextField(labelWithString: "48pt")
    private let boldButton = NSButton()
    private let italicButton = NSButton()
    private let textColorSwatch = NSButton()
    private let bgColorSwatch = NSButton()
    private let bgStyleControl = NSSegmentedControl()
    private let outlineCheckbox = NSButton()
    private let outlineColorSwatch = NSButton()
    private let outlineWidthSlider = NSSlider()
    private let alignmentControl = NSSegmentedControl()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = ToolbarLayout.iconColor.withAlphaComponent(0.06).cgColor
        // Match appearance to the toolbar background brightness so native
        // controls (popup, checkbox, segmented labels) stay readable on the
        // editor chrome.
        appearance = ToolbarLayout.appearance

        buildControls()
        layoutControls()
    }

    required init?(coder: NSCoder) { fatalError() }

    // Consume clicks in the gaps between controls so they don't fall through
    // to the editor view's mouseDown (which clears the segment selection and
    // would immediately hide this panel).
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    // MARK: - Sync from model

    /// Sync every control to the segment's current style. Called when the
    /// selection changes and after external edits (e.g. the color panel).
    func configure(with seg: VideoTextSegment) {
        selectFontFamily(seg.fontFamily)

        sizeSlider.doubleValue = Double(seg.fontSize)
        sizeLabel.stringValue = "\(Int(seg.fontSize.rounded()))pt"

        boldButton.state = seg.bold ? .on : .off
        italicButton.state = seg.italic ? .on : .off

        textColorSwatch.layer?.backgroundColor = nsColor(seg.textColor).cgColor
        bgColorSwatch.layer?.backgroundColor = nsColor(seg.bgColor).cgColor

        switch seg.bgStyle {
        case .none: bgStyleControl.selectedSegment = 0
        case .solid: bgStyleControl.selectedSegment = 1
        case .rounded: bgStyleControl.selectedSegment = 2
        }

        outlineCheckbox.state = seg.outlineEnabled ? .on : .off
        outlineColorSwatch.layer?.backgroundColor = nsColor(seg.outlineColor).cgColor
        outlineColorSwatch.isEnabled = seg.outlineEnabled
        outlineColorSwatch.layer?.opacity = seg.outlineEnabled ? 1.0 : 0.35
        outlineWidthSlider.doubleValue = Double(seg.outlineWidth)
        outlineWidthSlider.isEnabled = seg.outlineEnabled

        switch seg.alignment {
        case .left: alignmentControl.selectedSegment = 0
        case .center: alignmentControl.selectedSegment = 1
        case .right: alignmentControl.selectedSegment = 2
        }
    }

    // MARK: - Control construction

    private func buildControls() {
        // Font family
        fontPopup.controlSize = .small
        fontPopup.font = NSFont.systemFont(ofSize: 10)
        fontPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fontPopup.toolTip = L("Font")
        fontPopup.target = self
        fontPopup.action = #selector(fontFamilyChanged(_:))
        rebuildFontMenu()

        // Size
        sizeSlider.minValue = 12
        sizeSlider.maxValue = 200
        sizeSlider.isContinuous = true
        sizeSlider.controlSize = .small
        sizeSlider.trackFillColor = ToolbarLayout.accentColor
        sizeSlider.toolTip = L("Size")
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged(_:))

        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        sizeLabel.textColor = ToolbarLayout.iconColor.withAlphaComponent(0.7)
        sizeLabel.alignment = .left

        // Bold / italic toggles
        configureToggle(boldButton,
                        title: "B",
                        font: NSFont.systemFont(ofSize: 11, weight: .bold),
                        toolTip: L("Bold"),
                        action: #selector(boldToggled(_:)))
        let italicFont: NSFont = {
            let base = NSFont.systemFont(ofSize: 11, weight: .medium)
            let d = base.fontDescriptor.withSymbolicTraits(.italic)
            return NSFont(descriptor: d, size: 11) ?? base
        }()
        configureToggle(italicButton,
                        title: "I",
                        font: italicFont,
                        toolTip: L("Italic"),
                        action: #selector(italicToggled(_:)))

        // Color swatches
        configureSwatch(textColorSwatch, toolTip: L("Text Color"), action: #selector(textColorClicked))
        configureSwatch(bgColorSwatch, toolTip: L("Background"), action: #selector(bgColorClicked))
        configureSwatch(outlineColorSwatch, toolTip: L("Outline"), action: #selector(outlineColorClicked))

        // Background style
        bgStyleControl.segmentCount = 3
        bgStyleControl.setLabel(L("None"), forSegment: 0)
        bgStyleControl.setLabel(L("Solid"), forSegment: 1)
        bgStyleControl.setLabel(L("Rounded"), forSegment: 2)
        bgStyleControl.trackingMode = .selectOne
        bgStyleControl.controlSize = .small
        bgStyleControl.selectedSegmentBezelColor = ToolbarLayout.accentColor
        bgStyleControl.toolTip = L("Background")
        bgStyleControl.target = self
        bgStyleControl.action = #selector(bgStyleChanged(_:))

        // Outline: checkbox + color swatch + width slider
        outlineCheckbox.setButtonType(.switch)
        outlineCheckbox.title = L("Outline")
        outlineCheckbox.controlSize = .small
        outlineCheckbox.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        outlineCheckbox.target = self
        outlineCheckbox.action = #selector(outlineToggled(_:))

        outlineWidthSlider.minValue = 0.5
        outlineWidthSlider.maxValue = 8
        outlineWidthSlider.isContinuous = true
        outlineWidthSlider.controlSize = .small
        outlineWidthSlider.trackFillColor = ToolbarLayout.accentColor
        outlineWidthSlider.toolTip = L("Outline")
        outlineWidthSlider.target = self
        outlineWidthSlider.action = #selector(outlineWidthChanged(_:))

        // Alignment
        alignmentControl.segmentCount = 3
        let alignSymbols = ["text.alignleft", "text.aligncenter", "text.alignright"]
        for (index, name) in alignSymbols.enumerated() {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
            alignmentControl.setImage(image, forSegment: index)
            alignmentControl.setWidth(28, forSegment: index)
        }
        alignmentControl.trackingMode = .selectOne
        alignmentControl.controlSize = .small
        alignmentControl.selectedSegmentBezelColor = ToolbarLayout.accentColor
        alignmentControl.target = self
        alignmentControl.action = #selector(alignmentChanged(_:))
    }

    private func configureToggle(_ button: NSButton, title: String, font: NSFont,
                                 toolTip: String, action: Selector) {
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .recessed
        button.controlSize = .small
        button.font = font
        button.title = title
        button.toolTip = toolTip
        button.target = self
        button.action = action
    }

    private func configureSwatch(_ button: NSButton, toolTip: String, action: Selector) {
        button.title = ""
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.borderWidth = 1
        button.layer?.borderColor = ToolbarLayout.iconColor.withAlphaComponent(0.4).cgColor
        button.toolTip = toolTip
        button.target = self
        button.action = action
    }

    private func rebuildFontMenu() {
        let menu = NSMenu()
        let systemItem = NSMenuItem(title: L("System"), action: nil, keyEquivalent: "")
        systemItem.representedObject = "System"
        menu.addItem(systemItem)
        menu.addItem(.separator())
        for family in NSFontManager.shared.availableFontFamilies.sorted() {
            // Skip private families (leading '.') — internal UI fonts.
            if family.hasPrefix(".") { continue }
            let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
            item.representedObject = family
            menu.addItem(item)
        }
        fontPopup.menu = menu
    }

    private func selectFontFamily(_ family: String) {
        guard let menu = fontPopup.menu else { return }
        let index = menu.items.firstIndex { ($0.representedObject as? String) == family }
        fontPopup.selectItem(at: index ?? 0)
    }

    private func layoutControls() {
        func caption(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            label.textColor = ToolbarLayout.iconColor.withAlphaComponent(0.7)
            return label
        }

        let stack = NSStackView(views: [
            fontPopup,
            sizeSlider, sizeLabel,
            boldButton, italicButton,
            caption("Aa"), textColorSwatch,
            caption(L("BG")), bgColorSwatch,
            bgStyleControl,
            outlineCheckbox, outlineColorSwatch, outlineWidthSlider,
            alignmentControl,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),

            fontPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
            fontPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            sizeSlider.widthAnchor.constraint(equalToConstant: 80),
            sizeLabel.widthAnchor.constraint(equalToConstant: 38),
            boldButton.widthAnchor.constraint(equalToConstant: 26),
            italicButton.widthAnchor.constraint(equalToConstant: 26),
            textColorSwatch.widthAnchor.constraint(equalToConstant: 18),
            textColorSwatch.heightAnchor.constraint(equalToConstant: 18),
            bgColorSwatch.widthAnchor.constraint(equalToConstant: 18),
            bgColorSwatch.heightAnchor.constraint(equalToConstant: 18),
            outlineColorSwatch.widthAnchor.constraint(equalToConstant: 18),
            outlineColorSwatch.heightAnchor.constraint(equalToConstant: 18),
            outlineWidthSlider.widthAnchor.constraint(equalToConstant: 60),
        ])
    }

    // MARK: - Control actions

    @objc private func fontFamilyChanged(_ sender: NSPopUpButton) {
        let family = (sender.selectedItem?.representedObject as? String) ?? "System"
        onChange?(.fontFamily(family))
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        let size = CGFloat(sender.doubleValue.rounded())
        sizeLabel.stringValue = "\(Int(size))pt"
        onChange?(.fontSize(size))
    }

    @objc private func boldToggled(_ sender: NSButton) {
        onChange?(.bold(sender.state == .on))
    }

    @objc private func italicToggled(_ sender: NSButton) {
        onChange?(.italic(sender.state == .on))
    }

    @objc private func textColorClicked() { onChange?(.pickTextColor) }
    @objc private func bgColorClicked() { onChange?(.pickBgColor) }
    @objc private func outlineColorClicked() { onChange?(.pickOutlineColor) }

    @objc private func bgStyleChanged(_ sender: NSSegmentedControl) {
        let style: VideoTextSegment.BackgroundStyle
        switch sender.selectedSegment {
        case 1: style = .solid
        case 2: style = .rounded
        default: style = .none
        }
        onChange?(.bgStyle(style))
    }

    @objc private func outlineToggled(_ sender: NSButton) {
        onChange?(.outlineEnabled(sender.state == .on))
    }

    @objc private func outlineWidthChanged(_ sender: NSSlider) {
        onChange?(.outlineWidth(CGFloat(sender.doubleValue)))
    }

    @objc private func alignmentChanged(_ sender: NSSegmentedControl) {
        let alignment: VideoTextSegment.Alignment
        switch sender.selectedSegment {
        case 0: alignment = .left
        case 2: alignment = .right
        default: alignment = .center
        }
        onChange?(.alignment(alignment))
    }

    private func nsColor(_ c: VideoTextSegment.RGBA) -> NSColor {
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }
}
