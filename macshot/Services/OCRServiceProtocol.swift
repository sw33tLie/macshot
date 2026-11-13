import Foundation
import CoreGraphics

// Shared by the app and the macshotOCR XPC service (see the "macshot" folder
// exception for the macshotOCR target). Keep it free of AppKit and app state.
//
// Why a separate process: on macOS 27, Vision's accurate text recognition can
// get stuck inside the process for good. The call never returns, cancel() is
// ignored, and every later request queues behind it (FB25403069). Only a new
// process recovers, so accurate OCR runs in a service that can be replaced.

/// The XPC interface. Requests and responses are JSON so both sides can evolve
/// without NSSecureCoding classes; pixels travel separately as raw RGBA8.
@objc nonisolated protocol OCRServiceProtocol {
    func recognize(_ request: Data, pixels: Data, reply: @escaping (Data?, String?) -> Void)
    /// The service's process ID. Used by the probe to prove a replacement.
    func processIdentifier(reply: @escaping (Int32) -> Void)
}

nonisolated struct OCRServiceRequest: Codable, Sendable {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var accurate: Bool
    var preferredLanguages: [String]
    /// Per-character boxes let the app compute substring boxes (PII redaction)
    /// without a live Vision object.
    var includeCharacterBoxes: Bool
    /// The service ends itself if one request runs longer than this. Long
    /// enough for a cold model compile (44-66 s observed on macOS 27).
    var hardDeadline: TimeInterval
    /// Fault injection, honored only in builds with OCR_FAULT_INJECTION.
    var debugBehavior: String?
}

nonisolated struct OCRServiceLine: Codable, Sendable {
    var text: String
    /// Normalized, bottom-left origin, as Vision reports it.
    var boundingBox: CGRect
    /// One entry per Character of `text`; nil for whitespace or when Vision
    /// has no box. Empty when not requested.
    var characterBoxes: [CGRect?]
}

nonisolated struct OCRServiceResponse: Codable, Sendable {
    var lines: [OCRServiceLine]
}

nonisolated enum OCRServicePixels {
    /// Draws `image` into a tightly packed sRGB RGBA8 buffer.
    static func pack(_ image: CGImage) -> (data: Data, width: Int, height: Int, bytesPerRow: Int)? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (data, width, height, bytesPerRow) : nil
    }

    /// Rebuilds the image on the service side. Rejects inconsistent geometry.
    static func unpack(_ data: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard width > 0, height > 0, bytesPerRow >= width * 4,
              height <= Int.max / bytesPerRow, data.count >= bytesPerRow * height,
              let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

nonisolated enum OCRCharacterBoxes {
    /// Boxes for each Character of `text`. Whitespace is skipped on purpose:
    /// Vision returns a box spanning to the image edge for a space.
    static func compute(text: String, box: (Range<String.Index>) -> CGRect?) -> [CGRect?] {
        var result: [CGRect?] = []
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            result.append(text[index].isWhitespace ? nil : box(index..<next))
            index = next
        }
        return result
    }

    /// The union of the character boxes covering `range`, or nil if none has a box.
    static func union(text: String, boxes: [CGRect?], range: Range<String.Index>) -> CGRect? {
        guard !boxes.isEmpty,
              range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex else { return nil }
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let end = text.distance(from: text.startIndex, to: range.upperBound)
        guard start < end, end <= boxes.count else { return nil }
        var result: CGRect?
        for box in boxes[start..<end] {
            guard let box else { continue }
            result = result?.union(box) ?? box
        }
        return result
    }
}
