import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

// Callback types
typealias RecordingProgressCallback = (_ seconds: Int) -> Void
typealias RecordingCompletionCallback = (_ url: URL?, _ error: Error?) -> Void

enum RecordingFormat: String {
    case mp4 = "mp4"
    case gif = "gif"
}

@MainActor
final class RecordingEngine: NSObject {

    // MARK: - State

    enum State { case idle, countdown, recording, paused, stopping }
    private(set) var state: State = .idle

    // MARK: - Config (read from UserDefaults at start)

    private var format: RecordingFormat = .mp4
    private var fps: Int = 30
    private var cropRect: CGRect = .zero      // in screen coordinates (top-left origin)
    private var screen: NSScreen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()

    // MARK: - SCStream

    private var stream: SCStream?
    private var streamOutput: RecordingStreamOutput?

    // MARK: - MP4 writer

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?       // system audio
    private var micAudioInput: AVAssetWriterInput?    // microphone audio
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?
    private var startTime: CMTime = .invalid
    private var sessionStarted: Bool = false
    private var frameCount: Int64 = 0

    // MARK: - Mic capture

    private var micCaptureSession: AVCaptureSession?
    private var micDataOutput: AVCaptureAudioDataOutput?
    private var micDelegate: MicCaptureDelegate?

    // MARK: - GIF

    private var gifEncoder: GIFEncoder?

    // MARK: - Callbacks

    var onProgress: RecordingProgressCallback?
    var onProcessing: (() -> Void)?
    var onCompletion: RecordingCompletionCallback?

    private var progressTimer: Timer?
    private var elapsedSeconds: Int = 0
    private var pauseStartTime: Date?
    private var totalPausedDuration: TimeInterval = 0
    var onPauseChanged: ((Bool) -> Void)?

    // MARK: - Cursor highlight


    // MARK: - Public API

    /// Start recording the given rect (in NSScreen/AppKit coordinates, bottom-left origin).
    /// Optional overrides take precedence over UserDefaults for this session.
    func startRecording(rect: NSRect, screen: NSScreen, formatOverride: String? = nil, fpsOverride: Int? = nil) {
        guard state == .idle else { return }
        state = .recording

        self.screen = screen
        // Convert AppKit rect (bottom-left origin) → screen coords (top-left origin)
        // SCStream uses top-left origin matching the display's coordinate system.
        let displayBounds = screen.frame
        let flippedY = displayBounds.maxY - rect.maxY
        // Scale to points — SCStream works in points on the display
        self.cropRect = CGRect(x: rect.minX - displayBounds.minX,
                               y: flippedY,
                               width: rect.width,
                               height: rect.height)

        let effectiveFormat = formatOverride ?? UserDefaults.standard.string(forKey: "recordingFormat") ?? "mp4"
        self.format = RecordingFormat(rawValue: effectiveFormat) ?? .mp4
        let defaultFPS = UserDefaults.standard.integer(forKey: "recordingFPS") > 0
            ? UserDefaults.standard.integer(forKey: "recordingFPS") : 30
        self.fps = fpsOverride ?? defaultFPS
        Task {
            // Resolve mic permission before starting capture so the prompt
            // doesn't block the UI while frames are already being recorded.
            if format == .mp4 && UserDefaults.standard.bool(forKey: "recordMicAudio") {
                let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                if micStatus == .notDetermined {
                    let granted = await AVCaptureDevice.requestAccess(for: .audio)
                    if !granted {
                        UserDefaults.standard.set(false, forKey: "recordMicAudio")
                    }
                } else if micStatus == .denied || micStatus == .restricted {
                    UserDefaults.standard.set(false, forKey: "recordMicAudio")
                }
            }
            await self.beginCapture(rect: rect)
        }
    }

    func pauseRecording() {
        guard state == .recording else { return }
        state = .paused
        pauseStartTime = Date()
        progressTimer?.invalidate()
        progressTimer = nil
        onPauseChanged?(true)
    }

