import Cocoa

/// Emoji picker for the stamp tool, inside an NSPopover: a search field over
/// every emoji the Mac can draw, the curated category tabs, and an "All" tab
/// (#473). Curated tabs fit without scrolling; All and search results scroll.
class EmojiPickerView: NSView, NSSearchFieldDelegate {

    var onSelectEmoji: ((String) -> Void)?

    private let cols = 8
    private let cellSize: CGFloat = 32
    private let padding: CGFloat = 8
    private let searchHeight: CGFloat = 24
    private let tabH: CGFloat = 30
    /// Rows shown at once for All and search results.
    private let scrollingRows = 7

    private var categories: [(String, [String])] { StampEmojis.categories }
    /// The index past the curated categories is the "All" tab.
    private var categoryIndex = 0
    var allIndex: Int { categories.count }

    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let grid = EmojiGridView()

    init() {
        super.init(frame: .zero)
        searchField.placeholderString = L("Search emoji")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 12)
        searchField.setAccessibilityLabel(L("Search emoji"))
        addSubview(searchField)

        grid.cols = cols
        grid.cellSize = cellSize
        grid.onSelect = { [weak self] emoji in self?.select(emoji) }
        scrollView.documentView = grid
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)
        showCategory(0)
    }

    required init?(coder: NSCoder) { fatalError() }

    var preferredSize: NSSize { frame.size }

    // MARK: - Content

    /// The emoji shown now: search results, the All tab, or a curated tab.
    var shownEmoji: [String] { grid.emojis }

    /// Shows a tab: a curated category, or `allIndex` for every emoji.
    func showCategory(_ index: Int) {
        categoryIndex = index
        if index == allIndex {
            setGrid(EmojiCatalog.all.map(\.emoji), visibleRows: scrollingRows)
        } else {
            setGrid(categories[index].1, visibleRows: nil)
        }
    }

    /// `visibleRows` caps the height (the rest scrolls); nil shows every row.
    private func setGrid(_ emojis: [String], visibleRows cap: Int?) {
        grid.emojis = emojis
        let rows = max(1, (emojis.count + cols - 1) / cols)
        let visibleRows = cap.map { min($0, rows) } ?? rows
        let gridWidth = CGFloat(cols) * cellSize + grid.inset * 2
        let gridHeight = CGFloat(visibleRows) * cellSize
        let width = padding * 2 + CGFloat(cols) * cellSize
        let height = padding + searchHeight + 6 + tabH + 4 + gridHeight + padding
        frame.size = NSSize(width: width, height: height)

        searchField.frame = NSRect(x: padding, y: height - padding - searchHeight,
                                   width: width - padding * 2, height: searchHeight)
        scrollView.frame = NSRect(x: padding - grid.inset, y: padding, width: gridWidth, height: gridHeight)
        grid.frame = NSRect(x: 0, y: 0, width: gridWidth, height: max(gridHeight, CGFloat(rows) * cellSize))
        grid.scroll(.zero)
        grid.needsDisplay = true
        needsDisplay = true
        if let popover = window?.value(forKey: "_popover") as? NSPopover {
            popover.contentSize = frame.size
        }
    }

    private func select(_ emoji: String) {
        onSelectEmoji?(emoji)
        PopoverHelper.dismiss()
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        applySearch(searchField.stringValue)
    }

    /// Shows the emoji whose names contain every word typed; an empty field
    /// returns to the tab that was showing.
    func applySearch(_ text: String) {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            showCategory(categoryIndex)
        } else {
            // Sized to the matches (at least two rows, so the popover doesn't
            // collapse while typing), scrolling past seven rows.
            let matches = EmojiCatalog.search(text).map(\.emoji)
            setGrid(matches, visibleRows: max(2, min(scrollingRows, (matches.count + cols - 1) / cols)))
        }
    }

    private var isSearching: Bool { !searchField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), let first = grid.emojis.first, isSearching {
            select(first)   // Return picks the first match
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)), searchField.stringValue.isEmpty {
            PopoverHelper.dismiss()   // Escape on an empty field closes the picker
            return true
        }
        return false
    }

    // MARK: - Tabs

    private var tabY: CGFloat { bounds.maxY - padding - searchHeight - 6 - tabH }

    private func tabRect(_ index: Int) -> NSRect {
        let tabW = (bounds.width - padding * 2) / CGFloat(categories.count + 1)
        return NSRect(x: padding + CGFloat(index) * tabW, y: tabY, width: tabW, height: tabH)
    }

    override func draw(_ dirtyRect: NSRect) {
        for index in 0...allIndex {
            let rect = tabRect(index)
            if index == categoryIndex && !isSearching {
                ToolbarLayout.accentColor.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
            }
            let isAll = index == allIndex
            let label = (isAll ? L("All") : categories[index].0) as NSString
            let attrs: [NSAttributedString.Key: Any] = isAll
                ? [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: ToolbarLayout.iconColor]
                : [.font: NSFont.systemFont(ofSize: 16)]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
        }
        ToolbarLayout.iconColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: NSRect(x: padding, y: tabY - 1, width: bounds.width - padding * 2, height: 0.5)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = (0...allIndex).first(where: { tabRect($0).contains(point) }) else { return }
        searchField.stringValue = ""
        showCategory(index)
    }
}

/// A grid of emoji cells, top to bottom, inside the picker's scroll view.
final class EmojiGridView: NSView {
    var emojis: [String] = [] { didSet { needsDisplay = true } }
    var cols = 8
    var cellSize: CGFloat = 32
    var onSelect: ((String) -> Void)?
    /// Room at the sides: a few emoji glyphs are wider than their cell, and
    /// the scroll view would clip them.
    let inset: CGFloat = 4

    override var isFlipped: Bool { true }

    func cellRect(_ index: Int) -> NSRect {
        NSRect(x: inset + CGFloat(index % cols) * cellSize, y: CGFloat(index / cols) * cellSize,
               width: cellSize, height: cellSize)
    }

    func index(at point: NSPoint) -> Int? {
        let x = point.x - inset
        guard x >= 0, point.y >= 0, x < CGFloat(cols) * cellSize else { return nil }
        let index = Int(point.y / cellSize) * cols + Int(x / cellSize)
        return emojis.indices.contains(index) ? index : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22)]
        // Only the rows in view: All holds well over a thousand emoji.
        let firstRow = max(0, Int(dirtyRect.minY / cellSize))
        let lastRow = Int(dirtyRect.maxY / cellSize)
        for row in firstRow...max(firstRow, lastRow) {
            for col in 0..<cols {
                let index = row * cols + col
                guard emojis.indices.contains(index) else { break }
                let rect = cellRect(index)
                let text = emojis[index] as NSString
                let size = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let index = index(at: convert(event.locationInWindow, from: nil)) {
            onSelect?(emojis[index])
        }
    }
}
