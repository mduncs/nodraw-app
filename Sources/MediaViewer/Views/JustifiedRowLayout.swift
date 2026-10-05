import SwiftUI

// MARK: - JustifiedRowLayout

/// Justified row layout where items flow left to right.
/// Each row fills the full container width, scaling items proportionally
/// to maintain aspect ratios while sharing a uniform row height.
struct JustifiedRowLayout: Layout {
    var spacing: CGFloat = 8
    var rowHeight: CGFloat = 200

    struct CacheData {
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var totalHeight: CGFloat = 0
        // Cache validation
        var lastSubviewCount: Int = -1
        var lastContainerWidth: CGFloat = -1
        var lastRowHeight: CGFloat = -1
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
        let aspectRatios = itemSignatures.map(\.aspectRatio)

        // Cache validation - use 10px tolerance to avoid thrashing during animations
        // The debounced width handler in MasonryGrid ensures final accurate layout
        if cache.lastSubviewCount == subviews.count,
           abs(cache.lastContainerWidth - containerWidth) < 10,
           abs(cache.lastRowHeight - rowHeight) < 1,
           cache.lastItemSignatures == itemSignatures,
           !cache.positions.isEmpty {
            return CGSize(width: containerWidth, height: cache.totalHeight)
        }

        var positions: [CGPoint] = Array(repeating: .zero, count: subviews.count)
        var sizes: [CGSize] = Array(repeating: .zero, count: subviews.count)

        var currentY: CGFloat = 0
        var rowStartIndex = 0

        while rowStartIndex < subviews.count {
            // Find how many items fit in this row
            var rowEndIndex = rowStartIndex
            var totalAspectRatio: CGFloat = 0
            let availableWidth = containerWidth

            // Keep adding items until the row would be too short
            while rowEndIndex < subviews.count {
                let newTotalAspect = totalAspectRatio + aspectRatios[rowEndIndex]
                let itemCount = rowEndIndex - rowStartIndex + 1
                let totalSpacing = spacing * CGFloat(itemCount - 1)
                let scaledHeight = (availableWidth - totalSpacing) / newTotalAspect

                // If adding this item makes the row height too small, stop
                // (unless this is the first item in the row)
                if scaledHeight < rowHeight * 0.5 && rowEndIndex > rowStartIndex {
                    break
                }

                totalAspectRatio = newTotalAspect
                rowEndIndex += 1

                // If row is at or below target height, good enough
                if scaledHeight <= rowHeight {
                    break
                }
            }

            // Calculate actual row height
            let itemCount = rowEndIndex - rowStartIndex
            let totalSpacing = spacing * CGFloat(itemCount - 1)
            let actualRowHeight = (availableWidth - totalSpacing) / totalAspectRatio

            // Position items in this row
            var currentX: CGFloat = 0
            for i in rowStartIndex..<rowEndIndex {
                let itemWidth = actualRowHeight * aspectRatios[i]
                positions[i] = CGPoint(x: currentX, y: currentY)
                sizes[i] = CGSize(width: itemWidth, height: actualRowHeight)
                currentX += itemWidth + spacing
            }

            currentY += actualRowHeight + spacing
            rowStartIndex = rowEndIndex
        }

        let totalHeight = max(0, currentY - spacing)

        // Update cache
        cache.positions = positions
        cache.sizes = sizes
        cache.totalHeight = totalHeight
        cache.lastSubviewCount = subviews.count
        cache.lastContainerWidth = containerWidth
        cache.lastRowHeight = rowHeight
        cache.lastItemSignatures = itemSignatures

        return CGSize(width: containerWidth, height: totalHeight)
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
struct JustifiedRowLayout_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            JustifiedRowLayout(spacing: 8, rowHeight: 150) {
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
