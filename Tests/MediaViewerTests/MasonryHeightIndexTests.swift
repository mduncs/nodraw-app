import XCTest
@testable import MediaViewer

/// Tests for MasonryHeightIndex - O(log n) scroll-to-index lookup for variable-height masonry.
@MainActor
final class MasonryHeightIndexTests: XCTestCase {

    // MARK: - Setup

    private var sut: MasonryHeightIndex!

    override func setUp() async throws {
        sut = MasonryHeightIndex(columnCount: 4, spacing: 8, columnWidth: 200)
    }

    override func tearDown() async throws {
        sut = nil
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        XCTAssertEqual(sut.columnCount, 4)
        XCTAssertEqual(sut.spacing, 8)
        XCTAssertEqual(sut.columnWidth, 200)
        XCTAssertEqual(sut.itemCount, 0)
        XCTAssertEqual(sut.maxColumnHeight, 0)
    }

    func testInitializationWithDifferentConfig() {
        let index = MasonryHeightIndex(columnCount: 6, spacing: 12, columnWidth: 150)
        XCTAssertEqual(index.columnCount, 6)
        XCTAssertEqual(index.spacing, 12)
        XCTAssertEqual(index.columnWidth, 150)
    }

    func testInitializationClampsColumnCount() {
        let index = MasonryHeightIndex(columnCount: 0, spacing: 8, columnWidth: 200)
        XCTAssertEqual(index.columnCount, 1, "Column count should be clamped to minimum 1")
    }

    // MARK: - Append Tests

    func testAppendSingleItem() {
        let id = UUID()
        let column = sut.appendItem(id: id, height: 100)

        XCTAssertEqual(sut.itemCount, 1)
        XCTAssertTrue(column >= 0 && column < 4)

        let assignment = sut.assignment(for: id)
        XCTAssertNotNil(assignment)
        XCTAssertEqual(assignment?.column, column)
        XCTAssertEqual(assignment?.index, 0)
    }

    func testAppendMultipleItemsDistributesToShortestColumn() {
        // Add items that should fill columns evenly
        var ids: [UUID] = []
        for _ in 0..<8 {
            let id = UUID()
            ids.append(id)
            sut.appendItem(id: id, height: 100)
        }

        XCTAssertEqual(sut.itemCount, 8)

        // With 4 columns and 8 equal-height items, each column should have 2 items
        let itemsPerColumn = sut.itemsPerColumn
        XCTAssertEqual(itemsPerColumn.count, 4)
        for count in itemsPerColumn {
            XCTAssertEqual(count, 2)
        }
    }

    func testAppendWithAspectRatio() {
        let id = UUID()
        // Aspect ratio 2.0 with columnWidth 200 = height 100
        let column = sut.appendItem(id: id, aspectRatio: 2.0)

        XCTAssertEqual(sut.itemCount, 1)
        XCTAssertTrue(column >= 0 && column < 4)
    }

    func testAppendClampsAspectRatio() {
        let id1 = UUID()
        let id2 = UUID()

        // Very low aspect ratio should clamp to 0.4
        sut.appendItem(id: id1, aspectRatio: 0.1)
        // Very high aspect ratio should clamp to 2.5
        sut.appendItem(id: id2, aspectRatio: 10.0)

        XCTAssertEqual(sut.itemCount, 2)
    }

    func testAppendToShortestColumn() {
        // Add tall item to column 0
        let id1 = UUID()
        sut.appendItem(id: id1, height: 500)

        // Next items should avoid column 0
        var columns: [Int] = []
        for _ in 0..<3 {
            let id = UUID()
            let col = sut.appendItem(id: id, height: 100)
            columns.append(col)
        }

        // Column 0 should not receive any more items until others catch up
        for col in columns {
            XCTAssertNotEqual(col, 0, "Items should go to shorter columns first")
        }
    }

    // MARK: - Binary Search Tests

    func testBinarySearchEmptyColumn() {
        let index = sut.itemIndex(forScrollOffset: 100, inColumn: 0)
        XCTAssertEqual(index, 0)
    }

    func testBinarySearchSingleItem() {
        let id = UUID()
        let column = sut.appendItem(id: id, height: 100)

        // Offset within item should return 0
        let index = sut.itemIndex(forScrollOffset: 50, inColumn: column)
        XCTAssertEqual(index, 0)
    }

