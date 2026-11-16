import Cocoa

/// "Set Scale" popover for the measure tool: give a measured line its real
/// length (90 mm, 3 1/2 in, 6' 2"...) so every measurement shows real units.
final class MeasureScalePopoverView: NSView, NSTextFieldDelegate {

    var onApply: ((MeasureCalibration) -> Void)?
    var onRemove: (() -> Void)?
    var onChangeUnit: ((MeasureUnit) -> Void)?
    var onDrawReference: (() -> Void)?

    private let referencePoints: Double?
    private let pixelsPerPoint: Double
    private let current: MeasureCalibration?
    private let lengthField = NSTextField()
    private let unitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let errorLabel = NSTextField(labelWithString: "")
    private let width: CGFloat = 330

    static let lastUnitKey = "measureScaleUnit"

    /// The unit last used to set a scale, else metric/imperial from the region.
    static var preferredUnit: MeasureUnit {
        if let raw = UserDefaults.standard.string(forKey: lastUnitKey), let unit = MeasureUnit(rawValue: raw) {
            return unit
        }
        let usesMetric = (Locale.current as NSLocale).object(forKey: .usesMetricSystem) as? Bool ?? true
        return usesMetric ? .millimeters : .inches
    }

    static func unitTitle(_ unit: MeasureUnit) -> String {
        switch unit {
        case .millimeters: return L("Millimeters (mm)")
        case .centimeters: return L("Centimeters (cm)")
        case .meters: return L("Meters (m)")
        case .inches: return L("Inches (in)")
        case .feet: return L("Feet (ft)")
        }
    }

