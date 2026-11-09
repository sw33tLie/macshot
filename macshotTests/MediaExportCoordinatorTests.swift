import XCTest

@MainActor
final class MediaExportCoordinatorTests: XCTestCase {
    private final class Gate {
        private var open = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { open = true; waiter?.resume(); waiter = nil }
    }

    func testImmediateCancellationCompletesOnceWithoutStartingTheOperation() async {
        let coordinator = MediaExportCoordinator()
        var invoked = false, completions = 0
        let job = coordinator.start(title: "test", status: "test", operation: { _, _ in
            invoked = true
        }, completion: { result in
            completions += 1
            guard case .failure(let error) = result else { return XCTFail("Cancelled job succeeded") }
            XCTAssertTrue(error is CancellationError)
        })
        job.cancel(); job.cancel()
        await coordinator.waitUntilIdle()
        XCTAssertFalse(invoked)
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(job.isFinished)
        XCTAssertFalse(coordinator.hasActiveJobs)
    }

    func testOwnerReleaseDoesNotDiscardWorkAndIdleIncludesCompletionFollowup() async {
        let coordinator = MediaExportCoordinator()
        let first = Gate(), second = Gate(), third = Gate()
        let firstFinished = expectation(description: "First completion registered follow-up")
        let secondFinished = expectation(description: "Second completion")
        var job: MediaExportCoordinator.Job? = coordinator.start(title: "one", status: "test", operation: { _, _ in
            await first.wait()
        }, completion: { _ in
            coordinator.start(title: "three", status: "test", operation: { _, _ in await third.wait() }, completion: { _ in })
            firstFinished.fulfill()
        })
        XCTAssertNotNil(job)
        job = nil
        coordinator.start(title: "two", status: "test", operation: { _, _ in await second.wait() }, completion: { _ in secondFinished.fulfill() })
        var idle = false
        let waiter = Task { await coordinator.waitUntilIdle(); idle = true }
        XCTAssertEqual(coordinator.activeCount, 2)
        first.release()
        await fulfillment(of: [firstFinished], timeout: 5)
        XCTAssertEqual(coordinator.activeCount, 2)
        XCTAssertFalse(idle)
        second.release()
        await fulfillment(of: [secondFinished], timeout: 5)
        XCTAssertEqual(coordinator.activeCount, 1)
        XCTAssertFalse(idle)
        third.release()
        await waiter.value
        XCTAssertTrue(idle)
        XCTAssertEqual(coordinator.activeCount, 0)
    }

    func testCancellationWaitsForTheWorkerBeforeCompletingOrReleasingItsOwner() async {
        let coordinator = MediaExportCoordinator()
        let workerEntered = expectation(description: "Worker owns input")
        let workerRelease = DispatchSemaphore(value: 0)
        var completed = false
        let job = coordinator.start(title: "copy", status: "test", operation: { cancellation, _ in
            try await MediaExportIO.perform {
                workerEntered.fulfill()
                workerRelease.wait()
                try cancellation.check()
            }
        }, completion: { result in
            completed = true
            guard case .failure(let error) = result else { return XCTFail("Cancelled job succeeded") }
            XCTAssertTrue(error is CancellationError)
        })
        await fulfillment(of: [workerEntered], timeout: 5)
        job.cancel()
        XCTAssertTrue(job.isCancelling)
        XCTAssertFalse(completed)
        XCTAssertTrue(coordinator.hasActiveJobs)
        workerRelease.signal()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(completed)
        XCTAssertTrue(job.isFinished)
    }

    func testPublicationWinnerCannotBeCancelledOrReportedAsFailure() async {
        let coordinator = MediaExportCoordinator()
        let publishing = expectation(description: "Atomic publication owns result")
        let gate = Gate()
        var succeeded = false
        let job = coordinator.start(title: "save", status: "test", operation: { cancellation, _ in
            try cancellation.beginPublication()
            publishing.fulfill()
            await gate.wait()
            try Task.checkCancellation()
        }, completion: { result in
            if case .success = result { succeeded = true }
        })
        await fulfillment(of: [publishing], timeout: 5)
        XCTAssertFalse(job.canCancel)
        job.cancel()
        XCTAssertFalse(job.isCancelling)
        gate.release()
        await coordinator.waitUntilIdle()
        XCTAssertTrue(succeeded)
    }

    func testConcurrentPublicationAndCancellationHaveExactlyOneWinner() {
        final class Outcome: @unchecked Sendable {
            let lock = NSLock()
            nonisolated(unsafe) var published = false
            nonisolated(unsafe) var cancelled = false
            nonisolated func setPublished() { lock.lock(); published = true; lock.unlock() }
            nonisolated func setCancelled(_ value: Bool) { lock.lock(); cancelled = value; lock.unlock() }
        }
        for _ in 0..<500 {
            let cancellation = MediaExportCancellation(), outcome = Outcome()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    do { try cancellation.beginPublication(); outcome.setPublished() } catch {}
                } else { outcome.setCancelled(cancellation.cancel()) }
            }
            XCTAssertNotEqual(outcome.published, outcome.cancelled)
            XCTAssertFalse(cancellation.canCancel)
            XCTAssertEqual(cancellation.isCancelled, outcome.cancelled)
        }
    }

    func testQuitKeepsNormalRunLoopAndRetriesOnceAfterJobsAndTheirFollowupDrain() async {
        let exports = MediaExportCoordinator(), termination = ApplicationTerminationCoordinator()
        let first = Gate(), second = Gate()
        let followedUp = expectation(description: "First save starts follow-up")
        let quitRetried = expectation(description: "Quit retried after all work")
        var drainCount = 0, retryCount = 0
        exports.start(title: "one", status: "save", operation: { _, _ in await first.wait() }, completion: { _ in
            exports.start(title: "two", status: "save", operation: { _, _ in await second.wait() }, completion: { _ in })
            followedUp.fulfill()
        })
        for _ in 0..<3 {
            let reply = termination.request(hasActiveWork: exports.hasActiveJobs, drain: {
                drainCount += 1
                await exports.waitUntilIdle()
            }, terminate: {
                XCTAssertFalse(exports.hasActiveJobs)
                XCTAssertFalse(termination.isWaiting)
                retryCount += 1
                quitRetried.fulfill()
            })
            XCTAssertEqual(reply, .terminateCancel, "A modal termination loop stalls MainActor completion")
        }
        first.release()
        await fulfillment(of: [followedUp], timeout: 5)
        XCTAssertTrue(termination.isWaiting)
        XCTAssertEqual(retryCount, 0)
        second.release()
        await fulfillment(of: [quitRetried], timeout: 5)
        XCTAssertEqual(drainCount, 1)
        XCTAssertEqual(retryCount, 1)
        XCTAssertEqual(termination.request(hasActiveWork: false, drain: { XCTFail("Already idle") },
            terminate: { XCTFail("No asynchronous retry needed") }), .terminateNow)
    }
}
