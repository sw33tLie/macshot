import AudioToolbox
import CoreMedia
import XCTest

final class SampleBufferTimingTests: XCTestCase {
    private func buffer(samples: Int, rate: Int32 = 48_000,
                        timings supplied: [CMSampleTimingInfo]? = nil) throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description), noErr)
        var data: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: samples * 4, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: samples * 4,
            flags: 0, blockBufferOut: &data), noErr)
        let block = try XCTUnwrap(data)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0x3f, blockBuffer: block,
                                                offsetIntoDestination: 0, dataLength: samples * 4), noErr)
        let timings = supplied ?? [CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate),
            presentationTimeStamp: CMTime(value: 12, timescale: 1), decodeTimeStamp: .invalid)]
        var bytesPerSample = 4
        var sample: CMSampleBuffer?
        let status = timings.withUnsafeBufferPointer { values in
            CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                formatDescription: description, sampleCount: samples, sampleTimingEntryCount: timings.count,
                sampleTimingArray: values.baseAddress, sampleSizeEntryCount: 1,
                sampleSizeArray: &bytesPerSample, sampleBufferOut: &sample)
        }
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(sample)
    }

    private func timing(_ sample: CMSampleBuffer, at index: Int) throws -> CMSampleTimingInfo {
        var value = CMSampleTimingInfo()
        XCTAssertEqual(CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &value), noErr)
        return value
    }

    func testRetimingPCMPreservesTheDurationOfEverySampleAndTheWholeBuffer() throws {
        for rate: Int32 in [44_100, 48_000] {
            for count in [1, 512, 1024, 4096] {
                let source = try buffer(samples: count, rate: rate)
                let result = try XCTUnwrap(SampleBufferTiming.retimed(source, to: .zero))
                XCTAssertEqual(CMSampleBufferGetNumSamples(result), count)
                XCTAssertEqual(CMSampleBufferGetDuration(result), CMSampleBufferGetDuration(source))
                XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(result), .zero)
                let last = try timing(result, at: count - 1)
                XCTAssertEqual(last.duration, CMTime(value: 1, timescale: rate))
                XCTAssertEqual(last.presentationTimeStamp, CMTime(value: Int64(count - 1), timescale: rate))
                let resultData = try XCTUnwrap(CMSampleBufferGetDataBuffer(result))
                var bytes = [UInt8](repeating: 0, count: count * 4)
                XCTAssertEqual(CMBlockBufferCopyDataBytes(resultData, atOffset: 0,
                    dataLength: bytes.count, destination: &bytes), noErr)
                XCTAssertTrue(bytes.allSatisfy { $0 == 0x3f }, "retiming must not change PCM samples")
            }
        }
    }

    func testIndividualPresentationAndDecodeTimesRetainTheirSpacing() throws {
        let duration = CMTime(value: 1, timescale: 48_000)
        let entries = [0, 3, 9].map { value in
            CMSampleTimingInfo(duration: duration,
                presentationTimeStamp: CMTime(value: 480_000 + Int64(value), timescale: 48_000),
                decodeTimeStamp: CMTime(value: 479_999 + Int64(value), timescale: 48_000))
        }
        let source = try buffer(samples: 3, timings: entries)
        let shift = CMTime(value: -3, timescale: 1)
        let result = try XCTUnwrap(SampleBufferTiming.shifted(source, by: shift))
        for index in entries.indices {
            let before = try timing(source, at: index)
            let after = try timing(result, at: index)
            XCTAssertEqual(after.duration, before.duration)
            XCTAssertEqual(after.presentationTimeStamp, CMTimeAdd(before.presentationTimeStamp, shift))
            XCTAssertEqual(after.decodeTimeStamp, CMTimeAdd(before.decodeTimeStamp, shift))
        }
    }

    func testPauseOffsetsInAnEightHourTimelineDoNotAccumulateSampleDurationError() throws {
        let source = try buffer(samples: 1024)
        let start = CMTime(value: 8 * 60 * 60 * 48_000 + 17, timescale: 48_000)
        var result = try XCTUnwrap(SampleBufferTiming.retimed(source, to: start))
        let pause = CMTime(value: -1001, timescale: 48_000)
        for _ in 0..<100 {
            result = try XCTUnwrap(SampleBufferTiming.shifted(result, by: pause))
        }
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(result),
                       CMTimeAdd(start, CMTimeMultiply(pause, multiplier: 100)))
        XCTAssertEqual(CMSampleBufferGetDuration(result), CMSampleBufferGetDuration(source))
        XCTAssertFalse(try timing(result, at: 0).decodeTimeStamp.isValid)
    }

    func testInvalidTimeRequestsAreRejected() throws {
        let source = try buffer(samples: 1024)
        for invalid in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity] {
            XCTAssertNil(SampleBufferTiming.shifted(source, by: invalid))
            XCTAssertNil(SampleBufferTiming.retimed(source, to: invalid))
        }
    }
}
