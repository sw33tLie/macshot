import XCTest

final class CancellableRenderQueueTests: XCTestCase {
    func testPendingFramesCancelImmediatelyAndCancellationWaitsForRunningFrame() {
        let queue = CancellableRenderQueue()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0), returned = DispatchSemaphore(value: 0)
        let count = CompletionCounts()
        queue.submit(work: {
            started.signal()
            _ = release.wait(timeout: .now() + 5)
            count.rendered()
        }, onCancel: { count.cancelled() })
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        queue.submit(work: { count.rendered() }, onCancel: { count.cancelled(); cancelled.signal() })
        DispatchQueue.global().async { queue.cancelAll(); returned.signal() }
        XCTAssertEqual(cancelled.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(returned.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(returned.wait(timeout: .now() + 2), .success)
        queue.cancelAll()
        XCTAssertEqual(count.values.0, 1)
        XCTAssertEqual(count.values.1, 1)
    }

    func testConcurrentCancellationFinishesEachRequestExactlyOnce() {
        let queue = CancellableRenderQueue(), count = CompletionCounts()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        queue.submit(work: {
            started.signal(); _ = release.wait(timeout: .now() + 5); count.rendered()
        }, onCancel: { count.cancelled() })
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        for _ in 0..<500 { queue.submit(work: { count.rendered() }, onCancel: { count.cancelled() }) }
        let callers = DispatchGroup()
        for _ in 0..<4 {
            callers.enter()
            DispatchQueue.global().async { queue.cancelAll(); callers.leave() }
        }
        release.signal()
        XCTAssertEqual(callers.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(count.values.0 + count.values.1, 501)
    }

    func testNewRequestsWorkAfterCancellationAndFinishCanReenterCancellation() {
        let queue = CancellableRenderQueue(), count = CompletionCounts()
        queue.cancelAll()
        let done = DispatchSemaphore(value: 0)
        queue.submit(work: {
            count.rendered()
            queue.cancelAll() // Simulates reentry from a finish callback.
            done.signal()
        }, onCancel: { count.cancelled() })
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
        queue.cancelAll()
        XCTAssertEqual(count.values.0, 1)
        XCTAssertEqual(count.values.1, 0)
    }
}

private final class CompletionCounts: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var renders = 0
    nonisolated(unsafe) private var cancellations = 0
    nonisolated init() {}
    nonisolated func rendered() { lock.lock(); renders += 1; lock.unlock() }
    nonisolated func cancelled() { lock.lock(); cancellations += 1; lock.unlock() }
    nonisolated var values: (Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return (renders, cancellations)
    }
}
