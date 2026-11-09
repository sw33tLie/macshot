import Cocoa

struct HistoryEntry {
    let id: String           // UUID filename (without extension)
    let fileExtension: String // "png" or "jpg"
    let timestamp: Date       // creation time
    /// Last time the entry was edited & saved from the editor (nil = never).
    var lastEditedAt: Date? = nil
    var pixelWidth: Int
    var pixelHeight: Int
    var hasAnnotations: Bool = false  // true if editable raw data is saved alongside
    var thumbnail: NSImage?  // lazily cached, tiny
    var revision: String? = nil

    /// The time used for "order by last edit": the most recent of edit/creation.
    var effectiveSortDate: Date { lastEditedAt ?? timestamp }

    var timeAgoString: String {
        guard timestamp.timeIntervalSinceReferenceDate.isFinite,
              timestamp >= .distantPast, timestamp <= .distantFuture else { return "-" }
        let seconds = SafeNumerics.int((-timestamp.timeIntervalSinceNow).rounded(.towardZero))
        if seconds < 5 { return L("just now") }
        if seconds < 60 { return String(format: L("%ds ago"), seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: L("%dm ago"), minutes) }
        let hours = minutes / 60
        if hours < 24 { return String(format: L("%dh ago"), hours) }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: timestamp)
    }
}

@MainActor
final class ScreenshotHistory {
    static let shared = ScreenshotHistory()
    typealias IndexEntry = HistoryRecord
    private(set) var entries: [HistoryEntry] = []
    private let historyDir: URL
    private let storage: HistoryStorage
    private var committedRecords: [HistoryRecord]
    private var pendingRecords: [String: HistoryRecord] = [:]
    private var hiddenIDs: [String: UUID] = [:]
    private var activeWrites = 0
    private let maximumPendingBytes: Int
    private let maximumPendingSaves: Int
    private(set) var pendingSnapshotBytes = 0
    private var pendingSaves = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var hasPendingWrites: Bool { activeWrites > 0 }
    func containsEntry(id: String) -> Bool {
        hiddenIDs[id] == nil && (pendingRecords[id] != nil || committedRecords.contains { $0.id == id })
    }

    var maxEntries: Int {
        if UserDefaults.standard.bool(forKey: "historyUnlimited") { return Int.max }
        return max(0, UserDefaults.standard.object(forKey: "historySize") as? Int ?? 10)
    }
    static var orderByLastEdit: Bool {
        UserDefaults.standard.object(forKey: "historyOrderByLastEdit") as? Bool ?? true
    }

    init(directory: URL? = nil, cleanupQueue: DispatchQueue = .global(qos: .utility),
         writeQueue: DispatchQueue = DispatchQueue(label: "macshot.history.writer", qos: .utility),
         maximumPendingBytes: Int = 512 * 1024 * 1024, maximumPendingSaves: Int = 32,
         beforeIndexPublication: @escaping @Sendable () throws -> Void = {}) {
        self.maximumPendingBytes = max(1, maximumPendingBytes)
        self.maximumPendingSaves = max(1, maximumPendingSaves)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        historyDir = directory ?? support.appendingPathComponent("com.sw33tlie.macshot/history")
        try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let data = try? Data(contentsOf: historyDir.appendingPathComponent("index.json"))
        let complete = data.flatMap { try? JSONDecoder().decode([HistoryRecord].self, from: $0) }
        let loaded = complete ?? data.flatMap { LenientArrayDecoder.decode(HistoryRecord.self, from: $0) } ?? []
        var seen = Set<UUID>()
        let root = historyDir
        committedRecords = loaded.filter {
            guard let id = UUID(uuidString: $0.id), FileManager.default.fileExists(atPath: $0.url(in: root).path) else { return false }
            return seen.insert(id).inserted
        }
        storage = HistoryStorage(directory: root, records: committedRecords, queue: writeQueue,
                                 beforeIndexPublication: beforeIndexPublication)
        publishEntries()
        let indexedIDs = complete.map { Set($0.map(\.id)) }
        let cutoff = Date()
        cleanupQueue.async { HistoryFileCleanup.sweep(directory: root, indexedIDs: indexedIDs, asOf: cutoff) }
        if committedRecords.count > maxEntries { pruneToMax() }
    }

