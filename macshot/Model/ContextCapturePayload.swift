import Foundation

struct ContextCapturePayload {
    let applicationName: String
    let bundleIdentifier: String?
    let windowTitle: String?
    let capturedAt: Date
    let recognizedText: String

    var markdown: String {
        let application = singleLine(applicationName) ?? "Unknown Application"
        let bundleID = singleLine(bundleIdentifier) ?? "Unavailable"
        let title = singleLine(windowTitle) ?? "Untitled"
        let text = nonempty(recognizedText) ?? "No text was recognized."

        return """
        # App Shot

        - Application: \(application)
        - Bundle ID: \(bundleID)
        - Window: \(title)
        - Captured: \(Self.timestampFormatter.string(from: capturedAt))

        ## Recognized Text

        \(text)
        """
    }

    private func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func singleLine(_ value: String?) -> String? {
        guard let value else { return nil }
        let components = value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: " ")
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
