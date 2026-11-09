import CoreGraphics
import Foundation

/// Pixel comparisons used by scroll capture to work out what is scrolling and
/// what isn't: the scrollbar strip down the right edge, and any frozen header
/// pinned to the top of the window.
///
/// Kept free of capture state so it can be reasoned about — and tested — on
/// plain images. `ScrollCaptureController` owns the decisions; this owns the
/// arithmetic.
///
/// Row addressing goes through each image's own `bytesPerRow`. Deriving the
/// stride as `width * 4` is wrong whenever the window server pads rows for
/// alignment, and the error compounds row by row, so every sample after the
/// first row lands in the wrong place.
enum ScrollFrameAnalyzer {

    /// SAD (sum of absolute differences) above which two samples count as
    /// different content rather than compression or antialiasing noise.
    static let differenceThreshold: UInt64 = 8

    /// Registration needs some overlap with the previous frame. Reject invalid
    /// or out-of-frame shifts before callers round them into pixel integers.
    static func validatedVerticalShift(_ shift: CGFloat, frameHeight: Int) -> CGFloat? {
        guard frameHeight > 0, shift.isFinite, abs(shift) < CGFloat(frameHeight) else { return nil }
        return shift
    }

    /// A frame ready for comparison: raw bytes plus the geometry needed to
    /// address them. `data` keeps the pixel buffer alive for the scan.
    struct Frame {
        let data: CFData
        let bytes: UnsafePointer<UInt8>
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let redOffset: Int
        let greenOffset: Int
        let blueOffset: Int

        /// Byte offset of a pixel, or nil when it falls outside the buffer.
        func offset(x: Int, y: Int) -> Int? {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            let offset = y * bytesPerRow + x * 4
            guard offset + 3 < CFDataGetLength(data) else { return nil }
            return offset
        }
    }

    /// Wraps a `CGImage` for scanning. Returns nil for anything that isn't
    /// 8-bit, 32-bits-per-pixel — the byte offsets below only make sense there.
    static func frame(for image: CGImage) -> Frame? {
        let (minimumStride, strideOverflow) = image.width.multipliedReportingOverflow(by: 4)
        let (minimumBytes, sizeOverflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32,
              image.colorSpace?.model == .rgb, !image.bitmapInfo.contains(.floatComponents),
              image.width > 0, image.height > 0,
              !strideOverflow, !sizeOverflow, image.bytesPerRow >= minimumStride,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        // A buffer shorter than the geometry claims would read past the end.
        guard CFDataGetLength(data) >= minimumBytes else { return nil }
        let first: Bool
        switch image.alphaInfo {
        case .first, .premultipliedFirst, .noneSkipFirst: first = true
        case .last, .premultipliedLast, .noneSkipLast: first = false
        default: return nil
        }
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        guard order == .byteOrderDefault || order == .byteOrder32Big || order == .byteOrder32Little else { return nil }
        // AlphaFirst describes significance, not the first byte in memory.
        // Match R/G/B by channel even when the two frames use different layouts.
        let little = order == .byteOrder32Little
        let rgb = first ? (little ? (2, 1, 0) : (1, 2, 3)) : (little ? (3, 2, 1) : (0, 1, 2))
        return Frame(data: data, bytes: bytes, width: image.width,
                     height: image.height, bytesPerRow: image.bytesPerRow,
                     redOffset: rgb.0, greenOffset: rgb.1, blueOffset: rgb.2)
    }

    /// Absolute difference of the three colour channels at one pixel.
    private static func pixelDifference(_ a: Frame, _ b: Frame, x: Int, y: Int) -> UInt64? {
        guard let aOffset = a.offset(x: x, y: y), let bOffset = b.offset(x: x, y: y) else { return nil }
        let diff = abs(Int(a.bytes[aOffset + a.redOffset]) - Int(b.bytes[bOffset + b.redOffset]))
            + abs(Int(a.bytes[aOffset + a.greenOffset]) - Int(b.bytes[bOffset + b.greenOffset]))
            + abs(Int(a.bytes[aOffset + a.blueOffset]) - Int(b.bytes[bOffset + b.blueOffset]))
        return UInt64(diff)
    }

    /// Width in pixels of the changing strip at the right edge — the scrollbar,
    /// which must be excluded from matching or it drags the alignment with it.
    ///
    /// Returns 0 when the right edge is static, or nil when the two frames
    /// can't be compared at all (different sizes, unsupported pixel format).
    static func scrollbarWidth(current: CGImage, previous: CGImage) -> Int? {
        guard current.width == previous.width, current.height == previous.height,
              let a = frame(for: current), let b = frame(for: previous) else { return nil }

        let rowStart = a.height * 2 / 10
        let rowEnd = a.height * 8 / 10
        guard rowEnd > rowStart else { return 0 }
        let rowStep = max(1, (rowEnd - rowStart) / 40)

        var width = 0
        let maxScanCols = min(50, a.width / 8)
        for columnOffset in 0..<max(0, maxScanCols) {
            let column = a.width - 1 - columnOffset
            var sad: UInt64 = 0
            var samples = 0
            for row in stride(from: rowStart, to: rowEnd, by: rowStep) {
                guard let difference = pixelDifference(a, b, x: column, y: row) else { continue }
                sad += difference
                samples += 1
            }
            guard samples > 0 else { continue }

            if sad / UInt64(samples) > differenceThreshold {
                width = columnOffset + 1
            } else if width > 0 {
                break  // found the inner edge of the changing strip
            }
        }
        return width
    }

    /// How many rows at the top of the frame are unchanged — a pinned header
    /// that must not be stitched in again with every strip.
    ///
    /// Returns the row index of the first changed row; `height` when the whole
    /// frame is unchanged, and nil when the frames can't be compared.
    static func frozenTopRows(current: CGImage, previous: CGImage, rightMarginPx: Int) -> Int? {
        guard current.width == previous.width, current.height == previous.height,
              let a = frame(for: current), let b = frame(for: previous) else { return nil }

        let lastColumn = max(1, a.width - max(0, rightMarginPx))
        let columnStep = 4

        for row in 0..<a.height {
            var sad: UInt64 = 0
            var samples = 0
            for column in stride(from: 0, to: lastColumn, by: columnStep) {
                guard let difference = pixelDifference(a, b, x: column, y: row) else { continue }
                sad += difference
                samples += 1
            }
            // A row we couldn't sample counts as changed, so detection stops
            // rather than silently treating the whole frame as frozen.
            let average = samples > 0 ? sad / UInt64(samples) : UInt64.max
            if average > differenceThreshold { return row }
        }
        return a.height
    }
}
