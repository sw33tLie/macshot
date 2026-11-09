import Cocoa
import XCTest

/// A capture that can't be written used to vanish without a word: the overlay
/// dismissed, the thumbnail animated, and the only trace was a DEBUG-only log.
/// These pin the reporting path that replaced it.
final class ImageSaveServiceTests: XCTestCase {

    private var directory: URL!
    private var reported: [String] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-save-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reported = []
        ImageSaveService.onFailure = { [weak self] message in
            self?.reported.append(message)
        }
    }

    override func tearDownWithError() throws {
        ImageSaveService.onFailure = nil
        UserDefaults.standard.removeObject(forKey: ImageSaveService.copyPathAfterSaveKey)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    /// The write happens on a background queue and the completion hops back to
    /// main, so tests wait for it explicitly.
    @discardableResult
    private func save(_ image: NSImage, as filename: String,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let finished = expectation(description: "save finished")
        var result = false
        ImageSaveService.writeImageForTesting(image, toDirectory: directory, filename: filename) { success in
            result = success
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        return result
    }

    private var savedFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    // MARK: - Writing

    func testASavedScreenshotLandsOnDisk() throws {
        withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            XCTAssertTrue(save(ImageProbe.quadrantImage(width: 40, height: 30), as: "shot.png"))
        }
        XCTAssertEqual(savedFiles, ["shot.png"])
        XCTAssertTrue(reported.isEmpty, "a successful save must not report a failure")

        let reloaded = try XCTUnwrap(NSImage(contentsOf: directory.appendingPathComponent("shot.png")))
        let bitmap = try XCTUnwrap(ImageProbe.bitmap(from: reloaded))
        XCTAssertEqual(bitmap.pixelsWide, 40)
    }

    func testASecondSaveDoesNotOverwriteTheFirst() {
        withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            save(ImageProbe.solidImage(width: 10, height: 10), as: "shot.png")
            save(ImageProbe.solidImage(width: 20, height: 20), as: "shot.png")
        }
        XCTAssertEqual(savedFiles.count, 2, "the second capture must not replace the first")
        XCTAssertTrue(savedFiles.contains("shot.png"))
    }

    func testManySavesWithTheSameNameAllSurvive() {
        withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            for _ in 0..<5 {
                save(ImageProbe.solidImage(width: 8, height: 8), as: "same.png")
            }
        }
        XCTAssertEqual(savedFiles.count, 5, "five captures in the same second must produce five files")
        XCTAssertEqual(Set(savedFiles).count, 5, "and five distinct names")
    }

    func testCopyPathAfterSaveWritesTheActualAvailablePathToTheClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("sentinel", forType: .string)

        withDefaults([
            "imageFormat": "png",
            "downscaleRetina": false,
            ImageSaveService.copyPathAfterSaveKey: true,
        ]) {
            XCTAssertTrue(save(ImageProbe.solidImage(), as: "shot.png"))
            XCTAssertTrue(save(ImageProbe.solidImage(), as: "shot.png"))
        }

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            directory.appendingPathComponent("shot (2).png").standardizedFileURL.path
        )
    }

    func testCopyPathAfterSaveIsOffByDefault() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("sentinel", forType: .string)

        withDefaults([
            "imageFormat": "png",
            "downscaleRetina": false,
            ImageSaveService.copyPathAfterSaveKey: nil,
        ]) {
            XCTAssertFalse(ImageSaveService.copyPathAfterSave)
            XCTAssertTrue(save(ImageProbe.solidImage(), as: "shot.png"))
        }

        XCTAssertEqual(pasteboard.string(forType: .string), "sentinel")
    }

    func testQuickCaptureModesKeepTheirPersistedValuesAndOutputSemantics() {
        let expected: [(QuickCaptureMode, Int, Bool, Bool, Bool?)] = [
            (.saveToFile, 0, false, true, nil),
            (.copyImage, 1, true, false, nil),
            (.saveAndCopyImage, 2, true, true, nil),
            (.doNothing, 3, false, false, nil),
            (.saveAndCopyPath, 4, false, true, true),
        ]

        for (mode, rawValue, copiesImage, saves, pathOverride) in expected {
            XCTAssertEqual(mode.rawValue, rawValue)
            XCTAssertEqual(mode.shouldCopyImage, copiesImage)
            XCTAssertEqual(mode.shouldSave, saves)
            XCTAssertEqual(mode.copyPathOverride, pathOverride)
            XCTAssertFalse(mode.title.isEmpty)
        }
    }

    func testQuickCaptureModeDefaultsSafelyForMissingOrUnknownValues() {
        withDefaults([QuickCaptureMode.userDefaultsKey: nil]) {
            XCTAssertEqual(QuickCaptureMode.current, .copyImage)
        }
        withDefaults([QuickCaptureMode.userDefaultsKey: 99]) {
            XCTAssertEqual(QuickCaptureMode.current, .copyImage)
        }
    }

    // MARK: - Failure reporting

    func testConcurrentSavesAreCoordinatedAndKeepEveryDistinctImage() throws {
        let finished = expectation(description: "all concurrent saves complete")
        finished.expectedFulfillmentCount = 12
        withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            for width in 10..<22 {
                ImageSaveService.writeImageForTesting(ImageProbe.solidImage(width: width, height: 8),
                    toDirectory: directory, filename: "concurrent.png") { success in
                        XCTAssertTrue(success)
                        finished.fulfill()
                    }
            }
        }
        XCTAssertTrue(MediaExportCoordinator.shared.hasActiveJobs, "Quit must see pending screenshot saves")
        wait(for: [finished], timeout: 10)
        XCTAssertFalse(MediaExportCoordinator.shared.hasActiveJobs)
        let widths = try savedFiles.map { name in
            let image = try XCTUnwrap(NSImage(contentsOf: directory.appendingPathComponent(name)))
            return try XCTUnwrap(ImageProbe.bitmap(from: image)).pixelsWide
        }
        XCTAssertEqual(widths.sorted(), Array(10..<22))
    }

    func testFailedSaveAsPreservesExistingFile() throws {
        let destination = directory.appendingPathComponent("existing.png")
        let original = Data("original destination remains intact".utf8)
        try original.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let prepared = try ImageEncoder.PreparedImage(ImageProbe.solidImage())
        let finished = expectation(description: "failed replacement")
        ImageSaveService.writePreparedImage(prepared, to: destination, chooseAvailableName: false) { success in
            XCTAssertFalse(success)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testAFailedWriteIsReportedToTheUser() {
        // Make the directory read-only so the write fails the way a full disk
        // or an unmounted volume would.
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        var succeeded = true
        withDefaults(["imageFormat": "png", "downscaleRetina": false]) {
            succeeded = save(ImageProbe.solidImage(), as: "denied.png")
        }

        XCTAssertFalse(succeeded)
        // The report is dispatched to main; let it land.
        let reportArrived = expectation(description: "failure reported")
        DispatchQueue.main.async { reportArrived.fulfill() }
        wait(for: [reportArrived], timeout: 5)

        XCTAssertFalse(reported.isEmpty, "a save that failed must tell the user, not just return false")
        XCTAssertTrue(reported.first?.lowercased().contains("save") == true,
                      "the message should say what failed, got: \(reported)")
    }

    func testAMissingDirectoryIsReported() {
        let missing = directory.appendingPathComponent("not-created")
        let finished = expectation(description: "save finished")
        var succeeded = true
        withDefaults(["imageFormat": "png"]) {
            ImageSaveService.writeImageForTesting(ImageProbe.solidImage(), toDirectory: missing,
                                                  filename: "x.png") { success in
                succeeded = success
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(succeeded)

        let reportArrived = expectation(description: "failure reported")
        DispatchQueue.main.async { reportArrived.fulfill() }
        wait(for: [reportArrived], timeout: 5)
        XCTAssertFalse(reported.isEmpty)
    }

    func testTemplateSubfoldersAreCreatedOnlyBelowAnExistingSaveFolder() throws {
        let nested = directory.appendingPathComponent("2026/09/25/Safari-14.30.05.png")
        try ImageSaveService.createSubfolders(for: nested, below: directory)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.deletingLastPathComponent().path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        // A vanished save folder is never recreated.
        let missingRoot = directory.appendingPathComponent("unplugged-drive")
        try ImageSaveService.createSubfolders(for: missingRoot.appendingPathComponent("2026/x.png"), below: missingRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingRoot.path))

        // Paths outside the save folder are ignored.
        let outside = directory.deletingLastPathComponent().appendingPathComponent("elsewhere-\(UUID().uuidString)/x.png")
        try ImageSaveService.createSubfolders(for: outside, below: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.deletingLastPathComponent().path))
    }

    func testTheDefaultSaveActionIsToUseTheConfiguredFolder() {
        withDefaults([SaveActionPreference.userDefaultsKey: nil]) {
            XCTAssertEqual(SaveActionPreference.current, .saveToFolder)
        }
        withDefaults([SaveActionPreference.userDefaultsKey: 99]) {
            XCTAssertEqual(SaveActionPreference.current, .saveToFolder, "an unknown stored value must fall back")
        }
    }

    func testEverySaveActionHasATitle() {
        for action in SaveActionPreference.allCases {
            XCTAssertFalse(action.title.isEmpty)
        }
    }
}
