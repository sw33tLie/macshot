import Foundation

enum FilenameFormatter {
    static let defaultTemplate = "Screenshot {date} at {time}"
    static let userDefaultsKey = "filenameTemplate"

    static let defaultRecordingTemplate = "Recording {date} at {time}"
    static let recordingUserDefaultsKey = "recordingFilenameTemplate"

    /// Renders a filename *without* extension from a user-editable template.
    ///
    /// Supported tokens (case-sensitive, lowercase):
    ///   {date}       yyyy-MM-dd
    ///   {time}       HH-mm-ss
    ///   {timestamp}  {date}_{time}
    ///   {unix}       epoch seconds
    ///   {window}     sanitized window title, or "" when nil/empty
    ///   {index}      1, 2, …; "" when nil
    ///   {random}     8-char lowercase base36 (0-9a-z), fresh per call
    ///
    /// Unknown tokens are left verbatim so typos are visible.
    /// The result is sanitized for macOS filesystems (strips `/`, `:`, NUL,
    /// leading/trailing whitespace and dots) and capped to 200 UTF-8 bytes.
    /// If the final result is empty, the default template is re-rendered.
    static func format(
        template: String,
        windowTitle: String? = nil,
        index: Int? = nil,
        date: Date = Date(),
        fallback: String = defaultTemplate
    ) -> String {
        let effective = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : template
        let rendered = render(template: effective, windowTitle: windowTitle, index: index, date: date)
        let sanitized = sanitize(rendered)
        if sanitized.isEmpty && effective != fallback {
            return format(template: fallback, windowTitle: windowTitle, index: index, date: date, fallback: fallback)
        }
        return sanitized.isEmpty ? "Untitled" : sanitized
    }

    private static func render(template: String, windowTitle: String?, index: Int?, date: Date) -> String {
        let dateStr = dateFormatter("yyyy-MM-dd").string(from: date)
        let timeStr = dateFormatter("HH-mm-ss").string(from: date)
        let window = sanitizeWindowTitle(windowTitle)

        let values: [String: String] = [
            "{date}": dateStr,
            "{time}": timeStr,
            "{timestamp}": "\(dateStr)_\(timeStr)",
            "{unix}": String(Int(date.timeIntervalSince1970)),
            "{window}": window,
            "{index}": index.map(String.init) ?? "",
        ]

        var out = template
        for (token, value) in values {
            out = out.replacingOccurrences(of: token, with: value)
        }
        // {random} is substituted per-occurrence so multiple tokens in one
        // template (rare but cheap to support) produce distinct values.
        while let range = out.range(of: "{random}") {
            out.replaceSubrange(range, with: randomToken())
        }
        return out
    }

    private static let randomAlphabet: [Character] = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    private static func randomToken(length: Int = 8) -> String {
        var s = ""
        s.reserveCapacity(length)
        for _ in 0..<length {
            s.append(randomAlphabet[Int.random(in: 0..<randomAlphabet.count)])
        }
        return s
    }

    private static func sanitizeWindowTitle(_ title: String?) -> String {
        guard let title = title else { return "" }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        var cleaned = ""
        cleaned.reserveCapacity(trimmed.count)
        for scalar in trimmed.unicodeScalars {
            switch scalar {
            case "/", ":", "\0":
                cleaned.append("-")
            default:
                if scalar.value < 0x20 { continue } // strip control chars
                cleaned.unicodeScalars.append(scalar)
            }
        }
        return cleaned
    }

    /// Final pass on the fully-rendered filename.
    private static func sanitize(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "/", ":", "\0":
                result.append("-")
            default:
                if scalar.value < 0x20 { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        // Trim whitespace and trailing dots (macOS hides trailing dots).
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(".") { result.removeLast() }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return capToByteLength(result, bytes: 200)
    }

    /// Truncates at a Unicode scalar boundary so the UTF-8 byte count ≤ `bytes`.
    private static func capToByteLength(_ s: String, bytes: Int) -> String {
        if s.utf8.count <= bytes { return s }
        var out = ""
        var used = 0
        for scalar in s.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            if used + scalarBytes > bytes { break }
            out.unicodeScalars.append(scalar)
            used += scalarBytes
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Convenience: current user screenshot template + extension.
    static func defaultImageFilename(windowTitle: String? = nil, index: Int? = nil) -> String {
        let template = UserDefaults.standard.string(forKey: userDefaultsKey) ?? defaultTemplate
        let base = format(template: template, windowTitle: windowTitle, index: index)
        return "\(base).\(ImageEncoder.fileExtension)"
    }

    private static func dateFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}
