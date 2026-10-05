import SwiftUI

// MARK: - Masonry Layout Metadata

struct MasonryLayoutItemSignature: Equatable {
    let id: UUID?
    let aspectRatio: CGFloat
}

struct MasonryLayoutAspectRatioKey: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

struct MasonryLayoutItemIDKey: LayoutValueKey {
    static let defaultValue: UUID? = nil
}

extension View {
    /// Supplies lightweight layout inputs directly to custom masonry layouts.
    /// This avoids asking SwiftUI to measure the full cell subtree just to recover
    /// an aspect ratio from an ideal frame.
    func masonryLayoutMetadata(id: UUID?, aspectRatio: CGFloat) -> some View {
        layoutValue(key: MasonryLayoutItemIDKey.self, value: id)
            .layoutValue(
                key: MasonryLayoutAspectRatioKey.self,
                value: Self.clampedMasonryAspectRatio(aspectRatio)
            )
    }

    private static func clampedMasonryAspectRatio(_ aspectRatio: CGFloat) -> CGFloat {
        guard aspectRatio.isFinite, aspectRatio > 0 else { return 1 }
        return max(0.4, min(2.5, aspectRatio))
    }
}

extension LayoutSubview {
    var masonryLayoutAspectRatio: CGFloat {
        if let suppliedAspectRatio = self[MasonryLayoutAspectRatioKey.self] {
            return Self.clampedMasonryAspectRatio(suppliedAspectRatio)
        }

        let idealSize = sizeThatFits(.unspecified)
        let measuredAspectRatio = idealSize.width / max(idealSize.height, 1)
        return Self.clampedMasonryAspectRatio(measuredAspectRatio)
    }

    var masonryLayoutSignature: MasonryLayoutItemSignature {
        MasonryLayoutItemSignature(
            id: self[MasonryLayoutItemIDKey.self],
            aspectRatio: masonryLayoutAspectRatio
        )
    }

    private static func clampedMasonryAspectRatio(_ aspectRatio: CGFloat) -> CGFloat {
        guard aspectRatio.isFinite, aspectRatio > 0 else { return 1 }
        return max(0.4, min(2.5, aspectRatio))
    }
}
