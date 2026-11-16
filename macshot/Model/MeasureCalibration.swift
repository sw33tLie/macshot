import Foundation

/// Real-world units the measure tool can show once an image has a scale.
nonisolated enum MeasureUnit: String, CaseIterable, Codable, Sendable {
    case millimeters = "mm"
    case centimeters = "cm"
    case meters = "m"
    case inches = "in"
    case feet = "ft"

    var symbol: String { rawValue }

    /// Length of one unit in millimetres.
    var millimeters: Double {
        switch self {
        case .millimeters: return 1
        case .centimeters: return 10
        case .meters: return 1000
        case .inches: return 25.4
        case .feet: return 304.8
        }
    }

    var isImperial: Bool { self == .inches || self == .feet }

    func convert(_ value: Double, to unit: MeasureUnit) -> Double {
        value * millimeters / unit.millimeters
    }
}

/// A length typed by the user, in the unit they typed (or chose).
nonisolated struct MeasureLength: Equatable, Sendable {
    var value: Double
    var unit: MeasureUnit
}

/// Image-wide scale for the measure tool: how many canvas points make one
/// `unit`. Set from a measured line of known real length. Measurements made
/// this way are estimates (perspective, lens distortion), which the UI says.
nonisolated struct MeasureCalibration: Codable, Equatable, Sendable {
    /// Canvas points that correspond to one `unit`.
    var pointsPerUnit: Double
    var unit: MeasureUnit

    init(pointsPerUnit: Double, unit: MeasureUnit) {
        self.pointsPerUnit = pointsPerUnit
        self.unit = unit
    }

    /// Scale from a reference line `referencePoints` canvas points long that
    /// represents `length` in the real world. Nil when either side is unusable.
    init?(referencePoints: Double, length: MeasureLength) {
        guard referencePoints.isFinite, referencePoints >= 1,
              length.value.isFinite, length.value > 0 else { return nil }
        self.init(pointsPerUnit: referencePoints / length.value, unit: length.unit)
        guard isValid else { return nil }
    }

    var isValid: Bool {
        pointsPerUnit.isFinite && pointsPerUnit >= 1e-6 && pointsPerUnit <= 1e9
    }

    /// Real-world length of `points` canvas points, in `unit`.
    func length(ofPoints points: Double) -> Double {
        points / pointsPerUnit
    }

    /// The same scale expressed in another unit.
    func converted(to newUnit: MeasureUnit) -> MeasureCalibration {
        MeasureCalibration(pointsPerUnit: pointsPerUnit * newUnit.millimeters / unit.millimeters, unit: newUnit)
    }

    func format(points: Double, locale: Locale = .current) -> String {
        MeasureLengthFormatter.string(for: length(ofPoints: points), unit: unit, locale: locale)
    }

    enum CodingKeys: String, CodingKey { case pointsPerUnit, unit }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pointsPerUnit = c.decode(.pointsPerUnit, or: 0)
        // An unknown unit from a newer build drops the scale rather than
        // showing numbers in the wrong unit.
        guard let unit: MeasureUnit = c.decodeOptional(.unit) else {
            throw DecodingError.dataCorruptedError(forKey: .unit, in: c, debugDescription: "Unknown unit")
        }
        self.unit = unit
        guard isValid else {
            throw DecodingError.dataCorruptedError(forKey: .pointsPerUnit, in: c, debugDescription: "Invalid scale")
        }
    }
}

