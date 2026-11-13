import AppKit

/// Visual language of the video editor: a dark, quiet studio surface where
/// the recording is the brightest thing on screen.
enum VideoEditorStyle {
    static let window = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.085, alpha: 1)
    static let panel = NSColor(srgbRed: 0.105, green: 0.105, blue: 0.118, alpha: 1)
    static let panelRaised = NSColor(srgbRed: 0.135, green: 0.135, blue: 0.15, alpha: 1)
    static let stage = NSColor(srgbRed: 0.055, green: 0.055, blue: 0.063, alpha: 1)
    static let control = NSColor(white: 1, alpha: 0.07)
    static let controlHover = NSColor(white: 1, alpha: 0.11)
    static let separator = NSColor(white: 1, alpha: 0.07)
    static let textPrimary = NSColor(white: 1, alpha: 0.92)
    static let textSecondary = NSColor(white: 1, alpha: 0.58)
    static let textTertiary = NSColor(white: 1, alpha: 0.36)

    static var accent: NSColor { ToolbarLayout.accentColor }

    // Timeline item colors.
    static let zoom = NSColor(srgbRed: 0.49, green: 0.40, blue: 1.0, alpha: 1)
    static let cut = NSColor(srgbRed: 0.93, green: 0.30, blue: 0.33, alpha: 1)
    static let speed = NSColor(srgbRed: 0.10, green: 0.70, blue: 0.62, alpha: 1)
    static let freeze = NSColor(srgbRed: 0.30, green: 0.52, blue: 0.98, alpha: 1)
    static let text = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.20, alpha: 1)
    static let censor = NSColor(srgbRed: 0.96, green: 0.42, blue: 0.30, alpha: 1)
    static let caption = NSColor(srgbRed: 0.55, green: 0.62, blue: 0.72, alpha: 1)

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func label(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                      color: NSColor = textPrimary) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font(size, weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
}

// MARK: - Controls

/// Slider that reports when a drag begins and ends, so a whole drag becomes
/// one undo step.
final class TrackingSlider: NSSlider {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var onChange: ((Double) -> Void)?

    override class var cellClass: AnyClass? {
        get { TrackingSliderCell.self }
        set {}
    }

    convenience init(min: Double, max: Double, value: Double) {
        self.init(frame: .zero)
        minValue = min
        maxValue = max
        doubleValue = value
        isContinuous = true
        controlSize = .small
        target = self
        action = #selector(changed)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func changed() { onChange?(doubleValue) }

    fileprivate func began() { onBegin?() }
    fileprivate func ended() { onEnd?() }
}

private final class TrackingSliderCell: NSSliderCell {
    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        (controlView as? TrackingSlider)?.began()
        return super.startTracking(at: startPoint, in: controlView)
    }

    override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView, mouseIsUp flag: Bool) {
        super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
        (controlView as? TrackingSlider)?.ended()
    }
}

/// Borderless icon button with a hover highlight.
final class VideoIconButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    var tint: NSColor = VideoEditorStyle.textPrimary { didSet { contentTintColor = tint } }
    var isActive = false { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 7

    convenience init(symbol: String, size: CGFloat = 14, tooltip: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        image = VideoEditorStyle.symbol(symbol, size: size)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        contentTintColor = tint
        toolTip = tooltip
        setAccessibilityLabel(tooltip)
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        focusRingType = .none
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // NSButton pads its frame beyond the constrained size; highlights fill
    // `bounds`, so neighbouring buttons' hover and selection fills would touch.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            VideoEditorStyle.accent.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        } else if hovering && isEnabled {
            VideoEditorStyle.controlHover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
        contentTintColor = !isEnabled ? VideoEditorStyle.textTertiary : (isActive ? VideoEditorStyle.accent : tint)
        super.draw(dirtyRect)
    }
}

