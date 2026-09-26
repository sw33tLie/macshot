import AppKit
import UniformTypeIdentifiers

/// Left side of the editor: an icon rail choosing a panel, and the panel
/// itself. Selecting a timeline item shows that item's settings instead.
final class VideoInspectorView: NSView {
    enum Section: Int, CaseIterable {
        case background, cursor, zoom, keystrokes, camera, captions

        var symbol: String {
            switch self {
            case .background: return "photo.on.rectangle.angled"
            case .cursor: return "cursorarrow.rays"
            case .zoom: return "plus.magnifyingglass"
            case .keystrokes: return "keyboard"
            case .camera: return "person.crop.square"
            case .captions: return "captions.bubble"
            }
        }

        var title: String {
            switch self {
            case .background: return L("Background")
            case .cursor: return L("Pointer")
            case .zoom: return L("Zoom")
            case .keystrokes: return L("Keystrokes")
            case .camera: return L("Camera")
            case .captions: return L("Captions")
            }
        }
    }

    private let document: VideoEditorDocument
    weak var controller: VideoEditorWindowController?
    private let rail = NSStackView()
    private var railButtons: [Section: VideoIconButton] = [:]
    private let scroll = NSScrollView()
    private let content = FlippedStackView()
    private let titleLabel = VideoEditorStyle.label("", size: 15, weight: .semibold)
    private var section: Section = .background
    private var observerID: UUID?
    private var refreshers: [() -> Void] = []
    private var shownSelection: VideoSelection?
    private var wallpaperThumbnails: [String: NSImage] = [:]

    static let railWidth: CGFloat = 56
    static let panelWidth: CGFloat = 304

