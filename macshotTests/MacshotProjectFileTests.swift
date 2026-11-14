import Cocoa
import XCTest

/// `.macshot` projects (#497): a capture saved with every annotation still
/// editable, independent of history. Round-trips must be exact, and a damaged
/// or newer file must never reopen raw pixels with an annotation missing.
@MainActor
final class MacshotProjectFileTests: XCTestCase {

    private func retinaImage(width: Int = 120, height: Int = 80) -> NSImage {
        // 2x pixels for a point size of width/2 x height/2.
        let pixels = ImageProbe.quadrantImage(width: width, height: height)
        let cg = pixels.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        return NSImage(cgImage: cg, size: NSSize(width: width / 2, height: height / 2))
    }

    private func sampleAnnotations() -> [Annotation] {
        let arrow = Annotation(tool: .arrow, startPoint: NSPoint(x: 5, y: 6), endPoint: NSPoint(x: 40, y: 30),
                               color: .red, strokeWidth: 4)
        arrow.lineStyle = .dashed
        arrow.controlPoint = NSPoint(x: 20, y: 25)
        let measure = Annotation(tool: .measure, startPoint: NSPoint(x: 2, y: 2), endPoint: NSPoint(x: 50, y: 2),
                                 color: .blue, strokeWidth: 2)
        measure.measureCalibration = MeasureCalibration(pointsPerUnit: 4.8, unit: .millimeters)
        let highlight = Annotation(tool: .highlight, startPoint: NSPoint(x: 10, y: 10), endPoint: NSPoint(x: 30, y: 25),
                                   color: .yellow, strokeWidth: 2)
        highlight.dimOpacity = 0.4
        return [arrow, measure, highlight]
    }

    private func roundTrip(_ snapshot: MacshotProjectFile.Snapshot) throws -> MacshotProjectFile.Contents {
        let data = try snapshot.encoded()
        let decoded = try MacshotProjectFile.decode(data)
        return try MacshotProjectFile.contents(of: decoded)
    }

    func testAProjectReopensWithEverythingEditable() throws {
        let raw = retinaImage()
        var editState = CaptureEditState()
        editState.beautifyEnabled = true
        editState.beautifyPadding = 30
        editState.measureCalibration = MeasureCalibration(pointsPerUnit: 4.8, unit: .millimeters)
        let snapshot = try MacshotProjectFile.Snapshot(
            rawImage: raw, flattenedImage: retinaImage(width: 160, height: 120),
            annotations: sampleAnnotations(), editState: editState)

        guard case .editable(let image, let annotations, let state) = try roundTrip(snapshot) else {
            return XCTFail("expected an editable project")
        }
        XCTAssertEqual(image.size, raw.size, "point size must survive, or annotations land in the wrong place")
        XCTAssertEqual(image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 120)
        XCTAssertEqual(annotations.map(\.tool), [.arrow, .measure, .highlight])
        XCTAssertEqual(annotations[0].startPoint, NSPoint(x: 5, y: 6))
        XCTAssertEqual(annotations[0].controlPoint, NSPoint(x: 20, y: 25))
        XCTAssertEqual(annotations[0].lineStyle, .dashed)
        XCTAssertEqual(annotations[1].measureCalibration, MeasureCalibration(pointsPerUnit: 4.8, unit: .millimeters))
        XCTAssertEqual(annotations[2].dimOpacity, 0.4, accuracy: 0.0001)
        XCTAssertEqual(state, editState)
    }

    func testPixelsSurviveExactly() throws {
        let raw = retinaImage()
        let snapshot = try MacshotProjectFile.Snapshot(rawImage: raw, flattenedImage: nil, annotations: [], editState: nil)
        guard case .editable(let image, let annotations, let state) = try roundTrip(snapshot) else {
            return XCTFail("expected an editable project")
        }
        XCTAssertTrue(annotations.isEmpty)
        XCTAssertNil(state)
        for (x, y) in [(5, 5), (100, 10), (10, 70), (110, 70)] {
            let before = ImageProbe.pixelColor(raw, x: x, y: y)
            let after = ImageProbe.pixelColor(image, x: x, y: y)
            XCTAssertEqual(before?.redComponent ?? -1, after?.redComponent ?? -2, accuracy: 0.01)
            XCTAssertEqual(before?.greenComponent ?? -1, after?.greenComponent ?? -2, accuracy: 0.01)
            XCTAssertEqual(before?.blueComponent ?? -1, after?.blueComponent ?? -2, accuracy: 0.01)
        }
    }

