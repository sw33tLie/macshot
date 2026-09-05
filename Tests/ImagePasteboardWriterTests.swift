import Cocoa

@main
struct ImagePasteboardWriterTests {
    static func main() throws {
        try writesRetainedFileImageAndContextRepresentations()
        writesImageOnlyFallbackWithoutAFile()
    }

    private static func writesRetainedFileImageAndContextRepresentations() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macshot-context-test-\(UUID())"))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-context-test-\(UUID()).png")
        try Data([0x01]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        ImagePasteboardWriter.write(
            to: pasteboard,
            backingURL: fileURL,
            pngData: Data([0x02]),
            tiffData: Data([0x03]),
            text: "# Context"
        )

        let types = Set(pasteboard.types ?? [])
        precondition(pasteboard.pasteboardItems?.count == 1)
        let itemTypes = Set(pasteboard.pasteboardItems?.first?.types ?? [])
        precondition(types.contains(.fileURL))
        precondition(types.contains(.png))
        precondition(types.contains(.tiff))
        precondition(types.contains(.string))
        precondition(types.contains(ImagePasteboardWriter.markdownType))
        precondition(itemTypes.isSuperset(of: [
            .fileURL,
            .png,
            .tiff,
            .string,
            ImagePasteboardWriter.markdownType,
        ]))
        precondition(pasteboard.string(forType: .string) == "# Context")
        precondition(pasteboard.string(forType: ImagePasteboardWriter.markdownType) == "# Context")
    }

    private static func writesImageOnlyFallbackWithoutAFile() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("macshot-image-test-\(UUID())"))
        ImagePasteboardWriter.write(
            to: pasteboard,
            backingURL: nil,
            pngData: Data([0x04]),
            tiffData: nil,
            text: nil
        )

        let types = Set(pasteboard.types ?? [])
        precondition(types.contains(.png))
        precondition(!types.contains(.fileURL))
        precondition(!types.contains(.string))
        precondition(!types.contains(ImagePasteboardWriter.markdownType))
        precondition(pasteboard.data(forType: .png) == Data([0x04]))
    }
}
