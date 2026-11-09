import AVFoundation
import Speech

/// Transcribes a recording's audio on this Mac with Apple's speech
/// recognizer. Audio never leaves the device: recognition is refused when
/// on-device support is unavailable for the current language.
enum VideoCaptionTranscriber {
    enum TranscriptionError: LocalizedError {
        case notAuthorized, unavailable, noAudio, exportFailed
        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return L("Speech recognition is turned off for macshot in System Settings › Privacy & Security.")
            case .unavailable:
                return L("On-device speech recognition isn't available for your language on this Mac.")
            case .noAudio: return L("This recording has no audio to transcribe.")
            case .exportFailed: return L("The recording's audio could not be read.")
            }
        }
    }

    /// Recognition runs on chunks: long requests are less reliable and a
    /// chunk boundary only risks splitting one word.
    static let chunkDuration: Double = 50

    static func transcribe(asset: AVAsset, lease: TemporaryMediaLease) async throws -> [CaptionTimeline.Word] {
        defer { withExtendedLifetime(lease) {} }
        guard try await authorize() else { throw TranscriptionError.notAuthorized }
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.unavailable
        }
        guard !(try await asset.load(.tracks)).filter({ $0.mediaType == .audio }).isEmpty else {
            throw TranscriptionError.noAudio
        }
        let duration = try await asset.load(.duration).seconds
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("macshot-captions-\(UUID().uuidString)",
                                                                                   isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var words: [CaptionTimeline.Word] = []
        var start = 0.0
        var index = 0
        while start < duration - 0.05 {
            try Task.checkCancellation()
            let length = min(chunkDuration, duration - start)
            let url = folder.appendingPathComponent("chunk-\(index).m4a")
            try await exportAudio(asset: asset, range: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                                                   duration: CMTime(seconds: length, preferredTimescale: 600)),
                                  to: url)
            let chunk = try await recognize(url: url, recognizer: recognizer)
            words += chunk.map { CaptionTimeline.Word(text: $0.text, start: $0.start + start, end: $0.end + start) }
            start += length
            index += 1
        }
        return words
    }

    private static func authorize() async throws -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
            }
        @unknown default: return false
        }
    }

    private static func exportAudio(asset: AVAsset, range: CMTimeRange, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.exportFailed
        }
        session.outputURL = url
        session.outputFileType = .m4a
        session.timeRange = range
        await session.export()
        guard session.status == .completed else { throw session.error ?? TranscriptionError.exportFailed }
    }

    private static func recognize(url: URL, recognizer: SFSpeechRecognizer) async throws -> [CaptionTimeline.Word] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if #available(macOS 13.0, *) { request.addsPunctuation = true }
        let holder = RecognitionTaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CaptionTimeline.Word], Error>) in
                var finished = false
                holder.task = recognizer.recognitionTask(with: request) { result, error in
                    guard !finished else { return }
                    if let result, result.isFinal {
                        finished = true
                        let words = result.bestTranscription.segments.map {
                            CaptionTimeline.Word(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                        }
                        continuation.resume(returning: words)
                    } else if let error {
                        finished = true
                        // Silence produces "no speech detected": an empty chunk.
                        let code = (error as NSError).code
                        if code == 1110 || code == 203 { continuation.resume(returning: []) }
                        else { continuation.resume(throwing: error) }
                    }
                }
            }
        } onCancel: {
            holder.task?.cancel()
        }
    }

    nonisolated private final class RecognitionTaskHolder: @unchecked Sendable {
        var task: SFSpeechRecognitionTask?
    }
}
