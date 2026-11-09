import Cocoa

/// Saved non-destructive post-processing state for editable history entries.
struct CaptureEditState: Codable, Equatable {
    var effectsPresetRaw: Int = ImageEffectPreset.none.rawValue
    var effectsBrightness: Float = 0
    var effectsContrast: Float = 1
    var effectsSaturation: Float = 1
    var effectsSharpness: Float = 0

    var beautifyEnabled: Bool = false
    var beautifyModeRaw: Int = BeautifyMode.window.rawValue
    var beautifyStyleIndex: Int = 0
    var beautifyPadding: Double = 48
    var beautifyCornerRadius: Double = 10
    var beautifyShadowRadius: Double = 20
    var beautifyBackgroundBlur: Double = 0
    var beautifyIsWindowSnap: Bool = false
    var customBeautifyBackgroundPNG: Data?

    var effectsPreset: ImageEffectPreset {
        ImageEffectPreset(rawValue: effectsPresetRaw) ?? .none
    }

    var effectsConfig: ImageEffectsConfig {
        ImageEffectsConfig(
            preset: effectsPreset,
            brightness: SavedCaptureValidation.bounded(effectsBrightness, -0.5...0.5, fallback: 0),
            contrast: SavedCaptureValidation.bounded(effectsContrast, 0.5...2, fallback: 1),
            saturation: SavedCaptureValidation.bounded(effectsSaturation, 0...2, fallback: 1),
            sharpness: SavedCaptureValidation.bounded(effectsSharpness, 0...2, fallback: 0)
        )
    }

    var hasEffects: Bool { !effectsConfig.isIdentity }
    var hasPostProcessing: Bool { hasEffects || beautifyEnabled }

    var beautifyMode: BeautifyMode {
        BeautifyMode(rawValue: beautifyModeRaw) ?? .window
    }

    var customBeautifyBackground: NSImage? {
        customBeautifyBackgroundPNG.flatMap { SavedCaptureValidation.image($0) }
    }

    func beautifyConfig() -> BeautifyConfig {
        var config = BeautifyConfig(
            mode: beautifyMode,
            styleIndex: beautifyStyleIndex,
            padding: CGFloat(SavedCaptureValidation.bounded(beautifyPadding, 0...1024, fallback: 48)),
            cornerRadius: CGFloat(SavedCaptureValidation.bounded(beautifyCornerRadius, 0...1024, fallback: 10)),
            shadowRadius: CGFloat(SavedCaptureValidation.bounded(beautifyShadowRadius, 0...100, fallback: 20)),
            bgRadius: 0,
            isWindowSnap: beautifyIsWindowSnap,
            customBackgroundImage: customBeautifyBackground,
            backgroundBlur: CGFloat(SavedCaptureValidation.bounded(beautifyBackgroundBlur, 0...50, fallback: 0))
        )
        if config.customBackgroundImage != nil {
            config.prepareBackgroundCache()
        }
        return config
    }
}

extension CaptureEditState {

    /// Decoded field by field so edit state saved before a field existed still
    /// loads. The synthesized decoder throws `keyNotFound` for a missing key
    /// even though every field here has a default, which would silently discard
    /// the whole post-processing state of that capture. See `LenientDecoding.swift`.
    /// Declared in an extension so the memberwise initializer survives.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        effectsPresetRaw = c.decode(.effectsPresetRaw, or: ImageEffectPreset.none.rawValue)
        effectsBrightness = c.decode(.effectsBrightness, or: 0)
        effectsContrast = c.decode(.effectsContrast, or: 1)
        effectsSaturation = c.decode(.effectsSaturation, or: 1)
        effectsSharpness = c.decode(.effectsSharpness, or: 0)
        beautifyEnabled = c.decode(.beautifyEnabled, or: false)
        beautifyModeRaw = c.decode(.beautifyModeRaw, or: BeautifyMode.window.rawValue)
        beautifyStyleIndex = c.decode(.beautifyStyleIndex, or: 0)
        beautifyPadding = c.decode(.beautifyPadding, or: 48)
        beautifyCornerRadius = c.decode(.beautifyCornerRadius, or: 10)
        beautifyShadowRadius = c.decode(.beautifyShadowRadius, or: 20)
        beautifyBackgroundBlur = c.decode(.beautifyBackgroundBlur, or: 0)
        beautifyIsWindowSnap = c.decode(.beautifyIsWindowSnap, or: false)
        customBeautifyBackgroundPNG = c.decodeOptional(.customBeautifyBackgroundPNG)
        normalizeValues()
    }

    mutating func normalizeValues() {
        let effects = effectsConfig
        effectsBrightness = effects.brightness
        effectsContrast = effects.contrast
        effectsSaturation = effects.saturation
        effectsSharpness = effects.sharpness
        // Preserve legacy padding/radius values beyond today's sliders while
        // preventing invalid or unbounded canvas expansion.
        beautifyPadding = SavedCaptureValidation.bounded(beautifyPadding, 0...1024, fallback: 48)
        beautifyCornerRadius = SavedCaptureValidation.bounded(beautifyCornerRadius, 0...1024, fallback: 10)
        beautifyShadowRadius = SavedCaptureValidation.bounded(beautifyShadowRadius, 0...100, fallback: 20)
        beautifyBackgroundBlur = SavedCaptureValidation.bounded(beautifyBackgroundBlur, 0...50, fallback: 0)
    }
}

