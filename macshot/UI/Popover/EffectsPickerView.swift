import Cocoa

/// Popover view for image effects: preset filter swatches + adjustment sliders.
class EffectsPickerView: NSView {

    var onConfigChanged: ((ImageEffectsConfig) -> Void)?

    private var config: ImageEffectsConfig
    private let presets = ImageEffectPreset.allCases

    // Layout constants
    private let padding: CGFloat = 10
    private let swatchSize: CGFloat = 52
    private let swatchGap: CGFloat = 6
    private let cols = 4
    private let sliderLabelWidth: CGFloat = 72
    private let sliderWidth: CGFloat = 150
    private let sliderRowHeight: CGFloat = 24
    private let sectionGap: CGFloat = 10

    // Cached swatch images
    private var swatchImages: [NSImage] = []

    // Slider subviews
    private var brightnessSlider: NSSlider!
    private var contrastSlider: NSSlider!
    private var saturationSlider: NSSlider!
    private var sharpnessSlider: NSSlider!

    init(config: ImageEffectsConfig) {
        self.config = config
        super.init(frame: .zero)
        setupSwatches()
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredSize: NSSize { frame.size }

    private func setupSwatches() {
        swatchImages = presets.map { ImageEffects.presetSwatch($0, size: swatchSize) }
    }

    private func setupUI() {
        let rows = (presets.count + cols - 1) / cols
        let presetGridW = padding * 2 + CGFloat(cols) * swatchSize + CGFloat(cols - 1) * swatchGap
        let presetGridH = CGFloat(rows) * swatchSize + CGFloat(max(0, rows - 1)) * swatchGap

        let contentW = max(presetGridW, padding * 2 + sliderLabelWidth + sliderWidth + 8)

        // Compute total height (bottom-up in AppKit coordinates)
        let resetBtnH: CGFloat = 22
        let separatorH: CGFloat = 1
        let labelH: CGFloat = 14
        let sliderSectionH = CGFloat(4) * sliderRowHeight + 4 // 4 sliders + spacing

        let totalH = padding + labelH + 4 + presetGridH + sectionGap
            + separatorH + sectionGap
            + labelH + 4 + sliderSectionH + 8
            + resetBtnH + padding

        frame = NSRect(x: 0, y: 0, width: contentW, height: totalH)

        // Build subviews from top to bottom (high Y = top in AppKit)
        var y = totalH - padding

        // "Presets" label
        y -= labelH
        let presetsLabel = makeLabel(L("Presets"), at: NSPoint(x: padding, y: y))
        addSubview(presetsLabel)
        y -= 4

        // Preset swatches are drawn in draw(_:), skip height
        y -= presetGridH
        // Store the Y origin of the swatch grid for hit testing
        swatchGridOriginY = y
        y -= sectionGap

        // Separator
        y -= separatorH
        let sep = NSBox(frame: NSRect(x: padding, y: y, width: contentW - padding * 2, height: separatorH))
        sep.boxType = .separator
        addSubview(sep)
        y -= sectionGap

        // "Adjustments" label
        y -= labelH
        let adjLabel = makeLabel(L("Adjustments"), at: NSPoint(x: padding, y: y))
        addSubview(adjLabel)
        y -= 6

        // Sliders
        brightnessSlider = addSliderRow(label: L("Brightness"), y: &y, min: -0.5, max: 0.5, value: Double(config.brightness), action: #selector(brightnessChanged(_:)))
        contrastSlider = addSliderRow(label: L("Contrast"), y: &y, min: 0.5, max: 2.0, value: Double(config.contrast), action: #selector(contrastChanged(_:)))
        saturationSlider = addSliderRow(label: L("Saturation"), y: &y, min: 0.0, max: 2.0, value: Double(config.saturation), action: #selector(saturationChanged(_:)))
        sharpnessSlider = addSliderRow(label: L("Sharpness"), y: &y, min: 0.0, max: 2.0, value: Double(config.sharpness), action: #selector(sharpnessChanged(_:)))

        y -= 8

        // Reset button
        y -= resetBtnH
        let resetBtn = NSButton(frame: NSRect(x: contentW - padding - 60, y: y, width: 60, height: resetBtnH))
        resetBtn.title = L("Reset")
        resetBtn.bezelStyle = .recessed
        resetBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        resetBtn.target = self
        resetBtn.action = #selector(resetClicked)
        addSubview(resetBtn)

        // Adjust frame to actual content
        frame.size.height = totalH
    }

    private var swatchGridOriginY: CGFloat = 0

    private func makeLabel(_ text: String, at origin: NSPoint) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame.origin = origin
        label.sizeToFit()
        return label
    }

    @discardableResult
    private func addSliderRow(label: String, y: inout CGFloat, min: Double, max: Double, value: Double, action: Selector) -> NSSlider {
        y -= sliderRowHeight

        let lbl = NSTextField(labelWithString: label)
        lbl.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        lbl.textColor = .labelColor
        lbl.frame = NSRect(x: padding, y: y + 3, width: sliderLabelWidth, height: 16)
        addSubview(lbl)

        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
        slider.controlSize = .small
        slider.frame = NSRect(x: padding + sliderLabelWidth, y: y + 2, width: sliderWidth, height: 20)
        slider.isContinuous = true
        addSubview(slider)

        return slider
    }

    // MARK: - Drawing (preset swatches)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rows = (presets.count + cols - 1) / cols
        let gridH = CGFloat(rows) * swatchSize + CGFloat(max(0, rows - 1)) * swatchGap

        for (i, preset) in presets.enumerated() {
            let col = i % cols
            let row = i / cols
            let sx = padding + CGFloat(col) * (swatchSize + swatchGap)
            let sy = swatchGridOriginY + gridH - swatchSize - CGFloat(row) * (swatchSize + swatchGap)
            let sr = NSRect(x: sx, y: sy, width: swatchSize, height: swatchSize)

            let path = NSBezierPath(roundedRect: sr, xRadius: 6, yRadius: 6)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            if i < swatchImages.count {
                swatchImages[i].draw(in: sr, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            NSGraphicsContext.restoreGraphicsState()

            // Label
            let name = preset.displayName
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let textSize = (name as NSString).size(withAttributes: attrs)
            let textX = sr.midX - textSize.width / 2
            let textY = sr.minY + 4
            let shadowAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
                .foregroundColor: NSColor.black.withAlphaComponent(0.6),
            ]
            (name as NSString).draw(at: NSPoint(x: textX + 0.5, y: textY - 0.5), withAttributes: shadowAttrs)
            (name as NSString).draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)

            // Selection ring
            if preset == config.preset {
                ToolbarLayout.accentColor.setStroke()
                let ring = NSBezierPath(roundedRect: sr.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7)
                ring.lineWidth = 2
                ring.stroke()
            }
        }
    }

    // MARK: - Mouse handling (swatch selection)

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let rows = (presets.count + cols - 1) / cols
        let gridH = CGFloat(rows) * swatchSize + CGFloat(max(0, rows - 1)) * swatchGap

        for (i, _) in presets.enumerated() {
            let col = i % cols
            let row = i / cols
            let sx = padding + CGFloat(col) * (swatchSize + swatchGap)
            let sy = swatchGridOriginY + gridH - swatchSize - CGFloat(row) * (swatchSize + swatchGap)
            let sr = NSRect(x: sx, y: sy, width: swatchSize, height: swatchSize)

            if sr.insetBy(dx: -2, dy: -2).contains(pt) {
                config.preset = presets[i]

                // Vivid sets sliders to specific values
                if presets[i] == .vivid {
                    config.brightness = 0
                    config.contrast = 1.2
                    config.saturation = 1.5
                    config.sharpness = 0
                    updateSliders()
                } else if presets[i] == .none {
                    config.brightness = 0
                    config.contrast = 1.0
                    config.saturation = 1.0
                    config.sharpness = 0
                    updateSliders()
                }

                needsDisplay = true
                onConfigChanged?(config)
                return
            }
        }
    }

    // MARK: - Slider actions

    @objc private func brightnessChanged(_ sender: NSSlider) {
        config.brightness = Float(sender.doubleValue)
        clearPresetIfManual()
        onConfigChanged?(config)
    }

    @objc private func contrastChanged(_ sender: NSSlider) {
        config.contrast = Float(sender.doubleValue)
        clearPresetIfManual()
        onConfigChanged?(config)
    }

    @objc private func saturationChanged(_ sender: NSSlider) {
        config.saturation = Float(sender.doubleValue)
        clearPresetIfManual()
        onConfigChanged?(config)
    }

    @objc private func sharpnessChanged(_ sender: NSSlider) {
        config.sharpness = Float(sender.doubleValue)
        clearPresetIfManual()
        onConfigChanged?(config)
    }

    @objc private func resetClicked() {
        config = ImageEffectsConfig()
        updateSliders()
        needsDisplay = true
        onConfigChanged?(config)
    }

    private func clearPresetIfManual() {
        if config.preset != .none {
            config.preset = .none
            needsDisplay = true
        }
    }

    private func updateSliders() {
        brightnessSlider.doubleValue = Double(config.brightness)
        contrastSlider.doubleValue = Double(config.contrast)
        saturationSlider.doubleValue = Double(config.saturation)
        sharpnessSlider.doubleValue = Double(config.sharpness)
    }
}
