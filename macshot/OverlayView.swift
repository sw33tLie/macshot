import Cocoa
import UniformTypeIdentifiers

protocol OverlayViewDelegate: AnyObject {
    func overlayViewDidFinishSelection(_ rect: NSRect)
    func overlayViewSelectionDidChange(_ rect: NSRect)
    func overlayViewDidCancel()
    func overlayViewDidConfirm()
    func overlayViewDidRequestSave()
    func overlayViewDidRequestPin()
    func overlayViewDidRequestOCR()
}

class OverlayView: NSView {

    // MARK: - Properties

    weak var overlayDelegate: OverlayViewDelegate?

    var screenshotImage: NSImage? {
        didSet { needsDisplay = true }
    }

    // State
    enum State {
        case idle
        case selecting
        case selected
    }

    private(set) var state: State = .idle

    // Selection
    private var selectionRect: NSRect = .zero
    private var selectionStart: NSPoint = .zero
    private var isDraggingSelection: Bool = false
    private var isResizingSelection: Bool = false
    private var resizeHandle: ResizeHandle = .none
    private var dragOffset: NSPoint = .zero
    private var moveMode: Bool = false  // move tool active
    private var lastDragPoint: NSPoint?  // for shift constraint on flagsChanged

    // Annotations
    private var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []
    private var currentAnnotation: Annotation?
    private var currentTool: AnnotationTool = .arrow
    private var currentColor: NSColor = .systemRed
    private var currentStrokeWidth: CGFloat = 3.0
    private var numberCounter: Int = 0

    // Text editing
    private var textEditView: NSTextView?
    private var textScrollView: NSScrollView?
    private var textControlBar: NSView?
    private var textFontSize: CGFloat = 16
    private var textBold: Bool = false
    private var textItalic: Bool = false
    private var textUnderline: Bool = false
    private var textStrikethrough: Bool = false

    // Toolbars (drawn inline)
    private var bottomButtons: [ToolbarButton] = []
    private var rightButtons: [ToolbarButton] = []
    private var bottomBarRect: NSRect = .zero
    private var rightBarRect: NSRect = .zero
    private var showToolbars: Bool = false
    private var hoveredButtonIndex: Int = -1  // -1 = none, 0..N bottom, 1000+ right

    // Size label
    private var sizeLabelRect: NSRect = .zero
    private var sizeInputField: NSTextField?

    // Beautify
    private(set) var beautifyEnabled: Bool = false
    private(set) var beautifyStyleIndex: Int = 0

