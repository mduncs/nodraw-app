import Foundation

// MARK: - MasonryHeightIndex

/// O(log n) scroll-to-index lookup for variable-height masonry grids.
/// Maintains per-column cumulative heights for binary search.
/// Thread-safe via @MainActor isolation.
@MainActor
final class MasonryHeightIndex {

    // MARK: - Types

    /// Column assignment for an item
    struct ColumnAssignment {
        let column: Int
        let index: Int  // Index within the column
    }

    // MARK: - Configuration

    /// Spacing between items
    let spacing: CGFloat

    /// Column width for height calculations
    private(set) var columnWidth: CGFloat = 200

    /// Number of columns
    private(set) var columnCount: Int = 4

    // MARK: - State

    /// Per-column cumulative heights.
    /// cumulativeHeights[col][i] = total height from top through item i (inclusive).
    private var cumulativeHeights: [[CGFloat]] = []

    /// Stable ID cache for O(1) column lookup.
    /// Maps item ID -> (column, index within column).
    private var columnAssignments: [UUID: ColumnAssignment] = [:]

    /// Current column heights (last cumulative value per column).
    /// Used for shortest-column-first assignment.
    private var columnTotals: [CGFloat] = []

    // MARK: - Initialization

    init(columnCount: Int = 4, spacing: CGFloat = 8, columnWidth: CGFloat = 200) {
        self.columnCount = max(1, columnCount)
        self.spacing = spacing
        self.columnWidth = columnWidth
        initializeColumns()
    }

    private func initializeColumns() {
        cumulativeHeights = Array(repeating: [], count: columnCount)
        columnTotals = Array(repeating: 0, count: columnCount)
    }

    // MARK: - Public API