/// Pill button with a label (and optional symbol), used for primary actions.
final class VideoPillButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    var fill: NSColor = VideoEditorStyle.control { didSet { needsDisplay = true } }
    var textColor: NSColor = VideoEditorStyle.textPrimary { didSet { updateTitle() } }
    private var symbolName: String?
    private var trailingChevron = false
    private var baseTitle = ""
    private var updating = false

    convenience init(title: String, symbol: String? = nil, chevron: Bool = false, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        symbolName = symbol
        trailingChevron = chevron
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        self.title = title
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        focusRingType = .none
        imageHugsTitle = true
        updateTitle()
    }

    override var title: String {
        didSet {
            guard !updating else { return }
            baseTitle = title
            updateTitle()
        }
    }

    private func updateTitle() {
        guard !updating else { return }
        updating = true
        defer { updating = false }
        let attributed = NSMutableAttributedString(string: baseTitle, attributes: [
            .font: VideoEditorStyle.font(12.5, .semibold), .foregroundColor: isEnabled ? textColor : VideoEditorStyle.textTertiary,
        ])
        if trailingChevron {
            attributed.append(NSAttributedString(string: "  ⌄", attributes: [
                .font: VideoEditorStyle.font(11, .bold), .foregroundColor: textColor.withAlphaComponent(0.8),
                .baselineOffset: 2,
            ]))
        }
        attributedTitle = attributed
        if let symbolName {
            image = VideoEditorStyle.symbol(symbolName, size: 12, weight: .semibold)
            imagePosition = .imageLeading
            contentTintColor = textColor
        }
        invalidateIntrinsicContentSize()
    }

    override var isEnabled: Bool { didSet { updateTitle(); needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 24, height: 28)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let color = !isEnabled ? fill.withAlphaComponent(0.4) : (hovering ? fill.blended(withFraction: 0.12, of: .white) ?? fill : fill)
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        super.draw(dirtyRect)
    }
}

