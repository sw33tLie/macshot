import Cocoa

enum ImagePasteboardWriter {
    static let markdownType = NSPasteboard.PasteboardType("net.daringfireball.markdown")

    @discardableResult
    static func write(
        to pasteboard: NSPasteboard,
        backingURL: URL?,
        pngData: Data,
        tiffData: Data?,
        text: String?
    ) -> Bool {
        let item = NSPasteboardItem()
        var success = item.setData(pngData, forType: .png)
        if let backingURL {
            success = item.setString(backingURL.absoluteString, forType: .fileURL) && success
        }
        if let tiffData {
            success = item.setData(tiffData, forType: .tiff) && success
        }
        if let text {
            success = item.setString(text, forType: .string) && success
            success = item.setString(text, forType: markdownType) && success
        }

        pasteboard.clearContents()
        return success && pasteboard.writeObjects([item])
    }

    @discardableResult
    static func writeText(to pasteboard: NSPasteboard, markdown: String) -> Bool {
        let item = NSPasteboardItem()
        let representationsSucceeded = item.setString(markdown, forType: .string)
            && item.setString(markdown, forType: markdownType)
        pasteboard.clearContents()
        return representationsSucceeded && pasteboard.writeObjects([item])
    }
}
