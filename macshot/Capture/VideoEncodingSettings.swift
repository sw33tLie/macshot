import Foundation
import AVFoundation
import VideoToolbox

/// Video encoding quality tiers for both live recording and post-recording export.
///
/// Each tier targets a "bits per pixel per frame" ratio (bppf) rather than a fixed
/// bitrate. At `bitsPerPixelPerFrame = 0.15`, a 1920x1080 60fps stream gets
/// ~18.7 Mbit/s. Screen-recorded content is largely low-entropy (flat UI, fonts,
/// solid color regions) so these tiers run lighter than equivalent camera tiers.
/// The min/max bounds prevent pathological results on very small or very large
/// frames.
enum VideoQuality: String {
    case low, medium, high

    var bitsPerPixelPerFrame: Double {
        switch self {
        case .low:    return 0.07
        case .medium: return 0.13
        case .high:   return 0.21
        }
    }

    var minBitrate: Int {
        switch self {
        case .low:    return 600_000
        case .medium: return 1_500_000
        case .high:   return 3_000_000
        }
    }

    var maxBitrate: Int {
        switch self {
        case .low:    return 12_000_000
        case .medium: return 30_000_000
        case .high:   return 80_000_000
        }
    }

    var h264ProfileLevel: String {
        switch self {
        case .low:    return AVVideoProfileLevelH264MainAutoLevel
        case .medium: return AVVideoProfileLevelH264HighAutoLevel
        case .high:   return AVVideoProfileLevelH264HighAutoLevel
        }
    }

    var displayName: String {
        switch self {
        case .low:    return L("Low")
        case .medium: return L("Medium")
        case .high:   return L("High")
        }
    }
}

enum VideoCodec {
    case h264
    case hevc

    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }

    /// HEVC needs ~10–15% less bitrate for comparable visual quality.
    var bitrateMultiplier: Double {
        switch self {
        case .h264: return 1.0
        case .hevc: return 0.88
        }
    }
}

enum VideoContainer {
    case mp4
    case mov

    var fileType: AVFileType {
        switch self {
        case .mp4: return .mp4
        case .mov: return .mov
        }
    }

    var pathExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .mov: return "mov"
        }
    }
}

enum VideoEncodingSettings {

    /// Prefer HEVC on Apple Silicon where the hardware encoder is always available
    /// and the MOV container supports it everywhere. Fall back to H.264 for MP4
    /// (broader compatibility) and for Intel Macs where the HEVC encoder may or
    /// may not be hardware-accelerated depending on SKU.
    static func preferredCodec(for container: VideoContainer) -> VideoCodec {
        guard container == .mov else { return .h264 }
        #if arch(arm64)
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            return .hevc
        }
        #endif
        return .h264
    }

    /// Target bitrate in bits/sec, clamped to the tier's safe range and adjusted
    /// for codec efficiency. Dimensions beyond 4K get a mild taper to avoid
    /// runaway file sizes on high-DPI captures.
    static func bitrate(width: Int, height: Int, fps: Int, codec: VideoCodec, quality: VideoQuality) -> Int {
        guard width > 0, height > 0, fps > 0 else { return quality.minBitrate }
        let pixels = Double(width) * Double(height)
        let base = pixels * Double(fps) * quality.bitsPerPixelPerFrame
        let taper: Double
        if pixels > 3840 * 2160 {
            taper = 0.80
        } else if pixels > 1920 * 1080 {
            taper = 0.92
        } else {
            taper = 1.0
        }
        let raw = base * codec.bitrateMultiplier * taper
        let clamped = min(max(raw, Double(quality.minBitrate)), Double(quality.maxBitrate))
        return Int(clamped.rounded())
    }

    /// AVAssetWriter output settings for a video input.
    static func outputSettings(width: Int, height: Int, fps: Int, codec: VideoCodec, quality: VideoQuality) -> [String: Any] {
        let bps = bitrate(width: width, height: height, fps: fps, codec: codec, quality: quality)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bps,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: max(fps, 1),   // one keyframe per second
        ]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = quality.h264ProfileLevel
            compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        }
        return [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    /// Ensures width and height are even — H.264/HEVC both require this.
    static func evenDimensions(width: CGFloat, height: CGFloat) -> (Int, Int) {
        let w = (Int(width.rounded()) / 2) * 2
        let h = (Int(height.rounded()) / 2) * 2
        return (max(w, 2), max(h, 2))
    }
}
