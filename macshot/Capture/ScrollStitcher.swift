import CoreGraphics
import Foundation

/// Builds the tall image of a scroll capture from successive frames.
///
/// Each frame is aligned with the last one stitched from (`ScrollFrameMatcher`)
/// and only the rows it shows for the first time are appended, taken from just
/// above anything pinned at the bottom. What doesn't scroll appears once:
/// a header in the first frame at the top, fixed sidebars in the first frame
/// only (filled with their background below it), and a pinned bottom banner
/// at the very end. Scrolling back up is tracked, so those rows aren't added
/// twice when the page comes down again.
///
/// Free of capture and timing so it can be driven by synthetic frames in tests.
final class ScrollStitcher {

    enum Outcome: Equatable {
        /// New rows were added to the image.
        case appended
        /// The frame shows exactly what the reference showed.
        case noMovement
        /// Moved, but nothing new to add yet (too small, or scrolled back up).
        case pending
        /// The frame couldn't be aligned with the reference.
        case noMatch
    }

    /// The stitched image so far, without the held-back bottom banner.
    private(set) var image: CGImage
    /// Strips appended after the first frame.
    private(set) var appendedStrips = 0

    /// When false ("Detect sticky headers" off), every frame is stitched as
    /// captured: no sidebar filling and no held-back banner.
    private let handlesPinnedContent: Bool

    private var reference: CGImage
    private var referenceSamples: ScrollFrameMatcher.Samples?

    // Fixed by the first downward match, so every strip lines up.
    private var geometryDecided = false
    private var fixedSides: [(columns: Range<Int>, color: CGColor)] = []
    private var bottomRows = 0
    private var finished = false

    /// Rows scrolled back up that must come down again before anything new.
    private var rowsToRevisit = 0
    private var lastShift = 0
    private var consecutiveFailures = 0
    /// A reference that can't be matched for this many frames was outrun;
    /// start again from the current frame (leaving a gap).
    static let reanchorAfterFailures = 8

    init(firstFrame: CGImage, handlesPinnedContent: Bool = true) {
        image = firstFrame
        reference = firstFrame
        referenceSamples = ScrollFrameMatcher.samples(of: firstFrame)
        self.handlesPinnedContent = handlesPinnedContent
    }

    /// Aligns `frame` with the reference and appends the rows it reveals.
    @discardableResult
    func add(_ frame: CGImage) -> Outcome {
        guard !finished else { return .pending }
        guard let referenceSamples, frame.width == reference.width, frame.height == reference.height,
              let samples = ScrollFrameMatcher.samples(of: frame) else {
            reference = frame
            self.referenceSamples = ScrollFrameMatcher.samples(of: frame)
            return .noMatch
        }
        guard let match = ScrollFrameMatcher.match(previous: referenceSamples, current: samples, hint: lastShift) else {
            // Keep the reference: a transient mismatch (an animation, a blank
            // stretch) usually resolves on a later frame.
            consecutiveFailures += 1
            if consecutiveFailures >= Self.reanchorAfterFailures {
                consecutiveFailures = 0
                reference = frame
                self.referenceSamples = samples
            }
            return .noMatch
        }
        consecutiveFailures = 0
        if match.shift == 0 { return .noMovement }
        // Let small moves accumulate against the same reference: fewer seams,
        // and one exact large shift beats many small ones.
        guard abs(match.shift) >= max(6, frame.height / 24) else { return .pending }

        lastShift = match.shift
        reference = frame
        self.referenceSamples = samples
        if match.shift < 0 {
            rowsToRevisit += -match.shift
            return .pending
        }
        if !geometryDecided { decideGeometry(match) }
        let revisited = min(rowsToRevisit, match.shift)
        rowsToRevisit -= revisited
        let newRows = min(match.shift - revisited, frame.height - bottomRows)
        guard newRows > 0,
              let strip = frame.cropping(to: CGRect(x: 0, y: frame.height - bottomRows - newRows,
                                                    width: frame.width, height: newRows)) else { return .pending }
        append(strip, coveringSides: true)
        appendedStrips += 1
        return .appended
    }

    /// The finished image: adds the held-back bottom banner, once.
    func finish() -> CGImage {
        if !finished, geometryDecided, bottomRows > 0,
           let strip = reference.cropping(to: CGRect(x: 0, y: reference.height - bottomRows,
                                                     width: reference.width, height: bottomRows)) {
            append(strip, coveringSides: false)
        }
        finished = true
        return image
    }

    private func decideGeometry(_ match: ScrollFrameMatcher.Match) {
        geometryDecided = true
        guard handlesPinnedContent else { return }
        let first = image
        bottomRows = match.staticBottomRows
        fixedSides = match.fixedSides.compactMap { columns in
            Self.backgroundColor(of: first, columns: columns).map { (columns, $0) }
        }
        // The first frame's own banner is replaced by the final frame's at the end.
        if bottomRows > 0,
           let trimmed = first.cropping(to: CGRect(x: 0, y: 0, width: first.width, height: first.height - bottomRows)) {
            image = trimmed
        }
    }

    /// The most common colour in `columns` of `image`: a sidebar's background.
    /// Colours are bucketed to find the mode, then averaged within it so a
    /// plain white or black background is reproduced exactly.
    static func backgroundColor(of image: CGImage, columns: Range<Int>) -> CGColor? {
        guard let frame = ScrollFrameAnalyzer.frame(for: image), !columns.isEmpty else { return nil }
        var buckets: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        let columnStep = max(1, columns.count / 24), rowStep = max(1, image.height / 64)
        for y in stride(from: 0, to: image.height, by: rowStep) {
            for x in stride(from: columns.lowerBound, to: min(columns.upperBound, image.width), by: columnStep) {
                guard let offset = frame.offset(x: x, y: y) else { continue }
                let red = Int(frame.bytes[offset + frame.redOffset])
                let green = Int(frame.bytes[offset + frame.greenOffset])
                let blue = Int(frame.bytes[offset + frame.blueOffset])
                let key = ((red >> 3) << 10) | ((green >> 3) << 5) | (blue >> 3)
                let sum = buckets[key] ?? (0, 0, 0, 0)
                buckets[key] = (sum.count + 1, sum.red + red, sum.green + green, sum.blue + blue)
            }
        }
        guard let mode = buckets.values.max(by: { $0.count < $1.count }) else { return nil }
        func channel(_ total: Int) -> CGFloat { CGFloat((Double(total) / Double(mode.count)).rounded()) / 255 }
        return CGColor(srgbRed: channel(mode.red), green: channel(mode.green), blue: channel(mode.blue), alpha: 1)
    }

    private func append(_ strip: CGImage, coveringSides: Bool) {
        let existing = image
        guard existing.width == strip.width else { return }
        let width = existing.width
        let totalHeight = existing.height + strip.height
        let colorSpace = existing.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: totalHeight, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo) else { return }
        // CGContext has a bottom-left origin: the existing image goes on top.
        context.draw(existing, in: CGRect(x: 0, y: strip.height, width: width, height: existing.height))
        context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: strip.height))
        if coveringSides {
            for side in fixedSides {
                context.setFillColor(side.color)
                context.fill(CGRect(x: side.columns.lowerBound, y: 0, width: side.columns.count, height: strip.height))
            }
        }
        if let merged = context.makeImage() { image = merged }
    }
}
