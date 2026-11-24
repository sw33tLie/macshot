import CoreGraphics
import Foundation

/// Which way the content of a scroll capture moves.
enum ScrollAxis: Equatable {
    /// The page scrolls down; the image grows taller.
    case vertical
    /// The page scrolls right; the image grows wider.
    case horizontal
}

/// Stitches a scroll capture along whichever axis the content actually scrolls.
///
/// `ScrollFrameMatcher` and `ScrollStitcher` reason in rows: content moving
/// up, navbars at the top, sidebars beside the content, banners pinned at the
/// bottom. Measured that way a sideways scroll is "no movement", so a
/// horizontal capture never grew past its first frame. A horizontal scroll is
/// the same problem with x and y swapped, so this feeds transposed frames to a
/// second `ScrollStitcher` and transposes its result back. Its sticky-content
/// handling carries over: a frozen first column stays once at the left (like a
/// header), toolbars above or below the scrolling area are treated like
/// sidebars, and a panel pinned at the right edge appears once at the end.
///
/// Until the axis is known each frame goes to both stitchers. Measured on the
/// wrong axis a scroll explains nothing better than "no shift", so the first
/// stitcher to append decides and the other one is dropped. If both append on
/// the same frame, the caller's preferred axis (from the scroll events) wins,
/// otherwise vertical, the common case.
///
/// Free of capture and timing so it can be driven by synthetic frames in tests.
final class ScrollCaptureStitcher {

    /// The axis the capture grows along; nil until the first strip is appended.
    private(set) var axis: ScrollAxis?

    /// Stitches frames as captured. Dropped once the capture is horizontal.
    private var vertical: ScrollStitcher?
    /// Stitches transposed frames. Dropped once the capture is vertical, and
    /// absent when the first frame couldn't be transposed.
    private var horizontal: ScrollStitcher?

    /// The first frame as captured, shown until a strip is appended.
    private let firstFrame: CGImage
    /// The last horizontal image transposed back, keyed by the transposed
    /// image it came from, so repeated reads between appends cost nothing.
    private var orientedCache: (source: CGImage, result: CGImage)?

    /// Creates a stitcher that starts from `firstFrame` with no axis decided.
    /// - Parameters:
    ///   - firstFrame: the settled frame captured when the session began, in
    ///     screen orientation (top-left origin).
    ///   - handlesPinnedContent: passed to both inner stitchers; false stitches
    ///     every frame as captured, without sidebar filling or held-back banners.
    init(firstFrame: CGImage, handlesPinnedContent: Bool = true) {
        self.firstFrame = firstFrame
        vertical = ScrollStitcher(firstFrame: firstFrame, handlesPinnedContent: handlesPinnedContent)
        horizontal = Self.transposed(firstFrame).map {
            ScrollStitcher(firstFrame: $0, handlesPinnedContent: handlesPinnedContent)
        }
    }

    /// The stitched image so far, in screen orientation. For a horizontal
    /// capture this transposes the inner image back, once per change.
    var image: CGImage {
        switch axis {
        case .horizontal:
            guard let inner = horizontal?.image else { return firstFrame }
            return transposedBack(inner) ?? firstFrame
        case .vertical, nil:
            return vertical?.image ?? firstFrame
        }
    }

    /// Length of the stitched image along the scroll axis, in pixels: its
    /// height for a vertical capture, its width for a horizontal one. Used for
    /// the maximum-length limit without transposing anything.
    var length: Int {
        switch axis {
        case .horizontal: return horizontal?.image.height ?? firstFrame.width
        case .vertical, nil: return vertical?.image.height ?? firstFrame.height
        }
    }

