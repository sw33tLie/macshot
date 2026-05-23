import AppKit

enum ClipboardTextPinRenderer {

    private static let padding = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
    private static let plainFont = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
    private static let maxPixelArea: CGFloat = 24_000_000

    static func attributedString(html data: Data) -> NSAttributedString? {
        attributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
        )
    }

    static func attributedString(rtf data: Data) -> NSAttributedString? {
        attributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    static func attributedString(rtfd data: Data) -> NSAttributedString? {
        attributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
    }

    private static func attributedString(
        data: Data,
        options: [NSAttributedString.DocumentReadingOptionKey: Any]
    ) -> NSAttributedString? {
        var documentAttributes: NSDictionary?
        guard let attributed = try? NSAttributedString(
            data: data,
            options: options,
            documentAttributes: &documentAttributes
        ) else { return nil }

        let documentAttributesDict = documentAttributes as? [NSAttributedString.DocumentAttributeKey: Any]
        guard let backgroundColor = documentAttributesDict?[.backgroundColor] as? NSColor,
              attributed.length > 0 else {
            return attributed
        }

        let mutable = NSMutableAttributedString(attributedString: attributed)
        mutable.addAttribute(.backgroundColor, value: backgroundColor, range: NSRange(location: 0, length: mutable.length))
        return mutable
    }

    static func plainAttributedString(_ string: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .left

        return NSAttributedString(
            string: string,
            attributes: [
                .font: plainFont,
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph,
            ]
        )
    }

    static func render(_ attributed: NSAttributedString, fallbackBackground: NSColor = .white) -> NSImage? {
        guard attributed.length > 0 else { return nil }

        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxContentWidth = max(320, min(980, screenFrame.width * 0.72))
        let maxImageHeight = max(240, screenFrame.height * 0.82)

        let normalized = NSMutableAttributedString(attributedString: attributed)
        normalizeParagraphs(in: normalized)

        let contentSize = measuredSize(for: normalized, maxWidth: maxContentWidth)
        guard contentSize.width > 0, contentSize.height > 0 else { return nil }

        var imageWidth = ceil(contentSize.width + padding.left + padding.right)
        var imageHeight = ceil(contentSize.height + padding.top + padding.bottom)

        if imageHeight > maxImageHeight {
            imageHeight = maxImageHeight
        }

        if imageWidth * imageHeight > maxPixelArea {
            let scale = sqrt(maxPixelArea / (imageWidth * imageHeight))
            imageWidth = max(320, floor(imageWidth * scale))
            imageHeight = max(180, floor(imageHeight * scale))
        }

        let imageSize = NSSize(width: imageWidth, height: imageHeight)
        let drawRect = NSRect(
            x: padding.left,
            y: padding.top,
            width: max(1, imageWidth - padding.left - padding.right),
            height: max(1, imageHeight - padding.top - padding.bottom)
        )

        return NSImage(size: imageSize, flipped: true) { rect in
            let background = dominantBackgroundColor(in: normalized) ?? fallbackBackground
            background.setFill()
            NSBezierPath(rect: rect).fill()

            normalized.draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            return true
        }
    }

    private static func normalizeParagraphs(in attributed: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }

        attributed.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            if value == nil {
                attributed.addAttribute(.font, value: plainFont, range: range)
            }
        }

        attributed.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            if value == nil {
                attributed.addAttribute(.foregroundColor, value: NSColor.black, range: range)
            }
        }
    }

    private static func measuredSize(for attributed: NSAttributedString, maxWidth: CGFloat) -> NSSize {
        let rect = attributed.boundingRect(
            with: NSSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return NSSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    private static func dominantBackgroundColor(in attributed: NSAttributedString) -> NSColor? {
        let fullRange = NSRange(location: 0, length: attributed.length)
        var counts: [String: (color: NSColor, length: Int)] = [:]

        attributed.enumerateAttribute(.backgroundColor, in: fullRange) { value, range, _ in
            guard let color = value as? NSColor, color.alphaComponent > 0.01 else { return }
            let resolved = color.usingColorSpace(.sRGB) ?? color
            let key = String(
                format: "%.3f:%.3f:%.3f:%.3f",
                resolved.redComponent,
                resolved.greenComponent,
                resolved.blueComponent,
                resolved.alphaComponent
            )
            var entry = counts[key] ?? (resolved, 0)
            entry.length += range.length
            counts[key] = entry
        }

        return counts.values.max { $0.length < $1.length }?.color
    }
}
