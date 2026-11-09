import AVFoundation

/// Offline compression has a source bitrate to consult; live capture does not.
/// These are encoder targets, not guarantees about file size or visual quality.
struct VideoExportEncodingPlan: Sendable {
    struct Source: Sendable {
        let size: CGSize
        let averageBitrate: Double
        let codec: CMVideoCodecType?
        let nominalFPS: Double
        let minimumFrameDuration: Double
        var frameDuration: CMTime = .invalid
    }

    let width: Int
    let height: Int
    let fps: Int
    let videoBitrate: Int
    let quality: VideoQuality
    let supportsSizeEstimate: Bool

    static func make(source: Source, scale: Double, quality: VideoQuality,
                     sourceDuration: Double, outputDuration: Double) -> VideoExportEncodingPlan? {
        guard source.size.width.isFinite, source.size.height.isFinite,
              source.size.width >= 2, source.size.height >= 2,
              source.size.width <= 32_768, source.size.height <= 32_768,
              scale.isFinite, scale > 0, scale <= 1,
              sourceDuration.isFinite, sourceDuration > 0,
              outputDuration.isFinite, outputDuration > 0 else { return nil }
        let (width, height) = VideoEncodingSettings.evenDimensions(
            width: source.size.width * scale, height: source.size.height * scale)
        let minimum = source.minimumFrameDuration.isFinite && (0.001...1).contains(source.minimumFrameDuration)
            ? CMTime(seconds: source.minimumFrameDuration, preferredTimescale: 1_000_000_000) : .invalid
        let cadence = VideoFrameCadence.isUsable(source.frameDuration) ? source.frameDuration
            : VideoFrameCadence.duration(minimum: minimum, nominalRate: Float(source.nominalFPS))
        let fps = SafeNumerics.frameRate(Float(1 / cadence.seconds))
        let floor: Double
        let sourceRatio: Double
        switch quality {
        case .low: floor = 64_000; sourceRatio = 0.5
        case .medium: floor = 128_000; sourceRatio = 0.8
        case .high: floor = 256_000; sourceRatio = 1
        }
        // No multi-megabit live-capture minimum for an already compressed clip.
        var target = Double(width) * Double(height) * Double(fps) * quality.bitsPerPixelPerFrame
        // An average across long idle gaps is not a useful active-frame budget.
        // Only cap against comparable H.264 sources with a near-uniform cadence.
        // HEVC/other codecs use the pixel budget rather than an assumed codec ratio.
        let cadenceCoverage = source.nominalFPS * source.minimumFrameDuration
        let comparableSource = source.codec == kCMVideoCodecType_H264
            && source.averageBitrate.isFinite && source.averageBitrate > 0
            && cadenceCoverage.isFinite && (0.9...1.1).contains(cadenceCoverage)
        if comparableSource {
            let areaRatio = Double(width) * Double(height) / (source.size.width * source.size.height)
            let speedAllowance = min(10, max(1, sourceDuration / outputDuration))
            target = min(target, source.averageBitrate * sourceRatio * pow(areaRatio, 0.75) * speedAllowance)
        }
        let bitrate = Int(min(Double(quality.maxBitrate), max(floor, target)).rounded())
        return VideoExportEncodingPlan(width: width, height: height, fps: fps,
                                       videoBitrate: bitrate, quality: quality,
                                       supportsSizeEstimate: comparableSource && quality != .high)
    }

    var outputSettings: [String: Any] {
        var settings = VideoEncodingSettings.outputSettings(
            width: width, height: height, fps: fps, codec: .h264, quality: quality)
        var compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        compression[AVVideoAverageBitRateKey] = videoBitrate
        settings[AVVideoCompressionPropertiesKey] = compression
        return settings
    }

    /// A source-informed approximation including every encoded audio track.
    /// Sparse/unknown/different-codec sources use a pixel-based encoder budget,
    /// which can exceed actual output by orders of magnitude. Do not present
    /// that fallback budget as a file-size prediction.
    func estimatedBytes(duration: Double, audioTrackCount: Int, audioBitrate: Int) -> Int64? {
        guard supportsSizeEstimate, duration.isFinite, duration > 0,
              audioTrackCount >= 0, audioBitrate >= 0 else { return nil }
        let rate = Double(videoBitrate) + Double(audioTrackCount) * Double(audioBitrate)
        let bytes = rate * duration / 8 * 1.03 + 16_384
        guard bytes.isFinite, bytes > 0, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes.rounded(.up))
    }
}
