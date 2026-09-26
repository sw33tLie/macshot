import AVFoundation

/// A live camera that can hand its frames to a recorder.
protocol RecordingCameraSource: AnyObject {
    /// Starts delivering frames with host-clock times. Returns false when the
    /// camera is unavailable (then the take keeps the camera in its pixels).
    func startFrameTap(_ handler: @escaping @Sendable (CMSampleBuffer, Double) -> Void) -> Bool
    func stopFrameTap()
}

/// Records the webcam to its own file beside a take so the editor can
/// restyle, move, resize or hide the camera after recording. Where the live
/// bubble sat (including moves during the take) goes to a placement track.
///
/// The file's timeline is aligned to the screen recording: sample times are
/// host-clock seconds shifted so t = 0 is the screen's first frame, with
/// paused intervals removed exactly as the screen writer removes them.
/// A camera failure never affects the screen recording.
final class VideoCameraRecorder: @unchecked Sendable {
    nonisolated static let filename = "camera.mp4"
    nonisolated static let maxWidth = 1280

    private let queue = DispatchQueue(label: "macshot.camera-recorder", qos: .userInitiated)
    // Queue-confined state.
    nonisolated(unsafe) private var url: URL?
    nonisolated(unsafe) private var writer: AVAssetWriter?
    nonisolated(unsafe) private var input: AVAssetWriterInput?
    nonisolated(unsafe) private var anchor: Double?
    nonisolated(unsafe) private var pausedTotal = 0.0
    nonisolated(unsafe) private var paused = false
    nonisolated(unsafe) private var lastTime = CMTime.invalid
    nonisolated(unsafe) private var lastDuration = CMTime(value: 1, timescale: 30)
    nonisolated(unsafe) private var failed = false
    nonisolated(unsafe) private var finished = false
    nonisolated(unsafe) private(set) var frameCount = 0
    /// One frame the encoder was not ready for, retried with the next frame.
    nonisolated(unsafe) private var pending: (CMSampleBuffer, CMTime)?
    /// Bubble placement over the take, written beside the camera file.
    nonisolated(unsafe) private var placements: [CameraPlacementTrack.Sample] = []
    /// Latest placement before the first screen frame; becomes time zero.
    nonisolated(unsafe) private var initialPlacement: CameraPlacementTrack.Sample?
    /// Media time at which the current pause began.
    nonisolated(unsafe) private var pausedMediaTime: Double?

    /// Called once (on the recorder's queue) if the camera file fails, so
    /// the caller can put the camera back into the screen capture.
    nonisolated(unsafe) var onFailure: (() -> Void)?

    nonisolated init() {}

    nonisolated private func markFailed() {
        guard !failed else { return }
        failed = true
        onFailure?()
    }

    /// Sets where the camera file goes once the take's folder exists.
    nonisolated func open(directory: URL) {
        queue.async { self.url = directory.appendingPathComponent(Self.filename) }
    }

    /// Host time of the screen recording's first frame (media zero).
    nonisolated func markStart(hostTime: Double) {
        queue.async { if self.anchor == nil { self.anchor = hostTime } }
    }

    nonisolated func pause(hostTime: Double? = nil) {
        let host = hostTime ?? Self.hostNow()
        queue.async {
            self.paused = true
            self.pausedMediaTime = Self.mediaTime(host: host, anchor: self.anchor, pausedTotal: self.pausedTotal)
        }
    }

    nonisolated func resume(pausedDuration: Double) {
        queue.async {
            guard self.paused else { return }
            self.paused = false
            self.pausedMediaTime = nil
            if pausedDuration.isFinite, pausedDuration > 0 { self.pausedTotal += pausedDuration }
        }
    }

    nonisolated func append(_ sample: CMSampleBuffer, hostTime: Double) {
        // Capture buffers are immutable once delivered; only the recorder's
        // queue reads this one.
        nonisolated(unsafe) let sample = sample
        queue.async { self.appendOnQueue(sample, hostTime: hostTime) }
    }

    // MARK: Bubble placement

