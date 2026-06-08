import AppKit

enum ClipboardTextPinRenderer {

    private static let padding = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
    private static let plainFont = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
    private static let maxPointArea: CGFloat = 24_000_000
    private static let importedListBlockSpacing: CGFloat = 12
    private static let importedTableBlockSpacing: CGFloat = 8
    private static let maxImportedParagraphSpacing: CGFloat = 8

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

        let mutable = NSMutableAttributedString(attributedString: attributed)
        normalizeImportedListMarkers(in: mutable)
        removeRedundantImportedBlankParagraphs(in: mutable)
        restoreSpacingAfterImportedTables(in: mutable)
        capImportedParagraphSpacing(in: mutable)
        trimTrailingImportedLineBreaks(in: mutable)

        let documentAttributesDict = documentAttributes as? [NSAttributedString.DocumentAttributeKey: Any]
        guard let backgroundColor = documentAttributesDict?[.backgroundColor] as? NSColor,
              mutable.length > 0 else {
            return mutable
        }

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

    static func containsAttachments(_ attributed: NSAttributedString) -> Bool {
        var found = false
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.attachment, in: fullRange) { value, _, stop in
            if value is NSTextAttachment {
                found = true
                stop.pointee = true
            }
        }
        return found
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

        if imageWidth * imageHeight > maxPointArea {
            let scale = sqrt(maxPointArea / (imageWidth * imageHeight))
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

    private static func trimTrailingImportedLineBreaks(in attributed: NSMutableAttributedString) {
        while attributed.length > 0 {
            let lastRange = NSRange(location: attributed.length - 1, length: 1)
            let lastCharacter = (attributed.string as NSString).substring(with: lastRange)
            guard lastCharacter.rangeOfCharacter(from: .newlines) != nil else { break }
            attributed.deleteCharacters(in: lastRange)
        }
    }

    private static func removeRedundantImportedBlankParagraphs(in attributed: NSMutableAttributedString) {
        let nsString = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var paragraphs: [(paragraph: NSRange, enclosing: NSRange)] = []

        nsString.enumerateSubstrings(in: fullRange, options: [.byParagraphs, .substringNotRequired]) { _, paragraphRange, enclosingRange, _ in
            paragraphs.append((paragraphRange, enclosingRange))
        }

        for index in paragraphs.indices.reversed() {
            let current = paragraphs[index]
            guard current.paragraph.length == 0,
                  index > 0,
                  index + 1 < paragraphs.count,
                  paragraphs[index - 1].paragraph.length > 0,
                  paragraphs[index + 1].paragraph.length > 0,
                  hasParagraphSpacing(at: paragraphs[index - 1].paragraph.location, in: attributed),
                  current.enclosing.location + current.enclosing.length <= attributed.length else {
                continue
            }
            attributed.deleteCharacters(in: current.enclosing)
        }
    }

    private static func hasParagraphSpacing(at location: Int, in attributed: NSAttributedString) -> Bool {
        guard attributed.length > 0 else { return false }
        let safeLocation = min(location, attributed.length - 1)
        guard let style = attributed.attribute(.paragraphStyle, at: safeLocation, effectiveRange: nil) as? NSParagraphStyle else {
            return false
        }
        return style.paragraphSpacing > 0 || style.paragraphSpacingBefore > 0
    }

    private static func capImportedParagraphSpacing(in attributed: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            guard let paragraph = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }

            var changed = false
            if paragraph.paragraphSpacing > maxImportedParagraphSpacing {
                paragraph.paragraphSpacing = maxImportedParagraphSpacing
                changed = true
            }
            if paragraph.paragraphSpacingBefore > maxImportedParagraphSpacing {
                paragraph.paragraphSpacingBefore = maxImportedParagraphSpacing
                changed = true
            }

            if changed {
                attributed.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
        }
    }

    private static func restoreSpacingAfterImportedTables(in attributed: NSMutableAttributedString) {
        let nsString = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var paragraphs: [(paragraph: NSRange, enclosing: NSRange, isTable: Bool)] = []

        nsString.enumerateSubstrings(in: fullRange, options: [.byParagraphs, .substringNotRequired]) { _, paragraphRange, enclosingRange, _ in
            let isTable = paragraphRange.length > 0 && isTableParagraph(at: paragraphRange.location, in: attributed)
            paragraphs.append((paragraphRange, enclosingRange, isTable))
        }

        for index in paragraphs.indices {
            let current = paragraphs[index]
            guard current.isTable,
                  let next = nextNonEmptyParagraph(after: index, in: paragraphs),
                  !next.isTable else {
                continue
            }

            applyParagraphSpacing(
                importedTableBlockSpacing,
                at: current.enclosing,
                in: attributed
            )
            applyParagraphSpacingBefore(
                importedTableBlockSpacing,
                at: next.enclosing,
                in: attributed
            )
        }
    }

    private static func nextNonEmptyParagraph(
        after index: Int,
        in paragraphs: [(paragraph: NSRange, enclosing: NSRange, isTable: Bool)]
    ) -> (paragraph: NSRange, enclosing: NSRange, isTable: Bool)? {
        guard index + 1 < paragraphs.count else { return nil }
        for nextIndex in (index + 1)..<paragraphs.count where paragraphs[nextIndex].paragraph.length > 0 {
            return paragraphs[nextIndex]
        }
        return nil
    }

