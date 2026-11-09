import CoreGraphics
import Foundation

/// A session's settings are fixed before asynchronous permission/device work.
/// UI preferences changed while that work is suspended affect the next take.
struct RecordingConfiguration {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let frameRate: Int
    let microphone: Bool
    let systemAudio: Bool
    let microphoneDeviceID: String?
    let excludedWindows: [CGWindowID]
    let filename: String
    /// Recorded area in global Core Graphics coordinates, for pointer data.
    var pointerRegion: CGRect?
    /// Keep the system pointer out of the pixels; the editor draws it from
    /// recorded pointer data instead.
    var hidesCursor = false
    /// Click and keystroke overlays are excluded from the pixels and
    /// rendered by the editor.
    var overlaysInTelemetry = false
    /// Webcam window excluded because the camera records to its own file.
    var cameraWindowID: CGWindowID?

    init(displayID: CGDirectDisplayID, rect: CGRect, displayBounds: CGRect,
         backingScale: CGFloat, frameRate: Int, microphone: Bool, systemAudio: Bool,
         microphoneDeviceID: String?, excludedWindows: [CGWindowID], filename: String) throws {
        let scalars = [rect.origin.x, rect.origin.y, rect.width, rect.height,
                       displayBounds.origin.x, displayBounds.origin.y, displayBounds.width,
                       displayBounds.height, backingScale]
        guard scalars.allSatisfy({ $0.isFinite }), backingScale > 0,
              rect.width > 0, rect.height > 0, displayBounds.width > 0, displayBounds.height > 0,
              displayBounds.contains(rect), (1...120).contains(frameRate) else {
            throw ConfigurationError.invalidRegionOrFrameRate
        }
        let width = rect.width * backingScale
        let height = rect.height * backingScale
        guard width.isFinite, height.isFinite, width >= 2, height >= 2,
              width < CGFloat(Int32.max), height < CGFloat(Int32.max) else {
            throw ConfigurationError.invalidRegionOrFrameRate
        }
        self.displayID = displayID
        self.sourceRect = CGRect(x: rect.minX - displayBounds.minX,
                                 y: displayBounds.maxY - rect.maxY, width: rect.width, height: rect.height)
        (pixelWidth, pixelHeight) = VideoEncodingSettings.evenDimensions(width: width, height: height)
        self.frameRate = frameRate
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.microphoneDeviceID = MicrophoneDeviceSelection.persistentDeviceID(microphoneDeviceID)
        self.excludedWindows = excludedWindows
        self.filename = filename
    }

    enum ConfigurationError: LocalizedError {
        case invalidRegionOrFrameRate
        var errorDescription: String? { "The recording area or frame rate is invalid. Select an area on the current display and try again." }
    }
}
