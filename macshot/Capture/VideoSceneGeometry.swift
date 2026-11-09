import CoreGraphics

/// Where the recording sits in the exported frame. All rects use a top-left
/// origin in canvas pixels; content coordinates are normalized to the
/// upright (orientation-applied) source video, also top-left origin.
///
/// The camera (zoom) operates on the whole canvas, so the background moves
/// with it, exactly like a camera pushing in on a framed screen.
nonisolated struct VideoSceneLayout: Equatable, Sendable {
    /// Upright source size in pixels.
    let contentSize: CGSize
    /// Normalized crop of the source.
    let crop: CGRect
    /// Output size in pixels (even dimensions).
    let canvasSize: CGSize
    /// Recording placement inside the canvas.
    let videoRect: CGRect
    /// Rounded-corner radius of the recording, in canvas pixels.
    let cornerRadius: CGFloat
    let drawsBackground: Bool

    /// Canvas pixels per source pixel.
    var contentScale: CGFloat {
        let croppedWidth = contentSize.width * crop.width
        return croppedWidth > 0 ? videoRect.width / croppedWidth : 1
    }

    /// Normalized source point → canvas pixel (top-left origin).
    func canvasPoint(forContent p: CGPoint) -> CGPoint {
        let u = (p.x - crop.minX) / max(crop.width, 0.0001)
        let v = (p.y - crop.minY) / max(crop.height, 0.0001)
        return CGPoint(x: videoRect.minX + u * videoRect.width, y: videoRect.minY + v * videoRect.height)
    }

    /// Normalized source point → normalized canvas point.
    func sceneNormalized(forContent p: CGPoint) -> CGPoint {
        let c = canvasPoint(forContent: p)
        return CGPoint(x: c.x / max(canvasSize.width, 1), y: c.y / max(canvasSize.height, 1))
    }

    /// Normalized canvas point → normalized source point (inverse of above).
    func contentNormalized(forScene s: CGPoint) -> CGPoint {
        let cx = s.x * canvasSize.width, cy = s.y * canvasSize.height
        let u = (cx - videoRect.minX) / max(videoRect.width, 0.0001)
        let v = (cy - videoRect.minY) / max(videoRect.height, 0.0001)
        return CGPoint(x: crop.minX + u * crop.width, y: crop.minY + v * crop.height)
    }

    /// Normalized source rect → canvas pixel rect (top-left origin).
    func canvasRect(forContent r: CGRect) -> CGRect {
        let a = canvasPoint(forContent: CGPoint(x: r.minX, y: r.minY))
        let b = canvasPoint(forContent: CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// The same layout rendered at a different output size (preview scale).
    func scaled(by factor: CGFloat) -> VideoSceneLayout {
        VideoSceneLayout(contentSize: contentSize, crop: crop,
                         canvasSize: CGSize(width: canvasSize.width * factor, height: canvasSize.height * factor),
                         videoRect: CGRect(x: videoRect.minX * factor, y: videoRect.minY * factor,
                                           width: videoRect.width * factor, height: videoRect.height * factor),
                         cornerRadius: cornerRadius * factor, drawsBackground: drawsBackground)
    }
}

nonisolated enum VideoSceneGeometry {
    /// H.264 hardware encoders are reliable up to 4096 pixels per side.
    static let maxDimension: CGFloat = 4096

    /// - Parameters:
    ///   - contentSize: Upright source size in pixels.
    ///   - scale: Export scale (1 = keep the recording at native resolution).
    static func layout(contentSize: CGSize, crop rawCrop: CGRect, frame: VideoFrameStyle,
                       scale: CGFloat = 1, maxDimension: CGFloat = maxDimension) -> VideoSceneLayout? {
        guard contentSize.width.isFinite, contentSize.height.isFinite,
              contentSize.width >= 2, contentSize.height >= 2, scale.isFinite, scale > 0 else { return nil }
        let crop = VideoProjectLimits.normalizedRect(rawCrop)
        let cw = contentSize.width * crop.width, ch = contentSize.height * crop.height
        var canvas: CGSize
        var video: CGRect
        var radius: CGFloat = 0
        if frame.drawsBackground {
            let padding = CGFloat(frame.enabled ? frame.padding : 0)
            let margin = padding * min(cw, ch)
            var w = cw + 2 * margin, h = ch + 2 * margin
            if let ratio = frame.aspect.ratio {
                if w / h < ratio { w = h * ratio } else { h = w / ratio }
            }
            canvas = CGSize(width: w, height: h)
            video = CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch)
            if frame.enabled { radius = CGFloat(frame.cornerRadius) * min(cw, ch) / 1080 }
        } else {
            canvas = CGSize(width: cw, height: ch)
            video = CGRect(origin: .zero, size: canvas)
        }
        let fit = min(1, maxDimension / max(canvas.width, canvas.height))
        let s = scale * fit
        let evenW = max(2, (Int((canvas.width * s).rounded()) / 2) * 2)
        let evenH = max(2, (Int((canvas.height * s).rounded()) / 2) * 2)
        let output = CGSize(width: evenW, height: evenH)
        if frame.drawsBackground {
            // Scale uniformly to the rounded canvas and keep the recording centered.
            let k = min(output.width / canvas.width, output.height / canvas.height)
            let vw = video.width * k, vh = video.height * k
            video = CGRect(x: (output.width - vw) / 2, y: (output.height - vh) / 2, width: vw, height: vh)
            radius *= k
        } else {
            video = CGRect(origin: .zero, size: output)
        }
        radius = min(radius, min(video.width, video.height) / 2)
        return VideoSceneLayout(contentSize: contentSize, crop: crop, canvasSize: output, videoRect: video,
                                cornerRadius: radius, drawsBackground: frame.drawsBackground)
    }
}

// MARK: - Camera

/// Camera over the canvas: `zoom` ≥ 1 and the visible window's center in
/// normalized canvas coordinates (top-left origin).
nonisolated struct CameraState: Equatable, Sendable {
    var zoom: CGFloat
    var focus: CGPoint

    static let identity = CameraState(zoom: 1, focus: CGPoint(x: 0.5, y: 0.5))

    var isIdentity: Bool { zoom <= 1.0001 }

    /// Focus limited so the visible window stays inside the canvas.
    static func clampedFocus(_ f: CGPoint, zoom: CGFloat) -> CGPoint {
        let h = 0.5 / max(zoom, 1)
        return CGPoint(x: min(max(f.x, h), 1 - h), y: min(max(f.y, h), 1 - h))
    }

    /// Canvas-pixel (top-left) transform applying this camera.
    func transform(canvasSize: CGSize) -> CGAffineTransform {
        guard !isIdentity else { return .identity }
        let f = CameraState.clampedFocus(focus, zoom: zoom)
        let fx = f.x * canvasSize.width, fy = f.y * canvasSize.height
        // p' = (p - f) * z + center
        return CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom,
                                 tx: canvasSize.width / 2 - fx * zoom, ty: canvasSize.height / 2 - fy * zoom)
    }

    /// Visible window in normalized canvas coordinates.
    var visibleRect: CGRect {
        let f = CameraState.clampedFocus(focus, zoom: zoom)
        let side = 1 / max(zoom, 1)
        return CGRect(x: f.x - side / 2, y: f.y - side / 2, width: side, height: side)
    }
}

