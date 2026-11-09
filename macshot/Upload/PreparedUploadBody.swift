#if !OFFLINE
import CryptoKit
import Foundation

/// A request owns its bytes until every attempt finishes. The digest is made
/// during the same pass that writes those bytes, never by rereading the source.
final class PreparedUploadBody: Sendable {
    let url: URL
    let byteCount: Int
    let sha256: String

    nonisolated init(payload: UploadPayload) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("macshot_upload_\(UUID().uuidString).tmp")
        var digest = SHA256()
        var count = 0
        try MultipartBodyWriter.write(to: url) { append in
            try payload.forEachChunk { chunk in
                try append(chunk)
                digest.update(data: chunk)
                count += chunk.count
            }
        }
        byteCount = count
        sha256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated init(relatedTo source: PreparedUploadBody, metadata: Data,
                     mimeType: String, boundary: String) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("macshot_upload_\(UUID().uuidString).tmp")
        try MultipartBodyWriter.writeRelatedBody(metadata: metadata, mimeType: mimeType,
            boundary: boundary, payload: .file(source.url), to: url)
        do { byteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        // Only raw S3 bodies need a payload signature.
        sha256 = ""
    }

    nonisolated init(formImage source: PreparedUploadBody, boundary: String) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("macshot_upload_\(UUID().uuidString).tmp")
        try MultipartBodyWriter.write(to: url) { append in
            try append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"Screenshot.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
            try UploadPayload.file(source.url).forEachChunk(append)
            try append(Data("\r\n--\(boundary)--\r\n".utf8))
        }
        do { byteCount = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        sha256 = ""
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Uploads share the application's quit drain with local output jobs. Each
/// job owns its result and callbacks, including while its editor is closed.
enum UploadJob {
    @discardableResult
    static func start<Value>(filename: String,
                            operation: @escaping @MainActor () async throws -> Value,
                            completion: @escaping @MainActor (Result<Value, Error>) -> Void) -> MediaExportCoordinator.Job {
        var value: Value?
        return MediaExportCoordinator.shared.start(title: filename, status: L("Upload"), operation: { cancellation, _ in
            // There is no upload Cancel control yet. Once a remote request can
            // commit, don't let a late cancellation misreport it as unsaved.
            try cancellation.beginPublication()
            value = try await operation()
        }, completion: { result in
            switch result {
            case .success:
                if let value { completion(.success(value)) }
                else { completion(.failure(CocoaError(.fileWriteUnknown))) }
            case .failure(let error): completion(.failure(error))
            }
        })
    }
}

enum UploadTransport {
    final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let progress: @MainActor @Sendable (Double) -> Void
        nonisolated private let lock = NSLock()
        nonisolated(unsafe) private var active = true
        nonisolated init(progress: @escaping @MainActor @Sendable (Double) -> Void) { self.progress = progress }
        nonisolated func finish() { lock.lock(); active = false; lock.unlock() }
        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            let fraction = min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                lock.lock(); let deliver = active; lock.unlock()
                if deliver { progress(fraction) }
            }
        }
    }

    static func upload(session: URLSession, request: URLRequest, body: PreparedUploadBody,
                       progress: (@MainActor @Sendable (Double) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        let delegate = progress.map { ProgressDelegate(progress: $0) }
        defer { delegate?.finish(); withExtendedLifetime(body) {} }
        let (data, response) = try await session.upload(for: request, fromFile: body.url, delegate: delegate)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    nonisolated static func formBody(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
}
#endif
