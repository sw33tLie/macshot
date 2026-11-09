import AVFoundation

/// Pulls a bounded number of samples at a time. One serial queue owns every
/// reader/writer operation and delivers one result for success, failure, or
/// cancellation. The prepared inputs/outputs must not be used elsewhere.
final class MediaExportPump: @unchecked Sendable {
    struct Track: @unchecked Sendable {
        nonisolated(unsafe) let output: AVAssetReaderOutput
        nonisolated(unsafe) let input: AVAssetWriterInput
        let requiresSamples: Bool
    }

    private let queue = DispatchQueue(label: "macshot.media-export", qos: .userInitiated)
    nonisolated(unsafe) private let reader: AVAssetReader
    nonisolated(unsafe) private let writer: AVAssetWriter
    private let tracks: [Track]
    private let timeRange: CMTimeRange
    private let progress: @Sendable (Double) -> Void
    nonisolated(unsafe) private var completedTracks: Set<Int> = []
    nonisolated(unsafe) private var scheduledDrains: Set<Int> = []
    nonisolated(unsafe) private var sampleCounts: [Int]
    nonisolated(unsafe) private var result: Result<Void, Error>?
    nonisolated(unsafe) private var waiters: [CheckedContinuation<Void, Error>] = []
    nonisolated(unsafe) private var started = false
    nonisolated(unsafe) private var finishing = false
    nonisolated(unsafe) private var watchdog: DispatchSourceTimer?
    nonisolated(unsafe) private var lastActivity = ProcessInfo.processInfo.systemUptime
    nonisolated(unsafe) private var lastProgress = -Double.infinity

    enum ExportError: LocalizedError {
        case invalidSetup, emptyTrack, readerFailed, writerFailed, timedOut
        var errorDescription: String? {
            switch self {
            case .invalidSetup: return "The media export could not be configured."
            case .emptyTrack: return "The media export did not receive the required media samples."
            case .readerFailed: return "The source recording could not be read."
            case .writerFailed: return "The exported recording could not be written."
            case .timedOut: return "The media export stopped making progress. The original recording is unchanged."
            }
        }
    }

    nonisolated init(reader: AVAssetReader, writer: AVAssetWriter, tracks: [Track],
         timeRange: CMTimeRange, progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.reader = reader
        self.writer = writer
        self.tracks = tracks
        self.timeRange = timeRange
        self.progress = progress
        self.sampleCounts = Array(repeating: 0, count: tracks.count)
    }

    nonisolated func run() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.result { continuation.resume(with: result); return }
                self.waiters.append(continuation)
                guard !self.started else { return }
                self.started = true
                self.startOnQueue()
            }
        }
    }

    nonisolated func cancel() {
        queue.async { self.complete(.failure(CancellationError())) }
    }

    nonisolated private func startOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !tracks.isEmpty, reader.status == .unknown, writer.status == .unknown,
              timeRange.start.isNumeric, timeRange.duration.isNumeric,
              CMTimeCompare(timeRange.duration, .zero) > 0,
              tracks.allSatisfy({ track in
                  reader.outputs.contains { $0 === track.output } && writer.inputs.contains { $0 === track.input }
              }) else { complete(.failure(ExportError.invalidSetup)); return }
        guard writer.startWriting() else { complete(.failure(writer.error ?? ExportError.writerFailed)); return }
        guard reader.startReading() else { complete(.failure(reader.error ?? ExportError.readerFailed)); return }
        writer.startSession(atSourceTime: timeRange.start)
        lastActivity = ProcessInfo.processInfo.systemUptime
        progress(0)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.result == nil else { return }
            if self.reader.status == .failed {
                self.complete(.failure(self.reader.error ?? ExportError.readerFailed))
            } else if self.writer.status == .failed {
                self.complete(.failure(self.writer.error ?? ExportError.writerFailed))
            } else if ProcessInfo.processInfo.systemUptime - self.lastActivity > 60 {
                self.complete(.failure(ExportError.timedOut))
            }
        }
        watchdog = timer
        timer.resume()
        for index in tracks.indices {
            tracks[index].input.requestMediaDataWhenReady(on: queue) { [weak self] in self?.drain(index) }
        }
    }

    nonisolated private func drain(_ index: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard result == nil, !completedTracks.contains(index) else { return }
        let track = tracks[index]
        // Yield regularly so cancellation and the other track cannot starve
        // behind a long, cheap compressed-video passthrough loop.
        var batch = 0
        while track.input.isReadyForMoreMediaData, result == nil, batch < 32 {
            batch += 1
            let hasSample: Bool = autoreleasepool {
                guard let sample = track.output.copyNextSampleBuffer() else { return false }
                guard track.input.append(sample) else {
                    complete(.failure(writer.error ?? ExportError.writerFailed)); return true
                }
                if sample.numSamples > 0 { sampleCounts[index] += 1 }
                let now = ProcessInfo.processInfo.systemUptime
                lastActivity = now
                if track.input.mediaType == .video, now - lastProgress >= 0.2 {
                    let elapsed = CMTimeSubtract(sample.presentationTimeStamp, timeRange.start).seconds
                    if elapsed.isFinite { progress(min(0.99, max(0, elapsed / timeRange.duration.seconds))) }
                    lastProgress = now
                }
                return true
            }
            if !hasSample {
                guard result == nil else { return }
                if reader.status == .failed || reader.status == .cancelled {
                    complete(.failure(reader.error ?? ExportError.readerFailed)); return
                }
                if track.requiresSamples && sampleCounts[index] == 0 {
                    complete(.failure(ExportError.emptyTrack)); return
                }
                completedTracks.insert(index)
                track.input.markAsFinished()
                finishIfReady()
                return
            }
        }
        if batch == 32, result == nil, track.input.isReadyForMoreMediaData,
           scheduledDrains.insert(index).inserted {
            queue.async { [weak self] in
                self?.scheduledDrains.remove(index)
                self?.drain(index)
            }
        }
    }

    nonisolated private func finishIfReady() {
        guard completedTracks.count == tracks.count, !finishing, result == nil else { return }
        finishing = true
        lastActivity = ProcessInfo.processInfo.systemUptime
        writer.endSession(atSourceTime: CMTimeRangeGetEnd(timeRange))
        writer.finishWriting { [weak self] in
            guard let self = self else { return }
            self.queue.async {
                if self.writer.status == .completed {
                    self.progress(1)
                    self.complete(.success(()))
                } else {
                    self.complete(.failure(self.writer.error ?? ExportError.writerFailed))
                }
            }
        }
    }

    nonisolated private func complete(_ result: Result<Void, Error>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard self.result == nil else { return }
        self.result = result
        watchdog?.cancel()
        watchdog = nil
        if case .failure = result {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        let callbacks = waiters
        waiters.removeAll()
        for callback in callbacks { callback.resume(with: result) }
    }
}
