import Foundation
import CoreGraphics

/// Pointer, click and keystroke data recorded next to a take so the editor can
/// draw a sharp, restyleable cursor instead of the one baked into the pixels.
///
/// The file is append-only binary, written while recording. Every record is
/// self-delimiting, so a crash or power loss leaves at most one truncated
/// record at the end — the reader keeps everything before it, matching the
/// fragmented MP4's own recovery guarantee.
///
/// Layout (little endian):
///   "MSTL" · u32 version · u32 headerLength · header JSON
///   then records, each `u8 tag` + payload (see `Tag`).
/// Times are host-clock seconds (`CMClockGetHostTimeClock`, the clock
/// ScreenCaptureKit stamps frames with). Positions are normalized to the
/// recorded region with a top-left origin; values outside 0…1 mean the
/// pointer left the region.
nonisolated enum CursorTelemetry {
    static let magic: [UInt8] = Array("MSTL".utf8)
    static let version: UInt32 = 1
    static let filename = "cursor.mstl"

    /// Sanity bounds so a damaged header or shape record cannot request an
    /// unbounded allocation.
    static let maxHeaderBytes: UInt32 = 64 * 1024
    static let maxShapeBytes: UInt32 = 4 * 1024 * 1024
    static let maxKeyTextBytes = 64

    enum Tag: UInt8 {
        case move = 1
        case button = 2
        case shape = 3
        case shapeDefinition = 4
        case key = 5
        case start = 6
        case pause = 7
        case resume = 8
    }

    struct Header: Codable, Equatable, Sendable {
        /// Size of the recorded region in points. Cursor images are sized in
        /// points too, so this converts them to video pixels.
        var sourcePointSize: CGSize
        /// Pixel size of the recorded video.
        var pixelSize: CGSize
        var frameRate: Int
        var createdAt: Date
        /// Whether the system cursor was hidden from the video stream. When
        /// false the pixels already contain a cursor and the editor must not
        /// draw a second one by default.
        var cursorHiddenInVideo: Bool
        /// Whether click-highlight and keystroke overlays were excluded from
        /// the video and are therefore rendered by the editor.
        var overlaysInTelemetry: Bool

        init(sourcePointSize: CGSize, pixelSize: CGSize, frameRate: Int, createdAt: Date = Date(),
             cursorHiddenInVideo: Bool, overlaysInTelemetry: Bool) {
            self.sourcePointSize = sourcePointSize
            self.pixelSize = pixelSize
            self.frameRate = frameRate
            self.createdAt = createdAt
            self.cursorHiddenInVideo = cursorHiddenInVideo
            self.overlaysInTelemetry = overlaysInTelemetry
        }

        private enum CodingKeys: String, CodingKey {
            case sourcePointSize, pixelSize, frameRate, createdAt, cursorHiddenInVideo, overlaysInTelemetry
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sourcePointSize = c.decode(.sourcePointSize, or: .zero)
            pixelSize = c.decode(.pixelSize, or: .zero)
            frameRate = c.decode(.frameRate, or: 30)
            createdAt = c.decode(.createdAt, or: Date(timeIntervalSince1970: 0))
            cursorHiddenInVideo = c.decode(.cursorHiddenInVideo, or: false)
            overlaysInTelemetry = c.decode(.overlaysInTelemetry, or: false)
        }
    }

    enum Button: UInt8, Codable, Sendable { case left = 0, right = 1, other = 2 }

    /// A distinct cursor image. The PNG keeps the system cursor's largest
    /// representation so zoomed-in exports stay sharp.
    struct Shape: Equatable, Sendable {
        var id: UInt32
        /// Hotspot in points from the image's top-left corner.
        var hotspot: CGPoint
        /// Logical size in points.
        var size: CGSize
        var png: Data
    }

    enum Event: Equatable, Sendable {
        case move(time: Double, x: Float, y: Float)
        case button(time: Double, button: Button, down: Bool, x: Float, y: Float)
        case shape(time: Double, id: UInt32)
        case shapeDefinition(Shape)
        case key(time: Double, down: Bool, keyCode: UInt16, modifiers: UInt32, characters: String)
        case start(time: Double)
        case pause(time: Double)
        case resume(time: Double, pausedDuration: Double)
    }

    enum FormatError: Error, Equatable {
        case notTelemetry, unsupportedVersion, invalidHeader
    }

    // MARK: Encoding

    static func encodeHeader(_ header: Header) throws -> Data {
        let json = try JSONEncoder().encode(header)
        var data = Data(magic)
        data.appendLE(version)
        data.appendLE(UInt32(json.count))
        data.append(json)
        return data
    }

    static func encode(_ event: Event, into data: inout Data) {
        switch event {
        case let .move(time, x, y):
            data.append(Tag.move.rawValue)
            data.appendLE(time.bitPattern); data.appendLE(x.bitPattern); data.appendLE(y.bitPattern)
        case let .button(time, button, down, x, y):
            data.append(Tag.button.rawValue)
            data.appendLE(time.bitPattern); data.append(button.rawValue); data.append(down ? 1 : 0)
            data.appendLE(x.bitPattern); data.appendLE(y.bitPattern)
        case let .shape(time, id):
            data.append(Tag.shape.rawValue)
            data.appendLE(time.bitPattern); data.appendLE(id)
        case let .shapeDefinition(shape):
            guard shape.png.count <= Int(maxShapeBytes) else { return }
            data.append(Tag.shapeDefinition.rawValue)
            data.appendLE(shape.id)
            data.appendLE(Float(shape.hotspot.x).bitPattern); data.appendLE(Float(shape.hotspot.y).bitPattern)
            data.appendLE(Float(shape.size.width).bitPattern); data.appendLE(Float(shape.size.height).bitPattern)
            data.appendLE(UInt32(shape.png.count))
            data.append(shape.png)
        case let .key(time, down, keyCode, modifiers, characters):
            var text = Data(characters.utf8)
            if text.count > maxKeyTextBytes { text = Data(characters.utf8Prefix(maxBytes: maxKeyTextBytes).utf8) }
            data.append(Tag.key.rawValue)
            data.appendLE(time.bitPattern); data.append(down ? 1 : 0)
            data.appendLE(keyCode); data.appendLE(modifiers)
            data.append(UInt8(text.count)); data.append(text)
        case let .start(time):
            data.append(Tag.start.rawValue); data.appendLE(time.bitPattern)
        case let .pause(time):
            data.append(Tag.pause.rawValue); data.appendLE(time.bitPattern)
        case let .resume(time, paused):
            data.append(Tag.resume.rawValue); data.appendLE(time.bitPattern); data.appendLE(paused.bitPattern)
        }
    }

    // MARK: Decoding

    /// Parses a complete or truncated file. Throws only when the header is
    /// unusable; damaged trailing records are dropped.
    static func decode(_ data: Data) throws -> (header: Header, events: [Event]) {
        var reader = ByteReader(data: data)
        guard let magicBytes = reader.bytes(4), Array(magicBytes) == magic else { throw FormatError.notTelemetry }
        guard let fileVersion = reader.u32() else { throw FormatError.invalidHeader }
        guard fileVersion == version else { throw FormatError.unsupportedVersion }
        guard let headerLength = reader.u32(), headerLength <= maxHeaderBytes,
              let headerBytes = reader.bytes(Int(headerLength)),
              let header = try? JSONDecoder().decode(Header.self, from: headerBytes) else {
            throw FormatError.invalidHeader
        }
        var events: [Event] = []
        events.reserveCapacity(max(0, (data.count - reader.offset) / 17))
        while !reader.isAtEnd {
            let mark = reader.offset
            guard let event = readEvent(&reader) else {
                reader.offset = mark
                break
            }
            if let event { events.append(event) }
        }
        return (header, events)
    }

    /// Returns nil when the record is truncated or unrecognizable (stop
    /// reading), `.some(nil)` for a record intentionally skipped.
    private static func readEvent(_ r: inout ByteReader) -> Event?? {
        guard let rawTag = r.u8(), let tag = Tag(rawValue: rawTag) else { return nil }
        switch tag {
        case .move:
            guard let t = r.f64(), let x = r.f32(), let y = r.f32() else { return nil }
            guard t.isFinite, x.isFinite, y.isFinite else { return .some(nil) }
            return .move(time: t, x: x, y: y)
        case .button:
            guard let t = r.f64(), let b = r.u8(), let d = r.u8(), let x = r.f32(), let y = r.f32() else { return nil }
            guard t.isFinite, x.isFinite, y.isFinite else { return .some(nil) }
            return .button(time: t, button: Button(rawValue: b) ?? .other, down: d != 0, x: x, y: y)
        case .shape:
            guard let t = r.f64(), let id = r.u32() else { return nil }
            guard t.isFinite else { return .some(nil) }
            return .shape(time: t, id: id)
        case .shapeDefinition:
            guard let id = r.u32(), let hx = r.f32(), let hy = r.f32(), let w = r.f32(), let h = r.f32(),
                  let length = r.u32(), length <= maxShapeBytes, let png = r.bytes(Int(length)) else { return nil }
            guard [hx, hy, w, h].allSatisfy({ $0.isFinite }), w > 0, h > 0 else { return .some(nil) }
            return .shapeDefinition(Shape(id: id, hotspot: CGPoint(x: CGFloat(hx), y: CGFloat(hy)),
                                          size: CGSize(width: CGFloat(w), height: CGFloat(h)), png: Data(png)))
        case .key:
            guard let t = r.f64(), let d = r.u8(), let code = r.u16(), let mods = r.u32(),
                  let length = r.u8(), let text = r.bytes(Int(length)) else { return nil }
            guard t.isFinite else { return .some(nil) }
            return .key(time: t, down: d != 0, keyCode: code, modifiers: mods,
                        characters: String(decoding: text, as: UTF8.self))
        case .start:
            guard let t = r.f64() else { return nil }
            return t.isFinite ? .start(time: t) : .some(nil)
        case .pause:
            guard let t = r.f64() else { return nil }
            return t.isFinite ? .pause(time: t) : .some(nil)
        case .resume:
            guard let t = r.f64(), let paused = r.f64() else { return nil }
            return t.isFinite && paused.isFinite ? .resume(time: t, pausedDuration: max(0, paused)) : .some(nil)
        }
    }
}