    func testBinarySearchMultipleItems() {
        // Add 10 items of height 100 + 8 spacing = 108 each to column 0
        let index = MasonryHeightIndex(columnCount: 1, spacing: 8, columnWidth: 200)
        var ids: [UUID] = []
        for _ in 0..<10 {
            let id = UUID()
            ids.append(id)
            index.appendItem(id: id, height: 100)
        }

        // Item 0: 0 to 108
        XCTAssertEqual(index.itemIndex(forScrollOffset: 0, inColumn: 0), 0)
        XCTAssertEqual(index.itemIndex(forScrollOffset: 50, inColumn: 0), 0)
        XCTAssertEqual(index.itemIndex(forScrollOffset: 107, inColumn: 0), 0)

        // Item 1: 108 to 216
        XCTAssertEqual(index.itemIndex(forScrollOffset: 108, inColumn: 0), 1)
        XCTAssertEqual(index.itemIndex(forScrollOffset: 150, inColumn: 0), 1)

        // Item 5: 540 to 648
        XCTAssertEqual(index.itemIndex(forScrollOffset: 540, inColumn: 0), 5)
        XCTAssertEqual(index.itemIndex(forScrollOffset: 600, inColumn: 0), 5)

        // Item 9: 972 to 1080
        XCTAssertEqual(index.itemIndex(forScrollOffset: 972, inColumn: 0), 9)
        XCTAssertEqual(index.itemIndex(forScrollOffset: 1000, inColumn: 0), 9)
    }

    func testBinarySearchWithVariableHeights() {
        let index = MasonryHeightIndex(columnCount: 1, spacing: 8, columnWidth: 200)

        // Add items with different heights
        let heights: [CGFloat] = [50, 100, 200, 75, 150]
        var ids: [UUID] = []
        for height in heights {
            let id = UUID()
            ids.append(id)
            index.appendItem(id: id, height: height)
        }

        // Calculate cumulative positions (with 8 spacing)
        // Item 0: 0 to 58 (50 + 8)
        // Item 1: 58 to 166 (100 + 8)
        // Item 2: 166 to 374 (200 + 8)
        // Item 3: 374 to 457 (75 + 8)
        // Item 4: 457 to 615 (150 + 8)

        XCTAssertEqual(index.itemIndex(forScrollOffset: 0, inColumn: 0), 0)
        XCTAssertEqual(index.itemIndex(forScrollOffset: 57, inColumn: 0), 0)
        XCTAssertEqual(index.itemIndex(forScrollOffset: 58, inColumn: 0), 1)
        XCTAssertEqual(index.itemIndex(forScrollOffset: 165, inColumn: 0), 1)
        XCTAssertEqual(index.itemIndex(forScrollOffset: 166, inColumn: 0), 2)
        XCTAssertEqual(index.itemIndex(forScrollOffset: 300, inColumn: 0), 2)
        XCTAssertEqual(index.itemIndex(forScrollOffset: 374, inColumn: 0), 3)
        XCTAssertEqual(index.itemIndex(forScrollOffset: 457, inColumn: 0), 4)
    }

    func testBinarySearchBeyondEnd() {
        let index = MasonryHeightIndex(columnCount: 1, spacing: 8, columnWidth: 200)
        for _ in 0..<5 {
            index.appendItem(id: UUID(), height: 100)
        }

        // Offset way beyond content should return last item
        let result = index.itemIndex(forScrollOffset: 10000, inColumn: 0)
        XCTAssertEqual(result, 4)
    }

    func testBinarySearchInvalidColumn() {
        sut.appendItem(id: UUID(), height: 100)

        XCTAssertEqual(sut.itemIndex(forScrollOffset: 50, inColumn: -1), 0)
        XCTAssertEqual(sut.itemIndex(forScrollOffset: 50, inColumn: 100), 0)
    }

    // MARK: - First Visible Item Tests

    func testFirstVisibleItemEmpty() {
        let result = sut.firstVisibleItem(forScrollOffset: 0)
        XCTAssertNil(result)
    }

