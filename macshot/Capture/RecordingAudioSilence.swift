import AVFoundation

/// Small, owned PCM buffers for ScreenCaptureKit's omitted silent intervals.
/// Never allocate in proportion to a gap or the length of the recording.
enum RecordingAudioSilence {
    nonisolated static let maximumFrames = 4_800

    /// Keep a delivery-latency margin, and never replace a pending real sample
    /// or fill a healthy track just because ScreenCaptureKit omitted silence.
    nonisolated static func target(boundary: CMTime, progress: CMTime,
                                   hasQueuedAudio: Bool, siblingStalled: Bool) -> CMTime? {
        guard !hasQueuedAudio, siblingStalled, boundary.isNumeric, progress.isNumeric,
              CMTimeSubtract(progress, boundary).seconds > 0.2 else { return nil }
        return CMTimeSubtract(progress, CMTime(value: 1, timescale: 10))
    }

    nonisolated static func systemFormat() -> CMAudioFormatDescription? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                      channels: 2, interleaved: false)?.formatDescription
    }

    nonisolated static func buffer(from start: CMTime, to end: CMTime,
                                   format description: CMAudioFormatDescription) -> CMSampleBuffer? {
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard start.isNumeric, end.isNumeric, end > start,
              format.sampleRate.isFinite, (1...192_000).contains(format.sampleRate),
              format.sampleRate.rounded() == format.sampleRate,
              (1...32).contains(format.channelCount) else { return nil }
        let remaining = CMTimeConvertScale(CMTimeSubtract(end, start),
            timescale: CMTimeScale(format.sampleRate), method: .roundTowardZero).value
        let count = AVAudioFrameCount(min(Int64(maximumFrames), max(0, remaining)))
        guard count > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
        pcm.frameLength = count
        for plane in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
            guard let data = plane.mData else { return nil }
            memset(data, 0, Int(plane.mDataByteSize))
        }
        var result: CMSampleBuffer?
        guard CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault,
            dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description, sampleCount: Int(count), presentationTimeStamp: start,
            packetDescriptions: nil, sampleBufferOut: &result) == noErr, let result,
            CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
                bufferList: pcm.audioBufferList) == noErr else { return nil }
        return result
    }
}