/// Precomputed camera motion, sampled at 60 Hz inside zoom spans and the
/// identity elsewhere. Built on the main actor from immutable inputs; the
/// compositor only reads it.
nonisolated struct CameraPath: Sendable {
    struct Span: Sendable {
        let start: Double
        let interval: Double
        let zooms: [Float]
        let fxs: [Float]
        let fys: [Float]
        var end: Double { start + Double(max(0, zooms.count - 1)) * interval }
    }

    let spans: [Span]

    static let empty = CameraPath(spans: [])

    func state(at t: Double) -> CameraState {
        guard t.isFinite, let span = spans.last(where: { $0.start <= t }), t <= span.end else { return .identity }
        let f = (t - span.start) / span.interval
        let i = min(span.zooms.count - 1, max(0, Int(f)))
        let j = min(span.zooms.count - 1, i + 1)
        let w = Float(max(0, min(1, f - Double(i))))
        let z = span.zooms[i] + (span.zooms[j] - span.zooms[i]) * w
        let x = span.fxs[i] + (span.fxs[j] - span.fxs[i]) * w
        let y = span.fys[i] + (span.fys[j] - span.fys[i]) * w
        return CameraState(zoom: CGFloat(max(1, z)), focus: CGPoint(x: CGFloat(x), y: CGFloat(y)))
    }
}

