import Cocoa
import QuickLookUI

enum ImageContextTransform: Int {
    case rotateLeft
    case rotateRight
    case flipHorizontal
    case flipVertical

    var title: String {
        switch self {
        case .rotateLeft: return L("Rotate Left")
        case .rotateRight: return L("Rotate Right")
        case .flipHorizontal: return L("Flip Horizontal")
        case .flipVertical: return L("Flip Vertical")
        }
    }

    var symbolName: String {
        switch self {
        case .rotateLeft: return "rotate.left"
        case .rotateRight: return "rotate.right"
        case .flipHorizontal: return "flip.horizontal"
        case .flipVertical: return "flip.vertical"
        }
    }
}

extension NSImage {
    func macshotTransformed(_ transform: ImageContextTransform) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }

        let sourceSize = size
        let outputSize: NSSize
        switch transform {
        case .rotateLeft, .rotateRight:
            outputSize = NSSize(width: sourceSize.height, height: sourceSize.width)
        case .flipHorizontal, .flipVertical:
            outputSize = sourceSize
        }

        return NSImage(size: outputSize, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.interpolationQuality = .high

            switch transform {
            case .rotateLeft:
                context.translateBy(x: sourceSize.height, y: 0)
                context.rotate(by: .pi / 2)
            case .rotateRight:
                context.translateBy(x: 0, y: sourceSize.width)
                context.rotate(by: -.pi / 2)
            case .flipHorizontal:
                context.translateBy(x: sourceSize.width, y: 0)
                context.scaleBy(x: -1, y: 1)
            case .flipVertical:
                context.translateBy(x: 0, y: sourceSize.height)
                context.scaleBy(x: 1, y: -1)
            }

            self.draw(
                in: NSRect(origin: .zero, size: sourceSize),
                from: .zero,
                operation: .copy,
                fraction: 1.0
            )
            return true
        }
    }
}

