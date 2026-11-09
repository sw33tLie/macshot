import CoreGraphics

/// Shared geometry for the video image and overlays attached to its content.
enum VideoRenderGeometry {
    struct Layout: Sendable {
        let uprightSize: CGSize
        let renderSize: CGSize
        let layerTransform: CGAffineTransform
        let coreImageTransform: CGAffineTransform
    }

    /// Track transforms use top-left image coordinates; Core Image uses a
    /// bottom-left origin. Keep the two transforms explicit so quarter turns
    /// and mirrored input have the same appearance in both renderers.
    nonisolated static func layout(sourceSize: CGSize, preferredTransform: CGAffineTransform,
                                    renderSize requestedSize: CGSize? = nil) -> Layout? {
        let t = preferredTransform
        guard [sourceSize.width, sourceSize.height, t.a, t.b, t.c, t.d, t.tx, t.ty].allSatisfy({ $0.isFinite }),
              sourceSize.width > 0, sourceSize.height > 0,
              abs(t.a * t.d - t.b * t.c) > 0.000001 else { return nil }
        let bounds = CGRect(origin: .zero, size: sourceSize).applying(t)
        let size = requestedSize ?? bounds.size
        guard [bounds.minX, bounds.minY, bounds.width, bounds.height, size.width, size.height].allSatisfy({ $0.isFinite }),
              bounds.width > 0, bounds.height > 0, size.width >= 1, size.height >= 1,
              size.width < CGFloat(Int32.max), size.height < CGFloat(Int32.max) else { return nil }
        let upright = t.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let scale = CGAffineTransform(scaleX: size.width / bounds.width, y: size.height / bounds.height)
        let sourceFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceSize.height)
        let uprightFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        return Layout(uprightSize: bounds.size, renderSize: size, layerTransform: upright.concatenating(scale),
                      coreImageTransform: sourceFlip.concatenating(upright).concatenating(uprightFlip).concatenating(scale))
    }

    /// Translation is expressed in source pixels with a top-left origin.
    /// Core Image renders with a bottom-left origin, so the y pan is inverted.
    nonisolated static func zoomTransform(zoom: CGFloat, translation: CGPoint,
                                          naturalSize: CGSize, renderSize: CGSize) -> CGAffineTransform {
        guard zoom.isFinite, zoom > 1.0001,
              translation.x.isFinite, translation.y.isFinite,
              naturalSize.width.isFinite, naturalSize.height.isFinite,
              renderSize.width.isFinite, renderSize.height.isFinite,
              naturalSize.width > 0, naturalSize.height > 0,
              renderSize.width > 0, renderSize.height > 0 else { return .identity }
        return CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom,
            tx: renderSize.width * (1 - zoom) / 2 + translation.x * renderSize.width / naturalSize.width * zoom,
            ty: renderSize.height * (1 - zoom) / 2 - translation.y * renderSize.height / naturalSize.height * zoom)
    }

    nonisolated static func overlayRect(_ rect: CGRect, naturalSize: CGSize, renderSize: CGSize,
                                        zoom: CGFloat, translation: CGPoint) -> CGRect {
        let uprightRect = CGRect(x: rect.minX * renderSize.width,
                                 y: (1 - rect.maxY) * renderSize.height,
                                 width: rect.width * renderSize.width,
                                 height: rect.height * renderSize.height)
        return uprightRect.applying(zoomTransform(zoom: zoom, translation: translation,
                                                 naturalSize: naturalSize, renderSize: renderSize))
    }
}
