import Foundation
import Vision

struct RecognizedTable: Equatable {
    let rows: [[String]]
    let columnCount: Int

    nonisolated init(rows: [[String]]) {
        self.rows = rows
        self.columnCount = rows.map(\.count).max() ?? 0
    }

    var tsv: String {
        rows.map { row in
            (0..<columnCount).map { column in
                guard column < row.count else { return "" }
                return Self.tsvCell(row[column])
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    private static func tsvCell(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalized.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\"" }) else {
            return normalized
        }
        return "\"\(normalized.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

struct TableTextBlock: Equatable {
    let text: String
    let boundingBox: CGRect
}

enum TableRecognitionError: LocalizedError {
    case noTextDetected
    case noTableStructureDetected

    var errorDescription: String? {
        switch self {
        case .noTextDetected:
            return L("No text was detected in the selected area.")
        case .noTableStructureDetected:
            return L("No table structure was detected. Select a table with at least two rows and two columns.")
        }
    }
}

enum VisionTableRecognizer {

    static func recognize(
        cgImage: CGImage,
        completionHandler: @escaping (Result<RecognizedTable, Error>) -> Void
    ) {
        VisionOCR.performTextRecognition(cgImage: cgImage) { request, error in
            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            let blocks = observations.flatMap(textBlocks(from:))

            guard !blocks.isEmpty else {
                completionHandler(.failure(error ?? TableRecognitionError.noTextDetected))
                return
            }
            let grid = TableGridDetector.detect(cgImage: cgImage)
            guard let table = TableStructureDetector.detect(blocks: blocks, grid: grid) else {
                completionHandler(.failure(TableRecognitionError.noTableStructureDetected))
                return
            }
            completionHandler(.success(table))
        }
    }

    private nonisolated static func textBlocks(
        from observation: VNRecognizedTextObservation
    ) -> [TableTextBlock] {
        guard let candidate = observation.topCandidates(1).first else { return [] }
        let text = normalized(candidate.string)
        guard !text.isEmpty else { return [] }

        let fallback = TableTextBlock(text: text, boundingBox: observation.boundingBox)
        let matches = try? NSRegularExpression(pattern: "\\S+").matches(
            in: candidate.string,
            range: NSRange(candidate.string.startIndex..., in: candidate.string)
        )
        guard let matches, matches.count > 1 else { return [fallback] }

        let tokens = matches.compactMap { match -> TableTextBlock? in
            guard let range = Range(match.range, in: candidate.string),
                  let rectangle = try? candidate.boundingBox(for: range) else { return nil }
            let token = normalized(String(candidate.string[range]))
            guard !token.isEmpty else { return nil }
            return TableTextBlock(text: token, boundingBox: rectangle.boundingBox)
        }.sorted { $0.boundingBox.midX < $1.boundingBox.midX }

        guard tokens.count == matches.count else { return [fallback] }

        let characterWidths = tokens.map {
            $0.boundingBox.width / CGFloat(max($0.text.count, 1))
        }
        let medianCharacterWidth = median(characterWidths)
        let medianHeight = median(tokens.map(\.boundingBox.height))
        let cellGapThreshold = max(medianCharacterWidth * 2.5, medianHeight * 0.18)

        var groups: [[TableTextBlock]] = []
        for token in tokens {
            if let previous = groups.last?.last {
                let gap = token.boundingBox.minX - previous.boundingBox.maxX
                if gap <= cellGapThreshold {
                    groups[groups.count - 1].append(token)
                    continue
                }
            }
            groups.append([token])
        }

        guard groups.count > 1 else { return [fallback] }
        return groups.map { group in
            let box = group.dropFirst().reduce(group[0].boundingBox) { $0.union($1.boundingBox) }
            return TableTextBlock(
                text: group.map(\.text).joined(separator: " "),
                boundingBox: box
            )
        }
    }

    private nonisolated static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

enum TableStructureDetector {
    private enum ColumnAlignment: CaseIterable, Sendable {
        case left
        case center
        case right
    }

    private struct ColumnAnchor: Sendable {
        let position: CGFloat
        let center: CGFloat
        let alignment: ColumnAlignment
    }

    private struct AnchorCandidate: Sendable {
        let anchor: ColumnAnchor
        let blockIndices: Set<Int>
    }

    private struct AnchorCluster {
        var blocks: [(offset: Int, element: TableTextBlock)]
        var positions: [CGFloat]
    }

    private struct RowCluster {
        var blocks: [TableTextBlock]

        nonisolated var centerY: CGFloat {
            median(blocks.map(\.boundingBox.midY))
        }

        nonisolated var height: CGFloat {
            median(blocks.map(\.boundingBox.height))
        }
    }

    nonisolated static func detect(
        blocks: [TableTextBlock],
        grid: TableGrid? = nil
    ) -> RecognizedTable? {
        let usableBlocks = blocks.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.boundingBox.width > 0
                && $0.boundingBox.height > 0
        }
        guard !usableBlocks.isEmpty else { return nil }

        var rowClusters: [RowCluster] = []
        for block in usableBlocks.sorted(by: readingOrder) {
            let matchingRow = rowClusters.indices
                .filter { isSameRow(block, row: rowClusters[$0]) }
                .min { lhs, rhs in
                    abs(rowClusters[lhs].centerY - block.boundingBox.midY)
                        < abs(rowClusters[rhs].centerY - block.boundingBox.midY)
                }

            if let matchingRow {
                rowClusters[matchingRow].blocks.append(block)
            } else {
                rowClusters.append(RowCluster(blocks: [block]))
            }
        }

        rowClusters.sort { $0.centerY > $1.centerY }
        for index in rowClusters.indices {
            rowClusters[index].blocks.sort { $0.boundingBox.midX < $1.boundingBox.midX }
        }

        guard rowClusters.count >= 2 else { return nil }
        if let grid, let gridTable = tableUsingGrid(
            blocks: usableBlocks,
            visualRows: rowClusters,
            grid: grid
        ) {
            return gridTable
        }
        guard let anchors = columnAnchors(from: rowClusters) else { return nil }

        let minimumSeedColumns = max(2, (anchors.count + 1) / 2)
        let rowSeeds = rowClusters.filter { row in
            Set(row.blocks.map { columnIndex(for: $0, anchors: anchors) }).count
                >= minimumSeedColumns
        }
        guard rowSeeds.count >= 2 else { return nil }

        var physicalRows = Array(repeating: [RowCluster](), count: rowSeeds.count)
        for row in rowClusters {
            let nearestSeed = rowSeeds.indices.min {
                abs(rowSeeds[$0].centerY - row.centerY)
                    < abs(rowSeeds[$1].centerY - row.centerY)
            } ?? 0
            physicalRows[nearestSeed].append(row)
        }

        let rows = physicalRows.map { visualRows -> [String] in
            var cellLines = Array(repeating: [String](), count: anchors.count)
            for visualRow in visualRows.sorted(by: { $0.centerY > $1.centerY }) {
                var fragments = Array(repeating: [TableTextBlock](), count: anchors.count)
                for block in visualRow.blocks {
                    fragments[columnIndex(for: block, anchors: anchors)].append(block)
                }
                for column in fragments.indices where !fragments[column].isEmpty {
                    let line = fragments[column]
                        .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                        .map(\.text)
                        .joined(separator: " ")
                    cellLines[column].append(line)
                }
            }
            return cellLines.map { $0.joined(separator: "\n") }
        }

        return RecognizedTable(rows: rows)
    }

    private nonisolated static func tableUsingGrid(
        blocks: [TableTextBlock],
        visualRows: [RowCluster],
        grid: TableGrid
    ) -> RecognizedTable? {
        guard let horizontalBoundaries = relevantBoundaries(
            grid.horizontalSeparators,
            contentMin: blocks.map(\.boundingBox.minY).min() ?? 0,
            contentMax: blocks.map(\.boundingBox.maxY).max() ?? 1
        ) else { return nil }

        let verticalBoundaries = grid.verticalSeparators.count >= 3
            ? relevantBoundaries(
                grid.verticalSeparators,
                contentMin: blocks.map(\.boundingBox.minX).min() ?? 0,
                contentMax: blocks.map(\.boundingBox.maxX).max() ?? 1
            )
            : nil
        let geometryAnchors = verticalBoundaries == nil ? columnAnchors(from: visualRows) : nil
        guard verticalBoundaries != nil || geometryAnchors != nil else { return nil }

        var cells: [Int: [Int: [TableTextBlock]]] = [:]
        for block in blocks {
            guard let row = bandIndex(block.boundingBox.midY, boundaries: horizontalBoundaries)
            else { continue }
            let column: Int
            if let verticalBoundaries {
                guard let gridColumn = bandIndex(
                    block.boundingBox.midX,
                    boundaries: verticalBoundaries
                ) else { continue }
                column = gridColumn
            } else if let geometryAnchors {
                column = columnIndex(for: block, anchors: geometryAnchors)
            } else {
                continue
            }
            cells[row, default: [:]][column, default: []].append(block)
        }

        let occupiedRows = cells.keys.sorted()
        let occupiedColumns = Set(cells.values.flatMap(\.keys)).sorted()
        guard occupiedRows.count >= 2,
              let firstRow = occupiedRows.first,
              let lastRow = occupiedRows.last,
              let firstColumn = occupiedColumns.first,
              let lastColumn = occupiedColumns.last,
              lastColumn > firstColumn else { return nil }

        let rows = (firstRow...lastRow).reversed().map { row in
            (firstColumn...lastColumn).map { column in
                cellText(cells[row]?[column] ?? [])
            }
        }
        return RecognizedTable(rows: rows)
    }

    private nonisolated static func relevantBoundaries(
        _ separators: [CGFloat],
        contentMin: CGFloat,
        contentMax: CGFloat
    ) -> [CGFloat]? {
        let sorted = ([CGFloat(0)] + separators + [CGFloat(1)]).sorted()
        guard let lower = sorted.last(where: { $0 <= contentMin }),
              let upper = sorted.first(where: { $0 >= contentMax }),
              upper > lower else { return nil }
        let boundaries = sorted.filter { $0 >= lower && $0 <= upper }
        return boundaries.count >= 3 ? boundaries : nil
    }

    private nonisolated static func bandIndex(
        _ position: CGFloat,
        boundaries: [CGFloat]
    ) -> Int? {
        guard let upper = boundaries.firstIndex(where: { $0 > position }), upper > 0 else {
            return nil
        }
        return upper - 1
    }

    private nonisolated static func cellText(_ blocks: [TableTextBlock]) -> String {
        var lines: [RowCluster] = []
        for block in blocks.sorted(by: readingOrder) {
            if let matchingLine = lines.indices
                .filter({ isSameRow(block, row: lines[$0]) })
                .min(by: {
                    abs(lines[$0].centerY - block.boundingBox.midY)
                        < abs(lines[$1].centerY - block.boundingBox.midY)
                }) {
                lines[matchingLine].blocks.append(block)
            } else {
                lines.append(RowCluster(blocks: [block]))
            }
        }
        return lines
            .sorted { $0.centerY > $1.centerY }
            .map { line in
                line.blocks
                    .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                    .map(\.text)
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    private nonisolated static func columnAnchors(from rows: [RowCluster]) -> [ColumnAnchor]? {
        let candidates = rows
            .filter { $0.blocks.count >= 2 }
            .flatMap(\.blocks)
        guard !candidates.isEmpty else { return nil }

        let characterWidths = candidates.map {
            $0.boundingBox.width / CGFloat(max($0.text.count, 1))
        }
        let tolerance = min(max(median(characterWidths) * 1.5, 0.006), 0.025)

        let indexedCandidates = Array(candidates.enumerated())
        var anchorCandidates: [AnchorCandidate] = []
        for alignment in ColumnAlignment.allCases {
            var clusters: [AnchorCluster] = []
            for block in indexedCandidates.sorted(by: {
                alignedPosition(of: $0.element, alignment: alignment)
                    < alignedPosition(of: $1.element, alignment: alignment)
            }) {
                let position = alignedPosition(of: block.element, alignment: alignment)
                if let last = clusters.indices.last,
                   abs(medianOfSorted(clusters[last].positions) - position) <= tolerance {
                    clusters[last].blocks.append(block)
                    clusters[last].positions.append(position)
                } else {
                    clusters.append(AnchorCluster(blocks: [block], positions: [position]))
                }
            }

            for cluster in clusters where cluster.blocks.count >= 2 {
                anchorCandidates.append(AnchorCandidate(
                    anchor: ColumnAnchor(
                        position: medianOfSorted(cluster.positions),
                        center: median(cluster.blocks.map(\.element.boundingBox.midX)),
                        alignment: alignment
                    ),
                    blockIndices: Set(cluster.blocks.map(\.offset))
                ))
            }
        }

        var usedBlockIndices: Set<Int> = []
        var anchors: [ColumnAnchor] = []
        for candidate in anchorCandidates.sorted(by: {
            if $0.blockIndices.count != $1.blockIndices.count {
                return $0.blockIndices.count > $1.blockIndices.count
            }
            return $0.anchor.center < $1.anchor.center
        }) where candidate.blockIndices.isDisjoint(with: usedBlockIndices) {
            anchors.append(candidate.anchor)
            usedBlockIndices.formUnion(candidate.blockIndices)
        }
        anchors.sort { $0.center < $1.center }
        return anchors.count >= 2 ? anchors : nil
    }

    private nonisolated static func columnIndex(
        for block: TableTextBlock,
        anchors: [ColumnAnchor]
    ) -> Int {
        anchors.indices.min {
            abs(anchors[$0].position - alignedPosition(
                of: block,
                alignment: anchors[$0].alignment
            )) < abs(anchors[$1].position - alignedPosition(
                of: block,
                alignment: anchors[$1].alignment
            ))
        } ?? 0
    }

    private nonisolated static func alignedPosition(
        of block: TableTextBlock,
        alignment: ColumnAlignment
    ) -> CGFloat {
        switch alignment {
        case .left:
            return block.boundingBox.minX
        case .center:
            return block.boundingBox.midX
        case .right:
            return block.boundingBox.maxX
        }
    }

    private nonisolated static func readingOrder(
        _ lhs: TableTextBlock,
        _ rhs: TableTextBlock
    ) -> Bool {
        if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > 0.001 {
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }
        return lhs.boundingBox.minX < rhs.boundingBox.minX
    }

    private nonisolated static func isSameRow(_ block: TableTextBlock, row: RowCluster) -> Bool {
        let tolerance = max(block.boundingBox.height, row.height) * 0.6
        return abs(block.boundingBox.midY - row.centerY) <= tolerance
    }

    private nonisolated static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return medianOfSorted(sorted)
    }

    private nonisolated static func medianOfSorted(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}
