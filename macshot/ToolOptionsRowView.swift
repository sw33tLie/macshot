import Cocoa

/// Real NSView-based tool options row, replacing the custom-drawn drawToolOptionsRow().
/// Dynamically rebuilds its content when the selected tool changes.
class ToolOptionsRowView: NSView {

    weak var overlayView: OverlayView?
    private var currentTool: AnnotationTool?
    private let rowHeight: CGFloat = 34
    private let padding: CGFloat = 8
    private let accent = ToolbarLayout.accentColor

    /// Auto-tint controls to match toolbar accent color.
    override func addSubview(_ view: NSView) {
        super.addSubview(view)
        if let btn = view as? NSButton { btn.contentTintColor = accent }
        if let slider = view as? NSSlider { slider.trackFillColor = accent }
        if let seg = view as? NSSegmentedControl { seg.selectedSegmentBezelColor = accent }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = ToolbarLayout.bgColor.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rebuild the options row for the given tool. Call when tool or state changes.
    func rebuild(for tool: AnnotationTool) {
        // Remove old subviews
        subviews.forEach { $0.removeFromSuperview() }
        guard let ov = overlayView else { return }

        currentTool = tool
        var curX: CGFloat = padding

        // ── Beautify options (overrides tool options when active) ──
        if ov.showBeautifyInOptionsRow {
            curX = addBeautifyOptions(at: curX, ov: ov)
            let totalW = max(curX + padding, 200)
            frame.size = NSSize(width: totalW, height: rowHeight)
            return
        }

        // ── Stroke width slider (most drawing tools) ──
        let hasStroke = [.pencil, .line, .arrow, .rectangle, .ellipse, .marker, .number, .loupe].contains(tool)
        if hasStroke {
            curX = addStrokeSlider(at: curX, tool: tool, ov: ov)
        }

        // ── Line style (line, pencil, rectangle) ──
        let hasLineStyle = [.line, .pencil, .rectangle].contains(tool)
        if hasLineStyle {
            curX = addLineStyleSegment(at: curX, ov: ov)
        }

        // ── Arrow style ──
        if tool == .arrow {
            curX = addArrowStyleSegment(at: curX, ov: ov)
        }

        // ── Shape fill style (rectangle, ellipse) ──
        if tool == .rectangle || tool == .ellipse {
            curX = addShapeFillSegment(at: curX, tool: tool, ov: ov)
        }

        // ── Corner radius slider (rectangle) ──
        if tool == .rectangle {
            curX = addCornerRadiusSlider(at: curX, ov: ov)
        }

        // ── Right-click hint for line/arrow ──
        if tool == .line || tool == .arrow {
            curX = addHintLabel(at: curX, text: "Right-click to add points")
        }

        // ── Pencil smooth toggle ──
        if tool == .pencil {
            curX = addToggle(at: curX, title: "Smooth", isOn: ov.pencilSmoothEnabled) { [weak ov] isOn in
                ov?.pencilSmoothEnabled = isOn
                UserDefaults.standard.set(isOn, forKey: "pencilSmoothEnabled")
                ov?.needsDisplay = true
            }
        }

        // ── Number format + start-at ──
        if tool == .number {
            curX = addNumberOptions(at: curX, ov: ov)
        }

        // ── Text formatting ──
        if tool == .text {
            curX = addTextOptions(at: curX, ov: ov)
        }

        // ── Measure px/pt toggle ──
        if tool == .measure {
            curX = addMeasureToggle(at: curX, ov: ov)
        }

        // ── Stamp/emoji row ──
        if tool == .stamp {
            curX = addStampOptions(at: curX, ov: ov)
        }

        // ── Blur/pixelate redact buttons ──
        if tool == .pixelate || tool == .blur {
            curX = addRedactOptions(at: curX, ov: ov)
        }

        // Size the row
        let totalW = max(curX + padding, 200)
        frame.size = NSSize(width: totalW, height: rowHeight)
    }

    // MARK: - Section builders

    private func addStrokeSlider(at x: CGFloat, tool: AnnotationTool, ov: OverlayView) -> CGFloat {
        var curX = x
        let sliderW: CGFloat = 100
        let slider = NSSlider(value: Double(ov.activeStrokeWidthForTool(tool)),
                              minValue: 1, maxValue: tool == .loupe ? 320 : 20,
                              target: self, action: #selector(strokeSliderChanged(_:)))
        slider.frame = NSRect(x: curX, y: (rowHeight - 20) / 2, width: sliderW, height: 20)
        slider.isContinuous = true
        slider.tag = tool.rawValue
        addSubview(slider)
        curX += sliderW + 4

        let label = NSTextField(labelWithString: "\(Int(ov.activeStrokeWidthForTool(tool)))px")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.6)
        label.frame = NSRect(x: curX, y: (rowHeight - 14) / 2, width: 36, height: 14)
        label.tag = 997  // stroke label
        addSubview(label)
        curX += 34

        return curX
    }

    private func addLineStyleSegment(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let styles = ["Solid", "Dash", "Dot"]
        let seg = NSSegmentedControl(labels: styles, trackingMode: .selectOne,
                                     target: self, action: #selector(lineStyleChanged(_:)))
        seg.selectedSegment = ov.currentLineStyle.rawValue
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 120, height: 22)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        addSubview(seg)
        curX += 124
        return curX
    }

    private func addArrowStyleSegment(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let styles = ["→", "⇒", "⇉", "▷", "↦"]
        let seg = NSSegmentedControl(labels: styles, trackingMode: .selectOne,
                                     target: self, action: #selector(arrowStyleChanged(_:)))
        seg.selectedSegment = ov.currentArrowStyle.rawValue
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 140, height: 22)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        addSubview(seg)
        curX += 144
        return curX
    }

    private func addShapeFillSegment(at x: CGFloat, tool: AnnotationTool, ov: OverlayView) -> CGFloat {
        var curX = x
        let styles = ["Stroke", "Fill+Stroke", "Fill"]
        let seg = NSSegmentedControl(labels: styles, trackingMode: .selectOne,
                                     target: self, action: #selector(shapeFillChanged(_:)))
        seg.selectedSegment = ov.currentRectFillStyle.rawValue
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 160, height: 22)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        addSubview(seg)
        curX += 164
        return curX
    }

    private func addCornerRadiusSlider(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let label = NSTextField(labelWithString: "Radius")
        label.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.4)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: curX, y: (rowHeight - label.frame.height) / 2)
        addSubview(label)
        curX += label.frame.width + 4

