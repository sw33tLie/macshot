import Cocoa
import QuickLookUI

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Drop-down panel showing recent screenshot history as a horizontal scrolling strip.
/// Slides down from the top of the screen. Left-click to copy, right-click for more actions,
/// ESC or click outside to dismiss.
final class HistoryOverlayController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    private var panel: NSPanel?
    private var contentView: HistoryPanelView?
    private var backdropWindow: NSWindow?
    var onDismiss: (() -> Void)?

    // Quick Look state
    private var quickLookEntryIndex: Int = -1

    private static let panelHeight: CGFloat = 240
    private static let animationDuration: TimeInterval = 0.12

    func show() {
        guard let screen = NSScreen.main else { return }

        // Transparent click-catching backdrop (dismisses on click)
        let backdrop = NSWindow(
            contentRect: screen.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        backdrop.level = NSWindow.Level(256)
        backdrop.isOpaque = false
        backdrop.backgroundColor = NSColor.black.withAlphaComponent(0.001)
        backdrop.hasShadow = false
        backdrop.ignoresMouseEvents = false
        backdrop.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backdrop.isReleasedWhenClosed = false

        let backdropView = BackdropView(frame: screen.frame)
        backdropView.controller = self
        backdrop.contentView = backdropView
        backdrop.makeKeyAndOrderFront(nil)
        self.backdropWindow = backdrop

        // Panel window — starts above screen, slides down
        let menuBarHeight = screen.frame.height - screen.visibleFrame.height
            - screen.visibleFrame.origin.y + screen.frame.origin.y
        let panelWidth = min(screen.frame.width - 40, 1200)
        let panelX = screen.frame.midX - panelWidth / 2
        let panelY = screen.frame.maxY - menuBarHeight

        let startFrame = NSRect(x: panelX, y: panelY,
                                width: panelWidth, height: Self.panelHeight)
        let endFrame = NSRect(x: panelX, y: panelY - Self.panelHeight,
                              width: panelWidth, height: Self.panelHeight)

        let win = KeyablePanel(
            contentRect: startFrame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        win.level = NSWindow.Level(257)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.isMovableByWindowBackground = false
        win.alphaValue = 0.0

        let view = HistoryPanelView(
            frame: NSRect(origin: .zero, size: startFrame.size))
        view.controller = self
        win.contentView = view
        win.orderFront(nil)

        self.panel = win
        self.contentView = view

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().setFrame(endFrame, display: true)
            win.animator().alphaValue = 1.0
        }, completionHandler: {
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(view)
        })

        view.loadEntries()

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil)
    }

    @objc private func appDidResignActive() {
        dismiss()
    }

    /// Hide windows immediately so drag-and-drop can reach target apps.
    func hideForDrag() {
        backdropWindow?.orderOut(nil)
        panel?.alphaValue = 0.0
    }

    func confirmClearHistory() {
        dismiss()
        (NSApp.delegate as? AppDelegate)?.confirmClearHistory()
    }

    func dismiss() {
        NotificationCenter.default.removeObserver(self,
            name: NSApplication.didResignActiveNotification, object: nil)

        // Always tear down the backdrop immediately so it never blocks input
        if let bd = backdropWindow {
            bd.orderOut(nil)
            bd.close()
            backdropWindow = nil
        }

        guard let win = panel else {
            contentView = nil
            onDismiss?()
            return
        }
        panel = nil

        let hiddenFrame = NSRect(
            x: win.frame.origin.x, y: win.frame.origin.y + Self.panelHeight,
            width: win.frame.width, height: Self.panelHeight)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().setFrame(hiddenFrame, display: true)
            win.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            win.orderOut(nil)
            win.close()
            self?.contentView = nil
            self?.onDismiss?()
        })
    }

    // MARK: - Actions

    func copyAndDismiss(index: Int) {
        ScreenshotHistory.shared.copyEntry(at: index)
        let soundEnabled = UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true
        if soundEnabled {
            AppDelegate.captureSound?.stop()
            AppDelegate.captureSound?.play()
        }
        dismiss()
    }

    func deleteEntry(index: Int) {
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        let entry = entries[index]
        ScreenshotHistory.shared.removeEntry(id: entry.id)
        contentView?.loadEntries()
    }

    func openInEditor(index: Int) {
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        let entry = entries[index]

        // Try loading editable annotations + raw image first
        if entry.hasAnnotations,
           let rawImage = ScreenshotHistory.shared.loadRawImage(for: entry),
           let annotations = ScreenshotHistory.shared.loadAnnotations(for: entry) {
            dismiss()
            let entryID = entry.id
            DispatchQueue.main.async {
                DetachedEditorWindowController.open(image: rawImage, annotations: annotations, historyEntryID: entryID)
            }
            return
        }

        // Fall back to flattened image (old entries or missing files) — beautify already baked in
        guard let image = ScreenshotHistory.shared.loadImage(for: entry) else { return }
        dismiss()
        let entryID = entry.id
        DispatchQueue.main.async {
            DetachedEditorWindowController.open(image: image, historyEntryID: entryID, disableBeautify: true)
        }
    }

    func pinToScreen(index: Int) {
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        guard let image = ScreenshotHistory.shared.loadImage(for: entries[index]) else { return }
        dismiss()
        // Post notification so AppDelegate handles pin creation (it owns pinControllers)
        NotificationCenter.default.post(name: .init("macshot.pinFromHistory"), object: image)
    }

    func quickLook(index: Int) {
        quickLookEntryIndex = index
        dismiss()
        guard let qlPanel = QLPreviewPanel.shared() else { return }
        qlPanel.dataSource = self
        qlPanel.delegate = self
        qlPanel.reloadData()
        qlPanel.makeKeyAndOrderFront(nil)
    }

    func saveToFile(index: Int) {
        let entries = ScreenshotHistory.shared.entries
        guard index >= 0, index < entries.count else { return }
        guard let image = ScreenshotHistory.shared.loadImage(for: entries[index]) else { return }
        guard let imageData = ImageEncoder.encode(image) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Screenshot.\(ImageEncoder.fileExtension)"
        panel.level = .floating
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? imageData.write(to: url)
        }
    }

    // MARK: - Context Menu

    func showContextMenu(for globalIndex: Int, at point: NSPoint, in view: NSView) {
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: L("Copy"), action: #selector(contextCopy(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command]
        copyItem.target = self
        copyItem.tag = globalIndex
        menu.addItem(copyItem)

        let saveItem = NSMenuItem(title: L("Save As..."), action: #selector(contextSave(_:)), keyEquivalent: "")
        saveItem.target = self
        saveItem.tag = globalIndex
        menu.addItem(saveItem)

        menu.addItem(NSMenuItem.separator())

        let editorItem = NSMenuItem(title: L("Open in Editor"), action: #selector(contextOpenEditor(_:)), keyEquivalent: "e")
        editorItem.keyEquivalentModifierMask = [.command]
        editorItem.target = self
        editorItem.tag = globalIndex
        menu.addItem(editorItem)

        let pinItem = NSMenuItem(title: L("Pin to Screen"), action: #selector(contextPin(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.tag = globalIndex
        menu.addItem(pinItem)

        let qlItem = NSMenuItem(title: L("Quick Look"), action: #selector(contextQuickLook(_:)), keyEquivalent: " ")
        qlItem.target = self
        qlItem.tag = globalIndex
        menu.addItem(qlItem)

        menu.addItem(NSMenuItem.separator())

        let deleteItem = NSMenuItem(title: L("Delete"), action: #selector(contextDelete(_:)), keyEquivalent: "\u{8}")
        deleteItem.target = self
        deleteItem.tag = globalIndex
        menu.addItem(deleteItem)

        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: view)
    }

    @objc private func contextCopy(_ sender: NSMenuItem) { copyAndDismiss(index: sender.tag) }
    @objc private func contextSave(_ sender: NSMenuItem) { saveToFile(index: sender.tag) }
    @objc private func contextOpenEditor(_ sender: NSMenuItem) { openInEditor(index: sender.tag) }
    @objc private func contextPin(_ sender: NSMenuItem) { pinToScreen(index: sender.tag) }
    @objc private func contextQuickLook(_ sender: NSMenuItem) { quickLook(index: sender.tag) }
    @objc private func contextDelete(_ sender: NSMenuItem) { deleteEntry(index: sender.tag) }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let entries = ScreenshotHistory.shared.entries
        guard quickLookEntryIndex >= 0, quickLookEntryIndex < entries.count else { return nil }
        let entry = entries[quickLookEntryIndex]
        return ScreenshotHistory.shared.fileURL(for: entry) as NSURL?
    }
}

// MARK: - Backdrop View

private final class BackdropView: NSView {
    weak var controller: HistoryOverlayController?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        controller?.dismiss()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            controller?.dismiss()
        }
    }
}

