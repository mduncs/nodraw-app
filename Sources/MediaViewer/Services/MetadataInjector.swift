import Foundation
import ImageIO
import UniformTypeIdentifiers
import AppKit
import os.log

// MARK: - Export Metadata

/// Metadata fields to inject into exported images
struct ExportMetadata {
    var caption: String?           // IPTC:Caption-Abstract, EXIF:ImageDescription
    var source: URL?               // XMP:Source (stored as string)
    var creator: String?           // IPTC:Creator, EXIF:Artist
    var copyright: String?         // IPTC:CopyrightNotice
    var keywords: [String]         // IPTC:Keywords
    var dateCreated: Date?         // EXIF:DateTimeOriginal

    init(
        caption: String? = nil,
        source: URL? = nil,
        creator: String? = nil,
        copyright: String? = nil,
        keywords: [String] = [],
        dateCreated: Date? = nil
    ) {
        self.caption = caption
        self.source = source
        self.creator = creator
        self.copyright = copyright
        self.keywords = keywords
        self.dateCreated = dateCreated
    }

    /// Create ExportMetadata from a MediaItem using default field mappings
    static func from(item: MediaItem, options: ExportOptions) -> ExportMetadata {
        var metadata = ExportMetadata()

        if options.includeCaption {
            metadata.caption = item.metadata.notes
        }
        if options.includeSource {
            metadata.source = item.metadata.source
        }
        if options.includeCreator {
            metadata.creator = item.metadata.author
        }
        if options.includeKeywords {
            metadata.keywords = item.metadata.tags
        }
        if options.includeDate {
            metadata.dateCreated = item.metadata.originalDate ?? item.metadata.archivedDate
        }
        if options.includeCopyright, let creator = item.metadata.author {
            // Auto-generate copyright from author
            let year = Calendar.current.component(.year, from: item.metadata.originalDate ?? Date())
            metadata.copyright = "\(year) \(creator)"
        }

        return metadata
    }
}

// MARK: - Export Options

/// Configuration for what metadata to include in export
struct ExportOptions {
    var includeCaption: Bool = true
    var includeSource: Bool = true
    var includeCreator: Bool = true
    var includeCopyright: Bool = false
    var includeKeywords: Bool = true
    var includeDate: Bool = true

    /// Output format for export
    var outputFormat: ExportFormat = .jpeg

    /// JPEG quality (0.0-1.0), only used when outputFormat is .jpeg
    var jpegQuality: CGFloat = 0.92

    static let `default` = ExportOptions()
}

// MARK: - Export Format

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG"
    case png = "PNG"
    case tiff = "TIFF"
    case heic = "HEIC"
    case webp = "WebP"

    var id: String { rawValue }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .tiff: return .tiff
        case .heic: return .heic
        case .webp: return .webP
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        case .heic: return "heic"
        case .webp: return "webp"
        }
    }

    /// Whether this format supports quality adjustment
    var supportsQuality: Bool {
        switch self {
        case .jpeg, .heic, .webp: return true
        case .png, .tiff: return false
        }
    }
}

// MARK: - Export Errors

enum ExportError: Error, LocalizedError {
    case sourceLoadFailed(URL)
    case destinationCreationFailed(URL)
    case writeFailed(URL)
    case unsupportedFormat(String)
    case noMediaFiles

    var errorDescription: String? {
        switch self {
        case .sourceLoadFailed(let url):
            return "Failed to load source image: \(url.lastPathComponent)"
        case .destinationCreationFailed(let url):
            return "Failed to create destination: \(url.lastPathComponent)"
        case .writeFailed(let url):
            return "Failed to write image: \(url.lastPathComponent)"
        case .unsupportedFormat(let ext):
            return "Unsupported format: \(ext)"
        case .noMediaFiles:
            return "Item has no media files to export"
        }
    }
}

// MARK: - Export Result

struct ExportResult {
    let sourceURL: URL
    let destinationURL: URL
    let success: Bool
    let error: Error?

    static func success(source: URL, destination: URL) -> ExportResult {
        ExportResult(sourceURL: source, destinationURL: destination, success: true, error: nil)
    }

    static func failure(source: URL, destination: URL, error: Error) -> ExportResult {
        ExportResult(sourceURL: source, destinationURL: destination, success: false, error: error)
    }
}

// MARK: - Metadata Injector

private let logger = Logger(subsystem: "com.nodraw.app", category: "MetadataInjector")

