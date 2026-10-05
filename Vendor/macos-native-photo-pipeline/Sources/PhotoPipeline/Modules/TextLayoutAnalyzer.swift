import Foundation
import CoreGraphics

/// Spatial layout analysis for grouping OCR text observations into
/// paragraphs, columns, and document structures.
///
/// Replicates the layout reconstruction that Apple's CRTextDetectionPipeline
/// does internally: observations come back as flat arrays with bounding boxes,
/// and structure is recovered via spatial clustering.
///
/// Vision coordinates: origin at bottom-left, normalized 0–1.
///
/// ```swift
/// let analyzer = TextLayoutAnalyzer()
/// let blocks = analyzer.group(observations, strategy: .block)
/// let layout = analyzer.analyzeDocument(observations)
/// ```
public struct TextLayoutAnalyzer: Sendable {

    public init() {}

    // MARK: - Public API

    /// Group text observations using the specified strategy.
    public func group(_ observations: [TextObservation], strategy: TextGrouping) -> [TextBlock] {
        guard !observations.isEmpty else { return [] }

        switch strategy {
        case .line:
            return observations.enumerated().map { i, obs in
                TextBlock(
                    id: "line-\(i)",
                    text: obs.text,
                    lines: [obs],
                    boundingBox: obs.boundingBox,
                    confidence: obs.confidence,
                    role: .body,
                    columnIndex: 0
                )
            }

        case .block:
            return groupIntoBlocks(observations)

        case .column:
            let columns = detectColumns(observations)
            return groupColumnar(observations, columns: columns)

        case .document:
            return analyzeDocumentBlocks(observations)

        case .neural:
            // Neural grouping is handled by NeuralTextDetector before reaching here.
            // If we get here, fall back to document-level spatial analysis.
            return analyzeDocumentBlocks(observations)
        }
    }

    /// Full document layout analysis — columns, reading order, structure.
    public func analyzeDocument(_ observations: [TextObservation]) -> DocumentLayout {
        guard !observations.isEmpty else {
            return DocumentLayout(blocks: [])
        }

        let columns = detectColumns(observations)
        let blocks = analyzeDocumentBlocks(observations)
        let direction = detectReadingDirection(observations)
        let hasForm = detectFormStructure(observations)
        let hasTable = detectTableStructure(observations)

        return DocumentLayout(
            blocks: blocks,
            columnCount: max(columns.count, 1),
            readingDirection: direction,
            hasFormStructure: hasForm,
            hasTableStructure: hasTable
        )
    }

    // MARK: - Block Grouping (paragraph detection)

    /// Groups lines into paragraphs based on vertical proximity and horizontal alignment.
    ///
    /// Algorithm:
    /// 1. Sort lines top-to-bottom (descending Y in Vision coords)
    /// 2. For each line, check if it belongs to the current block:
    ///    - Vertical gap < threshold (1.8× median line height)
    ///    - Horizontal overlap > 30% (same text region)
    /// 3. If not, start a new block
    private func groupIntoBlocks(_ observations: [TextObservation]) -> [TextBlock] {
        let sorted = sortReadingOrder(observations)
        let medianHeight = medianLineHeight(sorted)
        let verticalThreshold = medianHeight * 1.8

        var blocks: [[TextObservation]] = []
        var currentBlock: [TextObservation] = []

        for obs in sorted {
            if let last = currentBlock.last {
                let gap = verticalGap(last, obs)
                let overlap = horizontalOverlap(last, obs)

                if gap < verticalThreshold && overlap > 0.3 {
                    currentBlock.append(obs)
                } else {
                    blocks.append(currentBlock)
                    currentBlock = [obs]
                }
            } else {
                currentBlock = [obs]
            }
        }
        if !currentBlock.isEmpty {
            blocks.append(currentBlock)
        }

        return blocks.enumerated().map { i, lines in
            makeBlock(id: "block-\(i)", lines: lines)
        }
    }

    // MARK: - Column Detection

