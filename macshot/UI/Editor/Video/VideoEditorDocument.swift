import AVFoundation
import AppKit
import CryptoKit

/// What an edit touched, so each view refreshes only what it must.
struct VideoEditChange: OptionSet {
    let rawValue: Int
    /// Trim, cuts, speed or freezes: the edited timeline itself changed.
    static let timing = VideoEditChange(rawValue: 1 << 0)
    /// Something visible in rendered frames changed.
    static let render = VideoEditChange(rawValue: 1 << 1)
    /// Segments were added, removed or moved on the timeline.
    static let segments = VideoEditChange(rawValue: 1 << 2)
    /// Selected item changed.
    static let selection = VideoEditChange(rawValue: 1 << 3)
    /// Undo/redo availability or dirty state changed.
    static let history = VideoEditChange(rawValue: 1 << 4)
    /// The whole project was replaced (undo, redo, reset).
    static let all: VideoEditChange = [.timing, .render, .segments, .selection, .history]
}

enum VideoSelection: Equatable {
    case zoom(UUID), censor(UUID), text(UUID), cut(UUID), speed(UUID), freeze(UUID), caption(UUID)

    var id: UUID {
        switch self {
        case .zoom(let id), .censor(let id), .text(let id), .cut(let id), .speed(let id), .freeze(let id),
             .caption(let id): return id
        }
    }
}

/// Owns one video's editable state: the project, its undo history, recorded
/// pointer data, and persistence. Views observe changes; they never keep
/// their own copies of project data.
@MainActor
final class VideoEditorDocument {
    let source: VideoSourceSnapshot
    let asset: AVAsset
    let duration: Double
    /// Upright source size in pixels.
    let contentSize: CGSize
    let frameDuration: CMTime
    let encodingSource: VideoExportEncodingPlan.Source?
    let audioTrackCount: Int
    let fileSize: Int64
    /// Recorded pointer data, if the take has it.
    let recording: CursorRecording?
    /// Recorded camera, if the take has a separate camera file.
    let cameraURL: URL?
    /// Where the camera bubble sat while recording, if the take has it.
    let cameraPlacement: CameraPlacementTrack?
    /// Folder for the project file and any imported background image.
    let projectDirectory: URL?
    private let projectURL: URL?

    private(set) var project: VideoProject
    private(set) var selection: VideoSelection? {
        didSet { if selection != oldValue { notify(.selection) } }
    }

    private var undoStack: [Data] = []
    private var redoStack: [Data] = []
    private var gestureBase: Data?
    private var gestureDepth = 0
    private var savedState: Data
    private var autosaveWork: DispatchWorkItem?
    private var observers: [UUID: (VideoEditChange) -> Void] = [:]
    private var trackCache: (smoothing: Double, track: CursorTrack)?
    private var trackTask: Task<Void, Never>?
    private var trackWorker: Task<CursorTrack?, Never>?
    private var pendingSmoothing: Double?
    /// Encoded project as loaded; an unchanged project needs no file.
    private let initialState: Data
    private var terminationObserver: NSObjectProtocol?
    /// Project writes are serialized so an older save can never land last.
    private static let saveQueue = DispatchQueue(label: "macshot.video-project-save", qos: .utility)
    /// Revision bumps on every change; exports and caches key off it.
    private(set) var revision: UInt64 = 0

    /// Cursor, click and keystroke rendering is available because the take
    /// recorded them separately from its pixels.
    var cursorIsEditable: Bool { recording?.header.cursorHiddenInVideo == true && recording?.isEmpty == false }
    var overlaysAreEditable: Bool { recording?.header.overlaysInTelemetry == true }
    var hasPointerData: Bool { recording?.isEmpty == false }
    var hasKeystrokes: Bool { !(recording?.keys.isEmpty ?? true) }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isDirty: Bool { project.encoded() != savedState }