    /// Binary search for item index at scroll offset within a column.
    /// Returns the index of the item whose top edge is at or just above the offset.
    /// - Parameters:
    ///   - y: Scroll offset (positive, measured from top)
    ///   - col: Column index
    /// - Returns: Item index within the column, or 0 if column is empty
    func itemIndex(forScrollOffset y: CGFloat, inColumn col: Int) -> Int {
        guard col >= 0, col < cumulativeHeights.count else { return 0 }
        let heights = cumulativeHeights[col]
        guard !heights.isEmpty else { return 0 }

        // Binary search for the item whose cumulative height contains y
        var lo = 0
        var hi = heights.count - 1

        while lo <= hi {
            let mid = (lo + hi) / 2
            let top = mid > 0 ? heights[mid - 1] : 0
            let bottom = heights[mid]

            if y >= top && y < bottom {
                return mid
            } else if y < top {
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }

        // Clamp to valid range
        return max(0, min(lo, heights.count - 1))
    }

    /// Find the first visible item across all columns for a scroll offset.
    /// - Parameter y: Scroll offset
    /// - Returns: (column, indexInColumn) of the first visible item
    func firstVisibleItem(forScrollOffset y: CGFloat) -> (column: Int, index: Int)? {
        guard columnCount > 0 else { return nil }

        var firstVisible: (column: Int, index: Int, topY: CGFloat)?

        for col in 0..<columnCount {
            guard !cumulativeHeights[col].isEmpty else { continue }
            let idx = itemIndex(forScrollOffset: y, inColumn: col)
            let topY = idx > 0 ? cumulativeHeights[col][idx - 1] : 0

            if firstVisible == nil || topY < firstVisible!.topY {
                firstVisible = (col, idx, topY)
            }
        }

        return firstVisible.map { ($0.column, $0.index) }
    }

    /// Get the Y position (top edge) of an item.
    /// - Parameters:
    ///   - column: Column index
    ///   - index: Item index within column
    /// - Returns: Y position from top, or nil if invalid
    func yPosition(column: Int, index: Int) -> CGFloat? {
        guard column >= 0, column < cumulativeHeights.count else { return nil }
        guard index >= 0, index < cumulativeHeights[column].count else { return nil }

        return index > 0 ? cumulativeHeights[column][index - 1] : 0
    }

    /// Get the column assignment for an item by ID.
    /// - Parameter id: Item UUID
    /// - Returns: Column assignment, or nil if not found
    func assignment(for id: UUID) -> ColumnAssignment? {
        columnAssignments[id]
    }

    /// O(1) append - adds an item to the shortest column.
    /// - Parameters:
    ///   - id: Item UUID (for stable lookup cache)
    ///   - height: Item height in points
    /// - Returns: The column index where the item was placed
    @discardableResult
    func appendItem(id: UUID, height: CGFloat) -> Int {
        // Find shortest column
        let shortestCol = columnTotals.enumerated()
            .min(by: { $0.element < $1.element })?.offset ?? 0

        // Calculate new cumulative height
        let prevY = columnTotals[shortestCol]
        let newY = prevY + height + spacing

        // Update structures
        cumulativeHeights[shortestCol].append(newY)
        columnTotals[shortestCol] = newY

        let indexInColumn = cumulativeHeights[shortestCol].count - 1
        columnAssignments[id] = ColumnAssignment(column: shortestCol, index: indexInColumn)

        return shortestCol
    }

    /// Append an item with a known aspect ratio.
    /// Calculates height from columnWidth and aspect ratio.
    /// - Parameters:
    ///   - id: Item UUID
    ///   - aspectRatio: Width/height ratio (clamped to 0.4...2.5)
    /// - Returns: The column index where the item was placed
    @discardableResult
    func appendItem(id: UUID, aspectRatio: CGFloat) -> Int {
        let clampedRatio = max(0.4, min(2.5, aspectRatio))
        let height = columnWidth / clampedRatio
        return appendItem(id: id, height: height)
    }

    /// Rebuild the index from scratch for a new set of items.
    /// Use when column count changes or for initial population.
    /// - Parameters:
    ///   - items: Array of (id, aspectRatio) tuples
    ///   - columnCount: Number of columns
    ///   - columnWidth: Width per column
    func rebuild(items: [(id: UUID, aspectRatio: CGFloat)], columnCount: Int, columnWidth: CGFloat) {
        self.columnCount = max(1, columnCount)
        self.columnWidth = columnWidth

        // Reset state
        cumulativeHeights = Array(repeating: [], count: self.columnCount)
        columnTotals = Array(repeating: 0, count: self.columnCount)
        columnAssignments.removeAll(keepingCapacity: true)

        // Rebuild
        for (id, aspectRatio) in items {
            appendItem(id: id, aspectRatio: aspectRatio)
        }
    }

    /// Async rebuild for large item sets.
    /// Runs the computation in batches to allow UI responsiveness.
    func rebuildAsync(items: [(id: UUID, aspectRatio: CGFloat)], columnCount: Int, columnWidth: CGFloat) async {
        let newColumnCount = max(1, columnCount)

        // Update config
        self.columnCount = newColumnCount
        self.columnWidth = columnWidth

        // Reset state
        cumulativeHeights = Array(repeating: [], count: newColumnCount)
        columnTotals = Array(repeating: 0, count: newColumnCount)
        columnAssignments.removeAll(keepingCapacity: true)

        // Process in batches to allow UI updates
        let batchSize = 1000
        for batchStart in stride(from: 0, to: items.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, items.count)
            for i in batchStart..<batchEnd {
                let (id, aspectRatio) = items[i]
                appendItem(id: id, aspectRatio: aspectRatio)
            }
            // Yield to allow other tasks
            if batchEnd < items.count {
                await Task.yield()
            }
        }
    }

    /// Clear all data
    func clear() {
        cumulativeHeights = Array(repeating: [], count: columnCount)
        columnTotals = Array(repeating: 0, count: columnCount)
        columnAssignments.removeAll()
    }

    /// Update configuration without rebuilding.
    /// Call rebuild() after this if items exist.
    func updateConfiguration(columnCount: Int, columnWidth: CGFloat) {
        self.columnCount = max(1, columnCount)
        self.columnWidth = columnWidth
    }

    // MARK: - Stats

    /// Total number of items indexed
    var itemCount: Int {
        cumulativeHeights.reduce(0) { $0 + $1.count }
    }

    /// Maximum column height (for scroll content size)
    var maxColumnHeight: CGFloat {
        columnTotals.max() ?? 0
    }

    /// Items per column (for debugging/stats)
    var itemsPerColumn: [Int] {
        cumulativeHeights.map(\.count)
    }

    /// Column heights (for debugging/stats)
    var currentColumnHeights: [CGFloat] {
        columnTotals
    }
}
