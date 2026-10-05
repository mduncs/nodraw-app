import Vision
import CoreGraphics
import CoreImage

/// Converts raster masks (CGImage) to vector contour paths (CGPath) using Vision's contour detection.
/// Used for generating glow animation paths around isolated subjects, and for vectorizing
/// flood fill / lasso selections into clean CGPaths.
public struct ContourTracer {

    public init() {}

    // MARK: - Contour Tracing

    /// Trace contours from a binary mask image.
    ///
    /// - Parameters:
    ///   - mask: Grayscale CGImage where white (1.0) = subject, black (0.0) = background.
    ///   - simplification: Polygon approximation epsilon. 0 = exact contour, higher = fewer points.
    /// - Returns: Tuple of (full contour including holes, outer contour without holes). Both nil if no contours found.
    public func traceContours(mask: CGImage, simplification: CGFloat) -> (full: CGPath?, outer: CGPath?) {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1.0
        request.detectsDarkOnLight = false

        let handler = VNImageRequestHandler(cgImage: mask, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return (nil, nil)
        }

        guard let observation = request.results?.first as? VNContoursObservation else {
            return (nil, nil)
        }

        guard observation.contourCount > 0 else {
            return (nil, nil)
        }

        // Full path: all contours including holes
        let fullPath: CGPath?
        if simplification > 0 {
            fullPath = simplifiedFullPath(from: observation, epsilon: simplification)
        } else {
            fullPath = observation.normalizedPath
        }

        // Outer path: top-level contours only (no holes)
        let outerPath = buildOuterPath(from: observation, simplification: simplification)

        return (fullPath, outerPath)
    }

    // MARK: - FloodFillResult Convenience

    /// Trace contours from a flood fill result.
    ///
    /// Converts the binary mask buffer to a CGImage, then runs contour detection.
    ///
    /// - Parameters:
    ///   - mask: FloodFillResult containing the binary mask.
    ///   - simplification: Polygon approximation epsilon. Default 0.005.
    /// - Returns: Tuple of (full contour including holes, outer contour without holes).
    public func traceContours(mask: FloodFillResult, simplification: CGFloat = 0.005) -> (full: CGPath?, outer: CGPath?) {
        guard let maskImage = mask.toCGImage() else { return (nil, nil) }
        return traceContours(mask: maskImage, simplification: simplification)
    }

    // MARK: - Bounding Box

    /// Compute the normalized bounding box of non-zero pixels in a mask.
    ///
    /// - Parameter mask: Grayscale CGImage.
    /// - Returns: Bounding box in normalized [0,1] coordinates. `.zero` if mask is empty.
    public func boundingBox(of mask: CGImage) -> CGRect {
        let ciImage = CIImage(cgImage: mask)
        let extent = ciImage.extent

        guard extent.width > 0, extent.height > 0 else {
            return .zero
        }

        let width = mask.width
        let height = mask.height

        guard width > 0, height > 0 else {
            return .zero
        }

        // Render to 8-bit grayscale buffer for pixel scanning
        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return .zero
        }

        context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        var found = false

        for y in 0..<height {
            let rowOffset = y * bytesPerRow
            for x in 0..<width {
                if pixels[rowOffset + x] > 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                    found = true
                }
            }
        }

        guard found else {
            return .zero
        }

        // Convert to normalized coordinates [0,1]
        // CGImage origin is top-left, Vision normalized coords are bottom-left
        let w = CGFloat(width)
        let h = CGFloat(height)

        return CGRect(
            x: CGFloat(minX) / w,
            y: 1.0 - CGFloat(maxY + 1) / h,
            width: CGFloat(maxX - minX + 1) / w,
            height: CGFloat(maxY - minY + 1) / h
        )
    }

    // MARK: - Private

    /// Build a CGPath containing only top-level contours (no holes).
    private func buildOuterPath(from observation: VNContoursObservation, simplification: CGFloat) -> CGPath? {
        let topLevel = observation.topLevelContours
        guard !topLevel.isEmpty else { return nil }

        let combined = CGMutablePath()

        for contour in topLevel {
            if simplification > 0 {
                if let simplified = try? contour.polygonApproximation(epsilon: Float(simplification)) {
                    combined.addPath(simplified.normalizedPath)
                } else {
                    combined.addPath(contour.normalizedPath)
                }
            } else {
                combined.addPath(contour.normalizedPath)
            }
        }

        return combined.isEmpty ? nil : combined
    }

    /// Build a simplified version of the full path (all contours with polygon approximation).
    private func simplifiedFullPath(from observation: VNContoursObservation, epsilon: CGFloat) -> CGPath? {
        let combined = CGMutablePath()
        let totalContours = observation.contourCount

        for i in 0..<totalContours {
            do {
                let contour = try observation.contour(at: i)
                let simplified = try contour.polygonApproximation(epsilon: Float(epsilon))
                combined.addPath(simplified.normalizedPath)
            } catch {
                continue
            }
        }

        return combined.isEmpty ? nil : combined
    }
}