        let slider = NSSlider(value: Double(ov.currentRectCornerRadius),
                              minValue: 0, maxValue: 30,
                              target: self, action: #selector(cornerRadiusChanged(_:)))
        slider.frame = NSRect(x: curX, y: (rowHeight - 20) / 2, width: 80, height: 20)
        slider.isContinuous = true
        addSubview(slider)
        curX += 84
        return curX
    }

    private func addToggle(at x: CGFloat, title: String, isOn: Bool, action: @escaping (Bool) -> Void) -> CGFloat {
        var curX = x
        let btn = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        btn.state = isOn ? .on : .off
        btn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        btn.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        btn.sizeToFit()
        btn.frame.origin = NSPoint(x: curX, y: (rowHeight - btn.frame.height) / 2)
        let handler = ToggleHandler(action: action)
        btn.target = handler
        btn.action = #selector(ToggleHandler.toggled(_:))
        objc_setAssociatedObject(btn, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        addSubview(btn)
        curX += btn.frame.width + 8
        return curX
    }

    private func addNumberOptions(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let formats = ["1", "I", "A", "a"]
        let seg = NSSegmentedControl(labels: formats, trackingMode: .selectOne,
                                     target: self, action: #selector(numberFormatChanged(_:)))
        seg.selectedSegment = ov.currentNumberFormat.rawValue
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 100, height: 22)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        addSubview(seg)
        curX += 104

        let startLabel = NSTextField(labelWithString: "Start:")
        startLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        startLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        startLabel.sizeToFit()
        startLabel.frame.origin = NSPoint(x: curX, y: (rowHeight - startLabel.frame.height) / 2)
        addSubview(startLabel)
        curX += startLabel.frame.width + 4

        let stepper = NSStepper()
        stepper.minValue = 1
        stepper.maxValue = 999
        stepper.integerValue = ov.numberStartAt
        stepper.target = self
        stepper.action = #selector(numberStartChanged(_:))
        stepper.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 19, height: 22)
        addSubview(stepper)

        let valLabel = NSTextField(labelWithString: ov.currentNumberFormat.format(ov.numberStartAt))
        valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        valLabel.tag = 999  // tag for finding later
        valLabel.sizeToFit()
        valLabel.frame.origin = NSPoint(x: curX + 22, y: (rowHeight - valLabel.frame.height) / 2)
        addSubview(valLabel)
        curX += 50

        return curX
    }

