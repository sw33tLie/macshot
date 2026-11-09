import Cocoa
import XCTest

/// Captures and settings written by older builds must keep loading. Swift's
/// synthesized `init(from:)` demands a key for every non-optional property even
/// when it has a default, so before `LenientDecoding.swift` existed, adding one
/// field to a persisted model silently discarded every annotation in older
/// captures — and, for the history index, every entry at once.
final class LegacyDecodingTests: XCTestCase {

    // MARK: - Annotations

    /// Exactly the fields `CodableAnnotation` required at its first version.
    private let oldestAnnotationJSON = """
    [{"tool":3,"startX":10,"startY":20,"endX":110,"endY":80,"colorRGBA":[1,0,0,1],"strokeWidth":4}]
    """

    func testCaptureFromTheOldestFormatStillLoads() throws {
        let annotations = try XCTUnwrap(
            AnnotationSerializer.decode(Data(oldestAnnotationJSON.utf8)),
            "a capture written before later fields existed must still open with its annotations")
        XCTAssertEqual(annotations.count, 1)
        let ann = annotations[0]
        XCTAssertEqual(ann.tool, .rectangle)
        XCTAssertEqual(ann.startPoint, NSPoint(x: 10, y: 20))
        XCTAssertEqual(ann.endPoint, NSPoint(x: 110, y: 80))
        XCTAssertEqual(ann.strokeWidth, 4)
        // Fields that didn't exist yet fall back to today's defaults.
        XCTAssertEqual(ann.fontSize, 20)
        XCTAssertEqual(ann.dimOpacity, 0.55, accuracy: 0.0001)
        XCTAssertEqual(ann.loupeMagnification, 2.0)
        XCTAssertEqual(ann.censorMode, .pixelate)
        XCTAssertEqual(ann.lineStyle, .solid)
    }

    func testEveryFieldMayBeAbsentExceptTool() throws {
        let annotations = try XCTUnwrap(AnnotationSerializer.decode(Data("""
        [{"tool":0}]
        """.utf8)), "only the tool is genuinely required to draw an annotation")
        XCTAssertEqual(annotations.first?.tool, .pencil)
    }

    func testAnnotationWithoutAToolIsSkipped() {
        XCTAssertNil(AnnotationSerializer.decode(Data("""
        [{"startX":1,"startY":2,"endX":3,"endY":4,"colorRGBA":[0,0,0,1],"strokeWidth":1}]
        """.utf8)), "an annotation with no tool can't be drawn, so it's dropped")
    }

    func testOneCorruptAnnotationDoesNotDiscardTheOthers() throws {
        let json = """
        [{"tool":0,"startX":0,"startY":0,"endX":5,"endY":5,"colorRGBA":[1,0,0,1],"strokeWidth":1},
         {"tool":"not-a-number"},
         {"tool":3,"startX":9,"startY":9,"endX":19,"endY":19,"colorRGBA":[0,1,0,1],"strokeWidth":2}]
        """
        let annotations = try XCTUnwrap(AnnotationSerializer.decode(Data(json.utf8)))
        XCTAssertEqual(annotations.count, 2, "a corrupt entry should cost one annotation, not the whole capture")
        XCTAssertEqual(annotations.map(\.tool), [.pencil, .rectangle])
    }

    func testWrongTypedFieldFallsBackInsteadOfDiscardingTheAnnotation() throws {
        let json = """
        [{"tool":0,"startX":0,"startY":0,"endX":5,"endY":5,"colorRGBA":[1,0,0,1],"strokeWidth":"thick",
          "fontSize":"big","isBold":"yes","rotation":null}]
        """
        let ann = try XCTUnwrap(AnnotationSerializer.decode(Data(json.utf8))?.first)
        XCTAssertEqual(ann.strokeWidth, 3, "a non-numeric stroke width falls back to the default")
        XCTAssertEqual(ann.fontSize, 20)
        XCTAssertFalse(ann.isBold)
        XCTAssertEqual(ann.rotation, 0)
    }

    func testUnknownFutureFieldsAreIgnored() throws {
        // A capture written by a newer build must still open in an older one.
        let json = """
        [{"tool":0,"startX":0,"startY":0,"endX":5,"endY":5,"colorRGBA":[1,0,0,1],"strokeWidth":2,
          "somethingAddedLater":{"nested":true},"anotherNewField":[1,2,3]}]
        """
        let ann = try XCTUnwrap(AnnotationSerializer.decode(Data(json.utf8))?.first)
        XCTAssertEqual(ann.tool, .pencil)
        XCTAssertEqual(ann.strokeWidth, 2)
    }

    func testTodaysFormatStillRoundTripsAfterTheLenientDecoder() throws {
        let ann = AnnotationPersistenceTests.fullyPopulated(tool: .arrow)
        let data = try XCTUnwrap(AnnotationSerializer.encode([ann]))
        let decoded = try XCTUnwrap(AnnotationSerializer.decode(data)?.first)
        XCTAssertEqual(decoded.arrowStyle, ann.arrowStyle)
        XCTAssertEqual(decoded.randomSeed, ann.randomSeed)
        XCTAssertEqual(decoded.dimOpacity, ann.dimOpacity, accuracy: 0.0001)
    }

    // MARK: - Capture edit state

