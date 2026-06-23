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
            brightness: effectsBrightness,
            contrast: effectsContrast,
            saturation: effectsSaturation,
            sharpness: effectsSharpness
        )
    }

    var hasEffects: Bool { !effectsConfig.isIdentity }
    var hasPostProcessing: Bool { hasEffects || beautifyEnabled }

    var beautifyMode: BeautifyMode {
        BeautifyMode(rawValue: beautifyModeRaw) ?? .window
    }

    var customBeautifyBackground: NSImage? {
        customBeautifyBackgroundPNG.flatMap { NSImage(data: $0) }
    }

    func beautifyConfig() -> BeautifyConfig {
        var config = BeautifyConfig(
            mode: beautifyMode,
            styleIndex: beautifyStyleIndex,
            padding: CGFloat(beautifyPadding),
            cornerRadius: CGFloat(beautifyCornerRadius),
            shadowRadius: CGFloat(beautifyShadowRadius),
            bgRadius: 0,
            isWindowSnap: beautifyIsWindowSnap,
            customBackgroundImage: customBeautifyBackground,
            backgroundBlur: CGFloat(beautifyBackgroundBlur)
        )
        if config.customBackgroundImage != nil {
            config.prepareBackgroundCache()
        }
        return config
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
        let imagePart = screenshotImage.map { "\(Int($0.size.width.rounded()))x\(Int($0.size.height.rounded()))" } ?? "nil"
        return "\(imagePart)|\(editPart)|\(annotationPart)"
    }
}
