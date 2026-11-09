import AVFoundation
import Darwin

// Real-time production-writer endurance probe. No screen/microphone permission,
// user defaults, user captures or network access. The output directory must be new.
// Build from the repository root:
// swiftc -O -swift-version 5 -default-isolation MainActor -parse-as-library macshot/Capture/{MP4WriterSession,RecordingAudioSilence,RecordingSampleValidation,SampleBufferTiming,VideoEncodingSettings,VideoFrameCadence}.swift scripts/stress-recording.swift -o /tmp/macshot-recording-stress
// Run: /tmp/macshot-recording-stress 1200 /new/output-directory > /path/to/metrics.jsonl
// Seconds: 30...28800. 1920x1080 at 30 fps for one minute, then a minute with no
// source video frames (the production heartbeat holds the last image). Two
// 48-kHz audio streams continue throughout. Audio amplitude pulses every 10 s;
// active video frames carry a binary frame counter and the same pulse marker.
// A halfway snapshot and the final MP4 remain for independent decoding.
func L(_ key: String) -> String { key }

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    func set(_ error: Error) { lock.lock(); defer { lock.unlock() }; if failure == nil { failure = error } }
    func check() throws { lock.lock(); defer { lock.unlock() }; if let failure { throw failure } }
}

private final class SyntheticMedia {
    let width = 1920, height = 1080, fps = 30, sampleRate: Int32 = 48_000
    private let pool: CVPixelBufferPool
    private let stride: Int
    private let background: Data
    private let mono: CMAudioFormatDescription
    private let stereo: CMAudioFormatDescription

    init() throws {
        var optionalPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
            [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
             kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
             kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &optionalPool) == kCVReturnSuccess,
              let pool = optionalPool else { throw CocoaError(.coderValueNotFound) }
        self.pool = pool
        var initial: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &initial) == kCVReturnSuccess,
              let initial else { throw CocoaError(.coderValueNotFound) }
        stride = CVPixelBufferGetBytesPerRow(initial)
        var pixels = Data(count: stride * height)
        let rowBytes = stride
        let rowWidth = width, rowCount = height
        pixels.withUnsafeMutableBytes { bytes in
            let base = bytes.baseAddress!.assumingMemoryBound(to: UInt32.self)
            for y in 0..<rowCount {
                for x in 0..<rowWidth {
                    let light = (x / 32 + y / 24).isMultiple(of: 2)
                    base[y * rowBytes / 4 + x] = light ? 0xFF303030 : 0xFF202020
                }
            }
        }
        background = pixels
        mono = try Self.audioFormat(channels: 1)
        stereo = try Self.audioFormat(channels: 2)
    }

    func frame(_ tick: Int) throws -> CVPixelBuffer {
        var optional: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 16] as CFDictionary, &optional) == kCVReturnSuccess,
              let buffer = optional else { throw CocoaError(.fileWriteOutOfSpace) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer) == stride else {
            throw CocoaError(.coderValueNotFound)
        }
        background.withUnsafeBytes { _ = memcpy(base, $0.baseAddress!, background.count) }
        let pixels = base.assumingMemoryBound(to: UInt32.self)
        let left = tick * 7 % (width - 64)
        let top = 200 + tick / 5 % (height - 264)
        for y in top..<(top + 64) {
            for x in left..<(left + 64) { pixels[y * stride / 4 + x] = 0xFF00CCFF }
        }
        // Large cells remain readable after H.264 compression; white means 1.
        for bit in 0..<24 {
            let color: UInt32 = tick & (1 << bit) == 0 ? 0xFF000000 : 0xFFFFFFFF
            for y in 16..<48 {
                for x in (16 + bit * 40)..<(48 + bit * 40) { pixels[y * stride / 4 + x] = color }
            }
        }
        let pulse: UInt32 = tick % (10 * fps) < 3 ? 0xFFFFFFFF : 0xFF000000
        for y in 64..<128 { for x in 16..<80 { pixels[y * stride / 4 + x] = pulse } }
        return buffer
    }

    private static func audioFormat(channels: Int) throws -> CMAudioFormatDescription {
        let frameBytes = UInt32(channels * MemoryLayout<Float>.size)
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: frameBytes, mFramesPerPacket: 1, mBytesPerFrame: frameBytes,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var result: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &result) == noErr, let result else {
            throw CocoaError(.coderValueNotFound)
        }
        return result
    }

    func audio(_ tick: Int, at time: CMTime, microphone: Bool) throws -> CMSampleBuffer {
        let channels = microphone ? 1 : 2
        let samples = Int(sampleRate) / fps
        let frameBytes = channels * MemoryLayout<Float>.size
        var data: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: samples * frameBytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: samples * frameBytes, flags: 0, blockBufferOut: &data) == noErr,
              let data else { throw CocoaError(.coderValueNotFound) }
        let amplitude = tick % (10 * fps) < 3 ? 0.4 : 0.04
        var pcm = [Float](repeating: 0, count: samples * channels)
        for sample in 0..<samples {
            let t = Double(tick * samples + sample) / Double(sampleRate)
            pcm[sample * channels] = Float(sin(2 * .pi * (microphone ? 440 : 880) * t) * amplitude)
            if !microphone { pcm[sample * channels + 1] = Float(sin(2 * .pi * 1320 * t) * amplitude) }
        }
        let copied = pcm.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data,
                                          offsetIntoDestination: 0, dataLength: $0.count)
        }
        guard copied == noErr else { throw CocoaError(.coderValueNotFound) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: sampleRate),
                                       presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = frameBytes
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
            formatDescription: microphone ? mono : stereo, sampleCount: samples,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result) == noErr,
              let result else { throw CocoaError(.coderValueNotFound) }
        return result
    }
}

