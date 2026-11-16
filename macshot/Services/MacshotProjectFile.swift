import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A standalone, editable macshot document (`.macshot`): the unannotated
/// image, every annotation as an editable object, the post-processing state
/// (beautify, effects, measure scale) and a flattened copy. It is
/// independent of capture history, so it can be archived, shared and reopened.
///
/// On disk it is a binary property list (`MacshotProjectArchive`). Images are
/// PNG, annotations use the same JSON as editable history, and every field
/// decodes leniently so newer and older builds can read each other's files.
enum MacshotProjectFile {
    nonisolated static let fileExtension = "macshot"
    nonisolated static let typeIdentifier = "com.sw33tlie.macshot.project"
    nonisolated static let formatIdentifier = "com.sw33tlie.macshot.project"
    /// Bumped only for changes an older build would misread. Files with a
    /// newer version still open when their required fields are readable.
    nonisolated static let currentVersion = 1
    /// Raw + flattened images and serialized annotations, with headroom.
    nonisolated static let maximumFileBytes = 1024 * 1024 * 1024

    static var contentType: UTType {
        UTType(typeIdentifier) ?? UTType(exportedAs: typeIdentifier, conformingTo: .data)
    }

    static func isProjectURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// Everything a save needs, owned by value and captured before any panel
    /// is shown, so the file matches the editor at the moment of the request.
    struct Snapshot: Sendable {
        let raw: HistoryImageSnapshot.Image
        let flattened: HistoryImageSnapshot.Image?
        let annotationsJSON: Data?
        let editStateJSON: Data?
        let appVersion: String

        @MainActor init(rawImage: NSImage, flattenedImage: NSImage?, annotations: [Annotation],
                        editState: CaptureEditState?) throws {
            raw = try HistoryImageSnapshot.Image(rawImage)
            flattened = try flattenedImage.map { try HistoryImageSnapshot.Image($0) }
            if annotations.isEmpty {
                annotationsJSON = nil
            } else {
                guard let data = AnnotationSerializer.encode(annotations) else { throw ProjectError.cannotEncode }
                annotationsJSON = data
            }
            editStateJSON = try editState.map { try JSONEncoder().encode($0) }
            appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        }

        /// Encode the archive. Runs off the main thread.
        nonisolated func encoded(savedAt: Date = Date()) throws -> Data {
            // Never write a project this build couldn't open again.
            guard MacshotProjectFile.isOpenable(raw.pixels) else { throw ProjectError.imageTooLarge }
            guard let rawPNG = raw.pngData() else { throw ProjectError.cannotEncode }
            guard rawPNG.count <= SavedCaptureValidation.maximumImageBytes else { throw ProjectError.imageTooLarge }
            // The flattened copy is only a fallback; leave it out rather than
            // make the file unopenable.
            let flattenedPNG = flattened.flatMap { image -> Data? in
                guard MacshotProjectFile.isOpenable(image.pixels), let data = image.pngData(),
                      data.count <= SavedCaptureValidation.maximumImageBytes else { return nil }
                return data
            }
            let archive = MacshotProjectArchive(
                format: MacshotProjectFile.formatIdentifier,
                version: MacshotProjectFile.currentVersion,
                appVersion: appVersion,
                savedAt: savedAt,
                imagePNG: rawPNG,
                imagePointWidth: Double(raw.pointSize.width),
                imagePointHeight: Double(raw.pointSize.height),
                flattenedPNG: flattenedPNG,
                annotationsJSON: annotationsJSON,
                editStateJSON: editStateJSON)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return try encoder.encode(archive)
        }
    }

    /// The decoded, not yet materialized contents. Produced off the main thread.
    struct DecodedArchive: Sendable {
        let image: CGImage
        let imagePointSize: CGSize
        let flattened: CGImage?
        let flattenedPointSize: CGSize?
        let annotationsJSON: Data?
        let editStateJSON: Data?
    }