    func testFirstVisibleItemSingleColumn() {
        let index = MasonryHeightIndex(columnCount: 1, spacing: 8, columnWidth: 200)
        for _ in 0..<5 {
            index.appendItem(id: UUID(), height: 100)
        }

        let result = index.firstVisibleItem(forScrollOffset: 250)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.column, 0)
        XCTAssertEqual(result?.index, 2)
    }

    func testFirstVisibleItemMultipleColumns() {
        // Add items with different heights to create offset columns
        for i in 0..<12 {
            let height: CGFloat = i % 2 == 0 ? 100 : 200
            sut.appendItem(id: UUID(), height: height)
        }

        // First visible should be from the column with smallest Y at offset
        let result = sut.firstVisibleItem(forScrollOffset: 100)
        XCTAssertNotNil(result)
    }

    // MARK: - Y Position Tests

    func testYPositionFirstItem() {
        let id = UUID()
        let column = sut.appendItem(id: id, height: 100)

        let y = sut.yPosition(column: column, index: 0)
        XCTAssertEqual(y, 0)
    }

    func testYPositionSubsequentItems() {
        let index = MasonryHeightIndex(columnCount: 1, spacing: 8, columnWidth: 200)
        for _ in 0..<3 {
            index.appendItem(id: UUID(), height: 100)
        }

        XCTAssertEqual(index.yPosition(column: 0, index: 0), 0)
        XCTAssertEqual(index.yPosition(column: 0, index: 1), 108)  // 100 + 8
        XCTAssertEqual(index.yPosition(column: 0, index: 2), 216)  // 2 * 108
    }

    func testYPositionInvalidIndices() {
        sut.appendItem(id: UUID(), height: 100)

        XCTAssertNil(sut.yPosition(column: -1, index: 0))
        XCTAssertNil(sut.yPosition(column: 100, index: 0))
        XCTAssertNil(sut.yPosition(column: 0, index: 100))
    }

    // MARK: - Assignment Cache Tests

    func testAssignmentForUnknownId() {
        let result = sut.assignment(for: UUID())
        XCTAssertNil(result)
    }

    func testAssignmentForKnownId() {
        let id = UUID()
        let column = sut.appendItem(id: id, height: 100)

        let assignment = sut.assignment(for: id)
        XCTAssertNotNil(assignment)
        XCTAssertEqual(assignment?.column, column)
        XCTAssertEqual(assignment?.index, 0)
    }

    func testAssignmentAfterMultipleAppends() {
        var ids: [UUID] = []
        for _ in 0..<20 {
            let id = UUID()
            ids.append(id)
            sut.appendItem(id: id, height: 100)
        }

        // All IDs should have valid assignments
        for id in ids {
            let assignment = sut.assignment(for: id)
            XCTAssertNotNil(assignment)
            XCTAssertTrue(assignment!.column >= 0 && assignment!.column < 4)
            XCTAssertTrue(assignment!.index >= 0)
        }
    }

    // MARK: - Rebuild Tests

    func testRebuild() {
        // Add some items
        for _ in 0..<10 {
            sut.appendItem(id: UUID(), height: 100)
        }
        XCTAssertEqual(sut.itemCount, 10)

        // Rebuild with new items
        let newItems = (0..<5).map { _ in (id: UUID(), aspectRatio: CGFloat(1.5)) }
        sut.rebuild(items: newItems, columnCount: 3, columnWidth: 180)

        XCTAssertEqual(sut.itemCount, 5)
        XCTAssertEqual(sut.columnCount, 3)
        XCTAssertEqual(sut.columnWidth, 180)
    }

    func testAsyncRebuild() async {
        // Add initial items
        for _ in 0..<10 {
            sut.appendItem(id: UUID(), height: 100)
        }

        // Create large item set for async rebuild
        let largeItemSet = (0..<5000).map { _ in (id: UUID(), aspectRatio: CGFloat.random(in: 0.5...2.0)) }

        await sut.rebuildAsync(items: largeItemSet, columnCount: 5, columnWidth: 220)

        XCTAssertEqual(sut.itemCount, 5000)
        XCTAssertEqual(sut.columnCount, 5)
        XCTAssertEqual(sut.columnWidth, 220)
    }

    // MARK: - Clear Tests

    func testClear() {
        let id = UUID()
        sut.appendItem(id: id, height: 100)
        XCTAssertEqual(sut.itemCount, 1)

        sut.clear()

        XCTAssertEqual(sut.itemCount, 0)
        XCTAssertEqual(sut.maxColumnHeight, 0)
        XCTAssertNil(sut.assignment(for: id))
    }

    // MARK: - Stats Tests

    func testMaxColumnHeight() {
        let index = MasonryHeightIndex(columnCount: 2, spacing: 8, columnWidth: 200)

        // Add tall item to one column
        index.appendItem(id: UUID(), height: 500)
        // Add short item to other column
        index.appendItem(id: UUID(), height: 100)

        // Max height should be from the tall column (500 + 8)
        XCTAssertEqual(index.maxColumnHeight, 508)
    }

    func testItemsPerColumn() {
        // Add 10 items with same height - should distribute evenly
        for _ in 0..<8 {
            sut.appendItem(id: UUID(), height: 100)
        }

        let perColumn = sut.itemsPerColumn
        XCTAssertEqual(perColumn.count, 4)

        // With equal heights, should be evenly distributed
        for count in perColumn {
            XCTAssertEqual(count, 2)
        }
    }

    // MARK: - Performance Tests

    func testPerformanceAppend10000Items() {
        let index = MasonryHeightIndex(columnCount: 5, spacing: 8, columnWidth: 200)

        measure {
            for _ in 0..<10000 {
                index.appendItem(id: UUID(), aspectRatio: CGFloat.random(in: 0.5...2.0))
            }
            index.clear()
        }
    }

    func testPerformanceBinarySearch() {
        let index = MasonryHeightIndex(columnCount: 1, spacing: 8, columnWidth: 200)

        // Populate with 10000 items
        for _ in 0..<10000 {
            index.appendItem(id: UUID(), height: CGFloat.random(in: 50...300))
        }

        let maxHeight = index.maxColumnHeight

        measure {
            for _ in 0..<10000 {
                let offset = CGFloat.random(in: 0...maxHeight)
                _ = index.itemIndex(forScrollOffset: offset, inColumn: 0)
            }
        }
    }
}
