import Foundation

/// Serial rendering with synchronous cancellation, as required by
/// AVVideoCompositing. A pending job finishes through its cancellation callback;
/// a running job owns its completion and is allowed to finish before we return.
final class CancellableRenderQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macshot.effects.render", qos: .userInitiated)
    private let lock = NSLock()
    nonisolated(unsafe) private var jobs: [UUID: Job] = [:]

    nonisolated init() {}

    nonisolated func submit(work: @escaping @Sendable () -> Void,
                            onCancel: @escaping @Sendable () -> Void) {
        let job = Job(work: work, onCancel: onCancel)
        lock.lock()
        jobs[job.id] = job
        queue.async { [weak self] in
            job.run()
            self?.remove(job)
        }
        lock.unlock()
    }

    nonisolated func cancelAll() {
        lock.lock()
        let pending = Array(jobs.values)
        lock.unlock()
        // Finish queued requests immediately, without allocating their source
        // and output buffers or waiting for the currently rendering frame.
        for job in pending { job.cancelIfPending() }
        for job in pending {
            job.waitForCompletion()
            if job.isFinished { remove(job) }
        }
    }

    nonisolated private func remove(_ job: Job) {
        lock.lock()
        jobs.removeValue(forKey: job.id)
        lock.unlock()
    }

    private final class Job: @unchecked Sendable {
        let id = UUID()
        private let condition = NSCondition()
        private enum State: Sendable { case pending, running, finished }
        nonisolated(unsafe) private var state = State.pending
        nonisolated(unsafe) private var work: (@Sendable () -> Void)?
        nonisolated(unsafe) private var onCancel: (@Sendable () -> Void)?
        nonisolated(unsafe) private var completingThread: pthread_t?

        nonisolated init(work: @escaping @Sendable () -> Void,
                         onCancel: @escaping @Sendable () -> Void) {
            self.work = work
            self.onCancel = onCancel
        }

        nonisolated func run() { perform(cancelling: false) }
        nonisolated func cancelIfPending() { perform(cancelling: true) }

        nonisolated private func perform(cancelling: Bool) {
            condition.lock()
            guard case .pending = state else { condition.unlock(); return }
            state = .running
            completingThread = pthread_self()
            let callback = cancelling ? onCancel : work
            work = nil
            onCancel = nil
            condition.unlock()
            callback?()
            condition.lock()
            state = .finished
            completingThread = nil
            condition.broadcast()
            condition.unlock()
        }

        nonisolated var isFinished: Bool {
            condition.lock()
            defer { condition.unlock() }
            if case .finished = state { return true }
            return false
        }

        nonisolated func waitForCompletion() {
            condition.lock()
            defer { condition.unlock() }
            // AVFoundation completion callbacks can reenter cancellation. That
            // request has already entered its finish callback; waiting on that
            // same stack would deadlock. Work must invoke completion last.
            if let thread = completingThread, pthread_equal(thread, pthread_self()) != 0 { return }
            while true {
                if case .finished = state { return }
                condition.wait()
            }
        }
    }
}
