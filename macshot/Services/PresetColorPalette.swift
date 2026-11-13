import Cocoa

/// The preset swatches at the top of `ColorPickerView`, editable in Settings → Tools.
/// The list length is the user's choice (up to `maxCount`); the shipped colors are only the starting point.
enum PresetColorPalette {

    static let defaultsKey = "presetColors"

    /// Four rows of six in the picker. Every extra row adds 30pt to the popover, so an
    /// unbounded list would eventually push it off a small display.
    static let maxCount = 24

    static let defaultColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
        .systemPink, .white, .lightGray, .gray, .darkGray, .black,
    ]

    /// Stored as hex so a renamed or removed system color can't corrupt the list.
    /// Read leniently: a value that isn't an array means "unset", and entries that aren't
    /// valid hex strings (hand-edited or imported) are dropped without discarding the rest.
    static var colors: [NSColor] {
        guard let stored = UserDefaults.standard.array(forKey: defaultsKey) else {
            return defaultColors
        }
        let parsed = stored.compactMap { entry in (entry as? String).flatMap { NSColor(presetHex: $0) } }
        return Array(parsed.prefix(maxCount))
    }

    static func save(_ colors: [NSColor]) {
        UserDefaults.standard.set(colors.prefix(maxCount).compactMap { hex($0) }, forKey: defaultsKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// `nil` for colors with no sRGB equivalent (patterns), so they are skipped rather than stored as black.
    static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X",
                      Int(round(min(max(rgb.redComponent, 0), 1) * 255)),
                      Int(round(min(max(rgb.greenComponent, 0), 1) * 255)),
                      Int(round(min(max(rgb.blueComponent, 0), 1) * 255)))
    }
}

extension NSColor {
    convenience init?(presetHex hex: String) {
        // `UInt32(_:radix:)` alone would also accept a leading "+" or "-".
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit),
              let value = UInt32(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}
