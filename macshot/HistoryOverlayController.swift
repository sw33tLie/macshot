import Cocoa

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Full-screen overlay showing recent screenshot history as a card grid.
/// Click a card to copy it to clipboard. ESC or click outside to dismiss.
final class HistoryOverlayController {

    private var window: NSWindow?
    private var contentView: HistoryOverlayView?
    var onDismiss: (() -> Void)?

    func show() {
        guard let screen = NSScreen.main else { return }

        let win = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.level = .statusBar + 1
        win.isOpaque = false
        win.backgroundColor = .clear
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false

        let view = HistoryOverlayView(frame: screen.frame)
        view.controller = self
        win.contentView = view
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
        self.contentView = view
    }

    func dismiss() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        contentView = nil
        onDismiss?()
    }

    func copyAndDismiss(index: Int) {
        ScreenshotHistory.shared.copyEntry(at: index)
        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        if soundEnabled {
            AppDelegate.captureSound?.stop()
            AppDelegate.captureSound?.play()
        }
        dismiss()
    }
}

// MARK: - HistoryOverlayView

private final class HistoryOverlayView: NSView {

    weak var controller: HistoryOverlayController?
    private var cardRects: [NSRect] = []
    private var cardImages: [NSImage?] = []
    private var hoveredIndex: Int = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        loadImages()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    private func loadImages() {
        let entries = ScreenshotHistory.shared.entries
        cardImages = entries.map { entry in
            ScreenshotHistory.shared.loadImage(for: entry)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Dark translucent background
        NSColor(white: 0.0, alpha: 0.75).setFill()
        NSBezierPath(rect: bounds).fill()

        let entries = ScreenshotHistory.shared.entries
        guard !entries.isEmpty else {
            drawEmptyState()
            return
        }

        // Title
        let titleStr = "Recent Captures" as NSString
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let titleSize = titleStr.size(withAttributes: titleAttrs)
        titleStr.draw(at: NSPoint(x: bounds.midX - titleSize.width / 2,
                                   y: bounds.maxY - 60),
                      withAttributes: titleAttrs)

        // Subtitle
        let subStr = "Click to copy  ·  ESC to close" as NSString
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.5),
        ]
        let subSize = subStr.size(withAttributes: subAttrs)
        subStr.draw(at: NSPoint(x: bounds.midX - subSize.width / 2,
                                 y: bounds.maxY - 85),
                    withAttributes: subAttrs)

        // Layout cards in a grid
        let count = entries.count
        let maxCols = min(count, 4)
        let rows = (count + maxCols - 1) / maxCols

        let padding: CGFloat = 40
        let gap: CGFloat = 20
        let topOffset: CGFloat = 110
        let availW = bounds.width - padding * 2
        let availH = bounds.height - topOffset - padding

        let cardW = (availW - CGFloat(maxCols - 1) * gap) / CGFloat(maxCols)
        let cardH = (availH - CGFloat(rows - 1) * gap) / CGFloat(rows)

        let gridW = CGFloat(maxCols) * cardW + CGFloat(maxCols - 1) * gap
        let gridH = CGFloat(rows) * cardH + CGFloat(rows - 1) * gap
        let gridX = bounds.midX - gridW / 2
        let gridY = bounds.maxY - topOffset - (availH - gridH) / 2 - gridH

        cardRects = []

        for (i, entry) in entries.enumerated() {
            let col = i % maxCols
            let row = i / maxCols
            let x = gridX + CGFloat(col) * (cardW + gap)
            let y = gridY + gridH - CGFloat(row + 1) * cardH - CGFloat(row) * gap
            let cardRect = NSRect(x: x, y: y, width: cardW, height: cardH)
            cardRects.append(cardRect)

            let isHovered = (i == hoveredIndex)

            // Card background
            let bgColor = isHovered ? NSColor.white.withAlphaComponent(0.15) : NSColor.white.withAlphaComponent(0.06)
            bgColor.setFill()
            NSBezierPath(roundedRect: cardRect, xRadius: 10, yRadius: 10).fill()

            // Hover border
            if isHovered {
                ToolbarLayout.accentColor.setStroke()
                let border = NSBezierPath(roundedRect: cardRect.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
                border.lineWidth = 2
                border.stroke()
            }

            // Image
            let imgPad: CGFloat = 12
            let labelH: CGFloat = 30
            let imgArea = NSRect(x: cardRect.minX + imgPad,
                                  y: cardRect.minY + labelH + imgPad / 2,
                                  width: cardRect.width - imgPad * 2,
                                  height: cardRect.height - labelH - imgPad * 1.5)

            if let img = cardImages[safe: i] ?? nil {
                let aspect = img.size.width / max(img.size.height, 1)
                var drawRect: NSRect
                if aspect > imgArea.width / imgArea.height {
                    let h = imgArea.width / aspect
                    drawRect = NSRect(x: imgArea.minX, y: imgArea.midY - h / 2, width: imgArea.width, height: h)
                } else {
                    let w = imgArea.height * aspect
                    drawRect = NSRect(x: imgArea.midX - w / 2, y: imgArea.minY, width: w, height: imgArea.height)
                }
                // Shadow
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
                shadow.shadowOffset = NSSize(width: 0, height: -2)
                shadow.shadowBlurRadius = 8
                shadow.set()
                img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
                NSShadow().set()  // clear shadow
            }

            // Label
            let labelStr = "\(entry.pixelWidth) × \(entry.pixelHeight)  ·  \(entry.timeAgoString)" as NSString
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(isHovered ? 0.9 : 0.5),
            ]
            let labelSize = labelStr.size(withAttributes: labelAttrs)
            labelStr.draw(at: NSPoint(x: cardRect.midX - labelSize.width / 2,
                                       y: cardRect.minY + (labelH - labelSize.height) / 2),
                          withAttributes: labelAttrs)
        }
    }

    private func drawEmptyState() {
        let str = "No recent captures" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.4),
        ]
        let size = str.size(withAttributes: attrs)
        str.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                 withAttributes: attrs)
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let newHovered = cardRects.firstIndex(where: { $0.contains(point) }) ?? -1
        if newHovered != hoveredIndex {
            hoveredIndex = newHovered
            NSCursor.pointingHand.set()
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredIndex != -1 { hoveredIndex = -1; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let idx = cardRects.firstIndex(where: { $0.contains(point) }) {
            controller?.copyAndDismiss(index: idx)
        } else {
            controller?.dismiss()
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            controller?.dismiss()
        }
    }
}

// Safe array subscript
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
