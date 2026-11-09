import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreVideo
import CoreMedia
import Darwin

/// Writes an animation incrementally. ImageIO only sees one image at a time;
/// the animation, its decoded frames and scratch PNGs are never accumulated.
/// Unchanged pixels extend the pending frame's hold instead of being quantized
/// again. Calls are serialized by a lock; the exporter uses one worker queue.
final class GIFEncoder: @unchecked Sendable {
    enum EncodingError: LocalizedError {
        case invalidFrame, invalidTime, noFrames, closed, encodingFailed
        nonisolated var errorDescription: String? {
            switch self {
            case .invalidFrame: return "The recording contains an unsupported GIF frame."
            case .invalidTime: return "The recording contains invalid GIF frame timing."
            case .noFrames: return "No frames were read from the recording."
            case .closed: return "The GIF encoder is no longer accepting frames."
            case .encodingFailed: return "A GIF frame could not be encoded."
            }
        }
    }

    private let url: URL
    private let lock = NSLock()
    private let writeData: @Sendable (FileHandle, Data) throws -> Void
    nonisolated(unsafe) private var file: FileHandle?
    nonisolated(unsafe) private var ownsFile = false
    nonisolated(unsafe) private var complete = false
    nonisolated(unsafe) private var pending: GIFFramePacket?
    nonisolated(unsafe) private var previousPixels: GIFPixels?
    nonisolated(unsafe) private var pendingTick: Int64 = 0
    nonisolated(unsafe) private var lastTick: Int64 = -1
    nonisolated(unsafe) private var lastPresentationTime = CMTime.invalid

    nonisolated init(url: URL, writeData: @escaping @Sendable (FileHandle, Data) throws -> Void = {
        try $0.write(contentsOf: $1)
    }) throws {
        self.url = url
        self.writeData = writeData
        guard url.isFileURL else { throw CocoaError(.fileWriteInvalidFileName) }
        let descriptor = try url.withUnsafeFileSystemRepresentation {
            guard let path = $0 else { throw CocoaError(.fileWriteInvalidFileName) }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        ownsFile = true
        file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit {
        try? file?.close()
        if ownsFile && !complete { try? FileManager.default.removeItem(at: url) }
    }

    /// Presentation time is relative to the exported timeline. The first frame
    /// must start at zero; subsequent frames must advance on GIF's 100 Hz clock.
    nonisolated func addFrame(_ buffer: CVPixelBuffer, at presentationTime: CMTime) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard let file, !complete else { throw EncodingError.closed }
            let tick = try Self.tick(presentationTime)
            guard tick > lastTick, lastTick >= 0 || tick == 0 else { throw EncodingError.invalidTime }
            let pixels = try GIFPixels(buffer)
            if let previousPixels {
                guard previousPixels.width == pixels.width, previousPixels.height == pixels.height else {
                    throw EncodingError.invalidFrame
                }
                if pixels.bytes == previousPixels.bytes {
                    lastTick = tick
                    lastPresentationTime = presentationTime
                    return
                }
            }
            let changed = previousPixels.map { pixels.changedRegion(since: $0) }
                ?? (pixels: pixels, x: 0, y: 0)
            let packet = try GIFFramePacket.encode(changed.pixels, x: changed.x, y: changed.y)
            if let pending {
                try write(pending, ticks: tick - pendingTick, to: file)
            } else {
                var header = Data("GIF89a".utf8)
                header.append(contentsOf: Self.littleEndian(pixels.width) + Self.littleEndian(pixels.height))
                // No global palette; each frame carries the palette generated
                // for its own pixels. Full opaque frames use disposal method 1.
                header.append(contentsOf: [0x70, 0, 0])
                header.append(contentsOf: [0x21, 0xff, 11])
                header.append(Data("NETSCAPE2.0".utf8))
                header.append(contentsOf: [3, 1, 0, 0, 0]) // Infinite loop.
                try writeData(file, header)
            }
            pending = packet
            previousPixels = pixels
            pendingTick = tick
            lastTick = tick
            lastPresentationTime = presentationTime
        } catch {
            abortLocked()
            throw error
        }
    }

