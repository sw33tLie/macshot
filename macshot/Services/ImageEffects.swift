import Cocoa

enum ImageEffectPreset: Int, CaseIterable {
    case none = 0
    case noir = 1
    case mono = 2
    case sepia = 3
    case chrome = 4
    case fade = 5
    case instant = 6
    case vivid = 7

    var displayName: String {
        switch self {
        case .none: return "None"
        case .noir: return "Noir"
        case .mono: return "Mono"
        case .sepia: return "Sepia"
        case .chrome: return "Chrome"
        case .fade: return "Fade"
        case .instant: return "Instant"
        case .vivid: return "Vivid"
        }
    }

    /// The CIFilter name for this preset, or nil for none/vivid (vivid uses CIColorControls).
    var ciFilterName: String? {
        switch self {
        case .none, .vivid: return nil
        case .noir: return "CIPhotoEffectNoir"
        case .mono: return "CIPhotoEffectMono"
        case .sepia: return "CISepiaTone"
        case .chrome: return "CIPhotoEffectChrome"
        case .fade: return "CIPhotoEffectFade"
        case .instant: return "CIPhotoEffectInstant"
        }
    }
}

struct ImageEffectsConfig {
    var preset: ImageEffectPreset = .none
    var brightness: Float = 0        // -0.5 to 0.5
    var contrast: Float = 1.0        // 0.5 to 2.0
    var saturation: Float = 1.0      // 0.0 to 2.0
    var sharpness: Float = 0         // 0.0 to 2.0

    var isIdentity: Bool {
        preset == .none && brightness == 0 && contrast == 1.0
            && saturation == 1.0 && sharpness == 0
    }
}

enum ImageEffects {

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Apply image effects to an NSImage. Returns the original if config is identity.
    static func apply(to image: NSImage, config: ImageEffectsConfig) -> NSImage {
        guard !config.isIdentity else { return image }

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else { return image }

        var ciImage = CIImage(cgImage: cgImage)

        // 1. Preset filter
        if config.preset == .vivid {
            // Vivid is just high saturation + contrast via CIColorControls
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(config.brightness, forKey: kCIInputBrightnessKey)
                filter.setValue(config.contrast * 1.2, forKey: kCIInputContrastKey)
                filter.setValue(config.saturation * 1.5, forKey: kCIInputSaturationKey)
                if let output = filter.outputImage {
                    ciImage = output
                }
            }
        } else {
            if let filterName = config.preset.ciFilterName,
               let filter = CIFilter(name: filterName) {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                if filterName == "CISepiaTone" {
                    filter.setValue(Float(0.8), forKey: kCIInputIntensityKey)
                }
                if let output = filter.outputImage {
                    ciImage = output
                }
            }

            // 2. Color controls (brightness, contrast, saturation)
            let hasColorAdjust = config.brightness != 0 || config.contrast != 1.0 || config.saturation != 1.0
            if hasColorAdjust {
                if let filter = CIFilter(name: "CIColorControls") {
                    filter.setValue(ciImage, forKey: kCIInputImageKey)
                    filter.setValue(config.brightness, forKey: kCIInputBrightnessKey)
                    filter.setValue(config.contrast, forKey: kCIInputContrastKey)
                    filter.setValue(config.saturation, forKey: kCIInputSaturationKey)
                    if let output = filter.outputImage {
                        ciImage = output
                    }
                }
            }
        }

        // 3. Sharpness
        if config.sharpness > 0 {
            if let filter = CIFilter(name: "CISharpenLuminance") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(config.sharpness, forKey: kCIInputSharpnessKey)
                if let output = filter.outputImage {
                    ciImage = output
                }
            }
        }

        // Render back to NSImage
        let extent = ciImage.extent
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let outputCG = ciContext.createCGImage(ciImage, from: extent, format: .RGBA8, colorSpace: colorSpace) else {
            return image
        }
        return NSImage(cgImage: outputCG, size: image.size)
    }

    /// Render a small preview swatch for a preset.
    static func presetSwatch(_ preset: ImageEffectPreset, size: CGFloat) -> NSImage {
        // Create a small gradient sample image
        let sampleSize = Int(size * 2)
        let sample = NSImage(size: NSSize(width: sampleSize, height: sampleSize), flipped: false) { rect in
            let gradient = NSGradient(colors: [
                NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.9, alpha: 1.0),
                NSColor(calibratedRed: 0.9, green: 0.6, blue: 0.3, alpha: 1.0),
                NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.5, alpha: 1.0),
            ])
            gradient?.draw(in: rect, angle: 135)
            // Add some "content" shapes for visual interest
            NSColor.white.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.width * 0.15, y: rect.height * 0.3,
                                        width: rect.width * 0.35, height: rect.height * 0.35)).fill()
            NSColor(white: 0.2, alpha: 0.6).setFill()
            NSBezierPath(rect: NSRect(x: rect.width * 0.55, y: rect.height * 0.2,
                                      width: rect.width * 0.3, height: rect.height * 0.5)).fill()
            return true
        }

        if preset == .none { return sample }

        let config = ImageEffectsConfig(
            preset: preset,
            brightness: 0, contrast: 1.0, saturation: 1.0, sharpness: 0
        )
        let result = apply(to: sample, config: config)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            result.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
    }
}