    private func addTextOptions(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x

        // Font family dropdown
        let displayName = ov.textFontFamily == "System" ? "System" : ov.textFontFamily
        let fontBtn = NSButton(title: "\(displayName) ▾", target: self, action: #selector(fontFamilyClicked(_:)))
        fontBtn.bezelStyle = .recessed
        fontBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        fontBtn.sizeToFit()
        fontBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: max(65, fontBtn.frame.width + 8), height: 22)
        addSubview(fontBtn)
        curX += fontBtn.frame.width + 6

        // Bold / Italic / Underline / Strikethrough
        let textStyles: [(String, String, Bool, Selector)] = [
            ("bold", "B", ov.textBold, #selector(boldToggled)),
            ("italic", "I", ov.textItalic, #selector(italicToggled)),
            ("underline", "U", ov.textUnderline, #selector(underlineToggled)),
            ("strikethrough", "S", ov.textStrikethrough, #selector(strikethroughToggled)),
        ]
        for (_, label, isOn, sel) in textStyles {
            let btn = NSButton(title: label, target: self, action: sel)
            btn.bezelStyle = .recessed
            btn.state = isOn ? .on : .off
            btn.setButtonType(.toggle)
            btn.font = NSFont.systemFont(ofSize: 12, weight: isOn ? .bold : .regular)
            btn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 26, height: 22)
            addSubview(btn)
            curX += 28
        }
        curX += 4

        // Alignment buttons
        let alignments: [(String, NSTextAlignment)] = [
            ("text.alignleft", .left), ("text.aligncenter", .center), ("text.alignright", .right)
        ]
        for (symbol, alignment) in alignments {
            let btn = NSButton()
            btn.bezelStyle = .recessed
            btn.isBordered = false
            btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            btn.state = ov.textAlignment == alignment ? .on : .off
            btn.setButtonType(.toggle)
            btn.tag = alignment.rawValue
            btn.target = self
            btn.action = #selector(alignmentChanged(_:))
            btn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 26, height: 22)
            addSubview(btn)
            curX += 28
        }
        curX += 4

        // Font size −/+
        let minusBtn = NSButton(title: "−", target: self, action: #selector(fontSizeDecreased))
        minusBtn.bezelStyle = .recessed
        minusBtn.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        minusBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 20, height: 22)
        addSubview(minusBtn)
        curX += 20

        let sizeLabel = NSTextField(labelWithString: "\(Int(ov.textFontSize))")
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        sizeLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        sizeLabel.alignment = .center
        sizeLabel.tag = 998
        sizeLabel.frame = NSRect(x: curX, y: (rowHeight - 14) / 2, width: 26, height: 14)
        addSubview(sizeLabel)
        curX += 26

        let plusBtn = NSButton(title: "+", target: self, action: #selector(fontSizeIncreased))
        plusBtn.bezelStyle = .recessed
        plusBtn.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        plusBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 20, height: 22)
        addSubview(plusBtn)
        curX += 24

        // Fill / Outline toggles
        let fillBtn = NSButton(checkboxWithTitle: "Fill", target: self, action: #selector(textBgToggled(_:)))
        fillBtn.state = ov.textBgEnabled ? .on : .off
        fillBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        fillBtn.sizeToFit()
        fillBtn.frame.origin = NSPoint(x: curX, y: (rowHeight - fillBtn.frame.height) / 2)
        addSubview(fillBtn)
        curX += fillBtn.frame.width + 4

        let outlineBtn = NSButton(checkboxWithTitle: "Outline", target: self, action: #selector(textOutlineToggled(_:)))
        outlineBtn.state = ov.textOutlineEnabled ? .on : .off
        outlineBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        outlineBtn.sizeToFit()
        outlineBtn.frame.origin = NSPoint(x: curX, y: (rowHeight - outlineBtn.frame.height) / 2)
        addSubview(outlineBtn)
        curX += outlineBtn.frame.width + 8

        // Cancel / Confirm (only when editing text)
        if ov.textEditView != nil {
            let cancelBtn = NSButton(title: "✕", target: self, action: #selector(textCancelClicked))
            cancelBtn.bezelStyle = .recessed
            cancelBtn.contentTintColor = .systemRed
            cancelBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            cancelBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 24, height: 22)
            addSubview(cancelBtn)
            curX += 26

            let confirmBtn = NSButton(title: "✓", target: self, action: #selector(textConfirmClicked))
            confirmBtn.bezelStyle = .recessed
            confirmBtn.contentTintColor = .systemGreen
            confirmBtn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            confirmBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 24, height: 22)
            addSubview(confirmBtn)
            curX += 28
        }

        return curX
    }

    private func addMeasureToggle(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let seg = NSSegmentedControl(labels: ["px", "pt"], trackingMode: .selectOne,
                                     target: self, action: #selector(measureUnitChanged(_:)))
        seg.selectedSegment = ov.currentMeasureInPoints ? 1 : 0
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 60, height: 22)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        addSubview(seg)
        curX += 72

        // Hint
        curX = addHintLabel(at: curX, text: "Hold 1 auto-vertical  ·  Hold 2 auto-horizontal")
        return curX
    }

    private func addStampOptions(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        // Quick emoji buttons
        for emoji in OverlayView.commonEmojis {
            let btn = NSButton(title: emoji, target: self, action: #selector(quickEmojiClicked(_:)))
            btn.bezelStyle = .recessed
            btn.isBordered = false
            btn.font = NSFont.systemFont(ofSize: 18)
            btn.frame = NSRect(x: curX, y: (rowHeight - 26) / 2, width: 26, height: 26)
            addSubview(btn)
            curX += 26
        }
        curX += 4

        let moreBtn = NSButton()
        moreBtn.bezelStyle = .recessed
        moreBtn.isBordered = false
        moreBtn.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "More Emojis")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        moreBtn.toolTip = "More Emojis"
        moreBtn.target = self
        moreBtn.action = #selector(moreEmojisClicked)
        moreBtn.frame = NSRect(x: curX, y: (rowHeight - 26) / 2, width: 28, height: 26)
        addSubview(moreBtn)
        curX += 30

        let loadBtn = NSButton()
        loadBtn.bezelStyle = .recessed
        loadBtn.isBordered = false
        loadBtn.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Load Image")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        loadBtn.toolTip = "Load Image"
        loadBtn.target = self
        loadBtn.action = #selector(loadImageClicked)
        loadBtn.frame = NSRect(x: curX, y: (rowHeight - 26) / 2, width: 28, height: 26)
        addSubview(loadBtn)
        curX += 30

        return curX
    }

    private func addRedactOptions(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let allTextBtn = NSButton(title: "All Text", target: self, action: #selector(redactAllTextClicked))
        allTextBtn.bezelStyle = .recessed
        allTextBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        allTextBtn.sizeToFit()
        allTextBtn.frame.origin = NSPoint(x: curX, y: (rowHeight - allTextBtn.frame.height) / 2)
        addSubview(allTextBtn)
        curX += allTextBtn.frame.width + 4

        let piiBtn = NSButton(title: "PII", target: self, action: #selector(redactPIIClicked))
        piiBtn.bezelStyle = .recessed
        piiBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        piiBtn.sizeToFit()
        piiBtn.frame.origin = NSPoint(x: curX, y: (rowHeight - piiBtn.frame.height) / 2)
        addSubview(piiBtn)
        curX += piiBtn.frame.width + 4

        let typeBtn = NSButton(title: "Types ▾", target: self, action: #selector(redactTypesClicked))
        typeBtn.bezelStyle = .recessed
        typeBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        typeBtn.sizeToFit()
        typeBtn.frame.origin = NSPoint(x: curX, y: (rowHeight - typeBtn.frame.height) / 2)
        addSubview(typeBtn)
        curX += typeBtn.frame.width + 4

        return curX
    }

    private func addBeautifyOptions(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x

        // Mode toggle: Window / Rounded
        let modeSeg = NSSegmentedControl(labels: ["W", "R"], trackingMode: .selectOne,
                                         target: self, action: #selector(beautifyModeChanged(_:)))
        modeSeg.selectedSegment = ov.beautifyMode == .window ? 0 : 1
        modeSeg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 56, height: 22)
        (modeSeg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        addSubview(modeSeg)
        curX += 60

        // Padding slider
        curX = addBeautifySlider(at: curX, label: "Pad", value: ov.beautifyPadding, min: 16, max: 96, action: #selector(beautifyPaddingChanged(_:)))

        // Corner radius slider
        curX = addBeautifySlider(at: curX, label: "Radius", value: ov.beautifyCornerRadius, min: 0, max: 30, action: #selector(beautifyCornerChanged(_:)))

        // Shadow slider
        curX = addBeautifySlider(at: curX, label: "Shadow", value: ov.beautifyShadowRadius, min: 0, max: 40, action: #selector(beautifyShadowChanged(_:)))

        // Gradient picker button
        let gradBtn = NSButton(title: "Style ▾", target: self, action: #selector(beautifyGradientClicked))
        gradBtn.bezelStyle = .recessed
        gradBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        gradBtn.sizeToFit()
        gradBtn.frame.origin = NSPoint(x: curX, y: (rowHeight - gradBtn.frame.height) / 2)
        addSubview(gradBtn)
        curX += gradBtn.frame.width + 8

        // On/off toggle
        let toggleBtn = NSButton(checkboxWithTitle: "On", target: self, action: #selector(beautifyToggleChanged(_:)))
        toggleBtn.state = ov.beautifyEnabled ? .on : .off
        toggleBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        toggleBtn.sizeToFit()
        toggleBtn.frame.origin = NSPoint(x: curX, y: (rowHeight - toggleBtn.frame.height) / 2)
        addSubview(toggleBtn)
        curX += toggleBtn.frame.width + 4

        return curX
    }

    private func addBeautifySlider(at x: CGFloat, label: String, value: CGFloat, min: CGFloat, max: CGFloat, action: Selector) -> CGFloat {
        var curX = x
        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        lbl.textColor = NSColor.white.withAlphaComponent(0.5)
        lbl.sizeToFit()
        lbl.frame.origin = NSPoint(x: curX, y: (rowHeight - lbl.frame.height) / 2)
        addSubview(lbl)
        curX += lbl.frame.width + 3

        let slider = NSSlider(value: Double(value), minValue: Double(min), maxValue: Double(max),
                              target: self, action: action)
        slider.frame = NSRect(x: curX, y: (rowHeight - 18) / 2, width: 60, height: 18)
        slider.isContinuous = true
        addSubview(slider)
        curX += 64

        return curX
    }

    // MARK: - Beautify Actions

    @objc private func beautifyModeChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        ov.beautifyMode = sender.selectedSegment == 0 ? .window : .rounded
        UserDefaults.standard.set(ov.beautifyMode.rawValue, forKey: "beautifyMode")
        ov.needsDisplay = true
    }

    @objc private func beautifyPaddingChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        ov.beautifyPadding = CGFloat(sender.floatValue)
        UserDefaults.standard.set(sender.doubleValue, forKey: "beautifyPadding")
        ov.needsDisplay = true
    }

    @objc private func beautifyCornerChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        ov.beautifyCornerRadius = CGFloat(sender.floatValue)
        UserDefaults.standard.set(sender.doubleValue, forKey: "beautifyCornerRadius")
        ov.needsDisplay = true
    }

    @objc private func beautifyShadowChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        ov.beautifyShadowRadius = CGFloat(sender.floatValue)
        UserDefaults.standard.set(sender.doubleValue, forKey: "beautifyShadowRadius")
        ov.needsDisplay = true
    }

    @objc private func beautifyGradientClicked() {
        guard let ov = overlayView else { return }
        ov.showBeautifyGradientPopover(anchorRect: frame)
    }

    @objc private func beautifyToggleChanged(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        ov.beautifyEnabled = sender.state == .on
        UserDefaults.standard.set(ov.beautifyEnabled, forKey: "beautifyEnabled")
        ov.needsDisplay = true
    }

    private func addHintLabel(at x: CGFloat, text: String) -> CGFloat {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.3)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: x, y: (rowHeight - label.frame.height) / 2)
        addSubview(label)
        return x + label.frame.width + 8
    }

    // MARK: - Actions

    @objc private func strokeSliderChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        let val = CGFloat(sender.floatValue)
        if let tool = currentTool { ov.setActiveStrokeWidth(val, for: tool) }
        if let label = viewWithTag(997) as? NSTextField {
            label.stringValue = currentTool == .loupe ? "\(Int(val))" : "\(Int(val))px"
        }
    }

    @objc private func lineStyleChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        if let style = LineStyle(rawValue: sender.selectedSegment) {
            ov.currentLineStyle = style
            UserDefaults.standard.set(style.rawValue, forKey: "currentLineStyle")
            ov.needsDisplay = true
        }
    }

    @objc private func arrowStyleChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        if let style = ArrowStyle(rawValue: sender.selectedSegment) {
            ov.currentArrowStyle = style
            UserDefaults.standard.set(style.rawValue, forKey: "currentArrowStyle")
            ov.needsDisplay = true
        }
    }

    @objc private func shapeFillChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        if let style = RectFillStyle(rawValue: sender.selectedSegment) {
            ov.currentRectFillStyle = style
            UserDefaults.standard.set(style.rawValue, forKey: "currentRectFillStyle")
            ov.needsDisplay = true
        }
    }

    @objc private func cornerRadiusChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        ov.currentRectCornerRadius = CGFloat(sender.floatValue)
        UserDefaults.standard.set(sender.doubleValue, forKey: "currentRectCornerRadius")
        ov.needsDisplay = true
    }

    @objc private func numberFormatChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        if let fmt = NumberFormat(rawValue: sender.selectedSegment) {
            ov.currentNumberFormat = fmt
            UserDefaults.standard.set(fmt.rawValue, forKey: "numberFormat")
            ov.needsDisplay = true
        }
    }

    @objc private func numberStartChanged(_ sender: NSStepper) {
        guard let ov = overlayView else { return }
        ov.numberStartAt = sender.integerValue
        UserDefaults.standard.set(sender.integerValue, forKey: "numberStartAt")
        // Update value label
        if let label = viewWithTag(999) as? NSTextField {
            label.stringValue = ov.currentNumberFormat.format(sender.integerValue)
            label.sizeToFit()
        }
        ov.needsDisplay = true
    }

    @objc private func fontSizeChanged(_ sender: NSStepper) {
        guard let ov = overlayView else { return }
        ov.textFontSize = CGFloat(sender.integerValue)
        UserDefaults.standard.set(sender.doubleValue, forKey: "fontSize")
        if let label = viewWithTag(998) as? NSTextField {
            label.stringValue = "\(sender.integerValue)pt"
            label.sizeToFit()
        }
        ov.updateTextFontSize()
        ov.needsDisplay = true
    }

    @objc private func boldToggled() { overlayView?.toggleTextBold(); overlayView.map { rebuild(for: $0.currentTool) } }
    @objc private func italicToggled() { overlayView?.toggleTextItalic(); overlayView.map { rebuild(for: $0.currentTool) } }
    @objc private func underlineToggled() { overlayView?.toggleTextUnderline(); overlayView.map { rebuild(for: $0.currentTool) } }
    @objc private func strikethroughToggled() { overlayView?.toggleTextStrikethrough(); overlayView.map { rebuild(for: $0.currentTool) } }

    @objc private func measureUnitChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        ov.currentMeasureInPoints = sender.selectedSegment == 1
        UserDefaults.standard.set(ov.currentMeasureInPoints, forKey: "measureInPoints")
        ov.needsDisplay = true
    }

