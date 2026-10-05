import Foundation
import CoreGraphics
import PhotoPipeline

/// Applies a slightly wider paragraph grouping threshold than PhotoPipeline defaults.
/// This keeps loosely spaced OCR lines together as a single paragraph block.
enum OCRParagraphGrouper {
    // Looser thresholds to keep meme/comic text blocks together when OCR line boxes
    // are slightly staggered or have larger inter-line spacing.
    private static let verticalGapMultiplier: CGFloat = 6.0
    private static let maximumMergeVerticalGap: CGFloat = 0.055
    private static let intraBlockSplitGapMultiplier: CGFloat = 1.2
    private static let minimumHorizontalOverlap: CGFloat = 0.03
    private static let maximumLeftEdgeDelta: CGFloat = 0.12
    private static let maximumCenterDeltaForCrossColumnMerge: CGFloat = 0.12
    private static let maximumLeftEdgeDeltaForCrossColumnMerge: CGFloat = 0.09

    static func group(
        _ observations: [TextObservation],
        analyzer: TextLayoutAnalyzer = TextLayoutAnalyzer()
    ) -> [TextBlock] {
        let initialBlocks = analyzer.group(observations, strategy: .block)
        let splitBlocks = splitBlocksOnLargeLineGaps(initialBlocks)
        return mergeAdjacentBlocks(splitBlocks)
    }

    private static func mergeAdjacentBlocks(_ blocks: [TextBlock]) -> [TextBlock] {
        guard !blocks.isEmpty else { return [] }

        let sorted = blocks.sorted { lhs, rhs in
            if lhs.columnIndex != rhs.columnIndex {
                return lhs.columnIndex < rhs.columnIndex
            }
            return lhs.boundingBox.maxY > rhs.boundingBox.maxY
        }

        let globalMedianHeight = medianLineHeight(sorted)

        var remaining = sorted
        var merged: [TextBlock] = []

        while !remaining.isEmpty {
            var current = remaining.removeFirst()

            // Keep merging the nearest compatible block, even if unrelated blocks
            // sit between lines in simple Y-order.
            while true {
                var bestIndex: Int?
                var bestDistance = CGFloat.greatestFiniteMagnitude

                for (index, candidate) in remaining.enumerated() {
                    let decision = mergeDecision(current: current, next: candidate, globalMedianHeight: globalMedianHeight)
                    guard decision.shouldMerge else { continue }

                    let distance = abs(decision.gap)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestIndex = index
                    }
                }

                guard let matchIndex = bestIndex else { break }
                let candidate = remaining.remove(at: matchIndex)
                current = combine(current, candidate)
            }

            merged.append(current)
        }

