import AVFoundation
import XCTest

final class RecordingAudioSilenceTests: XCTestCase {
    func testOnlyAStarvedSystemTrackBlockingAnotherInputIsAdvanced() {
        let start = CMTime(value: 100, timescale: 1)
        let progress = CMTime(value: 102, timescale: 1)
        XCTAssertNil(RecordingAudioSilence.target(boundary: start, progress: progress,
            hasQueuedAudio: false, siblingStalled: false))
        XCTAssertNil(RecordingAudioSilence.target(boundary: start, progress: progress,
            hasQueuedAudio: true, siblingStalled: true))
        XCTAssertNil(RecordingAudioSilence.target(boundary: start, progress: CMTime(value: 1001, timescale: 10),
            hasQueuedAudio: false, siblingStalled: true))
        XCTAssertEqual(RecordingAudioSilence.target(boundary: start, progress: progress,
            hasQueuedAudio: false, siblingStalled: true), CMTime(value: 1019, timescale: 10))
    }
    func testAnEightHourGapAllocatesOnlyOneSmallOwnedPCMBuffer() throws {
        let format = try XCTUnwrap(RecordingAudioSilence.systemFormat())
        let sample = try XCTUnwrap(RecordingAudioSilence.buffer(from: CMTime(value: 100, timescale: 1),
            to: CMTime(value: 28_900, timescale: 1), format: format))
        XCTAssertEqual(sample.numSamples, 4_800)
        XCTAssertEqual(sample.duration.seconds, 0.1, accuracy: 1e-9)
        XCTAssertTrue(RecordingSampleValidation.isValidAudio(sample))
        let planes = try RecordingMediaFixture.planarChannels(sample)
        XCTAssertEqual(planes.count, 2)
        XCTAssertTrue(planes.allSatisfy { $0.count == 4_800 && $0.allSatisfy { $0 == 0 } })
    }

    func testSilenceNeverRunsPastTheIncomingRealSample() throws {
        let format = try XCTUnwrap(RecordingAudioSilence.systemFormat())
        let start = CMTime(value: 4_800_000, timescale: 48_000)
        let end = CMTimeAdd(start, CMTime(value: 137, timescale: 48_000))
        let sample = try XCTUnwrap(RecordingAudioSilence.buffer(from: start, to: end, format: format))
        XCTAssertEqual(sample.numSamples, 137)
        XCTAssertEqual(CMTimeAdd(sample.presentationTimeStamp, sample.duration), end)
        XCTAssertNil(RecordingAudioSilence.buffer(from: start, to: start, format: format))
        XCTAssertNil(RecordingAudioSilence.buffer(from: .invalid, to: end, format: format))
    }
}
