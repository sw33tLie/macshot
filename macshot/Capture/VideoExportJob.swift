import AVFoundation

/// A prepared, single-use export. The caller transfers ownership of its media
/// objects here before doing asynchronous destination setup. Running it reads
/// no editor state, and does not require the editor window to remain open.
@MainActor
final class VideoExportJob {
    private enum Backend {
        case session(AVAssetExportSession)
        case transcode(VideoTranscoder.Request)
    }

    private let backend: Backend
    private let sourceLease: TemporaryMediaLease?
    private var started = false

    init(session: AVAssetExportSession, sourceLease: TemporaryMediaLease? = nil) {
        backend = .session(session)
        self.sourceLease = sourceLease
    }
    init(request: VideoTranscoder.Request, sourceLease: TemporaryMediaLease? = nil) {
        backend = .transcode(request)
        self.sourceLease = sourceLease
    }

    func export(to outputURL: URL, progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }) async throws {
        guard !started else { throw MediaExportPump.ExportError.invalidSetup }
        started = true
        defer { withExtendedLifetime(sourceLease) {} }
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        switch backend {
        case .transcode(let request):
            try await VideoTranscoder.export(request.writing(to: outputURL)) { fraction in
                DispatchQueue.main.async { progress(fraction) }
            }
        case .session(let session):
            session.outputURL = outputURL
            let cancellation = SessionCancellation(session: session)
            let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
                MainActor.assumeIsolated { progress(Double(cancellation.session.progress)) }
            }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                await session.export()
                try Task.checkCancellation()
                guard session.status == .completed else {
                    throw session.error ?? MediaExportPump.ExportError.invalidSetup
                }
            }, onCancel: { cancellation.cancel() })
        }
        progress(1)
    }

    /// AVFoundation permits cancelExport from another queue. This immutable
    /// reference is the only session access made by the cancellation handler.
    private struct SessionCancellation: @unchecked Sendable {
        nonisolated(unsafe) let session: AVAssetExportSession
        nonisolated func cancel() { session.cancelExport() }
    }
}
