import SwiftUI

// MARK: - ColumnMasonryLayout

/// Pinterest-style column masonry layout.
/// Items flow into the shortest column, each item getting its natural height
/// based on its aspect ratio. Unlike justified rows, this preserves
/// each item's proportions without forcing uniform row heights.
struct ColumnMasonryLayout: Layout {
    var columnCount: Int = 5
    var spacing: CGFloat = 8

    struct CacheData {
        var columnAssignments: [Int] = []  // Which column each subview belongs to
        var positions: [CGPoint] = []       // Position for each subview
        var sizes: [CGSize] = []            // Size for each subview
        var totalHeight: CGFloat = 0
        // Cache validation
        var lastSubviewCount: Int = -1
        var lastContainerWidth: CGFloat = -1
        var lastColumnCount: Int = -1
        var lastItemSignatures: [MasonryLayoutItemSignature] = []
    }

    func makeCache(subviews: Subviews) -> CacheData {
        CacheData()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout CacheData
    ) -> CGSize {
        let containerWidth = proposal.width ?? 800
        guard !subviews.isEmpty else {
            return CGSize(width: containerWidth, height: 0)
        }
        let itemSignatures = subviews.map(\.masonryLayoutSignature)

        // Cache validation - use 10px tolerance to avoid thrashing during animations
        // The debounced width handler in MasonryGrid ensures final accurate layout
        if cache.lastSubviewCount == subviews.count,
           abs(cache.lastContainerWidth - containerWidth) < 10,
           cache.lastColumnCount == columnCount,
           cache.lastItemSignatures == itemSignatures,
           !cache.positions.isEmpty {
            return CGSize(width: containerWidth, height: cache.totalHeight)
        }

        // Cache miss - log expensive layout calculation
        let token = PerfLog.begin("sizeThatFits", category: .layout, context: "\(subviews.count) views, \(columnCount) cols")
        defer { PerfLog.end(token) }

        // Calculate column width
        let totalSpacing = spacing * CGFloat(columnCount - 1)
        let columnWidth = (containerWidth - totalSpacing) / CGFloat(columnCount)

        // Track height of each column
        var columnHeights = Array(repeating: CGFloat(0), count: columnCount)
        var assignments: [Int] = []
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []

        for signature in itemSignatures {
            // Find shortest column
            let shortestColumn = columnHeights.enumerated()
                .min(by: { $0.element < $1.element })?
                .offset ?? 0

            // Calculate item height based on column width and aspect ratio
            let itemHeight = columnWidth / signature.aspectRatio

            // Calculate position
            let x = CGFloat(shortestColumn) * (columnWidth + spacing)
            let y = columnHeights[shortestColumn]

            assignments.append(shortestColumn)
            positions.append(CGPoint(x: x, y: y))
            sizes.append(CGSize(width: columnWidth, height: itemHeight))

            // Update column height
            columnHeights[shortestColumn] += itemHeight + spacing
        }

        // Total height is the tallest column (minus trailing spacing)
        let maxHeight = (columnHeights.max() ?? 0) - spacing

        // Update cache
        cache.columnAssignments = assignments
        cache.positions = positions
        cache.sizes = sizes
        cache.totalHeight = max(0, maxHeight)
        cache.lastSubviewCount = subviews.count
        cache.lastContainerWidth = containerWidth
        cache.lastColumnCount = columnCount
        cache.lastItemSignatures = itemSignatures

        return CGSize(width: containerWidth, height: cache.totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout CacheData
    ) {
        for (index, subview) in subviews.enumerated() {
            guard index < cache.positions.count, index < cache.sizes.count else { continue }

            let position = cache.positions[index]
            let size = cache.sizes[index]

            subview.place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ColumnMasonryLayout_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            ColumnMasonryLayout(columnCount: 4, spacing: 8) {
                ForEach(0..<30, id: \.self) { i in
                    let aspectRatios: [CGFloat] = [0.5, 0.7, 1.0, 1.3, 1.5, 0.8, 1.2, 0.6, 1.8, 0.45]
                    let ratio = aspectRatios[i % aspectRatios.count]

                    Rectangle()
                        .fill(Color(hue: Double(i) / 30, saturation: 0.7, brightness: 0.8))
                        .frame(idealWidth: 100 * ratio, idealHeight: 100)
                        .overlay(Text("\(i)").foregroundColor(.white))
                }
            }
            .padding(8)
        }
        .frame(width: 600, height: 800)
        .background(Color.black)
    }
}
#endif
