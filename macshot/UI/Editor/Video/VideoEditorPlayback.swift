import AVFoundation

/// Drives preview playback. Timing edits (cuts, speed, freezes) swap in a
/// new player item; visual edits only replace the item's composition, which
/// is flicker-free. All times exposed to the UI are source-asset seconds.
@MainActor
final class VideoEditorPlayback {
    let player = AVPlayer()
    private let document: VideoEditorDocument
    let planner: VideoRenderPlanner

    /// Preview render scale relative to the native canvas.
    var previewScale: CGFloat = 0.5 {
        didSet { if abs(previewScale - oldValue) > 0.001 { scheduleRebuild(item: false) } }
    }
    var options = VideoRenderPlanner.Options() {
        didSet { scheduleRebuild(item: false) }
    }

    /// Called about 60 times a second while playing, and after every seek.
    var onTime: ((Double) -> Void)?
    /// Play/pause state changed.
    var onPlayStateChange: ((Bool) -> Void)?
    /// A preview composition could not be built.
    var onError: ((String) -> Void)?

    private var mapping = VideoTimelineMapping(entries: [])
    private var usesComposition = false
    private var topology = ""
    private var timeObserver: Any?
    private var rateObservation: NSKeyValueObservation?
    private var rebuildScheduled = false
    private var rebuildItem = false
    private var seekInFlight = false
    private var pendingSeek: CMTime?
    private var requestedSourceTime: Double?
    private(set) var currentSourceTime: Double = 0
    private var observerID: UUID?

    var isPlaying: Bool { player.rate != 0 }

