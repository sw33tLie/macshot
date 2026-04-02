import Cocoa

/// Real NSView-based tool options row, replacing the custom-drawn drawToolOptionsRow().
/// Dynamically rebuilds its content when the selected tool changes.
class ToolOptionsRowView: NSView {

    weak var overlayView: OverlayView?
    private var currentTool: AnnotationTool?
    private let rowHeight: CGFloat = 34
    private let padding: CGFloat = 8
    /// The natural content width calculated during rebuild, before any external resizing.
    private(set) var contentWidth: CGFloat = 200
    private let accent = ToolbarLayout.accentColor

    // Consume clicks on gaps between controls so they don't fall through to OverlayView
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let result = super.hitTest(point), result !== self { return result }
        return self
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    /// Auto-tint controls to match toolbar accent color.
    /// Buttons with tag 990+ are excluded (they have custom colors like red/green/white).
    override func addSubview(_ view: NSView) {
        super.addSubview(view)
        if let btn = view as? NSButton, btn.tag < 990 { btn.contentTintColor = accent }
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
            contentWidth = totalW
            frame.size = NSSize(width: totalW, height: rowHeight)
            return
        }

        // ── Stroke width slider (most drawing tools) ──
        let hasStroke = [.pencil, .line, .arrow, .rectangle, .ellipse, .marker, .number, .loupe].contains(tool)
        if hasStroke {
            curX = addStrokeSlider(at: curX, tool: tool, ov: ov)
        }

        // ── Line style (line, pencil, rectangle) ──
        let hasLineStyle = [.line, .pencil, .rectangle, .arrow, .ellipse].contains(tool)
        if hasLineStyle {
            if hasStroke { curX = addSeparator(at: curX) }
            curX = addLineStyleSegment(at: curX, ov: ov)
        }

        // ── Arrow style ──
        if tool == .arrow {
            curX = addSeparator(at: curX)
            curX = addArrowStyleSegment(at: curX, ov: ov)
        }

        // ── Shape fill style (rectangle, ellipse) ──
        if tool == .rectangle || tool == .ellipse {
            curX = addSeparator(at: curX)
            curX = addShapeFillSegment(at: curX, tool: tool, ov: ov)
        }

        // ── Corner radius slider (rectangle) ──
        if tool == .rectangle {
            curX = addSeparator(at: curX)
            curX = addCornerRadiusSlider(at: curX, ov: ov)
        }

        // ── Right-click hint for line/arrow ──
        if tool == .line || tool == .arrow {
            curX += 8
            curX = addHintLabel(at: curX, text: "Right-click to add points")
        }

        // ── Pencil smooth toggle ──
        if tool == .pencil {
            curX = addSeparator(at: curX)
            curX = addToggle(at: curX, title: "Smooth", isOn: ov.pencilSmoothEnabled) { [weak ov] isOn in
                ov?.pencilSmoothEnabled = isOn
                UserDefaults.standard.set(isOn, forKey: "pencilSmoothEnabled")
                ov?.needsDisplay = true
            }
        }

        // ── Smart marker toggle ──
        if tool == .marker {
            curX = addSeparator(at: curX)
            curX = addToggle(at: curX, title: "Smart", isOn: ov.smartMarkerEnabled) { [weak ov, weak self] isOn in
                ov?.smartMarkerEnabled = isOn
                UserDefaults.standard.set(isOn, forKey: "smartMarkerEnabled")
                ov?.updateCursorForCurrentTool()
                ov?.needsDisplay = true
                // Rebuild to update stroke slider enabled state
                self?.rebuild(for: .marker)
            }
            // Disable stroke slider when smart marker is on (auto-sized)
            if ov.smartMarkerEnabled {
                for sub in subviews {
                    if let slider = sub as? NSSlider, slider.tag == AnnotationTool.marker.rawValue {
                        slider.isEnabled = false
                        slider.alphaValue = 0.35
                    }
                }
                if let label = viewWithTag(997) as? NSTextField {
                    label.alphaValue = 0.35
                }
                // Also dim the "Stroke" label
                for sub in subviews {
                    if let tf = sub as? NSTextField, tf.stringValue == "Stroke", tf.tag == 0 {
                        tf.alphaValue = 0.35
                    }
                }
            }
        }

        // ── Number format + start-at ──
        if tool == .number {
            curX = addSeparator(at: curX)
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
        contentWidth = totalW
        frame.size = NSSize(width: totalW, height: rowHeight)

        // Right-align cancel/confirm buttons for text tool
        if let confirmBtn = viewWithTag(991) {
            confirmBtn.frame.origin.x = totalW - padding - 28
        }
        if let cancelBtn = viewWithTag(990) {
            cancelBtn.frame.origin.x = totalW - padding - 28 - 4 - 28
        }
    }

