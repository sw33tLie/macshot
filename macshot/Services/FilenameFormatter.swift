import Foundation

enum FilenameFormatter {
    static let defaultTemplate = "Screenshot {date} at {time}"
    static let userDefaultsKey = "filenameTemplate"

    static let defaultRecordingTemplate = "Recording {date} at {time}"
    static let recordingUserDefaultsKey = "recordingFilenameTemplate"

    /// Optional template used instead of the main one when it contains `{app}`
    /// but no app is known (e.g. a whole-display capture). Empty or missing
    /// means "use the main template anyway".
    static let noAppUserDefaultsKey = "filenameTemplateNoApp"
    static let recordingNoAppUserDefaultsKey = "recordingFilenameTemplateNoApp"

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
    ///   {app}        name of the captured app, or "" when unknown
    ///   {yyyy} {MM} {dd} {HH} {mm} {ss} {ms}   date/time parts (ms = 000-999)
    ///
    /// Unknown tokens are left verbatim so typos are visible.
    /// The result is sanitized for macOS filesystems (strips `/`, `:`, NUL,
    /// control characters, surrounding whitespace and trailing dots), capped
    /// to 200 UTF-8 bytes without splitting a Unicode character.
    /// If the final result is empty, the default template is re-rendered.
    static func format(
        template: String,
        windowTitle: String? = nil,
        appName: String? = nil,
        index: Int? = nil,
        date: Date = Date(),
        fallback: String = defaultTemplate
    ) -> String {
        let effective = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : template
        let rendered = render(template: effective, windowTitle: windowTitle, appName: appName, index: index, date: date)
        let sanitized = FilenameSanitizer.sanitize(rendered)
        if sanitized.isEmpty && effective != fallback {
            return format(template: fallback, windowTitle: windowTitle, appName: appName, index: index, date: date, fallback: fallback)
        }
        return sanitized.isEmpty ? "Untitled" : sanitized
    }

    /// Like `format`, but each `/` in the template starts a subfolder, so
    /// `{yyyy}/{MM}/{dd}/{app}-{HH}.{mm}.{ss}` files captures by day.
    /// Returns sanitized path components; the last one is the filename
    /// (without extension). Empty, `.` and `..` components are dropped, so the
    /// result always stays inside the save folder.
    ///
    /// When the template uses `{app}` but `appName` is empty and a non-empty
    /// `noAppTemplate` is given, that template is rendered instead.
    static func formatRelativePath(
        template: String,
        noAppTemplate: String? = nil,
        windowTitle: String? = nil,
        appName: String? = nil,
        index: Int? = nil,
        date: Date = Date(),
        fallback: String = defaultTemplate
    ) -> [String] {
        var effective = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : template
        let hasApp = !(appName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !hasApp, effective.contains("{app}"),
           let noApp = noAppTemplate?.trimmingCharacters(in: .whitespacesAndNewlines), !noApp.isEmpty {
            effective = noApp
        }
        let pieces = effective.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var components: [String] = []
        for piece in pieces {
            let rendered = render(template: piece, windowTitle: windowTitle, appName: appName, index: index, date: date)
            let sanitized = FilenameSanitizer.sanitize(rendered)
            guard !sanitized.isEmpty, sanitized != ".", sanitized != ".." else { continue }
            components.append(sanitized)
        }
        if components.isEmpty {
            return [format(template: fallback, windowTitle: windowTitle, appName: appName, index: index, date: date, fallback: fallback)]
        }
        return components
    }

    /// Frontmost-app / window-owner name suitable for `{app}`: nil for macshot
    /// itself and for empty names.
    static func appNameForTemplate(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let ownName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        return trimmed == ownName ? nil : trimmed
    }

    private static func render(template: String, windowTitle: String?, appName: String?, index: Int?, date: Date) -> String {
        let dateStr = dateFormatter("yyyy-MM-dd").string(from: date)
        let timeStr = dateFormatter("HH-mm-ss").string(from: date)
        let window = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let app = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let millis = Int((date.timeIntervalSince1970 * 1000).rounded(.down)) % 1000

        let values: [String: String] = [
            "{date}": dateStr,
            "{time}": timeStr,
            "{timestamp}": "\(dateStr)_\(timeStr)",
            "{unix}": String(Int(date.timeIntervalSince1970)),
            "{window}": window,
            "{app}": app,
            "{index}": index.map(String.init) ?? "",
            "{yyyy}": dateFormatter("yyyy").string(from: date),
            "{MM}": dateFormatter("MM").string(from: date),
            "{dd}": dateFormatter("dd").string(from: date),
            "{HH}": dateFormatter("HH").string(from: date),
            "{mm}": dateFormatter("mm").string(from: date),
            "{ss}": dateFormatter("ss").string(from: date),
            "{ms}": String(format: "%03d", Int32(millis)),
        ]

        // Expand the template once. Inserted window titles are literal data,
        // even when a title itself contains a token such as {random} or {date}.
        var out = ""
        var cursor = template.startIndex
        while let open = template[cursor...].firstIndex(of: "{") {
            out += template[cursor..<open]
            guard let close = template[open...].firstIndex(of: "}") else {
                out += template[open...]
                cursor = template.endIndex
                break
            }
            let token = String(template[open...close])
            out += token == "{random}" ? randomToken() : (values[token] ?? token)
            cursor = template.index(after: close)
        }
        out += template[cursor...]
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

    /// Convenience: current user screenshot template + extension.
    static func defaultImageFilename(windowTitle: String? = nil, index: Int? = nil, fileExtension: String = ImageEncoder.fileExtension) -> String {
        let template = UserDefaults.standard.string(forKey: userDefaultsKey) ?? defaultTemplate
        let base = format(template: template, windowTitle: windowTitle, index: index)
        return "\(base).\(fileExtension)"
    }

    private static func dateFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}
