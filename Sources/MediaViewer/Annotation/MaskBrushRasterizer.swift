import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Bounded luminance masks for manual erase/restore strokes.
/// White is brush coverage, black is unaffected; document bounds stay the full source canvas.
enum MaskBrushRasterizer {
    static let maximumDimension = 2048

    static func image(points: [NormalizedPoint], sourceSize: CGSize, brushSize: CGFloat) -> CGImage? {
        guard !points.isEmpty, sourceSize.width.isFinite, sourceSize.height.isFinite,
              sourceSize.width > 0, sourceSize.height > 0,
              brushSize.isFinite, brushSize > 0,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let scale = min(1, CGFloat(maximumDimension) / max(sourceSize.width, sourceSize.height))
        let width = max(1, Int((sourceSize.width * scale).rounded()))
        let height = max(1, Int((sourceSize.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShouldAntialias(true)
        let diameter = brushSize * scale
        context.setLineWidth(diameter)
        func pixelPoint(_ point: NormalizedPoint) -> CGPoint {
            CGPoint(x: point.x * CGFloat(width), y: (1 - point.y) * CGFloat(height))
        }
        let first = pixelPoint(points[0])
        // A zero-length Core Graphics path need not paint; a click is explicitly one brush dab.
        context.fillEllipse(in: CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2,
                                       width: diameter, height: diameter))
        if points.count > 1 {
            context.beginPath()
            context.move(to: first)
            for point in points.dropFirst() { context.addLine(to: pixelPoint(point)) }
            context.strokePath()
        }
        return context.makeImage()
    }

    static func pngData(points: [NormalizedPoint], sourceSize: CGSize, brushSize: CGFloat) -> Data? {
        guard let image = image(points: points, sourceSize: sourceSize, brushSize: brushSize) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
