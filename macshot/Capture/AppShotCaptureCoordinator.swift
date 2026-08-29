import Foundation

/// Owns admission and the asynchronous steps for one no-overlay App Shot.
/// UI side effects stay behind `publish`, which keeps the capture path testable.
@MainActor
final class AppShotCaptureCoordinator<Target, Image> {
    struct Content {
        let target: Target
        let image: Image
        let recognizedText: String
        let capturedAt: Date
    }

    enum Outcome: Equatable {
        case completed
        case captureInProgress
        case imageCaptureFailed
        case clipboardPublicationFailed
    }

    private let captureImage: (Target) async -> Image?
    private let recognizeText: (Image) async -> String
    private let publish: (Content) async -> Bool

    private(set) var isCapturing = false

    init(
        captureImage: @escaping (Target) async -> Image?,
        recognizeText: @escaping (Image) async -> String,
        publish: @escaping (Content) async -> Bool
    ) {
        self.captureImage = captureImage
        self.recognizeText = recognizeText
        self.publish = publish
    }

    // Keep closure destruction out of the optimizer's early inliner. Xcode 26.5's
    // x86_64 Swift frontend crashes while optimizing the synthesized deinitializer.
    @inline(never)
    deinit {}

    func capture(target: Target, capturedAt: Date = Date()) async -> Outcome {
        guard !isCapturing else { return .captureInProgress }

        isCapturing = true
        defer { isCapturing = false }

        guard let image = await captureImage(target) else {
            return .imageCaptureFailed
        }
        let recognizedText = await recognizeText(image)
        guard await publish(Content(
            target: target,
            image: image,
            recognizedText: recognizedText,
            capturedAt: capturedAt
        )) else {
            return .clipboardPublicationFailed
        }
        return .completed
    }
}
