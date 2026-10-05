import CoreGraphics
import AppKit
import CoreImage

// MARK: - ImageMasking

/// Shared image extraction/masking utilities used by AI annotation operations
/// and drag-drop subject extraction. Pure functions — CGImage in, CGImage/Data out.
enum ImageMasking {
    private static let imageContext = CIContext()

    /// Extract subject pixels using mask, with transparent background.
    /// Handles mask/source dimension mismatch by scaling the mask.
    /// Used by both lift-subject and drag-subject flows.
    static func extractWithTransparency(source: CGImage, mask: CGImage) -> CGImage? {
        let foreground = CIImage(cgImage: source)
        let scaledMask = CIImage(cgImage: mask, options: [.colorSpace: NSNull()]).transformed(by: CGAffineTransform(
            scaleX: CGFloat(source.width) / CGFloat(mask.width),
            y: CGFloat(source.height) / CGFloat(mask.height)
        ))
        // Vision uses white = keep. CGImage image masks use inverse polarity;
        // CIBlendWithMask preserves the intended foreground, including soft edges.
        let result = foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: foreground.extent),
            kCIInputMaskImageKey: scaledMask
        ])
        return imageContext.createCGImage(result, from: foreground.extent)
    }

    /// Convert CGImage to PNG Data for annotation storage.
    static func cgImageToPNGData(_ image: CGImage) -> Data {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return Data()
        }
        return pngData
    }
}
