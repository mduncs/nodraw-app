import CoreGraphics
import CoreImage
import CoreVideo

/// Handles CVPixelBuffer/CGImage conversion and mask compositing operations.
/// Used internally by SubjectInstance.cutout and IsolationResult construction.
internal struct MaskProcessor {
    static let shared = MaskProcessor()

    /// GPU-accelerated CIContext, reused across all operations.
    let ciContext: CIContext

    private init() {
        // Prefer Metal for GPU acceleration; falls back to software if unavailable.
        self.ciContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false,
        ])
    }

    // MARK: - Pixel Buffer Conversion

    /// Convert a CVPixelBuffer (e.g. from VNInstanceMaskObservation) to CGImage.
    func pixelBufferToCGImage(_ buffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }

    // MARK: - Mask Application

    /// Apply a grayscale mask to an image, producing subject on transparent background.
    /// Mask is scaled to match image dimensions if they differ.
    /// Returns nil if filter creation or rendering fails (e.g. degenerate image dimensions).
    func applyMask(image: CGImage, mask: CGImage) -> CGImage? {
        let ciImage = CIImage(cgImage: image)
        let ciMask = CIImage(cgImage: mask)
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(image.width) / CGFloat(mask.width),
                y: CGFloat(image.height) / CGFloat(mask.height)
            ))

        guard let filter = CIFilter(name: "CIBlendWithMask") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        filter.setValue(ciMask, forKey: kCIInputMaskImageKey)

        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: ciImage.extent)
    }

    // MARK: - Mask Combination

    /// Merge multiple masks via logical max (OR). Returns nil if array is empty.
    /// All masks are scaled to the dimensions of the first mask before combining.
    func combineMasks(_ masks: [CGImage]) -> CGImage? {
        guard let first = masks.first else { return nil }
        if masks.count == 1 { return first }

        let targetSize = CGSize(width: first.width, height: first.height)
        var combined = CIImage(cgImage: first)

        for mask in masks.dropFirst() {
            let scaled = CIImage(cgImage: mask)
                .transformed(by: CGAffineTransform(
                    scaleX: targetSize.width / CGFloat(mask.width),
                    y: targetSize.height / CGFloat(mask.height)
                ))

            // CIMaximumCompositing: per-pixel max, equivalent to logical OR for masks.
            guard let filter = CIFilter(name: "CIMaximumCompositing") else { return nil }
            filter.setValue(combined, forKey: kCIInputImageKey)
            filter.setValue(scaled, forKey: kCIInputBackgroundImageKey)
            guard let output = filter.outputImage else { return nil }
            combined = output
        }

        return ciContext.createCGImage(combined, from: combined.extent)
    }

    // MARK: - Mask Scaling

    /// Resize a mask to target dimensions using Lanczos (high quality, sharp edges).
    /// Returns nil if rendering fails.
    func scaleMask(_ mask: CGImage, to size: CGSize) -> CGImage? {
        let ciMask = CIImage(cgImage: mask)
            .transformed(by: CGAffineTransform(
                scaleX: size.width / CGFloat(mask.width),
                y: size.height / CGFloat(mask.height)
            ))
        return ciContext.createCGImage(ciMask, from: ciMask.extent)
    }

    // MARK: - Mask Inspection

    /// Returns true when the mask contains at least one pixel above the threshold.
    func containsForeground(_ mask: CGImage, threshold: UInt8 = 0) -> Bool {
        let width = mask.width
        let height = mask.height
        guard width > 0, height > 0 else { return false }

        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return false
        }

        context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels.contains { $0 > threshold }
    }
}
