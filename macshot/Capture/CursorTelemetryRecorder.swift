import AppKit
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers

/// Appends telemetry records to disk. All calls must happen on one serial
/// queue (the recorder's). Data reaches the file in small batches so an
/// interrupted recording keeps nearly everything that was sampled.
nonisolated final class CursorTelemetryWriter {
    private let handle: FileHandle
    private var buffer = Data()
    private var lastSync = CFAbsoluteTimeGetCurrent()
    private(set) var isClosed = false
    /// Bytes written so far, including the header.
    private(set) var byteCount = 0

    init(url: URL, header: CursorTelemetry.Header) throws {
        let headerData = try CursorTelemetry.encodeHeader(header)
        guard FileManager.default.createFile(atPath: url.path, contents: headerData,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        byteCount = headerData.count
    }

    func append(_ event: CursorTelemetry.Event) {
        guard !isClosed else { return }
        CursorTelemetry.encode(event, into: &buffer)
        // Keep memory bounded even if flushing were delayed.
        if buffer.count >= 64 * 1024 { flush() }
    }

    /// Hands buffered records to the kernel; every ten seconds also forces
    /// them to stable storage, matching the MP4 fragment interval.
    func flush(forceSync: Bool = false) {
        guard !isClosed else { return }
        if !buffer.isEmpty {
            do {
                try handle.write(contentsOf: buffer)
                byteCount += buffer.count
            } catch {
                // Telemetry is an enhancement: a full disk stops it, never the take.
                close()
                return
            }
            buffer.removeAll(keepingCapacity: true)
        }
        let now = CFAbsoluteTimeGetCurrent()
        if forceSync || now - lastSync >= 10 {
            try? handle.synchronize()
            lastSync = now
        }
    }

    func close() {
        guard !isClosed else { return }
        if !buffer.isEmpty { try? handle.write(contentsOf: buffer); byteCount += buffer.count }
        buffer.removeAll()
        try? handle.synchronize()
        try? handle.close()
        isClosed = true
    }

    deinit { close() }
}

/// Decides which records a pointer poll produces. Stationary polls write
/// nothing; the first change after a pause is preceded by a "hold" sample
/// at the resting position, so playback never drifts across a pause.
nonisolated struct PointerSampler {
    static let sampleInterval: Double = 0.008
    static let holdThreshold: Double = 0.02
    private var lastX: Float = .nan
    private var lastY: Float = .nan
    private var lastWritten: Double = -.infinity
    private var buttonsDown: [Bool] = [false, false, false]

    mutating func sample(time now: Double, x: Float, y: Float, buttons: [Bool]) -> [CursorTelemetry.Event] {
        let kinds: [CursorTelemetry.Button] = [.left, .right, .other]
        var events: [CursorTelemetry.Event] = []
        for (index, down) in buttons.prefix(3).enumerated() where down != buttonsDown[index] {
            buttonsDown[index] = down
            events.append(.button(time: now, button: kinds[index], down: down, x: x, y: y))
        }
        if events.isEmpty, x != lastX || y != lastY { events.append(.move(time: now, x: x, y: y)) }
        if !events.isEmpty {
            if lastX.isFinite, now - lastWritten > Self.holdThreshold {
                events.insert(.move(time: now - Self.sampleInterval, x: lastX, y: lastY), at: 0)
            }
            lastWritten = now
        }
        lastX = x; lastY = y
        return events
    }
}

/// Samples the pointer during a recording and streams it to a telemetry file.
///
/// Position and buttons are polled on a background queue with Core Graphics
/// calls that need no Input Monitoring permission. The cursor image is read on
/// the main thread (AppKit) at a lower rate and deduplicated. Keystrokes arrive
/// from the existing keystroke overlay's event tap when that feature is on.
final class CursorTelemetryRecorder {
    private let queue = DispatchQueue(label: "macshot.cursor-telemetry", qos: .userInitiated)
    nonisolated(unsafe) private var writer: CursorTelemetryWriter?
    nonisolated(unsafe) private var sampler = PointerSampler()
    nonisolated(unsafe) private var paused = false
    nonisolated(unsafe) private var lastFlush = CFAbsoluteTimeGetCurrent()
    private var positionTimer: DispatchSourceTimer?
    private var shapeTimer: Timer?
    private var knownShapes: [Int: UInt32] = [:]
    private var nextShapeID: UInt32 = 1
    private var currentShapeID: UInt32 = 0
    /// Global display region (Core Graphics coordinates: top-left origin of
    /// the primary display, points) that the video covers.
    private let regionOrigin: CGPoint
    private let regionSize: CGSize

    let url: URL

    /// - Parameters:
    ///   - region: Recorded area in global Core Graphics coordinates.
    init(url: URL, region: CGRect, header: CursorTelemetry.Header) throws {
        self.url = url
        regionOrigin = region.origin
        regionSize = region.size
        writer = try CursorTelemetryWriter(url: url, header: header)
    }

    /// Global CG rect for an AppKit screen rect (bottom-left origin).
    static func globalRegion(forAppKitRect rect: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Normalized position of a global point inside the recorded region.
    nonisolated static func normalized(_ point: CGPoint, origin: CGPoint, size: CGSize) -> (Float, Float) {
        guard size.width > 0, size.height > 0 else { return (0, 0) }
        return (Float((point.x - origin.x) / size.width), Float((point.y - origin.y) / size.height))
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(2))
        let origin = regionOrigin, size = regionSize
        timer.setEventHandler { [weak self] in self?.samplePointer(origin: origin, size: size) }
        positionTimer = timer
        timer.resume()

        let shapes = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleShape() }
        }
        RunLoop.main.add(shapes, forMode: .common)
        shapeTimer = shapes
        sampleShape()
    }

    /// Called on the writer queue with the host time of the first video frame.
    nonisolated func markStart(hostTime: Double) {
        queue.async { [weak self] in self?.writer?.append(.start(time: hostTime)) }
    }

    func pause() {
        let now = Self.hostNow()
        queue.async { [weak self] in
            guard let self, !self.paused else { return }
            self.paused = true
            self.writer?.append(.pause(time: now))
        }
    }

    func resume(pausedDuration: Double) {
        let now = Self.hostNow()
        queue.async { [weak self] in
            guard let self, self.paused else { return }
            self.paused = false
            self.writer?.append(.resume(time: now, pausedDuration: pausedDuration))
            self.writer?.flush()
        }
    }

    /// Keystrokes are recorded only when the user enabled keystroke display.
    nonisolated func recordKey(down: Bool, keyCode: UInt16, modifiers: UInt32, characters: String) {
        let now = Self.hostNow()
        queue.async { [weak self] in
            guard let self, !self.paused else { return }
            self.writer?.append(.key(time: now, down: down, keyCode: keyCode, modifiers: modifiers, characters: characters))
        }
    }

    /// Stops sampling and closes the file. Blocks briefly until the last
    /// batch is written so the editor opening next can read it.
    func stop() {
        positionTimer?.cancel()
        positionTimer = nil
        shapeTimer?.invalidate()
        shapeTimer = nil
        queue.sync { writer?.close(); writer = nil }
    }

    nonisolated static func hostNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    // MARK: Sampling

    nonisolated private func samplePointer(origin: CGPoint, size: CGSize) {
        guard let writer, !paused else { return }
        guard let location = CGEvent(source: nil)?.location else { return }
        let now = Self.hostNow()
        let (x, y) = Self.normalized(location, origin: origin, size: size)
        let buttons = [CGMouseButton.left, .right, .center].map {
            CGEventSource.buttonState(.combinedSessionState, button: $0)
        }
        for event in sampler.sample(time: now, x: x, y: y, buttons: buttons) { writer.append(event) }
        let wall = CFAbsoluteTimeGetCurrent()
        if wall - lastFlush >= 0.5 {
            writer.flush()
            lastFlush = wall
        }
    }

    private func sampleShape() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard let signature = Self.signature(of: image) else { return }
        let id: UInt32
        if let known = knownShapes[signature] {
            id = known
        } else {
            guard let png = Self.pngData(for: image) else { return }
            id = nextShapeID
            nextShapeID &+= 1
            knownShapes[signature] = id
            let shape = CursorTelemetry.Shape(id: id, hotspot: cursor.hotSpot, size: image.size, png: png)
            queue.async { [weak self] in self?.writer?.append(.shapeDefinition(shape)) }
        }
        guard id != currentShapeID else { return }
        currentShapeID = id
        let now = Self.hostNow()
        queue.async { [weak self] in
            guard let self, !self.paused else { return }
            self.writer?.append(.shape(time: now, id: id))
        }
    }

    /// Cheap identity for a cursor image: its smallest representation's bytes.
    private static func signature(of image: NSImage) -> Int? {
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        guard let rep = reps.min(by: { $0.pixelsWide < $1.pixelsWide }), let bytes = rep.bitmapData else {
            return image.representations.isEmpty ? nil : Int(bitPattern: UInt(image.size.width * 1000 + image.size.height))
        }
        var hasher = Hasher()
        hasher.combine(rep.pixelsWide)
        hasher.combine(rep.pixelsHigh)
        hasher.combine(bytes: UnsafeRawBufferPointer(start: bytes, count: rep.bytesPerRow * rep.pixelsHigh))
        return hasher.finalize()
    }

    /// PNG of the sharpest representation, capped at 8× the point size.
    private static func pngData(for image: NSImage) -> Data? {
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
            .filter { CGFloat($0.pixelsWide) <= image.size.width * 8 + 1 }
        if let best = reps.max(by: { $0.pixelsWide < $1.pixelsWide }),
           let data = best.representation(using: .png, properties: [:]) {
            return data
        }
        var rect = CGRect(origin: .zero, size: CGSize(width: image.size.width * 4, height: image.size.height * 4))
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