    func testUnreadableAnnotationsFallBackToTheFlattenedCopy() throws {
        let flattened = retinaImage(width: 200, height: 100)
        let snapshot = try MacshotProjectFile.Snapshot(
            rawImage: retinaImage(), flattenedImage: flattened, annotations: sampleAnnotations(), editState: nil)
        var archive = try PropertyListDecoder().decode(MacshotProjectArchive.self, from: snapshot.encoded())
        // A newer build's annotation this build can't read.
        archive.annotationsJSON = Data(#"[{"tool": 0}, {"bogus": true}]"#.utf8)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let contents = try MacshotProjectFile.contents(of: try MacshotProjectFile.decode(encoder.encode(archive)))
        guard case .flattened(let image) = contents else {
            return XCTFail("raw pixels must not open with annotations missing")
        }
        XCTAssertEqual(image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width, 200)
        XCTAssertEqual(image.size, flattened.size, "flattened copy keeps the raw image's density")
    }

    func testWithoutAFlattenedCopyADamagedProjectRefusesToOpen() throws {
        // Opening the raw pixels would show whatever a lost censor covered.
        let censor = Annotation(tool: .pixelate, startPoint: NSPoint(x: 2, y: 2), endPoint: NSPoint(x: 30, y: 20),
                                color: .black, strokeWidth: 2)
        let snapshot = try MacshotProjectFile.Snapshot(
            rawImage: retinaImage(), flattenedImage: nil, annotations: [censor], editState: nil)
        var archive = try PropertyListDecoder().decode(MacshotProjectArchive.self, from: snapshot.encoded())
        archive.annotationsJSON = Data(#"[{"bogus": true}]"#.utf8)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let decoded = try MacshotProjectFile.decode(encoder.encode(archive))
        XCTAssertThrowsError(try MacshotProjectFile.contents(of: decoded))
    }

    func testFilesFromANewerBuildStillOpenWhenReadable() throws {
        let snapshot = try MacshotProjectFile.Snapshot(
            rawImage: retinaImage(), flattenedImage: nil, annotations: sampleAnnotations(), editState: nil)
        var archive = try PropertyListDecoder().decode(MacshotProjectArchive.self, from: snapshot.encoded())
        archive.version = 99
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard case .editable(_, let annotations, _) =
                try MacshotProjectFile.contents(of: try MacshotProjectFile.decode(encoder.encode(archive))) else {
            return XCTFail("expected editable")
        }
        XCTAssertEqual(annotations.count, 3)
    }

    func testOtherFilesAreRejected() {
        XCTAssertThrowsError(try MacshotProjectFile.decode(Data("hello".utf8)))
        XCTAssertThrowsError(try MacshotProjectFile.decode(Data()))
        // A plist that isn't a project.
        let other = try! PropertyListSerialization.data(fromPropertyList: ["format": "something.else"],
                                                       format: .binary, options: 0)
        XCTAssertThrowsError(try MacshotProjectFile.decode(other))
        // A project without its image.
        let noImage = try! PropertyListSerialization.data(
            fromPropertyList: ["format": MacshotProjectFile.formatIdentifier, "version": 1], format: .binary, options: 0)
        XCTAssertThrowsError(try MacshotProjectFile.decode(noImage))
        // An image that isn't a PNG.
        let notPNG = try! PropertyListSerialization.data(
            fromPropertyList: ["format": MacshotProjectFile.formatIdentifier, "version": 1,
                               "imagePNG": Data(repeating: 7, count: 64)], format: .binary, options: 0)
        XCTAssertThrowsError(try MacshotProjectFile.decode(notPNG))
    }

    func testAnImpossiblePointSizeFallsBackToPixels() throws {
        let snapshot = try MacshotProjectFile.Snapshot(rawImage: retinaImage(), flattenedImage: nil,
                                                       annotations: [], editState: nil)
        var archive = try PropertyListDecoder().decode(MacshotProjectArchive.self, from: snapshot.encoded())
        archive.imagePointWidth = 1
        archive.imagePointHeight = 1e12
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard case .editable(let image, _, _) =
                try MacshotProjectFile.contents(of: try MacshotProjectFile.decode(encoder.encode(archive))) else {
            return XCTFail("expected editable")
        }
        XCTAssertEqual(image.size, NSSize(width: 120, height: 80))
    }

    func testWritingIsAtomicAndReadable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macshot-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Report.macshot")
        try Data("previous".utf8).write(to: url)

        let snapshot = try MacshotProjectFile.Snapshot(
            rawImage: retinaImage(), flattenedImage: nil, annotations: sampleAnnotations(), editState: nil)
        let done = expectation(description: "written")
        MacshotProjectFile.write(snapshot, to: url) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        guard case .editable(_, let annotations, _) =
                try MacshotProjectFile.contents(of: try MacshotProjectFile.decode(contentsOf: url)) else {
            return XCTFail("expected editable")
        }
        XCTAssertEqual(annotations.count, 3)
        XCTAssertTrue(MacshotProjectFile.isProjectURL(url))
        XCTAssertFalse(MacshotProjectFile.isProjectURL(directory.appendingPathComponent("a.png")))
    }
}