    /// Return the reserved identifier directly. It must never be inferred from
    /// entries.first: saving is asynchronous, and history may be disabled.
    @discardableResult
    func add(image: NSImage, rawImage: NSImage? = nil, annotations: [Annotation]? = nil,
             editState: CaptureEditState? = nil, completion: ((Bool) -> Void)? = nil) -> String? {
        let limit = maxEntries
        guard limit > 0 else { completion?(false); return nil }
        do {
            try checkSaveCapacity()
            let snapshot = try HistoryImageSnapshot(image: image, rawImage: rawImage,
                                                    annotations: annotations, editState: editState)
            let record = HistoryRecord(id: UUID().uuidString, fileExtension: "png", timestamp: Date(),
                pixelWidth: snapshot.composited.pixels.width, pixelHeight: snapshot.composited.pixels.height,
                hasAnnotations: snapshot.isEditable ? true : nil, lastEditedAt: nil, revision: UUID().uuidString)
            try save(record, snapshot: snapshot, maximum: limit, completion: completion)
            return record.id
        } catch {
            report(error)
            completion?(false)
            return nil
        }
    }

    func updateEntry(id: String, compositedImage: NSImage, rawImage: NSImage?, annotations: [Annotation]?,
                     editState: CaptureEditState? = nil, completion: ((Bool) -> Void)? = nil) {
        guard maxEntries > 0, hiddenIDs[id] == nil,
              let previous = pendingRecords[id] ?? committedRecords.first(where: { $0.id == id }) else {
            completion?(false); return
        }
        do {
            try checkSaveCapacity()
            let snapshot = try HistoryImageSnapshot(image: compositedImage, rawImage: rawImage,
                                                    annotations: annotations, editState: editState)
            let record = HistoryRecord(id: id, fileExtension: "png", timestamp: previous.timestamp,
                pixelWidth: snapshot.composited.pixels.width, pixelHeight: snapshot.composited.pixels.height,
                hasAnnotations: snapshot.isEditable ? true : nil, lastEditedAt: Date(), revision: UUID().uuidString)
            try save(record, snapshot: snapshot, maximum: maxEntries, completion: completion)
        } catch { report(error); completion?(false) }
    }

    private func save(_ record: HistoryRecord, snapshot: HistoryImageSnapshot, maximum: Int,
                      completion: ((Bool) -> Void)?) throws {
        let bytes = snapshot.retainedBytes
        // One oversized scroll capture may save by itself. Never retain an
        // unbounded burst of additional snapshots while that save is pending.
        guard pendingSaves == 0 || bytes <= maximumPendingBytes - pendingSnapshotBytes else {
            throw saveQueueBusyError()
        }
        pendingSnapshotBytes += bytes
        pendingSaves += 1
        pendingRecords[record.id] = record
        enqueue(.save(record, snapshot, maximum: maximum, orderByEdit: Self.orderByLastEdit)) { [weak self] success in
            guard let self else { completion?(success); return }
            self.pendingSnapshotBytes -= bytes
            self.pendingSaves -= 1
            if self.pendingRecords[record.id]?.revision == record.revision { self.pendingRecords.removeValue(forKey: record.id) }
            completion?(success)
        }
    }