// MARK: - Filter Tab

private enum HistoryFilter: String, CaseIterable {
    case all = "All"
    case screenshots = "Screenshots"
    case gifs = "GIFs"

    func matches(_ entry: HistoryEntry) -> Bool {
        switch self {
        case .all: return true
        case .screenshots: return entry.fileExtension == "png"
        case .gifs: return entry.fileExtension == "gif"
        }
    }
}

// MARK: - History Panel View

private final class HistoryPanelView: NSView, NSDraggingSource {

    weak var controller: HistoryOverlayController?

    private var entries: [HistoryEntry] = []
    private var filteredIndices: [Int] = []
    private var previews: [String: NSImage] = [:]
    private var cardRects: [NSRect] = []
    private var hoveredIndex: Int = -1
    private var activeFilter: HistoryFilter = .all
    private var filterTabRects: [NSRect] = []

    // Scroll state
    private var scrollOffset: CGFloat = 0
    private var contentWidth: CGFloat = 0

    // Drag state: track mouseDown origin to distinguish click vs drag
    private var mouseDownPoint: NSPoint = .zero
    private var mouseDownCardIndex: Int = -1 // filtered index
    private var isDragging = false
    private static let dragThreshold: CGFloat = 4

    // Layout constants
    private static let cardWidth: CGFloat = 200
    private static let cardHeight: CGFloat = 160
    private static let cardGap: CGFloat = 14
    private static let sidePadding: CGFloat = 24
    private static let topBarHeight: CGFloat = 50
    private static let cornerRadius: CGFloat = 14
    private var trashButtonRect: NSRect = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    // MARK: - Data Loading