    // MARK: - Section builders

    private func addSeparator(at x: CGFloat) -> CGFloat {
        let sep = NSView(frame: NSRect(x: x + 6, y: 8, width: 1, height: rowHeight - 16))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        addSubview(sep)
        return x + 13
    }

    private func addStrokeSlider(at x: CGFloat, tool: AnnotationTool, ov: OverlayView) -> CGFloat {
        var curX = x

        let nameLabel = NSTextField(labelWithString: tool == .loupe ? "Size" : "Stroke")
        nameLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        nameLabel.sizeToFit()
        nameLabel.frame.origin = NSPoint(x: curX, y: (rowHeight - nameLabel.frame.height) / 2)
        addSubview(nameLabel)
        curX += nameLabel.frame.width + 4

        let sliderW: CGFloat = 100
        let slider = NSSlider(value: Double(ov.activeStrokeWidthForTool(tool)),
                              minValue: tool == .loupe ? 40 : 1, maxValue: tool == .loupe ? 320 : 20,
                              target: self, action: #selector(strokeSliderChanged(_:)))
        slider.frame = NSRect(x: curX, y: (rowHeight - 20) / 2, width: sliderW, height: 20)
        slider.isContinuous = true
        slider.tag = tool.rawValue
        addSubview(slider)
        curX += sliderW + 4

        let val = Int(ov.activeStrokeWidthForTool(tool))
        let valStr = tool == .loupe ? "\(val)" : "\(val)px"
        let labelW: CGFloat = tool == .loupe ? 32 : 28
        let label = NSTextField(labelWithString: valStr)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.6)
        label.alignment = .right
        label.frame = NSRect(x: curX, y: (rowHeight - 14) / 2, width: labelW, height: 14)
        label.tag = 997  // stroke value label
        addSubview(label)
        curX += labelW

        return curX
    }

