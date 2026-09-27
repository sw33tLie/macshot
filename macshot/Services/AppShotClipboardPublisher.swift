import Cocoa

enum AppShotClipboardPublisher {
    struct Generation: Equatable {
        fileprivate let value: Int
    }

    private static let historySeparationDelay: TimeInterval = 1.0
    private static let generationLock = NSLock()
    private static var generation = 0

    static func beginPublication() -> Generation {
        generationLock.lock()
        defer { generationLock.unlock() }
        generation += 1
        return Generation(value: generation)
    }

    static func isCurrent(_ expected: Generation) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation == expected.value
    }

    @MainActor
    static func publish(
        to pasteboard: NSPasteboard = .general,
        generation: Generation,
        backingURL: URL?,
        pngData: Data,
        tiffData: Data?,
        markdown: String,
        wait: () async -> Void = {
            try? await Task.sleep(
                nanoseconds: UInt64(historySeparationDelay * 1_000_000_000)
            )
        },
        writeContext: ((NSPasteboard, String) -> Bool)? = nil
    ) async -> Bool {
        guard isCurrent(generation),
              ImagePasteboardWriter.write(
            to: pasteboard,
            backingURL: backingURL,
            pngData: pngData,
            tiffData: tiffData,
            text: nil
        ) else {
            return false
        }

        await wait()

        guard isCurrent(generation),
              pasteboard.data(forType: .png) == pngData else {
            return false
        }
        if let writeContext {
            return writeContext(pasteboard, markdown)
        }
        return ImagePasteboardWriter.writeText(to: pasteboard, markdown: markdown)
    }
}