    func resumeRecording() {
        guard state == .paused else { return }
        if let start = pauseStartTime {
            totalPausedDuration += Date().timeIntervalSince(start)
            pauseStartTime = nil
        }
        state = .recording
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.elapsedSeconds += 1
            self.onProgress?(self.elapsedSeconds)
        }
        onPauseChanged?(false)
    }

    func stopRecording() {
        guard state == .recording || state == .paused else { return }
        state = .stopping
        progressTimer?.invalidate()
        progressTimer = nil
        Task { await self.finalizeCapture() }
    }

    // MARK: - Setup

    private func beginCapture(rect: NSRect) async {
        do {
            // Find the SCDisplay matching our screen by display ID
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { d in
                screenID != nil && d.displayID == screenID!
            }) ?? content.displays.first else {
                await MainActor.run { self.fail(RecordingError.noDisplay) }
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(cropRect.width * screen.backingScaleFactor)
            config.height = Int(cropRect.height * screen.backingScaleFactor)
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.showsCursor = true   // we'll draw our own highlight on top if needed
            config.sourceRect = cropRect
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.scalesToFit = false

            // System audio capture (MP4 only, off by default, macOS 13+)
            if #available(macOS 13.0, *) {
                let recordAudio = UserDefaults.standard.bool(forKey: "recordSystemAudio") && format == .mp4
                config.capturesAudio = recordAudio
                config.excludesCurrentProcessAudio = true  // don't capture macshot's own sounds
            }

            let pixelW = config.width
            let pixelH = config.height

            // Prepare output file
            outputURL = makeOutputURL()
            guard let outURL = outputURL else {
                await MainActor.run { self.fail(RecordingError.noOutput) }
                return
            }

            if format == .mp4 {
                try setupAssetWriter(url: outURL, width: pixelW, height: pixelH)
            } else {
                gifEncoder = GIFEncoder(url: outURL, fps: min(fps, 15), sourceFPS: fps)
            }

            let output = RecordingStreamOutput()
            output.onFrame = { [weak self] pixelBuffer, presentationTime in
                self?.handleFrame(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
            }
            output.onAudioSample = { [weak self] sampleBuffer in
                self?.handleAudioSample(sampleBuffer)
            }
            output.onStopped = { [weak self] in
                self?.stopRecording()
            }
            self.streamOutput = output

            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "macshot.recording"))
            if #available(macOS 13.0, *) {
                let recordAudio = UserDefaults.standard.bool(forKey: "recordSystemAudio") && format == .mp4
                if recordAudio {
                    try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "macshot.recording.audio"))
                }
            }
            try await stream.startCapture()
            self.stream = stream

            // Start mic capture if enabled and authorized (permission resolved before capture started)
            if format == .mp4 && UserDefaults.standard.bool(forKey: "recordMicAudio") &&
               AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                await MainActor.run { self.startMicCapture() }
            }

            await MainActor.run {
                self.elapsedSeconds = 0
                self.progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.elapsedSeconds += 1
                    self.onProgress?(self.elapsedSeconds)
                }
            }

        } catch {
            await MainActor.run { self.fail(error) }
        }
    }

    private func finalizeCapture() async {
        if let stream = stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        streamOutput = nil
        await MainActor.run { self.stopMicCapture() }

        if format == .mp4 {
            await finalizeMP4()
        } else {
            await finalizeGIF()
        }
    }

    // MARK: - Frame handling

    /// Adjust a presentation timestamp by subtracting accumulated pause duration
    /// so the output file has no gaps from pauses.
    private func adjustedTime(_ time: CMTime) -> CMTime {
        guard totalPausedDuration > 0 else { return time }
        return CMTimeSubtract(time, CMTimeMakeWithSeconds(totalPausedDuration, preferredTimescale: time.timescale))
    }

    private func handleFrame(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard state == .recording else { return }
        if format == .mp4 {
            writeMP4Frame(buffer: pixelBuffer, presentationTime: adjustedTime(presentationTime))
        } else {
            gifEncoder?.addFrame(pixelBuffer)
        }
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard state == .recording, format == .mp4, sessionStarted, let audioInput = audioInput, audioInput.isReadyForMoreMediaData else { return }
        if let adjusted = sampleBuffer.adjustingTime(by: totalPausedDuration) {
            audioInput.append(adjusted)
        }
    }

    private func handleMicSample(_ sampleBuffer: CMSampleBuffer) {
        guard state == .recording, format == .mp4, sessionStarted, let micInput = micAudioInput, micInput.isReadyForMoreMediaData else { return }
        if let adjusted = sampleBuffer.adjustingTime(by: totalPausedDuration) {
            micInput.append(adjusted)
        }
    }

    // MARK: - Mic capture

    private func startMicCapture() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let micDevice: AVCaptureDevice
        if let uid = UserDefaults.standard.string(forKey: "selectedMicDeviceUID"),
           let device = AVCaptureDevice(uniqueID: uid) {
            micDevice = device
        } else {
            guard let device = AVCaptureDevice.default(for: .audio) else { return }
            micDevice = device
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        guard let deviceInput = try? AVCaptureDeviceInput(device: micDevice) else { return }
        guard session.canAddInput(deviceInput) else { return }
        session.addInput(deviceInput)

        let dataOutput = AVCaptureAudioDataOutput()
        let delegate = MicCaptureDelegate()
        delegate.onSample = { [weak self] sampleBuffer in
            self?.handleMicSample(sampleBuffer)
        }
        dataOutput.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "macshot.recording.mic"))
        guard session.canAddOutput(dataOutput) else { return }
        session.addOutput(dataOutput)

        session.commitConfiguration()
        session.startRunning()

        self.micCaptureSession = session
        self.micDataOutput = dataOutput
        self.micDelegate = delegate
    }

    private func stopMicCapture() {
        micCaptureSession?.stopRunning()
        micCaptureSession = nil
        micDataOutput = nil
        micDelegate = nil
    }

    // MARK: - MP4

    private func setupAssetWriter(url: URL, width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * fps / 8,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let sourceAttr: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: sourceAttr)

        writer.add(input)

        // System audio input
        if UserDefaults.standard.bool(forKey: "recordSystemAudio") {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            ]
            let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioIn.expectsMediaDataInRealTime = true
            writer.add(audioIn)
            self.audioInput = audioIn
        }

        // Mic audio input (separate track)
        if UserDefaults.standard.bool(forKey: "recordMicAudio") {
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            ]
            let micIn = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            micIn.expectsMediaDataInRealTime = true
            writer.add(micIn)
            self.micAudioInput = micIn
        }

        writer.startWriting()
        // Don't start session yet — start at first video frame's timestamp
        // so audio and video are aligned

        self.assetWriter = writer
        self.videoInput = input
        self.adaptor = adaptor
        self.startTime = .invalid
        self.sessionStarted = false
        self.frameCount = 0
    }

    private func writeMP4Frame(buffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let writer = assetWriter, let input = videoInput, let adaptor = adaptor else { return }
        guard input.isReadyForMoreMediaData else { return }

        if !sessionStarted {
            startTime = presentationTime
            writer.startSession(atSourceTime: presentationTime)
            sessionStarted = true
        }

        adaptor.append(buffer, withPresentationTime: presentationTime)
        frameCount += 1
    }

    private func finalizeMP4() async {
        guard let writer = assetWriter, let input = videoInput else {
            await MainActor.run { self.succeed() }
            return
        }
        input.markAsFinished()
        audioInput?.markAsFinished()
        micAudioInput?.markAsFinished()
        await writer.finishWriting()
        await MainActor.run { self.succeed() }
    }

    // MARK: - GIF

    private func finalizeGIF() async {
        await MainActor.run { self.onProcessing?() }
        let encoder = gifEncoder
        gifEncoder = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                encoder?.finish()
                continuation.resume()
            }
        }
        await MainActor.run { self.succeed() }
    }

    // MARK: - Output URL

    private func makeOutputURL() -> URL? {
        // Save to temp directory — always writable in sandbox.
        // The video editor handles final export to the user's chosen location.
        let dir = FileManager.default.temporaryDirectory
        let ext = format.rawValue
        let name = "Recording \(OverlayWindowController.formattedTimestamp()).\(ext)"
        return dir.appendingPathComponent(name)
    }

    // MARK: - Helpers

    @MainActor private func succeed() {
        state = .idle
        onCompletion?(outputURL, nil)
    }

    @MainActor private func fail(_ error: Error) {
        state = .idle
        onCompletion?(nil, error)
    }

    enum RecordingError: LocalizedError {
        case noDisplay, noOutput
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "Could not find the screen to record."
            case .noOutput: return "Could not create output file."
            }
        }
    }
}

// MARK: - SCStreamOutput

private class RecordingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudioSample: ((CMSampleBuffer) -> Void)?
    var onStopped: (() -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            onFrame?(pixelBuffer, pts)
        case .audio:
            onAudioSample?(sampleBuffer)
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onStopped?()
        }
    }
}

// MARK: - Mic AVCaptureAudioDataOutput delegate

private class MicCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onSample: ((CMSampleBuffer) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onSample?(sampleBuffer)
    }
}

// MARK: - CMSampleBuffer time adjustment

private extension CMSampleBuffer {
    /// Create a copy of this audio sample buffer with timestamps shifted back
    /// by the given pause duration, so the output has no time gaps.
    func adjustingTime(by pauseDuration: TimeInterval) -> CMSampleBuffer? {
        guard pauseDuration > 0 else { return self }
        let offset = CMTimeMakeWithSeconds(pauseDuration, preferredTimescale: 44100)
        let pts = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(self), offset)
        let dur = CMSampleBufferGetDuration(self)

        var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: self, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &adjusted)
        return adjusted
    }
}
