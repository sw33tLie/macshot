import CoreGraphics

struct TableGrid {
    let horizontalSeparators: [CGFloat]
    let verticalSeparators: [CGFloat]
}

enum TableGridDetector {
    static func detect(cgImage: CGImage) -> TableGrid? {
        let width = cgImage.width
        let height = cgImage.height
        guard width >= 20, height >= 20 else { return nil }

        var grayscale = Array(repeating: UInt8.max, count: width * height)
        let rendered = grayscale.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        let horizontal = separatorPositions(
            axisLength: height,
            sampleLength: width,
            mergeDistance: max(3, min(width, height) / 250)
        ) { position, sample in
            grayscale[position * width + sample] <= 242
        }.map { 1 - (CGFloat($0) + 0.5) / CGFloat(height) }

        let vertical = separatorPositions(
            axisLength: width,
            sampleLength: height,
            mergeDistance: max(3, min(width, height) / 250)
        ) { position, sample in
            grayscale[sample * width + position] <= 242
        }.map { (CGFloat($0) + 0.5) / CGFloat(width) }

        guard horizontal.count >= 3 else { return nil }
        return TableGrid(horizontalSeparators: horizontal, verticalSeparators: vertical)
    }

    private static func separatorPositions(
        axisLength: Int,
        sampleLength: Int,
        mergeDistance: Int,
        isLinePixel: (Int, Int) -> Bool
    ) -> [Int] {
        let sampleStride = max(1, sampleLength / 1_500)
        let sampleCount = (sampleLength + sampleStride - 1) / sampleStride
        let minimumRunLength = max(1, Int(Double(sampleCount) * 0.45))
        var candidates: [Int] = []

        for position in 1..<(axisLength - 1) {
            var runLength = 0
            var pendingGap = 0
            var longestRun = 0
            var sample = 0
            while sample < sampleLength {
                if isLinePixel(position, sample) {
                    runLength += pendingGap + 1
                    pendingGap = 0
                    longestRun = max(longestRun, runLength)
                    if longestRun >= minimumRunLength {
                        candidates.append(position)
                        break
                    }
                } else if runLength > 0, pendingGap < 2 {
                    pendingGap += 1
                } else {
                    runLength = 0
                    pendingGap = 0
                }
                sample += sampleStride
            }
        }

        var groups: [[Int]] = []
        for candidate in candidates {
            if let last = groups.indices.last,
               candidate - (groups[last].last ?? candidate) <= mergeDistance {
                groups[last].append(candidate)
            } else {
                groups.append([candidate])
            }
        }
        return groups.flatMap { group -> [Int] in
            guard let first = group.first, let last = group.last else { return [] }
            if last - first > mergeDistance * 2 {
                return [first, last]
            }
            return [group.reduce(0, +) / group.count]
        }
    }
}