    /// Aligns `frame` with the previous one and appends what it reveals.
    ///
    /// Before the axis is decided the frame is matched on both axes; the first
    /// append locks the axis and releases the other stitcher's images.
    /// - Parameters:
    ///   - frame: the newly captured frame, same size as the first frame, in
    ///     screen orientation (top-left origin).
    ///   - pointer: where the mouse pointer is in `frame` (pixels, top-left
    ///     origin), if the frames include it; transposed for the horizontal side.
    ///   - preferredAxis: the axis the scroll events point to, if known. Only
    ///     breaks a tie when both axes append on the same frame.
    /// - Returns: what happened on the decided axis, or before the decision the
    ///   most informative of the two outcomes (pending, then no movement).
    @discardableResult
    func add(_ frame: CGImage, pointer: CGRect? = nil, preferredAxis: ScrollAxis? = nil) -> ScrollStitcher.Outcome {
        switch axis {
        case .vertical:
            return vertical?.add(frame, pointer: pointer) ?? .noMatch
        case .horizontal:
            return addHorizontally(frame, pointer: pointer) ?? .noMatch
        case nil:
            let down = vertical?.add(frame, pointer: pointer) ?? .noMatch
            let across = addHorizontally(frame, pointer: pointer) ?? .noMatch
            switch (down == .appended, across == .appended) {
            case (true, true):
                lock(preferredAxis ?? .vertical)
                return .appended
            case (true, false):
                lock(.vertical)
                return .appended
            case (false, true):
                lock(.horizontal)
                return .appended
            case (false, false):
                if down == .pending || across == .pending { return .pending }
                if down == .noMovement || across == .noMovement { return .noMovement }
                return .noMatch
            }
        }
    }

    /// The finished image in screen orientation, with any held-back banner
    /// added once. A capture that never moved returns the first frame.
    /// - Returns: the final stitched image; for a horizontal capture, the inner
    ///   result transposed back (the last preview if that allocation fails).
    func finish() -> CGImage {
        switch axis {
        case .horizontal:
            guard let inner = horizontal?.finish() else { return firstFrame }
            return transposedBack(inner) ?? orientedCache?.result ?? firstFrame
        case .vertical, nil:
            return vertical?.finish() ?? firstFrame
        }
    }

    // MARK: - Private

    /// Feeds the transposed `frame` (and pointer) to the horizontal stitcher.
    /// - Returns: its outcome, or nil when there is no horizontal stitcher or
    ///   the frame couldn't be transposed (the caller treats that as no match).
    private func addHorizontally(_ frame: CGImage, pointer: CGRect?) -> ScrollStitcher.Outcome? {
        guard let horizontal, let flipped = Self.transposed(frame) else { return nil }
        return horizontal.add(flipped, pointer: pointer.map(Self.transposed))
    }

    /// Decides the axis and drops the other stitcher, freeing its images.
    /// - Parameter decided: the axis whose stitcher appended first.
    private func lock(_ decided: ScrollAxis) {
        axis = decided
        switch decided {
        case .vertical: horizontal = nil
        case .horizontal: vertical = nil
        }
    }

    /// `inner` transposed back to screen orientation, reusing the last result
    /// when `inner` hasn't changed since.
    /// - Parameter inner: the horizontal stitcher's (transposed) image.
    /// - Returns: the image in screen orientation, or nil if it can't be drawn.
    private func transposedBack(_ inner: CGImage) -> CGImage? {
        if let cached = orientedCache, cached.source === inner { return cached.result }
        guard let result = Self.transposed(inner) else { return nil }
        orientedCache = (inner, result)
        return result
    }

    // MARK: - Transposition

    /// `image` mirrored across its main diagonal: the pixel at column x, row y
    /// (top-left origin) moves to column y, row x, so the result is
    /// `image.height` wide and `image.width` tall. Content scrolling left then
    /// moves up, and new columns at the right edge become rows at the bottom.
    /// Transposing twice gives back the original pixels exactly.
    /// Pure pixel work with no actor state, so it is `nonisolated`: callable
    /// from any context, including as a function value.
    /// - Parameter image: any 8-bit RGB image; drawn without interpolation.
    /// - Returns: the transposed image in the stitcher's BGRA layout, keeping
    ///   the source colour space when possible; nil if no context can be made.
    nonisolated static func transposed(_ image: CGImage) -> CGImage? {
        let width = image.height, height = image.width
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        func context(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: space, bitmapInfo: bitmapInfo)
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = image.colorSpace.flatMap(context) ?? context(srgb) else { return nil }
        context.interpolationQuality = .none
        // In CG's bottom-left space, source point (u, v) goes to
        // (sourceHeight - v, sourceWidth - u): the top-left-origin transpose.
        context.concatenate(CGAffineTransform(a: 0, b: -1, c: -1, d: 0,
                                              tx: CGFloat(image.height), ty: CGFloat(image.width)))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// `rect` (top-left origin) with x and y swapped, matching `transposed(_:)`.
    /// `nonisolated` so it can be passed to `Optional.map` as a function value.
    /// - Parameter rect: a rectangle in a frame's pixel coordinates.
    /// - Returns: the same area in the transposed frame's coordinates.
    nonisolated static func transposed(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
    }
}
