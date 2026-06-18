import Cocoa

/// The selection resolution control shown over a capture/recording selection:
///   [ W field ] × [ H field ]  [▾ presets]
/// Two real, separately-editable number fields with a non-editable "×" between
/// them (so the separator can't be deleted), plus a presets dropdown button for
/// aspect ratios and common resolutions. Replaces the old drawn "W × H" badge.
final class ResolutionBoxView: NSView, NSTextFieldDelegate, ChromeContent {

    enum EditedDimension {
        case width
        case height
        case both
    }

    /// Called when the user commits new W/H values (Enter or focus loss).
    var onCommit: ((_ w: Int, _ h: Int, _ edited: EditedDimension) -> Void)?
    /// Called after Enter commits so the owning overlay can reclaim keyboard
    /// focus from the field editor/panel.
    var onFinishEditing: (() -> Void)?
    /// Called when the presets button is clicked; passes the button for anchoring.
    var onPresets: ((_ anchor: NSView) -> Void)?

    private let widthField = ResolutionNumberField()
    private let heightField = ResolutionNumberField()
    private let timesLabel = CenteredGlyphView(glyph: "\u{00D7}")
    private let presetsButton = NSButton()

    private let fieldW: CGFloat = 56
    private let fieldH: CGFloat = 22
    private let gap: CGFloat = 4
    private let pad: CGFloat = 6
    private let btnW: CGFloat = 30
    private var suppressNextEndEditingCommit = false

    /// When hosted in a Liquid Glass chrome panel, the panel's glass provides the
    /// background, so the box clears its own solid layer fill (ChromeContent).
    var hostedInGlassPanel = false {
        didSet { layer?.backgroundColor = hostedInGlassPanel ? NSColor.clear.cgColor : ToolbarLayout.bgColor.cgColor }
    }

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
        f.isEditable = true
        f.isSelectable = true
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

    /// Update displayed dimensions from the selection. Skips a field only while it
    /// is ACTIVELY being edited (has a field editor) so we don't clobber typing —
    /// previously the guard also skipped when nothing was focused, leaving fields
    /// blank.
    func setDimensions(w: Int, h: Int) {
        if !isEditing(widthField) {
            widthField.stringValue = "\(w)"
        }
        if !isEditing(heightField) {
            heightField.stringValue = "\(h)"
        }
    }

    private func isEditing(_ field: NSTextField) -> Bool {
        // A field is being edited only if it has an active field editor that is
        // also the window's first responder.
        guard let editor = field.currentEditor() else { return false }
        return field.window?.firstResponder === editor
    }

    /// True while either W/H field is actively being edited. The owning overlay
    /// uses this to avoid re-presenting/re-placing the glass panel mid-edit,
    /// which would disturb the field editor and make typing beep.
    var isActivelyEditing: Bool {
        isEditing(widthField) || isEditing(heightField)
    }

    /// Reflect the active ratio/resolution preset in the presets button.
    func setActivePresetLabel(_ label: String?) {
        presetsButton.toolTip = label.map { "\(L("Presets")) — \($0)" } ?? L("Aspect ratio & resolution presets")
        presetsButton.contentTintColor = label == nil ? ToolbarLayout.iconColor : ToolbarLayout.accentColor
    }

    @objc private func presetsClicked() {
        onPresets?(presetsButton)
    }

    private func editedDimension(for control: Any?) -> EditedDimension {
        guard let control = control as? NSControl else { return .both }
        if control === widthField { return .width }
        if control === heightField { return .height }
        return .both
    }

    private func commit(edited: EditedDimension) {
        guard let w = Int(widthField.stringValue), let h = Int(heightField.stringValue),
              w > 0, h > 0 else { return }
        onCommit?(w, h, edited)
    }

    private func finishEditing() {
        window?.makeFirstResponder(nil)
        DispatchQueue.main.async { [weak self] in
            self?.onFinishEditing?()
        }
    }

    // Enter or Escape in either field commits and returns focus to the overlay.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:))
            || selector == #selector(NSResponder.cancelOperation(_:)) {
            suppressNextEndEditingCommit = true
            commit(edited: editedDimension(for: control))
            finishEditing()
            return true
        }
        return false
    }

    // Commit on focus loss too.
    func controlTextDidEndEditing(_ obj: Notification) {
        if suppressNextEndEditingCommit {
            suppressNextEndEditingCommit = false
            return
        }
        commit(edited: editedDimension(for: obj.object))
    }

    override func resetCursorRects() {
        // Fields show the I-beam (editable affordance); the button shows arrow.
        addCursorRect(widthField.frame, cursor: .iBeam)
        addCursorRect(heightField.frame, cursor: .iBeam)
        addCursorRect(presetsButton.frame, cursor: .arrow)
    }
}

/// A number field may enter editing from a direct mouse click, without becoming
/// a stray first responder during overlay keyboard handling.
private final class ResolutionNumberField: NSTextField, PanelKeyRequestingView {
    private var acceptingMouseFocus = false
    var requestsPanelKeyForMouseDown: Bool { true }

    // The field lives inside a borderless, non-activating glass child panel. For
    // AppKit to install a field editor there, the field must advertise that it
    // needs the panel to become key — otherwise clicks focus it inconsistently
    // and typing beeps.
    override var needsPanelToBecomeKey: Bool { true }

    override var acceptsFirstResponder: Bool {
        acceptingMouseFocus || currentEditor() != nil
    }

    override func becomeFirstResponder() -> Bool {
        guard acceptingMouseFocus || currentEditor() != nil else { return false }
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        acceptingMouseFocus = true
        defer { acceptingMouseFocus = false }
        super.mouseDown(with: event)
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
