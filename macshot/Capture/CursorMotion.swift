import Foundation
import CoreGraphics

/// Render-ready pointer motion on the media clock. Built once per settings
/// change (off the main thread for long recordings) and sampled per frame.
/// Every query is a pure function of time, so scrubbing, playback and export
/// produce identical cursor positions.
nonisolated struct CursorTrack: Sendable {
    /// Uniform sampling of the smoothed path. Empty when smoothing is off, in
    /// which case `raw` samples are interpolated directly.
    let start: Double
    let interval: Double
    let xs: [Float]
    let ys: [Float]
    /// Raw samples (always kept: idle detection and click positions use them).
    let rawTimes: [Double]
    let rawXs: [Float]
    let rawYs: [Float]
    /// Start times of movement bursts following an idle period, and the time
    /// of the last movement in each burst. Used for idle hiding.
    let burstStarts: [Double]
    let burstEnds: [Double]

    var isEmpty: Bool { rawTimes.isEmpty }

    func position(at t: Double) -> CGPoint? {
        if !xs.isEmpty {
            let f = (t - start) / interval
            if f <= 0 { return CGPoint(x: CGFloat(xs[0]), y: CGFloat(ys[0])) }
            let i = Int(f)
            if i >= xs.count - 1 { return CGPoint(x: CGFloat(xs[xs.count - 1]), y: CGFloat(ys[ys.count - 1])) }
            let w = Float(f - Double(i))
            return CGPoint(x: CGFloat(xs[i] + (xs[i + 1] - xs[i]) * w), y: CGFloat(ys[i] + (ys[i + 1] - ys[i]) * w))
        }
        return CursorTrack.interpolate(times: rawTimes, xs: rawXs, ys: rawYs, at: t)
    }

    static func interpolate(times: [Double], xs: [Float], ys: [Float], at t: Double) -> CGPoint? {
        guard !times.isEmpty else { return nil }
        guard let i = CursorRecording.index(in: times, atOrBefore: t) else {
            return CGPoint(x: CGFloat(xs[0]), y: CGFloat(ys[0]))
        }
        guard i + 1 < times.count else { return CGPoint(x: CGFloat(xs[i]), y: CGFloat(ys[i])) }
        let span = times[i + 1] - times[i]
        let w = span > 0 ? Float((t - times[i]) / span) : 0
        return CGPoint(x: CGFloat(xs[i] + (xs[i + 1] - xs[i]) * w), y: CGFloat(ys[i] + (ys[i + 1] - ys[i]) * w))
    }

    /// Opacity from idle hiding: 1 while moving, fades out `delay` seconds
    /// after the last movement, fades back in when movement resumes.
    func idleOpacity(at t: Double, delay: Double, fadeOut: Double = 0.35, fadeIn: Double = 0.12) -> CGFloat {
        guard !burstStarts.isEmpty else { return 1 }
        guard let i = CursorRecording.index(in: burstStarts, atOrBefore: t) else {
            // Before any movement: visible from the start, then idle-fades.
            return CursorTrack.fade(elapsed: t - (rawTimes.first ?? 0), delay: delay, duration: fadeOut)
        }
        let burstStart = burstStarts[i], burstEnd = burstEnds[i]
        let appear = i == 0 ? 1 : CGFloat(min(1, max(0, (t - burstStart) / fadeIn)))
        guard t > burstEnd else { return appear }
        return min(appear, CursorTrack.fade(elapsed: t - burstEnd, delay: delay, duration: fadeOut))
    }

    private static func fade(elapsed: Double, delay: Double, duration: Double) -> CGFloat {
        guard elapsed > delay else { return 1 }
        return CGFloat(max(0, 1 - (elapsed - delay) / duration))
    }
}