    private func saveQueueBusyError() -> NSError {
        NSError(domain: "macshot.history", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("History is busy saving. Please try again shortly.")])
    }

    private func checkSaveCapacity() throws {
        guard pendingSaves < maximumPendingSaves,
              pendingSaves == 0 || pendingSnapshotBytes < maximumPendingBytes else { throw saveQueueBusyError() }
    }

    private func enqueue(_ operation: HistoryStorage.Operation, completion: ((Bool) -> Void)? = nil) {
        activeWrites += 1
        // Retain the owner until publication, UI notification and cleanup finish.
        storage.enqueue(operation) { result in
            switch result {
            case .success(let commit):
                self.committedRecords = commit.records
                self.publishEntries()
                completion?(true)
                self.storage.cleanup(commit.obsoleteFiles) { error in
                    if let error { self.report(error) }
                    self.finishedWrite()
                }
            case .failure(let error):
                self.report(error)
                completion?(false)
                self.finishedWrite()
            }
        }
    }

    private func finishedWrite() {
        activeWrites -= 1
        guard activeWrites == 0 else { return }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilIdle() async {
        guard hasPendingWrites else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func report(_ error: Error) {
        ImageSaveService.reportFailure(L("Could not save the screenshot to history.") + " " + error.localizedDescription)
    }

    private func publishEntries() {
        entries = HistoryStorage.ordered(committedRecords, byEdit: Self.orderByLastEdit)
            .filter { hiddenIDs[$0.id] == nil }.map {
                HistoryEntry(id: $0.id, fileExtension: $0.fileExtension, timestamp: $0.timestamp,
                    lastEditedAt: $0.lastEditedAt, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                    hasAnnotations: $0.hasAnnotations ?? false, thumbnail: nil, revision: $0.revision)
            }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
    static let didChange = Notification.Name("macshot.screenshotHistoryDidChange")

    func applyHistoryOrderPreference(persist: Bool = false) {
        publishEntries()
        if persist { pruneToMax() }
    }
    func pruneToMax() {
        if maxEntries == 0 { clear(); return }
        enqueue(.prune(maximum: maxEntries, orderByEdit: Self.orderByLastEdit))
    }
    func removeEntry(id: String) { remove(ids: [id]) }
    func clear() { remove(ids: Set(committedRecords.map(\.id)).union(pendingRecords.keys)) }

    private func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let token = UUID()
        for id in ids { hiddenIDs[id] = token; pendingRecords.removeValue(forKey: id) }
        publishEntries()
        enqueue(.remove(ids)) { [weak self] _ in
            guard let self else { return }
            for id in ids where self.hiddenIDs[id] == token { self.hiddenIDs.removeValue(forKey: id) }
            self.publishEntries()
        }
    }

    private func record(for entry: HistoryEntry) -> HistoryRecord {
        committedRecords.first(where: { $0.id == entry.id }) ?? HistoryRecord(id: entry.id,
            fileExtension: entry.fileExtension, timestamp: entry.timestamp, pixelWidth: entry.pixelWidth,
            pixelHeight: entry.pixelHeight, hasAnnotations: entry.hasAnnotations,
            lastEditedAt: entry.lastEditedAt, revision: entry.revision)
    }
    func fileURL(for entry: HistoryEntry) -> URL { record(for: entry).url(in: historyDir) }
    func sidecarURL(for entry: HistoryEntry, suffix: String) -> URL { record(for: entry).url(in: historyDir, suffix: suffix) }
    func copyEntry(at index: Int) {
        guard entries.indices.contains(index), let image = loadImage(for: entries[index]) else { return }
        ImageEncoder.copyToClipboard(image)
    }
    func loadImage(for entry: HistoryEntry) -> NSImage? { image(at: fileURL(for: entry)) }
    func loadRawImage(for entry: HistoryEntry) -> NSImage? {
        guard record(for: entry).hasAnnotations == true else { return nil }
        return image(at: sidecarURL(for: entry, suffix: "_raw.png"))
    }
    func loadAnnotations(for entry: HistoryEntry) -> [Annotation]? {
        guard record(for: entry).hasAnnotations == true else { return nil }
        guard let data = try? Data(contentsOf: sidecarURL(for: entry, suffix: "_annotations.json")) else { return [] }
        return AnnotationSerializer.decode(data)
    }
    func loadEditState(for entry: HistoryEntry) -> CaptureEditState? {
        guard record(for: entry).hasAnnotations == true,
              let data = try? Data(contentsOf: sidecarURL(for: entry, suffix: "_edit.json")) else { return nil }
        return try? JSONDecoder().decode(CaptureEditState.self, from: data)
    }
    struct EditableCapture {
        let rawImage: NSImage
        let annotations: [Annotation]
        let editState: CaptureEditState?
    }

    /// Reopen the editable parts together. Missing optional legacy sidecars are
    /// supported, but a present unreadable sidecar must fall back to the saved
    /// composited image instead of silently removing its effects/annotations.
    func loadEditableCapture(for entry: HistoryEntry) -> EditableCapture? {
        guard let rawImage = loadRawImage(for: entry) else { return nil }
        let annotationsURL = sidecarURL(for: entry, suffix: "_annotations.json")
        let editURL = sidecarURL(for: entry, suffix: "_edit.json")
        let hasAnnotations = FileManager.default.fileExists(atPath: annotationsURL.path)
        let hasEditState = FileManager.default.fileExists(atPath: editURL.path)
        guard hasAnnotations || hasEditState else { return nil }
        let annotations: [Annotation]
        if hasAnnotations {
            guard let data = try? Data(contentsOf: annotationsURL),
                  let restored = AnnotationSerializer.decode(data, requireAll: true) else { return nil }
            annotations = restored
        } else { annotations = [] }
        let editState: CaptureEditState?
        if hasEditState {
            guard let restored = loadEditState(for: entry) else { return nil }
            if restored.customBeautifyBackgroundPNG != nil && restored.customBeautifyBackground == nil { return nil }
            editState = restored
        } else { editState = nil }
        return EditableCapture(rawImage: rawImage, annotations: annotations, editState: editState)
    }
    func loadThumbnail(for entry: HistoryEntry) -> NSImage? {
        image(at: sidecarURL(for: entry, suffix: "_thumb.png"))
    }
    func loadPreview(for entry: HistoryEntry) -> NSImage? {
        guard let pixels = HistoryImageSnapshot.preview(at: previewURLs(for: entry)) else { return nil }
        return NSImage(cgImage: pixels, size: .zero)
    }
    func previewURLs(for entry: HistoryEntry) -> [URL] {
        [sidecarURL(for: entry, suffix: "_preview.png"), fileURL(for: entry)]
    }
    private func image(at url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }
}
