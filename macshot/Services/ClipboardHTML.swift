import Foundation

/// Parse locally, then generate a small formatting-only document. No source
/// element, attribute, CSS declaration or document declaration is forwarded
/// wholesale to AppKit's WebKit-backed attributed-string importer.
enum ClipboardHTML {
    nonisolated static let maximumInputBytes = 2 * 1024 * 1024

    nonisolated static func sanitized(_ data: Data, maximumCharacters: Int) -> Data {
        guard !data.isEmpty, data.count <= maximumInputBytes, maximumCharacters > 0,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1),
              // Clipboard formatting never needs custom entity declarations.
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
              let document = try? XMLDocument(data: Data(text.utf8),
                options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = document.rootElement() else { return Data() }
        var remaining = maximumCharacters
        var nodes = 20_000
        var clipped = false
        let tags: Set<String> = ["p", "div", "span", "b", "strong", "i", "em", "u", "s", "del", "strike",
            "sub", "sup", "code", "pre", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li",
            "table", "thead", "tbody", "tfoot", "tr", "td", "th", "br", "hr"]
        let excluded: Set<String> = ["head", "script", "style", "iframe", "object", "embed", "video", "audio",
            "picture", "img", "link", "source", "track", "input", "svg", "math", "template"]

        func render(_ node: XMLNode, depth: Int) -> String {
            guard depth <= 64, nodes > 0, remaining > 0 else { clipped = true; return "" }
            nodes -= 1
            if node.kind == .text {
                let value = node.stringValue ?? ""
                let string = value as NSString
                let count: Int
                if string.length <= remaining { count = string.length }
                else {
                    count = string.rangeOfComposedCharacterSequence(at: remaining).location
                    clipped = true
                }
                remaining -= count
                return escape(string.substring(to: count))
            }
            guard let element = node as? XMLElement else { return "" }
            let name = (element.localName ?? element.name ?? "").lowercased()
            if excluded.contains(name) { return "" }
            let children = (element.children ?? []).map { render($0, depth: depth + 1) }.joined()
            let tag = name == "font" || name == "a" ? "span" : name
            guard tags.contains(tag) else { return children }
            var attributes = ""
            let style = safeStyle(element.attribute(forName: "style")?.stringValue ?? "")
            var declarations = style.isEmpty ? [] : [style]
            if let color = element.attribute(forName: "color")?.stringValue, let value = safeColor(color) {
                declarations.append("color:" + value)
            }
            if let color = element.attribute(forName: "bgcolor")?.stringValue, let value = safeColor(color) {
                declarations.append("background-color:" + value)
            }
            if let alignment = element.attribute(forName: "align")?.stringValue?.lowercased(),
               ["left", "right", "center", "justify"].contains(alignment) {
                declarations.append("text-align:" + alignment)
            }
            if !declarations.isEmpty { attributes += " style=\"" + escape(declarations.joined(separator: ";")) + "\"" }
            for attribute in ["colspan", "rowspan", "start"] {
                if let raw = element.attribute(forName: attribute)?.stringValue, let value = Int(raw),
                   (1...100).contains(value) { attributes += " \(attribute)=\"\(value)\"" }
            }
            if tag == "br" || tag == "hr" { return "<\(tag)>" }
            return "<\(tag)\(attributes)>\(children)</\(tag)>"
        }

        let content = render(root, depth: 0)
        return Data(("<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>" + content
            + (clipped ? "<p>…</p>" : "") + "</body></html>").utf8)
    }

    nonisolated private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    nonisolated private static func safeColor(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count <= 80 else { return nil }
        if value.range(of: "^(#[0-9a-f]{3,4}|#[0-9a-f]{6}|#[0-9a-f]{8}|[a-z]{1,24})$", options: .regularExpression) != nil {
            return value
        }
        // Only explicit colour functions with numeric comma-separated values.
        let function = value.hasPrefix("rgba(") ? "rgba" : (value.hasPrefix("rgb(") ? "rgb" : "")
        guard !function.isEmpty, value.hasSuffix(")") else { return nil }
        let fields = value.dropFirst(function.count + 1).dropLast().split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == (function == "rgba" ? 4 : 3) else { return nil }
        for (index, field) in fields.enumerated() {
            let field = field.trimmingCharacters(in: .whitespaces)
            guard let number = Double(field), number.isFinite, number >= 0,
                  number <= (index == 3 ? 1 : 255) else { return nil }
        }
        return value
    }

    nonisolated private static func safeStyle(_ input: String) -> String {
        var result: [String] = []
        for declaration in input.split(separator: ";").prefix(32) {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count <= 128 else { continue }
            let lower = value.lowercased()
            switch property {
            case "color", "background-color":
                if let color = safeColor(value) { result.append(property + ":" + color) }
            case "font-weight":
                if ["normal", "bold", "100", "200", "300", "400", "500", "600", "700", "800", "900"].contains(lower) {
                    result.append(property + ":" + lower)
                }
            case "font-style":
                if ["normal", "italic", "oblique"].contains(lower) { result.append(property + ":" + lower) }
            case "font-family":
                let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " ,-'\"_"))
                if value.unicodeScalars.allSatisfy({ allowed.contains($0) }) { result.append(property + ":" + value) }
            case "font-size":
                let units: [(String, Double)] = [("px", 0.75), ("pt", 1), ("em", 12), ("%", 0.12)]
                if let (unit, scale) = units.first(where: { lower.hasSuffix($0.0) }),
                   let size = Double(lower.dropLast(unit.count)), size.isFinite, size > 0 {
                    result.append("font-size:\(min(96, max(6, size * scale)))pt")
                }
            case "text-align":
                if ["left", "right", "center", "justify", "start", "end"].contains(lower) { result.append(property + ":" + lower) }
            case "text-decoration":
                let values = lower.split(separator: " ")
                if !values.isEmpty, values.allSatisfy({ ["none", "underline", "line-through", "overline"].contains(String($0)) }) {
                    result.append(property + ":" + values.joined(separator: " "))
                }
            case "white-space":
                if ["normal", "pre", "pre-wrap", "pre-line"].contains(lower) { result.append(property + ":" + lower) }
            default: break
            }
        }
        return result.joined(separator: ";")
    }
}
