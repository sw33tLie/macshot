import AVFoundation
import ObjectiveC

/// Source metadata is loaded once, before constructing the editor window.
/// The same asset instance then supplies playback, compositions and exports.
@MainActor
struct PreparedVideoSource {
    private static var leaseKey: UInt8 = 0
    let snapshot: VideoSourceSnapshot
    let asset: AVAsset?
    let pixelSize: CGSize?
    let duration: Double
    let fileSize: Int64
    let encodingSource: VideoExportEncodingPlan.Source?
    let audioTrackCount: Int

    struct Metadata {
        let size: CGSize
        let duration: Double
        let encodingSource: VideoExportEncodingPlan.Source
        let audioTrackCount: Int
    }

    static func load(_ snapshot: VideoSourceSnapshot) async throws -> PreparedVideoSource {
        try Task.checkCancellation()
        let fileSize = try await MediaExportIO.perform {
            let attributes = try FileManager.default.attributesOfItem(atPath: snapshot.mediaURL.path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        try Task.checkCancellation()
        if snapshot.mediaURL.pathExtension.lowercased() == "gif" {
            return PreparedVideoSource(snapshot: snapshot, asset: nil, pixelSize: nil, duration: 0,
                                       fileSize: fileSize, encodingSource: nil, audioTrackCount: 0)
        }
        let asset = AVURLAsset(url: snapshot.mediaURL)
        // AVPlayer/AVAssetImageGenerator can finish reads after the editor has
        // released its own reference. The asset keeps its backing file alive.
        objc_setAssociatedObject(asset, &leaseKey, snapshot.lease, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let metadata = try await loadMetadata(for: asset)
        return PreparedVideoSource(snapshot: snapshot, asset: asset,
                                   pixelSize: metadata.size, duration: metadata.duration,
                                   fileSize: fileSize, encodingSource: metadata.encodingSource,
                                   audioTrackCount: metadata.audioTrackCount)
    }

    /// Cancel AVFoundation's property loading as well as the Swift task. The
    /// asset retains its backing-file lease while its readers finish unwinding.
    static func loadMetadata(for asset: AVURLAsset) async throws -> Metadata {
        let cancellation = LoadingCancellation(asset: asset)
        return try await withTaskCancellationHandler(operation: {
            do {
                try Task.checkCancellation()
                let tracks = try await asset.load(.tracks)
                guard let video = tracks.first(where: { $0.mediaType == .video }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let size = try await video.load(.naturalSize)
                let transform = try await video.load(.preferredTransform)
                let range = try await video.load(.timeRange)
                let bitrate = (try? await video.load(.estimatedDataRate)) ?? 0
                let fps = (try? await video.load(.nominalFrameRate)) ?? 0
                let frameDuration = (try? await video.load(.minFrameDuration)) ?? .invalid
                let formats = (try? await video.load(.formatDescriptions)) ?? []
                let metadata = (try? await asset.load(.metadata)) ?? []
                let cadence: CMTime
                if let declared = VideoFrameCadence.declaredDuration(in: metadata) {
                    cadence = declared
                } else {
                    let inspection = VideoFrameCadence.Inspection(track: video)
                    cadence = try await MediaExportIO.perform { inspection.duration() }
                }
                try Task.checkCancellation()
                guard let geometry = VideoRenderGeometry.layout(sourceSize: size, preferredTransform: transform),
                      range.duration.isNumeric, range.duration.seconds > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return Metadata(size: geometry.uprightSize, duration: range.duration.seconds,
                    encodingSource: .init(size: geometry.uprightSize, averageBitrate: Double(bitrate),
                        codec: formats.first.map { CMFormatDescriptionGetMediaSubType($0) },
                        nominalFPS: Double(fps), minimumFrameDuration: frameDuration.seconds,
                        frameDuration: cadence),
                    audioTrackCount: tracks.filter { $0.mediaType == .audio }.count)
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }, onCancel: { cancellation.cancel() })
    }

    private struct LoadingCancellation: @unchecked Sendable {
        nonisolated(unsafe) let asset: AVAsset
        nonisolated func cancel() { asset.cancelLoading() }
    }
}