    init(document: VideoEditorDocument) {
        self.document = document
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = VideoEditorStyle.panel.cgColor
        buildRail()
        buildPanelArea()
        observerID = document.observe { [weak self] change in
            guard let self else { return }
            if change.contains(.selection) {
                self.rebuild()
            } else {
                self.refreshers.forEach { $0() }
            }
        }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    func tearDown() {
        if let observerID { document.removeObserver(observerID) }
    }

    // MARK: Structure

    private func buildRail() {
        rail.orientation = .vertical
        rail.spacing = 6
        rail.alignment = .centerX
        rail.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        rail.translatesAutoresizingMaskIntoConstraints = false
        for s in Section.allCases {
            let button = VideoIconButton(symbol: s.symbol, size: 16, tooltip: s.title, target: self, action: #selector(railClicked(_:)))
            button.tag = s.rawValue
            button.cornerRadius = 9
            button.widthAnchor.constraint(equalToConstant: 38).isActive = true
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            railButtons[s] = button
            rail.addArrangedSubview(button)
        }
        addSubview(rail)
        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = VideoEditorStyle.separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.topAnchor.constraint(equalTo: topAnchor),
            rail.widthAnchor.constraint(equalToConstant: Self.railWidth),
            divider.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func buildPanelArea() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 24, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        addSubview(scroll)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.railWidth + 17),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.railWidth + 1),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        // Never draw a legacy scroller over the controls.
        scroll.scrollerStyle = .overlay
        NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scroll.scrollerStyle = .overlay }
        }
    }

    @objc private func railClicked(_ sender: NSButton) {
        guard let s = Section(rawValue: sender.tag) else { return }
        show(section: s)
    }

    func show(section s: Section) {
        section = s
        if document.selection != nil { document.select(nil) } else { rebuild() }
    }

    private func rebuild() {
        refreshers.removeAll()
        for view in content.arrangedSubviews { content.removeArrangedSubview(view); view.removeFromSuperview() }
        let selection = document.selection
        shownSelection = selection
        for (s, button) in railButtons { button.isActive = selection == nil && s == section }
        if let selection {
            buildSelectionPanel(selection)
        } else {
            titleLabel.stringValue = section.title
            switch section {
            case .background: buildBackgroundPanel()
            case .cursor: buildCursorPanel()
            case .zoom: buildZoomPanel()
            case .keystrokes: buildKeystrokePanel()
            case .camera: buildCameraPanel()
            case .captions: buildCaptionsPanel()
            }
        }
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
        }
        content.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .zero)
    }

    #if VIDEO_EDITOR_PROBE
    func debugDescriptionOfContent() -> String {
        "title=\(titleLabel.stringValue) rows=\(content.arrangedSubviews.count) content=\(content.frame) "
            + content.arrangedSubviews.map { "\(type(of: $0)):\($0.frame)" }.joined(separator: " ")
    }
    #endif

    private func add(_ views: NSView...) { views.forEach { content.addArrangedSubview($0) } }

    // MARK: Editing helpers

    /// Edits the look; a whole slider drag is one undo step.
    private func slider(_ title: String, _ range: ClosedRange<Double>, get: @escaping () -> Double,
                        format: @escaping (Double) -> String, change: VideoEditChange = [.render],
                        set: @escaping (VideoProject, Double) -> Void) -> InspectorSliderRow {
        let row = InspectorSliderRow(title: title, min: range.lowerBound, max: range.upperBound, value: get(), format: format,
            onBegin: { [weak self] in self?.document.beginGesture() },
            onChange: { [weak self] v in
                self?.document.edit(change) { set($0, v) }
            },
            onEnd: { [weak self] in
                self?.document.endGesture()
                self?.document.rememberLook()
            })
        refreshers.append { [weak row] in row?.setValue(get()) }
        return row
    }

    private func toggle(_ title: String, subtitle: String? = nil, get: @escaping () -> Bool,
                        change: VideoEditChange = [.render], set: @escaping (VideoProject, Bool) -> Void) -> InspectorSwitchRow {
        let row = InspectorSwitchRow(title: title, subtitle: subtitle, isOn: get()) { [weak self] on in
            self?.document.edit(change) { set($0, on) }
            self?.document.rememberLook()
        }
        refreshers.append { [weak row] in row?.toggle.state = get() ? .on : .off }
        return row
    }

    private func segments(_ title: String?, _ labels: [String], symbols: [String?]? = nil, get: @escaping () -> Int,
                          change: VideoEditChange = [.render], set: @escaping (VideoProject, Int) -> Void) -> InspectorSegmentRow {
        let row = InspectorSegmentRow(title: title, labels: labels, symbols: symbols, selected: get()) { [weak self] i in
            self?.document.edit(change) { set($0, i) }
            self?.document.rememberLook()
        }
        refreshers.append { [weak row] in row?.control.selectedSegment = get() }
        return row
    }

    private func note(_ text: String, symbol: String = "info.circle") -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 1, alpha: 0.045).cgColor
        view.layer?.cornerRadius = 10
        let icon = NSImageView(image: VideoEditorStyle.symbol(symbol, size: 13) ?? NSImage())
        icon.contentTintColor = VideoEditorStyle.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = VideoEditorStyle.label(text, size: 11.5, color: VideoEditorStyle.textSecondary)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.preferredMaxLayoutWidth = Self.panelWidth - 32 - 48
        view.addSubview(icon)
        view.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 11),
            label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -11),
        ])
        return view
    }

    private func button(_ title: String, symbol: String?, primary: Bool = false, action: Selector) -> VideoPillButton {
        let button = VideoPillButton(title: title, symbol: symbol, target: self, action: action)
        if primary {
            button.fill = VideoEditorStyle.accent
            button.textColor = .white
        }
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private var look: VideoLook { document.project.look }

    // MARK: Background

    private func buildBackgroundPanel() {
        add(toggle(L("Frame the recording"), subtitle: L("Background, padding, rounded corners and shadow"),
                   get: { [unowned self] in self.look.frame.enabled }) { p, on in p.look.frame.enabled = on })
        add(InspectorSectionHeader(L("Background")))
        let kinds: [VideoBackgroundStyle.Kind] = [.gradient, .wallpaper, .color, .image]
        add(segments(nil, [L("Gradient"), L("Wallpaper"), L("Color"), L("Image")],
                     get: { [unowned self] in kinds.firstIndex(of: self.look.frame.background.kind) ?? 0 }) { [unowned self] p, i in
            p.look.frame.background.kind = kinds[i]
            p.look.frame.enabled = true
            if kinds[i] == .wallpaper, p.look.frame.background.imageName?.hasPrefix("/") != true {
                p.look.frame.background.imageName = VideoWallpapers.all.first?.path
            }
            DispatchQueue.main.async { self.rebuild() }
        })
        switch look.frame.background.kind {
        case .gradient: add(gradientGrid())
        case .wallpaper: add(wallpaperGrid())
        case .color: add(colorGrid())
        case .image:
            add(button(L("Choose Image…"), symbol: "photo", action: #selector(chooseBackgroundImage)))
        }
        add(slider(L("Background blur"), 0...1, get: { [unowned self] in self.look.frame.background.blur },
                   format: { "\(Int(($0 * 100).rounded()))%" }) { p, v in p.look.frame.background.blur = v })
        add(InspectorSectionHeader(L("Frame")))
        add(InspectorCard([
            slider(L("Padding"), VideoFrameStyle.paddingRange, get: { [unowned self] in self.look.frame.padding },
                   format: { "\(Int(($0 * 100).rounded()))%" }) { p, v in p.look.frame.padding = v; p.look.frame.enabled = true },
            slider(L("Corner radius"), VideoFrameStyle.radiusRange, get: { [unowned self] in self.look.frame.cornerRadius },
                   format: { "\(Int($0.rounded())) pt" }) { p, v in p.look.frame.cornerRadius = v; p.look.frame.enabled = true },
            slider(L("Shadow"), 0...1, get: { [unowned self] in self.look.frame.shadow },
                   format: { "\(Int(($0 * 100).rounded()))%" }) { p, v in p.look.frame.shadow = v; p.look.frame.enabled = true },
            toggle(L("Edge highlight"), get: { [unowned self] in self.look.frame.border }) { p, on in p.look.frame.border = on },
        ]))
    }

    private func gradientGrid() -> NSView {
        let styles = BeautifyRenderer.styles
        let selected = look.frame.background.kind == .gradient
            ? VideoGradientCatalog.styleIndex(for: look.frame.background.gradientID) : -1
        let tiles: [VideoSwatchGrid.Tile] = styles.enumerated().map { index, style in
            .init(id: VideoGradientCatalog.id(forStyleIndex: index), draw: { rect in
                let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
                if #available(macOS 15.0, *), let mesh = style.meshDef,
                   let image = BeautifyRenderer.renderMeshSwatch(mesh, size: rect.width) {
                    NSGraphicsContext.saveGraphicsState()
                    path.addClip()
                    image.draw(in: rect)
                    NSGraphicsContext.restoreGraphicsState()
                } else if let gradient = NSGradient(colors: style.stops.map { $0.0 }, atLocations: style.stops.map { $0.1 },
                                                    colorSpace: .sRGB) {
                    gradient.draw(in: path, angle: style.angle - 90)
                }
            })
        }
        return VideoSwatchGrid(tiles: tiles, selectedIndex: selected) { [weak self] index in
            self?.document.edit([.render]) { p in
                p.look.frame.background.kind = .gradient
                p.look.frame.background.gradientID = VideoGradientCatalog.id(forStyleIndex: index)
                p.look.frame.enabled = true
            }
            self?.document.rememberLook()
        }
    }

    private func wallpaperGrid() -> NSView {
        let wallpapers = VideoWallpapers.all
        guard !wallpapers.isEmpty else { return note(L("No system wallpapers were found. Choose an image instead.")) }
        let current = look.frame.background.imageName
        let tiles: [VideoSwatchGrid.Tile] = wallpapers.map { url in
            .init(id: url.path, draw: { [weak self] rect in
                let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
                NSColor(white: 0.2, alpha: 1).setFill()
                path.fill()
                if let image = self?.wallpaperThumbnail(url) {
                    NSGraphicsContext.saveGraphicsState()
                    path.addClip()
                    let size = image.size
                    let fill = max(rect.width / size.width, rect.height / size.height)
                    image.draw(in: NSRect(x: rect.midX - size.width * fill / 2, y: rect.midY - size.height * fill / 2,
                                          width: size.width * fill, height: size.height * fill))
                    NSGraphicsContext.restoreGraphicsState()
                }
            })
        }
        let grid = VideoSwatchGrid(tiles: tiles, selectedIndex: wallpapers.firstIndex { $0.path == current } ?? -1) { [weak self] i in
            self?.document.edit([.render]) { p in
                p.look.frame.background.kind = .wallpaper
                p.look.frame.background.imageName = wallpapers[i].path
                p.look.frame.enabled = true
            }
            self?.document.rememberLook()
        }
        for url in wallpapers where wallpaperThumbnails[url.path] == nil {
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak grid] in
                let image = VideoWallpapers.thumbnail(url)
                DispatchQueue.main.async {
                    self?.wallpaperThumbnails[url.path] = image
                    grid?.needsDisplay = true
                }
            }
        }
        return grid
    }

    private func wallpaperThumbnail(_ url: URL) -> NSImage? { wallpaperThumbnails[url.path] }

    private func colorGrid() -> NSView {
        let presets: [VideoRGBA] = [
            VideoRGBA(0.07, 0.07, 0.08), VideoRGBA(0.95, 0.95, 0.96), VideoRGBA(0.11, 0.14, 0.24), VideoRGBA(0.20, 0.13, 0.36),
            VideoRGBA(0.93, 0.36, 0.33), VideoRGBA(0.98, 0.62, 0.23), VideoRGBA(0.98, 0.84, 0.35), VideoRGBA(0.30, 0.75, 0.45),
            VideoRGBA(0.20, 0.62, 0.95), VideoRGBA(0.52, 0.42, 0.96), VideoRGBA(0.93, 0.44, 0.70), VideoRGBA(0.55, 0.58, 0.62),
        ]
        let current = look.frame.background.color
        let tiles: [VideoSwatchGrid.Tile] = presets.map { color in
            .init(id: "\(color)", draw: { rect in
                NSColor(color).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            })
        }
        let grid = VideoSwatchGrid(tiles: tiles, selectedIndex: look.frame.background.kind == .color
                                   ? (presets.firstIndex(of: current) ?? -1) : -1) { [weak self] i in
            self?.document.edit([.render]) { p in
                p.look.frame.background.kind = .color
                p.look.frame.background.color = presets[i]
                p.look.frame.enabled = true
            }
            self?.document.rememberLook()
        }
        let custom = NSStackView()
        custom.orientation = .horizontal
        custom.spacing = 8
        custom.addArrangedSubview(VideoEditorStyle.label(L("Custom color"), size: 12))
        custom.addArrangedSubview(ColorSwatchButton(color: NSColor(current)) { [weak self] color in
            self?.document.edit([.render]) { p in
                p.look.frame.background.kind = .color
                p.look.frame.background.color = color.videoRGBA
                p.look.frame.background.color.a = 1
                p.look.frame.enabled = true
            }
            self?.document.rememberLook()
        })
        let stack = NSStackView(views: [grid, custom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        grid.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    @objc private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self,
                  let name = self.document.importBackgroundImage(from: url) else { return }
            self.document.edit([.render]) { p in
                p.look.frame.background.kind = .image
                p.look.frame.background.imageName = name
                p.look.frame.enabled = true
            }
        }
    }

    // MARK: Pointer

    private func buildCursorPanel() {
        guard document.cursorIsEditable else {
            if document.hasPointerData {
                add(note(L("This recording already shows the pointer in its pixels, so it can't be restyled. Zooms can still follow it.")))
            } else {
                add(note(L("This video has no recorded pointer data. Recordings made with macshot that open in the editor let you restyle, smooth and resize the pointer after recording.")))
            }
            return
        }
        add(toggle(L("Show pointer"), get: { [unowned self] in self.look.cursor.show }) { p, on in p.look.cursor.show = on })
        let appearances = VideoCursorStyle.Appearance.allCases
        add(segments(L("Style"), [L("macOS"), L("Dot"), L("Ring")],
                     get: { [unowned self] in appearances.firstIndex(of: self.look.cursor.appearance) ?? 0 }) { p, i in
            p.look.cursor.appearance = appearances[i]
        })
        add(InspectorCard([
            slider(L("Size"), VideoCursorStyle.sizeRange, get: { [unowned self] in self.look.cursor.size },
                   format: { String(format: "%.1f×", $0) }) { p, v in p.look.cursor.size = v },
            slider(L("Smoothing"), 0...1, get: { [unowned self] in self.look.cursor.smoothing },
                   format: { $0 < 0.01 ? L("Off") : "\(Int(($0 * 100).rounded()))%" }) { p, v in p.look.cursor.smoothing = v },
            slider(L("Motion blur"), 0...1, get: { [unowned self] in self.look.cursor.motionBlur },
                   format: { $0 < 0.01 ? L("Off") : "\(Int(($0 * 100).rounded()))%" }) { p, v in p.look.cursor.motionBlur = v },
            slider(L("Sway"), 0...1, get: { [unowned self] in self.look.cursor.sway },
                   format: { $0 < 0.01 ? L("Off") : "\(Int(($0 * 100).rounded()))%" }) { p, v in p.look.cursor.sway = v },
        ]))
        add(InspectorSectionHeader(L("Clicks")))
        let effects = VideoCursorStyle.ClickEffect.allCases
        let clickRow = segments(nil, [L("None"), L("Ripple"), L("Spotlight"), L("Ring")],
                                get: { [unowned self] in effects.firstIndex(of: self.look.cursor.clickEffect) ?? 0 }) { p, i in
            p.look.cursor.clickEffect = effects[i]
        }
        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.addArrangedSubview(VideoEditorStyle.label(L("Click color"), size: 12))
        colorRow.addArrangedSubview(NSView())
        colorRow.addArrangedSubview(ColorSwatchButton(color: NSColor(look.cursor.clickColor)) { [weak self] color in
            self?.document.edit([.render]) { $0.look.cursor.clickColor = color.videoRGBA }
            self?.document.rememberLook()
        })
        add(InspectorCard([clickRow, colorRow,
                           toggle(L("Press animation"), get: { [unowned self] in self.look.cursor.pressBounce }) { p, on in
                               p.look.cursor.pressBounce = on }]))
        add(InspectorSectionHeader(L("Visibility")))
        add(InspectorCard([
            toggle(L("Hide when idle"), get: { [unowned self] in self.look.cursor.hideWhenIdle }) { p, on in p.look.cursor.hideWhenIdle = on },
            slider(L("Idle delay"), 0.5...10, get: { [unowned self] in self.look.cursor.idleDelay },
                   format: { String(format: "%.1fs", $0) }) { p, v in p.look.cursor.idleDelay = v },
            toggle(L("Hide while typing"), get: { [unowned self] in self.look.cursor.hideWhileTyping }) { p, on in
                p.look.cursor.hideWhileTyping = on },
            toggle(L("Return to start at the end"), subtitle: L("Makes looping GIFs seamless"),
                   get: { [unowned self] in self.look.cursor.loopToStart }) { p, on in p.look.cursor.loopToStart = on },
        ]))
    }

    // MARK: Zoom

    private func buildZoomPanel() {
        let auto = button(L("Auto Zoom"), symbol: "wand.and.stars", primary: true, action: #selector(autoZoom))
        auto.isEnabled = document.hasPointerData
        add(auto)
        add(note(document.hasPointerData
                 ? L("Creates zooms that follow the pointer wherever you click or type. Adjust or delete them on the timeline.")
                 : L("Auto Zoom needs pointer data, which macshot records with every new recording. You can still add zooms by double-clicking the zoom lane."),
                 symbol: "sparkles"))
        if document.project.zooms.contains(where: { $0.isAutomatic }) {
            add(button(L("Remove Automatic Zooms"), symbol: "trash", action: #selector(removeAutoZooms)))
        }
        add(InspectorSectionHeader(L("Motion")))
        let transitions = VideoZoomStyle.Transition.allCases
        add(InspectorCard([
            slider(L("Default zoom"), 1.2...4, get: { [unowned self] in self.look.zoom.defaultLevel },
                   format: { String(format: "%.1f×", $0) }) { p, v in p.look.zoom.defaultLevel = v },
            segments(L("Transition"), [L("Gentle"), L("Smooth"), L("Snappy")],
                     get: { [unowned self] in transitions.firstIndex(of: self.look.zoom.transition) ?? 1 },
                     change: [.render, .segments]) { p, i in
                p.look.zoom.transition = transitions[i]
                for zoom in p.zooms { zoom.fadeIn = transitions[i].duration; zoom.fadeOut = transitions[i].duration * 0.85 }
            },
            toggle(L("Connect nearby zooms"), subtitle: L("Pan between zooms instead of zooming out"),
                   get: { [unowned self] in self.look.zoom.connectZooms }) { p, on in p.look.zoom.connectZooms = on },
            slider(L("Motion blur"), 0...1, get: { [unowned self] in self.look.zoom.motionBlur },
                   format: { $0 < 0.01 ? L("Off") : "\(Int(($0 * 100).rounded()))%" }) { p, v in p.look.zoom.motionBlur = v },
            slider(L("Follow tightness"), 0...1, get: { [unowned self] in 1 - (self.look.zoom.followDeadZone - 0.1) / 0.8 },
                   format: { "\(Int(($0 * 100).rounded()))%" }) { p, v in p.look.zoom.followDeadZone = 0.1 + (1 - v) * 0.8 },
        ]))
        if !document.project.zooms.isEmpty {
            add(button(L("Apply Default Zoom to All"), symbol: "square.stack.3d.up", action: #selector(applyZoomToAll)))
        }
    }

    @objc private func autoZoom() { controller?.autoZoom() }

    @objc private func removeAutoZooms() {
        document.edit([.render, .segments]) { $0.zooms.removeAll { $0.isAutomatic } }
        rebuild()
    }

    @objc private func applyZoomToAll() {
        document.edit([.render, .segments]) { p in
            for zoom in p.zooms { zoom.zoomLevel = CGFloat(p.look.zoom.defaultLevel) }
        }
    }

    // MARK: Keystrokes

    private func buildKeystrokePanel() {
        guard document.hasKeystrokes, document.overlaysAreEditable else {
            add(note(document.hasKeystrokes
                ? L("Keystrokes in this recording are part of the video pixels.")
                : L("Turn on Show Keystrokes before recording. macshot then records them separately so you can style them here.")))
            return
        }
        add(toggle(L("Show keystrokes"), get: { [unowned self] in self.look.keystrokes.show }) { p, on in p.look.keystrokes.show = on })
        add(toggle(L("Shortcuts only"), subtitle: L("Hide ordinary typing, show key combinations"),
                   get: { [unowned self] in self.look.keystrokes.shortcutsOnly }) { p, on in p.look.keystrokes.shortcutsOnly = on })
        add(InspectorCard([
            slider(L("Size"), 0.5...2.5, get: { [unowned self] in self.look.keystrokes.size },
                   format: { String(format: "%.1f×", $0) }) { p, v in p.look.keystrokes.size = v },
            toggle(L("Light appearance"), get: { [unowned self] in self.look.keystrokes.lightAppearance }) { p, on in
                p.look.keystrokes.lightAppearance = on },
        ]))
        add(InspectorSectionHeader(L("Position")))
        add(positionGrid(get: { [unowned self] in self.look.keystrokes.position }) { p, pos in p.look.keystrokes.position = pos })
    }

    private func positionGrid(get: @escaping () -> VideoOverlayPosition,
                              set: @escaping (VideoProject, VideoOverlayPosition) -> Void) -> NSView {
        let grid = VideoPositionGrid(selected: get()) { [weak self] position in
            self?.document.edit([.render]) { set($0, position) }
            self?.document.rememberLook()
        }
        refreshers.append { [weak grid] in grid?.selected = get() }
        return grid
    }

    // MARK: Camera

    private func buildCameraPanel() {
        guard document.cameraURL != nil else {
            add(note(L("Turn on the camera before recording. macshot records it separately so you can move, resize, restyle or hide it here, and shrink it during zooms.")))
            return
        }
        add(toggle(L("Show camera"), get: { [unowned self] in self.look.camera.show }) { p, on in p.look.camera.show = on })
        let shapes = VideoCameraStyle.Shape.allCases
        add(segments(L("Shape"), [L("Circle"), L("Square"), L("Wide"), L("Tall")],
                     get: { [unowned self] in shapes.firstIndex(of: self.look.camera.shape) ?? 0 }) { p, i in
            p.look.camera.shape = shapes[i]
        })
        add(InspectorCard([
            // Picking a size or position switches from the recorded placement to a fixed one.
            slider(L("Size"), 0.08...0.6, get: { [unowned self] in self.look.camera.size },
                   format: { "\(Int(($0 * 100).rounded()))%" }) { p, v in
                p.look.camera.size = v
                p.look.camera.followsRecording = false },
            toggle(L("Mirror"), get: { [unowned self] in self.look.camera.mirror }) { p, on in p.look.camera.mirror = on },
            toggle(L("Shrink during zooms"), get: { [unowned self] in self.look.camera.shrinkOnZoom }) { p, on in
                p.look.camera.shrinkOnZoom = on },
            toggle(L("Shadow"), get: { [unowned self] in self.look.camera.shadow }) { p, on in p.look.camera.shadow = on },
        ]))
        add(InspectorSectionHeader(L("Position")))
        if document.cameraPlacement != nil {
            // "Original": where the bubble was, including moves made while recording.
            add(toggle(L("Original"), get: { [unowned self] in self.look.camera.followsRecording }) {
                p, on in p.look.camera.followsRecording = on })
        }
        add(positionGrid(get: { [unowned self] in self.look.camera.position }) { p, pos in
            p.look.camera.position = pos
            p.look.camera.followsRecording = false })
    }

    // MARK: Captions

    private func buildCaptionsPanel() {
        if document.audioTrackCount == 0 {
            add(note(L("This recording has no audio to transcribe.")))
            return
        }
        let generate = button(document.project.captions.isEmpty ? L("Generate Captions") : L("Regenerate Captions"),
                              symbol: "waveform", primary: document.project.captions.isEmpty, action: #selector(generateCaptions))
        add(generate)
        add(note(L("Captions are transcribed on this Mac. Nothing is uploaded."), symbol: "lock.shield"))
        guard !document.project.captions.isEmpty else { return }
        add(toggle(L("Show captions"), get: { [unowned self] in self.look.captions.show }) { p, on in p.look.captions.show = on })
        add(InspectorCard([
            slider(L("Size"), 16...120, get: { [unowned self] in self.look.captions.fontSize },
                   format: { "\(Int($0.rounded())) pt" }) { p, v in p.look.captions.fontSize = v },
            toggle(L("Background"), get: { [unowned self] in self.look.captions.background }) { p, on in
                p.look.captions.background = on },
        ]))
        add(InspectorSectionHeader(L("Position")))
        add(positionGrid(get: { [unowned self] in self.look.captions.position }) { p, pos in p.look.captions.position = pos })
        add(button(L("Export Subtitles (.srt)…"), symbol: "doc.text", action: #selector(exportSRT)))
        add(button(L("Remove Captions"), symbol: "trash", action: #selector(removeCaptions)))
    }

    @objc private func generateCaptions() { controller?.generateCaptions() }
    @objc private func exportSRT() { controller?.exportSubtitles() }
    @objc private func removeCaptions() {
        document.edit([.render, .segments]) { $0.captions.removeAll() }
        rebuild()
    }

    // MARK: Selected item

    private func buildSelectionPanel(_ selection: VideoSelection) {
        let p = document.project
        switch selection {
        case .zoom(let id):
            titleLabel.stringValue = L("Zoom")
            guard p.zooms.contains(where: { $0.id == id }) else { return }
            func zoom(_ project: VideoProject) -> VideoZoomSegment? { project.zooms.first { $0.id == id } }
            add(slider(L("Zoom level"), Double(VideoZoomSegment.minZoom)...Double(VideoZoomSegment.maxZoom),
                       get: { [unowned self] in Double(zoom(self.document.project)?.zoomLevel ?? 2) },
                       format: { String(format: "%.1f×", $0) }, change: [.render, .segments]) { p, v in
                zoom(p)?.zoomLevel = CGFloat(v)
            })
            let follow = segments(L("Focus"), [L("Fixed point"), L("Follow pointer")],
                                  get: { [unowned self] in zoom(self.document.project)?.followsCursor == true ? 1 : 0 },
                                  change: [.render, .segments]) { p, i in
                zoom(p)?.followsCursor = i == 1
                zoom(p)?.isAutomatic = false
            }
            follow.control.setEnabled(document.hasPointerData, forSegment: 1)
            add(follow)
            add(InspectorCard([
                slider(L("Zoom in"), 0.1...2.5, get: { [unowned self] in zoom(self.document.project)?.fadeIn ?? 0.8 },
                       format: { String(format: "%.2fs", $0) }) { p, v in zoom(p)?.fadeIn = v },
                slider(L("Zoom out"), 0.1...2.5, get: { [unowned self] in zoom(self.document.project)?.fadeOut ?? 0.7 },
                       format: { String(format: "%.2fs", $0) }) { p, v in zoom(p)?.fadeOut = v },
            ]))
            add(note(L("Drag the frame on the preview to choose where the zoom looks.")))
        case .censor(let id):
            titleLabel.stringValue = L("Blur")
            let styles: [VideoCensorSegment.Style] = [.blur, .pixelate, .solid]
            add(segments(L("Style"), [L("Blur"), L("Pixelate"), L("Solid")],
                         get: { [unowned self] in styles.firstIndex(of: self.document.project.censors.first { $0.id == id }?.style ?? .blur) ?? 0 },
                         change: [.render, .segments]) { p, i in p.censors.first { $0.id == id }?.style = styles[i] })
            add(note(L("Use Solid to hide sensitive information: blur and pixelation can sometimes be reversed.")))
        case .text(let id):
            titleLabel.stringValue = L("Text")
            buildTextPanel(id: id)
        case .cut(let id):
            titleLabel.stringValue = L("Cut")
            let length = p.cuts.first { $0.id == id }.map { $0.endTime - $0.startTime } ?? 0
            add(note(String(format: L("Removes %.1f seconds from the video. Drag its edges on the timeline to adjust."), length),
                     symbol: "scissors"))
        case .speed(let id):
            titleLabel.stringValue = L("Speed")
            add(slider(L("Speed"), VideoSpeedSegment.minFactor...VideoSpeedSegment.maxFactor,
                       get: { [unowned self] in self.document.project.speeds.first { $0.id == id }?.speedFactor ?? 2 },
                       format: { VideoTimelineView.speedLabel($0) }, change: [.render, .segments, .timing]) { p, v in
                let snapped = [0.25, 0.5, 0.75, 1.5, 2, 3, 4, 5, 8, 10].min { abs($0 - v) < abs($1 - v) } ?? v
                p.speeds.first { $0.id == id }?.speedFactor = abs(snapped - v) < 0.08 ? snapped : (v * 20).rounded() / 20
            })
        case .freeze(let id):
            titleLabel.stringValue = L("Freeze Frame")
            add(slider(L("Duration"), VideoFreezeSegment.minHoldDuration...10,
                       get: { [unowned self] in self.document.project.freezes.first { $0.id == id }?.holdDuration ?? 1 },
                       format: { String(format: "%.1fs", $0) }, change: [.render, .segments, .timing]) { p, v in
                p.freezes.first { $0.id == id }?.holdDuration = VideoFreezeSegment.clampDuration((v * 10).rounded() / 10)
            })
        case .caption(let id):
            titleLabel.stringValue = L("Caption")
            let field = NSTextField(string: p.captions.first { $0.id == id }?.text ?? "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byWordWrapping
            field.usesSingleLineMode = false
            field.cell?.wraps = true
            field.heightAnchor.constraint(equalToConstant: 64).isActive = true
            field.target = self
            field.action = #selector(captionEdited(_:))
            field.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
            add(field)
        }
        let delete = button(L("Delete"), symbol: "trash", action: #selector(deleteSelection))
        delete.textColor = NSColor(srgbRed: 1, green: 0.45, blue: 0.45, alpha: 1)
        add(delete)
    }

    @objc private func captionEdited(_ sender: NSTextField) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        document.edit([.render, .segments]) { p in
            guard let i = p.captions.firstIndex(where: { $0.id == id }) else { return }
            p.captions[i].text = sender.stringValue
        }
    }

    @objc private func deleteSelection() { document.deleteSelection() }

    private func buildTextPanel(id: UUID) {
        func segment(_ p: VideoProject) -> VideoTextSegment? { p.texts.first { $0.id == id } }
        guard let seg = segment(document.project) else { return }
        let editHint = note(L("Double-click the text on the preview to edit it."), symbol: "character.cursor.ibeam")
        add(editHint)
        let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fontPopup.controlSize = .small
        fontPopup.translatesAutoresizingMaskIntoConstraints = false
        let families = ["System"] + NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
        fontPopup.addItems(withTitles: families.map { $0 == "System" ? L("System") : $0 })
        fontPopup.selectItem(at: families.firstIndex(of: seg.fontFamily) ?? 0)
        let fontHandler = PopupHandler { [weak self] index in
            self?.document.edit([.render]) { p in segment(p)?.fontFamily = families[index]; segment(p)?.rememberStyle() }
        }
        fontPopup.target = fontHandler
        fontPopup.action = #selector(PopupHandler.changed(_:))
        objc_setAssociatedObject(fontPopup, &PopupHandler.key, fontHandler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        add(InspectorSectionHeader(L("Font")), fontPopup)
        add(InspectorCard([
            slider(L("Size"), 12...200, get: { [unowned self] in Double(segment(self.document.project)?.fontSize ?? 48) },
                   format: { "\(Int($0.rounded())) pt" }) { p, v in segment(p)?.fontSize = CGFloat(v); segment(p)?.rememberStyle() },
            segments(nil, [L("Regular"), L("Bold"), L("Italic"), L("Bold Italic")],
                     get: { [unowned self] in
                         guard let s = segment(self.document.project) else { return 0 }
                         return (s.bold ? 1 : 0) + (s.italic ? 2 : 0)
                     }) { p, i in
                segment(p)?.bold = i == 1 || i == 3
                segment(p)?.italic = i >= 2
                segment(p)?.rememberStyle()
            },
            segments(nil, [L("Left"), L("Center"), L("Right")],
                     symbols: ["text.alignleft", "text.aligncenter", "text.alignright"],
                     get: { [unowned self] in
                         switch segment(self.document.project)?.alignment ?? .center { case .left: return 0; case .center: return 1; case .right: return 2 }
                     }) { p, i in
                segment(p)?.alignment = [.left, .center, .right][i]
                segment(p)?.rememberStyle()
            },
        ]))
        add(InspectorSectionHeader(L("Colors")))
        func colorRow(_ title: String, get: @escaping (VideoTextSegment) -> VideoTextSegment.RGBA,
                      set: @escaping (VideoTextSegment, VideoTextSegment.RGBA) -> Void) -> NSView {
            let row = NSStackView()
            row.orientation = .horizontal
            row.addArrangedSubview(VideoEditorStyle.label(title, size: 12))
            row.addArrangedSubview(NSView())
            let rgba = get(seg)
            row.addArrangedSubview(ColorSwatchButton(color: NSColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)) { [weak self] color in
                let c = color.usingColorSpace(.sRGB) ?? color
                self?.document.edit([.render]) { p in
                    guard let s = segment(p) else { return }
                    set(s, .init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent),
                                 a: Double(c.alphaComponent)))
                    s.rememberStyle()
                }
            })
            return row
        }
        let bgStyles: [VideoTextSegment.BackgroundStyle] = [.none, .solid, .rounded]
        add(InspectorCard([
            colorRow(L("Text"), get: { $0.textColor }, set: { $0.textColor = $1 }),
            segments(L("Background"), [L("None"), L("Box"), L("Pill")],
                     get: { [unowned self] in bgStyles.firstIndex(of: segment(self.document.project)?.bgStyle ?? .none) ?? 0 }) { p, i in
                segment(p)?.bgStyle = bgStyles[i]
                segment(p)?.rememberStyle()
            },
            colorRow(L("Background color"), get: { $0.bgColor }, set: { $0.bgColor = $1 }),
            toggle(L("Outline"), get: { [unowned self] in segment(self.document.project)?.outlineEnabled ?? false }) { p, on in
                segment(p)?.outlineEnabled = on
                segment(p)?.rememberStyle()
            },
            colorRow(L("Outline color"), get: { $0.outlineColor }, set: { $0.outlineColor = $1 }),
            slider(L("Outline width"), 0.5...12, get: { [unowned self] in Double(segment(self.document.project)?.outlineWidth ?? 2) },
                   format: { String(format: "%.1f pt", $0) }) { p, v in segment(p)?.outlineWidth = CGFloat(v) },
        ]))
        add(InspectorCard([
            slider(L("Fade in"), 0...2, get: { [unowned self] in segment(self.document.project)?.fadeIn ?? 0.25 },
                   format: { String(format: "%.2fs", $0) }) { p, v in segment(p)?.fadeIn = v },
            slider(L("Fade out"), 0...2, get: { [unowned self] in segment(self.document.project)?.fadeOut ?? 0.25 },
                   format: { String(format: "%.2fs", $0) }) { p, v in segment(p)?.fadeOut = v },
        ]))
    }
}

private final class PopupHandler: NSObject {
    static var key: UInt8 = 0
    let handler: (Int) -> Void
    init(_ handler: @escaping (Int) -> Void) { self.handler = handler }
    @objc func changed(_ sender: NSPopUpButton) { handler(sender.indexOfSelectedItem) }
}

// MARK: - Swatch grid

final class VideoSwatchGrid: NSView {
    struct Tile {
        var id: String
        var draw: (NSRect) -> Void
    }

    private let tiles: [Tile]
    private var selectedIndex: Int
    private let onSelect: (Int) -> Void
    private let columns = 6
    private let spacing: CGFloat = 8

    init(tiles: [Tile], selectedIndex: Int, onSelect: @escaping (Int) -> Void) {
        self.tiles = tiles
        self.selectedIndex = selectedIndex
        self.onSelect = onSelect
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var tileSize: CGFloat { (max(bounds.width, 200) - spacing * CGFloat(columns - 1)) / CGFloat(columns) }

    override var intrinsicContentSize: NSSize {
        let rows = CGFloat((tiles.count + columns - 1) / columns)
        let size = (VideoInspectorView.panelWidth - 33 - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return NSSize(width: NSView.noIntrinsicMetric, height: rows * size + max(0, rows - 1) * spacing)
    }

    private func rect(at index: Int) -> NSRect {
        let s = tileSize
        let row = index / columns, column = index % columns
        return NSRect(x: CGFloat(column) * (s + spacing), y: CGFloat(row) * (s + spacing), width: s, height: s)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, tile) in tiles.enumerated() {
            let r = rect(at: i).insetBy(dx: 1.5, dy: 1.5)
            guard r.intersects(dirtyRect) else { continue }
            tile.draw(r)
            if i == selectedIndex {
                let ring = NSBezierPath(roundedRect: r.insetBy(dx: -2.5, dy: -2.5), xRadius: 10, yRadius: 10)
                ring.lineWidth = 2
                NSColor.white.setStroke()
                ring.stroke()
            } else {
                let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
                NSColor(white: 1, alpha: 0.12).setStroke()
                edge.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let index = tiles.indices.first(where: { rect(at: $0).contains(p) }) else { return }
        selectedIndex = index
        needsDisplay = true
        onSelect(index)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateIntrinsicContentSize()
    }
}

/// 3×3 anchor picker.
final class VideoPositionGrid: NSView {
    var selected: VideoOverlayPosition { didSet { needsDisplay = true } }
    private let onSelect: (VideoOverlayPosition) -> Void

    init(selected: VideoOverlayPosition, onSelect: @escaping (VideoOverlayPosition) -> Void) {
        self.selected = selected
        self.onSelect = onSelect
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 96).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var box: NSRect {
        let h = bounds.height, w = h * 16 / 9
        return NSRect(x: 0, y: 0, width: min(w, bounds.width), height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = box
        NSColor(white: 1, alpha: 0.05).setFill()
        NSBezierPath(roundedRect: b, xRadius: 10, yRadius: 10).fill()
        for position in VideoOverlayPosition.allCases {
            let a = position.anchor
            let center = NSPoint(x: b.minX + 16 + (b.width - 32) * a.x, y: b.minY + 14 + (b.height - 28) * a.y)
            let isOn = position == selected
            let dot = NSRect(x: center.x - (isOn ? 7 : 4), y: center.y - (isOn ? 5 : 4),
                             width: isOn ? 14 : 8, height: isOn ? 10 : 8)
            (isOn ? VideoEditorStyle.accent : NSColor(white: 1, alpha: 0.28)).setFill()
            NSBezierPath(roundedRect: dot, xRadius: isOn ? 3 : 4, yRadius: isOn ? 3 : 4).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let b = box
        guard b.contains(p) else { return }
        let column = min(2, max(0, Int((p.x - b.minX) / (b.width / 3))))
        let row = min(2, max(0, Int((p.y - b.minY) / (b.height / 3))))
        let position = VideoOverlayPosition.allCases[row * 3 + column]
        selected = position
        onSelect(position)
    }
}

enum VideoWallpapers {
    static let directory = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)

    /// Static, full-resolution wallpapers that ship with macOS.
    static let all: [URL] = {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    nonisolated static func thumbnail(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 160,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
