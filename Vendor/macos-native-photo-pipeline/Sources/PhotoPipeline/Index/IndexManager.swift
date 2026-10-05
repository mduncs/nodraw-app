import Foundation
import CoreGraphics
import ImageIO

/// Report from a bulk indexing operation.
public struct IndexReport: Sendable {
    public let totalProcessed: Int
    public let succeeded: Int
    public let failed: Int
    public let duration: TimeInterval
    public let errors: [String: String]  // assetID → error message

    public var successRate: Double {
        totalProcessed > 0 ? Double(succeeded) / Double(totalProcessed) : 0
    }
}

/// Manages bulk indexing operations with progress reporting.
///
/// Handles directory scanning, parallel analysis dispatch, and
/// index rebuild after bulk operations.
public final class IndexManager: @unchecked Sendable {

    private let searchIndex: SearchIndex
    private let queue = DispatchQueue(label: "com.photopipeline.indexmanager", qos: .utility)

    public init(searchIndex: SearchIndex) {
        self.searchIndex = searchIndex
    }

    /// Index all images in a directory.
    ///
    /// Scans for common image formats (JPEG, PNG, HEIC, TIFF),
    /// processes each through the pipeline, then rebuilds indices.
    public func indexDirectory(
        _ url: URL,
        recursive: Bool = true,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> IndexReport {
        let startTime = Date()

        // Discover image files
        let imageURLs = try discoverImages(in: url, recursive: recursive)
        let total = imageURLs.count

        var succeeded = 0
        var errors: [String: String] = [:]

        for (index, imageURL) in imageURLs.enumerated() {
            let assetID = imageURL.deletingPathExtension().lastPathComponent

            do {
                guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                    errors[assetID] = "Failed to load image"
                    continue
                }

                let metadata = extractMetadata(from: imageSource, url: imageURL)
                try await searchIndex.index(image: cgImage, assetID: assetID, metadata: metadata)
                succeeded += 1
            } catch {
                errors[assetID] = error.localizedDescription
            }

            progress?(index + 1, total)
        }

        // Rebuild indices after bulk insert
        try await searchIndex.rebuild()

        let duration = Date().timeIntervalSince(startTime)
        return IndexReport(
            totalProcessed: total,
            succeeded: succeeded,
            failed: total - succeeded,
            duration: duration,
            errors: errors
        )
    }

    // MARK: - Private

    private func discoverImages(in directory: URL, recursive: Bool) throws -> [URL] {
        let fm = FileManager.default
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "webp", "bmp"]

        if recursive {
            var results: [URL] = []
            if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) {
                while let url = enumerator.nextObject() as? URL {
                    if imageExtensions.contains(url.pathExtension.lowercased()) {
                        results.append(url)
                    }
                }
            }
            return results.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            let contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            return contents
                .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    private func extractMetadata(from source: CGImageSource, url: URL) -> AssetMetadata? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }

        let width = properties[kCGImagePropertyPixelWidth as String] as? Int
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int

        // Extract creation date from EXIF
        var dateCreated: Date?
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let dateStr = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            dateCreated = formatter.date(from: dateStr)
        }

        // Extract GPS location
        var location: AssetMetadata.Location?
        if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
           let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String
            let adjLat = latRef == "S" ? -lat : lat
            let adjLon = lonRef == "W" ? -lon : lon
            location = AssetMetadata.Location(latitude: adjLat, longitude: adjLon)
        }

        return AssetMetadata(
            dateCreated: dateCreated,
            width: width,
            height: height,
            mediaType: .image,
            location: location
        )
    }
}