    /// Detects column boundaries by clustering horizontal positions.
    ///
    /// Algorithm:
    /// 1. Collect left-edge X coordinates of all observations
    /// 2. Sort and find gaps significantly larger than median inter-line spacing
    /// 3. Each cluster of left-edges = one column
    ///
    /// Returns column boundaries as (minX, maxX) ranges.
    func detectColumns(_ observations: [TextObservation]) -> [ClosedRange<CGFloat>] {
        guard observations.count >= 2 else {
            return [0...1]
        }

        // Collect left edges and right edges
        let edges = observations.map { obs -> (left: CGFloat, right: CGFloat) in
            (obs.boundingBox.minX, obs.boundingBox.maxX)
        }

        let leftEdges = edges.map(\.left).sorted()

        // Find gaps between left edges that indicate column boundaries
        var gaps: [(index: Int, size: CGFloat)] = []
        for i in 1..<leftEdges.count {
            let gap = leftEdges[i] - leftEdges[i - 1]
            gaps.append((i, gap))
        }

        let medianGap = gaps.map(\.size).sorted()[gaps.count / 2]
        // A column boundary gap must be significantly larger than typical line spacing
        let columnGapThreshold = max(medianGap * 4, 0.15)

        // Find significant gaps
        let significantGaps = gaps.filter { $0.size > columnGapThreshold }

        if significantGaps.isEmpty {
            // Single column
            let minX = edges.map(\.left).min() ?? 0
            let maxX = edges.map(\.right).max() ?? 1
            return [minX...maxX]
        }

        // Build column ranges from gaps
        var columns: [ClosedRange<CGFloat>] = []
        var prevBoundary: CGFloat = edges.map(\.left).min() ?? 0

        for gap in significantGaps.sorted(by: { $0.index < $1.index }) {
            let boundaryX = (leftEdges[gap.index - 1] + leftEdges[gap.index]) / 2
            let maxX = edges.filter { $0.left >= prevBoundary && $0.left < boundaryX }
                .map(\.right).max() ?? boundaryX
            columns.append(prevBoundary...maxX)
            prevBoundary = leftEdges[gap.index]
        }

        // Last column
        let maxX = edges.filter { $0.left >= prevBoundary }.map(\.right).max() ?? 1
        columns.append(prevBoundary...maxX)

        return columns
    }

    /// Group observations by detected columns, then block-group within each column.
    private func groupColumnar(_ observations: [TextObservation], columns: [ClosedRange<CGFloat>]) -> [TextBlock] {
        var result: [TextBlock] = []

        for (colIdx, colRange) in columns.enumerated() {
            // Observations whose midpoint X falls within this column
            let colObs = observations.filter { obs in
                let midX = obs.boundingBox.midX
                return colRange.contains(midX)
            }

            let blocks = groupIntoBlocks(colObs)
            let retagged = blocks.map { block in
                TextBlock(
                    id: "col\(colIdx)-\(block.id)",
                    text: block.text,
                    lines: block.lines,
                    boundingBox: block.boundingBox,
                    confidence: block.confidence,
                    role: block.role,
                    columnIndex: colIdx
                )
            }
            result.append(contentsOf: retagged)
        }

        // Sort by reading order: column by column, top to bottom
        return result.sorted { a, b in
            if a.columnIndex != b.columnIndex { return a.columnIndex < b.columnIndex }
            return a.boundingBox.maxY > b.boundingBox.maxY
        }
    }

    // MARK: - Document Layout Analysis

    /// Full document analysis: columns + structural role classification.
    private func analyzeDocumentBlocks(_ observations: [TextObservation]) -> [TextBlock] {
        let columns = detectColumns(observations)
        var blocks = groupColumnar(observations, columns: columns)

        // Classify structural roles
        let stats = computeStats(observations)
        blocks = blocks.map { block in
            let role = classifyRole(block, stats: stats, totalColumns: columns.count)
            return TextBlock(
                id: block.id,
                text: block.text,
                lines: block.lines,
                boundingBox: block.boundingBox,
                confidence: block.confidence,
                role: role,
                columnIndex: block.columnIndex
            )
        }

        // Sort into reading order
        return sortBlocksReadingOrder(blocks)
    }

    // MARK: - Structural Role Classification

    private struct TextStats {
        let medianHeight: CGFloat
        let medianWidth: CGFloat
        let pageTopY: CGFloat    // highest Y value (top of page in Vision coords)
        let pageBottomY: CGFloat // lowest Y value
        let medianX: CGFloat
    }

    private func computeStats(_ observations: [TextObservation]) -> TextStats {
        let heights = observations.map { $0.boundingBox.height }
        let widths = observations.map { $0.boundingBox.width }
        let ys = observations.map { $0.boundingBox.maxY }
        let xs = observations.map { $0.boundingBox.midX }

        return TextStats(
            medianHeight: median(heights),
            medianWidth: median(widths),
            pageTopY: ys.max() ?? 1,
            pageBottomY: ys.min() ?? 0,
            medianX: median(xs)
        )
    }

