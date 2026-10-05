import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

// MARK: - ImageEditor

/// Non-destructive image editing service.
/// JPEG rotation/flip uses EXIF-only changes (no re-encoding).
/// Crop and format conversion re-encode as needed.
struct ImageEditor {

    // MARK: - EXIF Rotation

    /// EXIF orientation values (1-8)
    /// 1: Normal, 2: Flipped H, 3: Rotated 180, 4: Flipped V
    /// 5: Transposed, 6: Rotated 90 CW, 7: Transversed, 8: Rotated 90 CCW

    /// Rotation map: current orientation → new orientation after rotating 90° CW
    private static let rotateCWMap: [Int: Int] = [
        1: 6, 2: 5, 3: 8, 4: 7,
        5: 4, 6: 3, 7: 2, 8: 1
    ]

    /// Rotation map: current orientation → new orientation after rotating 90° CCW
    private static let rotateCCWMap: [Int: Int] = [
        1: 8, 2: 7, 3: 6, 4: 5,
        5: 2, 6: 1, 7: 4, 8: 3
    ]

    /// Flip horizontal map: current orientation → new orientation
    private static let flipHMap: [Int: Int] = [
        1: 2, 2: 1, 3: 4, 4: 3,
        5: 8, 6: 7, 7: 6, 8: 5
    ]

    /// Flip vertical map: current orientation → new orientation
    private static let flipVMap: [Int: Int] = [
        1: 4, 2: 3, 3: 2, 4: 1,
        5: 6, 6: 5, 7: 8, 8: 7
    ]

    /// Rotate a JPEG image 90° clockwise using EXIF metadata only (no re-encoding)
    /// - Parameter url: Path to JPEG file
    /// - Returns: true if rotation was applied
    @discardableResult
    static func rotateClockwise(url: URL) throws -> Bool {
        try applyEXIFOrientation(url: url, map: rotateCWMap)
    }

    /// Rotate a JPEG image 90° counter-clockwise using EXIF metadata only
    @discardableResult
    static func rotateCounterClockwise(url: URL) throws -> Bool {
        try applyEXIFOrientation(url: url, map: rotateCCWMap)
    }

    /// Flip image horizontally using EXIF metadata only
    @discardableResult
    static func flipHorizontal(url: URL) throws -> Bool {
        try applyEXIFOrientation(url: url, map: flipHMap)
    }

    /// Flip image vertically using EXIF metadata only
    @discardableResult
    static func flipVertical(url: URL) throws -> Bool {
        try applyEXIFOrientation(url: url, map: flipVMap)
    }

    /// Apply EXIF orientation change without re-encoding
    private static func applyEXIFOrientation(url: URL, map: [Int: Int]) throws -> Bool {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageEditorError.loadFailed(url)
        }

        // Get current orientation
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let currentOrientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1

        guard let newOrientation = map[currentOrientation] else {
            return false
        }

        // For JPEG: copy compressed data and only change metadata
        let sourceType = CGImageSourceGetType(imageSource)
        let isJPEG = sourceType.map { UTType($0 as String)?.conforms(to: .jpeg) ?? false } ?? false

        if isJPEG {
            return try applyJPEGOrientationMetadata(url: url, source: imageSource, newOrientation: newOrientation)
        } else {
            return try reencodeWithOrientation(url: url, source: imageSource, newOrientation: newOrientation)
        }
    }

    /// JPEG-specific: copy compressed data with updated EXIF orientation
    private static func applyJPEGOrientationMetadata(url: URL, source: CGImageSource, newOrientation: Int) throws -> Bool {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return false }

        // Write to temp file, then atomic rename
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")

        guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, UTType.jpeg.identifier as CFString, count, nil) else {
            throw ImageEditorError.writeFailed(url)
        }

        for index in 0..<count {
            let properties: [CFString: Any] = [
                kCGImagePropertyOrientation: newOrientation
            ]
            CGImageDestinationAddImageFromSource(destination, source, index, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ImageEditorError.writeFailed(url)
        }

        // Atomic replace
        try FileManager.default.replaceItemAt(url, withItemAt: tempURL)

        return true
    }

    /// Re-encode non-JPEG with new orientation
    private static func reencodeWithOrientation(url: URL, source: CGImageSource, newOrientation: Int) throws -> Bool {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return false
        }

        let sourceType = CGImageSourceGetType(source) ?? UTType.png.identifier as CFString
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")

        guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, sourceType, 1, nil) else {
            throw ImageEditorError.writeFailed(url)
        }

        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: newOrientation
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ImageEditorError.writeFailed(url)
        }

        try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        return true
    }

    // MARK: - Crop

    /// Crop an image to the specified rect (in pixel coordinates)
    /// - Parameters:
    ///   - url: Path to image file
    ///   - rect: Crop rectangle in pixel coordinates
    /// - Returns: New aspect ratio after crop
    static func crop(url: URL, rect: CGRect) throws -> CGFloat {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ImageEditorError.loadFailed(url)
        }

        guard let cropped = cgImage.cropping(to: rect) else {
            throw ImageEditorError.cropFailed
        }

        let sourceType = CGImageSourceGetType(imageSource) ?? UTType.png.identifier as CFString
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")

        guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, sourceType, 1, nil) else {
            throw ImageEditorError.writeFailed(url)
        }

        // Preserve existing metadata
        if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) {
            CGImageDestinationAddImage(destination, cropped, properties)
        } else {
            CGImageDestinationAddImage(destination, cropped, nil)
        }

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ImageEditorError.writeFailed(url)
        }

        try FileManager.default.replaceItemAt(url, withItemAt: tempURL)

        return CGFloat(cropped.width) / CGFloat(cropped.height)
    }

    // MARK: - Format Conversion

    /// Convert image to a different format
    /// - Parameters:
    ///   - url: Source file URL
    ///   - targetFormat: Target UTType (.jpeg, .png, .heic)
    ///   - quality: Compression quality for lossy formats (0.0-1.0)
    /// - Returns: URL of converted file (same directory, new extension)
    static func convert(url: URL, to targetFormat: UTType, quality: CGFloat = 0.85) throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ImageEditorError.loadFailed(url)
        }

        let newExtension: String
        switch targetFormat {
        case .jpeg: newExtension = "jpg"
        case .png: newExtension = "png"
        case .heic: newExtension = "heic"
        default: newExtension = targetFormat.preferredFilenameExtension ?? "img"
        }

        let newURL = url.deletingPathExtension().appendingPathExtension(newExtension)

        guard let destination = CGImageDestinationCreateWithURL(newURL as CFURL, targetFormat.identifier as CFString, 1, nil) else {
            throw ImageEditorError.writeFailed(newURL)
        }

        var properties: [CFString: Any] = [:]
        if targetFormat.conforms(to: .jpeg) || targetFormat == .heic {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }

        // Copy EXIF/IPTC metadata from source
        if let sourceProps = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] {
            for (key, value) in sourceProps {
                if key != kCGImagePropertyPixelWidth && key != kCGImagePropertyPixelHeight {
                    properties[key] = value
                }
            }
        }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageEditorError.writeFailed(newURL)
        }

        return newURL
    }
}

// MARK: - Errors

enum ImageEditorError: Error, LocalizedError {
    case loadFailed(URL)
    case writeFailed(URL)
    case cropFailed
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .loadFailed(let url): return "Failed to load image: \(url.lastPathComponent)"
        case .writeFailed(let url): return "Failed to write image: \(url.lastPathComponent)"
        case .cropFailed: return "Crop operation failed"
        case .unsupportedFormat: return "Unsupported image format"
        }
    }
}
