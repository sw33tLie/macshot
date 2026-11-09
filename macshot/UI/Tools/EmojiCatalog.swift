import CoreText
import Foundation

/// Every emoji this Mac can draw, with names to search by (#473).
///
/// Built at first use from Unicode's emoji properties rather than a bundled
/// list, so new emoji appear as macOS adds them, and filtered by the emoji
/// font's coverage, so an older macOS never shows empty boxes. Sequences
/// joined with ZWJ (families, skin tones) aren't listed; flags are.
nonisolated enum EmojiCatalog {

    struct Entry: Equatable {
        let emoji: String
        /// Lowercased words to search (the Unicode name, or a country name).
        let name: String
    }

    static let all: [Entry] = build()

    /// Entries whose name contains every word of `query`, in catalog order.
    /// An emoji typed or pasted into the field finds itself.
    static func search(_ query: String, in entries: [Entry] = all) -> [Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let words = trimmed.lowercased().split(whereSeparator: \.isWhitespace)
        return entries.filter { entry in
            entry.emoji == trimmed || words.allSatisfy { entry.name.contains($0) }
        }
    }

    /// Code point ranges holding emoji (outside them only © and ®).
    private static let ranges: [ClosedRange<UInt32>] = [0x00A9...0x00AE, 0x203C...0x3299, 0x1F000...0x1FAFF]
    private static let regionalIndicators: ClosedRange<UInt32> = 0x1F1E6...0x1F1FF

    static func build(font: CTFont = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)) -> [Entry] {
        var entries: [Entry] = []
        var seen = Set<String>()
        func add(_ emoji: String, _ name: String) {
            guard seen.insert(emoji).inserted else { return }
            entries.append(Entry(emoji: emoji, name: name.lowercased()))
        }
        for range in ranges {
            for value in range {
                guard !regionalIndicators.contains(value), let scalar = Unicode.Scalar(value) else { continue }
                let properties = scalar.properties
                // Skin-tone swatches only make sense attached to another emoji.
                guard properties.isEmoji, !properties.isEmojiModifier, canDraw(String(scalar), font: font) else { continue }
                // Text-style symbols (☀, ❤) need the emoji variation selector
                // to be drawn in color.
                let emoji = properties.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
                add(emoji, properties.name ?? "")
            }
        }
        let english = Locale(identifier: "en")
        for region in Locale.isoRegionCodes where region.count == 2 {
            let flag = region.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 - 0x41 + $0.value) }
                .reduce(into: "") { $0.unicodeScalars.append($1) }
            guard flag.unicodeScalars.count == 2, canDraw(flag, font: font) else { continue }
            let names = [english.localizedString(forRegionCode: region), Locale.current.localizedString(forRegionCode: region)]
            add(flag, (["flag", region] + names.compactMap { $0 }).joined(separator: " "))
        }
        return entries
    }

    /// Whether the emoji font has a glyph for every scalar of `text`.
    static func canDraw(_ text: String, font: CTFont) -> Bool {
        var characters = Array(text.unicodeScalars.filter { $0.value != 0xFE0F }.map(String.init).joined().utf16)
        guard !characters.isEmpty else { return false }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
    }
}