    private static func isTableParagraph(at location: Int, in attributed: NSAttributedString) -> Bool {
        guard attributed.length > 0 else { return false }
        let safeLocation = min(location, attributed.length - 1)
        guard let style = attributed.attribute(.paragraphStyle, at: safeLocation, effectiveRange: nil) as? NSParagraphStyle else {
            return false
        }
        return style.textBlocks.contains { $0 is NSTextTableBlock }
    }

    private static func applyParagraphSpacing(
        _ spacing: CGFloat,
        at range: NSRange,
        in attributed: NSMutableAttributedString
    ) {
        guard range.location < attributed.length,
              let paragraph = (attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle else {
            return
        }

        paragraph.paragraphSpacing = max(paragraph.paragraphSpacing, spacing)
        let safeRange = NSRange(
            location: range.location,
            length: min(range.length, attributed.length - range.location)
        )
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: safeRange)
    }

    private static func applyParagraphSpacingBefore(
        _ spacing: CGFloat,
        at range: NSRange,
        in attributed: NSMutableAttributedString
    ) {
        guard range.location < attributed.length,
              let paragraph = (attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle else {
            return
        }

        paragraph.paragraphSpacingBefore = max(paragraph.paragraphSpacingBefore, spacing)
        let safeRange = NSRange(
            location: range.location,
            length: min(range.length, attributed.length - range.location)
        )
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: safeRange)
    }

    private static func normalizeImportedListMarkers(in attributed: NSMutableAttributedString) {
        let nsString = attributed.string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var paragraphRanges: [NSRange] = []

        nsString.enumerateSubstrings(in: fullRange, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosingRange, _ in
            paragraphRanges.append(enclosingRange)
        }

        let listParagraphs = paragraphRanges.map { isImportedListParagraph(at: $0, in: attributed) }
        for index in paragraphRanges.indices.reversed() {
            let range = paragraphRanges[index]
            guard range.location < attributed.length else { continue }

            let hasFollowingParagraph = index + 1 < paragraphRanges.count
            let isEndOfListBlock = listParagraphs[index] && hasFollowingParagraph && !listParagraphs[index + 1]
            normalizeImportedListMarker(
                in: range,
                attributed: attributed,
                addsBlockEndSpacing: isEndOfListBlock
            )
        }
    }

    private static func isImportedListParagraph(at range: NSRange, in attributed: NSAttributedString) -> Bool {
        guard range.location < attributed.length,
              let paragraph = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle else {
            return false
        }
        return !paragraph.textLists.isEmpty
    }

    private static func normalizeImportedListMarker(
        in range: NSRange,
        attributed: NSMutableAttributedString,
        addsBlockEndSpacing: Bool
    ) {
        guard let paragraph = attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
              let textList = paragraph.textLists.last else {
            return
        }

        let paragraphText = (attributed.string as NSString).substring(with: range)
        guard paragraphText.hasPrefix("\t"),
              let secondTabIndex = paragraphText.dropFirst().firstIndex(of: "\t") else {
            return
        }

        let markerStart = paragraphText.index(after: paragraphText.startIndex)
        let marker = String(paragraphText[markerStart..<secondTabIndex])
        let markerStartOffset = markerStart.utf16Offset(in: paragraphText)
        let markerEndOffset = secondTabIndex.utf16Offset(in: paragraphText)
        let markerLocation = range.location + markerStartOffset
        let markerLength = markerEndOffset - markerStartOffset
        guard markerLength > 0, markerLocation + markerLength <= attributed.length else { return }

        let style = (paragraph.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.textLists = []
        if addsBlockEndSpacing {
            style.paragraphSpacing = max(style.paragraphSpacing, importedListBlockSpacing)
        }

        let attributesLocation = min(markerLocation, max(range.location, attributed.length - 1))
        var attributes = attributed.attributes(at: attributesLocation, effectiveRange: nil)
        attributes[.paragraphStyle] = style

        let displayMarker = displayListMarker(marker, textList: textList)
        let replacement = NSAttributedString(string: displayMarker, attributes: attributes)
        attributed.replaceCharacters(
            in: NSRange(location: markerLocation, length: markerLength),
            with: replacement
        )

        let adjustedRange = NSRange(
            location: range.location,
            length: range.length - markerLength + replacement.length
        )
        attributed.addAttribute(.paragraphStyle, value: style, range: adjustedRange)
    }

    private static func displayListMarker(_ marker: String, textList: NSTextList) -> String {
        let trimmed = marker.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return marker }
        guard isOrderedListMarker(trimmed, textList: textList),
              !trimmed.hasSuffix("."),
              !trimmed.hasSuffix(")") else {
            return trimmed
        }
        return "\(trimmed)."
    }

    private static func isOrderedListMarker(_ marker: String, textList: NSTextList) -> Bool {
        let markerFormat = String(describing: textList.markerFormat).lowercased()
        if markerFormat.contains("decimal")
            || markerFormat.contains("upper")
            || markerFormat.contains("lower")
            || markerFormat.contains("roman")
            || markerFormat.contains("alpha") {
            return true
        }

        return marker.range(of: #"^\d+$"#, options: .regularExpression) != nil
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
            guard let color = value as? NSColor,
                  let resolved = color.usingColorSpace(.sRGB),
                  resolved.alphaComponent > 0.01 else { return }
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
