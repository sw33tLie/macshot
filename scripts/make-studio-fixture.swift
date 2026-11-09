// Generates a synthetic "screen recording" plus pointer telemetry for the
// video editor probe: an app-like UI, a pointer that moves, clicks and types.
// Usage: swiftc -parse-as-library macshot/Capture/CursorTelemetry.swift macshot/Model/LenientDecoding.swift \
//          scripts/make-studio-fixture.swift -o /tmp/fixture && /tmp/fixture <session-dir> [seconds]
import AVFoundation
import AppKit

@main struct FixtureMain {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else { print("usage: fixture <dir> [seconds]"); exit(2) }
        let dir = URL(fileURLWithPath: args[1], isDirectory: true)
        let seconds = args.count > 2 ? Double(args[2]) ?? 16 : 16
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let width = 1920, height = 1200, fps = 30
        let video = dir.appendingPathComponent("Recording.mp4")
        try? FileManager.default.removeItem(at: video)
        let script = Script(duration: seconds)
        try writeVideo(url: video, width: width, height: height, fps: fps, script: script)
        try writeTelemetry(url: dir.appendingPathComponent("cursor.mstl"), script: script,
                           pointSize: CGSize(width: width / 2, height: height / 2),
                           pixelSize: CGSize(width: width, height: height), fps: fps)
        print(video.path)
    }

    /// What happens when: pointer path, clicks, typing.
    struct Script {
        let duration: Double
        let waypoints: [(t: Double, x: Double, y: Double, click: Bool)]
        let typing: (start: Double, text: String)

        init(duration: Double) {
            self.duration = duration
            let s = duration / 16
            waypoints = [
                (0.0, 0.50, 0.55, false), (1.2 * s, 0.14, 0.24, false), (1.6 * s, 0.14, 0.24, true),
                (2.8 * s, 0.15, 0.36, false), (3.1 * s, 0.15, 0.36, true), (5.0 * s, 0.62, 0.30, false),
                (5.4 * s, 0.62, 0.30, true), (9.5 * s, 0.63, 0.31, false), (10.6 * s, 0.84, 0.78, false),
                (11.0 * s, 0.84, 0.78, true), (13.0 * s, 0.40, 0.66, false), (13.4 * s, 0.40, 0.66, true),
                (duration, 0.52, 0.58, false),
            ]
            typing = (6.0 * s, "Ship the new editor")
        }

        func pointer(at t: Double) -> (Double, Double) {
            for (a, b) in zip(waypoints, waypoints.dropFirst()) where t >= a.t && t <= b.t {
                let f = (t - a.t) / max(0.0001, b.t - a.t)
                let e = f * f * (3 - 2 * f)
                // Slight arc for natural movement.
                let arc = sin(f * .pi) * 0.03
                return (a.x + (b.x - a.x) * e, a.y + (b.y - a.y) * e - arc)
            }
            let last = waypoints.last!
            return (last.x, last.y)
        }

        var clicks: [Double] { waypoints.filter(\.click).map(\.t) }

        func typed(at t: Double) -> String {
            guard t >= typing.start else { return "" }
            let count = min(typing.text.count, Int((t - typing.start) / 0.14))
            return String(typing.text.prefix(count))
        }
    }

    static func writeVideo(url: URL, width: Int, height: Int, fps: Int, script: Script) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        // A quiet audio track so the waveform and captions paths are exercised.
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
        ])
        writer.add(audio)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        var sample = 0
        let totalSamples = Int(script.duration * 48_000)
        // Appends audio up to `seconds` (speech-like tone bursts).
        func appendAudio(until seconds: Double) {
            let target = min(totalSamples, Int(seconds * 48_000))
            while sample < target, audio.isReadyForMoreMediaData {
                let count = min(4800, target - sample)
                var pcm = [Int16](repeating: 0, count: count)
                for j in 0..<count {
                    let s = Double(sample + j) / 48_000
                    let envelope = max(0, sin(s * .pi * 1.7)) * (0.5 + 0.5 * sin(s * 13))
                    pcm[j] = Int16(envelope * 6000 * sin(2 * .pi * 220 * s))
                }
                var block: CMBlockBuffer?
                let bytes = count * 2
                CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                   customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                                   blockBufferOut: &block)
                pcm.withUnsafeBytes { raw in
                    _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
                                                      dataLength: bytes)
                }
                var buffer: CMSampleBuffer?
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!,
                    formatDescription: description!, sampleCount: count,
                    presentationTimeStamp: CMTime(value: CMTimeValue(sample), timescale: 48_000),
                    packetDescriptions: nil, sampleBufferOut: &buffer)
                audio.append(buffer!)
                sample += count
            }
        }
        let frames = Int(script.duration * Double(fps))
        for i in 0..<frames {
            let t = Double(i) / Double(fps)
            appendAudio(until: t + 0.5)
            while !input.isReadyForMoreMediaData { appendAudio(until: t + 1); usleep(500) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            drawFrame(ctx, width: CGFloat(width), height: CGFloat(height), t: t, script: script)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        while sample < totalSamples {
            appendAudio(until: script.duration)
            if sample < totalSamples { usleep(500) }
        }
        audio.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// A light, app-like UI: sidebar, toolbar, cards, a text field and buttons.
    static func drawFrame(_ ctx: CGContext, width W: CGFloat, height H: CGFloat, t: Double, script: Script) {
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x * W, y: H - (y + h) * H, width: w * W, height: h * H)
        }
        func fill(_ r: CGRect, _ c: (CGFloat, CGFloat, CGFloat), radius: CGFloat = 0, alpha: CGFloat = 1) {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: alpha))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, color: (CGFloat, CGFloat, CGFloat), bold: Bool = false) {
            let font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            let attr = NSAttributedString(string: s, attributes: [.font: font,
                .foregroundColor: NSColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1)])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: x * W, y: H - y * H)
            CTLineDraw(line, ctx)
        }
        fill(CGRect(x: 0, y: 0, width: W, height: H), (0.96, 0.96, 0.97))
        // Sidebar.
        fill(rect(0, 0, 0.22, 1), (0.92, 0.93, 0.95))
        let items = ["Inbox", "Projects", "Roadmap", "Design", "Releases", "Settings"]
        let clicks = script.clicks
        let selectedItem = t > clicks[1] ? 1 : (t > clicks[0] ? 0 : -1)
        for (i, item) in items.enumerated() {
            let y = 0.2 + CGFloat(i) * 0.06
            if i == selectedItem { fill(rect(0.02, y, 0.18, 0.045), (0.24, 0.47, 0.96), radius: 12) }
            text(item, 0.05, y + 0.031, size: 26, color: i == selectedItem ? (1, 1, 1) : (0.2, 0.22, 0.26), bold: i == selectedItem)
        }
        // Toolbar.
        fill(rect(0.22, 0, 0.78, 0.09), (1, 1, 1))
        text("macshot Studio · Project", 0.25, 0.058, size: 30, color: (0.1, 0.1, 0.12), bold: true)
        // Text field (typed into).
        let fieldActive = t > clicks[2]
        fill(rect(0.28, 0.24, 0.66, 0.1), fieldActive ? (0.24, 0.47, 0.96) : (0.85, 0.86, 0.88), radius: 16)
        fill(rect(0.2815, 0.2425, 0.6570, 0.095), (1, 1, 1), radius: 14)
        let typed = script.typed(at: t)
        text(typed.isEmpty ? "What are you working on?" : typed + ((Int(t * 2) % 2 == 0 && fieldActive) ? "|" : ""),
             0.3, 0.305, size: 34, color: typed.isEmpty ? (0.6, 0.6, 0.65) : (0.1, 0.1, 0.12))
        // Cards.
        for i in 0..<3 {
            let x = 0.28 + CGFloat(i) * 0.225
            fill(rect(x, 0.42, 0.2, 0.3), (1, 1, 1), radius: 20)
            fill(rect(x + 0.015, 0.44, 0.17, 0.12), [(0.99, 0.80, 0.55), (0.62, 0.84, 0.99), (0.77, 0.93, 0.70)][i], radius: 14)
            text(["Record", "Edit", "Share"][i], x + 0.02, 0.62, size: 30, color: (0.12, 0.12, 0.14), bold: true)
            text("Card body text line", x + 0.02, 0.665, size: 22, color: (0.45, 0.46, 0.5))
        }
        // Primary button (clicked at clicks[3]).
        let pressed = clicks.count > 3 && abs(t - clicks[3]) < 0.25
        let done = clicks.count > 3 && t > clicks[3]
        fill(rect(0.76, 0.75, 0.16, 0.07), pressed ? (0.16, 0.36, 0.82) : (0.24, 0.47, 0.96), radius: 16)
        text(done ? "Published ✓" : "Publish", 0.785, 0.795, size: 28, color: (1, 1, 1), bold: true)
        // Secondary button.
        fill(rect(0.32, 0.62 + 0.0, 0.0, 0.0), (0, 0, 0))
    }

    static func writeTelemetry(url: URL, script: Script, pointSize: CGSize, pixelSize: CGSize, fps: Int) throws {
        let header = CursorTelemetry.Header(sourcePointSize: pointSize, pixelSize: pixelSize, frameRate: fps,
                                            cursorHiddenInVideo: true, overlaysInTelemetry: true)
        var data = try CursorTelemetry.encodeHeader(header)
        // Arrow cursor image from AppKit (largest representation).
        let cursor = NSCursor.arrow
        if let rep = cursor.image.representations.compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide }),
           let png = rep.representation(using: .png, properties: [:]) {
            CursorTelemetry.encode(.shapeDefinition(.init(id: 1, hotspot: cursor.hotSpot, size: cursor.image.size, png: png)), into: &data)
        }
        let base = 1000.0
        CursorTelemetry.encode(.start(time: base), into: &data)
        CursorTelemetry.encode(.shape(time: base, id: 1), into: &data)
        var t = 0.0
        var clickIndex = 0
        let clicks = script.clicks
        while t <= script.duration {
            let (x, y) = script.pointer(at: t)
            CursorTelemetry.encode(.move(time: base + t, x: Float(x), y: Float(y)), into: &data)
            if clickIndex < clicks.count, t >= clicks[clickIndex] {
                CursorTelemetry.encode(.button(time: base + t, button: .left, down: true, x: Float(x), y: Float(y)), into: &data)
                CursorTelemetry.encode(.button(time: base + t + 0.11, button: .left, down: false, x: Float(x), y: Float(y)), into: &data)
                clickIndex += 1
            }
            t += 1.0 / 120
        }
        // Typing and one shortcut.
        for (i, ch) in script.typing.text.enumerated() {
            CursorTelemetry.encode(.key(time: base + script.typing.start + Double(i) * 0.14, down: true, keyCode: 0, modifiers: 0,
                                        characters: String(ch)), into: &data)
        }
        CursorTelemetry.encode(.key(time: base + script.typing.start + 3.2, down: true, keyCode: 1,
                                    modifiers: 1 << 20, characters: "s"), into: &data)
        try data.write(to: url)
    }
}