    /// End time supplies the final frame's actual hold, including a static tail.
    /// GIF delays have a 16-bit limit; longer holds are split without re-encoding.
    nonisolated func finish(at endTime: CMTime) throws {
        lock.lock()
        defer { lock.unlock() }
        if complete { return }
        do {
            guard let file else { throw EncodingError.closed }
            guard let pending else { throw EncodingError.noFrames }
            let rounded = try Self.tick(endTime)
            guard CMTimeCompare(endTime, lastPresentationTime) > 0 else { throw EncodingError.invalidTime }
            let tick = max(rounded, lastTick + 1)
            try write(pending, ticks: tick - pendingTick, to: file)
            try writeData(file, Data([0x3b]))
            try file.synchronize()
            try file.close()
            self.file = nil
            self.pending = nil
            previousPixels = nil
            complete = true
        } catch {
            abortLocked()
            throw error
        }
    }

    nonisolated private static func tick(_ time: CMTime) throws -> Int64 {
        guard time.isNumeric, time.seconds.isFinite, time.seconds >= 0,
              time.seconds < 9_000_000_000 else { throw EncodingError.invalidTime }
        let rounded = CMTimeConvertScale(time, timescale: 100, method: .roundHalfAwayFromZero)
        guard rounded.isNumeric else { throw EncodingError.invalidTime }
        return rounded.value
    }

    nonisolated private func write(_ packet: GIFFramePacket, ticks: Int64, to file: FileHandle) throws {
        guard ticks > 0 else { throw EncodingError.invalidTime }
        var remaining = ticks
        while remaining > 0 {
            let delay = Int(min(remaining, Int64(UInt16.max)))
            var control = Data([0x21, 0xf9, 4, 4])
            control.append(contentsOf: Self.littleEndian(delay) + [0, 0])
            try writeData(file, control)
            try writeData(file, packet.imageBlock)
            remaining -= Int64(delay)
        }
    }

    nonisolated private func abortLocked() {
        // A call after successful finish must not delete the completed file.
        guard ownsFile && !complete else { return }
        try? file?.close()
        file = nil
        pending = nil
        previousPixels = nil
        try? FileManager.default.removeItem(at: url)
        ownsFile = false
    }

    nonisolated fileprivate static func littleEndian(_ value: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
}

/// One owned opaque BGRA frame, with no row padding. Comparing owned bytes lets
/// static recordings avoid repeated quantization while the reader reuses buffers.
private struct GIFPixels: Sendable {
    let width: Int
    let height: Int
    let bytes: Data

    nonisolated private init(width: Int, height: Int, bytes: Data) {
        self.width = width; self.height = height; self.bytes = bytes
    }

    nonisolated init(_ buffer: CVPixelBuffer) throws {
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              (1...65_535).contains(width), (1...65_535).contains(height),
              width * height <= 64 * 1024 * 1024,
              CVPixelBufferGetBytesPerRow(buffer) >= width * 4,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw GIFEncoder.EncodingError.invalidFrame
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw GIFEncoder.EncodingError.invalidFrame }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let rowBytes = width * 4, rows = height
        var owned = Data(count: rowBytes * rows)
        owned.withUnsafeMutableBytes { destination in
            for row in 0..<rows {
                memcpy(destination.baseAddress! + row * rowBytes, base + row * stride, rowBytes)
            }
        }
        bytes = owned
    }

    /// Desktop recordings often change only a cursor or a few lines of text.
    /// Encode their changed rectangle; disposal method 1 retains the remainder
    /// of the previously displayed frame. First frames always cover the canvas.
    nonisolated func changedRegion(since previous: GIFPixels) -> (pixels: GIFPixels, x: Int, y: Int) {
        bytes.withUnsafeBytes { current in
            previous.bytes.withUnsafeBytes { old in
                let rowBytes = width * 4
                let a = current.baseAddress!, b = old.baseAddress!
                var top = 0, bottom = height - 1
                while top < bottom && memcmp(a + top * rowBytes, b + top * rowBytes, rowBytes) == 0 { top += 1 }
                while bottom > top && memcmp(a + bottom * rowBytes, b + bottom * rowBytes, rowBytes) == 0 { bottom -= 1 }
                var left = width - 1, right = 0
                for row in top...bottom {
                    let offset = row * rowBytes
                    var x = 0
                    while x < left && memcmp(a + offset + x * 4, b + offset + x * 4, 4) == 0 { x += 1 }
                    left = min(left, x)
                    x = width - 1
                    while x > right && memcmp(a + offset + x * 4, b + offset + x * 4, 4) == 0 { x -= 1 }
                    right = max(right, x)
                }
                let croppedWidth = right - left + 1, croppedHeight = bottom - top + 1
                if croppedWidth == width && croppedHeight == height { return (self, 0, 0) }
                var cropped = Data(count: croppedWidth * croppedHeight * 4)
                cropped.withUnsafeMutableBytes { destination in
                    for row in 0..<croppedHeight {
                        memcpy(destination.baseAddress! + row * croppedWidth * 4,
                               a + (top + row) * rowBytes + left * 4, croppedWidth * 4)
                    }
                }
                return (GIFPixels(width: croppedWidth, height: croppedHeight, bytes: cropped), left, top)
            }
        }
    }

