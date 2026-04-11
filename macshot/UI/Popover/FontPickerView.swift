import Cocoa

/// Font picker view with popular fonts at top, separator, then all system fonts.
/// Each font name is rendered in its own typeface. Scrollable with overlay scroller.
class FontPickerView: NSScrollView {

    var onSelect: ((String) -> Void)?
    private var selectedFamily: String = "System"

    private static let popularFonts = [
        "System",
        "Helvetica Neue",
        "Arial",
        "Georgia",
        "Times New Roman",
        "Courier New",
        "Menlo",
        "SF Mono",
        "Futura",
        "Avenir Next",
        "Gill Sans",
        "Palatino",
        "Verdana",
        "Trebuchet MS",
        "American Typewriter",
        "Marker Felt",
        "Chalkboard SE",
        "Comic Sans MS",
    ]

    private let rowHeight: CGFloat = 26
    private let fontSize: CGFloat = 13

    init(selectedFamily: String) {
        self.selectedFamily = selectedFamily
        super.init(frame: NSRect(x: 0, y: 0, width: 210, height: 350))

        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = false
        scrollerStyle = .overlay
        drawsBackground = false
        borderType = .noBorder

        let docView = FontListDocView(picker: self)
        documentView = docView
        layoutDocView()
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredSize: NSSize { NSSize(width: 210, height: 350) }

    private func allFonts() -> [(family: String, isPopular: Bool, isSeparator: Bool)] {
        var result: [(String, Bool, Bool)] = []

        let available = Set(NSFontManager.shared.availableFontFamilies)
        for family in Self.popularFonts {
            if family == "System" || available.contains(family) {
                result.append((family, true, false))
            }
        }

        result.append(("", false, true))

        let popularSet = Set(Self.popularFonts)
        for family in NSFontManager.shared.availableFontFamilies.sorted() {
            if !popularSet.contains(family) {
                result.append((family, false, false))
            }
        }

        return result
    }

    private func layoutDocView() {
        let fonts = allFonts()
        let totalH = CGFloat(fonts.count) * rowHeight + 8
        documentView?.frame = NSRect(x: 0, y: 0, width: frame.width, height: totalH)
    }

    /// Scroll to top so popular fonts are visible first.
    func scrollToTop() {
        guard let docView = documentView else { return }
        let topPoint = NSPoint(x: 0, y: docView.frame.height - contentView.bounds.height)
        contentView.scroll(to: topPoint)
        reflectScrolledClipView(contentView)
    }

    fileprivate func drawContent(in dirtyRect: NSRect) {
        let fonts = allFonts()
        let totalH = CGFloat(fonts.count) * rowHeight + 8

        for (i, entry) in fonts.enumerated() {
            let y = totalH - CGFloat(i + 1) * rowHeight - 4
            let rowRect = NSRect(x: 0, y: y, width: frame.width, height: rowHeight)

            guard rowRect.intersects(dirtyRect) else { continue }

            if entry.isSeparator {
                ToolbarLayout.iconColor.withAlphaComponent(0.1).setFill()
                NSRect(x: 8, y: rowRect.midY - 0.5, width: frame.width - 16, height: 1).fill()
                continue
            }

            let isSelected = entry.family == selectedFamily

            if isSelected {
                ToolbarLayout.accentColor.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: rowRect.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
            }

            // Checkmark on the left for selected
            var textX: CGFloat = 10
            if isSelected {
                let checkAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: ToolbarLayout.accentColor,
                ]
                let checkSize = ("✓" as NSString).size(withAttributes: checkAttrs)
                ("✓" as NSString).draw(
                    at: NSPoint(x: 8, y: rowRect.midY - checkSize.height / 2),
                    withAttributes: checkAttrs)
                textX = 24
            }

            // Render font name in its own typeface
            let displayFont: NSFont
            if entry.family == "System" {
                displayFont = NSFont.systemFont(ofSize: fontSize)
            } else {
                displayFont = NSFont(name: entry.family, size: fontSize)
                    ?? NSFont.systemFont(ofSize: fontSize)
            }

            let attrs: [NSAttributedString.Key: Any] = [
                .font: displayFont,
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(isSelected ? 1.0 : 0.8),
            ]
            let displayName = entry.family == "System" ? "System (SF Pro)" : entry.family
            let str = displayName as NSString
            let strSize = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: textX, y: rowRect.midY - strSize.height / 2), withAttributes: attrs)
        }
    }

    fileprivate func handleClick(at point: NSPoint) {
        guard let docView = documentView else { return }
        let docPoint = contentView.convert(point, to: docView)
        let fonts = allFonts()
        let totalH = CGFloat(fonts.count) * rowHeight + 8

        for (i, entry) in fonts.enumerated() {
            if entry.isSeparator { continue }
            let y = totalH - CGFloat(i + 1) * rowHeight - 4
            let rowRect = NSRect(x: 0, y: y, width: frame.width, height: rowHeight)
            if rowRect.contains(docPoint) {
                selectedFamily = entry.family
                onSelect?(entry.family)
                documentView?.needsDisplay = true
                return
            }
        }
    }
}

/// Document view that draws the font list and handles clicks.
private class FontListDocView: NSView {
    weak var picker: FontPickerView?

    init(picker: FontPickerView) {
        self.picker = picker
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        picker?.drawContent(in: dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        guard let scrollView = picker else { return }
        let scrollPoint = scrollView.contentView.convert(event.locationInWindow, from: nil)
        scrollView.handleClick(at: scrollPoint)
    }
}
