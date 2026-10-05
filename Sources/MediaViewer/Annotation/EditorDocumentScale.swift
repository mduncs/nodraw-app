import CoreGraphics

/// Stroke widths and font sizes are stored in source pixels. A 4 px default reads well on a
/// 1,600 px screenshot but nearly vanishes on a 6,000 px photo shown to fit, so the editor's
/// starting styles and control ranges follow the document's size. Stored shapes never change.
enum EditorDocumentScale {
    static let referenceDimension: CGFloat = 1_600

    /// 1 for screenshots and small images, rounded to half steps, at most 8 for huge sources.
    static func factor(for imageSize: CGSize) -> CGFloat {
        let longest = max(imageSize.width, imageSize.height)
        guard longest.isFinite, longest > 0 else { return 1 }
        return min(8, max(1, (longest / referenceDimension * 2).rounded() / 2))
    }

    static func scaled(_ style: ShapeStyle, by factor: CGFloat) -> ShapeStyle {
        var style = style
        style.strokeWidth = max(1, (style.strokeWidth * factor).rounded())
        return style
    }

    /// Outline width is a percentage of the font size, so only absolute distances scale.
    static func scaled(_ style: TextStyle, by factor: CGFloat) -> TextStyle {
        var style = style
        style.fontSize = min(1_000, (style.fontSize * factor).rounded())
        style.shadowRadius *= factor
        style.shadowOffset *= factor
        return style
    }

    static func range(_ range: ClosedRange<CGFloat>, by factor: CGFloat, limit: CGFloat = .greatestFiniteMagnitude) -> ClosedRange<CGFloat> {
        range.lowerBound...max(range.lowerBound + 1, min(limit, (range.upperBound * factor).rounded()))
    }
}
