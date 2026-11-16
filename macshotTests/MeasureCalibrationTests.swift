import Cocoa
import XCTest

/// Real-world measuring (#497): people type lengths the way a tape measure or
/// a spec sheet writes them, and the result has to survive history/projects.
final class MeasureCalibrationTests: XCTestCase {

    private let posix = Locale(identifier: "en_US_POSIX")

    // MARK: - Parsing

    private func parse(_ text: String, _ unit: MeasureUnit = .millimeters) -> MeasureLength? {
        MeasureLengthParser.parse(text, defaultUnit: unit)
    }

    private func assertLength(_ text: String, _ value: Double, _ unit: MeasureUnit,
                              default defaultUnit: MeasureUnit = .millimeters,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let parsed = parse(text, defaultUnit) else {
            return XCTFail("\"\(text)\" did not parse", file: file, line: line)
        }
        XCTAssertEqual(parsed.unit, unit, "\"\(text)\"", file: file, line: line)
        XCTAssertEqual(parsed.value, value, accuracy: 1e-9, "\"\(text)\"", file: file, line: line)
    }

    func testPlainNumbersUseTheChosenUnit() {
        assertLength("90", 90, .millimeters)
        assertLength("  90  ", 90, .millimeters)
        assertLength("3.5", 3.5, .inches, default: .inches)
        assertLength("3,5", 3.5, .centimeters, default: .centimeters)
        assertLength(".5", 0.5, .meters, default: .meters)
    }

    func testTypedUnitsWinOverTheMenu() {
        assertLength("90 mm", 90, .millimeters, default: .inches)
        assertLength("90mm", 90, .millimeters, default: .inches)
        assertLength("2.4 m", 2.4, .meters)
        assertLength("12 cm", 12, .centimeters)
        assertLength("3 in", 3, .inches)
        assertLength("3 inches", 3, .inches)
        assertLength("3\"", 3, .inches)
        assertLength("8 ft", 8, .feet)
        assertLength("8'", 8, .feet)
        assertLength("1 metre", 1, .meters)
        assertLength("90 MM", 90, .millimeters)
    }

    func testFractionsAsOnATapeMeasure() {
        assertLength("3 1/2 in", 3.5, .inches)
        assertLength("3-1/2\"", 3.5, .inches)
        assertLength("1/2", 0.5, .inches, default: .inches)
        assertLength("3½", 3.5, .inches, default: .inches)
        assertLength("3 ½ in", 3.5, .inches)
        assertLength("¾ in", 0.75, .inches)
        assertLength("5 3/16", 5.1875, .inches, default: .inches)
    }

    func testFeetAndInchesCombine() {
        assertLength("6' 2\"", 6 + 2.0 / 12, .feet)
        assertLength("6'2\"", 6 + 2.0 / 12, .feet)
        assertLength("6 ft 2 1/2 in", 6 + 2.5 / 12, .feet)
        assertLength("6 ft 2", 6 + 2.0 / 12, .feet)
        assertLength("1 m 50 cm", 1.5, .meters)
    }

    func testNonsenseIsRejected() {
        for text in ["", "   ", "abc", "mm", "0", "0 mm", "-3", "3/0", "1 2", "2 in 3 ft", "3 1/2/4",
                     "12 mmx", "9e99999", "1 in 2 in"] {
            XCTAssertNil(parse(text), "\"\(text)\" should not parse")
        }
    }

    // MARK: - Formatting

    func testMetricFormattingKeepsSensiblePrecision() {
        XCTAssertEqual(MeasureLengthFormatter.string(for: 3.456, unit: .millimeters, locale: posix), "3.46 mm")
        XCTAssertEqual(MeasureLengthFormatter.string(for: 34.56, unit: .millimeters, locale: posix), "34.6 mm")
        XCTAssertEqual(MeasureLengthFormatter.string(for: 345.6, unit: .millimeters, locale: posix), "346 mm")
        XCTAssertEqual(MeasureLengthFormatter.string(for: 1.25, unit: .meters, locale: posix), "1.25 m")
        XCTAssertEqual(MeasureLengthFormatter.string(for: 2.5, unit: .centimeters,
                                                     locale: Locale(identifier: "de_DE")), "2,50 cm")
    }

