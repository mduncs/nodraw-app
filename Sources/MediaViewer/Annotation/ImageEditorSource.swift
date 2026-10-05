import Foundation
import ImageIO
import CoreGraphics

/// The browsing cache deliberately downsamples large media. Editing/export must
/// keep original pixel dimensions and apply EXIF orientation consistently.
enum ImageEditorSource {
    /// Non-actor async work keeps full-resolution compression and disk I/O off
    /// the UI actor, just like decoding and the shared composition renderer.
    static func encode(_ image: CGImage, typeIdentifier: String) async throws -> Data {
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(data, typeIdentifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
        try Task.checkCancellation()
        return data as Data
    }

    static func write(_ data: Data, to destination: URL) async throws {
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
    }

    static func dimensions(at url: URL) async -> CGSize? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = info[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = info[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
            let rotated = (5...8).contains((info[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1)
            return rotated ? CGSize(width: height.doubleValue, height: width.doubleValue)
                : CGSize(width: width.doubleValue, height: height.doubleValue)
        }.value
    }

    static func decode(at url: URL) async -> CGImage? {
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = info[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = info[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
            // ImageIO's thumbnail decoder applies EXIF orientation; requesting the
            // original maximum dimension prevents its normal downsampling behavior.
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue),
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
            return Task.isCancelled ? nil : image
        }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }
}
