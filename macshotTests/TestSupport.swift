import Cocoa
import XCTest

// MARK: - Value description

/// Turns an arbitrary property value into a string that can be compared across
/// a clone or a serialization round-trip. AppKit reference types (colors,
/// images, attributed strings) get structural descriptions instead of identity.
enum FieldDescriber {

    static func describe(_ value: Any) -> String {
        // Unwrap optionals so `Optional(3)` and `3` compare equal.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let inner = mirror.children.first?.value else { return "nil" }
            return describe(inner)
        }

        switch value {
        case let color as NSColor:
            return describeColor(color)
        case let image as NSImage:
            return describeImage(image)
        case let attributed as NSAttributedString:
            // RTF round-trips glyphs faithfully but not every private attribute,
            // so compare the visible text plus the attribute runs' fonts.
            return "attr(\(attributed.string))"
        case let number as CGFloat:
            return describeDouble(Double(number))
        case let number as Double:
            return describeDouble(number)
        case let point as NSPoint:
            return "pt(\(describeDouble(point.x)),\(describeDouble(point.y)))"
        case let rect as NSRect:
            return "rect(\(describeDouble(rect.origin.x)),\(describeDouble(rect.origin.y)),"
                + "\(describeDouble(rect.width)),\(describeDouble(rect.height)))"
        case let points as [NSPoint]:
            return "[" + points.map { describe($0) }.joined(separator: ",") + "]"
        case let numbers as [CGFloat]:
            return "[" + numbers.map { describeDouble(Double($0)) }.joined(separator: ",") + "]"
        default:
            // Imported @objc enums (NSTextAlignment and friends) all describe
            // as their type name, so include the raw value to tell cases apart.
            if let raw = value as? any RawRepresentable {
                return "\(type(of: value)).\(String(describing: raw.rawValue))"
            }
            return String(describing: value)
        }
    }

    /// Rounds away float noise introduced by color-space conversion and JSON.
    private static func describeDouble(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        return String(format: "%.5f", value)
    }

    private static func describeColor(_ color: NSColor) -> String {
        guard let srgb = color.usingColorSpace(.sRGB) else { return "color(unconvertible)" }
        return "color(\(describeDouble(srgb.redComponent)),\(describeDouble(srgb.greenComponent)),"
            + "\(describeDouble(srgb.blueComponent)),\(describeDouble(srgb.alphaComponent)))"
    }

    /// Size plus a handful of sampled pixels — enough to notice a dropped or
    /// mangled image without depending on byte-identical re-encoding.
    private static func describeImage(_ image: NSImage) -> String {
        let size = "image(\(describeDouble(image.size.width))x\(describeDouble(image.size.height))"
        guard let bitmap = ImageProbe.bitmap(from: image) else { return size + ",nobitmap)" }
        let samples = ImageProbe.samplePoints(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            .map { ImageProbe.describePixel(bitmap: bitmap, x: $0.x, y: $0.y) }
            .joined(separator: "|")
        return size + ",\(bitmap.pixelsWide)x\(bitmap.pixelsHigh),\(samples))"
    }
}

// MARK: - Image helpers

enum ImageProbe {

    static func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        if let rep = image.representations.first as? NSBitmapImageRep { return rep }
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    static func samplePoints(width: Int, height: Int) -> [(x: Int, y: Int)] {
        guard width > 0, height > 0 else { return [] }
        let xs = [0, width / 3, width / 2, max(0, width - 1)]
        let ys = [0, height / 3, height / 2, max(0, height - 1)]
        return zip(xs, ys).map { (x: $0, y: $1) }
    }

    static func describePixel(bitmap: NSBitmapImageRep, x: Int, y: Int) -> String {
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
              let color = bitmap.colorAt(x: x, y: y) else { return "?" }
        // Raw sample values — converting to another color space here would
        // report a shift the file doesn't actually contain.
        // Quantize: re-encoding through PNG can move a channel by a hair.
        let q = { (v: CGFloat) in Int((v * 255).rounded()) / 4 }
        return "\(q(color.redComponent)),\(q(color.greenComponent)),\(q(color.blueComponent)),\(q(color.alphaComponent))"
    }