    func testImperialFormattingUsesSixteenths() {
        XCTAssertEqual(MeasureLengthFormatter.string(for: 3.5, unit: .inches), "3 1/2 in")
        XCTAssertEqual(MeasureLengthFormatter.string(for: 0.25, unit: .inches), "1/4 in")
        XCTAssertEqual(MeasureLengthFormatter.string(for: 2.0, unit: .inches), "2 in")
        XCTAssertEqual(MeasureLengthFormatter.string(for: 5.19, unit: .inches), "5 3/16 in")
        XCTAssertEqual(MeasureLengthFormatter.string(for: 6 + 2.5 / 12, unit: .feet), "6 ft 2 1/2 in")
        XCTAssertEqual(MeasureLengthFormatter.string(for: 4, unit: .feet), "4 ft")
        XCTAssertEqual(MeasureLengthFormatter.string(for: 0.5, unit: .feet), "6 in")
        // 11 31/32 in rounds up to a whole foot, never "0 ft 12 in".
        XCTAssertEqual(MeasureLengthFormatter.string(for: (11 + 31.0 / 32) / 12, unit: .feet), "1 ft")
    }

    func testFormattedLengthsParseBack() {
        for (value, unit) in [(3.5, MeasureUnit.inches), (6 + 2.5 / 12, .feet), (34.5, .millimeters), (1.25, .meters)] {
            let text = MeasureLengthFormatter.string(for: value, unit: unit, locale: posix)
            let parsed = MeasureLengthParser.parse(text, defaultUnit: .centimeters)
            XCTAssertEqual(parsed?.unit, unit, text)
            XCTAssertEqual(parsed?.value ?? -1, value, accuracy: 0.01, text)
        }
    }

    // MARK: - Calibration

    func testCalibrationMapsTheReferenceToItsLength() throws {
        // A 90 mm brick drawn 270 points long: 3 points per mm.
        let calibration = try XCTUnwrap(MeasureCalibration(
            referencePoints: 270, length: MeasureLength(value: 90, unit: .millimeters)))
        XCTAssertEqual(calibration.pointsPerUnit, 3, accuracy: 1e-12)
        XCTAssertEqual(calibration.length(ofPoints: 600), 200, accuracy: 1e-12)
        XCTAssertEqual(calibration.format(points: 600, locale: posix), "200 mm")

        let inches = calibration.converted(to: .inches)
        XCTAssertEqual(inches.length(ofPoints: 600), 200 / 25.4, accuracy: 1e-9)
    }

    func testUnusableCalibrationsAreRefused() {
        XCTAssertNil(MeasureCalibration(referencePoints: 0, length: MeasureLength(value: 1, unit: .inches)))
        XCTAssertNil(MeasureCalibration(referencePoints: 100, length: MeasureLength(value: 0, unit: .inches)))
        XCTAssertNil(MeasureCalibration(referencePoints: .nan, length: MeasureLength(value: 1, unit: .inches)))
        XCTAssertNil(MeasureCalibration(referencePoints: 100, length: MeasureLength(value: .infinity, unit: .mm)))
    }