    /// Classify a block's structural role based on spatial features.
    ///
    /// Heuristics (similar to CRTextDetectionPipeline):
    /// - **Heading**: taller than 1.4× median line height, near top of page
    /// - **Caption**: shorter than 0.8× median, near bottom or narrow width
    /// - **Sidebar**: in outer column and significantly narrower than body
    /// - **Body**: everything else
    private func classifyRole(_ block: TextBlock, stats: TextStats, totalColumns: Int) -> TextRole {
        let avgLineHeight = block.lines.map { $0.boundingBox.height }.reduce(0, +)
            / CGFloat(max(block.lines.count, 1))

        // Heading: larger text, near page top
        let isLarger = avgLineHeight > stats.medianHeight * 1.4
        let nearTop = block.boundingBox.maxY > stats.pageTopY - (stats.pageTopY - stats.pageBottomY) * 0.15
        if isLarger && nearTop {
            return .heading
        }
        if isLarger && block.lines.count <= 2 {
            return .heading
        }

        // Caption: smaller text, near bottom or narrow
        let isSmaller = avgLineHeight < stats.medianHeight * 0.8
        let nearBottom = block.boundingBox.minY < stats.pageBottomY + (stats.pageTopY - stats.pageBottomY) * 0.1
        if isSmaller && (nearBottom || block.boundingBox.width < stats.medianWidth * 0.5) {
            return .caption
        }

        // Sidebar: in an outer column with significantly less text
        if totalColumns >= 2 && block.lines.count <= 3 {
            let isEdge = block.columnIndex == 0 || block.columnIndex == totalColumns - 1
            if isEdge && block.boundingBox.width < stats.medianWidth * 0.6 {
                return .sidebar
            }
        }

        return .body
    }

    // MARK: - Form/Table Detection

    /// Detect form structure: aligned label-value pairs.
    ///
    /// A form has horizontally aligned pairs where labels cluster on the left
    /// and values cluster on the right with consistent spacing.
    func detectFormStructure(_ observations: [TextObservation]) -> Bool {
        guard observations.count >= 4 else { return false }

        // Look for consistent left-right alignment patterns
        let sorted = sortReadingOrder(observations)
        var pairCount = 0

        for i in stride(from: 0, to: sorted.count - 1, by: 1) {
            let a = sorted[i]
            let b = sorted[i + 1]

            // Same vertical band (same row)
            let sameRow = abs(a.boundingBox.midY - b.boundingBox.midY) < a.boundingBox.height * 0.5
            // Horizontal gap between them
            let hGap = b.boundingBox.minX - a.boundingBox.maxX
            let hasGap = hGap > a.boundingBox.height * 0.5 && hGap < 0.4

            if sameRow && hasGap {
                pairCount += 1
            }
        }

        // Form-like if at least 3 label-value pairs
        return pairCount >= 3
    }

    /// Detect table structure: grid-aligned text in rows and columns.
    ///
    /// A table has:
    /// - Multiple observations sharing very similar Y positions (rows)
    /// - Multiple observations sharing very similar X positions (columns)
    /// - At least 2×2 grid intersections
    func detectTableStructure(_ observations: [TextObservation]) -> Bool {
        guard observations.count >= 4 else { return false }

        let tolerance = medianLineHeight(observations) * 0.3

        // Cluster Y positions into rows
        let ys = observations.map { $0.boundingBox.midY }.sorted()
        let rows = clusterValues(ys, tolerance: tolerance)

        // Cluster X positions into columns
        let xs = observations.map { $0.boundingBox.midX }.sorted()
        let cols = clusterValues(xs, tolerance: tolerance * 2)

        // Table: at least 2 rows and 2 columns with cells filled
        return rows.count >= 2 && cols.count >= 2
    }

    // MARK: - Reading Direction Detection