nonisolated enum MeasureLengthFormatter {
    /// "12.5 mm", "1.25 m", "3 1/2 in", "4 ft 3 1/4 in".
    /// Imperial lengths use sixteenths, as on a tape measure.
    static func string(for value: Double, unit: MeasureUnit, locale: Locale = .current) -> String {
        guard value.isFinite else { return "–" }
        let v = abs(value)
        switch unit {
        case .inches:
            return inchString(v, locale: locale)
        case .feet:
            let totalSixteenths = Int((v * 12 * 16).rounded())
            let feet = totalSixteenths / (12 * 16)
            let remainder = Double(totalSixteenths - feet * 12 * 16) / 16
            if feet == 0 { return inchString(remainder, locale: locale) }
            if remainder == 0 { return "\(feet) ft" }
            return "\(feet) ft \(inchString(remainder, locale: locale))"
        default:
            let digits = v >= 100 ? 0 : (v >= 10 ? 1 : 2)
            return "\(decimal(v, digits: digits, locale: locale)) \(unit.symbol)"
        }
    }

    private static func inchString(_ inches: Double, locale: Locale) -> String {
        let sixteenths = Int((inches * 16).rounded())
        let whole = sixteenths / 16
        var numerator = sixteenths % 16
        var denominator = 16
        while numerator > 0 && numerator % 2 == 0 {
            numerator /= 2
            denominator /= 2
        }
        if numerator == 0 { return "\(whole) in" }
        if whole == 0 { return "\(numerator)/\(denominator) in" }
        return "\(whole) \(numerator)/\(denominator) in"
    }

    static func decimal(_ value: Double, digits: Int, locale: Locale = .current) -> String {
        // Labels redraw on every drag step; reuse one formatter per locale and
        // precision instead of building a NumberFormatter each time.
        let key = "\(locale.identifier)|\(digits)"
        formatterLock.lock()
        defer { formatterLock.unlock() }
        let formatter: NumberFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.minimumFractionDigits = digits
            formatter.maximumFractionDigits = digits
            formatters[key] = formatter
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    private static let formatterLock = NSLock()
    nonisolated(unsafe) private static var formatters: [String: NumberFormatter] = [:]
}

/// Parses lengths as people type them: "90", "90 mm", "3.5in", "3,5 cm",
/// "3 1/2 in", "3-1/2\"", "3½", "1/2", "6' 2\"", "6 ft 2 1/2 in".
nonisolated enum MeasureLengthParser {
    private static let unitWords: [(String, MeasureUnit)] = [
        ("millimeters", .millimeters), ("millimetres", .millimeters), ("millimeter", .millimeters),
        ("millimetre", .millimeters), ("mm", .millimeters),
        ("centimeters", .centimeters), ("centimetres", .centimeters), ("centimeter", .centimeters),
        ("centimetre", .centimeters), ("cm", .centimeters),
        ("meters", .meters), ("metres", .meters), ("meter", .meters), ("metre", .meters), ("m", .meters),
        ("inches", .inches), ("inch", .inches), ("in", .inches), ("\"", .inches), ("″", .inches),
        ("”", .inches),
        ("feet", .feet), ("foot", .feet), ("ft", .feet), ("'", .feet), ("′", .feet), ("’", .feet),
    ]

    private static let vulgarFractions: [Character: Double] = [
        "½": 0.5, "¼": 0.25, "¾": 0.75, "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875,
        "⅓": 1.0 / 3, "⅔": 2.0 / 3, "⅕": 0.2, "⅖": 0.4, "⅗": 0.6, "⅘": 0.8,
        "⅙": 1.0 / 6, "⅚": 5.0 / 6, "⅒": 0.1,
    ]

    static func parse(_ text: String, defaultUnit: MeasureUnit) -> MeasureLength? {
        var parts: [(Double, MeasureUnit?)] = []
        var rest = Substring(text.lowercased())
        while true {
            rest = rest.drop(while: { $0.isWhitespace })
            if rest.isEmpty { break }
            guard let (number, afterNumber) = parseNumber(rest) else { return nil }
            rest = afterNumber.drop(while: { $0.isWhitespace })
            var unit: MeasureUnit?
            for (word, candidate) in unitWords where rest.hasPrefix(word) {
                let after = rest.dropFirst(word.count)
                // "m" must not swallow the start of an unknown word.
                if let next = after.first, next.isLetter { continue }
                unit = candidate
                rest = after
                break
            }
            parts.append((number, unit))
            // A trailing "." or "," after a unit ("90 mm.") is harmless.
            rest = rest.drop(while: { $0.isWhitespace || $0 == "." || $0 == "," })
        }
        guard !parts.isEmpty else { return nil }

        let value: Double
        let unit: MeasureUnit
        if parts.count == 1 {
            value = parts[0].0
            unit = parts[0].1 ?? defaultUnit
        } else {
            // Compound lengths only make sense from larger to smaller units
            // ("6 ft 2 in"); a missing last unit continues the sequence.
            let first = parts[0].1 ?? defaultUnit
            unit = first
            var total = 0.0
            var previous: MeasureUnit?
            for (index, part) in parts.enumerated() {
                let partUnit: MeasureUnit
                if let explicit = part.1 {
                    partUnit = explicit
                } else if index == parts.count - 1, previous == .feet {
                    partUnit = .inches
                } else {
                    return nil
                }
                if let previous, partUnit.millimeters >= previous.millimeters { return nil }
                previous = partUnit
                total += partUnit.convert(part.0, to: unit)
            }
            value = total
        }
        guard value.isFinite, value > 0 else { return nil }
        return MeasureLength(value: value, unit: unit)
    }

    /// A whole/decimal number, optionally followed by a fraction
    /// ("3 1/2", "3-1/2", "3½") or a bare fraction ("1/2").
    private static func parseNumber(_ input: Substring) -> (Double, Substring)? {
        var rest = input
        if let first = rest.first, let fraction = vulgarFractions[first] {
            return (fraction, rest.dropFirst())
        }
        guard let (whole, afterWhole) = parseDecimal(rest) else { return nil }
        rest = afterWhole
        // "1/2" directly
        if rest.first == "/" || rest.first == "⁄" {
            guard whole.rounded() == whole,
                  let (denominator, afterDenominator) = parseInteger(rest.dropFirst()), denominator > 0
            else { return nil }
            return (whole / denominator, afterDenominator)
        }
        if let first = rest.first, let fraction = vulgarFractions[first] {
            return (whole + fraction, rest.dropFirst())
        }
        // "3 1/2" or "3-1/2"
        let separatorTrimmed = rest.drop(while: { $0 == " " || $0 == "-" })
        if separatorTrimmed.startIndex != rest.startIndex, whole.rounded() == whole,
           let (numerator, afterNumerator) = parseInteger(separatorTrimmed),
           afterNumerator.first == "/" || afterNumerator.first == "⁄",
           let (denominator, afterDenominator) = parseInteger(afterNumerator.dropFirst()),
           denominator > 0, numerator < denominator {
            return (whole + numerator / denominator, afterDenominator)
        }
        if let first = separatorTrimmed.first, separatorTrimmed.startIndex != rest.startIndex,
           let fraction = vulgarFractions[first] {
            return (whole + fraction, separatorTrimmed.dropFirst())
        }
        return (whole, rest)
    }

    private static func parseInteger(_ input: Substring) -> (Double, Substring)? {
        let digits = input.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9, let value = Double(digits) else { return nil }
        return (value, input.dropFirst(digits.count))
    }

    /// Accepts "." or "," as the decimal separator.
    private static func parseDecimal(_ input: Substring) -> (Double, Substring)? {
        let digits = input.prefix(while: { $0.isASCII && $0.isNumber })
        var rest = input.dropFirst(digits.count)
        var text = String(digits)
        if let separator = rest.first, separator == "." || separator == "," {
            let fraction = rest.dropFirst().prefix(while: { $0.isASCII && $0.isNumber })
            if !fraction.isEmpty {
                text += "." + fraction
                rest = rest.dropFirst(1 + fraction.count)
            }
        }
        guard !text.isEmpty, text.count <= 15, let value = Double(text) else { return nil }
        return (value, rest)
    }
}