@main
struct RecordingStress {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    static func emit(_ record: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    static func sleep(until deadline: TimeInterval) async throws {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 3, let seconds = Int(CommandLine.arguments[1]),
              (30...28_800).contains(seconds) else {
            throw NSError(domain: "macshot.stress", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Usage: macshot-recording-stress SECONDS(30...28800) /new/output-directory"])
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Synthetic recording endurance probe")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let source = try SyntheticMedia()
        let queue = DispatchQueue(label: "macshot.stress.writer")
        let failure = FailureBox()
        let url = directory.appendingPathComponent("recording.mp4")
        let writer = try MP4WriterSession.make(queue: queue, url: url, width: source.width, height: source.height,
            fps: source.fps, recordSystemAudio: true, recordMicAudio: true, onFailure: failure.set)
        writer.captureDidStart()
        let start = ProcessInfo.processInfo.systemUptime
        let epoch = CMClockGetTime(CMClockGetHostTimeClock())
        var acceptedSourceFrames = 0
        var maximumDelay = 0.0
        try emit(["event": "start", "pid": getpid(), "seconds": seconds,
                  "width": source.width, "height": source.height, "fps": source.fps,
                  "residentBytes": residentBytes(), "directory": directory.path])
        do {
            for tick in 0..<(seconds * source.fps) {
                let deadline = start + Double(tick) / Double(source.fps)
                try await sleep(until: deadline)
                try failure.check()
                maximumDelay = max(maximumDelay, ProcessInfo.processInfo.systemUptime - deadline)
                let pts = CMTimeAdd(epoch, CMTime(value: Int64(tick), timescale: Int32(source.fps)))
                try autoreleasepool {
                    let frame = (tick / (60 * source.fps)).isMultiple(of: 2) ? try source.frame(tick) : nil
                    let mic = try source.audio(tick, at: pts, microphone: true)
                    let system = try source.audio(tick, at: pts, microphone: false)
                    queue.sync {
                        if let frame, writer.handleFrame(pixelBuffer: frame, presentationTime: pts) { acceptedSourceFrames += 1 }
                        writer.handleMicSample(mic)
                        writer.handleSystemAudioSample(system)
                    }
                }
                if tick > 0, tick.isMultiple(of: source.fps * 10) {
                    let stats = queue.sync { (writer.frameCount, writer.droppedVideoFrames) }
                    let bytes = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                    try emit(["event": "sample", "elapsed": ProcessInfo.processInfo.systemUptime - start,
                        "frames": stats.0, "droppedFrames": stats.1, "sourceFrames": acceptedSourceFrames,
                        "residentBytes": residentBytes(), "fileBytes": bytes, "maximumDelay": maximumDelay])
                }
                if tick == seconds * source.fps / 2 {
                    let snapshot = directory.appendingPathComponent("while-recording.mp4")
                    try queue.sync { try FileManager.default.copyItem(at: url, to: snapshot) }
                    try emit(["event": "snapshot", "elapsed": ProcessInfo.processInfo.systemUptime - start])
                }
            }
            try await sleep(until: start + Double(seconds))
            writer.requestStop(atSourceTime: CMTimeAdd(epoch, CMTime(value: Int64(seconds), timescale: 1)))
            let finishStart = ProcessInfo.processInfo.systemUptime
            try await writer.finish()
            let stats = queue.sync { (writer.frameCount, writer.droppedVideoFrames) }
            try emit(["event": "complete", "elapsed": ProcessInfo.processInfo.systemUptime - start,
                "finalizeSeconds": ProcessInfo.processInfo.systemUptime - finishStart,
                "frames": stats.0, "droppedFrames": stats.1, "sourceFrames": acceptedSourceFrames,
                "residentBytes": residentBytes(), "maximumDelay": maximumDelay,
                "fileBytes": (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0])
        } catch {
            writer.requestStop()
            try? await writer.finish()
            try? emit(["event": "failure", "error": error.localizedDescription,
                       "elapsed": ProcessInfo.processInfo.systemUptime - start])
            throw error
        }
    }
}
