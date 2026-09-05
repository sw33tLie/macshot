import Foundation

@main
struct ContextCapturePayloadTests {
    static func main() {
        let date = Date(timeIntervalSince1970: 0)
        let payload = ContextCapturePayload(
            applicationName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            windowTitle: "Project > Plan",
            capturedAt: date,
            recognizedText: "First line\nSecond line"
        )

        let expected = """
        # App Shot

        - Application: Notes
        - Bundle ID: com.apple.Notes
        - Window: Project > Plan
        - Captured: 1970-01-01T00:00:00Z

        ## Recognized Text

        First line
        Second line
        """

        precondition(payload.markdown == expected, "Unexpected Markdown:\n\(payload.markdown)")

        let empty = ContextCapturePayload(
            applicationName: "Finder",
            bundleIdentifier: nil,
            windowTitle: nil,
            capturedAt: date,
            recognizedText: "  \n"
        )
        precondition(empty.markdown.contains("- Bundle ID: Unavailable"))
        precondition(empty.markdown.contains("- Window: Untitled"))
        precondition(empty.markdown.hasSuffix("No text was recognized."))

        let multilineMetadata = ContextCapturePayload(
            applicationName: "Example\nApplication",
            bundleIdentifier: " com.example.app ",
            windowTitle: "First\nSecond",
            capturedAt: date,
            recognizedText: "Visible"
        )
        precondition(multilineMetadata.markdown.contains("- Application: Example Application"))
        precondition(multilineMetadata.markdown.contains("- Bundle ID: com.example.app"))
        precondition(multilineMetadata.markdown.contains("- Window: First Second"))
    }
}
