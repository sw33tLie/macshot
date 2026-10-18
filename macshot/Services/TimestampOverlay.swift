import AppKit

/// Burns a capture time into finished screenshot pixels.
@MainActor
enum TimestampOverlay {
    static let userDefaultsKey = "timestampBurnIn"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    /// A nil date leaves the image unchanged. This prevents screenshots taken
    /// with burn-in off from gaining a timestamp when they are edited later.
    static func stamp(_ image: NSImage, capturedAt: Date?) -> NSImage {
        guard let capturedAt, image.size.width > 1, image.size.height > 1 else { return image }
        var sourceRect = NSRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &sourceRect, context: nil, hints: nil),
              let context = bitmapContext(width: source.width, height: source.height, colorSpace: source.colorSpace),
              let layout = labelLayout(text: formatted(capturedAt), imageSize: image.size)
        else { return image }

        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let scale = CGFloat(source.width) / image.size.width
        context.saveGState()
        context.scaleBy(x: scale, y: scale)

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext

        let boxPath = NSBezierPath(
            roundedRect: layout.box,
            xRadius: min(layout.box.height / 2, 10),
            yRadius: min(layout.box.height / 2, 10))
        NSColor.black.withAlphaComponent(0.62).setFill()
        boxPath.fill()

        let textRect = NSRect(
            x: layout.box.midX - layout.textSize.width / 2,
            y: layout.box.midY - layout.textSize.height / 2,
            width: layout.textSize.width,
            height: layout.textSize.height)
        (layout.text as NSString).draw(in: textRect, withAttributes: [
            .font: layout.font,
            .foregroundColor: NSColor.white,
        ])

        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()

        guard let stamped = context.makeImage() else { return image }
        return NSImage(cgImage: stamped, size: image.size)
    }

    private struct LabelLayout {
        let text: String
        let font: NSFont
        let textSize: NSSize
        let box: NSRect
    }

    /// Bottom-right label sized to the image. Very small crops are left alone.
    private static func labelLayout(text: String, imageSize: NSSize) -> LabelLayout? {
        let minSide = min(imageSize.width, imageSize.height)
        guard minSide >= 24 else { return nil }
        let margin = max(6, minSide * 0.02)
        let maximumWidth = imageSize.width - margin * 2
        let maximumHeight = imageSize.height - margin * 2
        guard maximumWidth > 8, maximumHeight > 8 else { return nil }

        var fontSize = min(max(minSide * 0.04, 10), 22)
        while fontSize >= 8 {
            let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            let boxSize = NSSize(
                width: textSize.width + max(6, fontSize * 0.5) * 2,
                height: textSize.height + max(3, fontSize * 0.3) * 2)
            if boxSize.width <= maximumWidth, boxSize.height <= maximumHeight {
                return LabelLayout(
                    text: text,
                    font: font,
                    textSize: textSize,
                    box: NSRect(
                        x: imageSize.width - margin - boxSize.width,
                        y: margin,
                        width: boxSize.width,
                        height: boxSize.height))
            }
            fontSize -= 1
        }
        return nil
    }

    private static func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func bitmapContext(width: Int, height: Int, colorSpace: CGColorSpace?) -> CGContext? {
        let (bytesPerRow, overflow) = width.multipliedReportingOverflow(by: 4)
        let space = colorSpace?.model == .rgb ? colorSpace : CGColorSpace(name: CGColorSpace.sRGB)
        guard width > 0, height > 0, !overflow, let space else { return nil }
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
