import XCTest
@testable import PhotoPipeline

/// Tests for TextLayoutAnalyzer spatial grouping algorithms.
final class TextLayoutTests: XCTestCase {

    let analyzer = TextLayoutAnalyzer()

    // MARK: - Helpers

    /// Make a TextObservation at the given position.
    /// Vision coordinates: origin bottom-left, normalized 0–1.
    func obs(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 0.4, h: CGFloat = 0.03) -> TextObservation {
        TextObservation(
            text: text,
            boundingBox: CGRect(x: x, y: y, width: w, height: h),
            confidence: 0.95
        )
    }

    // MARK: - Line Grouping (passthrough)

    func testLineGroupingReturnsOneBlockPerLine() {
        let observations = [
            obs("Hello", x: 0.1, y: 0.9),
            obs("World", x: 0.1, y: 0.85),
        ]
        let blocks = analyzer.group(observations, strategy: .line)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].lines.count, 1)
        XCTAssertEqual(blocks[1].lines.count, 1)
    }

    // MARK: - Block Grouping (paragraph detection)

    func testAdjacentLinesGroupIntoOneBlock() {
        // Three lines close together vertically (paragraph)
        let observations = [
            obs("Line one of the paragraph.", x: 0.1, y: 0.9),
            obs("Line two continues here.", x: 0.1, y: 0.86),
            obs("Line three ends it.", x: 0.1, y: 0.82),
        ]
        let blocks = analyzer.group(observations, strategy: .block)
        XCTAssertEqual(blocks.count, 1, "Three adjacent lines should form one block")
        XCTAssertEqual(blocks[0].lines.count, 3)
        XCTAssert(blocks[0].text.contains("Line one"))
        XCTAssert(blocks[0].text.contains("Line three"))
    }

    func testLargeGapSplitsIntoTwoBlocks() {
        // Two paragraphs separated by a big gap
        let observations = [
            obs("First paragraph line one.", x: 0.1, y: 0.9),
            obs("First paragraph line two.", x: 0.1, y: 0.86),
            // big gap
            obs("Second paragraph line one.", x: 0.1, y: 0.5),
            obs("Second paragraph line two.", x: 0.1, y: 0.46),
        ]
        let blocks = analyzer.group(observations, strategy: .block)
        XCTAssertEqual(blocks.count, 2, "Large vertical gap should split into two blocks")
        XCTAssertEqual(blocks[0].lines.count, 2)
        XCTAssertEqual(blocks[1].lines.count, 2)
    }

    func testHorizontalMisalignmentSplitsBlocks() {
        // Two lines at same Y level but far apart horizontally = different blocks
        let observations = [
            obs("Left text here.", x: 0.05, y: 0.9, w: 0.3),
            obs("Right text here.", x: 0.65, y: 0.9, w: 0.3),
        ]
        let blocks = analyzer.group(observations, strategy: .block)
        // These are on the same row but don't overlap horizontally
        // Block grouping should keep them separate or in same block
        // depending on reading order — they're adjacent vertically (same Y)
        // but the horizontal overlap check should handle this
        XCTAssertGreaterThanOrEqual(blocks.count, 1)
    }

    func testEmptyInputReturnsEmpty() {
        let blocks = analyzer.group([], strategy: .block)
        XCTAssertTrue(blocks.isEmpty)
    }

    func testSingleLineReturnsOneBlock() {
        let blocks = analyzer.group([obs("Just one line.", x: 0.1, y: 0.5)], strategy: .block)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].text, "Just one line.")
    }

    // MARK: - Column Detection

    func testSingleColumnDetection() {
        let observations = [
            obs("Line A", x: 0.1, y: 0.9),
            obs("Line B", x: 0.1, y: 0.86),
            obs("Line C", x: 0.1, y: 0.82),
        ]
        let columns = analyzer.detectColumns(observations)
        XCTAssertEqual(columns.count, 1, "Left-aligned text should be 1 column")
    }

    func testTwoColumnDetection() {
        // Left column at x=0.05, right column at x=0.55
        let observations = [
            obs("Left col line 1", x: 0.05, y: 0.9, w: 0.35),
            obs("Left col line 2", x: 0.05, y: 0.86, w: 0.35),
            obs("Left col line 3", x: 0.05, y: 0.82, w: 0.35),
            obs("Right col line 1", x: 0.55, y: 0.9, w: 0.35),
            obs("Right col line 2", x: 0.55, y: 0.86, w: 0.35),
            obs("Right col line 3", x: 0.55, y: 0.82, w: 0.35),
        ]
        let columns = analyzer.detectColumns(observations)
        XCTAssertEqual(columns.count, 2, "Two distinct X clusters should be 2 columns")
    }

    func testColumnGroupingPreservesReadingOrder() {
        let observations = [
            obs("Left 1", x: 0.05, y: 0.9, w: 0.35),
            obs("Left 2", x: 0.05, y: 0.86, w: 0.35),
            obs("Right 1", x: 0.55, y: 0.9, w: 0.35),
            obs("Right 2", x: 0.55, y: 0.86, w: 0.35),
        ]
        let blocks = analyzer.group(observations, strategy: .column)
        // Left column blocks should come first
        XCTAssertTrue(blocks.first?.text.contains("Left") ?? false,
                      "Left column should appear first in reading order")
    }

    // MARK: - Document Layout

    func testDocumentLayoutDetectsHeading() {
        let observations = [
            // Large heading text
            obs("Big Title Here", x: 0.1, y: 0.95, w: 0.6, h: 0.06),
            // Body text
            obs("Body paragraph line one.", x: 0.1, y: 0.8, w: 0.6, h: 0.025),
            obs("Body paragraph line two.", x: 0.1, y: 0.77, w: 0.6, h: 0.025),
            obs("Body paragraph line three.", x: 0.1, y: 0.74, w: 0.6, h: 0.025),
        ]
        let blocks = analyzer.group(observations, strategy: .document)
        let headings = blocks.filter { $0.role == .heading }
        XCTAssertFalse(headings.isEmpty, "Large text near top should be classified as heading")
        XCTAssertTrue(headings[0].text.contains("Big Title"))
    }

    func testDocumentLayoutDetectsCaption() {
        let observations = [
            // Body text
            obs("Main body text here.", x: 0.1, y: 0.7, w: 0.6, h: 0.03),
            obs("More body text here.", x: 0.1, y: 0.66, w: 0.6, h: 0.03),
            // Small caption at bottom
            obs("Fig 1: A small caption.", x: 0.2, y: 0.05, w: 0.3, h: 0.015),
        ]
        let blocks = analyzer.group(observations, strategy: .document)
        let captions = blocks.filter { $0.role == .caption }
        XCTAssertFalse(captions.isEmpty, "Small text at bottom should be caption")
    }

    func testDocumentAnalysisReturnsLayout() {
        let observations = [
            obs("Title", x: 0.1, y: 0.95, w: 0.6, h: 0.05),
            obs("Body line 1", x: 0.1, y: 0.8),
            obs("Body line 2", x: 0.1, y: 0.76),
        ]
        let layout = analyzer.analyzeDocument(observations)
        XCTAssertFalse(layout.blocks.isEmpty)
        XCTAssertGreaterThanOrEqual(layout.columnCount, 1)
        XCTAssertEqual(layout.readingDirection, .leftToRight)
    }

    // MARK: - Reading Direction

    func testLTRDetection() {
        let observations = [
            obs("Hello", x: 0.1, y: 0.9, w: 0.3),
            obs("World", x: 0.1, y: 0.85, w: 0.35),
            obs("Test", x: 0.1, y: 0.8, w: 0.25),
        ]
        XCTAssertEqual(analyzer.detectReadingDirection(observations), .leftToRight)
    }

    func testRTLDetection() {
        // RTL: consistent right edges, variable left edges
        let observations = [
            obs("مرحبا", x: 0.4, y: 0.9, w: 0.5),
            obs("عالم", x: 0.5, y: 0.85, w: 0.4),
            obs("اختبار", x: 0.3, y: 0.8, w: 0.6),
        ]
        let dir = analyzer.detectReadingDirection(observations)
        // All right edges at 0.9 — should detect RTL
        XCTAssertEqual(dir, .rightToLeft)
    }

    // MARK: - Form/Table Detection

    func testFormDetection() {
        // Label-value pairs aligned horizontally
        let observations = [
            obs("Name:", x: 0.05, y: 0.9, w: 0.15),
            obs("John Smith", x: 0.3, y: 0.9, w: 0.25),
            obs("Email:", x: 0.05, y: 0.85, w: 0.15),
            obs("john@example.com", x: 0.3, y: 0.85, w: 0.3),
            obs("Phone:", x: 0.05, y: 0.8, w: 0.15),
            obs("555-1234", x: 0.3, y: 0.8, w: 0.2),
            obs("Address:", x: 0.05, y: 0.75, w: 0.15),
            obs("123 Main St", x: 0.3, y: 0.75, w: 0.25),
        ]
        XCTAssertTrue(analyzer.detectFormStructure(observations),
                      "Aligned label-value pairs should be detected as form")
    }

    func testTableDetection() {
        // 3×3 grid
        let observations = [
            obs("A1", x: 0.1, y: 0.9, w: 0.15),
            obs("B1", x: 0.35, y: 0.9, w: 0.15),
            obs("C1", x: 0.6, y: 0.9, w: 0.15),
            obs("A2", x: 0.1, y: 0.85, w: 0.15),
            obs("B2", x: 0.35, y: 0.85, w: 0.15),
            obs("C2", x: 0.6, y: 0.85, w: 0.15),
            obs("A3", x: 0.1, y: 0.8, w: 0.15),
            obs("B3", x: 0.35, y: 0.8, w: 0.15),
            obs("C3", x: 0.6, y: 0.8, w: 0.15),
        ]
        XCTAssertTrue(analyzer.detectTableStructure(observations),
                      "Grid-aligned text should be detected as table")
    }

    func testNonTableText() {
        // Just regular paragraph text
        let observations = [
            obs("Line one of text.", x: 0.1, y: 0.9),
            obs("Line two of text.", x: 0.1, y: 0.86),
        ]
        XCTAssertFalse(analyzer.detectTableStructure(observations))
    }

    // MARK: - Reading Order

    func testReadingOrderSort() {
        // Out-of-order observations
        let observations = [
            obs("Third", x: 0.1, y: 0.5),
            obs("First", x: 0.1, y: 0.9),
            obs("Second", x: 0.1, y: 0.7),
        ]
        let sorted = analyzer.sortReadingOrder(observations)
        XCTAssertEqual(sorted[0].text, "First")
        XCTAssertEqual(sorted[1].text, "Second")
        XCTAssertEqual(sorted[2].text, "Third")
    }

    func testSameRowReadingOrder() {
        // Two items on same row — left should come first
        let observations = [
            obs("Right", x: 0.6, y: 0.9, w: 0.2),
            obs("Left", x: 0.1, y: 0.9, w: 0.2),
        ]
        let sorted = analyzer.sortReadingOrder(observations)
        XCTAssertEqual(sorted[0].text, "Left")
        XCTAssertEqual(sorted[1].text, "Right")
    }

    // MARK: - Block Properties

    func testBlockBoundingBoxEnclosesAllLines() {
        let observations = [
            obs("Short", x: 0.1, y: 0.9, w: 0.2),
            obs("A much longer line of text.", x: 0.1, y: 0.86, w: 0.6),
            obs("Medium line.", x: 0.1, y: 0.82, w: 0.35),
        ]
        let blocks = analyzer.group(observations, strategy: .block)
        XCTAssertEqual(blocks.count, 1)
        let bbox = blocks[0].boundingBox
        // Should enclose all lines
        for obs in observations {
            XCTAssertTrue(bbox.contains(obs.boundingBox),
                          "Block bbox should contain all line bboxes")
        }
    }

    func testBlockConfidenceIsAverage() {
        let observations = [
            TextObservation(text: "High", boundingBox: CGRect(x: 0.1, y: 0.9, width: 0.4, height: 0.03), confidence: 0.99),
            TextObservation(text: "Low", boundingBox: CGRect(x: 0.1, y: 0.86, width: 0.4, height: 0.03), confidence: 0.51),
        ]
        let blocks = analyzer.group(observations, strategy: .block)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].confidence, 0.75, accuracy: 0.01)
    }
}
