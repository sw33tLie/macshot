import AVFoundation

/// AVCaptureSession start/stop are blocking operations. A dedicated queue owns
/// their lifecycle, independently of the main actor and the media writer queue.
final class MicrophoneCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macshot.microphone")
    private let session = AVCaptureSession()
    private var delegate: MicrophoneSampleDelegate?
    private var output: AVCaptureAudioDataOutput?
    private var observers: [NSObjectProtocol] = []
    private var stopping = false
    private var reportedFailure = false
    private let onFailure: (Error) -> Void

    enum CaptureError: LocalizedError {
        case unavailable, interrupted, clockUnavailable
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The selected microphone could not be started. Check its connection and Microphone permission."
            case .interrupted: return "Microphone capture was interrupted or the selected device disconnected."
            case .clockUnavailable: return "The microphone's timing information is unavailable."
            }
        }
    }

    private init(onFailure: @escaping (Error) -> Void) { self.onFailure = onFailure }

    static func start(deviceID: String?, sampleQueue: DispatchQueue,
                      onSample: @escaping (CMSampleBuffer) -> Void,
                      onFailure: @escaping (Error) -> Void) async throws -> MicrophoneCapture {
        let capture = MicrophoneCapture(onFailure: onFailure)
        return try await withCheckedThrowingContinuation { continuation in
            capture.queue.async {
                do {
                    try capture.configure(deviceID: deviceID, sampleQueue: sampleQueue, onSample: onSample)
                    capture.session.startRunning()
                    guard capture.session.isRunning else { throw CaptureError.unavailable }
                    continuation.resume(returning: capture)
                } catch {
                    capture.stopOnQueue()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func configure(deviceID: String?, sampleQueue: DispatchQueue,
                           onSample: @escaping (CMSampleBuffer) -> Void) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw CaptureError.unavailable }
        // A missing saved device must not silently select a different mic.
        let device = MicrophoneDeviceSelection.captureDevice(savedID: deviceID)
        guard let device = device else { throw CaptureError.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw CaptureError.unavailable }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        let session = self.session
        let delegate = MicrophoneSampleDelegate { [weak self, weak session] sample in
            guard let clock = session?.synchronizationClock else {
                self?.reportFailure(CaptureError.clockUnavailable); return
            }
            // Capture timestamps belong to the session clock, which need not
            // be the host clock used by ScreenCaptureKit. Convert each buffer
            // instead of assuming two independently-running clocks agree.
            let hostTime = CMSyncConvertTime(sample.presentationTimeStamp,
                                             from: clock, to: CMClockGetHostTimeClock())
            guard let aligned = SampleBufferTiming.retimed(sample, to: hostTime) else {
                self?.reportFailure(CaptureError.clockUnavailable); return
            }
            onSample(aligned)
        }
        output.setSampleBufferDelegate(delegate, queue: sampleQueue)
        guard session.canAddOutput(output) else { throw CaptureError.unavailable }
        session.addOutput(output)
        self.delegate = delegate
        self.output = output

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil) { [weak self] notification in
                self?.reportFailure(notification.userInfo?[AVCaptureSessionErrorKey] as? Error ?? CaptureError.interrupted)
            })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device, queue: nil) { [weak self] _ in self?.reportFailure(CaptureError.interrupted) })
        observers.append(center.addObserver(forName: AVCaptureSession.didStopRunningNotification,
            object: session, queue: nil) { [weak self] _ in self?.reportFailure(CaptureError.interrupted) })
    }

    private func reportFailure(_ error: Error) {
        queue.async { [weak self] in
            guard let self = self, !self.stopping, !self.reportedFailure else { return }
            self.reportedFailure = true
            self.onFailure(error)
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopOnQueue()
                continuation.resume()
            }
        }
    }

    private func stopOnQueue() {
        stopping = true
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        output?.setSampleBufferDelegate(nil, queue: nil)
        session.stopRunning()
        output = nil
        delegate = nil
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }
}

private final class MicrophoneSampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let onSample: (CMSampleBuffer) -> Void
    init(onSample: @escaping (CMSampleBuffer) -> Void) { self.onSample = onSample }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onSample(sampleBuffer)
    }
}