    @objc private func quickEmojiClicked(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        ov.currentStampImage = ov.renderEmoji(sender.title)
        ov.currentStampEmoji = sender.title
        ov.needsDisplay = true
    }

    @objc private func moreEmojisClicked() {
        guard let ov = overlayView else { return }
        ov.showEmojiPopover(anchorRect: frame)
    }

    @objc private func loadImageClicked() {
        guard let ov = overlayView else { return }
        ov.loadStampImage()
    }

    @objc private func redactAllTextClicked() {
        overlayView?.performAutoRedact()
    }

    @objc private func redactPIIClicked() {
        overlayView?.performAutoRedactPII()
    }

    @objc private func redactTypesClicked() {
        guard let ov = overlayView else { return }
        ov.showRedactTypePopover(anchorRect: frame)
    }

    @objc private func fontFamilyClicked(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        let families = OverlayView.fontFamilies
        let picker = ListPickerView()
        picker.items = families.map { family in
            .init(title: family, isSelected: family == ov.textFontFamily)
        }
        picker.onSelect = { [weak ov] idx in
            guard let ov = ov else { return }
            ov.textFontFamily = families[idx]
            UserDefaults.standard.set(families[idx], forKey: "textFontFamily")
            ov.updateTextFontSize()
            ov.rebuildToolbarLayout()
            ov.needsDisplay = true
            PopoverHelper.dismiss()
        }
        let size = NSSize(width: 160, height: min(400, CGFloat(families.count) * 28 + 12))
        PopoverHelper.show(picker, size: size, relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func alignmentChanged(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        if let align = NSTextAlignment(rawValue: sender.tag) {
            ov.textAlignment = align
            ov.applyAlignmentToTextIfEditing()
            ov.needsDisplay = true
        }
    }

    @objc private func fontSizeDecreased() {
        guard let ov = overlayView else { return }
        ov.textFontSize = max(8, ov.textFontSize - 1)
        UserDefaults.standard.set(Double(ov.textFontSize), forKey: "textFontSize")
        ov.updateTextFontSize()
        if let label = viewWithTag(998) as? NSTextField { label.stringValue = "\(Int(ov.textFontSize))" }
    }

    @objc private func fontSizeIncreased() {
        guard let ov = overlayView else { return }
        ov.textFontSize = min(200, ov.textFontSize + 1)
        UserDefaults.standard.set(Double(ov.textFontSize), forKey: "textFontSize")
        ov.updateTextFontSize()
        if let label = viewWithTag(998) as? NSTextField { label.stringValue = "\(Int(ov.textFontSize))" }
    }

    @objc private func textBgToggled(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        ov.textBgEnabled = sender.state == .on
        UserDefaults.standard.set(ov.textBgEnabled, forKey: "textBgEnabled")
        ov.needsDisplay = true
    }

    @objc private func textOutlineToggled(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        ov.textOutlineEnabled = sender.state == .on
        UserDefaults.standard.set(ov.textOutlineEnabled, forKey: "textOutlineEnabled")
        ov.needsDisplay = true
    }

    @objc private func textCancelClicked() {
        overlayView?.cancelTextEditing()
    }

    @objc private func textConfirmClicked() {
        overlayView?.commitTextFieldIfNeeded()
    }
}

// Helper for toggle closures
private class ToggleHandler: NSObject {
    let action: (Bool) -> Void
    init(action: @escaping (Bool) -> Void) { self.action = action }
    @objc func toggled(_ sender: NSButton) { action(sender.state == .on) }
}