    func loadEntries() {
        entries = ScreenshotHistory.shared.entries
        applyFilter()

        let entriesToLoad = entries
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var loaded: [String: NSImage] = [:]
            for entry in entriesToLoad {
                if let preview = ScreenshotHistory.shared.loadPreview(for: entry) {
                    loaded[entry.id] = preview
                }
            }
            DispatchQueue.main.async {
                self?.previews = loaded
                self?.needsDisplay = true
            }
        }
    }

    private func applyFilter() {
        filteredIndices = entries.enumerated().compactMap { (i, entry) in
            activeFilter.matches(entry) ? i : nil
        }
        scrollOffset = 0
        layoutCards()
        needsDisplay = true
    }

    private func layoutCards() {
        let count = filteredIndices.count
        contentWidth = CGFloat(count) * Self.cardWidth
            + CGFloat(max(count - 1, 0)) * Self.cardGap + Self.sidePadding * 2
        cardRects = (0..<count).map { i in
            let x = Self.sidePadding + CGFloat(i) * (Self.cardWidth + Self.cardGap)
            let y = Self.topBarHeight + 8
            return NSRect(x: x, y: y, width: Self.cardWidth, height: Self.cardHeight)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSColor(white: 0.10, alpha: 0.92)
        bg.setFill()
        let bgPath = NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        bgPath.fill()

        // Subtle border
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let borderPath = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        borderPath.lineWidth = 1
        borderPath.stroke()

        drawFilterTabs()

        guard let context = NSGraphicsContext.current else { return }

        if filteredIndices.isEmpty {
            drawEmptyState()
            return
        }

        // Clip card area
        let cardClip = NSRect(x: 0, y: Self.topBarHeight,
                              width: bounds.width, height: bounds.height - Self.topBarHeight)
        context.saveGraphicsState()
        NSBezierPath(rect: cardClip).setClip()

        for (fi, globalIndex) in filteredIndices.enumerated() {
            guard fi < cardRects.count else { continue }
            var rect = cardRects[fi]
            rect.origin.x -= scrollOffset

            guard rect.maxX > 0, rect.origin.x < bounds.width else { continue }

            let entry = entries[globalIndex]
            let isHovered = (fi == hoveredIndex)
            drawCard(entry: entry, rect: rect, isHovered: isHovered)
        }

        drawScrollFades(in: cardClip)
        context.restoreGraphicsState()
    }

    private func localizedFilterLabel(_ filter: HistoryFilter) -> String {
        switch filter {
        case .all: return L("All")
        case .screenshots: return L("Screenshots")
        case .gifs: return L("GIFs")
        }
    }

    private func drawFilterTabs() {
        let filters = HistoryFilter.allCases
        let tabFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let tabY: CGFloat = 13
        let tabH: CGFloat = 26
        let tabPadH: CGFloat = 16
        let tabGap: CGFloat = 6

        var tabWidths: [CGFloat] = []
        for filter in filters {
            let str = localizedFilterLabel(filter) as NSString
            let w = str.size(withAttributes: [.font: tabFont]).width + tabPadH * 2
            tabWidths.append(w)
        }
        let totalW = tabWidths.reduce(0, +) + CGFloat(filters.count - 1) * tabGap
        var x = bounds.midX - totalW / 2

        filterTabRects = []
        for (i, filter) in filters.enumerated() {
            let tabRect = NSRect(x: x, y: tabY, width: tabWidths[i], height: tabH)
            filterTabRects.append(tabRect)

            let isActive = filter == activeFilter
            if isActive {
                ToolbarLayout.accentColor.setFill()
            } else {
                NSColor.white.withAlphaComponent(0.10).setFill()
            }
            NSBezierPath(roundedRect: tabRect, xRadius: tabH / 2, yRadius: tabH / 2).fill()

            let textColor = isActive ? NSColor.white : NSColor.white.withAlphaComponent(0.55)
            let str = localizedFilterLabel(filter) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: tabFont,
                .foregroundColor: textColor,
            ]
            let size = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: tabRect.midX - size.width / 2,
                                 y: tabRect.midY - size.height / 2),
                     withAttributes: attrs)

            x += tabWidths[i] + tabGap
        }

        // Trash button (top-right)
        let trashSize: CGFloat = 22
        let trashRect = NSRect(
            x: bounds.maxX - Self.sidePadding - trashSize,
            y: tabY + (tabH - trashSize) / 2,
            width: trashSize, height: trashSize)
        trashButtonRect = trashRect
        if let trashIcon = NSImage(systemSymbolName: "trash", accessibilityDescription: L("Clear History"))?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
            let tinted = trashIcon.copy() as! NSImage
            tinted.isTemplate = false
            tinted.lockFocus()
            NSColor.white.withAlphaComponent(0.45).set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let iconSize = tinted.size
            // Flip the icon since the view is flipped (isFlipped = true)
            NSGraphicsContext.saveGraphicsState()
            let xform = NSAffineTransform()
            xform.translateX(by: trashRect.midX, yBy: trashRect.midY)
            xform.scaleX(by: 1, yBy: -1)
            xform.translateX(by: -trashRect.midX, yBy: -trashRect.midY)
            xform.concat()
            tinted.draw(in: NSRect(
                x: trashRect.midX - iconSize.width / 2,
                y: trashRect.midY - iconSize.height / 2,
                width: iconSize.width, height: iconSize.height),
                from: .zero, operation: .sourceOver, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawCard(entry: HistoryEntry, rect: NSRect, isHovered: Bool) {
        // Card background
        let bgColor = isHovered
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.white.withAlphaComponent(0.05)
        bgColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()

        // Hover border
        if isHovered {
            ToolbarLayout.accentColor.withAlphaComponent(0.7).setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            border.lineWidth = 1.5
            border.stroke()
        }

        // Image area
        let imgPad: CGFloat = 8
        let labelH: CGFloat = 28
        let imgArea = NSRect(
            x: rect.minX + imgPad,
            y: rect.minY + imgPad,
            width: rect.width - imgPad * 2,
            height: rect.height - labelH - imgPad)

        if let img = previews[entry.id] {
            let aspect = img.size.width / max(img.size.height, 1)
            var drawRect: NSRect
            if aspect > imgArea.width / imgArea.height {
                let h = imgArea.width / aspect
                drawRect = NSRect(x: imgArea.minX, y: imgArea.midY - h / 2,
                                  width: imgArea.width, height: h)
            } else {
                let w = imgArea.height * aspect
                drawRect = NSRect(x: imgArea.midX - w / 2, y: imgArea.minY,
                                  width: w, height: imgArea.height)
            }

            let clipPath = NSBezierPath(roundedRect: drawRect, xRadius: 6, yRadius: 6)
            NSGraphicsContext.current?.saveGraphicsState()
            clipPath.setClip()
            img.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                     respectFlipped: true,
                     hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
            NSGraphicsContext.current?.restoreGraphicsState()

            // Dim overlay + hint on hover
            if isHovered {
                NSColor.black.withAlphaComponent(0.35).setFill()
                clipPath.fill()

                // Hint text
                let hint = L("Click to copy · Drag to app") as NSString
                let hintAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.9),
                ]
                let hintSize = hint.size(withAttributes: hintAttrs)
                hint.draw(at: NSPoint(x: drawRect.midX - hintSize.width / 2,
                                      y: drawRect.midY - hintSize.height / 2),
                          withAttributes: hintAttrs)
            }
        } else {
            // Loading placeholder
            NSColor.white.withAlphaComponent(0.03).setFill()
            NSBezierPath(roundedRect: imgArea, xRadius: 6, yRadius: 6).fill()
        }

        // Label
        let labelStr = "\(entry.pixelWidth) x \(entry.pixelHeight)  ·  \(entry.timeAgoString)" as NSString
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(isHovered ? 0.85 : 0.45),
        ]
        let labelSize = labelStr.size(withAttributes: labelAttrs)
        labelStr.draw(
            at: NSPoint(x: rect.midX - labelSize.width / 2,
                        y: rect.maxY - labelH + (labelH - labelSize.height) / 2),
            withAttributes: labelAttrs)
    }

    private func drawScrollFades(in clipRect: NSRect) {
        let fadeWidth: CGFloat = 30

        if scrollOffset > 0 {
            let fadeRect = NSRect(x: 0, y: clipRect.minY,
                                 width: fadeWidth, height: clipRect.height)
            let gradient = NSGradient(
                starting: NSColor(white: 0.10, alpha: 0.92),
                ending: NSColor(white: 0.10, alpha: 0.0))
            gradient?.draw(in: fadeRect, angle: 0)
        }

        let maxScroll = max(contentWidth - bounds.width, 0)
        if scrollOffset < maxScroll {
            let fadeRect = NSRect(x: bounds.width - fadeWidth, y: clipRect.minY,
                                 width: fadeWidth, height: clipRect.height)
            let gradient = NSGradient(
                starting: NSColor(white: 0.10, alpha: 0.0),
                ending: NSColor(white: 0.10, alpha: 0.92))
            gradient?.draw(in: fadeRect, angle: 0)
        }
    }

    private func drawEmptyState() {
        let str = L("No captures yet") as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.3),
        ]
        let size = str.size(withAttributes: attrs)
        str.draw(
            at: NSPoint(x: bounds.midX - size.width / 2,
                        y: bounds.midY - size.height / 2 + Self.topBarHeight / 2),
            withAttributes: attrs)
    }

    // MARK: - Scrolling

    override func scrollWheel(with event: NSEvent) {
        let maxScroll = max(contentWidth - bounds.width, 0)
        guard maxScroll > 0 else { return }

        var delta = event.scrollingDeltaX
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            delta = event.scrollingDeltaY
        }

        if event.hasPreciseScrollingDeltas {
            scrollOffset = max(0, min(maxScroll, scrollOffset - delta))
        } else {
            scrollOffset = max(0, min(maxScroll, scrollOffset - delta * 8))
        }
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        let newHovered = cardRects.indices.first(where: { i in
            var rect = cardRects[i]
            rect.origin.x -= scrollOffset
            return rect.contains(point)
        }) ?? -1

        if newHovered != hoveredIndex {
            hoveredIndex = newHovered
            if newHovered >= 0 {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredIndex != -1 {
            hoveredIndex = -1
            NSCursor.arrow.set()
            needsDisplay = true
        }
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return context == .outsideApplication ? .copy : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Dismiss regardless of whether drop succeeded — panel is already hidden
        controller?.dismiss()
        isDragging = false
    }

    private func beginDragSession(filterIndex: Int, event: NSEvent) {
        guard filterIndex >= 0, filterIndex < filteredIndices.count else { return }
        let globalIndex = filteredIndices[filterIndex]
        let entry = entries[globalIndex]
        let fileURL = ScreenshotHistory.shared.fileURL(for: entry) as NSURL

        // Use NSURL as the pasteboard writer — it automatically provides
        // the file URL in all standard pasteboard types that apps expect
        // (kPasteboardTypeFileURLPromise, NSFilenamesPboardType, public.file-url, etc.)
        let dragItem = NSDraggingItem(pasteboardWriter: fileURL)

        // Use the preview as the drag image
        var cardRect = cardRects[filterIndex]
        cardRect.origin.x -= scrollOffset
        if let preview = previews[entry.id] {
            dragItem.setDraggingFrame(cardRect, contents: preview)
        }

        // Hide the panel and backdrop so the drag can reach the target app
        // (our windows are above everything and would block drop targets otherwise)
        controller?.hideForDrag()

        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    // MARK: - Click / Drag

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        isDragging = false

        // Filter tabs — immediate action, no drag
        for (i, tabRect) in filterTabRects.enumerated() {
            if tabRect.contains(point) {
                let filters = HistoryFilter.allCases
                if i < filters.count {
                    activeFilter = filters[i]
                    hoveredIndex = -1
                    applyFilter()
                }
                mouseDownCardIndex = -1
                return
            }
        }

        // Trash button — clear all history with confirmation
        if trashButtonRect.insetBy(dx: -4, dy: -4).contains(point) {
            controller?.confirmClearHistory()
            mouseDownCardIndex = -1
            return
        }

        // Record for click/drag detection
        mouseDownPoint = point
        mouseDownCardIndex = cardRects.indices.first(where: { i in
            var rect = cardRects[i]
            rect.origin.x -= scrollOffset
            return rect.contains(point)
        }) ?? -1

        // If clicked outside any card, dismiss immediately
        if mouseDownCardIndex < 0 {
            controller?.dismiss()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseDownCardIndex >= 0, !isDragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - mouseDownPoint.x
        let dy = point.y - mouseDownPoint.y
        if sqrt(dx * dx + dy * dy) >= Self.dragThreshold {
            isDragging = true
            beginDragSession(filterIndex: mouseDownCardIndex, event: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownCardIndex = -1 }
        guard !isDragging, mouseDownCardIndex >= 0,
              mouseDownCardIndex < filteredIndices.count else { return }

        // Click — copy to clipboard
        let globalIndex = filteredIndices[mouseDownCardIndex]
        controller?.copyAndDismiss(index: globalIndex)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        let clickedCard = cardRects.indices.first(where: { i in
            var rect = cardRects[i]
            rect.origin.x -= scrollOffset
            return rect.contains(point)
        }) ?? -1

        guard clickedCard >= 0, clickedCard < filteredIndices.count else { return }
        let globalIndex = filteredIndices[clickedCard]
        controller?.showContextMenu(for: globalIndex, at: point, in: self)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            controller?.dismiss()
        }
    }
}
