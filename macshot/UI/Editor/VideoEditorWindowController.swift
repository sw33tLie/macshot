import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// The video editor window: inspector on the left, the framed preview in the
/// middle, transport and a multi-lane timeline at the bottom.
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {

    private static var activeControllers: [VideoEditorWindowController] = []
    private var preparationJob: MediaExportCoordinator.Job?

    private(set) var editorDocument: VideoEditorDocument!
    private(set) var playback: VideoEditorPlayback!
    var exporter: VideoEditorExporter!
    private var inspector: VideoInspectorView!
    private var stage: VideoStageView!
    private var stageToolbar: VideoStageToolbar!
    var topBar: VideoEditorTopBar!
    private var transport: VideoTransportBar!
    private var timeline: VideoTimelineView!
    private var timelineScroll: NSScrollView!
    private var gutter: VideoTimelineGutter!
    private var observerID: UUID?
    private var wasPlayingBeforeScrub = false

    // Export state
    var exportSettings = VideoExportSettings.load()
    var isExporting = false
    var activeExportJob: MediaExportCoordinator.Job?
    var activeExportToken: UUID?
    var savedURL: URL?
    var savedRevision: UInt64?
    private var statusTimer: Timer?
    private var captionTask: Task<Void, Never>?

    /// Opens a video in the editor.
    /// - Parameter deleteOnClose: Temporary input is removed after the editor
    ///   and its readers release it. Durable recordings are always retained.
    /// - Parameter exportFormat: Preselects the export format for this window
    ///   only (Record GIF opens its take ready to export a GIF). The user's
    ///   remembered format changes only if they pick one in the export panel.
    static func open(url: URL, deleteOnClose: Bool = true, exportFormat: VideoExportSettings.Format? = nil) {
        let controller = VideoEditorWindowController(window: nil)
        if let exportFormat { controller.exportSettings.format = exportFormat }
        activeControllers.append(controller)
        if activeControllers.count == 1 { NSApp.setActivationPolicy(.regular) }
        controller.prepare(url: url, deleteOnClose: deleteOnClose)
    }

    private func prepare(url: URL, deleteOnClose: Bool) {
        var prepared: PreparedVideoSource?
        let job = MediaExportCoordinator.shared.start(title: url.lastPathComponent, status: L("Preparing video..."),
            operation: { cancellation, progress in
                let source = try await MediaExportIO.perform {
                    try VideoSourceSnapshot.prepare(url: url, deleteOnClose: deleteOnClose,
                                                    cancellation: cancellation, progress: progress)
                }
                prepared = try await PreparedVideoSource.load(source)
                try cancellation.beginPublication()
            }, completion: { [weak self] result in
                guard let self else { return }
                self.preparationJob = nil
                switch result {
                case .success:
                    if let prepared, self.show(prepared: prepared) { return }
                    (NSApp.delegate as? AppDelegate)?.showFailureToast(CocoaError(.fileReadUnknown).localizedDescription)
                case .failure(let error):
                    if !(error is CancellationError) {
                        (NSApp.delegate as? AppDelegate)?.showFailureToast(error.localizedDescription)
                    }
                }
                Self.activeControllers.removeAll { $0 === self }
                (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
            })
        preparationJob = job
        MediaExportProgressController.show(for: job)
    }

    private func show(prepared: PreparedVideoSource) -> Bool {
        guard let asset = prepared.asset else {
            // Animated GIF input: AVFoundation cannot edit it; show a viewer.
            return GIFPreviewController.show(prepared: prepared, owner: self)
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
        let editorDocument = VideoEditorDocument(prepared: prepared, asset: asset)
        self.editorDocument = editorDocument
        playback = VideoEditorPlayback(document: editorDocument)
        exporter = VideoEditorExporter(document: editorDocument)

        let visible = screen.visibleFrame
        let width = min(visible.width * 0.9, max(1100, visible.width * 0.84))
        let height = min(visible.height * 0.92, max(720, visible.height * 0.86))
        let window = VideoEditorWindow(contentRect: NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2,
                                                           width: width, height: height),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                       backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = VideoEditorStyle.window
        window.minSize = NSSize(width: 980, height: 640)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.title = prepared.snapshot.originalURL.deletingPathExtension().lastPathComponent
        window.setFrameAutosaveName("macshot.videoEditor")
        window.delegate = self
        window.editor = self
        self.window = window
        buildInterface(in: window)
        #if VIDEO_EDITOR_PROBE
        // Scripted probes must not take focus from whatever the user is doing.
        window.orderBack(nil)
        #else
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        #endif
        window.makeFirstResponder(timeline)
        return true
    }

    // MARK: Interface

    private func buildInterface(in window: NSWindow) {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = VideoEditorStyle.window.cgColor
        window.contentView = root

        topBar = VideoEditorTopBar(target: self)
        inspector = VideoInspectorView(document: editorDocument)
        inspector.controller = self
        inspector.translatesAutoresizingMaskIntoConstraints = false
        stageToolbar = VideoStageToolbar(target: self)
        stage = VideoStageView(document: editorDocument, playback: playback)
        stage.translatesAutoresizingMaskIntoConstraints = false
        transport = VideoTransportBar(target: self)

        timeline = VideoTimelineView(document: editorDocument)
        timeline.delegate = self
        timelineScroll = NSScrollView()
        timelineScroll.translatesAutoresizingMaskIntoConstraints = false
        timelineScroll.hasHorizontalScroller = true
        timelineScroll.hasVerticalScroller = true
        timelineScroll.autohidesScrollers = true
        timelineScroll.scrollerStyle = .overlay
        timelineScroll.drawsBackground = true
        timelineScroll.backgroundColor = VideoEditorStyle.panel
        timelineScroll.borderType = .noBorder
        timelineScroll.documentView = timeline
        timeline.translatesAutoresizingMaskIntoConstraints = true
        timelineScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(timelineScrolled),
                                               name: NSView.boundsDidChangeNotification, object: timelineScroll.contentView)
        gutter = VideoTimelineGutter()
        gutter.timeline = timeline
        gutter.translatesAutoresizingMaskIntoConstraints = false
        timeline.onLayoutChange = { [weak self] in self?.layoutTimeline() }
        timeline.onZoomChange = { [weak self] in self?.layoutTimeline() }

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = VideoEditorStyle.separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        for view in [topBar!, inspector!, divider, stageToolbar!, stage!, transport!, gutter!, timelineScroll!] as [NSView] {
            root.addSubview(view)
        }
        let timelineHeight = timelineScroll.heightAnchor.constraint(equalToConstant: 230)
        timelineHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            inspector.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            inspector.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            inspector.widthAnchor.constraint(equalToConstant: VideoInspectorView.railWidth + VideoInspectorView.panelWidth),
            inspector.bottomAnchor.constraint(equalTo: transport.topAnchor),
            divider.leadingAnchor.constraint(equalTo: inspector.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            divider.bottomAnchor.constraint(equalTo: transport.topAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            stageToolbar.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            stageToolbar.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            stageToolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stage.topAnchor.constraint(equalTo: stageToolbar.bottomAnchor),
            stage.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: transport.topAnchor),

            transport.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transport.bottomAnchor.constraint(equalTo: timelineScroll.topAnchor),

            gutter.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            gutter.widthAnchor.constraint(equalToConstant: 38),
            gutter.topAnchor.constraint(equalTo: timelineScroll.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: timelineScroll.bottomAnchor),
            timelineScroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            timelineScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            timelineScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            timelineHeight,
            timelineScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            stage.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        playback.onTime = { [weak self] t in self?.timeChanged(t) }
        playback.onPlayStateChange = { [weak self] playing in
            self?.transport.setPlaying(playing)
            self?.stage.isPlaying = playing
        }
        playback.onError = { [weak self] message in self?.showStatus(message, isError: true) }
        observerID = editorDocument.observe { [weak self] change in self?.documentChanged(change) }
        topBar.titleLabel.stringValue = window.title
        refreshChrome()
        timeChanged(0)
        DispatchQueue.main.async { [weak self] in self?.layoutTimeline() }
    }

    private func layoutTimeline() {
        guard let timelineScroll, let timeline else { return }
        timeline.fitWidth = timelineScroll.contentView.bounds.width
        let size = timeline.intrinsicContentSize
        timeline.setFrameSize(NSSize(width: max(size.width, timelineScroll.contentView.bounds.width),
                                     height: max(size.height, timelineScroll.contentView.bounds.height)))
        timeline.needsDisplay = true
        gutter.needsDisplay = true
        timeline.updatePlayhead(time: playback.currentSourceTime)
    }

    @objc private func timelineScrolled() { gutter.needsDisplay = true }

    func windowDidResize(_ notification: Notification) { layoutTimeline() }

    private func documentChanged(_ change: VideoEditChange) {
        if change.contains(.segments) || change.contains(.timing) || change.contains(.render) { layoutTimeline() }
        if change.contains(.history) || change.contains(.render) { refreshChrome() }
        if change.contains(.render) || change.contains(.timing) || change.contains(.segments) {
            if savedRevision != editorDocument.revision { savedURL = nil }
        }
    }

    private func refreshChrome() {
        topBar.undoButton.isEnabled = editorDocument.canUndo
        topBar.redoButton.isEnabled = editorDocument.canRedo
        transport.setMuted(editorDocument.project.muted)
        transport.durationLabel.stringValue = "/ " + VideoTransportBar.format(VideoRenderPlanner.outputDuration(project: editorDocument.project))
        let aspect = editorDocument.project.look.frame.aspect
        stageToolbar.aspectPopup.selectItem(at: VideoAspectRatio.allCases.firstIndex(of: aspect) ?? 0)
        stageToolbar.cropButton.title = stage.isCropping ? L("Done") : L("Crop")
        stageToolbar.cropButton.fill = stage.isCropping ? VideoEditorStyle.accent : VideoEditorStyle.control
        stageToolbar.cropButton.textColor = stage.isCropping ? .white : VideoEditorStyle.textPrimary
        stageToolbar.resetCropButton.isHidden = !stage.isCropping
        transport.autoZoomButton.isHidden = !editorDocument.hasPointerData
        var subtitle: [String] = []
        if let size = exporter.nativeCanvasSize { subtitle.append("\(Int(size.width))×\(Int(size.height))") }
        subtitle.append(ByteCountFormatter.string(fromByteCount: editorDocument.fileSize, countStyle: .file))
        topBar.subtitleLabel.stringValue = subtitle.joined(separator: "  ·  ")
    }

    private func timeChanged(_ t: Double) {
        transport.timeLabel.stringValue = VideoTransportBar.format(playback.outputTime(forSource: t))
        timeline.updatePlayhead(time: t)
        if playback.isPlaying { timeline.revealPlayhead(time: t) }
    }

    // MARK: Window lifecycle

    func windowWillClose(_ notification: Notification) {
        captionTask?.cancel()
        // Commit an in-progress inline text edit before the final save.
        stage?.tearDown()
        editorDocument?.saveNow(synchronously: true)
        inspector?.tearDown()
        timeline?.tearDown()
        playback?.tearDown()
        if let observerID { editorDocument?.removeObserver(observerID) }
        NotificationCenter.default.removeObserver(self)
        Self.activeControllers.removeAll { $0 === self }
        if Self.activeControllers.isEmpty { (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded() }
    }

    // MARK: Actions

    @objc func undoAction() { stage.overlay.endTextEditing(commit: true); editorDocument.undo() }
    @objc func redoAction() { stage.overlay.endTextEditing(commit: true); editorDocument.redo() }
    @objc func togglePlayAction() { playback.togglePlay() }

    @objc func toggleMuteAction() {
        editorDocument.edit([.render]) { $0.muted.toggle() }
    }

    /// Edit boundaries for previous/next navigation.
    private var editBoundaries: [Double] {
        let p = editorDocument.project
        var times = [p.trimStart, p.trimEnd]
        for z in p.zooms { times += [z.startTime, z.endTime] }
        for c in p.cuts { times += [c.startTime, c.endTime] }
        for s in p.speeds { times += [s.startTime, s.endTime] }
        for f in p.freezes { times.append(f.atTime) }
        for t in p.texts { times += [t.startTime, t.endTime] }
        for c in p.censors { times += [c.startTime, c.endTime] }
        return Array(Set(times)).sorted()
    }

    @objc func previousEditAction() {
        let now = playback.currentSourceTime
        playback.pause()
        playback.seek(toSource: editBoundaries.last { $0 < now - 0.02 } ?? editorDocument.project.trimStart)
    }

    @objc func nextEditAction() {
        let now = playback.currentSourceTime
        playback.pause()
        playback.seek(toSource: editBoundaries.first { $0 > now + 0.02 } ?? editorDocument.project.trimEnd)
    }

    @objc func timelineZoomIn() { timeline.zoom(by: 1.6, around: playheadAnchor) }
    @objc func timelineZoomOut() { timeline.zoom(by: 1 / 1.6, around: playheadAnchor) }
    @objc func timelineFit() { timeline.pointsPerSecond = 0; layoutTimeline(); timelineScroll.contentView.scroll(to: .zero) }
    private var playheadAnchor: CGFloat { timeline.x(for: playback.currentSourceTime) }

    @objc func aspectChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let aspect = VideoAspectRatio(rawValue: raw) else { return }
        editorDocument.edit([.render]) { $0.look.frame.aspect = aspect }
        editorDocument.rememberLook()
        stage.needsLayout = true
    }

    @objc func toggleCrop() {
        stage.isCropping.toggle()
        if stage.isCropping { editorDocument.select(nil) }
        refreshChrome()
    }

    @objc func resetCrop() {
        editorDocument.edit([.render]) { $0.crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
    }

    @objc func showAddMenu(_ sender: NSView) {
        let menu = NSMenu()
        let t = playback.currentSourceTime
        func item(_ title: String, _ symbol: String, _ lane: VideoTimelineView.Lane?, _ action: Selector? = nil, key: String = "") -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action ?? #selector(addMenuItem(_:)), keyEquivalent: key)
            entry.target = self
            entry.image = VideoEditorStyle.symbol(symbol, size: 12)
            if let lane { entry.representedObject = lane.rawValue }
            return entry
        }
        menu.addItem(item(L("Zoom"), "plus.magnifyingglass", .zoom))
        if editorDocument.hasPointerData { menu.addItem(item(L("Auto Zoom"), "wand.and.stars", nil, #selector(autoZoomAction))) }
        menu.addItem(.separator())
        menu.addItem(item(L("Cut"), "scissors", .edits))
        let speed = item(L("Speed"), "gauge.with.dots.needle.67percent", nil, #selector(addSpeedAction))
        menu.addItem(speed)
        menu.addItem(item(L("Freeze Frame"), "snowflake", nil, #selector(addFreezeAction)))
        menu.addItem(.separator())
        menu.addItem(item(L("Text"), "textformat", .overlays))
        menu.addItem(item(L("Blur"), "eye.slash", nil, #selector(addBlurAction)))
        _ = t
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func addMenuItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int, let lane = VideoTimelineView.Lane(rawValue: raw) else { return }
        addItem(lane, at: playback.currentSourceTime)
    }

    @objc private func addSpeedAction() { addSpeed(at: playback.currentSourceTime) }
    @objc private func addFreezeAction() { addFreeze(at: playback.currentSourceTime) }
    @objc private func addBlurAction() { addCensor(at: playback.currentSourceTime) }
    @objc func autoZoomAction() { autoZoom() }

    // MARK: Adding items

    func addItem(_ lane: VideoTimelineView.Lane, at time: Double) {
        switch lane {
        case .zoom: addZoom(at: time)
        case .edits: addCut(at: time)
        case .overlays: addText(at: time)
        case .clip, .captions: break
        }
    }

    /// The free interval around `t` among ranges (e.g. existing zooms).
    private func gap(around t: Double, in ranges: [(Double, Double)]) -> (Double, Double)? {
        if ranges.contains(where: { $0.0 <= t && t < $0.1 }) { return nil }
        let before = ranges.map(\.1).filter { $0 <= t }.max() ?? 0
        let after = ranges.map(\.0).filter { $0 > t }.min() ?? editorDocument.duration
        return (before, after)
    }

    private func place(length: Double, around t: Double, in gap: (Double, Double)) -> (Double, Double)? {
        let room = gap.1 - gap.0
        guard room >= 0.3 else { return nil }
        let d = min(length, room)
        let start = min(max(gap.0, t - 0.25), gap.1 - d)
        return (start, start + d)
    }

    private func addZoom(at t: Double) {
        let p = editorDocument.project
        let ranges = p.zooms.map { ($0.startTime, $0.endTime) }
        guard let g = gap(around: t, in: ranges) else {
            if let hit = p.zooms.first(where: { $0.startTime <= t && t < $0.endTime }) { editorDocument.select(.zoom(hit.id)) }
            return
        }
        guard let (start, end) = place(length: 3.5, around: t, in: g) else { showStatus(L("Not enough room here"), isError: true); return }
        let follows = editorDocument.hasPointerData
        let center = editorDocument.recording?.rawPosition(at: t).map { CGPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) }
            ?? CGPoint(x: 0.5, y: 0.5)
        let transition = p.look.zoom.transition.duration
        let zoom = VideoZoomSegment(startTime: start, endTime: end, zoomLevel: CGFloat(p.look.zoom.defaultLevel),
                                    center: center, fadeIn: transition, fadeOut: transition * 0.85, followsCursor: follows)
        editorDocument.edit([.segments, .render]) { $0.zooms.append(zoom) }
        editorDocument.select(.zoom(zoom.id))
    }

    private func addCut(at t: Double) {
        let p = editorDocument.project
        let start = min(max(p.trimStart, t - 0.5), max(p.trimStart, p.trimEnd - 1))
        let cut = VideoCutSegment(startTime: start, endTime: min(p.trimEnd, start + 1))
        guard cut.endTime - cut.startTime >= VideoCutSegment.minDuration else { return }
        editorDocument.edit([.segments, .render, .timing]) { $0.cuts.append(cut) }
        editorDocument.select(.cut(cut.id))
    }

    private func addSpeed(at t: Double) {
        let p = editorDocument.project
        guard let g = gap(around: t, in: p.speeds.map { ($0.startTime, $0.endTime) }),
              let (start, end) = place(length: 3, around: t, in: g) else {
            showStatus(L("Not enough room here"), isError: true)
            return
        }
        let speed = VideoSpeedSegment(startTime: start, endTime: end, speedFactor: 2)
        editorDocument.edit([.segments, .render, .timing]) { $0.speeds.append(speed) }
        editorDocument.select(.speed(speed.id))
    }

    private func addFreeze(at t: Double) {
        let time = min(max(0.001, t), editorDocument.duration - 0.001)
        if let existing = editorDocument.project.freezes.first(where: { abs($0.atTime - time) < 0.01 }) {
            editorDocument.select(.freeze(existing.id))
            return
        }
        let freeze = VideoFreezeSegment(atTime: time)
        editorDocument.edit([.segments, .render, .timing]) { $0.freezes.append(freeze) }
        editorDocument.select(.freeze(freeze.id))
    }

    private func addText(at t: Double) {
        let start = min(max(0, t), max(0, editorDocument.duration - 3))
        let text = VideoTextSegment.withLastUsedStyle(startTime: start, endTime: min(editorDocument.duration, start + 3))
        text.text = L("Title")
        editorDocument.edit([.segments, .render]) { $0.texts.append(text) }
        editorDocument.select(.text(text.id))
        playback.pause()
        playback.seek(toSource: start + 0.3)
    }

    private func addCensor(at t: Double) {
        let start = min(max(0, t), max(0, editorDocument.duration - 3))
        let censor = VideoCensorSegment(startTime: start, endTime: min(editorDocument.duration, start + 3), style: .blur)
        editorDocument.edit([.segments, .render]) { $0.censors.append(censor) }
        editorDocument.select(.censor(censor.id))
        playback.pause()
        playback.seek(toSource: start + 0.3)
    }

    func autoZoom() {
        guard let recording = editorDocument.recording else { return }
        let p = editorDocument.project
        let manual = p.zooms.filter { !$0.isAutomatic }.map { $0.startTime...$0.endTime }
        let track = editorDocument.cursorTrack(onReady: {})
        let suggestions = AutoZoomPlanner.suggestions(recording: recording, track: track, range: p.trimStart...p.trimEnd,
                                                      level: CGFloat(p.look.zoom.defaultLevel), avoiding: manual)
        guard !suggestions.isEmpty else {
            showStatus(L("No clicks or typing found to zoom into"), isError: true)
            return
        }
        let transition = p.look.zoom.transition.duration
        editorDocument.edit([.segments, .render]) { project in
            project.zooms.removeAll { $0.isAutomatic }
            for s in suggestions {
                project.zooms.append(VideoZoomSegment(startTime: s.start, endTime: s.end, zoomLevel: s.level, center: s.center,
                                                      fadeIn: transition, fadeOut: transition * 0.85,
                                                      followsCursor: true, isAutomatic: true))
            }
        }
        showStatus(String(format: L("Added %d zooms"), suggestions.count))
    }

    // MARK: Context menus

    func menu(for selection: VideoSelection) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String?, _ block: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runMenuBlock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuBlock(block)
            if let symbol { item.image = VideoEditorStyle.symbol(symbol, size: 12) }
            menu.addItem(item)
        }
        switch selection {
        case .zoom(let id):
            for level in [1.25, 1.5, 1.8, 2.2, 3.0] {
                add(String(format: "%.2g×", level), nil) { [weak self] in
                    self?.editorDocument.edit([.render, .segments]) { $0.zooms.first { $0.id == id }?.zoomLevel = CGFloat(level) }
                }
            }
            menu.addItem(.separator())
            if editorDocument.hasPointerData {
                let follows = editorDocument.project.zooms.first { $0.id == id }?.followsCursor == true
                add(follows ? L("Hold Focus") : L("Follow Pointer"), follows ? "scope" : "cursorarrow.motionlines") { [weak self] in
                    self?.editorDocument.edit([.render, .segments]) { p in
                        guard let z = p.zooms.first(where: { $0.id == id }) else { return }
                        z.followsCursor.toggle()
                        z.isAutomatic = false
                    }
                }
            }
        case .speed(let id):
            for factor in VideoSpeedSegment.presetFactors {
                add(VideoTimelineView.speedLabel(factor), nil) { [weak self] in
                    self?.editorDocument.edit([.render, .segments, .timing]) { $0.speeds.first { $0.id == id }?.speedFactor = factor }
                }
            }
        case .freeze(let id):
            for d in VideoFreezeSegment.presetDurations {
                add(String(format: "%.2gs", d), nil) { [weak self] in
                    self?.editorDocument.edit([.render, .segments, .timing]) { $0.freezes.first { $0.id == id }?.holdDuration = d }
                }
            }
        case .censor(let id):
            for (title, style) in [(L("Blur"), VideoCensorSegment.Style.blur), (L("Pixelate"), .pixelate), (L("Solid"), .solid)] {
                add(title, nil) { [weak self] in
                    self?.editorDocument.edit([.render, .segments]) { $0.censors.first { $0.id == id }?.style = style }
                }
            }
        case .text(let id):
            add(L("Edit Text"), "character.cursor.ibeam") { [weak self] in self?.editText(id: id) }
        case .cut, .caption:
            break
        }
        if menu.items.count > 0 { menu.addItem(.separator()) }
        add(L("Delete"), "trash") { [weak self] in self?.editorDocument.deleteSelection() }
        return menu
    }

    @objc private func runMenuBlock(_ sender: NSMenuItem) { (sender.representedObject as? MenuBlock)?.block() }

    private func editText(id: UUID) {
        guard let text = editorDocument.project.texts.first(where: { $0.id == id }) else { return }
        editorDocument.select(.text(id))
        playback.pause()
        if playback.currentSourceTime < text.startTime || playback.currentSourceTime > text.endTime {
            playback.seek(toSource: (text.startTime + text.endTime) / 2)
        }
        DispatchQueue.main.async { [weak self] in self?.stage.overlay.beginTextEditing(id: id) }
    }

    // MARK: Keyboard

    /// Handles editor shortcuts; returns false to let the event continue.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if let responder = window?.firstResponder as? NSTextView, responder.isEditable { return false }
        let mods = KeyboardShortcutMatcher.modifiers(in: event)
        switch event.keyCode {
        case 49 where mods.isEmpty: playback.togglePlay(); return true
        case 123: mods.contains(.shift) ? seekBy(-1) : playback.step(frames: -1); return true
        case 124: mods.contains(.shift) ? seekBy(1) : playback.step(frames: 1); return true
        case 115: playback.seek(toSource: editorDocument.project.trimStart); return true
        case 119: playback.seek(toSource: editorDocument.project.trimEnd); return true
        case 51 where editorDocument.selection != nil, 117 where editorDocument.selection != nil:
            editorDocument.deleteSelection(); return true
        case 53:
            if let job = activeExportJob { job.cancel(); return true }
            if stage.isCropping { toggleCrop(); return true }
            if editorDocument.selection != nil { editorDocument.select(nil); return true }
            return false
        default: break
        }
        guard mods.isEmpty else { return false }
        let characters = KeyboardShortcutMatcher.toolCharacters(for: event)
        if characters.contains("i") { setTrim(start: true); return true }
        if characters.contains("o") { setTrim(start: false); return true }
        if characters.contains("z") { addZoom(at: playback.currentSourceTime); return true }
        if characters.contains("c") { addCut(at: playback.currentSourceTime); return true }
        if characters.contains("t") { addText(at: playback.currentSourceTime); return true }
        if characters.contains("k") { playback.pause(); return true }
        if characters.contains("l") { playback.play(); return true }
        if characters.contains("j") { playback.step(frames: -Int(max(1, 1 / editorDocument.frameDuration.seconds))); return true }
        if characters.contains("=") || characters.contains("+") { timelineZoomIn(); return true }
        if characters.contains("-") { timelineZoomOut(); return true }
        return false
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        if let responder = window?.firstResponder as? NSTextView, responder.isEditable { return false }
        switch EditorCommandShortcutManager.action(for: event) {
        case .undo?: undoAction(); return true
        case .redo?: redoAction(); return true
        case nil: break
        }
        if KeyboardShortcutMatcher.matches(event, character: "s", modifiers: [.command]) { saveVideo(); return true }
        if KeyboardShortcutMatcher.matches(event, character: "s", modifiers: [.command, .shift]) { saveVideoAs(); return true }
        if KeyboardShortcutMatcher.matches(event, character: "c", modifiers: [.command]) { copyAction(); return true }
        if KeyboardShortcutMatcher.matches(event, character: "e", modifiers: [.command]) { showExportPanel(topBar.exportButton); return true }
        return false
    }

    private func seekBy(_ seconds: Double) {
        playback.pause()
        playback.seek(toSource: min(editorDocument.project.trimEnd, max(editorDocument.project.trimStart, playback.currentSourceTime + seconds)))
    }

    private func setTrim(start: Bool) {
        let t = playback.currentSourceTime
        editorDocument.edit([.timing, .render]) { p in
            if start { p.trimStart = min(t, p.trimEnd - 0.1) } else { p.trimEnd = max(t, p.trimStart + 0.1) }
        }
    }

    // MARK: Status

    func showStatus(_ message: String, isError: Bool = false, persist: Bool = false) {
        topBar.statusLabel.stringValue = message
        topBar.statusLabel.textColor = isError ? NSColor(srgbRed: 1, green: 0.5, blue: 0.5, alpha: 1) : VideoEditorStyle.textSecondary
        statusTimer?.invalidate()
        guard !persist else { return }
        statusTimer = Timer.scheduledTimer(withTimeInterval: isError ? 6 : 3.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.topBar.statusLabel.stringValue = "" }
        }
    }

    // MARK: Captions

    func generateCaptions() {
        captionTask?.cancel()
        showStatus(L("Transcribing…"), persist: true)
        let maxWords = editorDocument.project.look.captions.maxWords
        captionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let words = try await VideoCaptionTranscriber.transcribe(asset: self.editorDocument.asset,
                                                                        lease: self.editorDocument.source.lease)
                guard !Task.isCancelled else { return }
                let captions = CaptionTimeline.segments(from: words, maxWords: maxWords)
                guard !captions.isEmpty else {
                    self.showStatus(L("No speech was recognized"), isError: true)
                    return
                }
                self.editorDocument.edit([.render, .segments]) { $0.captions = captions; $0.look.captions.show = true }
                self.showStatus(String(format: L("Added %d captions"), captions.count))
            } catch {
                guard !(error is CancellationError) else { return }
                self.showStatus(error.localizedDescription, isError: true)
            }
        }
    }

    func exportSubtitles() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = editorDocument.source.originalURL.deletingPathExtension().lastPathComponent + ".srt"
        panel.directoryURL = SaveDirectoryAccess.recordingDirectoryHint()
        let text = exporter.captionsSRT()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                self?.showStatus(String(format: L("Saved to %@"), url.lastPathComponent))
            } catch {
                self?.showStatus(L("Save failed") + ": " + error.localizedDescription, isError: true)
            }
        }
    }
}