    /// Records where the live bubble is (`frame` inside the recorded
    /// `bounds`, AppKit screen coordinates) so the editor can replay moves
    /// and resizes made during the take. Moves while paused take effect at
    /// the point where the take resumes.
    nonisolated func recordPlacement(frame: CGRect, in bounds: CGRect, hostTime: Double? = nil) {
        let host = hostTime ?? Self.hostNow()
        queue.async {
            guard !self.finished,
                  let sample = CameraPlacementTrack.Sample.normalized(frame: frame, in: bounds, time: 0) else { return }
            let media = self.paused
                ? self.pausedMediaTime
                : Self.mediaTime(host: host, anchor: self.anchor, pausedTotal: self.pausedTotal)
            guard let media else {
                // Before the first screen frame: the latest one starts the take.
                if self.anchor == nil { self.initialPlacement = sample }
                return
            }
            if self.placements.isEmpty {
                var start = self.initialPlacement ?? sample
                start.time = 0
                self.placements.append(start)
            }
            var timed = sample
            timed.time = media
            // Mouse events arrive faster than any frame rate; within one
            // frame keep only the newest placement (at the frame's time, so
            // a continuous drag still yields one sample per frame).
            if let last = self.placements.last, self.placements.count > 1, media - last.time < 1.0 / 60 {
                timed.time = last.time
                self.placements[self.placements.count - 1] = timed
            } else if self.placements.count < CameraPlacementTrack.maxSamples {
                self.placements.append(timed)
            } else {
                self.placements[self.placements.count - 1] = timed
            }
        }
    }

    nonisolated private static func hostNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    /// Writes the placement track beside the camera file. Best effort: the
    /// editor falls back to its own placement without it.
    nonisolated private func writePlacements() {
        guard let url else { return }
        var samples = placements
        if samples.isEmpty, var initial = initialPlacement {
            initial.time = 0
            samples = [initial]
        }
        let track = CameraPlacementTrack(samples: samples)
        guard !track.isEmpty, let data = track.encoded() else { return }
        try? data.write(to: url.deletingLastPathComponent().appendingPathComponent(CameraPlacementTrack.filename),
                        options: .atomic)
    }

    /// Media time for a host time, or nil before the first screen frame.
    nonisolated static func mediaTime(host: Double, anchor: Double?, pausedTotal: Double) -> Double? {
        guard let anchor else { return nil }
        let t = host - anchor - pausedTotal
        return t >= 0 ? t : nil
    }

    nonisolated private func appendOnQueue(_ sample: CMSampleBuffer, hostTime: Double) {
        guard !failed, !finished, !paused, let url,
              let media = Self.mediaTime(host: hostTime, anchor: anchor, pausedTotal: pausedTotal) else { return }
        let time = CMTime(seconds: media, preferredTimescale: 60_000)
        guard !lastTime.isValid || CMTimeCompare(time, lastTime) > 0 else { return }
        if writer == nil {
            guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            guard dims.width > 0, dims.height > 0 else { return }
            let scale = min(1, Double(Self.maxWidth) / Double(dims.width))
            let width = max(2, Int(Double(dims.width) * scale) / 2 * 2)
            let height = max(2, Int(Double(dims.height) * scale) / 2 * 2)
            do {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
                writer.movieFragmentInterval = CMTime(value: 10, timescale: 1)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                    AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000,
                                                      AVVideoAllowFrameReorderingKey: false],
                ])
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { markFailed(); return }
                writer.add(input)
                guard writer.startWriting() else { markFailed(); return }
                writer.startSession(atSourceTime: .zero)
                self.writer = writer
                self.input = input
            } catch {
                markFailed()
                return
            }
        }
        guard let input, let retimed = SampleBufferTiming.retimed(sample, to: time) else { return }
        if let (held, heldTime) = pending, input.isReadyForMoreMediaData {
            pending = nil
            write(held, at: heldTime, to: input)
        }
        guard input.isReadyForMoreMediaData else {
            // Keep only the newest frame while the encoder catches up.
            pending = (retimed, time)
            return
        }
        write(retimed, at: time, to: input)
    }

    nonisolated private func write(_ sample: CMSampleBuffer, at time: CMTime, to input: AVAssetWriterInput) {
        guard !failed else { return }
        if input.append(sample) {
            lastTime = time
            let duration = CMSampleBufferGetDuration(sample)
            if duration.isNumeric, duration.value > 0, duration.seconds < 1 { lastDuration = duration }
            frameCount += 1
        } else {
            markFailed()
        }
    }

    /// Finishes the file. A take without camera frames leaves no file.
    nonisolated func finish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.finished = true
                if let (held, time) = self.pending, let input = self.input {
                    self.pending = nil
                    let deadline = Date().addingTimeInterval(0.5)
                    while !input.isReadyForMoreMediaData, Date() < deadline { usleep(2000) }
                    if input.isReadyForMoreMediaData { self.write(held, at: time, to: input) }
                }
                guard let writer = self.writer, writer.status == .writing, self.frameCount > 0 else {
                    self.writer?.cancelWriting()
                    if let url = self.url, self.frameCount == 0 { try? FileManager.default.removeItem(at: url) }
                    continuation.resume()
                    return
                }
                self.writePlacements()
                self.input?.markAsFinished()
                // The last frame keeps its duration rather than ending at zero length.
                if self.lastTime.isValid { writer.endSession(atSourceTime: CMTimeAdd(self.lastTime, self.lastDuration)) }
                writer.finishWriting { continuation.resume() }
            }
        }
    }
}