/// A vertically stacked, flipped container — the inspector's scroll content.
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// Section header: small uppercase caption with an optional trailing action.
final class InspectorSectionHeader: NSView {
    init(_ title: String, actionTitle: String? = nil, target: AnyObject? = nil, action: Selector? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = VideoEditorStyle.label(title.uppercased(), size: 10.5, weight: .semibold,
                                           color: VideoEditorStyle.textSecondary)
        let kern = NSMutableAttributedString(string: title.uppercased(), attributes: [
            .font: VideoEditorStyle.font(10.5, .semibold), .foregroundColor: VideoEditorStyle.textSecondary, .kern: 0.8,
        ])
        label.attributedStringValue = kern
        addSubview(label)
        var constraints = [
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ]
        if let actionTitle {
            let button = NSButton(title: actionTitle, target: target, action: action)
            button.isBordered = false
            button.attributedTitle = NSAttributedString(string: actionTitle, attributes: [
                .font: VideoEditorStyle.font(11, .medium), .foregroundColor: VideoEditorStyle.accent,
            ])
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            constraints += [button.trailingAnchor.constraint(equalTo: trailingAnchor),
                            button.centerYAnchor.constraint(equalTo: centerYAnchor)]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Rounded card grouping related rows.
final class InspectorCard: NSView {
    let stack = NSStackView()

    init(_ rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.045).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.05).cgColor
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for row in rows { stack.addArrangedSubview(row) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// "Label ———o——— 42%" row.
final class InspectorSliderRow: NSView {
    let slider: TrackingSlider
    private let valueLabel: NSTextField
    private let format: (Double) -> String

    init(title: String, min: Double, max: Double, value: Double, format: @escaping (Double) -> String,
         onBegin: @escaping () -> Void, onChange: @escaping (Double) -> Void, onEnd: @escaping () -> Void) {
        slider = TrackingSlider(min: min, max: max, value: value)
        valueLabel = VideoEditorStyle.label(format(value), size: 11.5, weight: .medium, color: VideoEditorStyle.textSecondary)
        self.format = format
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = VideoEditorStyle.label(title, size: 12)
        valueLabel.font = VideoEditorStyle.mono(11.5)
        valueLabel.alignment = .right
        slider.onBegin = onBegin
        slider.onEnd = onEnd
        slider.onChange = { [weak self] v in
            self?.valueLabel.stringValue = format(v)
            onChange(v)
        }
        slider.setAccessibilityLabel(title)
        addSubview(titleLabel)
        addSubview(slider)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func setValue(_ value: Double) {
        slider.doubleValue = value
        valueLabel.stringValue = format(value)
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// "Label ............. [switch]" row.
final class InspectorSwitchRow: NSView {
    let toggle = NSSwitch()
    private let onToggle: (Bool) -> Void

    init(title: String, subtitle: String? = nil, isOn: Bool, onToggle: @escaping (Bool) -> Void) {
        self.onToggle = onToggle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = VideoEditorStyle.label(title, size: 12)
        toggle.state = isOn ? .on : .off
        toggle.controlSize = .mini
        toggle.target = self
        toggle.action = #selector(changed)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.setAccessibilityLabel(title)
        addSubview(titleLabel)
        addSubview(toggle)
        var constraints = [
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ]
        if let subtitle {
            let sub = VideoEditorStyle.label(subtitle, size: 10.5, color: VideoEditorStyle.textTertiary)
            sub.lineBreakMode = .byWordWrapping
            sub.maximumNumberOfLines = 3
            sub.cell?.wraps = true
            sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(sub)
            constraints += [sub.leadingAnchor.constraint(equalTo: leadingAnchor),
                            sub.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -8),
                            sub.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
                            sub.bottomAnchor.constraint(equalTo: bottomAnchor)]
        } else {
            constraints += [titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)]
        }
        NSLayoutConstraint.activate(constraints)
    }

    @objc private func changed() { onToggle(toggle.state == .on) }

    required init?(coder: NSCoder) { fatalError() }
}

/// Title above a full-width segmented control.
final class InspectorSegmentRow: NSView {
    let control: NSSegmentedControl

    init(title: String?, labels: [String], symbols: [String?]? = nil, selected: Int, onSelect: @escaping (Int) -> Void) {
        control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        control.selectedSegment = selected
        control.segmentStyle = .rounded
        control.controlSize = .small
        control.segmentDistribution = .fillEqually
        control.translatesAutoresizingMaskIntoConstraints = false
        if let symbols {
            for (i, name) in symbols.enumerated() where name != nil {
                control.setImage(VideoEditorStyle.symbol(name!, size: 11), forSegment: i)
                control.setImageScaling(.scaleProportionallyDown, forSegment: i)
            }
        }
        let handler = SegmentHandler(onSelect)
        control.target = handler
        control.action = #selector(SegmentHandler.changed(_:))
        objc_setAssociatedObject(control, &SegmentHandler.key, handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        addSubview(control)
        var constraints = [
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        if let title {
            let label = VideoEditorStyle.label(title, size: 12)
            addSubview(label)
            constraints += [label.leadingAnchor.constraint(equalTo: leadingAnchor), label.topAnchor.constraint(equalTo: topAnchor),
                            control.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6)]
        } else {
            constraints += [control.topAnchor.constraint(equalTo: topAnchor)]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError() }
}

private final class SegmentHandler: NSObject {
    static var key: UInt8 = 0
    let handler: (Int) -> Void
    init(_ handler: @escaping (Int) -> Void) { self.handler = handler }
    @objc func changed(_ sender: NSSegmentedControl) { handler(sender.selectedSegment) }
}

/// Small color swatch that opens the app's color picker in a popover.
final class ColorSwatchButton: NSButton {
    var color: NSColor = .white { didSet { needsDisplay = true } }
    var onChange: ((NSColor) -> Void)?

    convenience init(color: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.init(frame: NSRect(x: 0, y: 0, width: 26, height: 20))
        self.color = color
        self.onChange = onChange
        isBordered = false
        title = ""
        target = self
        action = #selector(open)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        setAccessibilityLabel(L("Color"))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        // Checkerboard hint for transparent colors.
        NSColor(white: 0.35, alpha: 1).setFill()
        path.fill()
        color.setFill()
        path.fill()
        NSColor(white: 1, alpha: 0.25).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    @objc private func open() {
        let picker = ColorPickerView()
        picker.setColor(color.withAlphaComponent(1), opacity: color.alphaComponent)
        picker.onColorChanged = { [weak self] c in
            guard let self else { return }
            self.color = c.withAlphaComponent(self.color.alphaComponent)
            self.onChange?(self.color)
        }
        picker.onOpacityChanged = { [weak self] alpha in
            guard let self else { return }
            self.color = self.color.withAlphaComponent(alpha)
            self.onChange?(self.color)
        }
        PopoverHelper.show(picker, size: picker.frame.size, relativeTo: bounds, of: self, preferredEdge: .maxX)
    }
}

extension NSColor {
    convenience init(_ rgba: VideoRGBA) {
        self.init(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }

    var videoRGBA: VideoRGBA {
        let c = usingColorSpace(.sRGB) ?? self
        return VideoRGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent), Double(c.alphaComponent))
    }
}