// MARK: - Timeline delegate

extension VideoEditorWindowController: VideoTimelineDelegate {
    func timeline(_ timeline: VideoTimelineView, seekTo sourceTime: Double) {
        playback.seek(toSource: sourceTime)
    }

    func timelineDidBeginScrub(_ timeline: VideoTimelineView) {
        wasPlayingBeforeScrub = playback.isPlaying
        playback.pause()
    }

    func timelineDidEndScrub(_ timeline: VideoTimelineView) {
        if wasPlayingBeforeScrub { playback.play() }
    }

    func timeline(_ timeline: VideoTimelineView, add kind: VideoTimelineView.Lane, at time: Double) {
        addItem(kind, at: time)
    }

    func timelineDidRequestTextEdit(_ timeline: VideoTimelineView, id: UUID) { editText(id: id) }

    func timelineCurrentTime(_ timeline: VideoTimelineView) -> Double { playback?.currentSourceTime ?? 0 }
}

private final class MenuBlock: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
}

/// Routes editor shortcuts before AppKit's default handling.
final class VideoEditorWindow: NSWindow {
    weak var editor: VideoEditorWindowController?

    override func keyDown(with event: NSEvent) {
        if editor?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editor?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

#if VIDEO_EDITOR_PROBE
// MARK: - UI probe hooks (compiled only into scripts/probe-video-editor.sh)

extension VideoEditorWindowController {
    /// Executes one scripted command and returns a log line.
    func probe(_ line: String) -> String {
        let parts = line.split(separator: " ").map(String.init)
        guard let command = parts.first else { return "" }
        let args = Array(parts.dropFirst())
        let doc = editorDocument!
        func number(_ i: Int) -> Double { i < args.count ? Double(args[i]) ?? 0 : 0 }
        switch command {
        case "snapshot":
            let name = args.first ?? "snapshot"
            let dir = ProcessInfo.processInfo.environment["PROBE_OUT"] ?? NSTemporaryDirectory()
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
            return probeSnapshot(to: url) ? "snapshot \(url.path)" : "snapshot failed"
        case "seek": playback.pause(); playback.seek(toSource: number(0))
        case "play": playback.play()
        case "pause": playback.pause()
        case "section":
            let map: [String: VideoInspectorView.Section] = ["background": .background, "cursor": .cursor, "zoom": .zoom,
                                                              "keystrokes": .keystrokes, "camera": .camera, "captions": .captions]
            if let s = map[args.first ?? ""] { inspector.show(section: s) }
        case "autozoom": autoZoom()
        case "deselect": doc.select(nil)
        case "select":
            let index = Int(number(1))
            let p = doc.project
            switch args.first {
            case "zoom" where index < p.zooms.count: doc.select(.zoom(p.zooms[index].id))
            case "text" where index < p.texts.count: doc.select(.text(p.texts[index].id))
            case "censor" where index < p.censors.count: doc.select(.censor(p.censors[index].id))
            case "cut" where index < p.cuts.count: doc.select(.cut(p.cuts[index].id))
            case "speed" where index < p.speeds.count: doc.select(.speed(p.speeds[index].id))
            default: return "nothing to select"
            }
        case "add":
            let t = number(1)
            switch args.first {
            case "zoom": addZoom(at: t)
            case "cut": addCut(at: t)
            case "text": addText(at: t)
            case "blur": addCensor(at: t)
            case "speed": addSpeed(at: t)
            case "freeze": addFreeze(at: t)
            default: return "unknown item"
            }
        case "frame":
            doc.edit([.render]) { p in
                switch args.first {
                case "on": p.look.frame.enabled = true
                case "off": p.look.frame.enabled = false
                case "padding": p.look.frame.padding = number(1)
                case "radius": p.look.frame.cornerRadius = number(1)
                case "shadow": p.look.frame.shadow = number(1)
                case "gradient": p.look.frame.background.kind = .gradient; p.look.frame.background.gradientID = args[1]
                case "wallpaper": p.look.frame.background.kind = .wallpaper
                    p.look.frame.background.imageName = VideoWallpapers.all.first?.path
                case "color": p.look.frame.background.kind = .color
                case "blur": p.look.frame.background.blur = number(1)
                case "border": p.look.frame.border = args.count > 1 && args[1] == "on"
                default: break
                }
            }
        case "aspect":
            if let aspect = VideoAspectRatio.allCases.first(where: { $0.label == args.first || $0.rawValue == args.first }) {
                doc.edit([.render]) { $0.look.frame.aspect = aspect }
            }
        case "cursor":
            doc.edit([.render]) { p in
                switch args.first {
                case "size": p.look.cursor.size = number(1)
                case "smoothing": p.look.cursor.smoothing = number(1)
                case "style": p.look.cursor.appearance = VideoCursorStyle.Appearance(rawValue: args[1]) ?? .system
                case "click": p.look.cursor.clickEffect = VideoCursorStyle.ClickEffect(rawValue: args[1]) ?? .ripple
                case "blur": p.look.cursor.motionBlur = number(1)
                case "sway": p.look.cursor.sway = number(1)
                default: break
                }
            }
        case "crop":
            if args.first == "edit" { toggleCrop() }
            else { doc.edit([.render]) { $0.crop = CGRect(x: number(0), y: number(1), width: number(2), height: number(3)) } }
        case "undo": undoAction()
        case "redo": redoAction()
        case "timeline-zoom": timeline.zoom(by: CGFloat(number(0)), around: timeline.x(for: playback.currentSourceTime))
        case "export":
            var settings = exportSettings
            settings.format = args.first == "gif" ? .gif : .mp4
            if args.count > 2, let quality = VideoQuality(rawValue: args[2]) { settings.quality = quality }
            exportSettings = settings
            let url = URL(fileURLWithPath: args.count > 1 ? args[1] : NSTemporaryDirectory() + "/probe-export.mp4")
            try? FileManager.default.removeItem(at: url)
            probeExport(to: url)
        case "state":
            let p = doc.project
            func r(_ a: Double, _ b: Double) -> String { String(format: "%.2f-%.2f", a, b) }
            return "zooms=\(p.zooms.map { r($0.startTime, $0.endTime) }) cuts=\(p.cuts.map { r($0.startTime, $0.endTime) }) "
                + "texts=\(p.texts.count) censors=\(p.censors.count) speeds=\(p.speeds.count) freezes=\(p.freezes.count) "
                + "trim=\(r(p.trimStart, p.trimEnd)) t=\(String(format: "%.2f", playback.currentSourceTime)) "
                + "sel=\(String(describing: doc.selection)) muted=\(p.muted) canvas=\(exporter.nativeCanvasSize ?? .zero) "
                + "undo=\(doc.canUndo) redo=\(doc.canRedo)"
        case "camera-state":
            let p = doc.project
            guard let layout = playback.planner.layout(for: p) else { return "no layout" }
            let snapshot = playback.planner.snapshot(project: p, layout: layout, options: VideoRenderPlanner.Options(),
                                                     webcamTrackID: nil)
            let t = number(0)
            let st = snapshot.camera.state(at: t)
            return "t=\(t) zoom=\(st.zoom) focus=\(st.focus) spans=\(snapshot.camera.spans.map { ($0.start, $0.end) }) "
                + "zooms=\(p.zooms.map { ($0.startTime, $0.endTime, $0.zoomLevel, $0.fadeIn, $0.fadeOut) }) options=\(playback.options)"
        case "inspector":
            return inspector.debugDescriptionOfContent()
        case "texts":
            return doc.project.texts.map { "\($0.text) rect=\($0.rect) \($0.startTime)-\($0.endTime)" }.joined(separator: " | ")
        case "look":
            let l = doc.project.look
            return "frame on=\(l.frame.enabled) pad=\(l.frame.padding) radius=\(l.frame.cornerRadius) shadow=\(l.frame.shadow) "
                + "bg=\(l.frame.background.kind) \(l.frame.background.gradientID) blur=\(l.frame.background.blur) aspect=\(l.frame.aspect) "
                + "cursor size=\(l.cursor.size) smooth=\(l.cursor.smoothing) style=\(l.cursor.appearance) click=\(l.cursor.clickEffect)"
        case "click", "dblclick":
            // Points from the window content's top-left corner.
            return probeMouse(at: NSPoint(x: number(0), y: number(1)), to: nil, clicks: command == "dblclick" ? 2 : 1,
                              modifiers: args.count > 2 && args[2] == "cmd" ? .command : [])
        case "drag":
            return probeMouse(at: NSPoint(x: number(0), y: number(1)), to: NSPoint(x: number(2), y: number(3)), clicks: 1,
                              modifiers: [])
        case "key":
            // key <keyCode> [characters] [cmd|shift|cmdshift]
            let code = UInt16(number(0))
            let chars = args.count > 1 ? args[1].replacingOccurrences(of: "SPACE", with: " ").replacingOccurrences(of: "RETURN", with: "\r").replacingOccurrences(of: "ESC", with: "\u{1b}") : ""
            var mods: NSEvent.ModifierFlags = []
            if args.count > 2 { if args[2].contains("cmd") { mods.insert(.command) }; if args[2].contains("shift") { mods.insert(.shift) } }
            guard let window, let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars.lowercased(), isARepeat: false, keyCode: code) else { return "no event" }
            if mods.contains(.command) { if !window.performKeyEquivalent(with: down) { window.sendEvent(down) } }
            else { window.sendEvent(down) }
            return "key \(code) responder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
        case "hit":
            guard let content = window?.contentView else { return "no content" }
            let p = NSPoint(x: number(0), y: content.bounds.height - number(1))
            let view = content.hitTest(p)
            return "hit \(view.map { String(describing: type(of: $0)) } ?? "nil") \((view as? NSButton)?.title ?? "")"
        case "export-panel":
            let panel = VideoExportPanel(settings: exportSettings, controller: self)
            panel.frame.size = panel.fittingSize
            panel.layoutSubtreeIfNeeded()
            let host = NSView(frame: panel.bounds)
            host.wantsLayer = true
            host.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
            host.appearance = NSAppearance(named: .darkAqua)
            host.addSubview(panel)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return "no rep" }
            host.cacheDisplay(in: host.bounds, to: rep)
            let dir = ProcessInfo.processInfo.environment["PROBE_OUT"] ?? NSTemporaryDirectory()
            let url = URL(fileURLWithPath: dir).appendingPathComponent("export-panel.png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            return "export-panel \(url.path) \(panel.fittingSize)"
        case "quit": window?.close(); NSApp.terminate(nil)
        default: return "unknown \(command)"
        }
        return "ok \(line)"
    }

    /// Synthesizes a click or drag. Follow-up events are queued before the
    /// mouse-down so controls with their own tracking loops receive them.
    private func probeMouse(at start: NSPoint, to end: NSPoint?, clicks: Int, modifiers: NSEvent.ModifierFlags) -> String {
        guard let window, let content = window.contentView else { return "no window" }
        func windowPoint(_ p: NSPoint) -> NSPoint { content.convert(NSPoint(x: p.x, y: content.bounds.height - p.y), to: nil) }
        func event(_ type: NSEvent.EventType, _ p: NSPoint, _ count: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: windowPoint(p), modifierFlags: modifiers,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: count, pressure: 1)
        }
        let target = content.hitTest(NSPoint(x: start.x, y: content.bounds.height - start.y))
        var results: [String] = []
        for click in 1...clicks {
            var queued: [NSEvent] = []
            if let end {
                for step in 1...12 {
                    let f = CGFloat(step) / 12
                    if let e = event(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * f,
                                                                 y: start.y + (end.y - start.y) * f), click) { queued.append(e) }
                }
            }
            if let up = event(.leftMouseUp, end ?? start, click) { queued.append(up) }
            for e in queued { NSApp.postEvent(e, atStart: false) }
            if let down = event(.leftMouseDown, start, click) { window.sendEvent(down) }
            // Deliver whatever the control's tracking loop did not consume.
            while let pending = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(),
                                                inMode: .default, dequeue: true) {
                window.sendEvent(pending)
            }
            results.append(String(describing: type(of: target as Any)))
        }
        return "mouse on \(results.first ?? "nil")"
    }

    private func probeExport(to url: URL) {
        let settings = exportSettings
        do {
            if settings.format == .gif {
                let request = try exporter.gifRequest(settings, outputURL: url)
                startExport(status: "GIF", title: url.lastPathComponent, operation: { c, p in
                    try await GIFExporter.export(request, cancellation: c, progress: p)
                }, completion: { result in print("export-finished \(url.path) \(result)") })
            } else {
                let job = try exporter.mp4Job(settings, outputURL: url)
                startExport(status: "MP4", title: url.lastPathComponent, operation: { _, p in
                    try await job.export(to: url) { p($0) }
                }, completion: { result in print("export-finished \(url.path) \(result)") })
            }
        } catch {
            print("export-failed \(error)")
        }
    }

    /// Renders the window's layer tree plus the current preview frame.
    private func probeSnapshot(to url: URL) -> Bool {
        guard let window, let content = window.contentView, let layer = content.layer else { return false }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let scale = window.backingScaleFactor
        let size = content.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        // AVPlayerLayer content is not part of the layer render: draw the
        // exact composition frame into the canvas.
        if let item = playback.player.currentItem, let composition = item.videoComposition {
            let generator = AVAssetImageGenerator(asset: item.asset)
            generator.videoComposition = composition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            if let frame = try? generator.copyCGImage(at: item.currentTime(), actualTime: nil) {
                let canvas = stage.convert(stage.canvasRectInOverlay, from: stage.overlay)
                let inContent = stage.convert(canvas, to: content)
                ctx.saveGState()
                ctx.draw(frame, in: inContent)
                ctx.restoreGState()
                // Overlay handles are drawn above the video.
                let overlay = stage.overlay
                if let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) {
                    overlay.cacheDisplay(in: overlay.bounds, to: rep)
                    if let cg = rep.cgImage {
                        ctx.draw(cg, in: overlay.convert(overlay.bounds, to: content))
                    }
                }
            }
        }
        guard let image = ctx.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
#endif
