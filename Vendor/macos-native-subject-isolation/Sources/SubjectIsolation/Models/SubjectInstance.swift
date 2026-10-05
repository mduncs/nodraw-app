import CoreGraphics
import CoreImage
import AppKit

/// A single isolated subject with its mask and contour path.
public struct SubjectInstance: @unchecked Sendable {
    /// Instance index from VNInstanceMaskObservation.
    public let index: Int
    /// Alpha mask for this subject (grayscale CGImage, white = subject).
    public let mask: CGImage
    /// Bounding box in normalized [0,1] coordinates.
    public let boundingBox: CGRect
    /// Full contour path in normalized coordinates. nil if paths not requested.
    public let contourPath: CGPath?
    /// Simplified outer contour (no holes). nil if paths not requested.
    public let outerContourPath: CGPath?

    public init(
        index: Int,
        mask: CGImage,
        boundingBox: CGRect,
        contourPath: CGPath?,
        outerContourPath: CGPath?
    ) {
        self.index = index
        self.mask = mask
        self.boundingBox = boundingBox
        self.contourPath = contourPath
        self.outerContourPath = outerContourPath
    }

    /// Apply this subject's mask to an image, returning subject on transparent background.
    /// Returns nil if mask application fails (e.g. degenerate image).
    public func cutout(from image: CGImage) -> CGImage? {
        MaskProcessor.shared.applyMask(image: image, mask: mask)
    }

    /// Contour as NSBezierPath (convenience for AppKit).
    public var bezierPath: NSBezierPath? {
        guard let contourPath else { return nil }
        return NSBezierPath(cgPath: contourPath)
    }

    /// Outer contour as NSBezierPath.
    public var outerBezierPath: NSBezierPath? {
        guard let outerContourPath else { return nil }
        return NSBezierPath(cgPath: outerContourPath)
    }
}

/// NSBezierPath extension for CGPath conversion (macOS 14+).
extension NSBezierPath {
    convenience init(cgPath: CGPath) {
        self.init()
        cgPath.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                self.move(to: points[0])
            case .addLineToPoint:
                self.line(to: points[0])
            case .addQuadCurveToPoint:
                // Approximate quad curve as cubic
                let current = self.currentPoint
                let cp1 = CGPoint(
                    x: current.x + 2.0/3.0 * (points[0].x - current.x),
                    y: current.y + 2.0/3.0 * (points[0].y - current.y)
                )
                let cp2 = CGPoint(
                    x: points[1].x + 2.0/3.0 * (points[0].x - points[1].x),
                    y: points[1].y + 2.0/3.0 * (points[0].y - points[1].y)
                )
                self.curve(to: points[1], controlPoint1: cp1, controlPoint2: cp2)
            case .addCurveToPoint:
                self.curve(to: points[2], controlPoint1: points[0], controlPoint2: points[1])
            case .closeSubpath:
                self.close()
            @unknown default:
                break
            }
        }
    }
}
