import XCTest
import Cocoa

final class FeedbackTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func image(width: Int = 120, height: Int = 80) throws -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixels(_ image: CGImage) -> Data {
        let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width*4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: c.data!, count: image.width*image.height*4)
    }

    func testDraftDecodeAndValidation() throws {
        let doc = try JSONDecoder().decode(FeedbackDocument.self, from: Data("{\"width\":120,\"height\":80}".utf8))
        XCTAssertEqual(try doc.validated().notes, [])
        var invalid = doc
        invalid.notes = [FeedbackNote(kind: .region, rect: CGRect(x: 119, y: 0, width: 2, height: 5))]
        XCTAssertThrowsError(try invalid.validated())
        invalid.notes = [FeedbackNote(kind: .point, rect: CGRect(x: CGFloat.infinity, y: 0, width: 0, height: 0))]
        XCTAssertThrowsError(try invalid.validated())
    }

    func testEmptyMarkersAreNotInventedRequirements() {
        var doc = FeedbackDocument(width: 120, height: 80)
        doc.notes = [FeedbackNote(kind: .point, comment: "  \n"), FeedbackNote(kind: .global, comment: "改成蓝色")]
        XCTAssertEqual(doc.submitted.notes.count, 1)
        XCTAssertTrue(doc.markdown.contains("Modification 1"))
        XCTAssertFalse(doc.markdown.contains("Modification 2"))
        doc.notes = []
        XCTAssertTrue(doc.markdown.contains("empty feedback"))
    }

    @MainActor func testLocalizedExportPreservesUserTextAndPixelCoordinates() throws {
        let directory = try folder(), source = try image()
        var doc = FeedbackDocument(width: 120, height: 80)
        let comment = "保留原文：change 50% → 蓝色"
        let ocr = "Image text\n原始文字"
        doc.notes = [FeedbackNote(kind: .region, rect: CGRect(x: 10.5, y: 20, width: 30, height: 10), comment: comment)]
        doc.notes[0].ocr = ocr
        var labels = FeedbackMarkdownLabels()
        labels.title = "修改意见"
        labels.dimensions = "图片：%d × %d 像素。"
        labels.heading = "修改 %d"
        labels.region = "位置：区域 (%@, %@, %@, %@)。"
        let markdown = doc.markdown(labels: labels)
        XCTAssertTrue(markdown.contains("# 修改意见"))
        XCTAssertTrue(markdown.contains("120 × 80"))
        XCTAssertTrue(markdown.contains("(10.5, 20.0, 30.0, 10.0)"))
        XCTAssertTrue(markdown.contains(comment))
        XCTAssertTrue(markdown.contains("> Image text\n> 原始文字"))
        let preview = try FeedbackExport.preview(source, document: doc)
        try FeedbackExport.write(source: source, preview: preview, document: doc, directory: directory, markdown: markdown)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("feedback.md")), markdown)
        let exported = try JSONDecoder().decode(FeedbackDocument.self, from: Data(contentsOf: directory.appendingPathComponent("feedback.json")))
        XCTAssertEqual(exported, doc.submitted)
    }

    func testOneCorruptNoteDoesNotDiscardTheOtherNotes() throws {
        let note = FeedbackNote(kind: .global, comment: "保留这条意见")
        let data = try JSONEncoder().encode(note)
        let json = "{\"width\":120,\"height\":80,\"notes\":[false," + String(decoding: data, as: UTF8.self) + "]}"
        let doc = try JSONDecoder().decode(FeedbackDocument.self, from: Data(json.utf8))
        XCTAssertEqual(doc.notes, [note])
    }

    func testDraftRestoresImageAndNotesWithoutSubmitting() throws {
        let root = try folder(), image = try image()
        var doc = FeedbackDocument(width: 120, height: 80)
        doc.notes = [FeedbackNote(kind: .point, rect: CGRect(x: 12, y: 24, width: 0, height: 0), comment: "修改标题")]
        try FeedbackDraftStore.save(doc, source: image, directory: root)
        let directory = root.appendingPathComponent(doc.id.uuidString)
        let (restored, pixels) = try FeedbackDraftStore.load(directory)
        XCTAssertEqual(restored, doc)
        XCTAssertEqual(pixels.width, 120)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("result.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("feedback.json").path))
    }

    @MainActor func testExportPreservesPixelsAndPublishesConsistentFiles() throws {
        let dir = try folder(), source = try image()
        var doc = FeedbackDocument(width: 120, height: 80)
        doc.notes = [FeedbackNote(kind: .region, rect: CGRect(x: 10, y: 20, width: 30, height: 10), comment: "背景改成蓝色")]
        let preview = try FeedbackExport.preview(source, document: doc)
        try FeedbackExport.write(source: source, preview: preview, document: doc, directory: dir)
        let decoded = try JSONDecoder().decode(FeedbackDocument.self, from: Data(contentsOf: dir.appendingPathComponent("feedback.json")))
        XCTAssertEqual(decoded, doc.submitted)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("feedback.md"), encoding: .utf8), doc.markdown)
        let preserved = try FeedbackExport.loadImage(dir.appendingPathComponent("source.png"))
        XCTAssertEqual(preserved.width, 120); XCTAssertEqual(preserved.height, 80)
        XCTAssertEqual(pixels(preserved), pixels(source))
        let original = try Data(contentsOf: dir.appendingPathComponent("feedback.json"))
        XCTAssertThrowsError(try FeedbackExport.write(source: source, preview: preview, document: doc, directory: dir))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("feedback.json")), original)
    }

    @MainActor func testManualCopyBundleUsesTaskIDAndNeverOverwrites() throws {
        let root = try folder(), source = try image()
        var doc = FeedbackDocument(width: 120, height: 80)
        doc.notes = [FeedbackNote(kind: .point, rect: CGRect(x: 10, y: 20, width: 0, height: 0), comment: "Move the title")]
        let preview = try FeedbackExport.preview(source, document: doc)
        let taskID = UUID(), markdown = doc.markdown
        let directory = try FeedbackExport.writeManual(source: source, preview: preview, document: doc,
                                                       root: root, taskID: taskID, markdown: markdown)
        XCTAssertEqual(directory.lastPathComponent, taskID.uuidString)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set(["source.png", "preview.png", "feedback.json", "feedback.md"]))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("feedback.md")), markdown)
        let exported = try JSONDecoder().decode(FeedbackDocument.self,
            from: Data(contentsOf: directory.appendingPathComponent("feedback.json")))
        XCTAssertEqual(exported, doc.submitted)
        XCTAssertEqual(pixels(try FeedbackExport.loadImage(directory.appendingPathComponent("source.png"))), pixels(source))
        let copied = FeedbackExport.manualClipboardText(markdown: markdown, root: root, taskID: taskID)
        XCTAssertTrue(copied.contains(taskID.uuidString))
        XCTAssertTrue(copied.contains(directory.path))
        XCTAssertTrue(copied.contains("macshot-feedback Skill"))
        XCTAssertTrue(copied.contains(markdown))

        XCTAssertThrowsError(try FeedbackExport.writeManual(source: source, preview: preview, document: doc,
                                                             root: root, taskID: taskID, markdown: "changed"))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("feedback.md")), markdown)
        let next = try FeedbackExport.writeManual(source: source, preview: preview, document: doc,
                                                  root: root, taskID: UUID(), markdown: markdown)
        XCTAssertNotEqual(next, directory)
    }

    func testExclusivePublicationRejectsExistingFilesAndDanglingSymlinks() throws {
        let dir = try folder(), target = dir.appendingPathComponent("result.json")
        try FeedbackExport.publish(Data("first".utf8), to: target)
        XCTAssertThrowsError(try FeedbackExport.publish(Data("second".utf8), to: target))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "first")
        let symlink = dir.appendingPathComponent("feedback.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: dir.appendingPathComponent("missing"))
        XCTAssertThrowsError(try FeedbackExport.publish(Data(), to: symlink))
    }

    func testSessionRejectsWrongIdentityAndSymlinks() throws {
        let root = try folder(), id = UUID()
        let session = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let request = FeedbackRequest(version: 1, session: UUID(), token: String(repeating: "a", count: 64), deadline: Date().timeIntervalSince1970+30)
        try FeedbackExport.publish(JSONEncoder().encode(request), to: session.appendingPathComponent("request.json"))
        XCTAssertThrowsError(try FeedbackSessionFiles.request(root: root, session: id))
        let external = try folder(), linked = UUID()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(linked.uuidString), withDestinationURL: external)
        XCTAssertThrowsError(try FeedbackSessionFiles.directory(root: root, session: linked))
    }

    func testCaptureRequestNeedsNoInputAndLegacyRequestStillDecodes() throws {
        let root = try folder()
        let id = UUID()
        let session = root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let requestURL = session.appendingPathComponent("request.json")
        let request = FeedbackRequest(version: 1, session: id, token: String(repeating: "a", count: 64),
                                      deadline: Date().timeIntervalSince1970 + 30, mode: .capture)
        try FeedbackExport.publish(JSONEncoder().encode(request), to: requestURL)
        XCTAssertEqual(try FeedbackSessionFiles.request(root: root, session: id).1.mode, .capture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.appendingPathComponent("input.png").path))
        let cancelURL = session.appendingPathComponent("cancel.json")
        try FeedbackExport.publish(JSONEncoder().encode(request), to: cancelURL)
        XCTAssertTrue(FeedbackSessionFiles.cancelled(session, request: request))

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        legacy.removeValue(forKey: "mode")
        XCTAssertNil(try JSONDecoder().decode(FeedbackRequest.self, from: JSONSerialization.data(withJSONObject: legacy)).mode)
        legacy["mode"] = "unsupported"
        XCTAssertThrowsError(try JSONDecoder().decode(FeedbackRequest.self, from: JSONSerialization.data(withJSONObject: legacy)))
    }

    private func captureRequest(root: URL, deadline: TimeInterval = Date().timeIntervalSince1970 + 30) throws -> (URL, FeedbackRequest) {
        let request = FeedbackRequest(version: 1, session: UUID(), token: String(repeating: "b", count: 64),
                                      deadline: deadline, mode: .capture)
        let directory = root.appendingPathComponent(request.session.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FeedbackExport.publish(JSONEncoder().encode(request), to: directory.appendingPathComponent("request.json"))
        return (directory, request)
    }

    @MainActor func testCaptureCancellationAndBusyRequestsKeepOneSession() throws {
        let root = try folder()
        let (firstDirectory, first) = try captureRequest(root: root)
        let (secondDirectory, second) = try captureRequest(root: root)
        let manager = FeedbackSessionManager(directoryResolver: { root })
        var starts = 0, cleanups = 0
        manager.open(session: first.session, beginCapture: { XCTAssertEqual($0, first.session); starts += 1 },
                     cancelCapture: { XCTAssertEqual($0, first.session); cleanups += 1 })
        manager.open(session: first.session, beginCapture: { _ in starts += 1 })
        manager.open(session: second.session, beginCapture: { _ in starts += 1 })
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(manager.hasActiveSession)
        XCTAssertEqual(try FeedbackSessionFiles.read(FeedbackReceipt.self, at: secondDirectory.appendingPathComponent("result.json")).state, .failed)
        manager.endCapture(session: second.session, state: .cancelled, message: "Wrong session")
        XCTAssertTrue(manager.hasActiveSession)
        try FeedbackExport.publish(JSONEncoder().encode(first), to: firstDirectory.appendingPathComponent("cancel.json"))
        // A selection arriving after cancellation must not open an editor.
        manager.completeCapture(session: first.session, image: nil)
        XCTAssertFalse(manager.hasActiveSession)
        XCTAssertEqual(cleanups, 1)
        let receipt = try FeedbackSessionFiles.read(FeedbackReceipt.self, at: firstDirectory.appendingPathComponent("result.json"))
        XCTAssertEqual(receipt.state, .cancelled)
        manager.endCapture(session: first.session, state: .failed, message: "Late failure")
        XCTAssertEqual(try FeedbackSessionFiles.read(FeedbackReceipt.self, at: firstDirectory.appendingPathComponent("result.json")).state, .cancelled)
    }

    @MainActor func testPendingCaptureTimesOutAndCleansUp() throws {
        let root = try folder()
        let (directory, request) = try captureRequest(root: root, deadline: Date().timeIntervalSince1970 + 0.2)
        let manager = FeedbackSessionManager(directoryResolver: { root })
        var cleaned = false
        manager.open(session: request.session, beginCapture: { _ in }, cancelCapture: { _ in cleaned = true })
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        XCTAssertTrue(cleaned)
        XCTAssertFalse(manager.hasActiveSession)
        XCTAssertEqual(try FeedbackSessionFiles.read(FeedbackReceipt.self, at: directory.appendingPathComponent("result.json")).state, .timedOut)
    }

    @MainActor func testCaptureFailureAndApplicationQuitPublishTerminalReceipts() throws {
        let root = try folder()
        let manager = FeedbackSessionManager(directoryResolver: { root })
        let (failedDirectory, failed) = try captureRequest(root: root)
        manager.open(session: failed.session, beginCapture: { _ in })
        manager.completeCapture(session: failed.session, image: nil)
        XCTAssertFalse(manager.hasActiveSession)
        XCTAssertEqual(try FeedbackSessionFiles.read(FeedbackReceipt.self, at: failedDirectory.appendingPathComponent("result.json")).state, .failed)
        let (quitDirectory, quit) = try captureRequest(root: root)
        var cleaned = false
        manager.open(session: quit.session, beginCapture: { _ in }, cancelCapture: { _ in cleaned = true })
        manager.applicationWillTerminate()
        XCTAssertTrue(cleaned)
        XCTAssertFalse(manager.hasActiveSession)
        XCTAssertEqual(try FeedbackSessionFiles.read(FeedbackReceipt.self, at: quitDirectory.appendingPathComponent("result.json")).state, .cancelled)
    }

    @MainActor func testExportFailureDoesNotPublishFeedback() throws {
        let dir = try folder(), source = try image()
        let doc = FeedbackDocument(width: 120, height: 80)
        let blocked = dir.appendingPathComponent("preview.png")
        try FileManager.default.createSymbolicLink(at: blocked, withDestinationURL: dir.appendingPathComponent("missing"))
        XCTAssertThrowsError(try FeedbackExport.write(source: source, preview: source, document: doc, directory: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("feedback.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("source.png").path))
    }
}