extension OverlayView {
    func captureEditState() -> CaptureEditState {
        let customBackgroundData: Data? = {
            guard beautifyStyleIndex == -1, let image = customBeautifyBackground else { return nil }
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: .png, properties: [:])
        }()

        return CaptureEditState(
            effectsPresetRaw: effectsPreset.rawValue,
            effectsBrightness: effectsBrightness,
            effectsContrast: effectsContrast,
            effectsSaturation: effectsSaturation,
            effectsSharpness: effectsSharpness,
            beautifyEnabled: beautifyEnabled,
            beautifyModeRaw: beautifyMode.rawValue,
            beautifyStyleIndex: beautifyStyleIndex,
            beautifyPadding: Double(beautifyPadding),
            beautifyCornerRadius: Double(beautifyCornerRadius),
            beautifyShadowRadius: Double(beautifyShadowRadius),
            beautifyBackgroundBlur: Double(beautifyBackgroundBlur),
            beautifyIsWindowSnap: selectionIsWindowSnap,
            customBeautifyBackgroundPNG: customBackgroundData
        )
    }

    func applyCaptureEditState(_ state: CaptureEditState) {
        var state = state
        state.normalizeValues()
        effectsPreset = state.effectsPreset
        effectsBrightness = state.effectsBrightness
        effectsContrast = state.effectsContrast
        effectsSaturation = state.effectsSaturation
        effectsSharpness = state.effectsSharpness
        cachedEffectsScreenshot = nil

        beautifyEnabled = state.beautifyEnabled
        beautifyMode = state.beautifyMode
        beautifyStyleIndex = state.beautifyStyleIndex
        beautifyPadding = CGFloat(state.beautifyPadding)
        beautifyCornerRadius = CGFloat(state.beautifyCornerRadius)
        beautifyShadowRadius = CGFloat(state.beautifyShadowRadius)
        beautifyBackgroundBlur = CGFloat(state.beautifyBackgroundBlur)
        selectionIsWindowSnap = state.beautifyIsWindowSnap
        customBeautifyBackground = state.customBeautifyBackground
        if customBeautifyBackground != nil {
            prepareBeautifyBackgroundCache()
        } else {
            // The custom style can be selected without a stored background in the
            // edit state — load it eagerly here (not lazily in beautifyConfig's
            // getter) so the editor's clean-state signature is stable.
            ensureCustomBeautifyBackgroundLoaded()
        }

        cachedCompositedImage = nil
        rebuildToolbarLayout()
        needsDisplay = true
    }

    func editableStateSignature() -> String {
        let movableAnnotations = self.annotations.filter { $0.isMovable }
        let annotationPart = AnnotationSerializer.encode(movableAnnotations)?.base64EncodedString() ?? ""
        let editData = try? JSONEncoder().encode(captureEditState())
        let editPart = editData?.base64EncodedString() ?? ""
        let imagePart = screenshotImage.map { "\(SafeNumerics.int($0.size.width))x\(SafeNumerics.int($0.size.height))" } ?? "nil"
        return "\(imagePart)|\(editPart)|\(annotationPart)"
    }
}
