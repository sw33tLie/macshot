import Foundation

struct HistoryRecord: Codable, Sendable {
    let id: String
    let fileExtension: String
    let timestamp: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let hasAnnotations: Bool?
    let lastEditedAt: Date?
    /// Nil reads legacy flat files. Each new save publishes a complete revision.
    let revision: String?

    nonisolated init(id: String, fileExtension: String, timestamp: Date, pixelWidth: Int, pixelHeight: Int,
                    hasAnnotations: Bool?, lastEditedAt: Date?, revision: String? = nil) {
        self.id = id; self.fileExtension = fileExtension; self.timestamp = timestamp
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.hasAnnotations = hasAnnotations; self.lastEditedAt = lastEditedAt; self.revision = revision
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fileExtension = c.decode(.fileExtension, or: "png")
        guard id.count == 36, UUID(uuidString: id) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Invalid history identifier")
        }
        guard ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "tif"].contains(fileExtension.lowercased()) else {
            throw DecodingError.dataCorruptedError(forKey: .fileExtension, in: c, debugDescription: "Invalid history image extension")
        }
        let date = c.decode(.timestamp, or: Date(timeIntervalSince1970: 0))
        timestamp = date.timeIntervalSinceReferenceDate.isFinite && date >= .distantPast && date <= .distantFuture
            ? date : Date(timeIntervalSince1970: 0)
        pixelWidth = max(0, c.decode(.pixelWidth, or: 0))
        pixelHeight = max(0, c.decode(.pixelHeight, or: 0))
        hasAnnotations = c.decodeOptional(.hasAnnotations)
        if let edited: Date = c.decodeOptional(.lastEditedAt), edited.timeIntervalSinceReferenceDate.isFinite,
           edited >= .distantPast, edited <= .distantFuture { lastEditedAt = edited } else { lastEditedAt = nil }
        // An invalid present revision must never silently redirect to a legacy file.
        if c.contains(.revision), !(try c.decodeNil(forKey: .revision)) {
            let value = try c.decode(String.self, forKey: .revision)
            guard value.count == 36, UUID(uuidString: value) != nil else {
                throw DecodingError.dataCorruptedError(forKey: .revision, in: c, debugDescription: "Invalid history revision")
            }
            revision = value
        } else { revision = nil }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(fileExtension, forKey: .fileExtension)
        try c.encode(timestamp, forKey: .timestamp); try c.encode(pixelWidth, forKey: .pixelWidth)
        try c.encode(pixelHeight, forKey: .pixelHeight); try c.encodeIfPresent(hasAnnotations, forKey: .hasAnnotations)
        try c.encodeIfPresent(lastEditedAt, forKey: .lastEditedAt); try c.encodeIfPresent(revision, forKey: .revision)
    }
    private enum CodingKeys: String, CodingKey {
        case id, fileExtension, timestamp, pixelWidth, pixelHeight, hasAnnotations, lastEditedAt, revision
    }

    nonisolated func url(in directory: URL, suffix: String = "") -> URL {
        if let revision {
            return directory.appendingPathComponent(id, isDirectory: true).appendingPathComponent(revision, isDirectory: true)
                .appendingPathComponent(suffix.isEmpty ? "image.\(fileExtension)" : String(suffix.dropFirst()))
        }
        return directory.appendingPathComponent(suffix.isEmpty ? "\(id).\(fileExtension)" : id + suffix)
    }
}

/// One serial owner for every index mutation. Files are immutable revisions;
/// only a successfully flushed atomic index publication makes one current.
final class HistoryStorage: @unchecked Sendable {
    struct Commit: Sendable {
        let records: [HistoryRecord]
        let obsoleteFiles: [URL]
    }
    enum Operation: Sendable {
        case save(HistoryRecord, HistoryImageSnapshot, maximum: Int, orderByEdit: Bool)
        case remove(Set<String>)
        case prune(maximum: Int, orderByEdit: Bool)
    }
    let directory: URL
    let queue: DispatchQueue
    nonisolated(unsafe) private var records: [HistoryRecord]
    private let beforeIndexPublication: @Sendable () throws -> Void

    nonisolated init(directory: URL, records: [HistoryRecord], queue: DispatchQueue,
                     beforeIndexPublication: @escaping @Sendable () throws -> Void = {}) {
        self.directory = directory; self.records = records; self.queue = queue
        self.beforeIndexPublication = beforeIndexPublication
    }

