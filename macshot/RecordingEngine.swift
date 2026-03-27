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

    enum State { case idle, countdown, recording, stopping }
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
    var onCompletion: RecordingCompletionCallback?

    private var progressTimer: Timer?
    private var elapsedSeconds: Int = 0

    // MARK: - Cursor highlight


    // MARK: - Public API

    /// Start recording the given rect (in NSScreen/AppKit coordinates, bottom-left origin).
    func startRecording(rect: NSRect, screen: NSScreen) {
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

        self.format = RecordingFormat(rawValue: UserDefaults.standard.string(forKey: "recordingFormat") ?? "mp4") ?? .mp4
        self.fps = UserDefaults.standard.integer(forKey: "recordingFPS") > 0
            ? UserDefaults.standard.integer(forKey: "recordingFPS") : 30
        Task { await self.beginCapture(rect: rect) }
    }

    func stopRecording() {
        guard state == .recording else { return }
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
                gifEncoder = GIFEncoder(url: outURL, fps: min(fps, 15))
            }

            let output = RecordingStreamOutput()
            output.onFrame = { [weak self] pixelBuffer, presentationTime in
                self?.handleFrame(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
            }
            output.onAudioSample = { [weak self] sampleBuffer in
                self?.handleAudioSample(sampleBuffer)
            }
            self.streamOutput = output

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "macshot.recording"))
            if #available(macOS 13.0, *) {
                let recordAudio = UserDefaults.standard.bool(forKey: "recordSystemAudio") && format == .mp4
                if recordAudio {
                    try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "macshot.recording.audio"))
                }
            }
            try await stream.startCapture()
            self.stream = stream

            // Start mic capture if enabled (MP4 only, requires permission)
            if format == .mp4 && UserDefaults.standard.bool(forKey: "recordMicAudio") {
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

    private func handleFrame(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        if format == .mp4 {
            writeMP4Frame(buffer: pixelBuffer, presentationTime: presentationTime)
        } else {
            gifEncoder?.addFrame(pixelBuffer)
        }
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard format == .mp4, sessionStarted, let audioInput = audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    private func handleMicSample(_ sampleBuffer: CMSampleBuffer) {
        guard format == .mp4, sessionStarted, let micInput = micAudioInput, micInput.isReadyForMoreMediaData else { return }
        micInput.append(sampleBuffer)
    }

    // MARK: - Mic capture

    private func startMicCapture() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        guard let micDevice = AVCaptureDevice.default(for: .audio) else { return }

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
                AVEncoderBitRateKey: 128000,
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
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96000,
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
        gifEncoder?.finish()
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

private class RecordingStreamOutput: NSObject, SCStreamOutput {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudioSample: ((CMSampleBuffer) -> Void)?

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
}

// MARK: - Mic AVCaptureAudioDataOutput delegate

private class MicCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onSample: ((CMSampleBuffer) -> Void)?

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onSample?(sampleBuffer)
    }
}
