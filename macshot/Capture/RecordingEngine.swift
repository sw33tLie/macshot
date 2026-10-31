import Foundation
import AppKit
import AVFoundation
import ScreenCaptureKit
import CoreGraphics

// Callback types
typealias RecordingProgressCallback = (_ seconds: Int) -> Void
typealias RecordingCompletionCallback = (_ url: URL?, _ error: Error?) -> Void

@MainActor
final class RecordingEngine: NSObject {

    // MARK: - State

    typealias State = RecordingLifecycle.State
    private var lifecycle = RecordingLifecycle()
    var state: State { lifecycle.state }

    /// Setup suspends for permission, enumeration, and device startup. Stop
    /// invalidates resource-free setup immediately; once resources are owned,
    /// it waits for setup to hand them to the single finalization path.
    private var setupTask: Task<Void, Never>?
    private var captureError: Error?
    private var recordingActivity: NSObjectProtocol?
    private var diskMonitor: DispatchSourceTimer?
    private var sleepObserver: NSObjectProtocol?

    // MARK: - SCStream

    private var stream: SCStream?
    private var streamStartAttempted = false
    private var streamOutput: RecordingStreamOutput?

    // MARK: - MP4 writer

    /// Serial queue for all recording I/O (video + audio). The writer session and
    /// the SCStream/mic sample handlers all run here, so writer state never races
    /// with the main actor.
    private let recordingQueue = DispatchQueue(label: "macshot.recording")
    /// All AVAssetWriter state lives in this queue-confined object. The main actor
    /// only holds a reference and forwards lifecycle calls.
    private var writerSession: MP4WriterSession?
    private var outputURL: URL?
    private var storedSession: RecordingSessionStore?

    // MARK: - Mic capture

    private var microphoneCapture: MicrophoneCapture?

    // MARK: - Pointer data

    /// Pointer, click and keystroke data recorded beside the take for the
    /// editor. Optional: a failure here never affects the video.
    private(set) var cursorTelemetry: CursorTelemetryRecorder?
    /// Invoked (main actor) once pointer recording is running, so callers
    /// can route keystrokes into it.
    var onTelemetryStarted: ((CursorTelemetryRecorder) -> Void)?
    /// Separate camera recording, already receiving frames (set by the caller
    /// before starting). Finished before the take completes.
    var cameraRecorder: VideoCameraRecorder?
    var onCameraFinished: (() -> Void)?

    // MARK: - Callbacks

    var onProgress: RecordingProgressCallback?
    var onCompletion: RecordingCompletionCallback?

    private var progressTimer: Timer?
    private var recordingClock = RecordingClock()
    var onPauseChanged: ((Bool) -> Void)?

    // MARK: - Cursor highlight


    // MARK: - Public API

    /// Converts a selection in AppKit screen coordinates (bottom-left origin,
    /// global across all displays) into the crop rect SCStream expects: display
    /// -local, top-left origin, in points.
    ///
    /// Both conversions matter on a multi-display setup, where `displayBounds`
    /// has a non-zero origin that can be negative (a display placed left of, or
    /// above, the primary one).
    nonisolated static func cropRect(for rect: NSRect, displayBounds: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - displayBounds.minX,
            y: displayBounds.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Start recording the given rect (in NSScreen/AppKit coordinates, bottom-left origin).
    /// Optional overrides take precedence over UserDefaults for this session.
    /// `appName` fills the filename template's `{app}` token.
    func startRecording(rect: NSRect, screen: NSScreen, fpsOverride: Int? = nil, excludeWindowNumbers: [CGWindowID] = [],
                        editablePointer: Bool = false, cameraWindowID: CGWindowID? = nil, appName: String? = nil) {
        guard state == .idle else { return }
        var configuration: RecordingConfiguration
        do {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                throw RecordingError.noDisplay
            }
            let defaults = UserDefaults.standard
            let savedFPS = defaults.integer(forKey: "recordingFPS")
            let template = defaults.string(forKey: FilenameFormatter.recordingUserDefaultsKey) ?? FilenameFormatter.defaultRecordingTemplate
            configuration = try RecordingConfiguration(displayID: displayID, rect: rect, displayBounds: screen.frame,
                backingScale: screen.backingScaleFactor, frameRate: fpsOverride ?? ((1...120).contains(savedFPS) ? savedFPS : 30),
                microphone: defaults.bool(forKey: "recordMicAudio"), systemAudio: defaults.bool(forKey: "recordSystemAudio"),
                microphoneDeviceID: defaults.string(forKey: "selectedMicDeviceUID"), excludedWindows: excludeWindowNumbers,
                filename: Self.takeFilename(template: template, appName: appName))
            configuration.pointerRegion = CursorTelemetryRecorder.globalRegion(forAppKitRect: rect)
            configuration.hidesCursor = editablePointer
            configuration.overlaysInTelemetry = editablePointer
            configuration.cameraWindowID = cameraWindowID
        } catch {
            guard lifecycle.begin() != nil else { return }
            stopRecording(error: error)
            return
        }
        startRecording(configuration: configuration)
    }