    /// Builds an image with an exact pixel buffer in sRGB. `lockFocus` would
    /// give a 2x buffer on a Retina Mac and a 1x buffer in CI, so fixtures are
    /// drawn through CGContext instead: same pixels on every machine.
    /// The context has AppKit's bottom-left origin.
    static func makeImage(width: Int, height: Int, draw: (CGContext) -> Void) -> NSImage {
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage(size: NSSize(width: max(width, 0), height: max(height, 0))) }
        draw(context)
        guard let cgImage = context.makeImage() else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// A deterministic test image: four solid quadrants, so scaling, cropping
    /// and flipping are all visible in a pixel probe. In image coordinates
    /// (y from the top): blue top-left, white top-right, red bottom-left,
    /// green bottom-right.
    static func quadrantImage(width: Int = 64, height: Int = 48) -> NSImage {
        makeImage(width: width, height: height) { context in
            let w = CGFloat(width) / 2
            let h = CGFloat(height) / 2
            let quadrants: [(CGRect, CGColor)] = [
                (CGRect(x: 0, y: 0, width: w, height: h), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
                (CGRect(x: w, y: 0, width: w, height: h), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
                (CGRect(x: 0, y: h, width: w, height: h), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
                (CGRect(x: w, y: h, width: w, height: h), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
            ]
            for (rect, color) in quadrants {
                context.setFillColor(color)
                context.fill(rect)
            }
        }
    }

    /// Solid-color image, useful when only the size or presence matters.
    static func solidImage(width: Int = 10, height: Int = 10,
                           color: CGColor = CGColor(srgbRed: 1, green: 0.2, blue: 0.6, alpha: 1)) -> NSImage {
        makeImage(width: width, height: height) { context in
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
    }

    /// Fully transparent image — nothing drawn into the context.
    static func transparentImage(width: Int = 10, height: Int = 10) -> NSImage {
        makeImage(width: width, height: height) { _ in }
    }

    /// Pixel probe. `y` counts from the TOP of the image, as `NSBitmapImageRep`
    /// does — not AppKit's bottom-left origin. The color carries the bitmap's
    /// own sample values; don't convert it to another space before comparing,
    /// or you'll measure the conversion instead of the file.
    static func pixelColor(_ image: NSImage, x: Int, y: Int) -> NSColor? {
        guard let bitmap = bitmap(from: image) else { return nil }
        return bitmap.colorAt(x: x, y: y)
    }
}

// MARK: - Reflection

enum Reflect {

    /// Stored properties of a class instance, in declaration order.
    static func storedProperties(of subject: Any) -> [(name: String, value: Any)] {
        Mirror(reflecting: subject).children.compactMap { child in
            guard let label = child.label else { return nil }
            return (name: label, value: child.value)
        }
    }

    static func propertyNames(of subject: Any) -> [String] {
        storedProperties(of: subject).map(\.name)
    }

    static func describedProperties(of subject: Any) -> [String: String] {
        var result: [String: String] = [:]
        for property in storedProperties(of: subject) {
            result[property.name] = FieldDescriber.describe(property.value)
        }
        return result
    }
}

// MARK: - Defaults isolation

extension XCTestCase {

    /// Runs `body` with the given UserDefaults keys set, restoring them after.
    /// Tests run in the xctest process, so this never touches the shipping app's
    /// preferences — but tests still shouldn't leak state into each other.
    func withDefaults(_ values: [String: Any?], _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        var previous: [String: Any?] = [:]
        for (key, value) in values {
            previous[key] = defaults.object(forKey: key)
            if let value = value as Any?, !(value is NSNull) {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defer {
            for (key, value) in previous {
                if let value = value as Any?, !(value is NSNull) {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        try body()
    }
}

// MARK: - Synthetic key events

enum TestKeyEvent {

    /// Key codes for the keys the app binds by character.
    enum Code {
        static let a: UInt16 = 0
        static let s: UInt16 = 1
        static let f: UInt16 = 3
        static let z: UInt16 = 6
        static let y: UInt16 = 16
        static let c: UInt16 = 8
        static let v: UInt16 = 9
        static let w: UInt16 = 13
        static let one: UInt16 = 18
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
    }

    static func keyDown(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        // `characters` doubles as charactersIgnoringModifiers: the matcher only
        // reads the latter, and tests care about the layout's base character.
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("could not synthesize key event for \(characters)")
        }
        return event
    }
}
