import CoreMedia

/// Timestamp changes shared by recording pause removal and offline exports.
/// A timing entry's duration describes one sample, not the entire buffer.
enum SampleBufferTiming {
    nonisolated static func shifted(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset.isNumeric else { return nil }
        if CMTimeCompare(offset, .zero) == 0 { return sample }

        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0,
                                                     arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var timings = Array(repeating: CMSampleTimingInfo(duration: .invalid,
                                                         presentationTimeStamp: .invalid,
                                                         decodeTimeStamp: .invalid), count: count)
        let readStatus = timings.withUnsafeMutableBufferPointer { buffer in
            CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count,
                                                   arrayToFill: buffer.baseAddress, entriesNeededOut: nil)
        }
        guard readStatus == noErr else { return nil }
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isNumeric {
                timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, offset)
            }
            if timings[index].decodeTimeStamp.isNumeric {
                timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, offset)
            }
        }
        var result: CMSampleBuffer?
        let status = timings.withUnsafeBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                  sampleBuffer: sample, sampleTimingEntryCount: count,
                                                  sampleTimingArray: buffer.baseAddress, sampleBufferOut: &result)
        }
        return status == noErr ? result : nil
    }

    nonisolated static func retimed(_ sample: CMSampleBuffer, to presentationTime: CMTime) -> CMSampleBuffer? {
        let originalTime = CMSampleBufferGetPresentationTimeStamp(sample)
        guard originalTime.isNumeric, presentationTime.isNumeric else { return nil }
        return shifted(sample, by: CMTimeSubtract(presentationTime, originalTime))
    }
}
