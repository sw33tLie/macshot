#if !OFFLINE
import CryptoKit
import Foundation

/// What an uploader is asked to send: either bytes already in memory (an
/// encoded screenshot) or a file on disk (a recording).
///
/// Recordings are routinely hundreds of megabytes — a 4K screen recording runs
/// well past a gigabyte — so they are never read into memory. Reading one with
/// `Data(contentsOf:)` and then building a request body from it costs two full
/// copies of the file before a byte is sent, which is enough to get the app
/// jetsammed on a long capture.
enum UploadPayload: Sendable {
    case data(Data)
    case file(URL)
    case image(HistoryImageSnapshot.Image)

    /// Bytes read/streamed at a time. Big enough to keep syscalls cheap, small
    /// enough that peak memory stays flat regardless of file size.
    nonisolated static let chunkSize = 1 << 20  // 1 MiB

    nonisolated var byteCount: Int? {
        switch self {
        case .data(let data):
            return data.count
        case .file(let url):
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            return values?.fileSize
        case .image: return nil
        }
    }

    /// Feeds the payload to `consume` in chunks, never holding more than one
    /// chunk beyond what the caller keeps.
    nonisolated func forEachChunk(_ consume: (Data) throws -> Void) throws {
        switch self {
        case .image(let image):
            guard let data = ImageEncoder.encodeWithCGImageDestination(cgImage: image.pixels,
                type: "public.png", lossyQuality: nil) else { throw CocoaError(.fileWriteUnknown) }
            try UploadPayload.data(data).forEachChunk(consume)
        case .data(let data):
            var offset = 0
            while offset < data.count {
                let end = min(offset + Self.chunkSize, data.count)
                try consume(data.subdata(in: offset..<end))
                offset = end
            }
        case .file(let url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while true {
                let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try consume(chunk)
            }
        }
    }

    /// SHA256 of the payload, computed incrementally — AWS SigV4 needs the
    /// content hash, which would otherwise force the whole file into memory.
    nonisolated func sha256Hex() throws -> String {
        var hasher = SHA256()
        try forEachChunk { hasher.update(data: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Writes the payload to `destination`, replacing anything already there.
    @discardableResult
    nonisolated func write(to destination: URL) throws -> URL {
        try MultipartBodyWriter.write(to: destination) { append in
            try forEachChunk(append)
        }
        return destination
    }
}

/// Builds a request body on disk instead of in memory.
enum MultipartBodyWriter {

    /// Runs `build`, handing it an `append` function that streams straight to
    /// `destination`. The file is removed if anything throws, so a failed
    /// upload can't leave a half-written body behind.
    nonisolated static func write(to destination: URL, build: ((Data) throws -> Void) throws -> Void) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: destination)
        var succeeded = false
        defer {
            try? handle.close()
            if !succeeded { try? fm.removeItem(at: destination) }
        }
        try build { chunk in
            try handle.write(contentsOf: chunk)
        }
        succeeded = true
    }

    /// Writes a `multipart/related` body (JSON metadata part + payload part) to
    /// `destination` without materializing the payload in memory. This is the
    /// shape Google Drive's multipart upload endpoint expects.
    nonisolated static func writeRelatedBody(
        metadata: Data,
        mimeType: String,
        boundary: String,
        payload: UploadPayload,
        to destination: URL
    ) throws {
        try write(to: destination) { append in
            try append(Data("--\(boundary)\r\n".utf8))
            try append(Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
            try append(metadata)
            try append(Data("\r\n--\(boundary)\r\n".utf8))
            try append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
            try payload.forEachChunk(append)
            try append(Data("\r\n--\(boundary)--\r\n".utf8))
        }
    }
}
#endif
