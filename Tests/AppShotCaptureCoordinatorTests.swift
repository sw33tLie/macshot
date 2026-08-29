import Foundation

@main
struct AppShotCaptureCoordinatorTests {
    static func main() async {
        await presentsImageBeforeRecognitionCompletes()
        await publishesCompletedCapture()
        await reportsClipboardPublicationFailure()
        await resetsAdmissionAfterCaptureFailure()
        await rejectsOverlappingCapture()
    }

    @MainActor
    private static func presentsImageBeforeRecognitionCompletes() async {
        let recognitionGate = AsyncGate()
        var events: [String] = []
        let coordinator = AppShotCaptureCoordinator<Int, String>(
            captureImage: { _ in
                events.append("captured")
                return "pixels"
            },
            onImageCaptured: { target, image in
                precondition(target == 42)
                precondition(image == "pixels")
                events.append("presented")
            },
            recognizeText: { _ in
                events.append("recognition started")
                await recognitionGate.wait()
                events.append("recognition finished")
                return "visible text"
            },
            publish: { _ in
                events.append("published")
                return true
            }
        )

        let capture = Task { await coordinator.capture(target: 42) }
        await Task.yield()

        precondition(events == ["captured", "presented", "recognition started"])
        await recognitionGate.open()
        let result = await capture.value
        precondition(result == .completed)
        precondition(events == [
            "captured",
            "presented",
            "recognition started",
            "recognition finished",
            "published",
        ])
    }

    @MainActor
    private static func publishesCompletedCapture() async {
        var published: AppShotCaptureCoordinator<Int, String>.Content?
        let coordinator = AppShotCaptureCoordinator<Int, String>(
            captureImage: { _ in "pixels" },
            recognizeText: { _ in "visible text" },
            publish: {
                published = $0
                return true
            }
        )

        let result = await coordinator.capture(
            target: 42,
            capturedAt: Date(timeIntervalSince1970: 0)
        )

        precondition(result == .completed)
        precondition(published?.target == 42)
        precondition(published?.image == "pixels")
        precondition(published?.recognizedText == "visible text")
        precondition(published?.capturedAt == Date(timeIntervalSince1970: 0))
        precondition(!coordinator.isCapturing)
    }

    @MainActor
    private static func reportsClipboardPublicationFailure() async {
        var publicationFinished = false
        let coordinator = AppShotCaptureCoordinator<Int, String>(
            captureImage: { _ in "pixels" },
            recognizeText: { _ in "visible text" },
            publish: { _ in
                await Task.yield()
                publicationFinished = true
                return false
            }
        )

        let result = await coordinator.capture(target: 42)

        precondition(publicationFinished)
        precondition(result == .clipboardPublicationFailed)
        precondition(!coordinator.isCapturing)
    }

    @MainActor
    private static func resetsAdmissionAfterCaptureFailure() async {
        var attempts = 0
        let coordinator = AppShotCaptureCoordinator<Int, String>(
            captureImage: { _ in
                attempts += 1
                return attempts == 1 ? nil : "pixels"
            },
            recognizeText: { _ in "visible text" },
            publish: { _ in true }
        )

        let failed = await coordinator.capture(target: 42)
        precondition(failed == .imageCaptureFailed)
        precondition(!coordinator.isCapturing)
        let retried = await coordinator.capture(target: 42)
        precondition(retried == .completed)
    }

    @MainActor
    private static func rejectsOverlappingCapture() async {
        let gate = AsyncGate()
        let coordinator = AppShotCaptureCoordinator<Int, String>(
            captureImage: { _ in
                await gate.wait()
                return "pixels"
            },
            recognizeText: { _ in "visible text" },
            publish: { _ in true }
        )

        let first = Task { await coordinator.capture(target: 42) }
        await Task.yield()
        precondition(coordinator.isCapturing)
        let overlapping = await coordinator.capture(target: 42)
        precondition(overlapping == .captureInProgress)
        await gate.open()
        let firstResult = await first.value
        precondition(firstResult == .completed)
        precondition(!coordinator.isCapturing)
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
