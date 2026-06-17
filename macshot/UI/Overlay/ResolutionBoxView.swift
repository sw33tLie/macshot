import Cocoa

/// The selection resolution control shown over a capture/recording selection:
///   [ W field ] × [ H field ]  [▾ presets]
/// Two real, separately-editable number fields with a non-editable "×" between
/// them (so the separator can't be deleted), plus a presets dropdown button for
/// aspect ratios and common resolutions. Replaces the old drawn "W × H" badge.
final class ResolutionBoxView: NSView, NSTextFieldDelegate {

    /// Called when the user commits new W/H values (Enter or focus loss).
    var onCommit: ((_ w: Int, _ h: Int) -> Void)?
    /// Called when the presets button is clicked; passes the button for anchoring.
    var onPresets: ((_ anchor: NSView) -> Void)?

    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let timesLabel = CenteredGlyphView(glyph: "\u{00D7}")
    private let presetsButton = NSButton()

    private let fieldW: CGFloat = 56
    private let fieldH: CGFloat = 22
    private let gap: CGFloat = 4
    private let pad: CGFloat = 6
    private let btnW: CGFloat = 30

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = ToolbarLayout.bgColor.cgColor
        appearance = ToolbarLayout.appearance

        configureField(widthField)
        configureField(heightField)

        timesLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        timesLabel.color = ToolbarLayout.iconColor.withAlphaComponent(0.55)
        addSubview(timesLabel)

        presetsButton.bezelStyle = .regularSquare
        presetsButton.isBordered = false
        presetsButton.imagePosition = .imageOnly
        presetsButton.image = NSImage(systemSymbolName: "aspectratio", accessibilityDescription: L("Aspect ratio & resolution presets"))
            ?? NSImage(systemSymbolName: "rectangle.ratio.16.to.9", accessibilityDescription: nil)
        presetsButton.contentTintColor = ToolbarLayout.iconColor
        presetsButton.target = self
        presetsButton.action = #selector(presetsClicked)
        presetsButton.toolTip = L("Aspect ratio & resolution presets")
        addSubview(presetsButton)

        layoutPieces()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureField(_ f: NSTextField) {
        f.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        f.alignment = .center
        f.textColor = ToolbarLayout.iconColor
        f.delegate = self
        f.isBezeled = true
        f.bezelStyle = .roundedBezel
        f.drawsBackground = true
        f.focusRingType = .none
        f.formatter = ResolutionBoxView.intFormatter()
        addSubview(f)
    }

    private static func intFormatter() -> NumberFormatter {
        let nf = NumberFormatter()
        nf.numberStyle = .none
        nf.minimum = 1
        nf.maximum = 100000
        nf.allowsFloats = false
        return nf
    }

    private var timesWidth: CGFloat { max(12, timesLabel.intrinsicContentSize.width) }

    /// Natural size of the control.
    var preferredSize: NSSize {
        NSSize(width: pad + fieldW + gap + timesWidth + gap + fieldW + gap + btnW + pad,
               height: fieldH + pad * 2)
    }

    /// X (in this view's coords) of the midpoint of the W↔H pair — i.e. the center
    /// of the "×". OverlayView aligns this with the selection center so the box
    /// reads as centered on the dimensions, ignoring the trailing presets button.
    var dimensionsCenterX: CGFloat {
        pad + fieldW + gap + timesWidth / 2
    }

    private func layoutPieces() {
        let h = fieldH + pad * 2
        var x = pad
        let y = pad
        widthField.frame = NSRect(x: x, y: y, width: fieldW, height: fieldH)
        x += fieldW + gap
        // Vertically center the "×" against the fields' text. A label is
        // bottom-baseline; give it the full field height and center its glyph by
        // matching the field font's vertical metrics.
        timesLabel.frame = NSRect(x: x, y: y, width: timesWidth, height: fieldH)
        x += timesWidth + gap
        heightField.frame = NSRect(x: x, y: y, width: fieldW, height: fieldH)
        x += fieldW + gap
        presetsButton.frame = NSRect(x: x, y: y, width: btnW, height: fieldH)
        x += btnW + pad
        frame.size = NSSize(width: x, height: h)
    }

    /// Update displayed dimensions from the selection (skips fields being edited).
    func setDimensions(w: Int, h: Int) {
        if window?.firstResponder !== widthField.currentEditor() {
            widthField.stringValue = "\(w)"
        }
        if window?.firstResponder !== heightField.currentEditor() {
            heightField.stringValue = "\(h)"
        }
    }

    /// Update the presets button label/icon to reflect the active ratio (or none).
    func setActiveRatioLabel(_ label: String?) {
        presetsButton.toolTip = label.map { "\(L("Presets")) — \($0)" } ?? L("Aspect ratio & resolution presets")
    }

    @objc private func presetsClicked() {
        commit()  // flush any in-progress edit first
        onPresets?(presetsButton)
    }

    private func commit() {
        guard let w = Int(widthField.stringValue), let h = Int(heightField.stringValue),
              w > 0, h > 0 else { return }
        onCommit?(w, h)
    }

    // Enter in either field commits.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commit()
            window?.makeFirstResponder(superview)  // resign so it's clear edit ended
            return true
        }
        return false
    }

    // Commit on focus loss too.
    func controlTextDidEndEditing(_ obj: Notification) {
        commit()
    }

    override func resetCursorRects() {
        // Fields show the I-beam (editable affordance); the button shows arrow.
        addCursorRect(widthField.frame, cursor: .iBeam)
        addCursorRect(heightField.frame, cursor: .iBeam)
        addCursorRect(presetsButton.frame, cursor: .arrow)
    }
}

/// Draws a single glyph centered both horizontally and vertically — used for the
/// "×" so it lines up with the bezeled number fields (an NSTextField label is
/// baseline-anchored and sits too high/low).
private final class CenteredGlyphView: NSView {
    private let glyph: String
    var font: NSFont = .systemFont(ofSize: 13) { didSet { needsDisplay = true } }
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    init(glyph: String) {
        self.glyph = glyph
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = (glyph as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(s.width), height: ceil(s.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = (glyph as NSString).size(withAttributes: attrs)
        let p = NSPoint(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2)
        (glyph as NSString).draw(at: p, withAttributes: attrs)
    }
}
