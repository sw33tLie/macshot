import Foundation

/// A cancellation request and publication compete for one lock. Once atomic
/// publication begins, Cancel cannot report a saved file as cancelled.
final class MediaExportCancellation: @unchecked Sendable {
    private enum State: Sendable { case running, cancelled, publishing, finished }
    private let lock = NSLock()
    nonisolated(unsafe) private var state: State = .running

    nonisolated init() {}
    nonisolated var canCancel: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .running = state { return true }
        return false
    }
    nonisolated var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .cancelled = state { return true }
        return false
    }
    @discardableResult nonisolated func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard case .running = state else { return false }
        state = .cancelled
        return true
    }
    nonisolated func check() throws {
        if isCancelled { throw CancellationError() }
    }
    nonisolated func beginPublication() throws {
        lock.lock(); defer { lock.unlock() }
        if case .cancelled = state { throw CancellationError() }
        guard case .running = state else { throw CocoaError(.fileWriteUnknown) }
        state = .publishing
    }
    nonisolated fileprivate func finish() {
        lock.lock(); state = .finished; lock.unlock()
    }
}

/// App-owned tasks outlive their editor. Completion runs before an idle waiter
/// is resumed, so a completion that starts follow-up work cannot create a false
/// idle interval during application termination.
@MainActor
final class MediaExportCoordinator {
    static let shared = MediaExportCoordinator()

    final class Job {
        let id = UUID()
        let title: String
        let status: String
        let cancellation = MediaExportCancellation()
        private(set) var progress: Double?
        private(set) var isCancelling = false
        private(set) var isFinished = false
        var onChange: (() -> Void)?
        fileprivate var task: Task<Void, Never>?

        fileprivate init(title: String, status: String) { self.title = title; self.status = status }
        var canCancel: Bool { !isFinished && cancellation.canCancel }

        func cancel() {
            guard cancellation.cancel() else { onChange?(); return }
            isCancelling = true
            task?.cancel()
            onChange?()
        }

        fileprivate func report(_ value: Double) {
            guard !isFinished, !isCancelling, value.isFinite else { return }
            progress = max(progress ?? 0, max(0, min(1, value)))
            onChange?()
        }

        fileprivate func finish() {
            isFinished = true
            task = nil
            cancellation.finish()
            onChange?()
            onChange = nil
        }
    }

    private var jobs: [UUID: Job] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var hasActiveJobs: Bool { !jobs.isEmpty }
    var activeCount: Int { jobs.count }

    @discardableResult
    func start(title: String, status: String,
               operation: @escaping @MainActor (MediaExportCancellation, @escaping @Sendable (Double) -> Void) async throws -> Void,
               completion: @escaping @MainActor (Result<Void, Error>) -> Void) -> Job {
        let job = Job(title: title, status: status)
        jobs[job.id] = job
        let progress: @Sendable (Double) -> Void = { [weak job] value in
            DispatchQueue.main.async { job?.report(value) }
        }
        job.task = Task {
            let result: Result<Void, Error>
            do {
                try job.cancellation.check()
                try await operation(job.cancellation, progress)
                result = .success(())
            } catch {
                result = .failure(job.cancellation.isCancelled ? CancellationError() : error)
            }
            job.finish()
            completion(result)
            jobs.removeValue(forKey: job.id)
            if jobs.isEmpty {
                let waiters = idleWaiters
                idleWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        return job
    }

    func waitUntilIdle() async {
        guard !jobs.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
}

/// Await actual completion of worker I/O even after cancellation. Returning
/// early would release file/directory leases while that worker still uses them.
enum MediaExportIO {
    nonisolated static func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