enum ImageContextMenu {
    static func item(
        title: String,
        symbolName: String?,
        action: Selector?,
        target: AnyObject?,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        if let symbolName,
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            item.image = image
        }
        return item
    }

    static func addTransformItems(
        to menu: NSMenu,
        target: AnyObject,
        action: Selector,
        representedObject: Any? = nil
    ) {
        for transform in [ImageContextTransform.rotateLeft, .rotateRight, .flipHorizontal, .flipVertical] {
            let item = item(
                title: transform.title,
                symbolName: transform.symbolName,
                action: action,
                target: target
            )
            item.tag = transform.rawValue
            item.representedObject = representedObject
            menu.addItem(item)
        }
    }

    static func openWithItem(fileURL: URL, target: AnyObject, action: Selector) -> NSMenuItem {
        let root = item(title: L("Open With"), symbolName: "arrow.up.right.square", action: nil, target: nil)
        let submenu = NSMenu()
        let appURLs = orderedApplicationURLs(for: fileURL)
        if appURLs.isEmpty {
            let empty = NSMenuItem(title: L("No Apps Available"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for appURL in appURLs {
                let appItem = NSMenuItem(title: applicationDisplayName(for: appURL), action: action, keyEquivalent: "")
                appItem.target = target
                appItem.representedObject = appURL
                appItem.image = NSWorkspace.shared.icon(forFile: appURL.path)
                appItem.image?.size = NSSize(width: 16, height: 16)
                submenu.addItem(appItem)
            }
        }
        root.submenu = submenu
        return root
    }

    static func shareItem(fileURL: URL, target: AnyObject, action: Selector) -> NSMenuItem {
        let root = item(title: L("Share"), symbolName: "square.and.arrow.up", action: nil, target: nil)
        let submenu = NSMenu()
        let services = NSSharingService.sharingServices(forItems: [fileURL])
        if services.isEmpty {
            let empty = NSMenuItem(title: L("No Share Services"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for service in services {
                let serviceItem = NSMenuItem(title: service.title, action: action, keyEquivalent: "")
                serviceItem.target = target
                serviceItem.representedObject = service
                serviceItem.image = service.image
                serviceItem.image?.size = NSSize(width: 16, height: 16)
                submenu.addItem(serviceItem)
            }
        }
        root.submenu = submenu
        return root
    }

    private static func orderedApplicationURLs(for fileURL: URL) -> [URL] {
        var result: [URL] = []
        if let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: fileURL) {
            result.append(defaultApp)
        }
        for appURL in NSWorkspace.shared.urlsForApplications(toOpen: fileURL) {
            if !result.contains(appURL) {
                result.append(appURL)
            }
        }
        return result
    }

    private static func applicationDisplayName(for appURL: URL) -> String {
        if let bundle = Bundle(url: appURL) {
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty {
                return name
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
                return name
            }
        }
        return appURL.deletingPathExtension().lastPathComponent
    }
}

enum FloatingThumbnailCorner: String {
    case bottomRight
    case bottomLeft
    case topRight
    case topLeft

    var isLeft: Bool {
        self == .bottomLeft || self == .topLeft
    }

    var isTop: Bool {
        self == .topLeft || self == .topRight
    }
}

private enum ThumbnailDismissGesture {
    case mouseDrag
    case scroll
}

@MainActor
class FloatingThumbnailController: NSObject, NSDraggingSource, QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    private var window: NSPanel?
    private var dismissTask: DispatchWorkItem?
    private(set) var image: NSImage
    private var thumbnailView: ThumbnailView?
    private var corner: FloatingThumbnailCorner = .bottomRight
    /// History entry ID — used to match and update the thumbnail when the editor saves.
    var historyEntryID: String?
    /// The intended final frame — used instead of window.frame to avoid reading
    /// intermediate positions during slide-in or reflow animations.
    private var targetFrame: NSRect = .zero
    private var dismissDragStartFrame: NSRect?
    private var isInteractiveDismissActive = false
    private var isScrollDismissHostActive = false
    private var quickLookURL: URL?
    var onDismiss: (() -> Void)?

    // Action callbacks
    var onCopy:     (() -> Void)?
    var onSave:     (() -> Void)?
    var onSaveAs:   (() -> Void)?
    var onPin:      (() -> Void)?
    var onEdit:     (() -> Void)?
    var onUpload:   (() -> Void)?
    var onDelete:   (() -> Void)?
    var onCloseAll: (() -> Void)?
    var onSaveAll:  (() -> Void)?
    var onTransform: ((NSImage) -> Void)?
    var onOCR: (() -> Void)?

    init(image: NSImage) {
        self.image = image
        super.init()
    }

    static func currentThumbnailSize() -> NSSize {
        let scale = CGFloat(UserDefaults.standard.object(forKey: "thumbnailScale") as? Double ?? 1.0)
        return NSSize(width: round(240 * scale), height: round(160 * scale))
    }

    // MARK: - Show

    func show(at origin: NSPoint, corner: FloatingThumbnailCorner) {
        self.corner = corner
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let screenFrame = screen.visibleFrame

        // Fit image within max bounds preserving aspect ratio, then enforce
        // a minimum window size so hover buttons always fit (letterbox if needed).
        let padding: CGFloat = 16
        guard image.size.width > 0 && image.size.height > 0 else { return }

        // Fixed thumbnail size scaled by user preference (default 1.0 = 240x160)
        let thumbSize = Self.currentThumbnailSize()

        // Clamp so the thumbnail always fits within the visible screen.
        let clampedX = min(origin.x, screenFrame.maxX - thumbSize.width - padding)
        let finalX = max(screenFrame.minX + padding, clampedX)
        let clampedY = min(origin.y, screenFrame.maxY - thumbSize.height - padding)
        let finalY   = max(screenFrame.minY + padding, clampedY)

        let startX = corner.isLeft ? screenFrame.minX - thumbSize.width - 10 : screenFrame.maxX + 10

        let panel = NSPanel(
            contentRect: NSRect(x: startX, y: finalY, width: thumbSize.width, height: thumbSize.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.acceptsMouseMovedEvents = true

        let view = ThumbnailView(image: image, thumbSize: thumbSize)
        view.frame = NSRect(origin: .zero, size: thumbSize)
        view.autoresizingMask = [.width, .height]
        view.dismissesTowardLeft = corner.isLeft

        view.onDragStarted = { [weak self] event in self?.startDrag(event: event) }
        view.onDismissDragStarted = { [weak self] kind in self?.beginDismissDrag(kind: kind) }
        view.onDismissDragChanged = { [weak self] offset in self?.updateDismissDrag(offset: offset) }
        view.onDismissDragEnded = { [weak self] offset in self?.endDismissDrag(offset: offset) }
        view.onDismissDragCancelled = { [weak self] in self?.cancelDismissDrag() }
        view.onContextMenu = { [weak self] event, view in self?.showContextMenu(event: event, in: view) }
        view.onClose    = { [weak self] in self?.dismiss() }
        view.onCopy     = { [weak self] in self?.onCopy?();     self?.dismiss() }
        view.onSave     = { [weak self] in self?.onSave?();     self?.dismiss() }
        view.onPin      = { [weak self] in self?.onPin?();      self?.dismiss() }
        view.onEdit     = { [weak self] in self?.onEdit?();     self?.dismiss() }
        view.onUpload   = { [weak self] in self?.onUpload?();   self?.dismiss() }
        view.onDelete   = { [weak self] in self?.onDelete?();   self?.dismiss() }
        view.onCloseAll = { [weak self] in self?.onCloseAll?() }
        view.onSaveAll  = { [weak self] in self?.onSaveAll?() }
        view.onHoverEnter = { [weak self] in self?.pauseAutoDismiss() }
        view.onHoverExit  = { [weak self] in self?.scheduleAutoDismiss() }

        panel.contentView = view
        self.window = panel
        self.thumbnailView = view

        let finalFrame = NSRect(x: finalX, y: finalY, width: thumbSize.width, height: thumbSize.height)
        targetFrame = finalFrame

        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
        })

        scheduleAutoDismiss()
    }

    private func pauseAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func scheduleAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        let seconds = UserDefaults.standard.object(forKey: "thumbnailAutoDismiss") as? Int ?? 5
        guard seconds > 0 else { return }
        let task = DispatchWorkItem { [weak self] in self?.animateOut() }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds), execute: task)
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        isInteractiveDismissActive = false
        isScrollDismissHostActive = false
        dismissDragStartFrame = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        thumbnailView = nil
        onDismiss?()
        onDismiss = nil
    }

    var windowFrame: NSRect { targetFrame }

    /// The CGWindowID of the thumbnail panel, used for ScreenCaptureKit exclusion.
    var windowNumber: CGWindowID? {
        guard let w = window else { return nil }
        return CGWindowID(w.windowNumber)
    }

    func hideWindow() { window?.orderOut(nil) }
    func showWindow() { window?.orderFront(nil) }

    /// Update the displayed image (e.g. after editor saves new annotations).
    func updateImage(_ newImage: NSImage) {
        image = newImage
        thumbnailView?.updateImage(newImage)
    }

    private func makeCurrentImageFileURL() -> URL? {
        guard let encodedData = ImageEncoder.encode(image) else { return nil }
        let url = TmpScratchDirectory.makeURL(filename: FilenameFormatter.defaultImageFilename())
        do {
            try encodedData.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func showContextMenu(event: NSEvent, in view: NSView) {
        let menu = NSMenu()

        let copyItem = ImageContextMenu.item(title: L("Copy"), symbolName: "doc.on.doc", action: #selector(contextCopy), target: self, keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command]
        menu.addItem(copyItem)

        menu.addItem(ImageContextMenu.item(title: L("Save"), symbolName: "square.and.arrow.down", action: #selector(contextSave), target: self))
        menu.addItem(ImageContextMenu.item(title: L("Save As..."), symbolName: "square.and.arrow.down.on.square", action: #selector(contextSaveAs), target: self))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(ImageContextMenu.item(title: L("Open in Editor"), symbolName: "pencil", action: #selector(contextOpenEditor), target: self, keyEquivalent: "e"))
        menu.addItem(ImageContextMenu.item(title: L("Pin to Screen"), symbolName: "pin.fill", action: #selector(contextPin), target: self))
        menu.addItem(ImageContextMenu.item(title: L("Upload"), symbolName: "icloud.and.arrow.up", action: #selector(contextUpload), target: self))
        menu.addItem(ImageContextMenu.item(title: L("Quick Look"), symbolName: "eye", action: #selector(contextQuickLook), target: self, keyEquivalent: " "))
        menu.addItem(ImageContextMenu.item(title: L("Run OCR & QR"), symbolName: "text.viewfinder", action: #selector(contextOCR), target: self))

        menu.addItem(NSMenuItem.separator())
        ImageContextMenu.addTransformItems(to: menu, target: self, action: #selector(contextTransform(_:)))

        if let fileURL = makeCurrentImageFileURL() {
            menu.addItem(NSMenuItem.separator())
            menu.addItem(ImageContextMenu.openWithItem(fileURL: fileURL, target: self, action: #selector(contextOpenWith(_:))))
            menu.addItem(ImageContextMenu.shareItem(fileURL: fileURL, target: self, action: #selector(contextShare(_:))))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(ImageContextMenu.item(title: L("Delete"), symbolName: "trash", action: #selector(contextDelete), target: self, keyEquivalent: "\u{8}"))

        menu.addItem(NSMenuItem.separator())
        menu.addItem(ImageContextMenu.item(title: L("Close All"), symbolName: "xmark.circle", action: #selector(contextCloseAll), target: self))
        menu.addItem(ImageContextMenu.item(title: L("Save All to Folder…"), symbolName: "folder", action: #selector(contextSaveAll), target: self))

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func contextCopy() { onCopy?(); dismiss() }
    @objc private func contextSave() { onSave?(); dismiss() }
    @objc private func contextSaveAs() { onSaveAs?(); dismiss() }
    @objc private func contextPin() { onPin?(); dismiss() }
    @objc private func contextUpload() { onUpload?(); dismiss() }
    @objc private func contextOpenEditor() { onEdit?(); dismiss() }
    @objc private func contextDelete() { onDelete?(); dismiss() }
    @objc private func contextCloseAll() { onCloseAll?() }
    @objc private func contextSaveAll() { onSaveAll?() }
    @objc private func contextOCR() { onOCR?() }

    @objc private func contextTransform(_ sender: NSMenuItem) {
        guard let transform = ImageContextTransform(rawValue: sender.tag),
              let transformed = image.macshotTransformed(transform) else { return }
        updateImage(transformed)
        onTransform?(transformed)
    }

    @objc private func contextQuickLook() {
        quickLookURL = makeCurrentImageFileURL()
        guard quickLookURL != nil, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func contextOpenWith(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL,
              let fileURL = makeCurrentImageFileURL() else { return }
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    @objc private func contextShare(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? NSSharingService,
              let fileURL = makeCurrentImageFileURL() else { return }
        service.perform(withItems: [fileURL])
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURL == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookURL as NSURL?
    }

    /// Animate this thumbnail to a new Y position (used when a lower thumbnail is dismissed).
    func moveTo(origin: NSPoint) {
        guard let window = window else { return }
        guard !isInteractiveDismissActive else { return }
        guard targetFrame.origin != origin else { return }
        let newFrame = NSRect(x: origin.x, y: origin.y, width: targetFrame.width, height: targetFrame.height)
        targetFrame = newFrame
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(newFrame, display: true)
        }
    }

    private func animateOut() {
        guard let window = window else { return }
        isInteractiveDismissActive = true
        if isScrollDismissHostActive {
            animateScrollDismissHostOut()
            return
        }

        let frame = window.frame
        let offscreenX = offscreenX(for: frame)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(
                NSRect(x: offscreenX, y: frame.minY, width: frame.width, height: frame.height),
                display: true
            )
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            Task { @MainActor [self] in
                self.dismiss()
            }
        })
    }

    private var dismissDirection: CGFloat {
        corner.isLeft ? -1 : 1
    }

    private func visibleScreenFrame(for frame: NSRect) -> NSRect {
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) || $0.frame.intersects(frame) }) {
            return screen.visibleFrame
        }
        return (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    }

    private func offscreenX(for frame: NSRect) -> CGFloat {
        let screenFrame = visibleScreenFrame(for: frame)
        return corner.isLeft ? screenFrame.minX - frame.width - 10 : screenFrame.maxX + 10
    }

    private func dismissCompletionThreshold(for frame: NSRect) -> CGFloat {
        min(max(frame.width * 0.05, 8), 16)
    }

    private func dismissProgressDistance(for frame: NSRect) -> CGFloat {
        dismissCompletionThreshold(for: frame) * 1.4
    }

    private func beginDismissDrag(kind: ThumbnailDismissGesture) {
        guard let window = window else { return }
        dismissTask?.cancel()
        dismissTask = nil
        isInteractiveDismissActive = true

        if dismissDragStartFrame == nil {
            let currentFrame = window.frame
            dismissDragStartFrame = currentFrame
            window.setFrame(currentFrame, display: true, animate: false)
        }

        if kind == .scroll {
            prepareScrollDismissHost()
        }
    }

    private func updateDismissDrag(offset: CGFloat) {
        guard let window = window else { return }
        if dismissDragStartFrame == nil {
            beginDismissDrag(kind: .mouseDrag)
        }
        let startFrame = dismissDragStartFrame ?? window.frame
        let clampedOffset = max(0, offset)
        let progress = min(1, clampedOffset / dismissProgressDistance(for: startFrame))

        if isScrollDismissHostActive {
            thumbnailView?.dismissContentOffsetX = clampedOffset * dismissDirection
            window.alphaValue = 1 - progress * 0.45
            return
        }

        let frame = NSRect(
            x: startFrame.minX + clampedOffset * dismissDirection,
            y: startFrame.minY,
            width: startFrame.width,
            height: startFrame.height
        )
        window.setFrame(frame, display: true)
        window.alphaValue = 1 - progress * 0.45
    }

    private func endDismissDrag(offset: CGFloat) {
        let startFrame = dismissDragStartFrame ?? targetFrame
        if offset >= dismissCompletionThreshold(for: startFrame) {
            dismissDragStartFrame = nil
            animateOut()
        } else {
            cancelDismissDrag()
        }
    }

    private func cancelDismissDrag() {
        guard let window = window else { return }
        let restoreFrame = dismissDragStartFrame ?? targetFrame
        let wasScrollDismissHostActive = isScrollDismissHostActive
        dismissDragStartFrame = nil
        isInteractiveDismissActive = false
        isScrollDismissHostActive = false

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if wasScrollDismissHostActive {
                thumbnailView?.animator().dismissContentOffsetX = 0
            } else {
                window.animator().setFrame(restoreFrame, display: true)
            }
            window.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            Task { @MainActor [self] in
                if wasScrollDismissHostActive, let window = self.window {
                    window.setFrame(self.targetFrame, display: true, animate: false)
                    self.thumbnailView?.resetDismissContentPosition()
                }
            }
        })
    }

    private func prepareScrollDismissHost() {
        guard let window = window, !isScrollDismissHostActive else { return }
        let startFrame = dismissDragStartFrame ?? window.frame
        let offscreenX = offscreenX(for: startFrame)
        let hostX = min(startFrame.minX, offscreenX)
        let hostMaxX = max(startFrame.maxX, offscreenX + startFrame.width)
        let hostFrame = NSRect(
            x: hostX,
            y: startFrame.minY,
            width: hostMaxX - hostX,
            height: startFrame.height
        )

        isScrollDismissHostActive = true
        window.setFrame(hostFrame, display: true, animate: false)
        thumbnailView?.dismissContentBaseX = startFrame.minX - hostFrame.minX
        thumbnailView?.dismissContentOffsetX = 0
    }

    private func animateScrollDismissHostOut() {
        guard let window = window else { return }
        let startFrame = dismissDragStartFrame ?? targetFrame
        let finalOffset = offscreenX(for: startFrame) - startFrame.minX

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            thumbnailView?.animator().dismissContentOffsetX = finalOffset
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            Task { @MainActor [self] in
                self.dismiss()
            }
        })
    }

    // MARK: - Drag as file

    private func startDrag(event: NSEvent) {
        guard let view = thumbnailView else { return }
        guard let encodedData = ImageEncoder.encode(image) else { return }

        let tempURL = TmpScratchDirectory.makeURL(filename: FilenameFormatter.defaultImageFilename())
        do { try encodedData.write(to: tempURL) } catch { return }

        let draggingItem = NSDraggingItem(pasteboardWriter: tempURL as NSURL)
        draggingItem.setDraggingFrame(view.bounds, contents: image)
        view.beginDraggingSession(with: [draggingItem], event: event, source: self)
        dismissTask?.cancel()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dismiss() }
}

// MARK: - Thumbnail View

private class ThumbnailView: NSView {

    var onDragStarted: ((NSEvent) -> Void)?
    var onClose:    (() -> Void)?
    var onCopy:     (() -> Void)?
    var onSave:     (() -> Void)?
    var onPin:      (() -> Void)?
    var onEdit:     (() -> Void)?
    var onUpload:   (() -> Void)?
    var onDelete:   (() -> Void)?
    var onCloseAll: (() -> Void)?
    var onSaveAll:  (() -> Void)?
    var onHoverEnter: (() -> Void)?
    var onHoverExit:  (() -> Void)?
    var onDismissDragStarted: ((ThumbnailDismissGesture) -> Void)?
    var onDismissDragChanged: ((CGFloat) -> Void)?
    var onDismissDragEnded: ((CGFloat) -> Void)?
    var onDismissDragCancelled: (() -> Void)?
    var onContextMenu: ((NSEvent, NSView) -> Void)?
    var dismissesTowardLeft: Bool = false
    @objc dynamic var dismissContentBaseX: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    @objc dynamic var dismissContentOffsetX: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    private var image: NSImage
    private let thumbSize: NSSize
    private var dragStartScreenPoint: NSPoint?
    private var dragMode: DragMode = .idle
    private var dismissDragOffset: CGFloat = 0
    private var scrollDismissOffset: CGFloat = 0
    private var isScrollDismissing: Bool = false
    private var scrollGestureStartedOnButton: Bool = false
    private var scrollDismissEndTask: DispatchWorkItem?
    private var scrollDismissGlobalMonitor: Any?
    private var scrollDismissLocalMonitor: Any?
    private var isHovering: Bool = false
    private var trackingArea: NSTrackingArea?

    // Corner button hit rects (in view coords, updated in draw)
    private var closeBtnRect:  NSRect = .zero
    private var pinBtnRect:    NSRect = .zero
    private var editBtnRect:   NSRect = .zero
    private var uploadBtnRect: NSRect = .zero
    private var copyBtnRect:   NSRect = .zero
    private var saveBtnRect:   NSRect = .zero

    private var hoveredRect: NSRect = .zero

    private enum DragMode {
        case idle
        case button
        case pending
        case dismissing
        case exporting
    }

    private struct ScrollDismissSample {
        let rawDX: CGFloat
        let rawDY: CGFloat
        let didBegin: Bool
        let didEnd: Bool
        let hasGesturePhase: Bool
        let isTrackpadLike: Bool
    }

    deinit {
        removeScrollDismissMonitors()
    }

    func resetDismissContentPosition() {
        dismissContentBaseX = 0
        dismissContentOffsetX = 0
        frame = NSRect(origin: .zero, size: thumbSize)
        needsDisplay = true
    }

    private var controlScale: CGFloat {
        guard thumbSize.width > 0, thumbSize.height > 0 else { return 1 }
        let baseScale = min(bounds.width / 240, bounds.height / 160)
        return min(max(baseScale, 0.55), 2.0)
    }

    private var thumbnailDrawRect: NSRect {
        NSRect(
            x: dismissContentBaseX + dismissContentOffsetX,
            y: 0,
            width: thumbSize.width,
            height: thumbSize.height
        )
    }

    private func scaled(_ value: CGFloat, minimum: CGFloat = 0) -> CGFloat {
        max(minimum, round(value * controlScale))
    }

    init(image: NSImage, thumbSize: NSSize) {
        self.image = image
        self.thumbSize = thumbSize
        super.init(frame: .zero)
        updateTrackingArea()
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateImage(_ newImage: NSImage) {
        image = newImage
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
        onHoverEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        hoveredRect = .zero
        needsDisplay = true
        onHoverExit?()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let rects = [closeBtnRect, pinBtnRect, editBtnRect, uploadBtnRect, copyBtnRect, saveBtnRect]
        let hit = rects.first { $0.contains(p) } ?? .zero
        if hit != hoveredRect {
            hoveredRect = hit
            needsDisplay = true
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let r = thumbnailDrawRect
        let cr: CGFloat = 12

        // Rounded clip for entire thumbnail
        let path = NSBezierPath(roundedRect: r, xRadius: cr, yRadius: cr)
        path.addClip()

        // Dark background (visible as letterbox bars for extreme aspect ratios)
        NSColor(white: 0.12, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: r, xRadius: cr, yRadius: cr).fill()

        // Draw image with aspect fill (cropped to fill, no letterboxing)
        let imgAspect = image.size.width / image.size.height
        let viewAspect = r.width / r.height
        var drawW: CGFloat
        var drawH: CGFloat
        if imgAspect > viewAspect {
            // Image is wider than view — fill height, crop sides
            drawH = r.height
            drawW = drawH * imgAspect
        } else {
            // Image is taller than view — fill width, crop top/bottom
            drawW = r.width
            drawH = drawW / imgAspect
        }
        let drawRect = NSRect(
            x: r.midX - drawW / 2,
            y: r.midY - drawH / 2,
            width: drawW,
            height: drawH
        )
        image.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)

        // White border
        NSColor.white.withAlphaComponent(0.4).setStroke()
        let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: cr, yRadius: cr)
        border.lineWidth = 1.5
        border.stroke()

        guard isHovering else { return }

        // Semi-transparent dark overlay
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: r, xRadius: cr, yRadius: cr).fill()

        let pad = scaled(10, minimum: 5)
        let cornerD = scaled(28, minimum: 18)

        // Corner button definitions: (center, symbol, keyPath to write rect)
        let cornerDefs: [(NSPoint, String)] = [
            (NSPoint(x: r.minX + pad + cornerD/2, y: r.maxY - pad - cornerD/2), "xmark"),
            (NSPoint(x: r.maxX - pad - cornerD/2, y: r.maxY - pad - cornerD/2), "pin.fill"),
            (NSPoint(x: r.minX + pad + cornerD/2, y: r.minY + pad + cornerD/2), "pencil"),
            (NSPoint(x: r.maxX - pad - cornerD/2, y: r.minY + pad + cornerD/2), "icloud.and.arrow.up"),
        ]

        var cornerRects: [NSRect] = []
        for (center, symbol) in cornerDefs {
            let circleRect = NSRect(x: center.x - cornerD/2, y: center.y - cornerD/2, width: cornerD, height: cornerD)
            cornerRects.append(circleRect)
            let isHit = circleRect == hoveredRect

            let circlePath = NSBezierPath(ovalIn: circleRect)
            (isHit ? NSColor.white.withAlphaComponent(0.35) : NSColor.white.withAlphaComponent(0.18)).setFill()
            circlePath.fill()
            NSColor.white.withAlphaComponent(0.5).setStroke()
            circlePath.lineWidth = 1
            circlePath.stroke()

            if let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: scaled(11, minimum: 8), weight: .semibold)
                let colored = sym.withSymbolConfiguration(cfg) ?? sym
                let tinted = tintedWhite(colored)
                let iconSide = scaled(13, minimum: 9)
                let iconSize = NSSize(width: iconSide, height: iconSide)
                let iconRect = NSRect(x: center.x - iconSize.width/2, y: center.y - iconSize.height/2,
                                     width: iconSize.width, height: iconSize.height)
                tinted.draw(in: iconRect, from: NSRect.zero, operation: .sourceOver, fraction: 1.0)
            }
        }
        if cornerRects.count == 4 {
            closeBtnRect  = cornerRects[0]
            pinBtnRect    = cornerRects[1]
            editBtnRect   = cornerRects[2]
            uploadBtnRect = cornerRects[3]
        }

        // Center action buttons: Copy + Save
        let centerBtnH = scaled(32, minimum: 18)
        let centerGap = scaled(8, minimum: 4)
        let fontSize = scaled(13, minimum: 9)
        let titleFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont]
        let maxTitleW = max(
            (L("Copy") as NSString).size(withAttributes: titleAttrs).width,
            (L("Save") as NSString).size(withAttributes: titleAttrs).width
        )
        let horizontalTextPadding = scaled(32, minimum: 18)
        let preferredCenterW = max(scaled(110, minimum: 64), ceil(maxTitleW + horizontalTextPadding))
        let centerBtnW = min(r.width - pad * 2, preferredCenterW)
        let totalH = centerBtnH * 2 + centerGap
        let btnsY = r.midY - totalH/2

        let copyRect = NSRect(x: r.midX - centerBtnW/2, y: btnsY + centerBtnH + centerGap, width: centerBtnW, height: centerBtnH)
        let saveRect = NSRect(x: r.midX - centerBtnW/2, y: btnsY,                  width: centerBtnW, height: centerBtnH)
        copyBtnRect = copyRect
        saveBtnRect = saveRect

        for (rect, title) in [(copyRect, L("Copy")), (saveRect, L("Save"))] {
            let isHit = rect == hoveredRect
            let bg = NSBezierPath(roundedRect: rect, xRadius: centerBtnH/2, yRadius: centerBtnH/2)
            if isHit {
                NSColor.white.withAlphaComponent(0.95).setFill()
            } else {
                NSColor.white.withAlphaComponent(0.85).setFill()
            }
            bg.fill()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: isHit ? NSColor.black : NSColor(white: 0.1, alpha: 1),
            ]
            let str = title as NSString
            let strSize = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: rect.midX - strSize.width/2, y: rect.midY - strSize.height/2), withAttributes: attrs)
        }
    }

    private func tintedWhite(_ img: NSImage) -> NSImage {
        let result = NSImage(size: img.size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            img.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            return true
        }
        return result
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        dragStartScreenPoint = screenPoint(for: event)
        dismissDragOffset = 0
        let point = convert(event.locationInWindow, from: nil)
        dragMode = actionButtonRect(containing: point) == nil ? .pending : .button
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartScreenPoint else { return }
        let current = screenPoint(for: event)

        switch dragMode {
        case .button, .exporting:
            return
        case .dismissing:
            dismissDragOffset = max(0, (current.x - start.x) * dismissDirection)
            onDismissDragChanged?(dismissDragOffset)
            return
        case .idle, .pending:
            break
        }

        let dx = current.x - start.x
        let dy = current.y - start.y
        let distance = hypot(dx, dy)
        guard distance > 4 else { return }

        let directionalOffset = dx * dismissDirection
        let isEdgewardDismiss = directionalOffset > 6 && abs(dx) >= max(6, abs(dy) * 0.35)
        if isEdgewardDismiss {
            dragMode = .dismissing
            dismissDragOffset = directionalOffset
            onDismissDragStarted?(.mouseDrag)
            onDismissDragChanged?(dismissDragOffset)
        } else if distance > 8 {
            dragMode = .exporting
            dragStartScreenPoint = nil
            onDragStarted?(event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragMode == .dismissing {
            onDismissDragEnded?(dismissDragOffset)
            resetMouseDragState()
            return
        }

        guard dragStartScreenPoint != nil else {
            resetMouseDragState()
            return
        }
        dragStartScreenPoint = nil
        let p = convert(event.locationInWindow, from: nil)
        defer { resetMouseDragState() }

        if closeBtnRect.contains(p)  { onClose?();  return }
        if pinBtnRect.contains(p)    { onPin?();    return }
        if editBtnRect.contains(p)   { onEdit?();   return }
        if uploadBtnRect.contains(p) { onUpload?(); return }
        if copyBtnRect.contains(p)   { onCopy?();   return }
        if saveBtnRect.contains(p)   { onSave?();   return }

        // Click anywhere else on thumbnail — dismiss
        if isHovering { onClose?() }
    }

    override func scrollWheel(with event: NSEvent) {
        handleScrollDismiss(sample: Self.scrollDismissSample(from: event), isOverButton: false)
    }

    private func handleScrollDismiss(sample: ScrollDismissSample, isOverButton: Bool?) {
        guard sample.isTrackpadLike else { return }

        if sample.didBegin {
            scrollDismissOffset = 0
            isScrollDismissing = false
            scrollGestureStartedOnButton = isOverButton ?? false
            scrollDismissEndTask?.cancel()
            scrollDismissEndTask = nil
        } else if !isScrollDismissing && scrollDismissOffset == 0 && scrollDismissEndTask == nil {
            scrollGestureStartedOnButton = isOverButton ?? scrollGestureStartedOnButton
        }

        guard !scrollGestureStartedOnButton else {
            if sample.didEnd {
                scrollGestureStartedOnButton = false
            }
            return
        }
        guard isScrollDismissing || abs(sample.rawDX) > max(0.5, abs(sample.rawDY) * 0.35) else { return }

        let directionalDelta = sample.rawDX * dismissDirection
        if directionalDelta > 0 {
            if !isScrollDismissing {
                isScrollDismissing = true
                installScrollDismissMonitors()
                onDismissDragStarted?(.scroll)
            }
            scrollDismissOffset += directionalDelta
            onDismissDragChanged?(scrollDismissOffset)
            scheduleScrollDismissEnd(after: scrollDismissFallbackDelay(for: sample))
        } else if scrollDismissOffset > 0 {
            scheduleScrollDismissEnd(after: scrollDismissFallbackDelay(for: sample))
        }

        if sample.didEnd {
            scrollGestureStartedOnButton = false
            scheduleScrollDismissEnd(after: 0.04)
        }
    }

    override func swipe(with event: NSEvent) {
        let directionalDelta = event.deltaX * dismissDirection
        guard directionalDelta > 0 else { return }
        scrollDismissEndTask?.cancel()
        scrollDismissEndTask = nil
        scrollDismissOffset = 0
        isScrollDismissing = true
        scrollGestureStartedOnButton = false
        removeScrollDismissMonitors()
        onDismissDragStarted?(.scroll)
        onDismissDragChanged?(120)
        onDismissDragEnded?(120)
        isScrollDismissing = false
    }

    private var dismissDirection: CGFloat {
        dismissesTowardLeft ? -1 : 1
    }

    private func resetMouseDragState() {
        dragStartScreenPoint = nil
        dragMode = .idle
        dismissDragOffset = 0
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    private func actionButtonRect(containing point: NSPoint) -> NSRect? {
        [closeBtnRect, pinBtnRect, editBtnRect, uploadBtnRect, copyBtnRect, saveBtnRect]
            .first { !$0.isEmpty && $0.contains(point) }
    }

    private static func scrollDismissSample(from event: NSEvent) -> ScrollDismissSample {
        let didEnd = event.phase.contains(.ended)
            || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended)
            || event.momentumPhase.contains(.cancelled)
        let hasGesturePhase = event.phase != [] || event.momentumPhase != []
        return ScrollDismissSample(
            rawDX: event.scrollingDeltaX,
            rawDY: event.scrollingDeltaY,
            didBegin: event.phase.contains(.began),
            didEnd: didEnd,
            hasGesturePhase: hasGesturePhase,
            isTrackpadLike: hasGesturePhase || event.hasPreciseScrollingDeltas
        )
    }

    private func installScrollDismissMonitors() {
        guard scrollDismissGlobalMonitor == nil && scrollDismissLocalMonitor == nil else { return }

        scrollDismissGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let sample = Self.scrollDismissSample(from: event)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isScrollDismissing else { return }
                self.handleScrollDismiss(sample: sample, isOverButton: nil)
            }
        }

        scrollDismissLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, self.isScrollDismissing else { return event }
            if let eventWindow = event.window, eventWindow === self.window { return event }
            self.handleScrollDismiss(sample: Self.scrollDismissSample(from: event), isOverButton: nil)
            return event
        }
    }

    private func removeScrollDismissMonitors() {
        if let monitor = scrollDismissGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            scrollDismissGlobalMonitor = nil
        }
        if let monitor = scrollDismissLocalMonitor {
            NSEvent.removeMonitor(monitor)
            scrollDismissLocalMonitor = nil
        }
    }

    private func scheduleScrollDismissEnd(after delay: TimeInterval = 0.12) {
        scrollDismissEndTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.finishScrollDismiss()
        }
        scrollDismissEndTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func scrollDismissFallbackDelay(for sample: ScrollDismissSample) -> TimeInterval {
        sample.hasGesturePhase ? 0.8 : 0.45
    }

    private func finishScrollDismiss() {
        scrollDismissEndTask?.cancel()
        scrollDismissEndTask = nil
        removeScrollDismissMonitors()
        guard scrollDismissOffset > 0 else {
            isScrollDismissing = false
            scrollGestureStartedOnButton = false
            return
        }
        let offset = scrollDismissOffset
        scrollDismissOffset = 0
        isScrollDismissing = false
        scrollGestureStartedOnButton = false
        onDismissDragEnded?(offset)
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event, self)
    }
}