    // Color picker popover
    private var showColorPicker: Bool = false
    private var colorPickerRect: NSRect = .zero
    private let availableColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .systemPink, .white,
        .black, .darkGray, .systemTeal, .systemIndigo,
    ]

    // Handle
    private let handleSize: CGFloat = 10

    enum ResizeHandle {
        case none
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
        case move
    }

    // MARK: - Setup

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        guard showToolbars else { return }
        let point = convert(event.locationInWindow, from: nil)
        var newHovered = -1

        for (i, btn) in bottomButtons.enumerated() {
            if btn.rect.contains(point) {
                newHovered = i
                break
            }
        }
        if newHovered == -1 {
            for (i, btn) in rightButtons.enumerated() {
                if btn.rect.contains(point) {
                    newHovered = 1000 + i
                    break
                }
            }
        }

        if newHovered != hoveredButtonIndex {
            hoveredButtonIndex = newHovered
            needsDisplay = true
        }
    }

    // Diagonal resize cursors (macOS doesn't provide these publicly)
    private static let nwseCursor: NSCursor = {
        // Top-left <-> Bottom-right (backslash direction)
        if let cursor = NSCursor.perform(NSSelectorFromString("_windowResizeNorthWestSouthEastCursor"))?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .crosshair
    }()

    private static let neswCursor: NSCursor = {
        // Top-right <-> Bottom-left (slash direction)
        if let cursor = NSCursor.perform(NSSelectorFromString("_windowResizeNorthEastSouthWestCursor"))?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .crosshair
    }()

    override func resetCursorRects() {
        super.resetCursorRects()
        if state == .idle {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }

        guard state == .selected, selectionRect.width > 1, selectionRect.height > 1 else {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }

        let edgeThickness: CGFloat = 6
        let r = selectionRect
        let hs = handleSize + 4  // handle hit area

        // Corner handles — diagonal resize cursors
        // Top-left (NWSE)
        addCursorRect(NSRect(x: r.minX - hs/2, y: r.maxY - hs/2, width: hs, height: hs), cursor: Self.nwseCursor)
        // Bottom-right (NWSE)
        addCursorRect(NSRect(x: r.maxX - hs/2, y: r.minY - hs/2, width: hs, height: hs), cursor: Self.nwseCursor)
        // Top-right (NESW)
        addCursorRect(NSRect(x: r.maxX - hs/2, y: r.maxY - hs/2, width: hs, height: hs), cursor: Self.neswCursor)
        // Bottom-left (NESW)
        addCursorRect(NSRect(x: r.minX - hs/2, y: r.minY - hs/2, width: hs, height: hs), cursor: Self.neswCursor)

        // Edge handles — horizontal/vertical resize cursors
        // Top edge
        addCursorRect(NSRect(x: r.minX + hs/2, y: r.maxY - edgeThickness/2, width: r.width - hs, height: edgeThickness), cursor: .resizeUpDown)
        // Bottom edge
        addCursorRect(NSRect(x: r.minX + hs/2, y: r.minY - edgeThickness/2, width: r.width - hs, height: edgeThickness), cursor: .resizeUpDown)
        // Left edge
        addCursorRect(NSRect(x: r.minX - edgeThickness/2, y: r.minY + hs/2, width: edgeThickness, height: r.height - hs), cursor: .resizeLeftRight)
        // Right edge
        addCursorRect(NSRect(x: r.maxX - edgeThickness/2, y: r.minY + hs/2, width: edgeThickness, height: r.height - hs), cursor: .resizeLeftRight)

        // Toolbar buttons — arrow cursor so they look clickable
        if showToolbars {
            for btn in bottomButtons {
                if btn.rect.width > 0 {
                    addCursorRect(btn.rect, cursor: .arrow)
                }
            }
            for btn in rightButtons {
                if btn.rect.width > 0 {
                    addCursorRect(btn.rect, cursor: .arrow)
                }
            }
            if bottomBarRect.width > 0 {
                addCursorRect(bottomBarRect, cursor: .arrow)
            }
            if rightBarRect.width > 0 {
                addCursorRect(rightBarRect, cursor: .arrow)
            }
        }

        // Size label — pointer cursor to indicate clickable
        if sizeLabelRect.width > 0 && sizeInputField == nil {
            addCursorRect(sizeLabelRect, cursor: .pointingHand)
        }

        // Inside selection — crosshair for drawing
        let innerRect = r.insetBy(dx: edgeThickness, dy: edgeThickness)
        if innerRect.width > 0 && innerRect.height > 0 {
            addCursorRect(innerRect, cursor: .crosshair)
        }

        // Outside selection — crosshair for new selection
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current else { return }

        // Draw screenshot
        if let image = screenshotImage {
            image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
        }

        // Draw dark overlay
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(rect: bounds).fill()

        // Draw clear selection region
        if state != .idle && selectionRect.width > 1 && selectionRect.height > 1 {
            // Clear area inside selection
            context.saveGraphicsState()
            NSBezierPath(rect: selectionRect).setClip()
            if let image = screenshotImage {
                image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
            }

            // Draw annotations clipped to selection
            for annotation in annotations {
                annotation.draw(in: context)
            }
            currentAnnotation?.draw(in: context)

            context.restoreGraphicsState()

            // Selection border (purple like Flameshot)
            let borderPath = NSBezierPath(rect: selectionRect)
            borderPath.lineWidth = 2.0
            ToolbarLayout.accentColor.setStroke()
            borderPath.stroke()

            // Size label above/below selection
            drawSizeLabel()

            // Resize handles
            if state == .selected {
                drawResizeHandles()
            }

            // Toolbars
            if showToolbars && state == .selected {
                rebuildToolbarLayout()
                ToolbarLayout.drawToolbar(barRect: bottomBarRect, buttons: bottomButtons, selectionSize: selectionRect.size)
                ToolbarLayout.drawToolbar(barRect: rightBarRect, buttons: rightButtons, selectionSize: nil)

                // Color picker popover
                if showColorPicker {
                    drawColorPicker()
                }

                // Tooltip for hovered button
                drawHoveredTooltip()
            }
        }

        // Keep cursor rects in sync with current selection
        window?.invalidateCursorRects(for: self)
    }

    private func drawHoveredTooltip() {
        guard hoveredButtonIndex >= 0 else { return }

        // Find the hovered button
        var btn: ToolbarButton?
        var isBottomBar = false
        if hoveredButtonIndex < 1000 && hoveredButtonIndex < bottomButtons.count {
            btn = bottomButtons[hoveredButtonIndex]
            isBottomBar = true
        } else if hoveredButtonIndex >= 1000 && (hoveredButtonIndex - 1000) < rightButtons.count {
            btn = rightButtons[hoveredButtonIndex - 1000]
        }
        guard let button = btn, !button.tooltip.isEmpty else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str = button.tooltip as NSString
        let textSize = str.size(withAttributes: attrs)
        let padding: CGFloat = 6
        let tipWidth = textSize.width + padding * 2
        let tipHeight = textSize.height + padding

        let tipX = button.rect.midX - tipWidth / 2
        let tipY: CGFloat
        if isBottomBar {
            // Show below bottom bar, unless it would go off screen
            let below = bottomBarRect.minY - tipHeight - 4
            if below >= bounds.minY + 2 {
                tipY = below
            } else {
                tipY = bottomBarRect.maxY + 4
            }
        } else {
            // Right bar: show to the left
            let tipRect = NSRect(x: button.rect.minX - tipWidth - 6, y: button.rect.midY - tipHeight / 2, width: tipWidth, height: tipHeight)
            ToolbarLayout.bgColor.setFill()
            NSBezierPath(roundedRect: tipRect, xRadius: 4, yRadius: 4).fill()
            str.draw(at: NSPoint(x: tipRect.minX + padding, y: tipRect.minY + padding / 2), withAttributes: attrs)
            return
        }

        let tipRect = NSRect(x: tipX, y: tipY, width: tipWidth, height: tipHeight)
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: tipRect, xRadius: 4, yRadius: 4).fill()
        str.draw(at: NSPoint(x: tipRect.minX + padding, y: tipRect.minY + padding / 2), withAttributes: attrs)
    }

    private func drawSizeLabel() {
        guard sizeInputField == nil else { return }  // don't draw while editing

        // Get pixel dimensions (account for Retina)
        let scale = window?.backingScaleFactor ?? 2.0
        let pixelW = Int(selectionRect.width * scale)
        let pixelH = Int(selectionRect.height * scale)
        let text = "\(pixelW) \u{00D7} \(pixelH)"

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 6
        let labelW = textSize.width + padding * 2
        let labelH = textSize.height + padding

        let labelX = selectionRect.midX - labelW / 2

        // Default: above selection. If toolbar is above (bottomBarRect is above selection), go below toolbar area.
        // If no room above, go below.
        let above = selectionRect.maxY + 4
        let below = selectionRect.minY - labelH - 4
        let labelY: CGFloat
        if above + labelH < bounds.maxY - 2 {
            labelY = above
        } else if below >= bounds.minY + 2 {
            labelY = below
        } else {
            labelY = above  // fallback
        }

        let rect = NSRect(x: labelX, y: labelY, width: labelW, height: labelH)
        sizeLabelRect = rect

        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: NSPoint(x: rect.minX + padding, y: rect.minY + padding / 2), withAttributes: attrs)
    }

    private func showSizeInput() {
        let scale = window?.backingScaleFactor ?? 2.0
        let pixelW = Int(selectionRect.width * scale)
        let pixelH = Int(selectionRect.height * scale)

        let fieldWidth: CGFloat = 120
        let fieldHeight: CGFloat = 22
        let fieldX = sizeLabelRect.midX - fieldWidth / 2
        let fieldY = sizeLabelRect.minY + (sizeLabelRect.height - fieldHeight) / 2

        let field = NSTextField(frame: NSRect(x: fieldX, y: fieldY, width: fieldWidth, height: fieldHeight))
        field.stringValue = "\(pixelW) \u{00D7} \(pixelH)"
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        field.alignment = .center
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.backgroundColor = NSColor(white: 0.15, alpha: 0.95)
        field.textColor = .white
        field.focusRingType = .none
        field.delegate = self
        field.tag = 888

        addSubview(field)
        sizeInputField = field
        window?.makeFirstResponder(field)
        field.selectText(nil)
        needsDisplay = true
    }

    private func commitSizeInputIfNeeded() {
        guard let field = sizeInputField else { return }
        let input = field.stringValue.trimmingCharacters(in: .whitespaces)

        // Parse "W × H", "WxH", "W*H", "W H"
        let separators = CharacterSet(charactersIn: "\u{00D7}xX*").union(.whitespaces)
        let parts = input.components(separatedBy: separators).filter { !$0.isEmpty }

        if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 {
            let scale = window?.backingScaleFactor ?? 2.0
            let newW = CGFloat(w) / scale
            let newH = CGFloat(h) / scale

            // Resize from center of current selection
            let centerX = selectionRect.midX
            let centerY = selectionRect.midY
            selectionRect = NSRect(
                x: centerX - newW / 2,
                y: centerY - newH / 2,
                width: newW,
                height: newH
            )
        }

        field.removeFromSuperview()
        sizeInputField = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func drawResizeHandles() {
        for (_, rect) in allHandleRects() {
            ToolbarLayout.handleColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    private func drawColorPicker() {
        let cols = 4
        let rows = (availableColors.count + cols - 1) / cols
        let swatchSize: CGFloat = 24
        let padding: CGFloat = 6
        let pickerWidth = CGFloat(cols) * (swatchSize + padding) + padding
        let pickerHeight = CGFloat(rows) * (swatchSize + padding) + padding

        // Find color button in bottom bar
        var anchorX = bottomBarRect.midX
        for btn in bottomButtons {
            if case .color = btn.action {
                anchorX = btn.rect.midX
                break
            }
        }

        let pickerX = anchorX - pickerWidth / 2
        let pickerY: CGFloat
        if bottomBarRect.minY < selectionRect.minY {
            pickerY = bottomBarRect.minY - pickerHeight - 4
        } else {
            pickerY = bottomBarRect.maxY + 4
        }

        colorPickerRect = NSRect(x: pickerX, y: pickerY, width: pickerWidth, height: pickerHeight)

        // Background
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: colorPickerRect, xRadius: 6, yRadius: 6).fill()

        // Swatches
        for (i, color) in availableColors.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = colorPickerRect.minX + padding + CGFloat(col) * (swatchSize + padding)
            let y = colorPickerRect.maxY - padding - swatchSize - CGFloat(row) * (swatchSize + padding)
            let swatchRect = NSRect(x: x, y: y, width: swatchSize, height: swatchSize)

            color.setFill()
            NSBezierPath(roundedRect: swatchRect, xRadius: 4, yRadius: 4).fill()

            if color == currentColor {
                NSColor.white.setStroke()
                let border = NSBezierPath(roundedRect: swatchRect.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
                border.lineWidth = 2
                border.stroke()
            }
        }
    }

    // MARK: - Toolbar Layout

    private func rebuildToolbarLayout() {
        bottomButtons = ToolbarLayout.bottomButtons(selectedTool: currentTool, selectedColor: currentColor, beautifyEnabled: beautifyEnabled, beautifyStyleIndex: beautifyStyleIndex)
        rightButtons = ToolbarLayout.rightButtons()
        bottomBarRect = ToolbarLayout.layoutBottom(buttons: &bottomButtons, selectionRect: selectionRect, viewBounds: bounds)
        rightBarRect = ToolbarLayout.layoutRight(buttons: &rightButtons, selectionRect: selectionRect, viewBounds: bounds)

        // Apply hover state
        for i in 0..<bottomButtons.count {
            bottomButtons[i].isHovered = (hoveredButtonIndex == i)
        }
        for i in 0..<rightButtons.count {
            rightButtons[i].isHovered = (hoveredButtonIndex == 1000 + i)
        }
    }

    // MARK: - Handle hit testing

    private func allHandleRects() -> [(ResizeHandle, NSRect)] {
        let r = selectionRect
        let s = handleSize
        return [
            (.topLeft, NSRect(x: r.minX - s/2, y: r.maxY - s/2, width: s, height: s)),
            (.topRight, NSRect(x: r.maxX - s/2, y: r.maxY - s/2, width: s, height: s)),
            (.bottomLeft, NSRect(x: r.minX - s/2, y: r.minY - s/2, width: s, height: s)),
            (.bottomRight, NSRect(x: r.maxX - s/2, y: r.minY - s/2, width: s, height: s)),
            (.top, NSRect(x: r.midX - s/2, y: r.maxY - s/2, width: s, height: s)),
            (.bottom, NSRect(x: r.midX - s/2, y: r.minY - s/2, width: s, height: s)),
            (.left, NSRect(x: r.minX - s/2, y: r.midY - s/2, width: s, height: s)),
            (.right, NSRect(x: r.maxX - s/2, y: r.midY - s/2, width: s, height: s)),
        ]
    }

    private func hitTestHandle(at point: NSPoint) -> ResizeHandle {
        let hitPad: CGFloat = handleSize
        // Check corner handles first (they take priority over edges)
        for (handle, rect) in allHandleRects() {
            switch handle {
            case .topLeft, .topRight, .bottomLeft, .bottomRight:
                if rect.insetBy(dx: -hitPad, dy: -hitPad).contains(point) {
                    return handle
                }
            default:
                break
            }
        }

        // Check full edges/borders (not just the handle dots)
        let edgeThickness: CGFloat = 8
        let r = selectionRect
        // Top edge
        if NSRect(x: r.minX, y: r.maxY - edgeThickness/2, width: r.width, height: edgeThickness).contains(point) {
            return .top
        }
        // Bottom edge
        if NSRect(x: r.minX, y: r.minY - edgeThickness/2, width: r.width, height: edgeThickness).contains(point) {
            return .bottom
        }
        // Left edge
        if NSRect(x: r.minX - edgeThickness/2, y: r.minY, width: edgeThickness, height: r.height).contains(point) {
            return .left
        }
        // Right edge
        if NSRect(x: r.maxX - edgeThickness/2, y: r.minY, width: edgeThickness, height: r.height).contains(point) {
            return .right
        }

        return .none
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        let isTextEditing = textEditView != nil

        // Color picker swatch selection
        if showColorPicker {
            if let color = hitTestColorPicker(at: point) {
                currentColor = color
                showColorPicker = false
                if isTextEditing, let tv = textEditView {
                    // Apply color to selected text or all text
                    let range = selectedOrAllRange()
                    if range.length > 0 {
                        tv.textStorage?.addAttribute(.foregroundColor, value: currentColor, range: range)
                    }
                    tv.insertionPointColor = currentColor
                    tv.typingAttributes[.foregroundColor] = currentColor
                    window?.makeFirstResponder(tv)
                }
                needsDisplay = true
                return
            }
            showColorPicker = false
            needsDisplay = true
        }

        // If text is being edited, check if the click is on the color toolbar button
        // before committing the text field
        if isTextEditing && showToolbars {
            if let action = ToolbarLayout.hitTest(point: point, buttons: bottomButtons) {
                if case .color = action {
                    showColorPicker.toggle()
                    needsDisplay = true
                    return
                }
            }
            // Clicking on the text control bar or text editor itself — don't commit
            if let bar = textControlBar, bar.frame.contains(point) {
                return
            }
            if let sv = textScrollView, sv.frame.contains(point) {
                return
            }
        }

        commitTextFieldIfNeeded()
        commitSizeInputIfNeeded()

        switch state {
        case .idle:
            selectionStart = point
            selectionRect = NSRect(origin: point, size: .zero)
            state = .selecting
            needsDisplay = true

        case .selecting:
            break

        case .selected:
            // Check size label click
            if sizeLabelRect.contains(point) && sizeInputField == nil {
                showSizeInput()
                return
            }
            if let field = sizeInputField, field.frame.contains(point) {
                return  // let the text field handle it
            }

            // Check toolbar hit first
            if showToolbars {
                if let action = ToolbarLayout.hitTest(point: point, buttons: bottomButtons) {
                    handleToolbarAction(action, mousePoint: point)
                    return
                }
                if let action = ToolbarLayout.hitTest(point: point, buttons: rightButtons) {
                    handleToolbarAction(action, mousePoint: point)
                    return
                }
                // Don't start new selection if clicking toolbar area
                if ToolbarLayout.hitTestBar(point: point, barRect: bottomBarRect) ||
                   ToolbarLayout.hitTestBar(point: point, barRect: rightBarRect) {
                    return
                }
            }

            // Check handles
            let handle = hitTestHandle(at: point)
            if handle != .none {
                isResizingSelection = true
                resizeHandle = handle
                return
            }

            // Inside selection — draw annotation
            if selectionRect.contains(point) {
                startAnnotation(at: point)
                return
            }

            // Outside everything - start new selection
            showToolbars = false
            annotations.removeAll()
            redoStack.removeAll()
            numberCounter = 0
            selectionStart = point
            selectionRect = NSRect(origin: point, size: .zero)
            state = .selecting
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch state {
        case .selecting:
            let x = min(selectionStart.x, point.x)
            let y = min(selectionStart.y, point.y)
            let w = abs(point.x - selectionStart.x)
            let h = abs(point.y - selectionStart.y)
            selectionRect = NSRect(x: x, y: y, width: w, height: h)
            needsDisplay = true

        case .selected:
            if isDraggingSelection {
                selectionRect.origin = NSPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y)
                needsDisplay = true
            } else if isResizingSelection {
                resizeSelection(to: point)
                needsDisplay = true
            } else if currentAnnotation != nil {
                lastDragPoint = point
                updateAnnotation(at: point, shiftHeld: event.modifierFlags.contains(.shift))
                needsDisplay = true
            }

        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        switch state {
        case .selecting:
            if selectionRect.width > 5 && selectionRect.height > 5 {
                state = .selected
                showToolbars = true
                overlayDelegate?.overlayViewDidFinishSelection(selectionRect)
            } else {
                state = .idle
                selectionRect = .zero
            }
            needsDisplay = true

        case .selected:
            if isDraggingSelection {
                isDraggingSelection = false
                moveMode = false
                needsDisplay = true
            } else if isResizingSelection {
                isResizingSelection = false
                resizeHandle = .none
                needsDisplay = true
            } else if let annotation = currentAnnotation {
                finishAnnotation(annotation)
            }

        default:
            break
        }
    }

    // MARK: - Selection Resizing

    private func resizeSelection(to point: NSPoint) {
        let minSize: CGFloat = 10
        let r = selectionRect
        var newRect = r

        switch resizeHandle {
        case .topLeft:
            let newX = min(point.x, r.maxX - minSize)
            let newMaxY = max(point.y, r.minY + minSize)
            newRect = NSRect(x: newX, y: r.minY, width: r.maxX - newX, height: newMaxY - r.minY)
        case .topRight:
            let newMaxX = max(point.x, r.minX + minSize)
            let newMaxY = max(point.y, r.minY + minSize)
            newRect = NSRect(x: r.minX, y: r.minY, width: newMaxX - r.minX, height: newMaxY - r.minY)
        case .bottomLeft:
            let newX = min(point.x, r.maxX - minSize)
            let newY = min(point.y, r.maxY - minSize)
            newRect = NSRect(x: newX, y: newY, width: r.maxX - newX, height: r.maxY - newY)
        case .bottomRight:
            let newMaxX = max(point.x, r.minX + minSize)
            let newY = min(point.y, r.maxY - minSize)
            newRect = NSRect(x: r.minX, y: newY, width: newMaxX - r.minX, height: r.maxY - newY)
        case .top:
            let newMaxY = max(point.y, r.minY + minSize)
            newRect = NSRect(x: r.minX, y: r.minY, width: r.width, height: newMaxY - r.minY)
        case .bottom:
            let newY = min(point.y, r.maxY - minSize)
            newRect = NSRect(x: r.minX, y: newY, width: r.width, height: r.maxY - newY)
        case .left:
            let newX = min(point.x, r.maxX - minSize)
            newRect = NSRect(x: newX, y: r.minY, width: r.maxX - newX, height: r.height)
        case .right:
            let newMaxX = max(point.x, r.minX + minSize)
            newRect = NSRect(x: r.minX, y: r.minY, width: newMaxX - r.minX, height: r.height)
        default:
            break
        }

        selectionRect = newRect
    }

    // MARK: - Toolbar Actions

    private func handleToolbarAction(_ action: ToolbarButtonAction, mousePoint: NSPoint = .zero) {
        switch action {
        case .tool(let tool):
            currentTool = tool
            needsDisplay = true
        case .color:
            showColorPicker.toggle()
            needsDisplay = true
        case .sizeDisplay:
            break
        case .moveSelection:
            // Start drag-to-move immediately (hold and drag, release to stop)
            isDraggingSelection = true
            moveMode = true
            dragOffset = NSPoint(x: mousePoint.x - selectionRect.origin.x, y: mousePoint.y - selectionRect.origin.y)
            needsDisplay = true
        case .undo:
            undo()
        case .redo:
            redo()
        case .copy:
            overlayDelegate?.overlayViewDidConfirm()
        case .save:
            overlayDelegate?.overlayViewDidRequestSave()
        case .pin:
            overlayDelegate?.overlayViewDidRequestPin()
        case .ocr:
            overlayDelegate?.overlayViewDidRequestOCR()
        case .beautify:
            beautifyEnabled.toggle()
            needsDisplay = true
        case .beautifyStyle:
            beautifyStyleIndex = (beautifyStyleIndex + 1) % BeautifyRenderer.styles.count
            needsDisplay = true
        case .cancel:
            overlayDelegate?.overlayViewDidCancel()
        }
    }

    private func hitTestColorPicker(at point: NSPoint) -> NSColor? {
        guard showColorPicker else { return nil }
        let cols = 4
        let swatchSize: CGFloat = 24
        let padding: CGFloat = 6

        for (i, color) in availableColors.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = colorPickerRect.minX + padding + CGFloat(col) * (swatchSize + padding)
            let y = colorPickerRect.maxY - padding - swatchSize - CGFloat(row) * (swatchSize + padding)
            let swatchRect = NSRect(x: x, y: y, width: swatchSize, height: swatchSize)
            if swatchRect.contains(point) {
                return color
            }
        }
        return nil
    }

    // MARK: - Annotation Creation

    private func startAnnotation(at point: NSPoint) {
        guard selectionRect.contains(point) else { return }

        switch currentTool {
        case .text:
            showTextField(at: point)
            return
        case .number:
            numberCounter += 1
            let annotation = Annotation(tool: .number, startPoint: point, endPoint: point, color: currentColor, strokeWidth: currentStrokeWidth)
            annotation.number = numberCounter
            annotations.append(annotation)
            redoStack.removeAll()
            needsDisplay = true
            return
        default:
            break
        }

        let annotation = Annotation(tool: currentTool, startPoint: point, endPoint: point, color: currentColor, strokeWidth: currentStrokeWidth)
        if currentTool == .pencil || currentTool == .marker {
            annotation.points = [point]
        }
        if currentTool == .pixelate || currentTool == .blur {
            annotation.sourceImage = screenshotImage
            annotation.sourceImageBounds = bounds
        }
        currentAnnotation = annotation
    }

    private func updateAnnotation(at point: NSPoint, shiftHeld: Bool = false) {
        guard let annotation = currentAnnotation else { return }
        var clampedPoint = NSPoint(
            x: max(selectionRect.minX, min(point.x, selectionRect.maxX)),
            y: max(selectionRect.minY, min(point.y, selectionRect.maxY))
        )

        if shiftHeld {
            let start = annotation.startPoint
            let dx = clampedPoint.x - start.x
            let dy = clampedPoint.y - start.y

            switch annotation.tool {
            case .line, .arrow:
                // Snap to nearest 45° angle
                let angle = atan2(dy, dx)
                let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
                let distance = hypot(dx, dy)
                clampedPoint = NSPoint(
                    x: start.x + distance * cos(snapped),
                    y: start.y + distance * sin(snapped)
                )
            case .rectangle, .filledRectangle, .ellipse, .pixelate, .blur:
                // Constrain to square/circle: use the larger dimension
                let side = max(abs(dx), abs(dy))
                clampedPoint = NSPoint(
                    x: start.x + side * (dx >= 0 ? 1 : -1),
                    y: start.y + side * (dy >= 0 ? 1 : -1)
                )
            default:
                break
            }
        }

        annotation.endPoint = clampedPoint

        if annotation.tool == .pencil || annotation.tool == .marker {
            annotation.points?.append(clampedPoint)
        }
    }

    private func finishAnnotation(_ annotation: Annotation) {
        let dx = abs(annotation.endPoint.x - annotation.startPoint.x)
        let dy = abs(annotation.endPoint.y - annotation.startPoint.y)

        if annotation.tool == .pencil || annotation.tool == .marker {
            if let points = annotation.points, points.count > 2 {
                annotation.bakePixelate()  // no-op for non-pixelate tools
                annotations.append(annotation)
                redoStack.removeAll()
            }
        } else if dx > 2 || dy > 2 {
            annotation.bakePixelate()  // bake pixelate result and release screenshot ref
            annotations.append(annotation)
            redoStack.removeAll()
        }
        currentAnnotation = nil
        needsDisplay = true
    }

    // MARK: - Text Field

    private func showTextField(at point: NSPoint) {
        let height = max(28, textFontSize + 12)
        let scrollView = NSScrollView(frame: NSRect(x: point.x, y: point.y - 10, width: 250, height: height))
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .lineBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.white.withAlphaComponent(0.9)

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 246, height: height - 4))
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = true
        tv.allowsUndo = true
        tv.backgroundColor = .clear
        tv.isFieldEditor = false
        tv.textColor = currentColor
        tv.insertionPointColor = currentColor
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.delegate = self

        let font = currentTextFont()
        tv.typingAttributes = [
            .font: font,
            .foregroundColor: currentColor
        ]

        scrollView.documentView = tv
        addSubview(scrollView)
        textScrollView = scrollView
        textEditView = tv

        // Control bar above the text field
        let barHeight: CGFloat = 28
        let barWidth: CGFloat = 260
        let barX = point.x
        let barY = scrollView.frame.maxY + 4
        let bar = NSView(frame: NSRect(x: barX, y: barY, width: barWidth, height: barHeight))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        bar.layer?.cornerRadius = 5

        let btnH: CGFloat = 24
        let btnY: CGFloat = (barHeight - btnH) / 2
        var btnX: CGFloat = 4

        // Bold
        let boldBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 28, height: btnH),
                                        title: "B", font: NSFont.boldSystemFont(ofSize: 12),
                                        active: textBold, action: #selector(textBoldToggle(_:)), tag: 100)
        bar.addSubview(boldBtn)
        btnX += 28

        // Italic
        let italicFont = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        let italicBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 28, height: btnH),
                                          title: "I", font: italicFont,
                                          active: textItalic, action: #selector(textItalicToggle(_:)), tag: 101)
        bar.addSubview(italicBtn)
        btnX += 28

        // Underline
        let uBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 28, height: btnH),
                                     title: "U", font: NSFont.systemFont(ofSize: 12),
                                     active: textUnderline, action: #selector(textUnderlineToggle(_:)), tag: 102)
        // Add underline to the button title
        let uAttr = NSMutableAttributedString(string: "U", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: textUnderline ? ToolbarLayout.accentColor : NSColor.white,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
        uBtn.attributedTitle = uAttr
        bar.addSubview(uBtn)
        btnX += 28

        // Strikethrough
        let sBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 28, height: btnH),
                                     title: "S", font: NSFont.systemFont(ofSize: 12),
                                     active: textStrikethrough, action: #selector(textStrikethroughToggle(_:)), tag: 103)
        let sAttr = NSMutableAttributedString(string: "S", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: textStrikethrough ? ToolbarLayout.accentColor : NSColor.white,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue
        ])
        sBtn.attributedTitle = sAttr
        bar.addSubview(sBtn)
        btnX += 32

        // Separator
        let sep = NSView(frame: NSRect(x: btnX, y: btnY + 2, width: 1, height: btnH - 4))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        bar.addSubview(sep)
        btnX += 5

        // Font size decrease
        let minusBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 24, height: btnH),
                                         title: "−", font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                         active: false, action: #selector(textSizeDecrease(_:)), tag: 0)
        bar.addSubview(minusBtn)
        btnX += 24

        // Font size label
        let sizeLabel = NSTextField(labelWithString: "\(Int(textFontSize))")
        sizeLabel.frame = NSRect(x: btnX, y: btnY, width: 28, height: btnH)
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        sizeLabel.textColor = .white
        sizeLabel.alignment = .center
        sizeLabel.tag = 999
        bar.addSubview(sizeLabel)
        btnX += 28

        // Font size increase
        let plusBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 24, height: btnH),
                                        title: "+", font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                        active: false, action: #selector(textSizeIncrease(_:)), tag: 0)
        bar.addSubview(plusBtn)
        btnX += 28

        // Separator
        let sep2 = NSView(frame: NSRect(x: btnX, y: btnY + 2, width: 1, height: btnH - 4))
        sep2.wantsLayer = true
        sep2.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        bar.addSubview(sep2)
        btnX += 5

        // Cancel (X) button
        let cancelBtn = makeTextBarButton(frame: NSRect(x: btnX, y: btnY, width: 24, height: btnH),
                                          title: "✕", font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                          active: false, action: #selector(textCancelClicked(_:)), tag: 0)
        cancelBtn.contentTintColor = .systemRed
        bar.addSubview(cancelBtn)

        addSubview(bar)
        textControlBar = bar

        window?.makeFirstResponder(tv)
    }

    private func currentTextFont() -> NSFont {
        if textBold && textItalic {
            return NSFontManager.shared.convert(NSFont.systemFont(ofSize: textFontSize, weight: .bold), toHaveTrait: .italicFontMask)
        } else if textItalic {
            return NSFontManager.shared.convert(NSFont.systemFont(ofSize: textFontSize), toHaveTrait: .italicFontMask)
        } else {
            return NSFont.systemFont(ofSize: textFontSize, weight: textBold ? .bold : .regular)
        }
    }

    private func selectedOrAllRange() -> NSRange {
        guard let tv = textEditView else { return NSRange(location: 0, length: 0) }
        let sel = tv.selectedRange()
        if sel.length > 0 { return sel }
        return NSRange(location: 0, length: tv.textStorage?.length ?? 0)
    }

    private func makeTextBarButton(frame: NSRect, title: String, font: NSFont, active: Bool, action: Selector, tag: Int) -> HoverButton {
        let btn = HoverButton(frame: frame)
        btn.bezelStyle = .smallSquare
        btn.isBordered = false
        btn.title = title
        btn.font = font
        btn.contentTintColor = active ? ToolbarLayout.accentColor : .white
        btn.target = self
        btn.action = action
        btn.tag = tag
        return btn
    }

    @objc private func textBoldToggle(_ sender: NSButton) {
        guard let tv = textEditView, let ts = tv.textStorage else { return }
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.font, in: range) { value, attrRange, _ in
                if let font = value as? NSFont {
                    let fm = NSFontManager.shared
                    let isBold = fm.traits(of: font).contains(.boldFontMask)
                    let newFont = isBold ? fm.convert(font, toNotHaveTrait: .boldFontMask) : fm.convert(font, toHaveTrait: .boldFontMask)
                    ts.addAttribute(.font, value: newFont, range: attrRange)
                }
            }
            ts.endEditing()
        }
        textBold.toggle()
        sender.contentTintColor = textBold ? ToolbarLayout.accentColor : .white
        tv.typingAttributes[.font] = currentTextFont()
        window?.makeFirstResponder(tv)
    }

    @objc private func textItalicToggle(_ sender: NSButton) {
        guard let tv = textEditView, let ts = tv.textStorage else { return }
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.font, in: range) { value, attrRange, _ in
                if let font = value as? NSFont {
                    let fm = NSFontManager.shared
                    let isItalic = fm.traits(of: font).contains(.italicFontMask)
                    let newFont = isItalic ? fm.convert(font, toNotHaveTrait: .italicFontMask) : fm.convert(font, toHaveTrait: .italicFontMask)
                    ts.addAttribute(.font, value: newFont, range: attrRange)
                }
            }
            ts.endEditing()
        }
        textItalic.toggle()
        sender.contentTintColor = textItalic ? ToolbarLayout.accentColor : .white
        tv.typingAttributes[.font] = currentTextFont()
        window?.makeFirstResponder(tv)
    }

    @objc private func textUnderlineToggle(_ sender: NSButton) {
        guard let tv = textEditView, let ts = tv.textStorage else { return }
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.underlineStyle, in: range) { value, attrRange, _ in
                let current = (value as? Int) ?? 0
                if current != 0 {
                    ts.removeAttribute(.underlineStyle, range: attrRange)
                } else {
                    ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: attrRange)
                }
            }
            ts.endEditing()
        }
        textUnderline.toggle()
        let uAttr = NSMutableAttributedString(string: "U", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: textUnderline ? ToolbarLayout.accentColor : NSColor.white,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ])
        sender.attributedTitle = uAttr
        if textUnderline {
            tv.typingAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else {
            tv.typingAttributes.removeValue(forKey: .underlineStyle)
        }
        window?.makeFirstResponder(tv)
    }

    @objc private func textStrikethroughToggle(_ sender: NSButton) {
        guard let tv = textEditView, let ts = tv.textStorage else { return }
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.strikethroughStyle, in: range) { value, attrRange, _ in
                let current = (value as? Int) ?? 0
                if current != 0 {
                    ts.removeAttribute(.strikethroughStyle, range: attrRange)
                } else {
                    ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: attrRange)
                }
            }
            ts.endEditing()
        }
        textStrikethrough.toggle()
        let sAttr = NSMutableAttributedString(string: "S", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: textStrikethrough ? ToolbarLayout.accentColor : NSColor.white,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue
        ])
        sender.attributedTitle = sAttr
        if textStrikethrough {
            tv.typingAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        } else {
            tv.typingAttributes.removeValue(forKey: .strikethroughStyle)
        }
        window?.makeFirstResponder(tv)
    }

    @objc private func textSizeDecrease(_ sender: Any) {
        textFontSize = max(10, textFontSize - 2)
        applyFontSizeToSelection()
        updateSizeLabel()
    }

    @objc private func textSizeIncrease(_ sender: Any) {
        textFontSize = min(72, textFontSize + 2)
        applyFontSizeToSelection()
        updateSizeLabel()
    }

    private func applyFontSizeToSelection() {
        guard let tv = textEditView, let ts = tv.textStorage else { return }
        let range = selectedOrAllRange()
        if range.length > 0 {
            ts.beginEditing()
            ts.enumerateAttribute(.font, in: range) { value, attrRange, _ in
                if let font = value as? NSFont {
                    let newFont = NSFontManager.shared.convert(font, toSize: textFontSize)
                    ts.addAttribute(.font, value: newFont, range: attrRange)
                }
            }
            ts.endEditing()
        }
        tv.typingAttributes[.font] = currentTextFont()
        // Resize text view
        let height = max(28, textFontSize + 12)
        if let sv = textScrollView {
            sv.frame.size.height = height
            if let bar = textControlBar {
                bar.frame.origin.y = sv.frame.maxY + 4
            }
        }
        window?.makeFirstResponder(tv)
    }

    @objc private func textCancelClicked(_ sender: Any) {
        textScrollView?.removeFromSuperview()
        textScrollView = nil
        textEditView = nil
        textControlBar?.removeFromSuperview()
        textControlBar = nil
        window?.makeFirstResponder(self)
    }

    private func updateSizeLabel() {
        guard let bar = textControlBar,
              let label = bar.viewWithTag(999) as? NSTextField else { return }
        label.stringValue = "\(Int(textFontSize))"
    }

    private func commitTextFieldIfNeeded() {
        guard let tv = textEditView, let sv = textScrollView else { return }
        let text = tv.string
        if !text.isEmpty {
            let annotation = Annotation(tool: .text, startPoint: sv.frame.origin, endPoint: sv.frame.origin, color: currentColor, strokeWidth: currentStrokeWidth)
            annotation.attributedText = NSAttributedString(attributedString: tv.textStorage!)
            annotation.text = text
            annotation.fontSize = textFontSize
            annotation.isBold = textBold
            annotations.append(annotation)
            redoStack.removeAll()
        }
        sv.removeFromSuperview()
        textScrollView = nil
        textEditView = nil
        textControlBar?.removeFromSuperview()
        textControlBar = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func flagsChanged(with event: NSEvent) {
        // Re-apply shift constraint immediately when Shift is pressed/released during annotation drag
        if currentAnnotation != nil, let lastPoint = lastDragPoint {
            let shiftHeld = event.modifierFlags.contains(.shift)
            updateAnnotation(at: lastPoint, shiftHeld: shiftHeld)
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            if textEditView != nil {
                textScrollView?.removeFromSuperview()
                textScrollView = nil
                textEditView = nil
                textControlBar?.removeFromSuperview()
                textControlBar = nil
                window?.makeFirstResponder(self)
            } else if showColorPicker {
                showColorPicker = false
                needsDisplay = true
            } else {
                overlayDelegate?.overlayViewDidCancel()
            }
        case 36: // Return/Enter
            commitTextFieldIfNeeded()
            if state == .selected {
                overlayDelegate?.overlayViewDidConfirm()
            }
        default:
            if event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "z" {
                    if event.modifierFlags.contains(.shift) {
                        redo()
                    } else {
                        undo()
                    }
                    return
                }
                if event.charactersIgnoringModifiers == "c" {
                    if state == .selected {
                        overlayDelegate?.overlayViewDidConfirm()
                    }
                    return
                }
                if event.charactersIgnoringModifiers == "s" {
                    if state == .selected {
                        overlayDelegate?.overlayViewDidRequestSave()
                    }
                    return
                }
            }
            super.keyDown(with: event)
        }
    }

    // MARK: - Undo/Redo

    func undo() {
        if let last = annotations.popLast() {
            redoStack.append(last)
            if last.tool == .number { numberCounter = max(0, numberCounter - 1) }
            needsDisplay = true
        }
    }

    func redo() {
        if let annotation = redoStack.popLast() {
            annotations.append(annotation)
            if annotation.tool == .number { numberCounter += 1 }
            needsDisplay = true
        }
    }

    // MARK: - Output

    func captureSelectedRegion() -> NSImage? {
        guard selectionRect.width > 0, selectionRect.height > 0 else { return nil }

        let image = NSImage(size: selectionRect.size)
        image.lockFocus()

        guard let context = NSGraphicsContext.current else {
            image.unlockFocus()
            return nil
        }

        context.cgContext.translateBy(x: -selectionRect.origin.x, y: -selectionRect.origin.y)

        if let screenshot = screenshotImage {
            screenshot.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)
        }

        for annotation in annotations {
            annotation.draw(in: context)
        }

        image.unlockFocus()
        return image
    }

    func copyToClipboard() {
        guard let image = captureSelectedRegion() else { return }
        guard let tiffData = image.tiffRepresentation else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(tiffData, forType: .tiff)
        if let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            pasteboard.setData(pngData, forType: .png)
        }
    }

    // MARK: - Cleanup

    func reset() {
        state = .idle
        selectionRect = .zero
        annotations.removeAll()
        redoStack.removeAll()
        currentAnnotation = nil
        numberCounter = 0
        showToolbars = false
        showColorPicker = false
        moveMode = false
        beautifyEnabled = false
        beautifyStyleIndex = 0
        textScrollView?.removeFromSuperview()
        textScrollView = nil
        textEditView = nil
        textControlBar?.removeFromSuperview()
        textControlBar = nil
        sizeInputField?.removeFromSuperview()
        sizeInputField = nil
        needsDisplay = true
    }
}

// MARK: - NSTextFieldDelegate

extension OverlayView: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control.tag == 888 else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitSizeInputIfNeeded()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            sizeInputField?.removeFromSuperview()
            sizeInputField = nil
            window?.makeFirstResponder(self)
            needsDisplay = true
            return true
        }
        return false
    }
}

// MARK: - NSTextViewDelegate

extension OverlayView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitTextFieldIfNeeded()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textScrollView?.removeFromSuperview()
            textScrollView = nil
            textEditView = nil
            textControlBar?.removeFromSuperview()
            textControlBar = nil
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }
}

// MARK: - HoverButton

class HoverButton: NSButton {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        layer?.cornerRadius = 4
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
}
