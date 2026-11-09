import Foundation
import CoreGraphics

/// Shared by editor previews and immutable render instructions.
enum VideoEffectTiming {
    nonisolated static func effectiveFade(_ fade: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, fade.isFinite else { return 0 }
        return min(max(fade, 0), max(0, duration / 2 - 0.001))
    }

    nonisolated static func opacity(at time: Double, start: Double, end: Double,
                                    fadeIn: Double, fadeOut: Double) -> CGFloat {
        guard time.isFinite, start.isFinite, end.isFinite,
              time >= start, time <= end, end > start else { return 0 }
        let incoming = effectiveFade(fadeIn, duration: end - start)
        let outgoing = effectiveFade(fadeOut, duration: end - start)
        let progress: Double
        if incoming > 0, time - start < incoming {
            progress = (time - start) / incoming
        } else if outgoing > 0, end - time < outgoing {
            progress = (end - time) / outgoing
        } else {
            return 1
        }
        let x = CGFloat(max(0, min(1, progress)))
        return x * x * (3 - 2 * x)
    }
}

/// Copies every field before a request leaves the main actor. No renderer
/// retains a mutable editor segment, even while the user drags its handles.
struct VideoZoomSnapshot: Sendable {
    let id: UUID
    let startTime: Double
    let endTime: Double
    let zoomLevel: CGFloat
    let center: CGPoint
    let fadeIn: Double
    let fadeOut: Double

    @MainActor init(_ segment: VideoZoomSegment) {
        id = segment.id
        startTime = segment.startTime
        endTime = segment.endTime
        zoomLevel = segment.zoomLevel
        center = segment.center
        fadeIn = segment.fadeIn
        fadeOut = segment.fadeOut
    }

    nonisolated func zoomLevel(at time: Double) -> CGFloat {
        let amount = VideoEffectTiming.opacity(at: time, start: startTime, end: endTime,
                                               fadeIn: fadeIn, fadeOut: fadeOut)
        return 1 + (zoomLevel - 1) * amount
    }

    nonisolated func translation(zoom: CGFloat, videoSize: CGSize) -> CGPoint {
        guard zoom > 1.0001 else { return .zero }
        let rawX = videoSize.width * (0.5 - center.x)
        let rawY = videoSize.height * (0.5 - center.y)
        let maxX = (zoom - 1) * videoSize.width / (2 * zoom)
        let maxY = (zoom - 1) * videoSize.height / (2 * zoom)
        return CGPoint(x: min(max(rawX, -maxX), maxX), y: min(max(rawY, -maxY), maxY))
    }
}

struct VideoCensorSnapshot: Sendable {
    let id: UUID
    let startTime: Double
    let endTime: Double
    let rect: CGRect
    let style: VideoCensorSegment.Style
    let fadeIn: Double
    let fadeOut: Double

    @MainActor init(_ segment: VideoCensorSegment) {
        id = segment.id
        startTime = segment.startTime
        endTime = segment.endTime
        rect = segment.rect
        style = segment.style
        fadeIn = segment.fadeIn
        fadeOut = segment.fadeOut
    }

    nonisolated func opacity(at time: Double) -> CGFloat {
        VideoEffectTiming.opacity(at: time, start: startTime, end: endTime,
                                  fadeIn: fadeIn, fadeOut: fadeOut)
    }
}
