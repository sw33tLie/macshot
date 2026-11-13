import Foundation
@preconcurrency import Vision

/// Sends text recognition to the macshotOCR XPC service and keeps the app
/// responsive when it gets stuck.
///
/// On macOS 27 an accurate Vision request can block forever, ignore cancel(),
/// and make every later request in the same process queue behind it
/// (FB25403069). A timeout alone only hides that: the app stays poisoned until
/// it is relaunched. So accurate recognition runs in a separate process:
///
/// - Each request gets `softTimeout` to answer. If it doesn't, the caller gets
///   an in-process fast-model result, and further requests go straight to the
///   fast model while the service is busy.
/// - The service keeps working for up to `hardDeadline`, so a first-use model
///   compile (44-66 s observed) can still finish, then ends itself if stuck.
///   launchd starts a fresh process for the next request.
/// - An error, or no text where the fast model finds some, means the service
///   can't be trusted any more: the connection is dropped, the service exits,
///   and the next request starts a new one.
/// - Without the embedded service (unit tests) or if it can't launch, the
///   original in-process path runs instead.
nonisolated final class OCRServiceClient: @unchecked Sendable {

    enum Route: String, Sendable {
        /// The service answered.
        case service
        /// The service didn't answer in time; the fast model did.
        case fastAfterTimeout
        /// An earlier request is still stuck in the service.
        case fastWhileServiceBusy
        /// The service returned an error or its process went away.
        case fastAfterServiceFailure
        /// The service found nothing but the fast model found text.
        case fastAfterEmptyResult
        /// A replaced service can't relaunch yet (launchd's respawn throttle).
        case fastWhileServiceRestarts
        /// No usable service: the original in-process accurate/fast session.
        case inProcess
        /// No usable service on macOS 27 or later, where an accurate request
        /// in this process can hang and take every later request with it:
        /// the fast model only.
        case fastWithoutService
    }

    struct Timing: Sendable {
        var softTimeout: TimeInterval = 10
        var hardDeadline: TimeInterval = 120
        var fastTimeout: TimeInterval = 10
        /// launchd won't relaunch a job until this long after its last launch.
        var relaunchThrottle: TimeInterval = 10
    }

    static let shared = OCRServiceClient(serviceName: embeddedServiceName())

    /// The service's bundle identifier, read from the app bundle so it follows
    /// whatever bundle ID the build variant gives it.
    static func embeddedServiceName(in bundle: Bundle = .main) -> String? {
        let url = bundle.bundleURL.appendingPathComponent("Contents/XPCServices/macshotOCR.xpc")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    let serviceName: String?

    private let queue = DispatchQueue(label: "com.sw33tlie.macshot.ocr-client", qos: .userInitiated)
    /// Fast fallback reads, one at a time, on a plain GCD thread.
    private let fastQueue = DispatchQueue(label: "com.sw33tlie.macshot.ocr-fast", qos: .userInitiated)

    // All state below is confined to `queue`.
    nonisolated(unsafe) private var timing = Timing()
    nonisolated(unsafe) private var connection: NSXPCConnection?
    nonisolated(unsafe) private var pending: [UInt64: Pending] = [:]
    nonisolated(unsafe) private var nextAttempt: UInt64 = 0
    /// A request outlived its soft timeout and the service hasn't answered since.
    nonisolated(unsafe) private var serviceBusy = false
    /// When the current service process was (approximately) launched: the
    /// first message after a new connection or after the process ended.
    nonisolated(unsafe) private var serviceLaunchedAt: Date?
    /// After a replacement, requests sent before this would wait for launchd.
    nonisolated(unsafe) private var relaunchAllowedAt: Date?
    /// Failures that came back before the soft timeout, with no answer since.
    /// Three in a row means the service can't run here; use the in-process path.
    nonisolated(unsafe) private var consecutiveQuickFailures = 0
    nonisolated(unsafe) private var disabled = false
    /// Bumped whenever this client drops its own connection. A request sent
    /// on an older connection fails because of that, not because the service
    /// can't run, so its failure must not count towards `disabled`.
    nonisolated(unsafe) private var connectionGeneration: UInt64 = 0
    /// Set when this client replaced the service. The first failure after
    /// that can be a request that reached the old process as it exited.
    nonisolated(unsafe) private var replacedSinceLastAnswer = false
    #if OCR_FAULT_INJECTION
    nonisolated(unsafe) private var nextDebugBehavior: String?
    #endif

    private struct Pending {
        let image: CGImage
        let languages: [String]
        let finish: Finish
    }

    /// Calls the caller's completion once, off the client queue.
    private final class Finish: @unchecked Sendable {
        private var completion: (([OCRTextObservation], Error?, Route) -> Void)?
        private let lock = NSLock()
        init(_ completion: @escaping ([OCRTextObservation], Error?, Route) -> Void) { self.completion = completion }
        func callAsFunction(_ lines: [OCRTextObservation], _ error: Error?, _ route: Route) {
            lock.lock()
            let callback = completion
            completion = nil
            lock.unlock()
            guard let callback else { return }
            DispatchQueue.global(qos: .userInitiated).async { callback(lines, error, route) }
        }
    }

    init(serviceName: String?) {
        self.serviceName = serviceName
    }

    func setTiming(_ timing: Timing) {
        queue.sync { self.timing = timing }
    }

    #if OCR_FAULT_INJECTION
    /// Probe hook: the next service request hangs, returns nothing, or fails.
    func injectNextServiceBehavior(_ behavior: String) {
        queue.sync { nextDebugBehavior = behavior }
    }
    #endif

    /// The current service process, for diagnostics and the probe.
    func serviceProcessIdentifier(_ completion: @escaping (Int32?) -> Void) {
        queue.async { [self] in
            guard let proxy = proxy(errorHandler: { _ in completion(nil) }) else { completion(nil); return }
            proxy.processIdentifier { completion($0) }
        }
    }

    func recognize(cgImage: CGImage,
                   preferredLanguages: [String] = VisionOCR.userLanguages(),
                   includeCharacterBoxes: Bool = false,
                   completion: @escaping ([OCRTextObservation], Error?, Route) -> Void) {
        let finish = Finish(completion)
        guard serviceName != nil else {
            runInProcess(cgImage, finish: finish)
            return
        }
        // Packing a large capture takes a moment; keep it off the client queue.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let packed = OCRServicePixels.pack(cgImage)
            queue.async { [self] in
                start(image: cgImage, packed: packed, languages: preferredLanguages,
                      includeCharacterBoxes: includeCharacterBoxes, finish: finish)
            }
        }
    }

    // MARK: - Request lifecycle (on `queue`)

    private func start(image: CGImage, packed: (data: Data, width: Int, height: Int, bytesPerRow: Int)?,
                       languages: [String], includeCharacterBoxes: Bool, finish: Finish) {
        if disabled || packed == nil {
            runWithoutService(image, languages: languages, finish: finish)
            return
        }
        if serviceBusy {
            runFast(image, languages: languages) { finish($0, $1, .fastWhileServiceBusy) }
            return
        }
        if let allowed = relaunchAllowedAt {
            if Date() < allowed {
                runFast(image, languages: languages) { finish($0, $1, .fastWhileServiceRestarts) }
                return
            }
            relaunchAllowedAt = nil
        }

        nextAttempt &+= 1
        let attempt = nextAttempt
        var debugBehavior: String?
        #if OCR_FAULT_INJECTION
        debugBehavior = nextDebugBehavior
        nextDebugBehavior = nil
        #endif
        let request = OCRServiceRequest(width: packed!.width, height: packed!.height, bytesPerRow: packed!.bytesPerRow,
                                        accurate: true, preferredLanguages: languages,
                                        includeCharacterBoxes: includeCharacterBoxes,
                                        hardDeadline: timing.hardDeadline, debugBehavior: debugBehavior)
        let generation = connectionGeneration
        guard let requestData = try? JSONEncoder().encode(request),
              let proxy = proxy(errorHandler: { [weak self] error in
                  self?.queue.async { self?.serviceFailed(error, attempt: attempt, generation: generation) }
              }) else {
            runWithoutService(image, languages: languages, finish: finish)
            return
        }

        pending[attempt] = Pending(image: image, languages: languages, finish: finish)
        if serviceLaunchedAt == nil { serviceLaunchedAt = Date() }
        queue.asyncAfter(deadline: .now() + timing.softTimeout) { [weak self] in
            self?.softTimeoutExpired(attempt: attempt)
        }
        proxy.recognize(requestData, pixels: packed!.data) { [weak self] data, message in
            self?.queue.async { self?.serviceReplied(attempt: attempt, data: data, message: message) }
        }
    }

    private func serviceReplied(attempt: UInt64, data: Data?, message: String?) {
        // Any answer means the service is responsive again.
        serviceBusy = false
        consecutiveQuickFailures = 0
        replacedSinceLastAnswer = false
        guard let request = pending.removeValue(forKey: attempt) else { return } // already answered by fast

        guard message == nil, let data,
              let response = try? JSONDecoder().decode(OCRServiceResponse.self, from: data) else {
            replaceService()
            runFast(request.image, languages: request.languages) { request.finish($0, $1, .fastAfterServiceFailure) }
            return
        }
        let lines = response.lines.map { line in
            OCRTextObservation(text: line.text, boundingBox: line.boundingBox, substringBounds: { range in
                OCRCharacterBoxes.union(text: line.text, boxes: line.characterBoxes, range: range)
            })
        }
        if Self.containsText(lines) {
            request.finish(lines, nil, .service)
            return
        }
        // Nothing found: either there's no text, or the accurate model has
        // failed silently (seen on macOS 27). Ask the fast model.
        runFast(request.image, languages: request.languages) { [weak self] result, error in
            if Self.containsText(result) {
                self?.queue.async { self?.replaceService() }
                request.finish(result, nil, .fastAfterEmptyResult)
            } else {
                request.finish(lines, nil, .service)
            }
        }
    }

    private func softTimeoutExpired(attempt: UInt64) {
        guard let request = pending.removeValue(forKey: attempt) else { return }
        serviceBusy = true
        runFast(request.image, languages: request.languages) { request.finish($0, $1, .fastAfterTimeout) }
    }

    /// The service process went away (crash, its own deadline, or replacement)
    /// or never launched.
    private func serviceFailed(_ error: Error, attempt: UInt64, generation: UInt64) {
        // This client dropped that connection itself (a replacement while
        // this request was still queued behind another): the current service
        // is not to blame, so neither its launch time nor the failure count
        // change.
        guard generation == connectionGeneration else {
            guard let request = pending.removeValue(forKey: attempt) else { return }
            runFast(request.image, languages: request.languages) { request.finish($0, $1, .fastAfterServiceFailure) }
            return
        }
        serviceEnded()
        // A request already answered by the fast model (a hang that hit the
        // service's own deadline) is expected and doesn't count.
        guard let request = pending.removeValue(forKey: attempt) else { return }
        if replacedSinceLastAnswer {
            // Possibly sent to the replaced process as it exited.
            replacedSinceLastAnswer = false
        } else {
            consecutiveQuickFailures += 1
        }
        if consecutiveQuickFailures >= 3 {
            disabled = true
            dropConnection()
        }
        if disabled {
            runWithoutService(request.image, languages: request.languages, finish: request.finish)
        } else {
            runFast(request.image, languages: request.languages) { request.finish($0, $1, .fastAfterServiceFailure) }
        }
    }

    /// Drop the connection; the service exits when it notices, and the next
    /// request gets a new process.
    private func replaceService() {
        dropConnection()
        replacedSinceLastAnswer = true
        serviceEnded()
    }

    private func dropConnection() {
        guard let connection else { return }
        connectionGeneration &+= 1
        self.connection = nil
        connection.invalidate()
    }

    /// The service process is gone or going. If it was young, launchd will
    /// hold back its successor; answer from the fast model until then rather
    /// than leave the user waiting on a request launchd is sitting on.
    private func serviceEnded() {
        serviceBusy = false
        if let launched = serviceLaunchedAt {
            let allowed = launched.addingTimeInterval(timing.relaunchThrottle)
            if allowed > Date() { relaunchAllowedAt = max(allowed, relaunchAllowedAt ?? allowed) }
        }
        serviceLaunchedAt = nil
    }

    private func proxy(errorHandler: @escaping (Error) -> Void) -> OCRServiceProtocol? {
        guard let serviceName, !disabled else { return nil }
        if connection == nil {
            let connection = NSXPCConnection(serviceName: serviceName)
            connection.remoteObjectInterface = NSXPCInterface(with: OCRServiceProtocol.self)
            connection.interruptionHandler = { [weak self] in
                // The process ended; the next message relaunches it.
                self?.queue.async { self?.serviceEnded() }
            }
            let identity = ObjectIdentifier(connection)
            connection.invalidationHandler = { [weak self] in
                self?.queue.async {
                    guard let self, let current = self.connection, ObjectIdentifier(current) == identity else { return }
                    self.connection = nil
                }
            }
            connection.resume()
            self.connection = connection
        }
        return connection?.remoteObjectProxyWithErrorHandler(errorHandler) as? OCRServiceProtocol
    }

    // MARK: - Fallbacks

    private func runFast(_ image: CGImage, languages: [String],
                         completion: @escaping ([OCRTextObservation], Error?) -> Void) {
        let once = Finish { lines, error, _ in completion(lines, error) }
        let timeout = timing.fastTimeout
        fastQueue.async {
            let result = VisionOCR.recognizeWithLegacyAPI(cgImage: image, recognitionLevel: .fast,
                                                          preferredLanguages: languages)
            switch result {
            case .success(let lines): once(lines, nil, .service)
            case .failure(let error): once([], error, .service)
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            once([], OCRRecognitionSession.Failure.timedOut, .service)
        }
    }

    /// Used when the service can't be used. Before macOS 27 that is the
    /// original in-process session; on macOS 27 an accurate request in this
    /// process can block forever and poison every later one (FB25403069),
    /// so only the fast model runs.
    private func runWithoutService(_ image: CGImage, languages: [String], finish: Finish) {
        if Self.inProcessAccurateIsUnsafe {
            runFast(image, languages: languages) { finish($0, $1, .fastWithoutService) }
        } else {
            runInProcess(image, finish: finish)
        }
    }

    static var inProcessAccurateIsUnsafe: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    private func runInProcess(_ image: CGImage, finish: Finish) {
        VisionOCR.performTextRecognitionInProcess(cgImage: image) { lines, error in
            finish(lines, error, .inProcess)
        }
    }

    private static func containsText(_ lines: [OCRTextObservation]) -> Bool {
        lines.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
