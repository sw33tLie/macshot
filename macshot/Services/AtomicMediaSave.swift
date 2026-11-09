import Foundation
import Darwin

/// Builds the replacement on the destination's volume, then publishes it with
/// one atomic rename. Call the I/O methods from a worker queue. A failed copy,
/// export, or commit must leave the previous destination intact.
final class AtomicMediaSave: @unchecked Sendable {
    let destinationURL: URL
    let stagingURL: URL
    private let stagingDirectory: URL

    nonisolated init(destinationURL: URL) throws {
        self.destinationURL = destinationURL
        stagingDirectory = try FileManager.default.url(for: .itemReplacementDirectory,
            in: .userDomainMask, appropriateFor: destinationURL, create: true)
        stagingURL = stagingDirectory.appendingPathComponent(destinationURL.lastPathComponent)
    }

    nonisolated func copySource(_ sourceURL: URL, allowClone: Bool = true,
                                checkCancellation: @Sendable () throws -> Void = {},
                                progress: @Sendable (Double) -> Void = { _ in }) throws {
        try checkCancellation()
        // APFS clones share existing blocks until either file changes. Other
        // volumes copy in cancellable 1 MiB chunks; neither blocks the UI.
        let cloned = allowClone && sourceURL.withUnsafeFileSystemRepresentation { source in
            stagingURL.withUnsafeFileSystemRepresentation { destination in
                guard let source = source, let destination = destination else { return false }
                return clonefile(source, destination, 0) == 0
            }
        }
        if cloned {
            try checkCancellation()
            progress(1)
            return
        }
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        var metadata = stat()
        guard fstat(input.fileDescriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let descriptor = try stagingURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CocoaError(.fileWriteInvalidFileName) }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        var copied: Int64 = 0
        var lastPercent = -1
        while copied < metadata.st_size {
            try checkCancellation()
            let count = try autoreleasepool { () throws -> Int in
                guard let data = try input.read(upToCount: Int(min(1024 * 1024, metadata.st_size - copied))),
                      !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                try output.write(contentsOf: data)
                return data.count
            }
            copied += Int64(count)
            let fraction = Double(copied) / Double(metadata.st_size)
            let percent = Int(fraction * 100)
            if percent != lastPercent {
                lastPercent = percent
                progress(fraction)
            }
        }
        try checkCancellation()
        var after = stat()
        guard fstat(input.fileDescriptor, &after) == 0,
              after.st_size == metadata.st_size,
              after.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    nonisolated func commit(overwritingExisting: Bool = true, beforePublish: () throws -> Void = {}) throws {
        // A missing/empty output must never replace an existing recording.
        let values = try stagingURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Flush before publishing. This also surfaces a deferred disk-full/I/O
        // error while the original destination is still untouched.
        let handle = try FileHandle(forWritingTo: stagingURL)
        defer { try? handle.close() }
        try handle.synchronize()
        try beforePublish()
        let code: Int32 = stagingURL.withUnsafeFileSystemRepresentation { source in
            destinationURL.withUnsafeFileSystemRepresentation { destination in
                guard let source = source, let destination = destination else { return EINVAL }
                let status = overwritingExisting ? rename(source, destination)
                    : renamex_np(source, destination, UInt32(RENAME_EXCL))
                return status == 0 ? 0 : errno
            }
        }
        guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }

    deinit {
        let directory = stagingDirectory
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// Takes ownership of an access count the caller has already acquired. Jobs
/// retain this object, so even a closed/deallocated editor releases it once.
final class SaveDirectoryLease: @unchecked Sendable {
    private let url: URL?
    nonisolated init(alreadyAccessing url: URL?) { self.url = url }
    deinit { url?.stopAccessingSecurityScopedResource() }
}

/// Keeps a temporary source alive through background reads after editor close.
/// User-owned source files never get a deletion lease.
final class TemporaryMediaLease: @unchecked Sendable {
    private let url: URL
    private let cleanupURL: URL
    private let retainedLease: TemporaryMediaLease?
    private let retainedFileHandle: FileHandle?
    private let cleanupQueue: DispatchQueue
    private let lock = NSLock()
    nonisolated(unsafe) private var shouldDelete = true

    nonisolated init(url: URL, cleanupURL: URL? = nil, retaining retainedLease: TemporaryMediaLease? = nil,
                     retainingFileHandle: FileHandle? = nil,
                     cleanupQueue: DispatchQueue = .global(qos: .utility)) {
        self.url = url
        self.cleanupURL = cleanupURL ?? url
        self.retainedLease = retainedLease
        self.retainedFileHandle = retainingFileHandle
        self.cleanupQueue = cleanupQueue
    }

    /// Saving back to a temporary source makes that path user-owned. Retaining
    /// the input for the export alone is insufficient: editor close must not
    /// subsequently delete the successfully published file.
    nonisolated func preserve(ifSavedAt destination: URL) {
        retainedLease?.preserve(ifSavedAt: destination)
        guard url.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() else { return }
        lock.lock()
        shouldDelete = false
        lock.unlock()
    }

    deinit {
        guard shouldDelete else { return }
        let file = cleanupURL
        let handle = retainedFileHandle
        cleanupQueue.async {
            defer { withExtendedLifetime(handle) {} }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
