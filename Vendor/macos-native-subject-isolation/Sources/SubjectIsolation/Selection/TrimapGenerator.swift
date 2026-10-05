import CoreGraphics

/// Result of trimap generation — a 3-class pixel map.
public struct TrimapResult: @unchecked Sendable {
    /// Raw trimap data: 0x00 = background, 0x88 = unknown, 0xFF = foreground.
    public let data: [UInt8]
    public let width: Int
    public let height: Int

    public static let background: UInt8 = 0x00
    public static let unknown: UInt8 = 0x88
    public static let foreground: UInt8 = 0xFF

    /// Convert to CGImage for visualization or downstream processing.
    public func toCGImage() -> CGImage? {
        var pixels = data
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        return ctx.makeImage()
    }

    /// Whether the trimap has both foreground and unknown regions (required for matting).
    public var isValid: Bool {
        var hasForeground = false
        var hasUnknown = false
        for pixel in data {
            if pixel == Self.foreground { hasForeground = true }
            if pixel == Self.unknown { hasUnknown = true }
            if hasForeground && hasUnknown { return true }
        }
        return false
    }
}

/// Generates trimap (3-class segmentation map) from a selection path.
///
/// Algorithm from Ghidra RE of Preview.app's generateTrimap (§16):
/// 1. Create 8-bit grayscale context
/// 2. Fill black (background)
/// 3. Fill path with gray (unknown boundary)
/// 4. Stroke path with gray using round join/cap (expand boundary region)
/// 5. Fill inset path with white (definite foreground)
/// 6. Post-process: normalize all pixels to exactly 0x00, 0x88, or 0xFF
public struct TrimapGenerator {

    /// Width of the unknown boundary region in pixels.
    public var boundaryWidth: CGFloat

    /// - Parameter boundaryWidth: Width of the unknown/uncertain boundary region. Default 15px.
    public init(boundaryWidth: CGFloat = 15) {
        self.boundaryWidth = boundaryWidth
    }

    /// Generate a trimap from a selection path.
    ///
    /// - Parameters:
    ///   - path: Selection path in pixel coordinates (top-left origin).
    ///   - width: Output trimap width.
    ///   - height: Output trimap height.
    /// - Returns: TrimapResult, or nil if the context couldn't be created.
    public func generate(path: CGPath, width: Int, height: Int) -> TrimapResult? {
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Step 1: Fill entire context black (background)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Step 2: Fill path with unknown gray (0x88 ≈ 0.533)
        let unknownGray = CGFloat(TrimapResult.unknown) / 255.0
        ctx.setFillColor(gray: unknownGray, alpha: 1)
        ctx.addPath(path)
        ctx.fillPath()

        // Step 3: Stroke path with unknown gray — expands boundary outward
        // Round join/cap per RE findings
        ctx.setStrokeColor(gray: unknownGray, alpha: 1)
        ctx.setLineWidth(boundaryWidth * 2) // stroke extends both sides
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addPath(path)
        ctx.strokePath()

        // Step 4: Fill the interior (inset from boundary) as definite foreground
        // Create a slightly inset version by stroking then filling
        ctx.setFillColor(gray: 1.0, alpha: 1)
        ctx.addPath(path)
        ctx.fillPath()

        // Now we need to re-stroke the boundary to restore the unknown region
        ctx.setStrokeColor(gray: unknownGray, alpha: 1)
        ctx.setLineWidth(boundaryWidth)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.addPath(path)
        ctx.strokePath()

        // Step 5: Post-process — quantize to exactly 3 values
        for i in 0..<pixels.count {
            let val = pixels[i]
            if val > 0xC0 {
                pixels[i] = TrimapResult.foreground  // 0xFF
            } else if val > 0x40 {
                pixels[i] = TrimapResult.unknown     // 0x88
            } else {
                pixels[i] = TrimapResult.background  // 0x00
            }
        }

        let result = TrimapResult(data: pixels, width: width, height: height)

        // Validate: must have both foreground and unknown regions
        guard result.isValid else { return nil }

        return result
    }

    /// Generate a trimap from a binary mask image and its contour path.
    ///
    /// - Parameters:
    ///   - mask: Binary mask CGImage (white = foreground).
    ///   - contourPath: Path along the mask boundary (normalized [0,1] coordinates).
    /// - Returns: TrimapResult matching mask dimensions.
    public func generate(mask: CGImage, contourPath: CGPath) -> TrimapResult? {
        let width = mask.width
        let height = mask.height

        // Scale contour path from normalized [0,1] to pixel coords
        var transform = CGAffineTransform(scaleX: CGFloat(width), y: CGFloat(height))
        guard let scaledPath = contourPath.copy(using: &transform) else { return nil }

        return generate(path: scaledPath, width: width, height: height)
    }
}
