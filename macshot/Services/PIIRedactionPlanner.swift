import Foundation
import CoreGraphics

/// The decisions made after OCR, separated from Vision and annotation drawing.
/// Bounds use image points, so proximity is relative to text height rather than
/// a fixed fraction of the screenshot (which changes with the crop's shape).
enum PIIRedactionPlanner {
    struct Line {
        let text: String
        let bounds: CGRect
    }

    struct Match {
        let lineIndex: Int
        let type: String
        let range: Range<String.Index>
    }

    static func matches(in lines: [Line], enabledTypes: [String]?) -> [Match] {
        func enabled(_ type: String) -> Bool { enabledTypes?.contains(type) ?? true }
        let valid = lines.indices.filter { validBounds(lines[$0].bounds) }
        var matches: [Match] = []
        var cardBounds: [CGRect] = []
        var cardLines = Set<Int>()

        func append(_ match: Match) {
            // Several card patterns can identify the same range. Keep the
            // widest covering range instead of stacking redaction effects.
            if matches.contains(where: {
                $0.lineIndex == match.lineIndex && $0.type == match.type &&
                    $0.range.lowerBound <= match.range.lowerBound && $0.range.upperBound >= match.range.upperBound
            }) { return }
            matches.removeAll {
                $0.lineIndex == match.lineIndex && $0.type == match.type &&
                    match.range.lowerBound <= $0.range.lowerBound && match.range.upperBound >= $0.range.upperBound
            }
            matches.append(match)
        }

        for i in valid {
            for match in AutoRedactor.sensitiveMatches(in: lines[i].text, enabledTypes: enabledTypes) {
                append(Match(lineIndex: i, type: match.name, range: match.range))
            }
            // Card context can identify a CVV even when only CVV is selected;
            // it must not also select the card number itself in that case.
            if enabled("cvv"), AutoRedactor.containsSensitiveText(lines[i].text, enabledTypes: ["credit_card"]) {
                cardBounds.append(lines[i].bounds)
                cardLines.insert(i)
            }
        }

        if enabled("credit_card") || enabled("cvv") {
            // Vision can split one card into several observations. Only join
            // adjacent numeric groups on the same text row. In particular,
            // neither two years nor numbers in distant columns form a card.
            let numeric = valid.filter { numericGroups(lines[$0].text) != nil }
                .sorted { lines[$0].bounds.midY > lines[$1].bounds.midY }
            var rows: [[Int]] = []
            for i in numeric {
                if let row = rows.firstIndex(where: { sameRow(lines[$0[0]].bounds, lines[i].bounds) }) {
                    rows[row].append(i)
                } else {
                    rows.append([i])
                }
            }

            func inspect(_ run: [Int]) {
                guard run.count >= 2 else { return }
                var joined = ""
                var spans: [(index: Int, range: NSRange)] = []
                for i in run {
                    if !joined.isEmpty { joined += " " }
                    spans.append((i, NSRange(location: joined.utf16.count, length: lines[i].text.utf16.count)))
                    joined += lines[i].text
                }
                for match in AutoRedactor.sensitiveMatches(in: joined, enabledTypes: ["credit_card"]) {
                    let text = String(joined[match.range])
                    guard let groups = numericGroups(text), groups.count >= 3,
                          (12...19).contains(groups.reduce(0, +)) else { continue }
                    let range = NSRange(match.range, in: joined)
                    let covered = spans.compactMap { span -> (Int, Range<String.Index>)? in
                        let overlap = NSIntersectionRange(range, span.range)
                        guard overlap.length > 0,
                              let local = Range(NSRange(location: overlap.location - span.range.location,
                                                        length: overlap.length), in: lines[span.index].text)
                        else { return nil }
                        return (span.index, local)
                    }
                    guard covered.count >= 2 else { continue }
                    var bounds = CGRect.null
                    for (i, range) in covered {
                        bounds = bounds.union(lines[i].bounds)
                        cardLines.insert(i)
                        if enabled("credit_card") { append(Match(lineIndex: i, type: "credit_card", range: range)) }
                    }
                    cardBounds.append(bounds)
                }
            }

            for row in rows {
                var run: [Int] = []
                for i in row.sorted(by: { lines[$0].bounds.minX < lines[$1].bounds.minX }) {
                    if let previous = run.last {
                        let left = lines[previous].bounds, right = lines[i].bounds
                        if right.minX - left.maxX > max(left.height, right.height) * 2 {
                            inspect(run)
                            run.removeAll(keepingCapacity: true)
                        }
                    }
                    run.append(i)
                }
                inspect(run)
            }
        }

        if enabled("cvv") {
            let labels = valid.filter {
                let label = lines[$0].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                    .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                return ["CVV", "CVC", "CSC", "CCV"].contains(label)
            }.map { lines[$0].bounds }
            for i in valid {
                let text = lines[i].text
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard (3...4).contains(trimmed.count), isDecimal(trimmed),
                      !cardLines.contains(i),
                      (labels + cardBounds).contains(where: { nearby($0, lines[i].bounds) }),
                      let range = text.range(of: trimmed) else { continue }
                append(Match(lineIndex: i, type: "cvv", range: range))
            }
        }
        return matches
    }

    private static func numericGroups(_ text: String) -> [Int]? {
        let groups = text.split { $0.isWhitespace || $0 == "-" }.map(String.init)
        guard !groups.isEmpty, groups.allSatisfy({ (3...6).contains($0.count) && isDecimal($0) }) else { return nil }
        return groups.map(\.count)
    }

    private static func isDecimal(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    private static func validBounds(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite) &&
            rect.width > 0 && rect.height > 0
    }

    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxY, b.maxY) - max(a.minY, b.minY) >= min(a.height, b.height) * 0.6 &&
            max(a.height, b.height) <= min(a.height, b.height) * 2
    }

    private static func nearby(_ anchor: CGRect, _ value: CGRect) -> Bool {
        let height = max(anchor.height, value.height)
        let horizontalGap = max(0, max(anchor.minX - value.maxX, value.minX - anchor.maxX))
        let verticalGap = max(0, max(anchor.minY - value.maxY, value.minY - anchor.maxY))
        return (sameRow(anchor, value) && horizontalGap <= height * 3) ||
            (horizontalGap == 0 && verticalGap <= height * 2)
    }
}