    private func addLineStyleSegment(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let seg = NSSegmentedControl()
        seg.segmentCount = LineStyle.allCases.count
        seg.trackingMode = .selectOne
        seg.target = self
        seg.action = #selector(lineStyleChanged(_:))
        for (i, style) in LineStyle.allCases.enumerated() {
            seg.setImage(Self.lineStyleImage(style), forSegment: i)
            seg.setWidth(36, forSegment: i)
        }
        seg.selectedSegment = ov.currentLineStyle.rawValue
        let segW = CGFloat(LineStyle.allCases.count) * 36
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: segW, height: 22)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        addSubview(seg)
        curX += segW
        return curX
    }

    private func addArrowStyleSegment(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let seg = NSSegmentedControl()
        seg.segmentCount = ArrowStyle.allCases.count
        seg.trackingMode = .selectOne
        seg.target = self
        seg.action = #selector(arrowStyleChanged(_:))
        for (i, style) in ArrowStyle.allCases.enumerated() {
            seg.setImage(Self.arrowStyleImage(style), forSegment: i)
            seg.setWidth(30, forSegment: i)
        }
        seg.selectedSegment = ov.currentArrowStyle.rawValue
        let segW = CGFloat(ArrowStyle.allCases.count) * 30
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: segW, height: 22)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        addSubview(seg)
        curX += segW
        return curX
    }

    private func addShapeFillSegment(at x: CGFloat, tool: AnnotationTool, ov: OverlayView) -> CGFloat {
        var curX = x
        let isOval = tool == .ellipse
        let seg = NSSegmentedControl()
        seg.segmentCount = RectFillStyle.allCases.count
        seg.trackingMode = .selectOne
        seg.target = self
        seg.action = #selector(shapeFillChanged(_:))
        for (i, style) in RectFillStyle.allCases.enumerated() {
            seg.setImage(Self.shapeFillImage(style, oval: isOval), forSegment: i)
            seg.setWidth(30, forSegment: i)
        }
        seg.selectedSegment = ov.currentRectFillStyle.rawValue
        let segW = CGFloat(RectFillStyle.allCases.count) * 30
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: segW, height: 22)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        addSubview(seg)
        curX += segW
        return curX
    }

    // MARK: - Segment preview images

    private static func lineStyleImage(_ style: LineStyle) -> NSImage {
        let size = NSSize(width: 28, height: 16)
        return NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            style.apply(to: path)
            NSColor.white.setStroke()
            path.move(to: NSPoint(x: 4, y: size.height / 2))
            path.line(to: NSPoint(x: size.width - 4, y: size.height / 2))
            path.stroke()
            return true
        }
    }

    private static func arrowStyleImage(_ style: ArrowStyle) -> NSImage {
        let size = NSSize(width: 24, height: 16)
        return NSImage(size: size, flipped: false) { _ in
            let mid = size.height / 2
            let from = NSPoint(x: 3, y: mid)
            let to = NSPoint(x: size.width - 3, y: mid)
            NSColor.white.setStroke()
            NSColor.white.setFill()

            switch style {
            case .single:
                let path = NSBezierPath()
                path.lineWidth = 1.5
                path.move(to: from)
                path.line(to: NSPoint(x: to.x - 4, y: mid))
                path.stroke()
                let head = NSBezierPath()
                head.move(to: to)
                head.line(to: NSPoint(x: to.x - 5, y: mid + 3))
                head.line(to: NSPoint(x: to.x - 5, y: mid - 3))
                head.close()
                head.fill()
            case .thick:
                // Thick shaft stops before the head
                let path = NSBezierPath()
                path.lineWidth = 2.5
                path.move(to: from)
                path.line(to: NSPoint(x: to.x - 6, y: mid))
                path.stroke()
                let head = NSBezierPath()
                head.move(to: to)
                head.line(to: NSPoint(x: to.x - 7, y: mid + 5))
                head.line(to: NSPoint(x: to.x - 7, y: mid - 5))
                head.close()
                head.fill()
            case .double:
                let path = NSBezierPath()
                path.lineWidth = 1.5
                path.move(to: NSPoint(x: from.x + 4, y: mid))
                path.line(to: NSPoint(x: to.x - 4, y: mid))
                path.stroke()
                // Left arrowhead (pointing left)
                let headL = NSBezierPath()
                headL.move(to: from)
                headL.line(to: NSPoint(x: from.x + 5, y: mid + 3))
                headL.line(to: NSPoint(x: from.x + 5, y: mid - 3))
                headL.close()
                headL.fill()
                // Right arrowhead (pointing right)
                let headR = NSBezierPath()
                headR.move(to: to)
                headR.line(to: NSPoint(x: to.x - 5, y: mid + 3))
                headR.line(to: NSPoint(x: to.x - 5, y: mid - 3))
                headR.close()
                headR.fill()
            case .open:
                let path = NSBezierPath()
                path.lineWidth = 1.5
                path.move(to: from)
                path.line(to: to)
                path.move(to: NSPoint(x: to.x - 5, y: mid + 3))
                path.line(to: to)
                path.line(to: NSPoint(x: to.x - 5, y: mid - 3))
                path.stroke()
            case .tail:
                let path = NSBezierPath()
                path.lineWidth = 1.5
                path.move(to: from)
                path.line(to: NSPoint(x: to.x - 4, y: mid))
                path.stroke()
                // Tail crossbar — taller so it's clearly a line, not a dot
                let tail = NSBezierPath()
                tail.lineWidth = 1.5
                tail.move(to: NSPoint(x: from.x, y: mid + 5))
                tail.line(to: NSPoint(x: from.x, y: mid - 5))
                tail.stroke()
                let head = NSBezierPath()
                head.move(to: to)
                head.line(to: NSPoint(x: to.x - 5, y: mid + 3))
                head.line(to: NSPoint(x: to.x - 5, y: mid - 3))
                head.close()
                head.fill()
            }
            return true
        }
    }

    private static func shapeFillImage(_ style: RectFillStyle, oval: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        return NSImage(size: size, flipped: false) { _ in
            let r = NSRect(x: 3, y: 2, width: size.width - 6, height: size.height - 4)
            let path = oval ? NSBezierPath(ovalIn: r) : NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            path.lineWidth = 1.5
            switch style {
            case .stroke:
                NSColor.white.setStroke()
                path.stroke()
            case .strokeAndFill:
                NSColor.white.withAlphaComponent(0.4).setFill()
                path.fill()
                NSColor.white.setStroke()
                path.stroke()
            case .fill:
                NSColor.white.setFill()
                path.fill()
            }
            return true
        }
    }

    private static func gradientSwatchImage(styleIndex: Int, size: CGFloat) -> NSImage {
        let styles = BeautifyRenderer.styles
        guard styleIndex >= 0, styleIndex < styles.count else {
            return NSImage(size: NSSize(width: size, height: size))
        }
        let style = styles[styleIndex]
        // Use mesh rendering on macOS 15+ for mesh styles
        if #available(macOS 15.0, *), let mesh = style.meshDef,
           let meshImg = BeautifyRenderer.renderMeshSwatch(mesh, size: size) {
            return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
                let r = NSRect(x: 0, y: 0, width: size, height: size)
                let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                meshImg.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()
                NSColor.white.withAlphaComponent(0.3).setStroke()
                path.lineWidth = 0.5
                path.stroke()
                return true
            }
        }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let r = NSRect(x: 0, y: 0, width: size, height: size)
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            if let grad = NSGradient(
                colors: style.stops.map { $0.0 },
                atLocations: style.stops.map { $0.1 },
                colorSpace: .deviceRGB)
            {
                grad.draw(in: path, angle: style.angle - 90)
            }
            NSColor.white.withAlphaComponent(0.3).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
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
        curX += 80 + 4

        let valLabel = NSTextField(labelWithString: "\(Int(ov.currentRectCornerRadius))px")
        valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        valLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        valLabel.alignment = .right
        valLabel.frame = NSRect(x: curX, y: (rowHeight - 14) / 2, width: 28, height: 14)
        valLabel.tag = 996  // corner radius value label
        addSubview(valLabel)
        curX += 28

        return curX
    }

    private func addToggle(at x: CGFloat, title: String, isOn: Bool, action: @escaping (Bool) -> Void) -> CGFloat {
        var curX = x
        let btn = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        btn.state = isOn ? .on : .off
        btn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        btn.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        // Force white text regardless of system appearance (toolbar is always dark)
        if let cell = btn.cell as? NSButtonCell {
            let attrTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.7),
                .font: NSFont.systemFont(ofSize: 10, weight: .medium)
            ])
            cell.attributedTitle = attrTitle
        }
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
        curX += 100

        curX = addSeparator(at: curX)

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
        let displayName = ov.textEditor.fontFamily == "System" ? "System" : ov.textEditor.fontFamily
        let fontBtn = NSButton(title: "\(displayName) ▾", target: self, action: #selector(fontFamilyClicked(_:)))
        fontBtn.bezelStyle = .recessed
        fontBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        fontBtn.sizeToFit()
        fontBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: max(65, fontBtn.frame.width + 8), height: 22)
        addSubview(fontBtn)
        curX += fontBtn.frame.width + 6

        // Bold / Italic / Underline / Strikethrough
        let textStyles: [(String, String, Bool, Selector, Int)] = [
            ("bold", "B", ov.textEditor.bold, #selector(boldToggled), 980),
            ("italic", "I", ov.textEditor.italic, #selector(italicToggled), 981),
            ("underline", "U", ov.textEditor.underline, #selector(underlineToggled), 982),
            ("strikethrough", "S", ov.textEditor.strikethrough, #selector(strikethroughToggled), 983),
        ]
        for (_, label, isOn, sel, tag) in textStyles {
            let btn = NSButton(title: label, target: self, action: sel)
            btn.bezelStyle = .smallSquare
            btn.isBordered = false
            btn.wantsLayer = true
            btn.tag = tag
            btn.layer?.cornerRadius = 4
            btn.layer?.backgroundColor = isOn ? ToolbarLayout.accentColor.withAlphaComponent(0.85).cgColor : nil
            btn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            btn.attributedTitle = NSAttributedString(string: label, attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(isOn ? 1.0 : 0.6),
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            ])
            btn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 26, height: 22)
            addSubview(btn)
            curX += 28
        }

        curX = addSeparator(at: curX)

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
            btn.state = ov.textEditor.alignment == alignment ? .on : .off
            btn.setButtonType(.toggle)
            btn.tag = alignment.rawValue
            btn.target = self
            btn.action = #selector(alignmentChanged(_:))
            btn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 26, height: 22)
            addSubview(btn)
            curX += 28
        }

        curX = addSeparator(at: curX)

        // Font size −/+
        let minusBtn = NSButton(title: "−", target: self, action: #selector(fontSizeDecreased))
        minusBtn.bezelStyle = .recessed
        minusBtn.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        minusBtn.isContinuous = true
        (minusBtn.cell as? NSButtonCell)?.setPeriodicDelay(0.3, interval: 0.05)
        minusBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 20, height: 22)
        addSubview(minusBtn)
        curX += 20

        let sizeLabel = NSTextField(labelWithString: "\(Int(ov.textEditor.fontSize))")
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
        plusBtn.isContinuous = true
        (plusBtn.cell as? NSButtonCell)?.setPeriodicDelay(0.3, interval: 0.05)
        plusBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 20, height: 22)
        addSubview(plusBtn)
        curX += 24

        curX = addSeparator(at: curX)

        // Fill: clickable label (toggles on/off) + color swatch (opens color picker)
        let fillSwatchSize: CGFloat = 18
        let fillLabelBtn = NSButton(title: "Fill", target: self, action: #selector(textBgToggled(_:)))
        fillLabelBtn.bezelStyle = .recessed
        fillLabelBtn.setButtonType(.toggle)
        fillLabelBtn.state = ov.textEditor.bgEnabled ? .on : .off
        fillLabelBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        fillLabelBtn.sizeToFit()
        fillLabelBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: max(30, fillLabelBtn.frame.width), height: 22)
        addSubview(fillLabelBtn)
        curX += fillLabelBtn.frame.width + 2

        let fillSwatch = NSButton(frame: NSRect(x: curX, y: (rowHeight - fillSwatchSize) / 2, width: fillSwatchSize, height: fillSwatchSize))
        fillSwatch.title = ""
        fillSwatch.isBordered = false
        fillSwatch.wantsLayer = true
        fillSwatch.layer?.backgroundColor = ov.textEditor.bgColor.cgColor
        fillSwatch.layer?.cornerRadius = 3
        fillSwatch.layer?.borderWidth = 1.5
        fillSwatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        fillSwatch.layer?.opacity = ov.textEditor.bgEnabled ? 1.0 : 0.3
        fillSwatch.tag = 975
        fillSwatch.target = self
        fillSwatch.action = #selector(textBgColorClicked(_:))
        addSubview(fillSwatch)
        curX += fillSwatchSize + 6

        // Outline: clickable label (toggles on/off) + color swatch (opens color picker)
        let outlineLabelBtn = NSButton(title: "Outline", target: self, action: #selector(textOutlineToggled(_:)))
        outlineLabelBtn.bezelStyle = .recessed
        outlineLabelBtn.setButtonType(.toggle)
        outlineLabelBtn.state = ov.textEditor.outlineEnabled ? .on : .off
        outlineLabelBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        outlineLabelBtn.sizeToFit()
        outlineLabelBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: max(50, outlineLabelBtn.frame.width), height: 22)
        addSubview(outlineLabelBtn)
        curX += outlineLabelBtn.frame.width + 2

        let outlineSwatch = NSButton(frame: NSRect(x: curX, y: (rowHeight - fillSwatchSize) / 2, width: fillSwatchSize, height: fillSwatchSize))
        outlineSwatch.title = ""
        outlineSwatch.isBordered = false
        outlineSwatch.wantsLayer = true
        outlineSwatch.layer?.backgroundColor = ov.textEditor.outlineColor.cgColor
        outlineSwatch.layer?.cornerRadius = 3
        outlineSwatch.layer?.borderWidth = 1.5
        outlineSwatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
        outlineSwatch.layer?.opacity = ov.textEditor.outlineEnabled ? 1.0 : 0.3
        outlineSwatch.tag = 976
        outlineSwatch.target = self
        outlineSwatch.action = #selector(textOutlineColorClicked(_:))
        addSubview(outlineSwatch)
        curX += fillSwatchSize

        // Cancel / Confirm — only when actively editing text, right-aligned
        if ov.textEditor.isEditing {
            curX = addSeparator(at: curX)
            let cancelBtn = NSButton(title: "✕", target: self, action: #selector(textCancelClicked))
            cancelBtn.bezelStyle = .smallSquare
            cancelBtn.isBordered = false
            cancelBtn.wantsLayer = true
            cancelBtn.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.8).cgColor
            cancelBtn.layer?.cornerRadius = 4
            cancelBtn.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            cancelBtn.attributedTitle = NSAttributedString(string: "✕", attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11, weight: .bold)])
            cancelBtn.frame = NSRect(x: 0, y: (rowHeight - 22) / 2, width: 28, height: 22)
            cancelBtn.tag = 990
            addSubview(cancelBtn)

            let confirmBtn = NSButton(title: "✓", target: self, action: #selector(textConfirmClicked))
            confirmBtn.bezelStyle = .smallSquare
            confirmBtn.isBordered = false
            confirmBtn.wantsLayer = true
            confirmBtn.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.8).cgColor
            confirmBtn.layer?.cornerRadius = 4
            confirmBtn.font = NSFont.systemFont(ofSize: 12, weight: .bold)
            confirmBtn.attributedTitle = NSAttributedString(string: "✓", attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .bold)])
            confirmBtn.frame = NSRect(x: 0, y: (rowHeight - 22) / 2, width: 28, height: 22)
            confirmBtn.tag = 991
            addSubview(confirmBtn)

            curX += 68  // reserve space for right-aligned buttons
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
        for emoji in StampEmojis.common {
            let btn = NSButton(title: emoji, target: self, action: #selector(quickEmojiClicked(_:)))
            btn.bezelStyle = .recessed
            btn.isBordered = false
            btn.font = NSFont.systemFont(ofSize: 18)
            btn.frame = NSRect(x: curX, y: (rowHeight - 26) / 2, width: 26, height: 26)
            addSubview(btn)
            curX += 26
        }
        curX += 4

        curX = addSeparator(at: curX)

        let moreBtn = NSButton()
        moreBtn.bezelStyle = .recessed
        moreBtn.isBordered = false
        moreBtn.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "More Emojis")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        moreBtn.toolTip = "More Emojis"
        moreBtn.target = self
        moreBtn.action = #selector(moreEmojisClicked(_:))
        moreBtn.frame = NSRect(x: curX, y: (rowHeight - 26) / 2, width: 28, height: 26)
        addSubview(moreBtn)
        moreBtn.contentTintColor = .white  // after addSubview to override auto-tint
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
        loadBtn.contentTintColor = .white  // after addSubview to override auto-tint
        curX += 30

        return curX
    }

    private func addRedactOptions(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let toolName = ov.currentTool == .blur ? "Blur" : "Pixelate"

        // — Draw mode: All / Text Only segmented control —
        let drawLabel = NSTextField(labelWithString: "Draw:")
        drawLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        drawLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        drawLabel.sizeToFit()
        drawLabel.frame.origin = NSPoint(x: curX, y: (rowHeight - drawLabel.frame.height) / 2)
        addSubview(drawLabel)
        curX += drawLabel.frame.width + 4

        let textOnly = UserDefaults.standard.bool(forKey: "blurPixelateTextOnly")
        let drawSeg = NSSegmentedControl(labels: ["All", "Text Only"], trackingMode: .selectOne,
                                          target: self, action: #selector(drawModeChanged(_:)))
        drawSeg.selectedSegment = textOnly ? 1 : 0
        drawSeg.controlSize = .small
        drawSeg.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        (drawSeg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        drawSeg.sizeToFit()
        drawSeg.frame.origin = NSPoint(x: curX, y: (rowHeight - drawSeg.frame.height) / 2)
        addSubview(drawSeg)
        curX += drawSeg.frame.width + 4

        curX = addSeparator(at: curX)

        // — Auto-detect: All Text, PII, Types —
        let autoLabel = NSTextField(labelWithString: "Auto:")
        autoLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        autoLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        autoLabel.sizeToFit()
        autoLabel.frame.origin = NSPoint(x: curX, y: (rowHeight - autoLabel.frame.height) / 2)
        addSubview(autoLabel)
        curX += autoLabel.frame.width + 4

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

        let typeBtn = NSButton(title: "Types ▾", target: self, action: #selector(redactTypesClicked(_:)))
        typeBtn.bezelStyle = .recessed
        typeBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        typeBtn.sizeToFit()
        typeBtn.frame.origin = NSPoint(x: curX, y: (rowHeight - typeBtn.frame.height) / 2)
        addSubview(typeBtn)
        curX += typeBtn.frame.width + 4

        curX = addSeparator(at: curX)

        // — Face & people detection —
        let facesBtn = NSButton(title: "Faces", target: self, action: #selector(redactFacesClicked))
        facesBtn.bezelStyle = .recessed
        facesBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        facesBtn.sizeToFit()
        facesBtn.frame.origin = NSPoint(x: curX, y: (rowHeight - facesBtn.frame.height) / 2)
        addSubview(facesBtn)
        curX += facesBtn.frame.width + 4

        let peopleBtn = NSButton(title: "People", target: self, action: #selector(redactPeopleClicked))
        peopleBtn.bezelStyle = .recessed
        peopleBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        peopleBtn.sizeToFit()
        peopleBtn.frame.origin = NSPoint(x: curX, y: (rowHeight - peopleBtn.frame.height) / 2)
        addSubview(peopleBtn)
        curX += peopleBtn.frame.width + 4

        return curX
    }

    private func addBeautifyOptions(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let isSnap = ov.selectionIsWindowSnap

        // Mode toggle: Window / Rounded — hidden for snapped windows (always uses native chrome)
        if !isSnap {
            let modeSeg = NSSegmentedControl(labels: ["W", "R"], trackingMode: .selectOne,
                                             target: self, action: #selector(beautifyModeChanged(_:)))
            modeSeg.selectedSegment = ov.beautifyMode == .window ? 0 : 1
            modeSeg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 56, height: 22)
            (modeSeg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
            addSubview(modeSeg)
            curX += 56

            curX = addSeparator(at: curX)
        }

        // Padding slider
        curX = addBeautifySlider(at: curX, label: "Pad", value: ov.beautifyPadding, min: 16, max: 96, action: #selector(beautifyPaddingChanged(_:)))

        // Corner radius slider — hidden for snapped windows (native corners are baked in)
        if !isSnap {
            curX = addBeautifySlider(at: curX, label: "Radius", value: ov.beautifyCornerRadius, min: 0, max: 30, action: #selector(beautifyCornerChanged(_:)))
        }

        // Shadow slider
        curX = addBeautifySlider(at: curX, label: "Shadow", value: ov.beautifyShadowRadius, min: 0, max: 40, action: #selector(beautifyShadowChanged(_:)))

        curX = addSeparator(at: curX)

        // Gradient style picker — swatch preview + dropdown arrow
        curX += 2
        let swatchSize: CGFloat = 22
        let swatchBtn = NSButton(frame: NSRect(x: curX, y: (rowHeight - swatchSize) / 2, width: swatchSize, height: swatchSize))
        swatchBtn.bezelStyle = .recessed
        swatchBtn.isBordered = false
        swatchBtn.image = Self.gradientSwatchImage(styleIndex: ov.beautifyStyleIndex, size: swatchSize)
        swatchBtn.imageScaling = .scaleProportionallyUpOrDown
        swatchBtn.target = self
        swatchBtn.action = #selector(beautifyGradientClicked(_:))
        swatchBtn.toolTip = "Gradient Style"
        swatchBtn.tag = 995
        addSubview(swatchBtn)
        curX += swatchSize + 2

        let arrowBtn = NSButton(frame: NSRect(x: curX, y: (rowHeight - 16) / 2, width: 14, height: 16))
        arrowBtn.bezelStyle = .recessed
        arrowBtn.isBordered = false
        arrowBtn.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        arrowBtn.target = self
        arrowBtn.action = #selector(beautifyGradientClicked(_:))
        addSubview(arrowBtn)
        arrowBtn.contentTintColor = .white.withAlphaComponent(0.6)
        curX += 18

        curX = addSeparator(at: curX)

        // On/off toggle
        let toggleBtn = NSButton(checkboxWithTitle: "On", target: self, action: #selector(beautifyToggleChanged(_:)))
        toggleBtn.state = ov.beautifyEnabled ? .on : .off
        toggleBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        if let cell = toggleBtn.cell as? NSButtonCell {
            cell.attributedTitle = NSAttributedString(string: "On", attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.7),
                .font: NSFont.systemFont(ofSize: 10, weight: .medium)
            ])
        }
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

    @objc private func beautifyGradientClicked(_ sender: NSButton) {
        if PopoverHelper.isVisible { PopoverHelper.dismiss(); return }
        guard let ov = overlayView else { return }
        let swatchBtn = viewWithTag(995) as? NSButton ?? sender
        ov.showBeautifyGradientPopover(anchorView: swatchBtn)
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
        if let label = viewWithTag(996) as? NSTextField {
            label.stringValue = "\(Int(sender.floatValue))px"
        }
        ov.needsDisplay = true
    }

    @objc private func numberFormatChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        if let fmt = NumberFormat(rawValue: sender.selectedSegment) {
            ov.currentNumberFormat = fmt
            UserDefaults.standard.set(fmt.rawValue, forKey: "numberFormat")
            // Update start value preview to match new format
            if let label = viewWithTag(999) as? NSTextField {
                label.stringValue = fmt.format(ov.numberStartAt)
                label.sizeToFit()
            }
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
        ov.textEditor.fontSize = CGFloat(sender.integerValue)
        UserDefaults.standard.set(sender.doubleValue, forKey: "fontSize")
        if let label = viewWithTag(998) as? NSTextField {
            label.stringValue = "\(sender.integerValue)pt"
            label.sizeToFit()
        }
        ov.textEditor.applyFontSizeChange()
        ov.needsDisplay = true
    }

    @objc private func boldToggled() { overlayView?.textEditor.toggleBold(); overlayView.map { $0.needsDisplay = true; rebuild(for: $0.currentTool) } }
    @objc private func italicToggled() { overlayView?.textEditor.toggleItalic(); overlayView.map { $0.needsDisplay = true; rebuild(for: $0.currentTool) } }
    @objc private func underlineToggled() { overlayView?.textEditor.toggleUnderline(); overlayView.map { $0.needsDisplay = true; rebuild(for: $0.currentTool) } }
    @objc private func strikethroughToggled() { overlayView?.textEditor.toggleStrikethrough(); overlayView.map { $0.needsDisplay = true; rebuild(for: $0.currentTool) } }

    @objc private func measureUnitChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        ov.currentMeasureInPoints = sender.selectedSegment == 1
        UserDefaults.standard.set(ov.currentMeasureInPoints, forKey: "measureInPoints")
        ov.needsDisplay = true
    }

    @objc private func quickEmojiClicked(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        ov.currentStampImage = StampEmojis.renderEmoji(sender.title)
        ov.currentStampEmoji = sender.title
        ov.needsDisplay = true
    }

    @objc private func moreEmojisClicked(_ sender: NSButton) {
        if PopoverHelper.isVisible { PopoverHelper.dismiss(); return }
        guard let ov = overlayView else { return }
        ov.showEmojiPopover(anchorView: sender)
    }

    @objc private func loadImageClicked() {
        guard let ov = overlayView else { return }
        StampEmojis.loadStampImage { [weak ov] image in
            ov?.currentStampImage = image
            ov?.currentStampEmoji = nil
            ov?.needsDisplay = true
        }
    }

    @objc private func drawModeChanged(_ sender: NSSegmentedControl) {
        UserDefaults.standard.set(sender.selectedSegment == 1, forKey: "blurPixelateTextOnly")
    }

    @objc private func redactAllTextClicked() {
        overlayView?.performRedactAllText()
    }

    @objc private func redactPIIClicked() {
        overlayView?.performAutoRedact()
    }

    @objc private func redactFacesClicked() {
        overlayView?.performRedactFaces()
    }

    @objc private func redactPeopleClicked() {
        overlayView?.performRedactPeople()
    }

    @objc private func redactTypesClicked(_ sender: NSButton) {
        if PopoverHelper.isVisible { PopoverHelper.dismiss(); return }
        guard let ov = overlayView else { return }
        ov.showRedactTypePopover(anchorRect: .zero, anchorView: sender)
    }

    @objc private func fontFamilyClicked(_ sender: NSButton) {
        // Toggle: close if already open
        if PopoverHelper.isVisible {
            PopoverHelper.dismiss()
            return
        }
        guard let ov = overlayView else { return }
        let picker = FontPickerView(selectedFamily: ov.textEditor.fontFamily)
        picker.onSelect = { [weak ov] family in
            guard let ov = ov else { return }
            ov.textEditor.fontFamily = family
            UserDefaults.standard.set(family, forKey: "textFontFamily")
            ov.textEditor.applyFontSizeChange()
            ov.rebuildToolbarLayout()
            ov.needsDisplay = true
            PopoverHelper.dismiss()
        }
        PopoverHelper.show(picker, size: picker.preferredSize, relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        DispatchQueue.main.async {
            picker.scrollToTop()
        }
    }

    @objc private func alignmentChanged(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        if let align = NSTextAlignment(rawValue: sender.tag) {
            ov.textEditor.alignment = align
            ov.textEditor.applyAlignment()
            // Update all alignment buttons — only the selected one should be on
            for case let btn as NSButton in subviews where
                btn.tag == NSTextAlignment.left.rawValue ||
                btn.tag == NSTextAlignment.center.rawValue ||
                btn.tag == NSTextAlignment.right.rawValue {
                btn.state = btn.tag == align.rawValue ? .on : .off
            }
            ov.needsDisplay = true
        }
    }

    @objc private func fontSizeDecreased() {
        guard let ov = overlayView else { return }
        ov.textEditor.fontSize = max(8, ov.textEditor.fontSize - 1)
        UserDefaults.standard.set(Double(ov.textEditor.fontSize), forKey: "textFontSize")
        ov.textEditor.applyFontSizeChange()
        ov.textEditor.resizeToFit()
        if let label = viewWithTag(998) as? NSTextField { label.stringValue = "\(Int(ov.textEditor.fontSize))" }
        ov.needsDisplay = true
    }

    @objc private func fontSizeIncreased() {
        guard let ov = overlayView else { return }
        ov.textEditor.fontSize = min(200, ov.textEditor.fontSize + 1)
        UserDefaults.standard.set(Double(ov.textEditor.fontSize), forKey: "textFontSize")
        ov.textEditor.applyFontSizeChange()
        ov.textEditor.resizeToFit()
        if let label = viewWithTag(998) as? NSTextField { label.stringValue = "\(Int(ov.textEditor.fontSize))" }
        ov.needsDisplay = true
    }

    @objc private func textBgToggled(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        ov.textEditor.bgEnabled = sender.state == .on
        UserDefaults.standard.set(ov.textEditor.bgEnabled, forKey: "textBgEnabled")
        // Update swatch opacity
        if let swatch = viewWithTag(975) { swatch.layer?.opacity = ov.textEditor.bgEnabled ? 1.0 : 0.3 }
        ov.needsDisplay = true
    }

    @objc private func textOutlineToggled(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        ov.textEditor.outlineEnabled = sender.state == .on
        UserDefaults.standard.set(ov.textEditor.outlineEnabled, forKey: "textOutlineEnabled")
        if let swatch = viewWithTag(976) { swatch.layer?.opacity = ov.textEditor.outlineEnabled ? 1.0 : 0.3 }
        ov.needsDisplay = true
    }

    @objc private func textBgColorClicked(_ sender: NSButton) {
        if PopoverHelper.isVisible { PopoverHelper.dismiss(); return }
        guard let ov = overlayView else { return }
        ov.showColorPickerPopover(target: .textBg, anchorView: sender)
    }

    @objc private func textOutlineColorClicked(_ sender: NSButton) {
        if PopoverHelper.isVisible { PopoverHelper.dismiss(); return }
        guard let ov = overlayView else { return }
        ov.showColorPickerPopover(target: .textOutline, anchorView: sender)
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