    /// The take's own name: the template's last path component, so a
    /// `{yyyy}/{MM}/…` template names the file like the saved copy does
    /// (folders are created only where the take is published).
    static func takeFilename(template: String, appName: String?, date: Date = Date()) -> String {
        let components = FilenameFormatter.formatRelativePath(
            template: template,
            noAppTemplate: UserDefaults.standard.string(forKey: FilenameFormatter.recordingNoAppUserDefaultsKey),
            appName: appName, date: date, fallback: FilenameFormatter.defaultRecordingTemplate)
        return components.last ?? FilenameFormatter.format(template: FilenameFormatter.defaultRecordingTemplate,
                                                           fallback: FilenameFormatter.defaultRecordingTemplate)
    }

    /// Shared entry point for the UI and internal recording test driver.
    func startRecording(configuration: RecordingConfiguration) {
        guard let sessionID = lifecycle.begin() else { return }
        captureError = nil
        recordingClock = RecordingClock()
        setupTask = Task { [weak self] in
            guard let self = self, self.lifecycle.isPreparing(sessionID) else { return }
            if #unavailable(macOS 13.0), configuration.systemAudio {
                self.stopRecording(error: RecordingError.systemAudioUnavailable)
                return
            }
            // Resolve mic permission before starting capture so the prompt
            // doesn't block the UI while frames are already being recorded.
            if configuration.microphone {
                let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                if micStatus == .notDetermined {
                    let granted = await AVCaptureDevice.requestAccess(for: .audio)
                    guard self.lifecycle.isPreparing(sessionID) else { return }
                    if !granted {
                        self.stopRecording(error: RecordingError.microphoneUnavailable)
                        return
                    }
                } else if micStatus == .denied || micStatus == .restricted {
                    self.stopRecording(error: RecordingError.microphoneUnavailable)
                    return
                }
            }
            guard self.lifecycle.isPreparing(sessionID) else { return }
            await self.beginCapture(configuration: configuration, sessionID: sessionID)
        }
    }

    func pauseRecording() {
        guard lifecycle.pause() else { return }
        recordingClock.pause(at: ProcessInfo.processInfo.systemUptime)
        updateProgress()
        writerSession?.pause()
        cursorTelemetry?.pause()
        cameraRecorder?.pause()
        progressTimer?.invalidate()
        progressTimer = nil
        onPauseChanged?(true)
    }

    func resumeRecording() {
        guard lifecycle.resume() else { return }
        let pausedFor = recordingClock.resume(at: ProcessInfo.processInfo.systemUptime)
        writerSession?.resume(addingPausedDuration: pausedFor)
        cursorTelemetry?.resume(pausedDuration: pausedFor)
        cameraRecorder?.resume(pausedDuration: pausedFor)
        startProgressTimer()
        onPauseChanged?(false)
    }

    func stopRecording() {
        stopRecording(error: nil)
    }

    private func stopRecording(error: Error?) {
        guard lifecycle.sessionID != nil else { return }
        captureError = captureError ?? error
        guard let sessionID = lifecycle.requestStop() else { return }
        // Stop accepting samples ASAP (more may arrive during SCStream teardown).
        writerSession?.requestStop()
        progressTimer?.invalidate()
        progressTimer = nil
        let startingTask = setupTask
        if stream == nil && writerSession == nil {
            // Permissions and display enumeration own no capture resources.
            // They may be uninterruptible; generation checks make their eventual
            // callbacks harmless without keeping the user's stop action waiting.
            startingTask?.cancel()
            Task { [weak self] in
                guard let self = self, self.lifecycle.isCurrent(sessionID) else { return }
                self.complete(sessionID: sessionID, url: nil, error: self.captureError ?? RecordingError.stoppedBeforeStart)
            }
            return
        }
        Task { [weak self] in
            // Setup may still be in flight. Let it observe `.stopping` and
            // unwind first — otherwise this tears down a session whose stream
            // and writer don't exist yet, and setup then brings them up with
            // nothing left to stop them.
            await startingTask?.value
            guard let self = self, self.lifecycle.isCurrent(sessionID) else { return }
            self.setupTask = nil
            await self.finalizeCapture(sessionID: sessionID)
        }
    }

    // MARK: - Setup

    private func updateProgress() {
        let elapsed = recordingClock.elapsed(at: ProcessInfo.processInfo.systemUptime)
        onProgress?(SafeNumerics.int(elapsed.rounded(.down)))
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateProgress() }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
        updateProgress()
    }

    private func beginCapture(configuration: RecordingConfiguration, sessionID: UUID) async {
        do {
            // Find the SCDisplay matching our screen by display ID
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard lifecycle.isPreparing(sessionID) else { return }
            guard let display = content.displays.first(where: { $0.displayID == configuration.displayID }) else {
                throw RecordingError.noDisplay
            }

            // Exclude specific macshot UI chrome windows (selection border, HUD)
            // but NOT recording overlays (webcam, mouse highlight, keystrokes)
            // which are intentionally part of the recording.
            let excludeIDs = configuration.excludedWindows
            let excludeWindows = excludeIDs.compactMap { wid in
                content.windows.first(where: { CGWindowID($0.windowID) == wid })
            }
            let filter = SCContentFilter(display: display, excludingWindows: excludeWindows)
            let config = SCStreamConfiguration()
            config.width = configuration.pixelWidth
            config.height = configuration.pixelHeight
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
            // Editable takes keep the pointer out of the pixels: the editor
            // redraws it sharply from recorded pointer data.
            config.showsCursor = !configuration.hidesCursor
            config.sourceRect = configuration.sourceRect
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.scalesToFit = true
            // Force sRGB at capture time. Without this ScreenCaptureKit delivers
            // frames in the display's native color space (often Display P3),
            // but AVAssetWriter tags the file as bt709 below — a mismatch that
            // makes AVPlayer render back the video with washed-out colors on
            // P3 displays.
            if #available(macOS 14.0, *) {
                config.colorSpaceName = CGColorSpace.sRGB
            }

            // System audio capture (off by default, macOS 13+)
            if #available(macOS 13.0, *) {
                config.capturesAudio = configuration.systemAudio
                config.excludesCurrentProcessAudio = true  // don't capture macshot's own sounds
            }

            let pixelW = config.width
            let pixelH = config.height

            let stored: RecordingSessionStore = try await withCheckedThrowingContinuation { continuation in
                recordingQueue.async {
                    continuation.resume(with: Result { try RecordingSessionStore(filename: configuration.filename) })
                }
            }
            guard lifecycle.isPreparing(sessionID) else {
                recordingQueue.async { stored.removeIfEmpty() }
                return
            }
            storedSession = stored
            let outURL = stored.mediaURL
            outputURL = outURL
            recordingActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Screen recording")
            startDiskMonitor(directory: stored.directoryURL, sessionID: sessionID)
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self = self, self.lifecycle.isCurrent(sessionID) else { return }
                        self.stopRecording(error: RecordingError.systemSleep)
                    }
                }

            if let region = configuration.pointerRegion {
                let header = CursorTelemetry.Header(sourcePointSize: region.size,
                    pixelSize: CGSize(width: pixelW, height: pixelH), frameRate: configuration.frameRate,
                    cursorHiddenInVideo: configuration.hidesCursor, overlaysInTelemetry: configuration.overlaysInTelemetry)
                cursorTelemetry = try? CursorTelemetryRecorder(
                    url: stored.directoryURL.appendingPathComponent(CursorTelemetry.filename), region: region, header: header)
            }
            let telemetry = cursorTelemetry
            let camera = cameraRecorder
            camera?.open(directory: stored.directoryURL)
            if let camera, let cameraWindow = configuration.cameraWindowID {
                // If the separate camera file fails, capture the webcam in the
                // screen video again so the take never loses it.
                let fallbackWindows = excludeWindows.filter { CGWindowID($0.windowID) != cameraWindow }
                camera.onFailure = { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, self.lifecycle.isCurrent(sessionID), let stream = self.stream else { return }
                        let filter = SCContentFilter(display: display, excludingWindows: fallbackWindows)
                        stream.updateContentFilter(filter) { _ in }
                    }
                }
            }
            let writer = try MP4WriterSession.make(
                queue: recordingQueue, url: outURL, width: pixelW, height: pixelH, fps: configuration.frameRate,
                recordSystemAudio: configuration.systemAudio, recordMicAudio: configuration.microphone,
                onFailure: { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self = self, self.lifecycle.isCurrent(sessionID) else { return }
                        self.stopRecording(error: error)
                    }
                },
                onSessionStart: { time in
                    telemetry?.markStart(hostTime: time.seconds)
                    camera?.markStart(hostTime: time.seconds)
                })
            self.writerSession = writer

            // Sample handlers run ON recordingQueue and call the queue-confined
            // writer session directly — no @MainActor hop, no race.
            let output = RecordingStreamOutput()
            output.onFrame = { pixelBuffer, presentationTime in
                writer.handleFrame(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
            }
            output.onAudioSample = { sampleBuffer in
                writer.handleSystemAudioSample(sampleBuffer)
            }
            output.onStopped = { [weak self] error in
                guard let self = self, self.lifecycle.isCurrent(sessionID) else { return }
                self.stopRecording(error: error)
            }
            self.streamOutput = output

            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            // Take ownership before the stream can go live. Everything below can
            // throw, and the task can be cancelled — both `finalizeCapture()` and
            // the `catch` need a handle to call `stopCapture()` on. Assigning only
            // after `startCapture()` leaves a window where the local `stream`
            // deallocates while the daemon is already capturing. replayd then
            // pushes frames into a dead queue for the lifetime of the login
            // session (err=-16665 "Client terminated the queue"), once per frame
            // interval, with no way to stop it short of killing replayd.
            self.stream = stream
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: recordingQueue)
            if #available(macOS 13.0, *) {
                if configuration.systemAudio {
                    try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: recordingQueue)
                }
            }
            // Bring up the microphone before screen capture so its startup
            // latency cannot cut the beginning off the recorded audio. Pre-roll
            // is bounded and clipped to the first complete video frame.
            if configuration.microphone {
                microphoneCapture = try await MicrophoneCapture.start(
                    deviceID: configuration.microphoneDeviceID, sampleQueue: recordingQueue,
                    onSample: { sample in writer.handleMicSample(sample) },
                    onFailure: { [weak self] error in
                        DispatchQueue.main.async {
                            guard let self = self, self.lifecycle.isCurrent(sessionID) else { return }
                            self.stopRecording(error: error)
                        }
                    })
            }

            guard lifecycle.isPreparing(sessionID) else { return }
            streamStartAttempted = true
            try await stream.startCapture()

            // The stop task owns teardown, including samples already written
            // during startup. Do not discard them or complete from setup too.
            guard lifecycle.didStart(sessionID) else { return }
            writer.captureDidStart()
            recordingClock.start(at: ProcessInfo.processInfo.systemUptime)
            if let telemetry = cursorTelemetry {
                telemetry.start()
                onTelemetryStarted?(telemetry)
            }

            startProgressTimer()

        } catch {
            guard lifecycle.isCurrent(sessionID) else { return }
            // One owner drains setup, stops capture, and completes the writer.
            // This task returns before the stop task awaits its completion.
            stopRecording(error: error)
        }
    }

    private func finalizeCapture(sessionID: UUID) async {
        if let stream = stream {
            if streamStartAttempted {
                do { try await stream.stopCapture() }
                catch { captureError = captureError ?? error }
            }
            self.stream = nil
        }
        streamStartAttempted = false
        streamOutput = nil
        cursorTelemetry?.stop()
        cursorTelemetry = nil
        if let camera = cameraRecorder {
            onCameraFinished?()
            await camera.finish()
            cameraRecorder = nil
        }
        await microphoneCapture?.stop()
        microphoneCapture = nil

        guard let writer = writerSession else {
            // Nothing was ever written — the session was stopped before the
            // stream came up. Reporting success with a nil URL made the UI
            // tear down silently, as if the recording had never happened.
            complete(sessionID: sessionID, url: nil, error: captureError ?? RecordingError.stoppedBeforeStart)
            return
        }
        do {
            try await writer.finish()
            writerSession = nil
            complete(sessionID: sessionID, url: outputURL, error: captureError)
        } catch {
            writerSession = nil
            // Preserve partial media for the session-recovery path. Never
            // delete the user's only recording merely because finish failed.
            complete(sessionID: sessionID, url: nil, error: captureError ?? error)
        }
    }

    // MARK: - Helpers

    private func startDiskMonitor(directory: URL, sessionID: UUID) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "macshot.recording.disk"))
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
                  let available = values.volumeAvailableCapacity, available < 256 * 1024 * 1024 else { return }
            DispatchQueue.main.async {
                guard let self = self, self.lifecycle.isCurrent(sessionID) else { return }
                self.stopRecording(error: CocoaError(.fileWriteOutOfSpace))
            }
        }
        diskMonitor = timer
        timer.resume()
    }

    private func complete(sessionID: UUID, url: URL?, error: Error?) {
        guard lifecycle.finish(sessionID) else { return }
        cursorTelemetry?.stop()
        cursorTelemetry = nil
        if let camera = cameraRecorder {
            // Setup failed before finalization: release the camera file.
            onCameraFinished?()
            cameraRecorder = nil
            Task { await camera.finish() }
        }
        diskMonitor?.cancel()
        diskMonitor = nil
        if let observer = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sleepObserver = nil
        if let activity = recordingActivity { ProcessInfo.processInfo.endActivity(activity) }
        recordingActivity = nil
        progressTimer?.invalidate()
        progressTimer = nil
        setupTask = nil
        recordingClock = RecordingClock()
        outputURL = nil
        captureError = nil
        let stored = storedSession
        storedSession = nil
        if let stored = stored {
            recordingQueue.async {
                try? stored.update(status: error == nil ? "complete" : "interrupted", error: error)
                stored.removeIfEmpty()
            }
        }
        if let error = error, let stored = stored {
            onCompletion?(url, NSError(domain: "macshot.recording", code: 1, userInfo: [
                NSLocalizedDescriptionKey: error.localizedDescription + " Original recording data is kept in Show Recordings in Finder.",
                NSUnderlyingErrorKey: error,
                NSURLErrorKey: stored.mediaURL,
            ]))
        } else {
            onCompletion?(url, error)
        }
    }

    enum RecordingError: LocalizedError {
        case noDisplay, stoppedBeforeStart, microphoneUnavailable, systemAudioUnavailable, systemSleep
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "Could not find the screen to record."
            case .stoppedBeforeStart: return "Recording stopped before it started. Nothing was captured."
            case .microphoneUnavailable: return "The selected microphone could not be started. Check its connection and Microphone permission."
            case .systemAudioUnavailable: return "System audio recording requires macOS 13 or later."
            case .systemSleep: return "Recording stopped because the Mac is going to sleep."
            }
        }
    }
}

// MARK: - SCStreamOutput

private class RecordingStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudioSample: ((CMSampleBuffer) -> Void)?
    var onStopped: ((Error) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Only screen and system-audio outputs are registered on this stream.
        // Microphone samples are delivered by the separate AVCaptureSession.
        if type == .screen {
            guard RecordingSampleValidation.isCompleteFrame(sampleBuffer),
                  let pixelBuffer = sampleBuffer.imageBuffer else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            onFrame?(pixelBuffer, pts)
        } else if #available(macOS 13.0, *), type == .audio {
            onAudioSample?(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onStopped?(error)
        }
    }
}
