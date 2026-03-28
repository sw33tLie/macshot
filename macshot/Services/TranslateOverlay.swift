import Cocoa
import Vision

/// Handles text translation overlay: OCR → translate → create overlay annotations.
enum TranslateOverlay {

    /// Perform OCR + translation on the selected region. Calls completion with overlay annotations.
    static func translate(
        screenshot: NSImage,
        selectionRect: NSRect,
        captureDrawRect: NSRect,
        targetLang: String,
        onError: @escaping (String) -> Void,
        completion: @escaping ([Annotation]) -> Void
    ) {
        let regionImage = NSImage(size: selectionRect.size, flipped: false) { _ in
            screenshot.draw(in: NSRect(x: -selectionRect.origin.x, y: -selectionRect.origin.y,
                                       width: captureDrawRect.width, height: captureDrawRect.height),
                            from: .zero, operation: .copy, fraction: 1.0)
            return true
        }

        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else {
            onError("Failed to process image")
            return
        }

        let request = VisionOCR.makeTextRecognitionRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation],
                  !observations.isEmpty else {
                DispatchQueue.main.async { onError("No text found in selection.") }
                return
            }

            let blocks = observations.compactMap { obs -> (text: String, box: CGRect)? in
                guard let top = obs.topCandidates(1).first else { return nil }
                let t = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return nil }
                return (t, obs.boundingBox)
            }

            TranslationService.translateBatch(texts: blocks.map { $0.text }, targetLang: targetLang) { result in
                switch result {
                case .failure(let error):
                    onError("Translation failed: \(error.localizedDescription)")

                case .success(let translations):
                    var annotations: [Annotation] = []
                    let groupID = UUID()

                    for (i, block) in blocks.enumerated() {
                        guard i < translations.count else { continue }
                        let translated = translations[i].trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !translated.isEmpty else { continue }

                        let box = block.box
                        let padding: CGFloat = 1
                        let viewX = selectionRect.origin.x + box.origin.x * selectionRect.width - padding
                        let viewY = selectionRect.origin.y + box.origin.y * selectionRect.height - padding
                        let viewW = box.width * selectionRect.width + padding * 2
                        let viewH = box.height * selectionRect.height + padding * 2

                        let bgColor = sampleAverageColor(in: cgImage, region: CGRect(
                            x: box.origin.x * CGFloat(cgImage.width),
                            y: box.origin.y * CGFloat(cgImage.height),
                            width: box.width * CGFloat(cgImage.width),
                            height: box.height * CGFloat(cgImage.height)
                        ))

                        let ann = Annotation(
                            tool: .translateOverlay,
                            startPoint: NSPoint(x: viewX, y: viewY),
                            endPoint: NSPoint(x: viewX + viewW, y: viewY + viewH),
                            color: bgColor, strokeWidth: 0
                        )
                        ann.text = translated
                        ann.fontSize = max(8, viewH * 0.65)
                        ann.groupID = groupID
                        annotations.append(ann)
                    }

                    DispatchQueue.main.async { completion(annotations) }
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }
    }

    // MARK: - Helpers

    private static func sampleAverageColor(in cgImage: CGImage, region: CGRect) -> NSColor {
        let clampedX = max(0, min(Int(region.origin.x), cgImage.width - 1))
        let clampedY = max(0, min(Int(region.origin.y), cgImage.height - 1))
        let clampedW = min(max(1, Int(region.width)), cgImage.width - clampedX)
        let clampedH = min(max(1, Int(region.height)), cgImage.height - clampedY)
        guard clampedW > 0, clampedH > 0 else { return .white }

        let thumbW = 4, thumbH = 4
        var pixelData = [UInt8](repeating: 0, count: thumbW * thumbH * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixelData, width: thumbW, height: thumbH,
                                  bitsPerComponent: 8, bytesPerRow: thumbW * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cropped = cgImage.cropping(to: CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH))
        else { return .white }

        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        let count = CGFloat(thumbW * thumbH)
        for i in 0..<(thumbW * thumbH) {
            let base = i * 4
            r += CGFloat(pixelData[base]) / 255.0
            g += CGFloat(pixelData[base + 1]) / 255.0
            b += CGFloat(pixelData[base + 2]) / 255.0
        }
        return NSColor(deviceRed: r / count, green: g / count, blue: b / count, alpha: 1.0)
    }
}
