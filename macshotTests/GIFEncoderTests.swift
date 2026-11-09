import AVFoundation
import ImageIO
import XCTest

/// Independent decoding verifies the streaming container, palettes and timing.
/// These are accelerated media tests, not real recording endurance tests.
final class GIFEncoderTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private var output: URL { directory.appendingPathComponent("out.gif") }
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000_000) }

    func testVariablePresentationTimesAndFinalHoldDecodeCorrectly() throws {
        let encoder = try GIFEncoder(url: output)
        let times = [0.0, 0.1, 0.45]
        for (index, seconds) in times.enumerated() {
            try encoder.addFrame(GIFTestMedia.pixels(color: index), at: time(seconds))
        }
        try encoder.finish(at: time(1.25))
        let frames = try GIFTestMedia.decode(output)
        XCTAssertEqual(frames.delays.count, 3)
        for (actual, expected) in zip(frames.delays, [0.1, 0.35, 0.8]) { XCTAssertEqual(actual, expected, accuracy: 0.001) }
        XCTAssertEqual(frames.colors, [0, 1, 2])
        XCTAssertEqual(frames.loopCount, 0)
    }

    func testUnchangedFramesCoalesceAndEightHourHoldSplitsWithoutReencoding() throws {
        let encoder = try GIFEncoder(url: output)
        let pixels = try GIFTestMedia.pixels(color: 0)
        for index in 0..<3000 { try encoder.addFrame(pixels, at: CMTime(value: Int64(index), timescale: 30)) }
        // Only the header exists until an image changes or the final hold ends.
        XCTAssertLessThan(try Data(contentsOf: output).count, 100)
        try encoder.finish(at: time(8 * 3600))
        let frames = try GIFTestMedia.decode(output)
        XCTAssertEqual(frames.delays.count, 44)
        XCTAssertEqual(frames.delays.reduce(0, +), 8 * 3600, accuracy: 0.01)
        XCTAssertTrue(frames.delays.allSatisfy { $0 > 0 && $0 <= 655.35 })
        XCTAssertTrue(frames.colors.allSatisfy { $0 == 0 })
        XCTAssertLessThan(try Data(contentsOf: output).count, 10_000)
    }

    func testFractionalFramePeriodsHaveNoCumulativeDrift() throws {
        for fps in [5, 15, 24, 30] {
            let url = directory.appendingPathComponent("\(fps).gif")
            let encoder = try GIFEncoder(url: url)
            for index in 0..<(fps * 4) {
                try encoder.addFrame(GIFTestMedia.pixels(color: index % 3), at: CMTime(value: Int64(index), timescale: CMTimeScale(fps)))
            }
            try encoder.finish(at: time(4))
            let frames = try GIFTestMedia.decode(url)
            XCTAssertEqual(frames.delays.count, fps * 4)
            XCTAssertEqual(frames.delays.reduce(0, +), 4, accuracy: 0.001)
            XCTAssertTrue(frames.delays.allSatisfy { $0 > 0 })
        }
    }

    func testVeryShortClipGetsTheMinimumRepresentablePositiveHold() throws {
        let encoder = try GIFEncoder(url: output)
        try encoder.addFrame(GIFTestMedia.pixels(color: 2), at: .zero)
        try encoder.finish(at: time(0.001))
        XCTAssertEqual(try GIFTestMedia.decode(output).delays, [0.01])
    }

    func testPaddedRowsAndRecycledBufferDoNotChangePreviousFrames() throws {
        let encoder = try GIFEncoder(url: output)
        let pixels = try GIFTestMedia.pixels(color: 0, width: 37, height: 11)
        try encoder.addFrame(pixels, at: .zero)
        GIFTestMedia.fill(pixels, color: 1)
        try encoder.addFrame(pixels, at: time(0.1))
        GIFTestMedia.fill(pixels, color: 2)
        try encoder.finish(at: time(0.2))
        let frames = try GIFTestMedia.decode(output)
        XCTAssertEqual(frames.colors, [0, 1])
        XCTAssertEqual(frames.size, CGSize(width: 37, height: 11))
    }

    func testExistingDestinationSurvivesFailedInitialization() throws {
        let original = Data("Existing user's file".utf8)
        try original.write(to: output)
        XCTAssertThrowsError(try GIFEncoder(url: output))
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testChangedRectanglesPreserveAndErasePreviouslyDisplayedPixels() throws {
        let encoder = try GIFEncoder(url: output)
        let buffer = try GIFTestMedia.pixels(color: 1, width: 64, height: 32)
        for (index, x) in [4, 12, 20].enumerated() {
            GIFTestMedia.fill(buffer, color: 1)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            for y in 8..<12 {
                for column in x..<(x + 4) {
                    let offset = y * CVPixelBufferGetBytesPerRow(buffer) + column * 4
                    base[offset + 1] = 0; base[offset + 2] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try encoder.addFrame(buffer, at: time(Double(index) / 10))
        }
        try encoder.finish(at: time(0.3))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        for index in 0..<3 {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 32)
            for (position, x) in [5, 13, 21].enumerated() {
                let crop = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: 9, width: 1, height: 1)))
                let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
                XCTAssertGreaterThan(bytes[position == index ? 0 : 1], 220)
                XCTAssertLessThan(bytes[position == index ? 1 : 0], 30)
            }
        }
    }

    func testInvalidTimingAbortsAndRemovesPartialOutput() throws {
        for invalid in [CMTime.invalid, .indefinite, .positiveInfinity, time(-1), .zero] {
            let encoder = try GIFEncoder(url: output)
            try encoder.addFrame(GIFTestMedia.pixels(color: 0), at: .zero)
            XCTAssertThrowsError(try encoder.addFrame(GIFTestMedia.pixels(color: 1), at: invalid))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertThrowsError(try encoder.finish(at: time(1)))
        }
    }

    func testMissingFramesOrDirectoryAreReported() throws {
        let encoder = try GIFEncoder(url: output)
        XCTAssertThrowsError(try encoder.finish(at: time(1)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertThrowsError(try GIFEncoder(url: directory.appendingPathComponent("missing/out.gif")))
    }

    func testCompletedFileSurvivesRepeatedFinishAndInvalidAppend() throws {
        let encoder = try GIFEncoder(url: output)
        try encoder.addFrame(GIFTestMedia.pixels(color: 0), at: .zero)
        try encoder.finish(at: time(1))
        let original = try Data(contentsOf: output)
        try encoder.finish(at: time(1))
        XCTAssertThrowsError(try encoder.addFrame(GIFTestMedia.pixels(color: 1), at: time(1)))
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testWriteFailureIsThrownAndPartialFileIsRemoved() throws {
        let encoder = try GIFEncoder(url: output, writeData: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try encoder.addFrame(GIFTestMedia.pixels(color: 0), at: .zero)) { error in
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}

enum GIFTestMedia {
    static func pixels(color: Int, width: Int = 16, height: Int = 16) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        fill(pixels, color: color)
        return pixels
    }

    static func fill(_ pixels: CVPixelBuffer, color: Int) {
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<CVPixelBufferGetHeight(pixels) {
            for x in 0..<CVPixelBufferGetWidth(pixels) {
                let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                for channel in 0..<3 { base[offset + channel] = channel == 2 - color ? 255 : 0 }
                base[offset + 3] = 255
            }
        }
    }

    static func decode(_ url: URL) throws -> (delays: [Double], colors: [Int], loopCount: Int?, size: CGSize) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        var delays: [Double] = [], colors: [Int] = []
        var size = CGSize.zero
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let frameGIF = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            delays.append(try XCTUnwrap(frameGIF[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? frameGIF[kCGImagePropertyGIFDelayTime] as? Double))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            size = CGSize(width: image.width, height: image.height)
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let rgb = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            colors.append((0..<3).max(by: { rgb[$0] < rgb[$1] })!)
        }
        return (delays, colors, gif?[kCGImagePropertyGIFLoopCount] as? Int, size)
    }
}