    func testEditStateFromAnOlderBuildStillLoads() throws {
        // Written before the blur/window-snap/custom-background fields existed.
        let json = """
        {"effectsPresetRaw":0,"effectsBrightness":0.2,"effectsContrast":1.1,
         "effectsSaturation":0.9,"effectsSharpness":0.3,"beautifyEnabled":true,
         "beautifyModeRaw":1,"beautifyStyleIndex":4,"beautifyPadding":64,
         "beautifyCornerRadius":16,"beautifyShadowRadius":30}
        """
        let state = try XCTUnwrap(try? JSONDecoder().decode(CaptureEditState.self, from: Data(json.utf8)),
                                  "beautify settings saved by an older build must survive an update")
        XCTAssertTrue(state.beautifyEnabled)
        XCTAssertEqual(state.beautifyStyleIndex, 4)
        XCTAssertEqual(state.beautifyPadding, 64)
        XCTAssertEqual(state.beautifyBackgroundBlur, 0, "a field added later takes its default")
        XCTAssertFalse(state.beautifyIsWindowSnap)
        XCTAssertNil(state.customBeautifyBackgroundPNG)
        XCTAssertEqual(state.effectsBrightness, 0.2, accuracy: 0.0001)
    }

    func testEmptyEditStateObjectDecodesToDefaults() throws {
        let state = try XCTUnwrap(try? JSONDecoder().decode(CaptureEditState.self, from: Data("{}".utf8)))
        XCTAssertEqual(state, CaptureEditState())
    }

    func testEditStateRoundTrips() throws {
        var state = CaptureEditState()
        state.beautifyEnabled = true
        state.beautifyStyleIndex = 7
        state.beautifyPadding = 100
        state.beautifyBackgroundBlur = 12
        state.effectsSaturation = 1.4
        state.customBeautifyBackgroundPNG = ImageProbe.quadrantImage(width: 8, height: 8)
            .tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CaptureEditState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testEditStateBoundsValuesBeforePassingThemToRendering() throws {
        let data = Data("""
        {"effectsBrightness":3,"effectsContrast":-2,"effectsSaturation":5,"effectsSharpness":-1,
         "beautifyPadding":-10,"beautifyCornerRadius":-5,"beautifyShadowRadius":120,"beautifyBackgroundBlur":75}
        """.utf8)
        let state = try JSONDecoder().decode(CaptureEditState.self, from: data)
        XCTAssertEqual(state.effectsBrightness, 0.5)
        XCTAssertEqual(state.effectsContrast, 0.5)
        XCTAssertEqual(state.effectsSaturation, 2)
        XCTAssertEqual(state.effectsSharpness, 0)
        XCTAssertEqual(state.beautifyPadding, 0)
        XCTAssertEqual(state.beautifyCornerRadius, 0)
        XCTAssertEqual(state.beautifyShadowRadius, 100)
        XCTAssertEqual(state.beautifyBackgroundBlur, 50)
        var inMemory = CaptureEditState()
        inMemory.effectsBrightness = .nan
        inMemory.beautifyPadding = .infinity
        XCTAssertEqual(inMemory.effectsConfig.brightness, 0)
        XCTAssertEqual(inMemory.beautifyConfig().padding, 48)
        let overlay = OverlayView()
        overlay.applyCaptureEditState(inMemory)
        XCTAssertEqual(overlay.effectsBrightness, 0)
        XCTAssertEqual(overlay.beautifyPadding, 48)
    }

    // MARK: - History index

    func testHistoryIndexRowsSurviveMissingAndCorruptFields() throws {
        // Row 1: oldest format. Row 2: corrupt. Row 3: current format.
        let json = """
        [{"id":"00000000-0000-0000-0000-000000000001","fileExtension":"png","timestamp":0,"pixelWidth":100,"pixelHeight":50},
         {"nope":true},
         {"id":"00000000-0000-0000-0000-000000000003","fileExtension":"jpg","timestamp":1000,"pixelWidth":10,"pixelHeight":20,
          "hasAnnotations":true,"lastEditedAt":2000}]
        """
        let rows = try XCTUnwrap(
            LenientArrayDecoder.decode(ScreenshotHistory.IndexEntry.self, from: Data(json.utf8)),
            "one bad row must not wipe the user's whole capture history")
        XCTAssertEqual(rows.map(\.id), ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000003"])
        XCTAssertEqual(rows[0].pixelWidth, 100)
        XCTAssertNil(rows[0].hasAnnotations)
        XCTAssertEqual(rows[1].hasAnnotations, true)
        XCTAssertEqual(rows[1].fileExtension, "jpg")
    }

    func testHistoryRowMissingEverythingButIdStillLoads() throws {
        let rows = try XCTUnwrap(
            LenientArrayDecoder.decode(ScreenshotHistory.IndexEntry.self, from: Data("""
            [{"id":"00000000-0000-0000-0000-000000000004"}]
            """.utf8)))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].fileExtension, "png", "a row with no extension falls back to the original format")
    }

    // MARK: - LenientArrayDecoder itself

    func testLenientArrayDecoderReturnsNilForNonArrayData() {
        XCTAssertNil(LenientArrayDecoder.decode(CodableAnnotation.self, from: Data("{}".utf8)))
        XCTAssertNil(LenientArrayDecoder.decode(CodableAnnotation.self, from: Data("garbage".utf8)))
    }

    func testLenientArrayDecoderReturnsNilWhenEveryElementIsCorrupt() {
        XCTAssertNil(LenientArrayDecoder.decode(CodableAnnotation.self, from: Data("[{},{},{}]".utf8)))
    }

    func testLenientArrayDecoderKeepsOrder() throws {
        let json = "[" + (0..<5).map { #"{"tool":\#($0),"startX":\#($0)}"# }.joined(separator: ",") + "]"
        let decoded = try XCTUnwrap(LenientArrayDecoder.decode(CodableAnnotation.self, from: Data(json.utf8)))
        XCTAssertEqual(decoded.map(\.tool), [0, 1, 2, 3, 4])
    }
}
