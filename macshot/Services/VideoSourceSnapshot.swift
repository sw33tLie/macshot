import Foundation
import Darwin

/// Every editor reads its own stable media version. Replacing the public file
/// therefore cannot change playback or apply edits twice in a later export.
/// APFS uses a copy-on-write clone; other volumes copy in bounded chunks on a
/// worker. The read lease travels with every prepared export.
final class VideoSourceSnapshot: @unchecked Sendable {
    let originalURL: URL
    let mediaURL: URL
    let lease: TemporaryMediaLease
    private let durableOriginal: Bool

    nonisolated static var temporaryRootURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("macshot-editor-sources", isDirectory: true)
    }

    nonisolated private init(originalURL: URL, mediaURL: URL, lease: TemporaryMediaLease, durableOriginal: Bool) {
        self.originalURL = originalURL
        self.mediaURL = mediaURL
        self.lease = lease
        self.durableOriginal = durableOriginal
    }

    /// Call from a worker. `workspaceRoot` and `allowClone` support isolated
    /// filesystem tests without touching the user's recording library.
    nonisolated static func prepare(url: URL, deleteOnClose: Bool,
                                    workspaceRoot: URL? = nil, allowClone: Bool = true,
                                    recordingRoot: URL = RecordingSessionStore.rootURL,
                                    cleanupQueue: DispatchQueue = .global(qos: .utility),
                                    cancellation: MediaExportCancellation = MediaExportCancellation(),
                                    progress: @Sendable (Double) -> Void = { _ in }) throws -> VideoSourceSnapshot {
        try cancellation.check()
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let accessingSource = url.startAccessingSecurityScopedResource()
        defer { if accessingSource { url.stopAccessingSecurityScopedResource() } }
        let durable = RecordingSessionStore.owns(url, root: recordingRoot)
        // A durable take's backup must survive if Save As explicitly replaces
        // that take. Temporary working copies are removed after their readers
        // finish; a preserved backup stays beside its recording session.
        let root = workspaceRoot ?? (durable
            ? url.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("Editor Sources", isDirectory: true)
            : temporaryRootURL)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var prepared = false
        defer { if !prepared { try? FileManager.default.removeItem(at: directory) } }
        let descriptor = directory.appendingPathComponent(".readers").withUnsafeFileSystemRepresentation {
            $0.map { Darwin.open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR) } ?? -1
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let readerLock = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let mediaURL = directory.appendingPathComponent(url.lastPathComponent)
        let save = try AtomicMediaSave(destinationURL: mediaURL)
        try save.copySource(url, allowClone: allowClone, checkCancellation: { try cancellation.check() }, progress: progress)
        try save.commit(beforePublish: cancellation.check)
        try cancellation.check()
        let originalLease = deleteOnClose && !durable ? TemporaryMediaLease(url: url, cleanupQueue: cleanupQueue) : nil
        let lease = TemporaryMediaLease(url: mediaURL, cleanupURL: directory, retaining: originalLease,
                                       retainingFileHandle: readerLock, cleanupQueue: cleanupQueue)
        prepared = true
        return VideoSourceSnapshot(originalURL: url, mediaURL: mediaURL, lease: lease, durableOriginal: durable)
    }

    /// Publication transfers ownership of a disposable public input to the
    /// user. A recording original also retains its pre-export bytes durably.
    nonisolated func didSave(at destination: URL) {
        lease.preserve(ifSavedAt: destination)
        if durableOriginal,
           originalURL.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() {
            lease.preserve(ifSavedAt: mediaURL)
        }
    }

    /// Reclaim abandoned private copies after a crash/quit. A kernel lock
    /// protects readers in another process, including editors open >24 hours.
    /// Durable backup folders are outside this temporary root and never swept.
    nonisolated static func removeAbandonedTemporaryCopies(root: URL = temporaryRootURL,
                                                          now: Date = Date(),
                                                          olderThan: TimeInterval = 24 * 60 * 60) -> Int {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let directories = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return 0 }
        var removed = 0
        for directory in directories {
            guard UUID(uuidString: directory.lastPathComponent) != nil,
                  let values = try? directory.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let modified = values.contentModificationDate,
                  modified < now.addingTimeInterval(-olderThan) else { continue }
            let descriptor = directory.appendingPathComponent(".readers").withUnsafeFileSystemRepresentation {
                $0.map { Darwin.open($0, O_RDWR | O_CLOEXEC) } ?? -1
            }
            if descriptor < 0 {
                guard errno == ENOENT else { continue }
            } else if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                Darwin.close(descriptor)
                continue
            }
            defer { if descriptor >= 0 { Darwin.close(descriptor) } }
            if (try? FileManager.default.removeItem(at: directory)) != nil { removed += 1 }
        }
        return removed
    }
}
