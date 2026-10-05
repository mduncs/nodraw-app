import CoreGraphics
import AppKit

/// Path manipulation utilities for glow animation and coordinate transforms.
internal enum PathUtilities {

    /// Reverse a CGPath (glow traces backwards, per Apple's implementation).
    static func reversePath(_ path: CGPath) -> CGPath {
        let bezier = NSBezierPath(cgPath: path)
        return bezier.reversed.cgPath
    }

    /// Estimate path length by summing line segment distances.
    /// Approximates curves as straight lines to endpoints.
    /// Matches Apple's `vk_lengthIgnoringCurves` behavior.
    static func estimatePathLength(_ path: CGPath) -> CGFloat {
        var length: CGFloat = 0
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                current = points[0]
                subpathStart = current
            case .addLineToPoint:
                length += hypot(points[0].x - current.x, points[0].y - current.y)
                current = points[0]
            case .addQuadCurveToPoint:
                length += hypot(points[1].x - current.x, points[1].y - current.y)
                current = points[1]
            case .addCurveToPoint:
                length += hypot(points[2].x - current.x, points[2].y - current.y)
                current = points[2]
            case .closeSubpath:
                length += hypot(subpathStart.x - current.x, subpathStart.y - current.y)
                current = subpathStart
            @unknown default:
                break
            }
        }
        return length
    }

    /// Transform a path from normalized [0,1] coordinates to a target rect.
    static func transformPath(
        _ path: CGPath,
        fromNormalized: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        to targetRect: CGRect
    ) -> CGPath {
        var transform = CGAffineTransform.identity
        // Scale from normalized to target
        transform = transform.scaledBy(
            x: targetRect.width / fromNormalized.width,
            y: targetRect.height / fromNormalized.height
        )
        // Translate to target origin
        transform = transform.translatedBy(
            x: targetRect.origin.x / (targetRect.width / fromNormalized.width),
            y: targetRect.origin.y / (targetRect.height / fromNormalized.height)
        )
        return path.copy(using: &transform) ?? path
    }

    /// Transform a path from view coordinates through the layer's affine transform.
    /// Used for mapping between image space and layer space.
    static func transformPathForLayer(
        _ path: CGPath,
        imageSize: CGSize,
        layerBounds: CGRect
    ) -> CGPath {
        var transform = CGAffineTransform.identity
        transform = transform.scaledBy(
            x: layerBounds.width / imageSize.width,
            y: layerBounds.height / imageSize.height
        )
        return path.copy(using: &transform) ?? path
    }

    /// Estimate path length in view-space coordinates.
    /// Transforms the normalized path to the target rect first.
    static func estimatePathLength(_ path: CGPath, in rect: CGRect) -> CGFloat {
        let viewPath = transformPath(path, to: rect)
        return estimatePathLength(viewPath)
    }
}
