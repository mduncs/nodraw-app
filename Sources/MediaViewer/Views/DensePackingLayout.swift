import SwiftUI

// MARK: - DensePackingLayout

/// A dense bin-packing layout that fits items together like a jigsaw puzzle.
/// Items flow into available gaps rather than strict columns.
struct DensePackingLayout: Layout {
    var spacing: CGFloat = 8
    var rowHeight: CGFloat = 200  // Target row height - items scale to fit
    var maxScaleFactor: CGFloat = 1.5  // Prevent excessive upscaling of small images

    struct CacheData {
        var rows: [RowData] = []
        var totalHeight: CGFloat = 0
        // Cache validation - skip recalc if inputs unchanged
        var lastSubviewCount: Int = -1
        var lastContainerWidth: CGFloat = -1
        var lastRowHeight: CGFloat = -1
        var lastItemSignatures: [MasonryLayoutItemSignature] = []
    }

    struct RowData {
        var items: [(index: Int, width: CGFloat)]
        var y: CGFloat
        var height: CGFloat
        var totalWidth: CGFloat
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
            cache.rows = []
            cache.totalHeight = 0
            cache.lastItemSignatures = []
            return CGSize(width: containerWidth, height: 0)
        }
        let itemSignatures = subviews.map(\.masonryLayoutSignature)

        // CACHE VALIDATION: Skip expensive recalc if inputs unchanged
        // This prevents O(n) recalculation on every selection change
        if cache.lastSubviewCount == subviews.count,
           abs(cache.lastContainerWidth - containerWidth) < 1,
           abs(cache.lastRowHeight - rowHeight) < 1,
           cache.lastItemSignatures == itemSignatures,
           !cache.rows.isEmpty {
            return CGSize(width: containerWidth, height: cache.totalHeight)
        }

        // Build rows using justified flow algorithm
        // Each row fills the full width, items stretch proportionally
        var rows: [RowData] = []
        var currentRow: [(index: Int, width: CGFloat)] = []
        var currentRowWidth: CGFloat = 0

        for (index, signature) in itemSignatures.enumerated() {
            // Calculate item width at target row height
            let itemWidth = rowHeight * signature.aspectRatio

            // Check if item fits in current row
            let widthWithItem = currentRowWidth + itemWidth + (currentRow.isEmpty ? 0 : spacing)

            if widthWithItem > containerWidth && !currentRow.isEmpty {
                // Finalize current row (y will be calculated below with scaled heights)
                rows.append(RowData(
                    items: currentRow,
                    y: 0,  // Not used - placeSubviews calculates Y dynamically
                    height: rowHeight,
                    totalWidth: currentRowWidth
                ))
                currentRow = []
                currentRowWidth = 0
            }

            // Add item to current row
            currentRow.append((index: index, width: itemWidth))
            currentRowWidth += itemWidth + (currentRow.count > 1 ? spacing : 0)
        }

        // Don't forget the last row
        if !currentRow.isEmpty {
            rows.append(RowData(
                items: currentRow,
                y: 0,  // Not used - placeSubviews calculates Y dynamically
                height: rowHeight,
                totalWidth: currentRowWidth
            ))
        }

        cache.rows = rows
        cache.lastSubviewCount = subviews.count
        cache.lastContainerWidth = containerWidth
        cache.lastRowHeight = rowHeight
        cache.lastItemSignatures = itemSignatures

        // Calculate total height using SCALED row heights (must match placeSubviews logic)
        var totalHeight: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let totalItemWidth = row.items.reduce(0) { $0 + $1.width }
            let totalSpacing = spacing * CGFloat(row.items.count - 1)
            let availableForItems = containerWidth - totalSpacing
            // Cap scale to prevent excessive upscaling of small images
            let scale = min(availableForItems / totalItemWidth, maxScaleFactor)
            let scaledHeight = row.height * scale

            totalHeight += scaledHeight
            if index < rows.count - 1 {
                totalHeight += spacing
            }
        }

        cache.totalHeight = totalHeight

        return CGSize(width: containerWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout CacheData
    ) {
        let containerWidth = bounds.width

        // CRITICAL: Must recalculate Y positions using scaled heights.
        // The cached row.y values were calculated with unscaled rowHeight,
        // but each row's actual height depends on its scale factor.
        var currentY: CGFloat = bounds.minY

        for row in cache.rows {
            guard !row.items.isEmpty else { continue }

            // Calculate scale factor to justify row (fill full width)
            let totalItemWidth = row.items.reduce(0) { $0 + $1.width }
            let totalSpacing = spacing * CGFloat(row.items.count - 1)
            let availableForItems = containerWidth - totalSpacing
            // Cap scale to prevent excessive upscaling (matches sizeThatFits calculation)
            let scale = min(availableForItems / totalItemWidth, maxScaleFactor)

            // Scale row height proportionally
            let scaledHeight = row.height * scale

            var x: CGFloat = bounds.minX

            for (index, itemWidth) in row.items {
                guard index < subviews.count else { continue }

                let scaledWidth = itemWidth * scale

                subviews[index].place(
                    at: CGPoint(x: x, y: currentY),
                    proposal: ProposedViewSize(width: scaledWidth, height: scaledHeight)
                )

                x += scaledWidth + spacing
            }

            // Advance Y by the actual scaled height (not the cached row.y)
            currentY += scaledHeight + spacing
        }
    }
}

// MARK: - Preview

#if DEBUG
struct DensePackingLayout_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            DensePackingLayout(spacing: 4, rowHeight: 150) {
                ForEach(0..<30, id: \.self) { i in
                    let aspectRatios: [CGFloat] = [0.7, 1.0, 1.3, 1.5, 0.8, 1.2, 0.6, 1.8]
                    let ratio = aspectRatios[i % aspectRatios.count]

                    Rectangle()
                        .fill(Color(hue: Double(i) / 30, saturation: 0.7, brightness: 0.8))
                        .aspectRatio(ratio, contentMode: .fit)
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