nonisolated enum CameraPathBuilder {
    struct Zoom: Sendable {
        var start: Double
        var end: Double
        var level: CGFloat
        /// Focus in normalized content coordinates.
        var center: CGPoint
        var follows: Bool
        var rampIn: Double
        var rampOut: Double
    }

    static let sampleRate: Double = 60
    /// Pan responsiveness between focus targets (rad/s of a critically damped spring).
    static let panOmega: Double = 5.5
    static let followOmega: Double = 4.2

    static func build(zooms input: [Zoom], layout: VideoSceneLayout, cursor: CursorTrack?,
                      connect: Bool, connectGap: Double = VideoZoomStyle.connectGap,
                      deadZone: Double = 0.45) -> CameraPath {
        let zooms = input
            .filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && $0.level.isFinite }
            .sorted { $0.start < $1.start }
        guard !zooms.isEmpty else { return .empty }
        // Chains of zooms separated by short gaps pan instead of zooming out.
        var chains: [[Zoom]] = []
        for zoom in zooms {
            if connect, var chain = chains.last, let last = chain.last, zoom.start - last.end <= connectGap {
                chain.append(zoom)
                chains[chains.count - 1] = chain
            } else if let last = chains.last?.last, zoom.start < last.end {
                // Overlapping zooms are not connected: the later one wins its
                // own range; clip it to start where the earlier ends.
                var clipped = zoom
                clipped.start = last.end
                if clipped.end > clipped.start { chains.append([clipped]) }
            } else {
                chains.append([zoom])
            }
        }
        return CameraPath(spans: chains.map { span(for: $0, layout: layout, cursor: cursor, deadZone: deadZone) })
    }

    private static func span(for chain: [Zoom], layout: VideoSceneLayout, cursor: CursorTrack?,
                             deadZone: Double) -> CameraPath.Span {
        let interval = 1 / sampleRate
        let start = chain[0].start, end = chain[chain.count - 1].end
        let count = max(2, Int(((end - start) * sampleRate).rounded(.up)) + 1)
        var zs = [Float](repeating: 1, count: count)
        var xs = [Float](repeating: 0.5, count: count)
        var ys = [Float](repeating: 0.5, count: count)

        func cursorScene(_ t: Double) -> CGPoint? {
            guard let p = cursor?.position(at: t) else { return nil }
            return layout.sceneNormalized(forContent: p)
        }
        func staticTarget(_ zoom: Zoom) -> CGPoint { layout.sceneNormalized(forContent: zoom.center) }

        // Initial focus: where the first zoom looks.
        let first = chain[0]
        var focus = first.follows ? (cursorScene(first.start) ?? staticTarget(first)) : staticTarget(first)
        var velocity = CGPoint.zero
        var followTarget = focus

        for n in 0..<count {
            let t = min(end, start + Double(n) * interval)
            let (level, index, inGap) = level(at: t, chain: chain)
            let active = chain[inGap ? min(index + 1, chain.count - 1) : index]
            let z = max(1, level)
            // Target for this instant.
            var target: CGPoint
            var omega = panOmega
            if active.follows, let c = cursorScene(t) {
                let h = 0.5 / Double(max(z, 1))
                let zone = h * deadZone
                if abs(Double(c.x - followTarget.x)) > zone { followTarget.x = c.x }
                if abs(Double(c.y - followTarget.y)) > zone { followTarget.y = c.y }
                target = followTarget
                omega = followOmega
            } else {
                target = staticTarget(active)
                followTarget = target
            }
            if n > 0 {
                let dt = interval
                let x = CursorMotion.criticallyDamped(position: Double(focus.x), velocity: Double(velocity.x),
                                                      target: Double(target.x), omega: omega, dt: dt)
                let y = CursorMotion.criticallyDamped(position: Double(focus.y), velocity: Double(velocity.y),
                                                      target: Double(target.y), omega: omega, dt: dt)
                focus = CGPoint(x: x.0, y: y.0)
                velocity = CGPoint(x: x.1, y: y.1)
            } else {
                focus = target
            }
            // Keep the spring state inside the reachable range so it never
            // lags behind a clamp it cannot see.
            let clamped = CameraState.clampedFocus(focus, zoom: z)
            if clamped != focus {
                if clamped.x != focus.x { velocity.x = 0 }
                if clamped.y != focus.y { velocity.y = 0 }
                focus = clamped
            }
            zs[n] = Float(z); xs[n] = Float(focus.x); ys[n] = Float(focus.y)
        }
        return CameraPath.Span(start: start, interval: interval, zooms: zs, fxs: xs, fys: ys)
    }

    /// Zoom level inside a chain at `t`, the index of the zoom covering (or
    /// preceding) `t`, and whether `t` is in a gap before the next zoom.
    static let minimumBlend: Double = 0.6

    static func level(at t: Double, chain: [Zoom]) -> (CGFloat, Int, Bool) {
        let first = chain[0], last = chain[chain.count - 1]
        // Transitions between connected zooms span their gap, widened to a
        // minimum so touching zooms with different levels never jump.
        for i in 1..<max(1, chain.count) {
            let previous = chain[i - 1], next = chain[i]
            let gap = max(0, next.start - previous.end)
            let pad = max(0, (minimumBlend - gap) / 2)
            let from = previous.end - pad, to = next.start + pad
            guard t >= from, t < to else { continue }
            let p = (t - from) / max(to - from, 0.0001)
            let blended = previous.level + (next.level - previous.level) * CGFloat(smootherstep(p))
            return (blended, i - 1, t >= previous.end || p >= 0.5)
        }
        for (i, zoom) in chain.enumerated() {
            guard t <= zoom.end || i == chain.count - 1 else { continue }
            if t < zoom.start, i > 0 { return (chain[i - 1].level, i - 1, true) }
            var amount: Double = 1
            let duration = zoom.end - zoom.start
            if i == 0 {
                let ramp = min(first.rampIn, duration / 2)
                if ramp > 0, t - first.start < ramp { amount = min(amount, smootherstep((t - first.start) / ramp)) }
            }
            if i == chain.count - 1 {
                let ramp = min(last.rampOut, duration / 2)
                if ramp > 0, last.end - t < ramp { amount = min(amount, smootherstep((last.end - t) / ramp)) }
            }
            return (1 + (zoom.level - 1) * CGFloat(amount), i, false)
        }
        return (1, chain.count - 1, false)
    }

    static func smootherstep(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

// MARK: - Auto zoom

/// Suggests zoom segments from recorded clicks and typing, following the
/// pointer. Pure and deterministic.
nonisolated enum AutoZoomPlanner {
    struct Suggestion: Equatable, Sendable {
        var start: Double
        var end: Double
        var center: CGPoint
        var level: CGFloat
    }

    static let clusterGap: Double = 2.4
    static let leadIn: Double = 0.7
    static let tail: Double = 1.5
    static let minDuration: Double = 2.0

    static func suggestions(recording: CursorRecording, track: CursorTrack?, range: ClosedRange<Double>,
                            level: CGFloat, avoiding occupied: [ClosedRange<Double>] = []) -> [Suggestion] {
        struct Activity { var time: Double; var point: CGPoint }
        var events: [Activity] = recording.clicks.compactMap { click in
            let p = click.position
            guard (0...1).contains(p.x), (0...1).contains(p.y), range.contains(click.time) else { return nil }
            return Activity(time: click.time, point: p)
        }
        // Typing bursts: sample where the pointer (usually the caret area) is.
        var lastKeyTime = -Double.infinity
        for key in recording.keys where range.contains(key.time) {
            if key.time - lastKeyTime > 0.8, let p = track?.position(at: key.time) ?? recording.rawPosition(at: key.time),
               (0...1).contains(p.x), (0...1).contains(p.y) {
                events.append(Activity(time: key.time, point: p))
            }
            lastKeyTime = key.time
        }
        events.sort { $0.time < $1.time }
        guard !events.isEmpty else { return [] }

        var clusters: [[Activity]] = []
        for event in events {
            if let last = clusters.last?.last, event.time - last.time <= clusterGap {
                clusters[clusters.count - 1].append(event)
            } else {
                clusters.append([event])
            }
        }
        var result: [Suggestion] = []
        for cluster in clusters {
            var start = cluster[0].time - leadIn
            var end = cluster[cluster.count - 1].time + tail
            if end - start < minDuration { end = start + minDuration }
            start = max(range.lowerBound, start)
            end = min(range.upperBound, end)
            guard end - start >= 0.6 else { continue }
            if let previous = result.last, start < previous.end {
                result[result.count - 1].end = max(previous.end, end)
                continue
            }
            // Zoom out enough to keep the whole cluster in view.
            let xs = cluster.map(\.point.x), ys = cluster.map(\.point.y)
            let spread = max((xs.max()! - xs.min()!), (ys.max()! - ys.min()!)) + 0.18
            let fitted = min(level, max(1.25, 1 / spread))
            result.append(Suggestion(start: start, end: end, center: cluster[0].point, level: fitted))
        }
        return result.filter { s in !occupied.contains { $0.lowerBound < s.end && $0.upperBound > s.start } }
    }
}