    nonisolated func image() throws -> CGImage {
        guard let provider = CGDataProvider(data: bytes as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw GIFEncoder.EncodingError.invalidFrame
        }
        return image
    }
}

/// Imports one ImageIO-produced image block, preserving its LZW data and
/// interlace flag and converting a global palette to a per-frame local table.
/// Only our own single-frame ImageIO output is accepted, not arbitrary input GIFs.
private struct GIFFramePacket: Sendable {
    let imageBlock: Data

    nonisolated static func encode(_ pixels: GIFPixels, x: Int, y: Int) throws -> GIFFramePacket {
        try autoreleasepool {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 1, nil) else {
                throw GIFEncoder.EncodingError.encodingFailed
            }
            CGImageDestinationAddImage(destination, try pixels.image(), nil)
            guard CGImageDestinationFinalize(destination) else { throw GIFEncoder.EncodingError.encodingFailed }
            return try parse(data as Data, width: pixels.width, height: pixels.height, x: x, y: y)
        }
    }

    nonisolated private static func parse(_ data: Data, width: Int, height: Int, x: Int, y: Int) throws -> GIFFramePacket {
        var cursor = 0
        func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= data.count - cursor else { throw GIFEncoder.EncodingError.encodingFailed }
            defer { cursor += count }
            return data.subdata(in: cursor..<(cursor + count))
        }
        func byte() throws -> UInt8 {
            guard cursor < data.count else { throw GIFEncoder.EncodingError.encodingFailed }
            defer { cursor += 1 }
            return data[cursor]
        }
        func blocks() throws {
            while true {
                let count = Int(try byte())
                if count == 0 { return }
                guard count <= data.count - cursor else { throw GIFEncoder.EncodingError.encodingFailed }
                cursor += count
            }
        }
        let header = try take(13)
        guard [Data("GIF87a".utf8), Data("GIF89a".utf8)].contains(header.prefix(6)),
              Array(header[6..<10]) == GIFEncoder.littleEndian(width) + GIFEncoder.littleEndian(height) else {
            throw GIFEncoder.EncodingError.encodingFailed
        }
        let globalSize = header[10] & 7
        let globalPalette = header[10] & 0x80 != 0 ? try take(3 << (Int(globalSize) + 1)) : Data()
        var image: Data?
        while cursor < data.count {
            switch try byte() {
            case 0x21:
                let label = try byte()
                if label == 0xf9 {
                    let control = try take(6)
                    guard control[0] == 4, control[1] & 1 == 0, control[5] == 0 else {
                        throw GIFEncoder.EncodingError.encodingFailed
                    }
                } else {
                    try blocks()
                }
            case 0x2c:
                guard image == nil else { throw GIFEncoder.EncodingError.encodingFailed }
                var descriptor = try take(9)
                guard descriptor.prefix(4).allSatisfy({ $0 == 0 }),
                      Array(descriptor[4..<8]) == GIFEncoder.littleEndian(width) + GIFEncoder.littleEndian(height) else {
                    throw GIFEncoder.EncodingError.encodingFailed
                }
                let local = descriptor[8] & 0x80 != 0
                let size = local ? descriptor[8] & 7 : globalSize
                let palette = local ? try take(3 << (Int(size) + 1)) : globalPalette
                guard !palette.isEmpty else { throw GIFEncoder.EncodingError.encodingFailed }
                descriptor.replaceSubrange(0..<4, with: GIFEncoder.littleEndian(x) + GIFEncoder.littleEndian(y))
                descriptor[8] = (descriptor[8] & 0x40) | 0x80 | size
                let start = cursor
                let codeSize = try byte()
                guard (2...8).contains(codeSize) else { throw GIFEncoder.EncodingError.encodingFailed }
                try blocks()
                var block = Data([0x2c])
                block.append(descriptor)
                block.append(palette)
                block.append(data.subdata(in: start..<cursor))
                image = block
            case 0x3b:
                guard let image, cursor == data.count else { throw GIFEncoder.EncodingError.encodingFailed }
                return GIFFramePacket(imageBlock: image)
            default:
                throw GIFEncoder.EncodingError.encodingFailed
            }
        }
        throw GIFEncoder.EncodingError.encodingFailed
    }
}
