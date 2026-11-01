import AVFoundation
import CryptoKit
import XCTest

final class AudioTrackMixerTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func source() async throws -> URL {
        try await RecordingMediaFixture.mixedMovie(in: directory)
    }

    private func compressedVideo(_ url: URL) throws -> (String, [Double], CGAffineTransform) {
        let asset = AVAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var hash = SHA256()
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = sample.dataBuffer else {
                // AVAssetReader may return timing-only markers. Compare the
                // compressed media samples, which are the bytes being preserved.
                continue
            }
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            bytes.withUnsafeMutableBytes { buffer in
                XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: buffer.count,
                    destination: buffer.baseAddress!), noErr)
            }
            hash.update(data: bytes)
            times.append(sample.presentationTimeStamp.seconds)
        }
        XCTAssertEqual(reader.status, .completed)
        return (hash.finalize().description, times, track.preferredTransform)
    }

    private func audio(_ url: URL, channel: Int = 0) throws -> [Float] {
        let asset = AVAsset(url: url)
        let tracks = asset.tracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1, "The result must be one playable mix, not two separate tracks")
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            let block = try XCTUnwrap(sample.dataBuffer)
            var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
            values.withUnsafeMutableBytes { buffer in
                XCTAssertEqual(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: buffer.count,
                    destination: buffer.baseAddress!), noErr)
            }
            result.append(contentsOf: stride(from: 0, to: values.count, by: 2).map { values[$0 + channel] })
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(result.count, 90_000)
        return result
    }

    private func amplitude(_ samples: [Float], frequency: Double) -> Double {
        // Omit encoder priming and the end pad. Phase-independent correlation
        // identifies the tones despite AAC's small sample/phase differences.
        let range = 12_000..<min(84_000, samples.count)
        var real = 0.0
        var imaginary = 0.0
        for index in range {
            let phase = 2 * Double.pi * frequency * Double(index) / 48_000
            real += Double(samples[index]) * cos(phase)
            imaginary += Double(samples[index]) * sin(phase)
        }
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(range.count)
    }

    func testVolumesAndMuteAreAppliedToOneAACTrackWithoutReencodingVideo() async throws {
        let source = try await source()
        let sourceBytes = try Data(contentsOf: source)
        let originalVideo = try compressedVideo(source)
        XCTAssertEqual(originalVideo.1.count, 60)
        var levels: [[Double]] = []
        for volumes: [Float] in [[1, 0], [0, 1], [1, 1], [0, 0]] {
            let destination = directory.appendingPathComponent(UUID().uuidString + ".mp4")
            try await AudioTrackMixer.export(source: source, destination: destination, volumes: volumes)
            XCTAssertTrue(try MP4Boxes.isFastStart(destination), "mixed copies put the index first (#452)")
            let samples = try audio(destination)
            if volumes == [0, 1] {
                let right = try audio(destination, channel: 1)
                XCTAssertGreaterThan(amplitude(right, frequency: 1320), 0.1)
                XCTAssertLessThan(amplitude(right, frequency: 880), 0.005)
                XCTAssertLessThan(amplitude(samples, frequency: 1320), 0.005)
            }
            levels.append([amplitude(samples, frequency: 440), amplitude(samples, frequency: 880)])
            let outputVideo = try compressedVideo(destination)
            XCTAssertEqual(outputVideo.0, originalVideo.0, "H.264 sample bytes must pass through unchanged")
            XCTAssertEqual(outputVideo.1.count, originalVideo.1.count)
            for (actual, expected) in zip(outputVideo.1, originalVideo.1) { XCTAssertEqual(actual, expected, accuracy: 0.0001) }
            XCTAssertEqual(outputVideo.2, originalVideo.2)
            XCTAssertEqual(AVAsset(url: destination).duration.seconds, 2, accuracy: 0.04)
            XCTAssertEqual(VideoFrameCadence.declaredDuration(in: AVAsset(url: destination).metadata),
                           CMTime(value: 1, timescale: 30))
        }
        XCTAssertGreaterThan(levels[0][0], 0.1)
        XCTAssertLessThan(levels[0][1], levels[0][0] * 0.05, "Muted system tone must be absent")
        XCTAssertGreaterThan(levels[1][1], 0.1)
        XCTAssertLessThan(levels[1][0], levels[1][1] * 0.05, "Muted mic tone must be absent")
        XCTAssertEqual(levels[2][0] / levels[0][0], 0.5, accuracy: 0.08)
        XCTAssertEqual(levels[2][1] / levels[1][1], 0.5, accuracy: 0.08)
        XCTAssertLessThan(levels[3].max() ?? 1, 0.0001)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes, "Mixing must retain the original take")
    }

    func testCancellationAndInvalidVolumesDoNotPublishOrAlterTheOriginal() async throws {
        let source = try await source()
        let original = try Data(contentsOf: source)
        let destination = directory.appendingPathComponent("cancelled.mp4")
        let task = Task { try await AudioTrackMixer.export(source: source, destination: destination, volumes: [1, 1]) }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled export must not succeed") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        for volumes: [Float] in [[.nan, 1], [1.5, 1], [-1, 0], [1]] {
            do {
                try await AudioTrackMixer.export(source: source, destination: destination, volumes: volumes)
                XCTFail("Invalid volumes must not export")
            } catch { XCTAssertTrue(error is AudioTrackMixer.MixError) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testMixCannotOverwriteTheOriginalOrAnExistingDestination() async throws {
        let source = try await source()
        let original = try Data(contentsOf: source)
        do {
            try await AudioTrackMixer.export(source: source, destination: source, volumes: [1, 1])
            XCTFail("Original must never be replaced by a mix")
        } catch { XCTAssertTrue(error is AudioTrackMixer.MixError) }
        let destination = directory.appendingPathComponent("existing.mp4")
        let existing = Data("another recording".utf8)
        try existing.write(to: destination)
        do {
            try await AudioTrackMixer.export(source: source, destination: destination, volumes: [1, 1])
            XCTFail("Existing output must not be silently overwritten")
        } catch { XCTAssertEqual(try Data(contentsOf: destination), existing) }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testAppCancellationTokenPreventsPublicationEvenWithoutCancellingTheTask() async throws {
        let source = try await source()
        let original = try Data(contentsOf: source)
        let destination = directory.appendingPathComponent("token-cancelled.mp4")
        let cancellation = MediaExportCancellation()
        do {
            try await AudioTrackMixer.export(source: source, destination: destination,
                volumes: [1, 1], cancellation: cancellation) { _ in
                cancellation.cancel()
            }
            XCTFail("A cancelled publication token must not publish the mix")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testVideoOrientationSurvivesTheAudioMix() async throws {
        let source = try await source()
        let asset = AVAsset(url: source)
        let composition = AVMutableComposition()
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0)
        for track in asset.tracks {
            let copy = try XCTUnwrap(composition.addMutableTrack(withMediaType: track.mediaType,
                preferredTrackID: kCMPersistentTrackID_Invalid))
            try copy.insertTimeRange(track.timeRange, of: track, at: track.timeRange.start)
            if track.mediaType == .video { copy.preferredTransform = rotation }
        }
        let rotated = directory.appendingPathComponent("rotated.mp4")
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        exporter.outputURL = rotated
        exporter.outputFileType = .mp4
        await exporter.export()
        XCTAssertEqual(exporter.status, .completed)
        XCTAssertEqual(try compressedVideo(rotated).2, rotation)
        let mixed = directory.appendingPathComponent("rotated-mix.mp4")
        try await AudioTrackMixer.export(source: rotated, destination: mixed, volumes: [1, 1])
        let before = try compressedVideo(rotated)
        let after = try compressedVideo(mixed)
        XCTAssertEqual(after.2, rotation)
        XCTAssertEqual(after.0, before.0)
    }

    func testCancellationAfterThePumpStartsPreservesTheSourceAndPublishesNothing() async throws {
        let source = try await source()
        let original = try Data(contentsOf: source)
        let destination = directory.appendingPathComponent("cancel-after-start.mp4")
        let cancellation = MixCancellation()
        let task = Task {
            try await AudioTrackMixer.export(source: source, destination: destination, volumes: [1, 1]) { _ in
                cancellation.progress()
            }
        }
        cancellation.install { task.cancel() }
        defer { cancellation.clear() }
        do { try await task.value; XCTFail("Cancellation during export must not publish a file") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}

private final class MixCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks = 0
    private var cancel: (() -> Void)?
    func install(_ action: @escaping () -> Void) {
        lock.lock()
        cancel = action
        let requested = callbacks >= 2
        lock.unlock()
        if requested { action() }
    }
    func progress() {
        lock.lock()
        callbacks += 1
        let action = callbacks == 2 ? cancel : nil
        lock.unlock()
        action?()
    }
    func clear() { lock.lock(); cancel = nil; lock.unlock() }
}
