import Cocoa

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
@main
struct AppShotClipboardPublisherTests {
    @MainActor
    static func main() async throws {
        try await publishesImageThenContextDocumentAsSeparateClipboardStates()
        await publishesContextAfterClipboardHistoryEnrichesTheImageState()
        await doesNotOverwriteAClipboardChangedBeforeContextPublication()
        await newerAppShotGenerationRejectsOlderContextPublication()
        await reportsContextDocumentWriteFailure()
        await productionPublicationUsesTheHistorySeparationDelay()
    }

    @MainActor
    private static func publishesContextAfterClipboardHistoryEnrichesTheImageState() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let historyMetadataType = NSPasteboard.PasteboardType("com.example.clipboard-history-metadata")
        let generation = AppShotClipboardPublisher.beginPublication()

        let result = await AppShotClipboardPublisher.publish(
            to: pasteboard,
            generation: generation,
            backingURL: nil,
            pngData: Data([0x01]),
            tiffData: nil,
            markdown: "# App Shot",
            wait: {
                pasteboard.clearContents()
                pasteboard.declareTypes([.png, historyMetadataType], owner: nil)
                pasteboard.setData(Data([0x01]), forType: .png)
                pasteboard.setString("history metadata", forType: historyMetadataType)
            }
        )

        expect(result, "clipboard-history metadata must not cancel Context Document publication")
        expect(
            pasteboard.string(forType: .string) == "# App Shot",
            "Context Document must become current after clipboard-history enrichment"
        )
    }

    @MainActor
    private static func publishesImageThenContextDocumentAsSeparateClipboardStates() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let backingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-appshot-clipboard-\(UUID()).png")
        try Data([0x03]).write(to: backingURL)
        defer { try? FileManager.default.removeItem(at: backingURL) }
        let generation = AppShotClipboardPublisher.beginPublication()

        let result = await AppShotClipboardPublisher.publish(
            to: pasteboard,
            generation: generation,
            backingURL: backingURL,
            pngData: Data([0x01]),
            tiffData: Data([0x02]),
            markdown: "# App Shot",
            wait: {
                expect(pasteboard.data(forType: .png) == Data([0x01]), "first state must contain the Window Image")
                expect(pasteboard.data(forType: .tiff) == Data([0x02]), "first state must contain TIFF when available")
                expect(pasteboard.string(forType: .fileURL) != nil, "first state must retain its backing file URL")
                expect(pasteboard.string(forType: .string) == nil, "first state must not contain Context Document text")
            }
        )

        expect(result, "publication must report success after the Context Document is current")
        expect(pasteboard.string(forType: .string) == "# App Shot", "current state must contain plain text")
        expect(
            pasteboard.string(forType: ImagePasteboardWriter.markdownType) == "# App Shot",
            "current state must contain Markdown"
        )
        expect(pasteboard.data(forType: .png) == nil, "current state must be text-only")
    }

    @MainActor
    private static func doesNotOverwriteAClipboardChangedBeforeContextPublication() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let generation = AppShotClipboardPublisher.beginPublication()

        let result = await AppShotClipboardPublisher.publish(
            to: pasteboard,
            generation: generation,
            backingURL: nil,
            pngData: Data([0x01]),
            tiffData: nil,
            markdown: "# App Shot",
            wait: {
                pasteboard.clearContents()
                pasteboard.setString("newer clipboard content", forType: .string)
            }
        )

        expect(!result, "stale Context Document publication must be rejected")
        expect(
            pasteboard.string(forType: .string) == "newer clipboard content",
            "stale publication must preserve newer clipboard content"
        )
    }

    @MainActor
    private static func newerAppShotGenerationRejectsOlderContextPublication() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let olderGeneration = AppShotClipboardPublisher.beginPublication()

        let result = await AppShotClipboardPublisher.publish(
            to: pasteboard,
            generation: olderGeneration,
            backingURL: nil,
            pngData: Data([0x01]),
            tiffData: nil,
            markdown: "older context",
            wait: {
                _ = AppShotClipboardPublisher.beginPublication()
            }
        )

        expect(!result, "a newer App Shot generation must reject older Context Document publication")
        expect(pasteboard.string(forType: .string) == nil, "older Context Document must not become current")
    }

    @MainActor
    private static func reportsContextDocumentWriteFailure() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let generation = AppShotClipboardPublisher.beginPublication()

        let result = await AppShotClipboardPublisher.publish(
            to: pasteboard,
            generation: generation,
            backingURL: nil,
            pngData: Data([0x01]),
            tiffData: nil,
            markdown: "# App Shot",
            wait: {},
            writeContext: { _, _ in false }
        )

        expect(!result, "publication must report a failed Context Document write")
    }

    @MainActor
    private static func productionPublicationUsesTheHistorySeparationDelay() async {
        let pasteboard = NSPasteboard.withUniqueName()
        let generation = AppShotClipboardPublisher.beginPublication()
        let startedAt = Date()

        let result = await AppShotClipboardPublisher.publish(
            to: pasteboard,
            generation: generation,
            backingURL: nil,
            pngData: Data([0x01]),
            tiffData: nil,
            markdown: "# App Shot"
        )

        expect(result, "production publication must succeed")
        expect(Date().timeIntervalSince(startedAt) >= 0.9, "production publication must preserve clipboard-history separation")
    }
}