    init(document: VideoEditorDocument) {
        self.document = document
        planner = VideoRenderPlanner(document: document)
        player.actionAtItemEnd = .pause
        player.isMuted = document.project.muted
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onPlayStateChange?(self.isPlaying)
            }
        }
        observerID = document.observe { [weak self] change in
            guard let self else { return }
            if change.contains(.timing) { self.scheduleRebuild(item: true) }
            else if change.contains(.render) || change.contains(.segments) { self.scheduleRebuild(item: false) }
            if change.contains(.render) { self.player.isMuted = self.document.project.muted }
        }
        rebuild(forceItem: true)
    }

    func tearDown() {
        if let observerID { document.removeObserver(observerID) }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rateObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Composition

    private func scheduleRebuild(item: Bool) {
        rebuildItem = rebuildItem || item
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            let forceItem = self.rebuildItem
            self.rebuildItem = false
            self.rebuild(forceItem: forceItem)
        }
    }

    private func topologyKey() -> String {
        let p = document.project
        let cuts = p.cuts.map { "c\($0.startTime.bitPattern)-\($0.endTime.bitPattern)" }
        let speeds = p.speeds.map { "s\($0.startTime.bitPattern)-\($0.endTime.bitPattern)@\($0.speedFactor.bitPattern)" }
        let freezes = p.freezes.map { "f\($0.atTime.bitPattern)@\($0.holdDuration.bitPattern)" }
        return (cuts + speeds + freezes).joined(separator: "|") + (planner.hasCamera ? "|cam" : "")
    }

    /// Rebuilds the preview. Keeps the current item unless the timeline's
    /// structure changed.
    func rebuild(forceItem: Bool = false) {
        let project = document.project
        let key = topologyKey()
        let needsComposition = !project.cuts.isEmpty || !project.speeds.isEmpty || !project.freezes.isEmpty
            || planner.hasCamera
        let resumeTime = requestedSourceTime ?? currentSourceTime
        do {
            if needsComposition {
                let processed = try planner.processed(project: project, from: 0, to: document.duration, includeAudio: true)
                let composition = try planner.videoComposition(project: project, processed: processed,
                    options: previewOptions, onTrackReady: { [weak self] in self?.scheduleRebuild(item: false) })
                if key != topology || !usesComposition || forceItem || player.currentItem == nil {
                    replaceItem(asset: processed.composition, composition: composition,
                                mapping: VideoTimelineMapping(entries: processed.timeMap), resumeAt: resumeTime)
                    usesComposition = true
                    topology = key
                } else {
                    player.currentItem?.videoComposition = composition
                    refreshPausedFrame()
                }
            } else {
                guard let track = document.asset.tracks(withMediaType: .video).first else { return }
                let identity = [EffectsCompositionInstruction.TimeMapEntry(compStart: 0, compEnd: document.duration,
                                                                           sourceStart: 0, factor: 1)]
                let composition = try planner.sourceComposition(project: project, track: track, timeMap: identity,
                    options: previewOptions, onTrackReady: { [weak self] in self?.scheduleRebuild(item: false) })
                if usesComposition || forceItem || player.currentItem == nil {
                    replaceItem(asset: document.asset, composition: composition,
                                mapping: VideoTimelineMapping(entries: identity), resumeAt: resumeTime)
                    usesComposition = false
                    topology = key
                } else {
                    player.currentItem?.videoComposition = composition
                    refreshPausedFrame()
                }
            }
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private var previewOptions: VideoRenderPlanner.Options {
        var o = options
        o.scale = previewScale
        return o
    }

    private func replaceItem(asset: AVAsset, composition: AVVideoComposition, mapping: VideoTimelineMapping,
                             resumeAt sourceTime: Double) {
        let wasPlaying = isPlaying
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = composition
        // Decode ahead generously: the compositor, not decoding, is the cost.
        item.preferredForwardBufferDuration = 2
        player.replaceCurrentItem(with: item)
        self.mapping = mapping
        seekInFlight = false
        pendingSeek = nil
        let target = CMTime(seconds: mapping.compositionTime(at: sourceTime), preferredTimescale: 600_000)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
    }

    /// AVPlayer does not re-render a paused frame when only the composition
    /// changes; an exact seek to the same time does.
    private func refreshPausedFrame() {
        guard !isPlaying, let item = player.currentItem else { return }
        let time = item.currentTime()
        guard !seekInFlight else { pendingSeek = pendingSeek ?? time; return }
        seekInFlight = true
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { self?.seekFinished() }
        }
    }

    // MARK: Clock

    private func tick(_ time: CMTime) {
        guard requestedSourceTime == nil else { return }
        let source = mapping.sourceTime(at: time.seconds)
        currentSourceTime = source
        let project = document.project
        if isPlaying, source >= project.trimEnd - 0.0005 {
            player.pause()
            currentSourceTime = project.trimEnd
        }
        onTime?(currentSourceTime)
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        let project = document.project
        if currentSourceTime >= project.trimEnd - 0.05 || currentSourceTime < project.trimStart - 0.001 {
            seek(toSource: project.trimStart) { [weak self] in self?.player.play() }
            return
        }
        player.play()
    }

    func pause() { player.pause() }

    /// Seeks exactly; rapid calls (scrubbing) coalesce to the latest target.
    func seek(toSource time: Double, completion: (() -> Void)? = nil) {
        let clamped = min(max(0, time), document.duration)
        requestedSourceTime = clamped
        currentSourceTime = clamped
        onTime?(clamped)
        let target = CMTime(seconds: mapping.compositionTime(at: clamped), preferredTimescale: 600_000)
        if seekInFlight {
            pendingSeek = target
            pendingCompletion = completion ?? pendingCompletion
            return
        }
        seekInFlight = true
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                completion?()
                self?.seekFinished()
            }
        }
    }

    private var pendingCompletion: (() -> Void)?

    private func seekFinished() {
        seekInFlight = false
        if let next = pendingSeek {
            pendingSeek = nil
            let completion = pendingCompletion
            pendingCompletion = nil
            seekInFlight = true
            player.seek(to: next, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async {
                    completion?()
                    self?.seekFinished()
                }
            }
            return
        }
        requestedSourceTime = nil
    }

    func step(frames: Int) {
        pause()
        let delta = document.frameDuration.seconds * Double(frames)
        let project = document.project
        seek(toSource: min(project.trimEnd, max(project.trimStart, currentSourceTime + delta)))
    }

    /// Source time → edited (output) time for display.
    func outputTime(forSource t: Double) -> Double {
        let pieces = VideoRenderPlanner.pieces(project: document.project, from: document.project.trimStart,
                                               to: document.project.trimEnd)
        var elapsed = 0.0
        for piece in pieces {
            if piece.kind == .freeze {
                if t > piece.srcStart { elapsed += piece.compositionDuration }
                continue
            }
            if t >= piece.srcEnd { elapsed += piece.compositionDuration; continue }
            if t > piece.srcStart { elapsed += (t - piece.srcStart) / max(piece.factor, 0.0001) }
            break
        }
        return elapsed
    }
}
