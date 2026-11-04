import Cocoa

/// The preset swatches at the top of `ColorPickerView`, editable in Settings → Tools.
/// The list length is the user's choice; the shipped colors are only the starting point.
enum PresetColorPalette {

    static let defaultsKey = "presetColors"

    static let defaultColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple,
        .systemPink, .white, .lightGray, .gray, .darkGray, .black,
    ]

    /// Stored as hex so a renamed or removed system color can't corrupt the list.
    static var colors: [NSColor] {
        guard let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [String] else {
            return defaultColors
        }
        return stored.compactMap { NSColor(presetHex: $0) }
    }

    static func save(_ colors: [NSColor]) {
        UserDefaults.standard.set(colors.map(hex), forKey: defaultsKey)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    private static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "000000" }
        return String(format: "%02X%02X%02X",
                      Int(round(rgb.redComponent * 255)),
                      Int(round(rgb.greenComponent * 255)),
                      Int(round(rgb.blueComponent * 255)))
    }
}

extension NSColor {
    convenience init?(presetHex hex: String) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}