nonisolated enum CursorMotion {
    /// Movement below this (normalized) is jitter, not intent.
    static let movementEpsilon: Float = 0.0008
    /// A gap without movement longer than this starts a new burst.
    static let burstGap: Double = 0.25
    static let outputRate: Double = 120

    /// Angular frequency of the critically damped follower for a smoothing
    /// amount in 0…1. 0 disables smoothing; 1 is a slow, floaty glide.
    static func angularFrequency(forSmoothing amount: Double) -> Double {
        let a = min(1, max(0, amount))
        return 34 - 27 * a
    }

    static func buildTrack(from recording: CursorRecording, smoothing: Double) -> CursorTrack {
        // Without a cancellation source this always completes.
        buildTrack(from: recording, smoothing: smoothing, isCancelled: { false })!
    }

    /// Returns nil when `isCancelled` reports cancellation (long takes).
    static func buildTrack(from recording: CursorRecording, smoothing: Double,
                           isCancelled: () -> Bool) -> CursorTrack? {
        let (starts, ends) = bursts(times: recording.times, xs: recording.xs, ys: recording.ys)
        guard smoothing > 0.001, recording.times.count > 1,
              let first = recording.times.first, let last = recording.times.last, last > first else {
            return CursorTrack(start: 0, interval: 1 / outputRate, xs: [], ys: [],
                               rawTimes: recording.times, rawXs: recording.xs, rawYs: recording.ys,
                               burstStarts: starts, burstEnds: ends)
        }
        let omega = angularFrequency(forSmoothing: smoothing)
        let interval = 1 / outputRate
        // A short settle tail lets the glide finish after the final sample.
        let end = last + 4 / omega
        let count = Int(((end - first) / interval).rounded(.up)) + 1
        var xs = [Float](repeating: 0, count: count)
        var ys = [Float](repeating: 0, count: count)
        let substeps = 4
        let dt = interval / Double(substeps)
        var px = Double(recording.xs[0]), py = Double(recording.ys[0])
        var vx = 0.0, vy = 0.0
        var cursor = 0
        let times = recording.times, rawX = recording.xs, rawY = recording.ys
        for n in 0..<count {
            if n & 0x3FFF == 0, isCancelled() { return nil }
            let tEnd = first + Double(n) * interval
            if n > 0 {
                for s in 1...substeps {
                    let t = tEnd - interval + Double(s) * dt
                    while cursor + 1 < times.count, times[cursor + 1] <= t { cursor += 1 }
                    let target: (Double, Double)
                    if cursor + 1 < times.count {
                        let span = times[cursor + 1] - times[cursor]
                        let w = span > 0 ? (t - times[cursor]) / span : 0
                        target = (Double(rawX[cursor]) + (Double(rawX[cursor + 1]) - Double(rawX[cursor])) * w,
                                  Double(rawY[cursor]) + (Double(rawY[cursor + 1]) - Double(rawY[cursor])) * w)
                    } else {
                        target = (Double(rawX[cursor]), Double(rawY[cursor]))
                    }
                    (px, vx) = criticallyDamped(position: px, velocity: vx, target: target.0, omega: omega, dt: dt)
                    (py, vy) = criticallyDamped(position: py, velocity: vy, target: target.1, omega: omega, dt: dt)
                }
            }
            xs[n] = Float(px); ys[n] = Float(py)
        }
        return CursorTrack(start: first, interval: interval, xs: xs, ys: ys,
                           rawTimes: recording.times, rawXs: recording.xs, rawYs: recording.ys,
                           burstStarts: starts, burstEnds: ends)
    }

    /// Exact step of a critically damped spring toward a fixed target.
    static func criticallyDamped(position x: Double, velocity v: Double, target: Double,
                                 omega: Double, dt: Double) -> (Double, Double) {
        let offset = x - target
        let decay = exp(-omega * dt)
        let temp = (v + omega * offset) * dt
        let newPosition = target + (offset + temp) * decay
        let newVelocity = (v - omega * temp) * decay
        return (newPosition, newVelocity)
    }

    /// Splits raw motion into bursts of intentional movement.
    static func bursts(times: [Double], xs: [Float], ys: [Float]) -> ([Double], [Double]) {
        var starts: [Double] = [], ends: [Double] = []
        guard times.count > 1 else { return (starts, ends) }
        var lastMoveTime: Double?
        for i in 1..<times.count {
            let dx = abs(xs[i] - xs[i - 1]), dy = abs(ys[i] - ys[i - 1])
            guard max(dx, dy) > movementEpsilon else { continue }
            let t = times[i]
            if let previous = lastMoveTime, t - previous <= burstGap {
                ends[ends.count - 1] = t
            } else {
                starts.append(times[i - 1])
                ends.append(t)
            }
            lastMoveTime = t
        }
        return (starts, ends)
    }

    /// Opacity while typing: the pointer hides from a key press until it
    /// next moves (common screen-recorder behavior that keeps text visible).
    static func typingOpacity(at t: Double, keyTimes: [Double], track: CursorTrack, fade: Double = 0.15) -> CGFloat {
        guard let k = CursorRecording.index(in: keyTimes, atOrBefore: t) else { return 1 }
        let keyTime = keyTimes[k]
        // Movement after the key press brings the pointer back.
        if let b = CursorRecording.index(in: track.burstStarts, atOrBefore: t), track.burstStarts[b] > keyTime {
            return CGFloat(min(1, (t - track.burstStarts[b]) / fade))
        }
        if let b = CursorRecording.index(in: track.burstStarts, atOrBefore: t), track.burstEnds[b] > keyTime {
            return 1
        }
        return CGFloat(max(0, 1 - (t - keyTime) / fade))
    }
}