        return merged
    }

    private struct MergeDecision {
        let shouldMerge: Bool
        let gap: CGFloat
    }

    private static func mergeDecision(current: TextBlock, next: TextBlock, globalMedianHeight: CGFloat) -> MergeDecision {
        let gap = current.boundingBox.minY - next.boundingBox.maxY
        let overlap = horizontalOverlapRatio(current.boundingBox, next.boundingBox)
        let leftDelta = abs(current.boundingBox.minX - next.boundingBox.minX)
        let centerDelta = abs(current.boundingBox.midX - next.boundingBox.midX)
        let localMedianHeight = median(
            current.lines.map { $0.boundingBox.height } +
            next.lines.map { $0.boundingBox.height }
        )
        // Use local line heights so small text elsewhere doesn't make large
        // paragraphs artificially hard to merge.
        let verticalThreshold = max(
            0.01,
            max(globalMedianHeight, localMedianHeight) * verticalGapMultiplier
        )
        let clampedVerticalThreshold = min(verticalThreshold, maximumMergeVerticalGap)

        let horizontalAligned = overlap >= minimumHorizontalOverlap || leftDelta <= maximumLeftEdgeDelta
        let crossColumnAligned = centerDelta <= maximumCenterDeltaForCrossColumnMerge ||
            leftDelta <= maximumLeftEdgeDeltaForCrossColumnMerge
        let columnCompatible = current.columnIndex == next.columnIndex || crossColumnAligned

        return MergeDecision(
            shouldMerge: columnCompatible && gap <= clampedVerticalThreshold && horizontalAligned,
            gap: gap
        )
    }

    /// Split oversized analyzer blocks at large vertical gaps between lines.
    /// This prevents feed-like screenshots from collapsing multiple posts into one block.
    private static func splitBlocksOnLargeLineGaps(_ blocks: [TextBlock]) -> [TextBlock] {
        var result: [TextBlock] = []
        result.reserveCapacity(blocks.count)

        for block in blocks {
            let sortedLines = sortLinesByReadingOrder(block.lines)
            guard sortedLines.count > 1 else {
                result.append(block)
                continue
            }

            let lineMedianHeight = median(sortedLines.map { $0.boundingBox.height })
            let splitGapThreshold = max(0.03, lineMedianHeight * intraBlockSplitGapMultiplier)

            var chunks: [[TextObservation]] = [[sortedLines[0]]]
            for line in sortedLines.dropFirst() {
                guard let prev = chunks.last?.last else { continue }
                let gap = prev.boundingBox.minY - line.boundingBox.maxY

                if gap > splitGapThreshold {
                    chunks.append([line])
                } else {
                    chunks[chunks.count - 1].append(line)
                }
            }

            if chunks.count == 1 {
                result.append(block)
                continue
            }

            for (index, chunk) in chunks.enumerated() {
                result.append(makeBlock(from: chunk, template: block, chunkIndex: index))
            }
        }

        return result
    }

    private static func makeBlock(from lines: [TextObservation], template: TextBlock, chunkIndex: Int) -> TextBlock {
        let orderedLines = sortLinesByReadingOrder(lines)
        let text = orderedLines.map(\.text).joined(separator: " ")
        let confidence = orderedLines.map(\.confidence).reduce(0, +) / Float(max(orderedLines.count, 1))
        let boundingBox = orderedLines
            .map(\.boundingBox)
            .reduce(.null) { partial, rect in
                partial.isNull ? rect : partial.union(rect)
            }

        return TextBlock(
            id: chunkIndex == 0 ? template.id : "\(template.id)-chunk-\(chunkIndex)",
            text: text,
            lines: orderedLines,
            boundingBox: boundingBox,
            confidence: confidence,
            role: template.role,
            columnIndex: template.columnIndex
        )
    }

    private static func combine(_ upper: TextBlock, _ lower: TextBlock) -> TextBlock {
        let combinedLines = sortLinesByReadingOrder(upper.lines + lower.lines)
        let text = combinedLines.map(\.text).joined(separator: " ")
        let confidence = combinedLines.map(\.confidence).reduce(0, +) / Float(max(combinedLines.count, 1))
        let boundingBox = combinedLines
            .map(\.boundingBox)
            .reduce(.null) { partial, rect in
                partial.isNull ? rect : partial.union(rect)
            }

        return TextBlock(
            id: upper.id,
            text: text,
            lines: combinedLines,
            boundingBox: boundingBox,
            confidence: confidence,
            role: upper.role,
            columnIndex: upper.columnIndex
        )
    }

    private static func sortLinesByReadingOrder(_ lines: [TextObservation]) -> [TextObservation] {
        guard !lines.isEmpty else { return [] }
        let medianHeight = median(lines.map { $0.boundingBox.height })

        return lines.sorted { lhs, rhs in
            let sameRow = abs(lhs.boundingBox.midY - rhs.boundingBox.midY) < (medianHeight * 0.5)
            if sameRow {
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }
    }

    private static func medianLineHeight(_ blocks: [TextBlock]) -> CGFloat {
        median(blocks.flatMap { $0.lines.map { $0.boundingBox.height } })
    }

    private static func horizontalOverlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlapStart = max(lhs.minX, rhs.minX)
        let overlapEnd = min(lhs.maxX, rhs.maxX)
        let overlap = max(0, overlapEnd - overlapStart)
        let minWidth = min(lhs.width, rhs.width)
        guard minWidth > 0 else { return 0 }
        return overlap / minWidth
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0.02 }
        return sorted[sorted.count / 2]
    }
}