    func testDecodingDropsBrokenOrUnknownScales() throws {
        let decoder = JSONDecoder()
        let good = try decoder.decode(MeasureCalibration.self,
                                      from: Data(#"{"pointsPerUnit": 2.5, "unit": "cm"}"#.utf8))
        XCTAssertEqual(good, MeasureCalibration(pointsPerUnit: 2.5, unit: .centimeters))
        for json in [#"{"pointsPerUnit": 2.5, "unit": "furlong"}"#, #"{"pointsPerUnit": 0, "unit": "cm"}"#,
                     #"{"unit": "cm"}"#] {
            XCTAssertThrowsError(try decoder.decode(MeasureCalibration.self, from: Data(json.utf8)), json)
        }
    }

    func testEditStateKeepsTheScaleAndOlderStatesStillDecode() throws {
        var state = CaptureEditState()
        XCTAssertFalse(state.hasEditableState)
        state.measureCalibration = MeasureCalibration(pointsPerUnit: 4, unit: .feet)
        XCTAssertTrue(state.hasEditableState, "a scale alone is worth saving with the capture")
        XCTAssertFalse(state.hasPostProcessing, "a scale changes no pixels")

        let decoded = try JSONDecoder().decode(CaptureEditState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.measureCalibration, state.measureCalibration)

        let legacy = try JSONDecoder().decode(CaptureEditState.self, from: Data(#"{"beautifyEnabled": true}"#.utf8))
        XCTAssertNil(legacy.measureCalibration)
    }
}

private extension MeasureUnit {
    static let mm = MeasureUnit.millimeters
}

/// The canvas side: one scale for the whole image, every measure line
/// relabelled with it, one undo step to take it back.
@MainActor
final class MeasureScaleCanvasTests: XCTestCase {

    private func makeEditor() -> EditorView {
        let view = EditorView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        view.screenshotImage = ImageProbe.quadrantImage(width: 300, height: 200)
        view.applySelection(NSRect(x: 0, y: 0, width: 300, height: 200))
        return view
    }

    private func measure(_ length: CGFloat) -> Annotation {
        Annotation(tool: .measure, startPoint: NSPoint(x: 10, y: 10),
                   endPoint: NSPoint(x: 10 + length, y: 10), color: .red, strokeWidth: 2)
    }

    func testSettingAScaleRelabelsEveryMeasureLineAndUndoesInOneStep() {
        let editor = makeEditor()
        let a = measure(100), b = measure(50)
        let arrow = Annotation(tool: .arrow, startPoint: .zero, endPoint: NSPoint(x: 5, y: 5), color: .red, strokeWidth: 2)
        editor.annotations = [a, arrow, b]
        editor.undoStack = [.added(a), .added(arrow), .added(b)]
        let scale = MeasureCalibration(pointsPerUnit: 2, unit: .millimeters)

        editor.setMeasureCalibration(scale)
        XCTAssertEqual(editor.measureCalibration, scale)
        XCTAssertEqual(a.measureCalibration, scale)
        XCTAssertEqual(b.measureCalibration, scale)
        XCTAssertNil(arrow.measureCalibration)
        XCTAssertEqual(editor.undoStack.count, 4)

        editor.undo()
        XCTAssertNil(editor.measureCalibration)
        XCTAssertNil(a.measureCalibration)
        XCTAssertNil(b.measureCalibration)
        XCTAssertEqual(editor.annotations.count, 3, "undoing the scale must not remove a line")

        editor.redo()
        XCTAssertEqual(editor.measureCalibration, scale)
        XCTAssertEqual(a.measureCalibration, scale)

        editor.setMeasureCalibration(nil)
        XCTAssertNil(a.measureCalibration)
        editor.undo()
        XCTAssertEqual(a.measureCalibration, scale)
    }

    func testAReusedOverlayForgetsThePreviousCapturesScale() {
        // Overlay views are pooled per display; one capture's scale must not
        // label the next capture's measurements.
        let overlay = OverlayView()
        overlay.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        overlay.setMeasureCalibration(MeasureCalibration(pointsPerUnit: 2, unit: .millimeters))
        overlay.isAwaitingMeasureReference = true
        overlay.reset()
        XCTAssertNil(overlay.measureCalibration)
        XCTAssertFalse(overlay.isAwaitingMeasureReference)
        XCTAssertNil(overlay.captureEditState().measureCalibration)
    }

    func testSettingTheSameScaleTwiceIsNotAnEdit() {
        let editor = makeEditor()
        let scale = MeasureCalibration(pointsPerUnit: 2, unit: .millimeters)
        editor.setMeasureCalibration(scale)
        let depth = editor.undoStack.count
        editor.setMeasureCalibration(scale)
        XCTAssertEqual(editor.undoStack.count, depth)
    }

    func testRestoredCapturesAdoptTheScaleTheirLinesCarry() {
        let editor = makeEditor()
        let line = measure(80)
        line.measureCalibration = MeasureCalibration(pointsPerUnit: 8, unit: .inches)
        editor.setAnnotations([line])
        XCTAssertEqual(editor.measureCalibration, line.measureCalibration)

        // An edit state's own scale wins over whatever the lines carry.
        var state = CaptureEditState()
        state.measureCalibration = MeasureCalibration(pointsPerUnit: 3, unit: .centimeters)
        editor.applyCaptureEditState(state)
        XCTAssertEqual(editor.measureCalibration, state.measureCalibration)
        XCTAssertEqual(editor.captureEditState().measureCalibration, state.measureCalibration)
    }

    func testCalibratedLabelsRenderWithoutCrashingAtAnyAngle() throws {
        let editor = makeEditor()
        let lines = [
            Annotation(tool: .measure, startPoint: NSPoint(x: 10, y: 10), endPoint: NSPoint(x: 200, y: 10), color: .red, strokeWidth: 2),
            Annotation(tool: .measure, startPoint: NSPoint(x: 10, y: 10), endPoint: NSPoint(x: 10, y: 150), color: .red, strokeWidth: 2),
            Annotation(tool: .measure, startPoint: NSPoint(x: 10, y: 10), endPoint: NSPoint(x: 120, y: 90), color: .red, strokeWidth: 2),
        ]
        editor.annotations = lines
        editor.setMeasureCalibration(MeasureCalibration(pointsPerUnit: 7.3, unit: .feet))
        editor.cachedCompositedImage = nil
        XCTAssertNotNil(editor.compositedImage())
    }
}