/// Pointer tilt from horizontal speed ("sway").
nonisolated enum CursorSway {
    /// Largest tilt, in radians (about 14°).
    static let maxAngle: Double = 0.24

    /// Tilt at `t`: positive (counter-clockwise) when moving left. Uses the
    /// smoothed path, so the tilt eases in and out with the motion.
    static func angle(at t: Double, track: CursorTrack, amount: Double, aspect: Double) -> Double {
        guard amount > 0.001, let a = track.position(at: t - 0.04), let b = track.position(at: t) else { return 0 }
        // Normalized units per second, horizontal only, in content aspect.
        let velocity = Double(b.x - a.x) / 0.04 * aspect
        let tilt = -tanh(velocity * 0.9) * maxAngle * amount
        return tilt.isFinite ? tilt : 0
    }
}

/// Click pulse timing shared by preview and export.
nonisolated enum CursorClickEffect {
    static let duration: Double = 0.5

    /// Progress 0…1 of the most recent click's pulse at `t`, and that click.
    static func activeClick(at t: Double, clicks: [CursorRecording.Click]) -> (click: CursorRecording.Click, progress: Double)? {
        guard !clicks.isEmpty else { return nil }
        var lo = 0, hi = clicks.count - 1
        guard clicks[0].time <= t else { return nil }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if clicks[mid].time <= t { lo = mid } else { hi = mid - 1 }
        }
        let click = clicks[lo]
        let progress = (t - click.time) / duration
        guard progress >= 0, progress < 1 else { return nil }
        return (click, progress)
    }

    /// Cursor scale dip while a button is held ("press" feel).
    static func pressScale(at t: Double, clicks: [CursorRecording.Click]) -> CGFloat {
        guard let (click, _) = activeClick(at: t, clicks: clicks) else { return 1 }
        let held = (click.upTime ?? click.time + 0.12) - click.time
        let local = t - click.time
        let press = 0.07, release = 0.18
        if local < press { return 1 - 0.18 * CGFloat(local / press) }
        if local < max(press, held) { return 0.82 }
        let r = (local - max(press, held)) / release
        guard r < 1 else { return 1 }
        // Slight overshoot on release.
        let eased = 1 - pow(1 - r, 3)
        return 0.82 + 0.18 * CGFloat(eased) + 0.06 * CGFloat(sin(r * .pi))
    }
}