// MARK: - Parsed recording on the media clock

/// Telemetry converted to media time: seconds from the first video frame,
/// with paused intervals removed exactly like `MP4WriterSession` removes them.
nonisolated struct CursorRecording: Sendable {
    struct Click: Equatable, Sendable {
        var time: Double
        var upTime: Double?
        var button: CursorTelemetry.Button
        var position: CGPoint
    }

    struct Key: Equatable, Sendable {
        var time: Double
        var keyCode: UInt16
        var modifiers: UInt32
        var characters: String
    }

    var header: CursorTelemetry.Header
    /// Sorted, strictly increasing media times with matching positions.
    var times: [Double] = []
    var xs: [Float] = []
    var ys: [Float] = []
    var clicks: [Click] = []
    /// Key-down events only; releases carry no display information.
    var keys: [Key] = []
    var shapeTimes: [Double] = []
    var shapeIDs: [UInt32] = []
    var shapes: [UInt32: CursorTelemetry.Shape] = [:]
    /// True when the file had a start anchor. Without one, times are
    /// estimated from the first sample and may be offset slightly.
    var hasStartAnchor = false

    var isEmpty: Bool { times.isEmpty }

    /// Builds the media-clock view of raw events.
    init(header: CursorTelemetry.Header, events: [CursorTelemetry.Event]) {
        self.header = header
        var start: Double?
        for case let .start(time) in events { start = time; break }
        hasStartAnchor = start != nil
        if start == nil {
            for event in events {
                switch event {
                case let .move(time, _, _), let .button(time, _, _, _, _), let .shape(time, _):
                    start = time
                default: continue
                }
                break
            }
        }
        guard let origin = start else { return }

        var pausedTotal = 0.0
        var pausedSince: Double?
        var openClicks: [CursorTelemetry.Button: Int] = [:]
        for event in events {
            switch event {
            case .start:
                continue
            case let .pause(time):
                if pausedSince == nil { pausedSince = time }
                continue
            case let .resume(_, paused):
                if pausedSince != nil { pausedTotal += paused }
                pausedSince = nil
                continue
            case let .shapeDefinition(shape):
                shapes[shape.id] = shape
                continue
            default:
                break
            }
            guard pausedSince == nil else { continue }
            func media(_ host: Double) -> Double { host - origin - pausedTotal }
            switch event {
            case let .move(time, x, y):
                let t = media(time)
                guard t >= -0.5 else { continue }
                appendMove(max(0, t), x, y)
            case let .button(time, button, down, x, y):
                let t = max(0, media(time))
                let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
                appendMove(t, x, y)
                if down {
                    clicks.append(Click(time: t, upTime: nil, button: button, position: point))
                    openClicks[button] = clicks.count - 1
                } else if let index = openClicks.removeValue(forKey: button) {
                    clicks[index].upTime = max(clicks[index].time, t)
                }
            case let .shape(time, id):
                let t = max(0, media(time))
                if let last = shapeTimes.last, t <= last {
                    shapeIDs[shapeIDs.count - 1] = id
                } else {
                    shapeTimes.append(t); shapeIDs.append(id)
                }
            case let .key(time, down, keyCode, modifiers, characters):
                guard down else { continue }
                keys.append(Key(time: max(0, media(time)), keyCode: keyCode, modifiers: modifiers, characters: characters))
            default:
                continue
            }
        }
        // Keys and clicks are queried by binary search.
        if !keys.isSorted(by: { $0.time <= $1.time }) { keys.sort { $0.time < $1.time } }
        if !clicks.isSorted(by: { $0.time <= $1.time }) { clicks.sort { $0.time < $1.time } }
    }

    init(header: CursorTelemetry.Header) { self.header = header }

    private mutating func appendMove(_ t: Double, _ x: Float, _ y: Float) {
        if let last = times.last, t <= last {
            // Coincident samples keep the latest position; never go backwards.
            xs[xs.count - 1] = x; ys[ys.count - 1] = y
            return
        }
        times.append(t); xs.append(x); ys.append(y)
    }

    /// Reads a telemetry file. Returns nil if it is missing or unusable.
    static func load(url: URL) -> CursorRecording? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let decoded = try? CursorTelemetry.decode(data) else { return nil }
        return CursorRecording(header: decoded.header, events: decoded.events)
    }

    // MARK: Queries

    /// Index of the last sample at or before `t`, or nil if `t` precedes all.
    func sampleIndex(atOrBefore t: Double) -> Int? {
        CursorRecording.index(in: times, atOrBefore: t)
    }

    static func index(in times: [Double], atOrBefore t: Double) -> Int? {
        guard let first = times.first, t >= first else { return nil }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Raw pointer position, linearly interpolated between samples.
    func rawPosition(at t: Double) -> CGPoint? {
        guard !times.isEmpty else { return nil }
        guard let i = sampleIndex(atOrBefore: t) else { return CGPoint(x: CGFloat(xs[0]), y: CGFloat(ys[0])) }
        guard i + 1 < times.count else { return CGPoint(x: CGFloat(xs[i]), y: CGFloat(ys[i])) }
        let span = times[i + 1] - times[i]
        let f = span > 0 ? Float((t - times[i]) / span) : 0
        return CGPoint(x: CGFloat(xs[i] + (xs[i + 1] - xs[i]) * f), y: CGFloat(ys[i] + (ys[i + 1] - ys[i]) * f))
    }

    func shapeID(at t: Double) -> UInt32? {
        guard let i = CursorRecording.index(in: shapeTimes, atOrBefore: t) else { return shapeIDs.first }
        return shapeIDs[i]
    }

    /// Pixels in the recorded video per cursor point.
    var pixelsPerPoint: CGFloat {
        guard header.sourcePointSize.width > 0, header.pixelSize.width > 0 else { return 2 }
        return header.pixelSize.width / header.sourcePointSize.width
    }
}