    init(referencePoints: Double?, pixelsPerPoint: Double, current: MeasureCalibration?) {
        self.referencePoints = referencePoints.flatMap { $0 >= 1 ? $0 : nil }
        self.pixelsPerPoint = pixelsPerPoint.isFinite && pixelsPerPoint > 0 ? pixelsPerPoint : 1
        self.current = current
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: width),
        ])
        let contentWidth = width - 28

        let title = NSTextField(labelWithString: L("Measure Scale"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(title)

        if let referencePoints {
            let pixels = Int((referencePoints * pixelsPerPoint).rounded())
            stack.addArrangedSubview(wrappingLabel(
                String(format: L("This line is %d px long. How long is it in real life?"), pixels),
                width: contentWidth))

            lengthField.placeholderString = L("e.g. 90 mm or 3 1/2 in")
            lengthField.delegate = self
            lengthField.target = self
            lengthField.action = #selector(applyClicked)
            lengthField.translatesAutoresizingMaskIntoConstraints = false
            lengthField.widthAnchor.constraint(equalToConstant: 165).isActive = true
            if let current {
                // Prefill with what the line measures now, so the user only edits.
                lengthField.stringValue = MeasureLengthFormatter.string(
                    for: current.length(ofPoints: referencePoints), unit: current.unit)
            }

            for unit in MeasureUnit.allCases {
                unitPopup.addItem(withTitle: Self.unitTitle(unit))
                unitPopup.lastItem?.representedObject = unit.rawValue
            }
            selectUnit(current?.unit ?? Self.preferredUnit)

            let row = NSStackView(views: [lengthField, unitPopup])
            row.orientation = .horizontal
            row.spacing = 6
            stack.addArrangedSubview(row)

            // Always laid out (blank until needed) so showing an error can't
            // grow the content past the popover's fixed size.
            errorLabel.font = .systemFont(ofSize: 11)
            errorLabel.textColor = .systemRed
            errorLabel.stringValue = " "
            errorLabel.lineBreakMode = .byTruncatingTail
            errorLabel.translatesAutoresizingMaskIntoConstraints = false
            errorLabel.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            stack.addArrangedSubview(errorLabel)

            let apply = NSButton(title: L("Set Scale"), target: self, action: #selector(applyClicked))
            apply.keyEquivalent = "\r"
            apply.bezelStyle = .rounded
            stack.addArrangedSubview(apply)
        } else {
            stack.addArrangedSubview(wrappingLabel(
                L("Draw or select a measure line along something whose length you know, then enter that length."),
                width: contentWidth))
            let draw = NSButton(title: L("Draw Reference Line"), target: self, action: #selector(drawReferenceClicked))
            draw.bezelStyle = .rounded
            if current == nil { draw.keyEquivalent = "\r" }
            stack.addArrangedSubview(draw)
        }

        if let current {
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            stack.addArrangedSubview(separator)

            let perUnitPixels = current.pointsPerUnit * pixelsPerPoint
            let digits = perUnitPixels >= 100 ? 0 : (perUnitPixels >= 10 ? 1 : 2)
            stack.addArrangedSubview(wrappingLabel(
                String(format: L("Current scale: 1 %@ = %@ px"), current.unit.symbol,
                       MeasureLengthFormatter.decimal(perUnitPixels, digits: digits)),
                width: contentWidth))

            let showIn = NSTextField(labelWithString: L("Show lengths in"))
            let unitChoice = NSPopUpButton(frame: .zero, pullsDown: false)
            for unit in MeasureUnit.allCases {
                unitChoice.addItem(withTitle: Self.unitTitle(unit))
                unitChoice.lastItem?.representedObject = unit.rawValue
            }
            if let index = MeasureUnit.allCases.firstIndex(of: current.unit) { unitChoice.selectItem(at: index) }
            unitChoice.target = self
            unitChoice.action = #selector(displayUnitChanged(_:))
            let unitRow = NSStackView(views: [showIn, unitChoice])
            unitRow.orientation = .horizontal
            unitRow.spacing = 6
            stack.addArrangedSubview(unitRow)

            let remove = NSButton(title: L("Remove Scale"), target: self, action: #selector(removeClicked))
            remove.bezelStyle = .rounded
            stack.addArrangedSubview(remove)
        }

        let note = wrappingLabel(
            L("Real-world lengths are estimates. They are only reliable for things in the same plane as the reference line."),
            width: contentWidth)
        note.font = .systemFont(ofSize: 10)
        note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)

        layoutSubtreeIfNeeded()
        frame.size = fittingSize
    }

    private func wrappingLabel(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.preferredMaxLayoutWidth = width
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard referencePoints != nil, let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self.lengthField)
            self.lengthField.currentEditor()?.selectAll(nil)
        }
    }

    private var selectedUnit: MeasureUnit {
        (unitPopup.selectedItem?.representedObject as? String).flatMap(MeasureUnit.init(rawValue:))
            ?? Self.preferredUnit
    }

    private func selectUnit(_ unit: MeasureUnit) {
        if let index = MeasureUnit.allCases.firstIndex(of: unit) { unitPopup.selectItem(at: index) }
    }

    /// A unit typed into the field ("90 mm") is mirrored in the menu.
    func controlTextDidChange(_ obj: Notification) {
        errorLabel.stringValue = " "
        if let parsed = MeasureLengthParser.parse(lengthField.stringValue, defaultUnit: selectedUnit) {
            selectUnit(parsed.unit)
        }
    }

    @objc private func applyClicked() {
        guard let referencePoints else { return }
        guard let length = MeasureLengthParser.parse(lengthField.stringValue, defaultUnit: selectedUnit),
              let calibration = MeasureCalibration(referencePoints: referencePoints, length: length) else {
            errorLabel.stringValue = L("Enter a length, like 90 mm, 3.5 in or 3 1/2 in.")
            NSSound.beep()
            return
        }
        UserDefaults.standard.set(length.unit.rawValue, forKey: Self.lastUnitKey)
        onApply?(calibration)
    }

    @objc private func displayUnitChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let unit = MeasureUnit(rawValue: raw) else { return }
        UserDefaults.standard.set(unit.rawValue, forKey: Self.lastUnitKey)
        onChangeUnit?(unit)
    }

    @objc private func removeClicked() { onRemove?() }
    @objc private func drawReferenceClicked() { onDrawReference?() }
}