/// Injects EXIF/IPTC metadata into exported image files using ImageIO/CGImageDestination
struct MetadataInjector {

    // MARK: - EXIF Date Formatter

    /// EXIF date format: "yyyy:MM:dd HH:mm:ss"
    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Public API

    /// Export a single image with metadata injection
    /// - Parameters:
    ///   - sourceURL: Source image file
    ///   - destinationURL: Destination file path
    ///   - metadata: Metadata to inject
    ///   - options: Export options (format, quality)
    /// - Returns: ExportResult indicating success or failure
    func export(
        sourceURL: URL,
        to destinationURL: URL,
        metadata: ExportMetadata,
        options: ExportOptions = .default
    ) -> ExportResult {
        do {
            try exportThrowing(sourceURL: sourceURL, to: destinationURL, metadata: metadata, options: options)
            return .success(source: sourceURL, destination: destinationURL)
        } catch {
            logger.error("Export failed for \(sourceURL.lastPathComponent): \(error.localizedDescription)")
            return .failure(source: sourceURL, destination: destinationURL, error: error)
        }
    }

    /// Export a MediaItem with all its media files
    /// - Parameters:
    ///   - item: MediaItem to export
    ///   - destinationFolder: Folder to export to
    ///   - options: Export options
    /// - Returns: Array of ExportResults for each file
    func export(
        item: MediaItem,
        to destinationFolder: URL,
        options: ExportOptions = .default
    ) -> [ExportResult] {
        guard !item.mediaFiles.isEmpty else {
            return [.failure(
                source: item.metadataFile,
                destination: destinationFolder,
                error: ExportError.noMediaFiles
            )]
        }

        let metadata = ExportMetadata.from(item: item, options: options)
        var results: [ExportResult] = []

        for (index, mediaURL) in item.mediaFiles.enumerated() {
            // Skip non-image files (videos, etc)
            guard isImageFile(mediaURL) else { continue }

            // Generate destination filename
            let baseName = mediaURL.deletingPathExtension().lastPathComponent
            let suffix = item.mediaFiles.count > 1 ? "_\(index + 1)" : ""
            let destName = "\(baseName)\(suffix).\(options.outputFormat.fileExtension)"
            let destURL = destinationFolder.appendingPathComponent(destName)

            let result = export(sourceURL: mediaURL, to: destURL, metadata: metadata, options: options)
            results.append(result)
        }

        return results
    }

    /// Batch export multiple items
    /// - Parameters:
    ///   - items: Array of MediaItems to export
    ///   - destinationFolder: Folder to export to
    ///   - options: Export options
    ///   - progress: Optional callback with (current, total) progress
    /// - Returns: Array of all ExportResults
    func exportBatch(
        items: [MediaItem],
        to destinationFolder: URL,
        options: ExportOptions = .default,
        progress: ((Int, Int) -> Void)? = nil
    ) async -> [ExportResult] {
        var allResults: [ExportResult] = []

        // Calculate total files upfront
        let totalFiles = items.reduce(0) { count, item in
            count + item.mediaFiles.filter(isImageFile).count
        }

        var processed = 0

        for item in items {
            let results = export(item: item, to: destinationFolder, options: options)
            allResults.append(contentsOf: results)
            processed += results.count
            progress?(processed, totalFiles)
        }

        return allResults
    }

    // MARK: - Private Implementation

    private func exportThrowing(
        sourceURL: URL,
        to destinationURL: URL,
        metadata: ExportMetadata,
        options: ExportOptions
    ) throws {
        // Load source image
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw ExportError.sourceLoadFailed(sourceURL)
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ExportError.sourceLoadFailed(sourceURL)
        }