// MARK: - Byte helpers

nonisolated extension Array {
    func isSorted(by areInOrder: (Element, Element) -> Bool) -> Bool {
        zip(self, dropFirst()).allSatisfy { areInOrder($0, $1) }
    }
}

nonisolated extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

nonisolated extension String {
    /// The longest prefix whose UTF-8 encoding fits in `maxBytes`, never
    /// splitting a character.
    func utf8Prefix(maxBytes: Int) -> String {
        var used = 0
        var end = startIndex
        for index in indices {
            let size = String(self[index]).utf8.count
            guard used + size <= maxBytes else { break }
            used += size
            end = self.index(after: index)
        }
        return String(self[startIndex..<end])
    }
}

nonisolated struct ByteReader {
    let data: Data
    var offset = 0
    init(data: Data) { self.data = data }
    var isAtEnd: Bool { offset >= data.count }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        let start = data.startIndex + offset
        defer { offset += count }
        return data.subdata(in: start..<(start + count))
    }

    private mutating func integer<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { return nil }
        var value: T = 0
        let start = data.startIndex + offset
        withUnsafeMutableBytes(of: &value) { buffer in
            data.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: start..<(start + size))
        }
        offset += size
        return T(littleEndian: value)
    }

    mutating func u8() -> UInt8? { integer(UInt8.self) }
    mutating func u16() -> UInt16? { integer(UInt16.self) }
    mutating func u32() -> UInt32? { integer(UInt32.self) }
    mutating func f32() -> Float? { integer(UInt32.self).map(Float.init(bitPattern:)) }
    mutating func f64() -> Double? { integer(UInt64.self).map(Double.init(bitPattern:)) }
}