    nonisolated func enqueue(_ operation: Operation, completion: @escaping @MainActor (Result<Commit, Error>) -> Void) {
        queue.async {
            let result = autoreleasepool { Result { try self.perform(operation) } }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Cleanup is requested only after the UI has adopted the committed index.
    /// It uses exact obsolete revision URLs, never a stale directory scan.
    nonisolated func cleanup(_ files: [URL], completion: @escaping @MainActor (Error?) -> Void) {
        queue.async {
            var failure: Error?
            for file in files where FileManager.default.fileExists(atPath: file.path) {
                do {
                    try FileManager.default.removeItem(at: file)
                    let parent = file.deletingLastPathComponent()
                    if parent != self.directory, UUID(uuidString: parent.lastPathComponent) != nil,
                       (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                        try FileManager.default.removeItem(at: parent)
                    }
                } catch { failure = failure ?? error }
            }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    nonisolated private func perform(_ operation: Operation) throws -> Commit {
        dispatchPrecondition(condition: .onQueue(queue))
        var next = records
        var staged: URL?
        do {
            switch operation {
            case .save(let record, let snapshot, let maximum, let orderByEdit):
                guard let revision = record.revision, UUID(uuidString: record.id) != nil,
                      UUID(uuidString: revision) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
                let folder = directory.appendingPathComponent(record.id, isDirectory: true)
                    .appendingPathComponent(revision, isDirectory: true)
                guard !FileManager.default.fileExists(atPath: folder.path) else { throw CocoaError(.fileWriteFileExists) }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                staged = folder
                try snapshot.composited.writePNG(to: record.url(in: directory))
                try snapshot.composited.writePNG(to: record.url(in: directory, suffix: "_thumb.png"), maximumPointDimension: 36)
                try snapshot.composited.writePNG(to: record.url(in: directory, suffix: "_preview.png"), maximumPointDimension: 240)
                if let raw = snapshot.raw { try raw.writePNG(to: record.url(in: directory, suffix: "_raw.png")) }
                if let data = snapshot.annotations { try data.write(to: record.url(in: directory, suffix: "_annotations.json")) }
                if let data = snapshot.editState { try data.write(to: record.url(in: directory, suffix: "_edit.json")) }
                // Every constituent must be durable before its pointer is published.
                for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    try handle.synchronize()
                }
                next.removeAll { $0.id == record.id }
                next.append(record)
                next = Self.ordered(next, byEdit: orderByEdit)
                next = Array(next.prefix(max(0, maximum)))
            case .remove(let ids): next.removeAll { ids.contains($0.id) }
            case .prune(let maximum, let orderByEdit):
                next = Array(Self.ordered(next, byEdit: orderByEdit).prefix(max(0, maximum)))
            }
            let transaction = try AtomicMediaSave(destinationURL: directory.appendingPathComponent("index.json"))
            try JSONEncoder().encode(next).write(to: transaction.stagingURL)
            try transaction.commit(beforePublish: beforeIndexPublication)
            var obsolete = records.filter { old in !next.contains { $0.id == old.id && $0.revision == old.revision } }
                .flatMap { record -> [URL] in
                    if record.revision != nil { return [record.url(in: directory).deletingLastPathComponent()] }
                    return ["", "_thumb.png", "_preview.png", "_raw.png", "_annotations.json", "_edit.json"]
                        .map { record.url(in: directory, suffix: $0) }
                }
            if let staged, !next.contains(where: { $0.url(in: directory).deletingLastPathComponent() == staged }) {
                obsolete.append(staged)
            }
            records = next
            return Commit(records: next, obsoleteFiles: obsolete)
        } catch {
            if let staged { try? FileManager.default.removeItem(at: staged) }
            throw error
        }
    }

    nonisolated static func ordered(_ records: [HistoryRecord], byEdit: Bool) -> [HistoryRecord] {
        records.enumerated().sorted {
            let first = byEdit ? $0.element.lastEditedAt ?? $0.element.timestamp : $0.element.timestamp
            let second = byEdit ? $1.element.lastEditedAt ?? $1.element.timestamp : $1.element.timestamp
            return first == second ? $0.offset < $1.offset : first > second
        }.map(\.element)
    }
}
