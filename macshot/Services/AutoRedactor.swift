import Cocoa
import Vision

/// Handles PII auto-redaction: regex pattern matching + Vision OCR to find sensitive text,
/// creates redaction annotations (filled rect, blur, or pixelate).
enum AutoRedactor {

    // MARK: - Sensitive patterns

    static let redactTypeNames: [(key: String, label: String)] = [
        ("email", "Emails"),
        ("phone", "Phone Numbers"),
        ("ssn", "SSN"),
        ("credit_card", "Credit Cards"),
        ("cvv", "CVV Codes"),
        ("expiry", "Expiry Dates"),
        ("ipv4", "IP Addresses"),
        ("aws_key", "AWS Keys"),
        ("secret_assignment", "Secrets/Tokens"),
        ("hex_key", "Hex Keys"),
        ("bearer", "Bearer Tokens"),
    ]

    private static let sensitivePatterns: [(name: String, pattern: NSRegularExpression)] = {
        let patterns: [(String, String)] = [
            ("email", #"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"#),
            ("phone", #"(?:\+?1[-.\s]?)?(?:\(?\d{3}\)?[-.\s]?)\d{3}[-.\s]?\d{4}"#),
            ("ssn", #"\b\d{3}[-\s]\d{2}[-\s]\d{4}\b"#),
            ("credit_card", #"\d{4}[-\s]*\d{4}[-\s]*\d{4}[-\s]*\d{1,7}"#),
            ("credit_card", #"\d{4}[-\s]*\d{6}[-\s]*\d{5}"#),
            ("credit_card", #"\d{3,6}\s+\d{3,6}(?:\s+\d{3,6}){0,3}"#),
            ("cvv", #"(?:CVV|CVC|CSC|CCV)\s*:?\s*\d{3,4}"#),
            ("expiry", #"\b(?:\d{2}[/\-]\d{2,4}|\d{4}[/\-]\d{2})\b"#),
            ("ipv4", #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#),
            ("aws_key", #"\b(?:AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b"#),
            ("secret_assignment", #"(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)\s*[:=]\s*\S+"#),
            ("hex_key", #"\b[0-9a-fA-F]{32,}\b"#),
            ("bearer", #"Bearer\s+[A-Za-z0-9\-._~+/]+=*"#),
        ]
        return patterns.compactMap { (name, pat) in
            guard let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) else { return nil }
            return (name, regex)
        }
    }()

    // MARK: - Public API

    /// Redact PII patterns in the selected region. Runs OCR on background thread, calls completion with annotations.
    static func redactPII(
        screenshot: NSImage,
        selectionRect: NSRect,
        captureDrawRect: NSRect,
        redactTool: AnnotationTool,
        color: NSColor,
        sourceImage: NSImage?,
        sourceImageBounds: NSRect,
        completion: @escaping ([Annotation]) -> Void
    ) {
        let cgImage = cropToCGImage(screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect)
        guard let cgImage = cgImage else { completion([]); return }

        let request = VisionOCR.makeTextRecognitionRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { completion([]); return }
            let annotations = buildPIIRedactions(
                observations: observations, selectionRect: selectionRect,
                redactTool: redactTool, color: color,
                sourceImage: sourceImage, sourceImageBounds: sourceImageBounds
            )
            for ann in annotations { ann.bakePixelate() }
            DispatchQueue.main.async { completion(annotations) }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }
    }

    /// Redact ALL text in the selected region (not just PII). Runs OCR, calls completion with annotations.
    static func redactAllText(
        screenshot: NSImage,
        selectionRect: NSRect,
        captureDrawRect: NSRect,
        redactTool: AnnotationTool,
        color: NSColor,
        sourceImage: NSImage?,
        sourceImageBounds: NSRect,
        completion: @escaping ([Annotation]) -> Void
    ) {
        let cgImage = cropToCGImage(screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect)
        guard let cgImage = cgImage else { completion([]); return }

        let request = VisionOCR.makeTextRecognitionRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { completion([]); return }
            let groupID = UUID()
            let padding: CGFloat = 2
            var annotations: [Annotation] = []

            for observation in observations {
                let box = observation.boundingBox
                let viewX = selectionRect.origin.x + box.origin.x * selectionRect.width - padding
                let viewY = selectionRect.origin.y + box.origin.y * selectionRect.height - padding
                let viewW = box.width * selectionRect.width + padding * 2
                let viewH = box.height * selectionRect.height + padding * 2
                let ann = Annotation(tool: redactTool,
                    startPoint: NSPoint(x: viewX, y: viewY),
                    endPoint: NSPoint(x: viewX + viewW, y: viewY + viewH),
                    color: color, strokeWidth: 0)
                ann.groupID = groupID
                if redactTool == .rectangle { ann.rectFillStyle = .fill }
                else if redactTool == .blur || redactTool == .pixelate {
                    ann.sourceImage = sourceImage
                    ann.sourceImageBounds = sourceImageBounds
                }
                annotations.append(ann)
            }
            for ann in annotations { ann.bakePixelate() }
            DispatchQueue.main.async { completion(annotations) }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }
    }

    // MARK: - Face redaction

    /// Detect faces in the selected region and create blur/pixelate/filled-rect annotations over each face.
    static func redactFaces(
        screenshot: NSImage,
        selectionRect: NSRect,
        captureDrawRect: NSRect,
        redactTool: AnnotationTool,
        color: NSColor,
        sourceImage: NSImage?,
        sourceImageBounds: NSRect,
        completion: @escaping ([Annotation]) -> Void
    ) {
        let cgImage = cropToCGImage(screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect)
        guard let cgImage = cgImage else { completion([]); return }

        let request = VNDetectFaceRectanglesRequest { request, _ in
            guard let observations = request.results as? [VNFaceObservation] else { completion([]); return }
            let groupID = UUID()
            let padding: CGFloat = 4
            var annotations: [Annotation] = []

            for observation in observations {
                let box = observation.boundingBox
                let viewX = selectionRect.origin.x + box.origin.x * selectionRect.width - padding
                let viewY = selectionRect.origin.y + box.origin.y * selectionRect.height - padding
                let viewW = box.width * selectionRect.width + padding * 2
                let viewH = box.height * selectionRect.height + padding * 2
                let ann = Annotation(tool: redactTool,
                    startPoint: NSPoint(x: viewX, y: viewY),
                    endPoint: NSPoint(x: viewX + viewW, y: viewY + viewH),
                    color: color, strokeWidth: 0)
                ann.groupID = groupID
                if redactTool == .rectangle { ann.rectFillStyle = .fill }
                else if redactTool == .blur || redactTool == .pixelate {
                    ann.sourceImage = sourceImage
                    ann.sourceImageBounds = sourceImageBounds
                }
                annotations.append(ann)
            }
            for ann in annotations { ann.bakePixelate() }
            DispatchQueue.main.async { completion(annotations) }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }
    }

    /// Detect human bodies in the selected region and create blur/pixelate/filled-rect annotations over each person.
    static func redactPeople(
        screenshot: NSImage,
        selectionRect: NSRect,
        captureDrawRect: NSRect,
        redactTool: AnnotationTool,
        color: NSColor,
        sourceImage: NSImage?,
        sourceImageBounds: NSRect,
        completion: @escaping ([Annotation]) -> Void
    ) {
        let cgImage = cropToCGImage(screenshot: screenshot, selectionRect: selectionRect, captureDrawRect: captureDrawRect)
        guard let cgImage = cgImage else { completion([]); return }

        let request = VNDetectHumanRectanglesRequest { request, _ in
            guard let observations = request.results as? [VNHumanObservation] else { completion([]); return }
            let groupID = UUID()
            let padding: CGFloat = 4
            var annotations: [Annotation] = []

            for observation in observations {
                let box = observation.boundingBox
                let viewX = selectionRect.origin.x + box.origin.x * selectionRect.width - padding
                let viewY = selectionRect.origin.y + box.origin.y * selectionRect.height - padding
                let viewW = box.width * selectionRect.width + padding * 2
                let viewH = box.height * selectionRect.height + padding * 2
                let ann = Annotation(tool: redactTool,
                    startPoint: NSPoint(x: viewX, y: viewY),
                    endPoint: NSPoint(x: viewX + viewW, y: viewY + viewH),
                    color: color, strokeWidth: 0)
                ann.groupID = groupID
                if redactTool == .rectangle { ann.rectFillStyle = .fill }
                else if redactTool == .blur || redactTool == .pixelate {
                    ann.sourceImage = sourceImage
                    ann.sourceImageBounds = sourceImageBounds
                }
                annotations.append(ann)
            }
            for ann in annotations { ann.bakePixelate() }
            DispatchQueue.main.async { completion(annotations) }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        }
    }

    // MARK: - Helpers

    private static func cropToCGImage(screenshot: NSImage, selectionRect: NSRect, captureDrawRect: NSRect) -> CGImage? {
        let regionImage = NSImage(size: selectionRect.size, flipped: false) { _ in
            screenshot.draw(in: NSRect(x: -selectionRect.origin.x, y: -selectionRect.origin.y,
                                        width: captureDrawRect.width, height: captureDrawRect.height),
                            from: .zero, operation: .copy, fraction: 1.0)
            return true
        }
        guard let tiffData = regionImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.cgImage
    }

    private static func buildPIIRedactions(
        observations: [VNRecognizedTextObservation],
        selectionRect: NSRect,
        redactTool: AnnotationTool,
        color: NSColor,
        sourceImage: NSImage?,
        sourceImageBounds: NSRect
    ) -> [Annotation] {
        var annotations: [Annotation] = []
        let groupID = UUID()
        let padding: CGFloat = 2
        var redactedObservations = Set<Int>()

        func addRedaction(box: CGRect) {
            let viewX = selectionRect.origin.x + box.origin.x * selectionRect.width - padding
            let viewY = selectionRect.origin.y + box.origin.y * selectionRect.height - padding
            let viewW = box.width * selectionRect.width + padding * 2
            let viewH = box.height * selectionRect.height + padding * 2
            let ann = Annotation(tool: redactTool,
                startPoint: NSPoint(x: viewX, y: viewY),
                endPoint: NSPoint(x: viewX + viewW, y: viewY + viewH),
                color: color, strokeWidth: 0)
            ann.groupID = groupID
            if redactTool == .rectangle { ann.rectFillStyle = .fill }
            else if redactTool == .blur || redactTool == .pixelate {
                ann.sourceImage = sourceImage
                ann.sourceImageBounds = sourceImageBounds
            }
            annotations.append(ann)
        }

        // Pass 1: regex matching
        let enabledTypes = UserDefaults.standard.array(forKey: "enabledRedactTypes") as? [String]
        let activePatterns = sensitivePatterns.filter { enabledTypes == nil || enabledTypes!.contains($0.name) }

        for (i, obs) in observations.enumerated() {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            for (_, regex) in activePatterns {
                for match in regex.matches(in: text, options: [], range: fullRange) {
                    guard let swiftRange = Range(match.range, in: text),
                          let box = try? candidate.boundingBox(for: swiftRange) else { continue }
                    addRedaction(box: box.boundingBox)
                    redactedObservations.insert(i)
                }
            }
        }

        // Pass 2: split card numbers
        struct DigitObs { let index: Int; let midY: CGFloat; let midX: CGFloat; let box: CGRect; let digitCount: Int }
        var digitObs: [DigitObs] = []
        for (i, obs) in observations.enumerated() {
            guard !redactedObservations.contains(i), let c = obs.topCandidates(1).first else { continue }
            let digits = c.string.filter(\.isNumber)
            if digits.count >= 3 && digits.count <= 6 {
                digitObs.append(DigitObs(index: i, midY: obs.boundingBox.midY, midX: obs.boundingBox.midX, box: obs.boundingBox, digitCount: digits.count))
            }
        }
        var used = Set<Int>()
        var grouped: [[DigitObs]] = []
        for (idx, obs) in digitObs.enumerated() {
            guard !used.contains(idx) else { continue }
            var row = [obs]; used.insert(idx)
            for (jdx, other) in digitObs.enumerated() where !used.contains(jdx) && abs(other.midY - obs.midY) < 0.03 {
                row.append(other); used.insert(jdx)
            }
            row.sort { $0.midX < $1.midX }
            grouped.append(row)
        }
        for row in grouped where row.count >= 2 {
            let total = row.reduce(0) { $0 + $1.digitCount }
            guard total >= 8 || (row.count >= 2 && row.allSatisfy { $0.digitCount >= 4 }) else { continue }
            for obs in row { addRedaction(box: obs.box); redactedObservations.insert(obs.index) }
        }

        // Pass 3: CVV/expiry near card data
        if !redactedObservations.isEmpty {
            let cvv = try? NSRegularExpression(pattern: #"^\d{3,4}$"#)
            let expiry = try? NSRegularExpression(pattern: #"^\d{4}[-/]\d{2}$|^\d{2}[-/]\d{2,4}$"#)
            for (i, obs) in observations.enumerated() {
                guard !redactedObservations.contains(i), let c = obs.topCandidates(1).first else { continue }
                let text = c.string.trimmingCharacters(in: .whitespaces)
                let range = NSRange(location: 0, length: (text as NSString).length)
                if cvv?.firstMatch(in: text, range: range) != nil || expiry?.firstMatch(in: text, range: range) != nil {
                    addRedaction(box: obs.boundingBox); redactedObservations.insert(i)
                }
            }
        }

        return annotations
    }
}