    /// An opened project, ready for the editor.
    enum Contents {
        /// Everything restored: edit it as it was saved.
        case editable(rawImage: NSImage, annotations: [Annotation], editState: CaptureEditState?)
        /// Annotations could not all be restored (corrupt, or from a newer
        /// build). The flattened copy keeps every annotation visible, baked in.
        case flattened(NSImage)
    }

    enum ProjectError: LocalizedError {
        case notAProject
        case tooLarge
        case invalidImage
        case cannotEncode
        case imageTooLarge

        var errorDescription: String? {
            switch self {
            case .notAProject: return L("The file is not a macshot project or is damaged.")
            case .tooLarge: return L("The project file is too large to open.")
            case .invalidImage: return L("The project's image could not be read.")
            case .cannotEncode: return L("The project could not be prepared for saving.")
            case .imageTooLarge: return L("The image is too large to save as an editable project.")
            }
        }
    }

    // MARK: - Reading

    /// Read and validate the archive and decode its images. Runs off the main thread.
    nonisolated static func decode(contentsOf url: URL) throws -> DecodedArchive {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false else { throw ProjectError.notAProject }
        if let size = values.fileSize, size > maximumFileBytes { throw ProjectError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumFileBytes else { throw ProjectError.tooLarge }
        return try decode(data)
    }

    nonisolated static func decode(_ data: Data) throws -> DecodedArchive {
        guard let archive = try? PropertyListDecoder().decode(MacshotProjectArchive.self, from: data),
              archive.format == formatIdentifier, let imagePNG = archive.imagePNG else {
            throw ProjectError.notAProject
        }
        guard let image = decodePNG(imagePNG) else { throw ProjectError.invalidImage }
        let pointSize = validPointSize(width: archive.imagePointWidth, height: archive.imagePointHeight,
                                       pixels: image) ?? CGSize(width: image.width, height: image.height)
        let flattened = archive.flattenedPNG.flatMap { decodePNG($0) }
        // The flattened copy may be larger than the raw image (beautify
        // padding); keep the raw image's pixel density.
        let flattenedSize = flattened.map { flat in
            let scale = Double(image.width) / Double(pointSize.width)
            return CGSize(width: Double(flat.width) / scale, height: Double(flat.height) / scale)
        }
        return DecodedArchive(image: image, imagePointSize: pointSize, flattened: flattened,
                              flattenedPointSize: flattenedSize,
                              annotationsJSON: archive.annotationsJSON, editStateJSON: archive.editStateJSON)
    }

    /// Materialize annotations and edit state. Main thread (Annotation is UI state).
    /// Throws rather than show the raw image when an annotation (perhaps a
    /// censor) can't be restored and there is no flattened copy to fall back to.
    @MainActor static func contents(of decoded: DecodedArchive) throws -> Contents {
        let rawImage = NSImage(cgImage: decoded.image, size: decoded.imagePointSize)
        let flattenedImage = decoded.flattened.map {
            NSImage(cgImage: $0, size: decoded.flattenedPointSize ?? CGSize(width: $0.width, height: $0.height))
        }

        var annotations: [Annotation] = []
        if let json = decoded.annotationsJSON {
            // All or nothing: never reopen raw pixels with a censor left out.
            guard let restored = AnnotationSerializer.decode(json, requireAll: true) else {
                guard let flattenedImage else { throw ProjectError.notAProject }
                return .flattened(flattenedImage)
            }
            annotations = restored
        }
        var editState: CaptureEditState?
        if let json = decoded.editStateJSON {
            guard let restored = try? JSONDecoder().decode(CaptureEditState.self, from: json),
                  restored.customBeautifyBackgroundPNG == nil || restored.customBeautifyBackground != nil else {
                guard let flattenedImage else { throw ProjectError.notAProject }
                return .flattened(flattenedImage)
            }
            editState = restored
        }
        return .editable(rawImage: rawImage, annotations: annotations, editState: editState)
    }

    nonisolated static func isOpenable(_ image: CGImage) -> Bool {
        Double(image.width) * Double(image.height) <= Double(SavedCaptureValidation.maximumImagePixels)
    }

    nonisolated private static func decodePNG(_ data: Data) -> CGImage? {
        guard data.count <= SavedCaptureValidation.maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0, width * height <= Double(SavedCaptureValidation.maximumImagePixels),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return image
    }

    /// The stored point size, if it describes the pixels at a sane density.
    nonisolated private static func validPointSize(width: Double?, height: Double?, pixels: CGImage) -> CGSize? {
        guard let width, let height, width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let scaleX = Double(pixels.width) / width
        let scaleY = Double(pixels.height) / height
        guard (0.25...8).contains(scaleX), (0.25...8).contains(scaleY), abs(scaleX - scaleY) < 0.05 * scaleX else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    // MARK: - Writing

    /// Write atomically: a failed save leaves any previous file untouched.
    /// Registered with the export coordinator so Quit waits for it.
    @MainActor static func write(_ snapshot: Snapshot, to url: URL, completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        let accessing = url.startAccessingSecurityScopedResource()
        MediaExportCoordinator.shared.start(title: url.lastPathComponent, status: L("Saving..."), operation: { cancellation, _ in
            _ = try await MediaExportIO.perform {
                try autoreleasepool {
                    try cancellation.check()
                    let data = try snapshot.encoded()
                    let transaction = try AtomicMediaSave(destinationURL: url)
                    try data.write(to: transaction.stagingURL)
                    try transaction.commit(beforePublish: cancellation.beginPublication)
                    return true
                }
            }
        }, completion: { result in
            if accessing { url.stopAccessingSecurityScopedResource() }
            switch result {
            case .success: completion(.success(url))
            case .failure(let error): completion(.failure(error))
            }
        })
    }
}

/// The on-disk layout of a `.macshot` file. Field names are the file format:
/// add new optional fields freely, never rename or repurpose existing ones.
nonisolated struct MacshotProjectArchive: Codable, Sendable {
    var format: String
    var version: Int
    var appVersion: String
    var savedAt: Date?
    var imagePNG: Data?
    var imagePointWidth: Double?
    var imagePointHeight: Double?
    var flattenedPNG: Data?
    var annotationsJSON: Data?
    var editStateJSON: Data?

    init(format: String, version: Int, appVersion: String, savedAt: Date?, imagePNG: Data?,
         imagePointWidth: Double?, imagePointHeight: Double?, flattenedPNG: Data?,
         annotationsJSON: Data?, editStateJSON: Data?) {
        self.format = format
        self.version = version
        self.appVersion = appVersion
        self.savedAt = savedAt
        self.imagePNG = imagePNG
        self.imagePointWidth = imagePointWidth
        self.imagePointHeight = imagePointHeight
        self.flattenedPNG = flattenedPNG
        self.annotationsJSON = annotationsJSON
        self.editStateJSON = editStateJSON
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.decode(.format, or: "")
        version = c.decode(.version, or: 0)
        appVersion = c.decode(.appVersion, or: "")
        savedAt = c.decodeOptional(.savedAt)
        imagePNG = c.decodeOptional(.imagePNG)
        imagePointWidth = c.decodeOptional(.imagePointWidth)
        imagePointHeight = c.decodeOptional(.imagePointHeight)
        flattenedPNG = c.decodeOptional(.flattenedPNG)
        annotationsJSON = c.decodeOptional(.annotationsJSON)
        editStateJSON = c.decodeOptional(.editStateJSON)
    }
}

extension HistoryImageSnapshot.Image {
    /// PNG bytes with the image's pixel density, like history's raw sidecar.
    nonisolated func pngData() -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.png" as CFString, 1, nil)
        else { return nil }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: Double(pixels.width) / pointSize.width * 72,
            kCGImagePropertyDPIHeight: Double(pixels.height) / pointSize.height * 72,
        ]
        CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