    /// Detect reading direction from observation layout.
    ///
    /// Looks at the dominant text flow direction:
    /// - Most observations left-aligned with ascending X → LTR
    /// - Most observations right-aligned with descending X → RTL
    /// - Tall narrow observations stacked → TTB
    func detectReadingDirection(_ observations: [TextObservation]) -> ReadingDirection {
        guard observations.count >= 2 else { return .leftToRight }

        // Check for vertical text (tall, narrow bounding boxes)
        let verticalCount = observations.filter { obs in
            obs.boundingBox.height > obs.boundingBox.width * 2
        }.count

        if verticalCount > observations.count / 2 {
            return .topToBottom
        }

        // Check for RTL: right edges more consistently aligned than left edges
        let leftEdges = observations.map { $0.boundingBox.minX }
        let rightEdges = observations.map { $0.boundingBox.maxX }

        let leftVariance = variance(leftEdges)
        let rightVariance = variance(rightEdges)

        // RTL text has more consistent right-edge alignment
        if rightVariance < leftVariance * 0.5 {
            return .rightToLeft
        }

        return .leftToRight
    }

    // MARK: - Spatial Helpers

    /// Sort observations in reading order (top-to-bottom, left-to-right).
    /// Vision coordinates have Y increasing upward, so we sort descending Y.
    func sortReadingOrder(_ observations: [TextObservation]) -> [TextObservation] {
        let lineHeight = medianLineHeight(observations)

        return observations.sorted { a, b in
            // Same row if Y midpoints are within half a line height
            let sameRow = abs(a.boundingBox.midY - b.boundingBox.midY) < lineHeight * 0.5
            if sameRow {
                return a.boundingBox.minX < b.boundingBox.minX
            }
            // Higher Y = earlier in reading order (Vision coords: Y goes up)
            return a.boundingBox.midY > b.boundingBox.midY
        }
    }

    /// Vertical gap between two observations (in reading order).
    /// Positive = there's a gap, negative = overlapping.
    private func verticalGap(_ upper: TextObservation, _ lower: TextObservation) -> CGFloat {
        // In Vision coords, upper has higher Y
        return upper.boundingBox.minY - lower.boundingBox.maxY
    }

    /// Fraction of horizontal overlap between two observations (0–1).
    private func horizontalOverlap(_ a: TextObservation, _ b: TextObservation) -> CGFloat {
        let overlapStart = max(a.boundingBox.minX, b.boundingBox.minX)
        let overlapEnd = min(a.boundingBox.maxX, b.boundingBox.maxX)
        let overlap = max(0, overlapEnd - overlapStart)
        let minWidth = min(a.boundingBox.width, b.boundingBox.width)
        guard minWidth > 0 else { return 0 }
        return overlap / minWidth
    }

    private func medianLineHeight(_ observations: [TextObservation]) -> CGFloat {
        let heights = observations.map { $0.boundingBox.height }.sorted()
        guard !heights.isEmpty else { return 0.02 }
        return heights[heights.count / 2]
    }

    private func makeBlock(id: String, lines: [TextObservation], role: TextRole = .body, columnIndex: Int = 0) -> TextBlock {
        let text = lines.map(\.text).joined(separator: " ")
        let avgConf = lines.map(\.confidence).reduce(0, +) / Float(max(lines.count, 1))
        let bbox = enclosingBox(lines.map(\.boundingBox))
        return TextBlock(
            id: id,
            text: text,
            lines: lines,
            boundingBox: bbox,
            confidence: avgConf,
            role: role,
            columnIndex: columnIndex
        )
    }

    private func enclosingBox(_ rects: [CGRect]) -> CGRect {
        guard let first = rects.first else { return .zero }
        var result = first
        for r in rects.dropFirst() {
            result = result.union(r)
        }
        return result
    }

    private func sortBlocksReadingOrder(_ blocks: [TextBlock]) -> [TextBlock] {
        blocks.sorted { a, b in
            // Primary: column index (left columns first)
            if a.columnIndex != b.columnIndex { return a.columnIndex < b.columnIndex }
            // Secondary: top to bottom (descending Y in Vision coords)
            return a.boundingBox.maxY > b.boundingBox.maxY
        }
    }

    /// Cluster sorted values into groups where adjacent values are within tolerance.
    private func clusterValues(_ sorted: [CGFloat], tolerance: CGFloat) -> [[CGFloat]] {
        guard !sorted.isEmpty else { return [] }
        var clusters: [[CGFloat]] = [[sorted[0]]]
        for v in sorted.dropFirst() {
            if v - clusters[clusters.count - 1].last! < tolerance {
                clusters[clusters.count - 1].append(v)
            } else {
                clusters.append([v])
            }
        }
        return clusters
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    private func variance(_ values: [CGFloat]) -> CGFloat {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / CGFloat(values.count)
        let sumSquares = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
        return sumSquares / CGFloat(values.count)
    }
}