        // Get existing properties to preserve
        var properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]

        // Build and merge IPTC dictionary
        var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        injectIPTC(metadata: metadata, into: &iptc)
        if !iptc.isEmpty {
            properties[kCGImagePropertyIPTCDictionary] = iptc
        }

        // Build and merge EXIF dictionary
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        injectEXIF(metadata: metadata, into: &exif)
        if !exif.isEmpty {
            properties[kCGImagePropertyExifDictionary] = exif
        }

        // Build and merge TIFF dictionary (for Artist field)
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        injectTIFF(metadata: metadata, into: &tiff)
        if !tiff.isEmpty {
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }

        // Create destination directory if needed
        let destDir = destinationURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create destination with appropriate format
        let destOptions: [CFString: Any]
        if options.outputFormat.supportsQuality {
            destOptions = [kCGImageDestinationLossyCompressionQuality: options.jpegQuality]
        } else {
            destOptions = [:]
        }

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            options.outputFormat.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.destinationCreationFailed(destinationURL)
        }

        // Merge destination options with metadata properties
        var finalProperties = properties
        for (key, value) in destOptions {
            finalProperties[key] = value
        }

        CGImageDestinationAddImage(destination, cgImage, finalProperties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.writeFailed(destinationURL)
        }

        logger.info("Exported \(sourceURL.lastPathComponent) to \(destinationURL.lastPathComponent)")
    }

    // MARK: - IPTC Injection

    private func injectIPTC(metadata: ExportMetadata, into iptc: inout [CFString: Any]) {
        // Caption/Abstract
        if let caption = metadata.caption, !caption.isEmpty {
            iptc[kCGImagePropertyIPTCCaptionAbstract] = caption
        }

        // Creator/Byline
        if let creator = metadata.creator, !creator.isEmpty {
            // IPTC Creator is an array
            iptc[kCGImagePropertyIPTCCreatorContactInfo] = nil // Clear contact info
            iptc[kCGImagePropertyIPTCByline] = [creator]
        }

        // Copyright
        if let copyright = metadata.copyright, !copyright.isEmpty {
            iptc[kCGImagePropertyIPTCCopyrightNotice] = copyright
        }

        // Keywords
        if !metadata.keywords.isEmpty {
            iptc[kCGImagePropertyIPTCKeywords] = metadata.keywords
        }

        // Source URL (stored as Source field)
        if let source = metadata.source {
            iptc[kCGImagePropertyIPTCSource] = source.absoluteString
        }

        // Date created
        if let date = metadata.dateCreated {
            // IPTC date format: YYYYMMDD
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            iptc[kCGImagePropertyIPTCDateCreated] = formatter.string(from: date)

            // IPTC time format: HHmmss+HHMM or HHmmss
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HHmmss"
            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
            iptc[kCGImagePropertyIPTCTimeCreated] = timeFormatter.string(from: date)
        }
    }

    // MARK: - EXIF Injection

    private func injectEXIF(metadata: ExportMetadata, into exif: inout [CFString: Any]) {
        // DateTimeOriginal
        if let date = metadata.dateCreated {
            exif[kCGImagePropertyExifDateTimeOriginal] = Self.exifDateFormatter.string(from: date)
            exif[kCGImagePropertyExifDateTimeDigitized] = Self.exifDateFormatter.string(from: date)
        }

        // ImageDescription (caption)
        if let caption = metadata.caption, !caption.isEmpty {
            // Note: ImageDescription is actually in the TIFF dictionary, not EXIF
            // but some apps look for it in EXIF too
            exif[kCGImagePropertyExifUserComment] = caption
        }
    }

    // MARK: - TIFF Injection

    private func injectTIFF(metadata: ExportMetadata, into tiff: inout [CFString: Any]) {
        // Artist
        if let creator = metadata.creator, !creator.isEmpty {
            tiff[kCGImagePropertyTIFFArtist] = creator
        }

        // Copyright
        if let copyright = metadata.copyright, !copyright.isEmpty {
            tiff[kCGImagePropertyTIFFCopyright] = copyright
        }

        // ImageDescription
        if let caption = metadata.caption, !caption.isEmpty {
            tiff[kCGImagePropertyTIFFImageDescription] = caption
        }

        // DateTime (modification time)
        if let date = metadata.dateCreated {
            tiff[kCGImagePropertyTIFFDateTime] = Self.exifDateFormatter.string(from: date)
        }
    }

    // MARK: - Helpers

    private func isImageFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "tiff", "tif", "webp", "heic", "heif"].contains(ext)
    }
}

// MARK: - Read Metadata (for verification/testing)

extension MetadataInjector {
    /// Read metadata from an image file (for testing/verification)
    static func readMetadata(from url: URL) -> (iptc: [String: Any], exif: [String: Any], tiff: [String: Any])? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return nil
        }

        // Convert CFString keys to String for easier use
        func convertKeys(_ dict: [CFString: Any]) -> [String: Any] {
            Dictionary(uniqueKeysWithValues: dict.map { (key, value) in
                (key as String, value)
            })
        }

        return (
            iptc: (properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]).map(convertKeys) ?? [:],
            exif: (properties[kCGImagePropertyExifDictionary] as? [CFString: Any]).map(convertKeys) ?? [:],
            tiff: (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]).map(convertKeys) ?? [:]
        )
    }
}
