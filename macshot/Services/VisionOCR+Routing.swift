import CoreGraphics

// App-only entry points. VisionOCR.swift is also compiled into the OCR service,
// which must not know about the client that talks to it.
extension VisionOCR {

    /// All consumers share the same recovery path, including geometry-based tools.
    /// Pass `includeCharacterBoxes` when the caller needs `boundingBox(for:)`
    /// on substrings (PII redaction); it costs one Vision lookup per character.
    nonisolated static func performTextRecognition(
        cgImage: CGImage,
        includeCharacterBoxes: Bool = false,
        completionHandler: @escaping ([OCRTextObservation], Error?) -> Void
    ) {
        OCRServiceClient.shared.recognize(cgImage: cgImage, includeCharacterBoxes: includeCharacterBoxes) { lines, error, _ in
            completionHandler(lines, error)
        }
    }

    nonisolated static func performTextAndQRCodeRecognition(
        cgImage: CGImage,
        completionHandler: @escaping (OCRScanResult) -> Void
    ) {
        performTextRecognition(cgImage: cgImage) { observations, _ in
            let text = observations.map(\.text).joined(separator: "\n")
            let qrCodes = detectQRCodes(cgImage: cgImage)
            completionHandler(OCRScanResult(text: text, qrCodes: qrCodes))
        }
    }
}