    init(prepared: PreparedVideoSource, asset: AVAsset) {
        source = prepared.snapshot
        self.asset = asset
        duration = prepared.duration
        contentSize = prepared.pixelSize ?? CGSize(width: 1920, height: 1080)
        let cadence = prepared.encodingSource?.frameDuration ?? .invalid
        frameDuration = VideoFrameCadence.isUsable(cadence) ? cadence : CMTime(value: 1, timescale: 30)
        encodingSource = prepared.encodingSource
        audioTrackCount = prepared.audioTrackCount
        fileSize = prepared.fileSize

        let original = prepared.snapshot.originalURL
        let sessionOwned = RecordingSessionStore.owns(original)
        let directory: URL?
        if sessionOwned {
            directory = original.resolvingSymlinksInPath().deletingLastPathComponent()
        } else {
            directory = Self.externalProjectDirectory(for: original)
        }
        projectDirectory = directory
        projectURL = directory?.appendingPathComponent(original.deletingPathExtension().lastPathComponent + ".project.json")
        let telemetryURL = sessionOwned ? directory?.appendingPathComponent(CursorTelemetry.filename) : nil
        recording = telemetryURL.flatMap { CursorRecording.load(url: $0) }
        let camera = sessionOwned ? directory?.appendingPathComponent(VideoCameraRecorder.filename) : nil
        cameraURL = camera.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        cameraPlacement = cameraURL == nil ? nil : directory.flatMap {
            CameraPlacementTrack.load(url: $0.appendingPathComponent(CameraPlacementTrack.filename))
        }

        if let url = projectURL, let data = try? Data(contentsOf: url), let saved = VideoProject.decode(data),
           abs(saved.sourceDuration - prepared.duration) < 0.05 {
            saved.sourceDuration = prepared.duration
            saved.sanitizeSegments()
            project = saved
        } else {
            var look: VideoLook
            if sessionOwned {
                if let remembered = VideoLook.remembered() {
                    look = remembered
                } else {
                    var first = VideoLook.recordingDefault
                    first.frame.background.gradientID = VideoGradientCatalog.defaultID
                    look = first
                }
            } else {
                look = VideoLook()
            }
            // A new take starts with the camera where it was while recording.
            look.camera.followsRecording = cameraPlacement != nil
            project = VideoProject(sourceDuration: prepared.duration, look: look)
        }
        savedState = project.encoded()
        initialState = savedState
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow(synchronously: true) }
        }
    }

    /// Projects for files outside the recording library live in Application
    /// Support, keyed by the file's path.
    private static func externalProjectDirectory(for url: URL) -> URL? {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        let key = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let root = RecordingSessionStore.rootURL.deletingLastPathComponent()
            .appendingPathComponent("VideoProjects", isDirectory: true)
        return root.appendingPathComponent(key, isDirectory: true)
    }

    // MARK: Observation

    @discardableResult
    func observe(_ handler: @escaping (VideoEditChange) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func notify(_ change: VideoEditChange) {
        if change.contains(.render) || change.contains(.timing) || change.contains(.segments) { revision &+= 1 }
        for handler in observers.values { handler(change) }
    }

    // MARK: Editing

    /// Applies one edit. Outside a gesture it becomes its own undo step.
    func edit(_ change: VideoEditChange, _ body: (VideoProject) -> Void) {
        let before = gestureDepth > 0 ? nil : project.encoded()
        body(project)
        if let before, project.encoded() != before {
            pushUndo(before)
        }
        notify(change.union(.history))
        scheduleAutosave()
    }

    /// Groups a continuous interaction (dragging, slider tracking) into a
    /// single undo step.
    func beginGesture() {
        if gestureDepth == 0 { gestureBase = project.encoded() }
        gestureDepth += 1
    }

    func endGesture() {
        guard gestureDepth > 0 else { return }
        gestureDepth -= 1
        guard gestureDepth == 0, let base = gestureBase else { return }
        gestureBase = nil
        if project.encoded() != base { pushUndo(base) }
        notify(.history)
    }

    private func pushUndo(_ state: Data) {
        undoStack.append(state)
        if undoStack.count > 200 { undoStack.removeFirst(undoStack.count - 200) }
        redoStack.removeAll()
    }

    func undo() {
        guard gestureDepth == 0, let state = undoStack.popLast(), let restored = VideoProject.decode(state) else { return }
        redoStack.append(project.encoded())
        replaceProject(restored)
    }

    func redo() {
        guard gestureDepth == 0, let state = redoStack.popLast(), let restored = VideoProject.decode(state) else { return }
        undoStack.append(project.encoded())
        replaceProject(restored)
    }

    private func replaceProject(_ restored: VideoProject) {
        project = restored
        if let current = selection, !contains(current) { selection = nil }
        notify(.all)
        scheduleAutosave()
    }

    func select(_ newSelection: VideoSelection?) {
        selection = newSelection.flatMap { contains($0) ? $0 : nil }
    }

    private func contains(_ selection: VideoSelection) -> Bool {
        switch selection {
        case .zoom(let id): return project.zooms.contains { $0.id == id }
        case .censor(let id): return project.censors.contains { $0.id == id }
        case .text(let id): return project.texts.contains { $0.id == id }
        case .cut(let id): return project.cuts.contains { $0.id == id }
        case .speed(let id): return project.speeds.contains { $0.id == id }
        case .freeze(let id): return project.freezes.contains { $0.id == id }
        case .caption(let id): return project.captions.contains { $0.id == id }
        }
    }

    /// Removes the selected item.
    func deleteSelection() {
        guard let selection else { return }
        let change: VideoEditChange = [.segments, .render, .timing]
        edit(change) { project in
            switch selection {
            case .zoom(let id): project.zooms.removeAll { $0.id == id }
            case .censor(let id): project.censors.removeAll { $0.id == id }
            case .text(let id): project.texts.removeAll { $0.id == id }
            case .cut(let id): project.cuts.removeAll { $0.id == id }
            case .speed(let id): project.speeds.removeAll { $0.id == id }
            case .freeze(let id): project.freezes.removeAll { $0.id == id }
            case .caption(let id): project.captions.removeAll { $0.id == id }
            }
        }
        self.selection = nil
    }

    /// The look is remembered for the next recording whenever it changes.
    func rememberLook() {
        guard RecordingSessionStore.owns(source.originalURL) else { return }
        project.look.remember()
    }

    // MARK: Pointer motion

    /// Smoothed pointer track for the current smoothing amount. Short takes
    /// are built synchronously; long ones build in the background and call
    /// `onReady` when available (returning the previous track meanwhile).
    func cursorTrack(onReady: @escaping () -> Void) -> CursorTrack? {
        guard let recording, !recording.isEmpty else { return nil }
        let smoothing = project.look.cursor.smoothing
        if let cached = trackCache, cached.smoothing == smoothing { return cached.track }
        if recording.times.count < 200_000 {
            let track = CursorMotion.buildTrack(from: recording, smoothing: smoothing)
            trackCache = (smoothing, track)
            return track
        }
        if pendingSmoothing != smoothing {
            // Only the newest request keeps computing.
            trackWorker?.cancel()
            trackTask?.cancel()
            pendingSmoothing = smoothing
            let worker = Task.detached(priority: .userInitiated) { () -> CursorTrack? in
                CursorMotion.buildTrack(from: recording, smoothing: smoothing, isCancelled: { Task.isCancelled })
            }
            trackWorker = worker
            trackTask = Task { [weak self] in
                guard let track = await worker.value, !Task.isCancelled, let self,
                      self.pendingSmoothing == smoothing else { return }
                self.trackCache = (smoothing, track)
                self.pendingSmoothing = nil
                onReady()
            }
        }
        return trackCache?.track
    }

    /// The exact track for the current settings, computed now if needed.
    /// Exports use this so they never freeze a stale or missing pointer.
    func cursorTrackForExport() -> CursorTrack? {
        guard let recording, !recording.isEmpty else { return nil }
        let smoothing = project.look.cursor.smoothing
        if let cached = trackCache, cached.smoothing == smoothing { return cached.track }
        let track = CursorMotion.buildTrack(from: recording, smoothing: smoothing)
        trackCache = (smoothing, track)
        return track
    }

    // MARK: Persistence

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    /// Writes the project atomically on a serial queue. A failed write keeps
    /// the project dirty so the next change or close retries it.
    func saveNow(synchronously: Bool = false) {
        autosaveWork?.cancel()
        autosaveWork = nil
        guard let url = projectURL else { return }
        let data = project.encoded()
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard data != savedState || (!exists && data != initialState) else { return }
        // A project never changed from its initial state needs no file.
        if data == initialState && !exists { return }
        let write = { () -> Bool in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return true
            } catch {
                return false
            }
        }
        if synchronously {
            if Self.saveQueue.sync(execute: write) { savedState = data }
            return
        }
        Self.saveQueue.async { [weak self] in
            let ok = write()
            DispatchQueue.main.async {
                guard ok, let self else { return }
                // A newer edit may already be queued; only mark what was written.
                if self.project.encoded() == data { self.savedState = data }
            }
        }
    }

    /// Copies a user-chosen background image into the project folder.
    func importBackgroundImage(from url: URL) -> String? {
        guard let directory = projectDirectory else { return nil }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let name = "background-\(UUID().uuidString.prefix(8)).\(ext)"
        let destination = directory.appendingPathComponent(name)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
            return name
        } catch {
            return nil
        }
    }

    deinit {
        trackTask?.cancel()
        trackWorker?.cancel()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }
}
