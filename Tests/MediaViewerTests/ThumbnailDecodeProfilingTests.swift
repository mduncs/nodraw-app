import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MediaViewer

/// Opt-in, headless first-draw evidence. Synthetic JPEGs and an isolated disk
/// cache only; no window or live library is used. OS file caches stay warm.
final class ThumbnailDecodeProfilingTests: XCTestCase {
    func testMainThreadFirstDrawAfterBackgroundThumbnailLoad() async throws {
        guard ProcessInfo.processInfo.environment["NODRAW_THUMBNAIL_DECODE_PROFILE"] == "1" else {
            throw XCTSkip("Set NODRAW_THUMBNAIL_DECODE_PROFILE=1 for thumbnail decode profiling")
        }
        guard ProcessInfo.processInfo.environment["NODRAW_APP_SUPPORT_DIR"] != nil,
              ProcessInfo.processInfo.environment["NODRAW_ARCHIVE_PATH"] != nil else {
            throw XCTSkip("Profiling requires isolated support and archive paths")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodraw-thumbnail-decode-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = try await Task.detached(priority: .utility) {
            try [400, 800].map { pixels in
                let url = directory.appendingPathComponent("fixture-\(pixels).jpg")
                try Self.writeFixture(pixels: pixels, to: url)
                return url
            }
        }.value

        let itemID = UUID()
        let productionPaths = [ThumbnailGenerator.Size.small, .medium].map {
            ThumbnailGenerator.thumbnailPath(for: itemID, size: $0)
        }
        try FileManager.default.createDirectory(at: productionPaths[0].deletingLastPathComponent(),
            withIntermediateDirectories: true)
        for (fixture, path) in zip(fixtures, productionPaths) {
            try FileManager.default.copyItem(at: fixture, to: path)
        }
        defer { for path in productionPaths { try? FileManager.default.removeItem(at: path) } }
        let cache = ImageCache()
        let item = MediaItem(id: itemID, basePath: directory,
            metadataFile: directory.appendingPathComponent("fixture.md"),
            mediaFiles: [directory.appendingPathComponent("missing-original.jpg")],
            metadata: MediaMetadata(source: URL(string: "https://example.invalid/thumbnail-profile")!,
                platform: "profile"))

        let modes = DecodeMode.allCases
        var samples: [DecodeMode: [DrawSample]] = [:]
        // Rotate order, recreate each image, and discard warmup samples. This
        // avoids timing an already-drawn NSImage or a fixed mode-order bias.
        for iteration in 0..<53 {
            for offset in modes.indices {
                let mode = modes[(iteration + offset) % modes.count]
                let url = fixtures[mode.sourcePixels == 400 ? 0 : 1]
                let loaded: LoadedImage
                if mode == .cacheSmall || mode == .cacheMedium || mode == .cacheDisplay {
                    await cache.clearMemoryCache()
                    let started = Self.now()
                    let result = await cache.loadThumbnail(for: item,
                        size: mode.sourcePixels == 400 || mode == .cacheDisplay ? .small : .medium,
                        displaySize: mode == .cacheDisplay ? CGSize(width: 250, height: 250) : nil,
                        displayScale: mode == .cacheDisplay ? 2 : 1)
                    let image = try XCTUnwrap(result)
                    loaded = LoadedImage(image: image, milliseconds: Self.elapsed(started))
                } else {
                    loaded = try await Task.detached(priority: .utility) {
                        try autoreleasepool {
                            XCTAssertFalse(Thread.isMainThread)
                            let started = Self.now()
                            let image: NSImage
                            if mode == .productionSmall || mode == .productionMedium {
                                image = try XCTUnwrap(ThumbnailGenerator.loadThumbnail(for: itemID,
                                    size: mode.sourcePixels == 400 ? .small : .medium))
                            } else if mode.maximumPixels == nil {
                                image = try XCTUnwrap(NSImage(contentsOf: url))
                                if mode == .legacyCostSmall || mode == .legacyCostMedium {
                                    _ = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                                }
                            } else {
                                image = try Self.decode(url: url, maximumPixels: mode.maximumPixels!)
                            }
                            return LoadedImage(image: image, milliseconds: Self.elapsed(started))
                        }
                    }.value
                }
                let sample = try await MainActor.run { try Self.draw(loaded) }
                if iteration >= 5 { samples[mode, default: []].append(sample) }
            }
        }
        for mode in modes {
            let values = try XCTUnwrap(samples[mode])
            Self.emit([
                "mode": mode.rawValue,
                "samples": values.count,
                "source_pixels": mode.sourcePixels,
                "maximum_decode_pixels": mode.maximumPixels ?? mode.sourcePixels,
                "background_load_ms": Self.percentiles(values.map(\.loadMilliseconds)),
                "main_first_draw_ms": Self.percentiles(values.map(\.firstDrawMilliseconds)),
                "main_second_draw_ms": Self.percentiles(values.map(\.secondDrawMilliseconds)),
                "decoded_bytes_per_image": values[0].decodedBytes,
                "screenful_decoded_bytes": values[0].decodedBytes * 24,
                "screenful_assumption": "6 columns x 4 rows, square 250pt tiles at 2x; image bitmaps only",
                "limitations": "Offscreen AppKit bitmap drawing; not a Core Animation commit trace. Warm OS file cache; debug build."
            ])
        }
        let sourceResult = await cache.loadThumbnail(for: item, displaySize: CGSize(width: 250, height: 250), displayScale: 2)
        let source = try XCTUnwrap(sourceResult)
        let blurResult = await cache.loadBlurredThumbnail(for: item, source: source)
        let blur = try XCTUnwrap(blurResult)
        let bitmap = try XCTUnwrap(blur.cgImage(forProposedRect: nil, context: nil, hints: nil))
        Self.emit(["phase": "optional_blur_memory", "decoded_bytes_per_image": bitmap.bytesPerRow * bitmap.height,
            "screenful_extra_bytes_if_every_tile_needs_blur": bitmap.bytesPerRow * bitmap.height * 24])
        await cache.clearMemoryCache()
    }

    private enum DecodeMode: String, CaseIterable {
        case legacySmall = "NSImage_contentsOf_400"
        case legacyMedium = "NSImage_contentsOf_800"
        case legacyCostSmall = "NSImage_contentsOf_cgImage_cost_400"
        case legacyCostMedium = "NSImage_contentsOf_cgImage_cost_800"
        case decodedSmall = "ImageIO_immediate_400_at_500"
        case decodedMedium = "ImageIO_immediate_800_at_500"
        case decodedMediumFull = "ImageIO_immediate_800_at_800"
        case productionSmall = "production_400"
        case productionMedium = "production_800"
        case cacheSmall = "production_ImageCache_400"
        case cacheMedium = "production_ImageCache_800"
        case cacheDisplay = "production_ImageCache_display250pt_2x"

        var sourcePixels: Int {
            [.legacySmall, .legacyCostSmall, .decodedSmall, .productionSmall, .cacheSmall].contains(self) ? 400 : 800
        }
        var maximumPixels: Int? {
            switch self {
            case .legacySmall, .legacyMedium, .legacyCostSmall, .legacyCostMedium,
                 .productionSmall, .productionMedium, .cacheSmall, .cacheMedium: return nil
            case .decodedSmall, .decodedMedium, .cacheDisplay: return 500
            case .decodedMediumFull: return 800
            }
        }
    }

    private struct LoadedImage: @unchecked Sendable {
        let image: NSImage
        let milliseconds: Double
    }

    private struct DrawSample {
        let loadMilliseconds: Double
        let firstDrawMilliseconds: Double
        let secondDrawMilliseconds: Double
        let decodedBytes: Int
    }

    private static func writeFixture(pixels: Int, to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: pixels * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // Deterministic textured pixels give the JPEG decoder real work without
        // relying on fonts, on-screen drawing, or personal media.
        for y in 0..<pixels {
            for x in 0..<pixels {
                let index = (y * pixels + x) * 4
                bytes[index] = UInt8(truncatingIfNeeded: x * 13 + y * 7)
                bytes[index + 1] = UInt8(truncatingIfNeeded: x * 3 + y * 17)
                bytes[index + 2] = UInt8(truncatingIfNeeded: (x ^ y) * 19)
                bytes[index + 3] = 255
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private static func decode(url: URL, maximumPixels: Int) throws -> NSImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary))
        let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary))
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }

    @MainActor
    private static func draw(_ loaded: LoadedImage) throws -> DrawSample {
        XCTAssertTrue(Thread.isMainThread)
        return try autoreleasepool {
            let context = try XCTUnwrap(CGContext(data: nil, width: 500, height: 500,
                bitsPerComponent: 8, bytesPerRow: 500 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: 2, y: 2)
            context.interpolationQuality = .high
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let rectangle = NSRect(x: 0, y: 0, width: 250, height: 250)
            var started = now()
            loaded.image.draw(in: rectangle, from: .zero, operation: .copy, fraction: 1)
            context.flush()
            let first = elapsed(started)
            started = now()
            loaded.image.draw(in: rectangle, from: .zero, operation: .copy, fraction: 1)
            context.flush()
            let second = elapsed(started)
            let image = try XCTUnwrap(loaded.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            return DrawSample(loadMilliseconds: loaded.milliseconds,
                firstDrawMilliseconds: first, secondDrawMilliseconds: second,
                decodedBytes: image.bytesPerRow * image.height)
        }
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func elapsed(_ start: UInt64) -> Double { Double(now() - start) / 1_000_000 }
    private static func percentiles(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        return ["p50": sorted[Int(ceil(Double(sorted.count) * 0.50)) - 1],
                "p95": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]]
    }
    private static func emit(_ values: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print("NODRAW_THUMBNAIL_DECODE_PROFILE \(line)") }
    }
}
