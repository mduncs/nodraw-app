import XCTest
import AppKit
@testable import MediaViewer

final class EditorRenderingTests: XCTestCase {
    func testExtractionUsesWhiteAsKeepIncludingSoftMaskAndDimensionScaling() throws {
        let source = EditorPixels.image(width: 12, height: 8) { _, _ in [240, 50, 80, 255] }
        let mask = EditorPixels.mask(width: 3, height: 2) { x, _ in [255, 128, 0][x] }
        let extracted = try XCTUnwrap(ImageMasking.extractWithTransparency(source: source, mask: mask))
        EditorPixels.assertPixel(extracted, x: 1, y: 4, equals: [240, 50, 80, 255], tolerance: 3)
        XCTAssertEqual(try EditorPixels.pixel(extracted, x: 10, y: 4)[3], 0)
        // Constant gray isolates opacity from interpolation across the three-step mask.
        let softMask = EditorPixels.mask(width: 3, height: 2) { _, _ in 128 }
        let soft = try XCTUnwrap(ImageMasking.extractWithTransparency(source: source, mask: softMask))
        XCTAssertEqual(Double(try EditorPixels.pixel(soft, x: 6, y: 4)[3]), 128, accuracy: 2)
    }

    func testRemoveAndKeepMaskHaveOppositeCorrectPolarity() async throws {
        let source = EditorPixels.image(width: 20, height: 20) { _, _ in [255, 100, 0, 255] }
        let mask = EditorPixels.mask(width: 20, height: 20) { x, _ in x < 10 ? 255 : 0 }
        for mode in [BlendMode.maskRemove, .maskKeep] {
            let set = AnnotationSet(shapes: [EditorPixels.maskShape(mask, mode: mode)])
            let rendered = try await EditorPixels.render(set, source: source)
            let left = try EditorPixels.pixel(rendered, x: 3, y: 10)
            let right = try EditorPixels.pixel(rendered, x: 16, y: 10)
            XCTAssertEqual(left[3], mode == .maskKeep ? 255 : 0)
            XCTAssertEqual(right[3], mode == .maskKeep ? 0 : 255)
        }
    }

    func testMaskLayerOpacityAppliesToCanvasAndZeroStrengthIsNoOp() async throws {
        let source = EditorPixels.image(width: 20, height: 20) { _, _ in [255, 0, 0, 255] }
        let mask = EditorPixels.mask(width: 20, height: 20) { x, _ in x < 10 ? 255 : 0 }
        for mode in [BlendMode.maskRemove, .maskKeep] {
            let set = AnnotationSet(layers: [AnnotationLayer(opacity: 0.5, shapes: [EditorPixels.maskShape(mask, mode: mode)])])
            let rendered = try await EditorPixels.render(set, source: source)
            let affectedX = mode == .maskRemove ? 3 : 16
            let retainedX = mode == .maskRemove ? 16 : 3
            XCTAssertEqual(Double(try EditorPixels.pixel(rendered, x: affectedX, y: 10)[3]), 128, accuracy: 2, "\(mode) must apply partial layer strength")
            XCTAssertEqual(try EditorPixels.pixel(rendered, x: retainedX, y: 10)[3], 255)
            let noOp = AnnotationSet(shapes: [EditorPixels.maskShape(mask, mode: mode, opacity: 0)])
            let unchanged = try await EditorPixels.render(noOp, source: source)
            EditorPixels.assertPixel(unchanged, x: 3, y: 10, equals: [255, 0, 0, 255])
            EditorPixels.assertPixel(unchanged, x: 16, y: 10, equals: [255, 0, 0, 255])
        }
    }

    func testBoundedPreviewMatchesScaledExportLayerOrderShapeAndGroupOpacity() async throws {
        let directory = EditorPixels.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnnotationAssetStore(assetDirectory: directory)
        let green = EditorPixels.image(width: 16, height: 16) { _, _ in [0, 255, 0, 255] }
        let key = try await store.saveCGImage(green)
        let source = EditorPixels.image(width: 80, height: 60) { _, y in y < 30 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        let yellow = AnnotationShape.rectangle(id: UUID(), rect: NormalizedRect(x: 0.25, y: 0, width: 0.5, height: 1),
                                               style: ShapeStyle(strokeColor: 0, strokeWidth: 0, fillColor: 0xffff00ff))
        let subject = AnnotationShape.extractedSubject(id: UUID(), assetKey: key,
            bounds: NormalizedRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5), opacity: 0.5,
            transform: .identity, sourceSubjectId: nil)
        let set = AnnotationSet(layers: [AnnotationLayer(shapes: [yellow]), AnnotationLayer(opacity: 0.5, shapes: [subject])])
        let full = try await EditorPixels.render(set, source: source, store: store)
        let preview = try await EditorPixels.render(set, source: source, store: store, maximumDimension: 40)
        XCTAssertEqual(preview.width, 40)
        XCTAssertEqual(preview.height, 30)
        let scaled = EditorPixels.scaled(full, width: 40, height: 30)
        for (x, y) in [(4, 4), (4, 25), (15, 15), (25, 15), (35, 18)] {
            EditorPixels.assertPixel(preview, x: x, y: y, equals: try EditorPixels.pixel(scaled, x: x, y: y), tolerance: 2)
        }
        EditorPixels.assertPixel(preview, x: 4, y: 4, equals: [255, 0, 0, 255])
        EditorPixels.assertPixel(preview, x: 4, y: 25, equals: [0, 0, 255, 255])
        // PNG profile conversion plus two 8-bit opacity operations can round a few levels.
        EditorPixels.assertPixel(preview, x: 25, y: 15, equals: [191, 255, 0, 255], tolerance: 4)
        EditorPixels.assertPixel(preview, x: 35, y: 18, equals: [0, 64, 191, 255], tolerance: 2)
    }

    func testAdjustmentsAndAsymmetricTopLeftCropMatchPreviewAndExport() async throws {
        let source = EditorPixels.image(width: 80, height: 60) { _, y in y < 30 ? [150, 20, 20, 255] : [20, 20, 150, 255] }
        let crop = NormalizedRect(x: 0.25, y: 0, width: 0.5, height: 0.25)
        let set = AnnotationSet(cropRegion: crop, adjustments: PhotoAdjustments(brightness: 0.1, saturation: 0.5))
        let full = try await EditorPixels.render(set, source: source)
        let preview = try await EditorPixels.render(set, source: source, maximumDimension: 40)
        let uncropped = try await EditorPixels.render(set, source: source, maximumDimension: 40, applyCrop: false)
        XCTAssertEqual(full.width, 40)
        XCTAssertEqual(full.height, 15)
        XCTAssertEqual(preview.width, 20)
        XCTAssertEqual(preview.height, 8)
        XCTAssertEqual(uncropped.width, 40)
        XCTAssertEqual(uncropped.height, 30)
        let pixel = try EditorPixels.pixel(full, x: 10, y: 5)
        XCTAssertGreaterThan(pixel[0], pixel[2], "Top-left crop must retain the red top, not the blue bottom")
        XCTAssertNotEqual(pixel, [150, 20, 20, 255], "Photo adjustments must be applied")
        EditorPixels.assertPixel(preview, x: 5, y: 3, equals: pixel, tolerance: 2)
        EditorPixels.assertPixel(uncropped, x: 15, y: 3, equals: pixel, tolerance: 2)
    }

    func testMissingVisibleExtractedAssetFailsInsteadOfExportingPartialImage() async throws {
        let directory = EditorPixels.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnnotationAssetStore(assetDirectory: directory)
        let source = EditorPixels.image(width: 8, height: 8) { _, _ in [255, 0, 0, 255] }
        let shape = AnnotationShape.extractedSubject(id: UUID(), assetKey: "missing",
            bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1), opacity: 1,
            transform: .identity, sourceSubjectId: nil)
        let set = AnnotationSet(shapes: [shape])
        let missingAsset = await AnnotationRenderer.render(annotations: set, onto: source, assetStore: store)
        XCTAssertNil(missingAsset)
        let hidden = AnnotationSet(layers: [AnnotationLayer(isVisible: false, shapes: [shape])])
        let result = await AnnotationRenderer.render(annotations: hidden, onto: source, assetStore: store)
        XCTAssertNotNil(result)
    }

    func testCorruptVisibleMaskFailsInsteadOfExportingPartialComposition() async throws {
        let source = EditorPixels.image(width: 8, height: 8) { _, _ in [255, 0, 0, 255] }
        let corrupt = AnnotationShape.mask(id: UUID(), maskData: Data([0x89, 0x50, 0x4e, 0x47]),
            bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1), blendMode: .maskRemove,
            opacity: 1, featherRadius: 0)
        let visible = await AnnotationRenderer.render(annotations: AnnotationSet(shapes: [corrupt]), onto: source)
        XCTAssertNil(visible)
        let hidden = AnnotationSet(layers: [AnnotationLayer(isVisible: false, shapes: [corrupt])])
        let ignored = await AnnotationRenderer.render(annotations: hidden, onto: source)
        XCTAssertNotNil(ignored)
    }

    func testExtractedSubjectScaleKeepsTopLeftAndPositiveRotationIsClockwise() async throws {
        let directory = EditorPixels.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnnotationAssetStore(assetDirectory: directory)
        let asset = EditorPixels.image(width: 20, height: 10) { x, _ in x < 10 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        let key = try await store.saveCGImage(asset)
        let source = EditorPixels.image(width: 80, height: 80) { _, _ in [0, 0, 0, 255] }
        let shape = AnnotationShape.extractedSubject(id: UUID(), assetKey: key,
            bounds: NormalizedRect(x: 0.125, y: 0.25, width: 0.25, height: 0.125), opacity: 1,
            transform: ShapeTransform(scale: 2), sourceSubjectId: nil)
        let scaled = try await EditorPixels.render(AnnotationSet(shapes: [shape]), source: source, store: store)
        EditorPixels.assertPixel(scaled, x: 14, y: 24, equals: [255, 0, 0, 255], tolerance: 3)
        EditorPixels.assertPixel(scaled, x: 44, y: 24, equals: [0, 0, 255, 255], tolerance: 3)
        EditorPixels.assertPixel(scaled, x: 14, y: 16, equals: [0, 0, 0, 255])
        let rotatedShape = shape.withTransform(ShapeTransform(scale: 2, rotation: 90))
        let rotated = try await EditorPixels.render(AnnotationSet(shapes: [rotatedShape]), source: source, store: store)
        EditorPixels.assertPixel(rotated, x: 30, y: 16, equals: [255, 0, 0, 255], tolerance: 3)
        EditorPixels.assertPixel(rotated, x: 30, y: 44, equals: [0, 0, 255, 255], tolerance: 3)
        EditorPixels.assertPixel(rotated, x: 12, y: 22, equals: [0, 0, 0, 255])
    }

    func testRestoreBrushBringsBackAdjustedSourceOnlyUnderItsStroke() async throws {
        let source = EditorPixels.image(width: 40, height: 32) { x, _ in x < 20 ? [180, 30, 0, 255] : [0, 30, 180, 255] }
        let erase = EditorPixels.mask(width: 40, height: 32) { x, _ in x < 20 ? 255 : 0 }
        let restore = EditorPixels.mask(width: 40, height: 32) { x, y in
            (8..<12).contains(x) && (4..<20).contains(y) ? 255 : 0
        }
        let adjustments = PhotoAdjustments(brightness: 0.1)
        let baseline = try await EditorPixels.render(AnnotationSet(adjustments: adjustments), source: source)
        let document = AnnotationSet(layers: [
            AnnotationLayer(shapes: [EditorPixels.maskShape(erase, mode: .maskRemove)]),
            AnnotationLayer(opacity: 0.5, shapes: [EditorPixels.maskShape(restore, mode: .maskRestore, opacity: 0.5)])
        ], adjustments: adjustments)
        let output = try await EditorPixels.render(document, source: source)
        var restoredPixel = try EditorPixels.pixel(baseline, x: 10, y: 10)
        restoredPixel[3] = 64
        EditorPixels.assertPixel(output, x: 10, y: 10, equals: restoredPixel, tolerance: 3)
        XCTAssertEqual(try EditorPixels.pixel(output, x: 2, y: 10)[3], 0, "Unpainted erased pixels must stay erased")
        EditorPixels.assertPixel(output, x: 30, y: 10, equals: try EditorPixels.pixel(baseline, x: 30, y: 10), tolerance: 1)
    }

    func testDownsampledInputKeepsOriginalCoordinateStrokeWidths() async throws {
        let source = EditorPixels.image(width: 80, height: 80) { _, _ in [0, 0, 0, 255] }
        let cachedPreview = EditorPixels.scaled(source, width: 40, height: 40)
        let rectangle = AnnotationShape.rectangle(id: UUID(), rect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            style: ShapeStyle(strokeColor: 0xff0000ff, strokeWidth: 8))
        let document = AnnotationSet(shapes: [rectangle])
        let fromOriginal = try await EditorPixels.render(document, source: source, maximumDimension: 40)
        let fromCache = try await EditorPixels.render(document, source: cachedPreview,
                                                       coordinateSize: CGSize(width: 80, height: 80))
        for x in [6, 9, 11, 14, 20, 29, 34] {
            EditorPixels.assertPixel(fromCache, x: x, y: 20, equals: try EditorPixels.pixel(fromOriginal, x: x, y: 20))
        }
        EditorPixels.assertPixel(fromCache, x: 6, y: 20, equals: [0, 0, 0, 255])
        EditorPixels.assertPixel(fromCache, x: 9, y: 20, equals: [255, 0, 0, 255])
    }
}

/// Fixtures explicitly encode rows top-to-bottom; no live archive, clipboard, GUI or input events.
enum EditorPixels {
    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nodraw-pixels-\(UUID().uuidString)")
    }
    static func image(width: Int, height: Int, pixel: (Int, Int) -> [UInt8]) -> CGImage {
        var bytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let rgba = pixel(x, y)
                bytes += rgba.prefix(3).map { UInt8(Int($0) * Int(rgba[3]) / 255) } + [rgba[3]]
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func mask(width: Int, height: Int, pixel: (Int, Int) -> UInt8) -> CGImage {
        let bytes = (0..<height).flatMap { y in (0..<width).map { pixel($0, y) } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func maskShape(_ image: CGImage, mode: BlendMode, opacity: CGFloat = 1) -> AnnotationShape {
        .mask(id: UUID(), maskData: ImageMasking.cgImageToPNGData(image),
              bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1), blendMode: mode,
              opacity: opacity, featherRadius: 0)
    }
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        // Normalize tagged PNG/CI and bitmap images to the renderer's explicit sRGB space.
        // Read pixel bytes directly so device profiles cannot affect assertions.
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        let alpha = Int(bytes[offset + 3])
        guard alpha > 0 else { return [0, 0, 0, 0] }
        return (0..<3).map { UInt8(min(255, (Int(bytes[offset + $0]) * 255 + alpha / 2) / alpha)) } + [UInt8(alpha)]
    }
    static func assertPixel(_ image: CGImage, x: Int, y: Int, equals expected: [UInt8], tolerance: Double = 1,
                            file: StaticString = #filePath, line: UInt = #line) {
        do {
            let actual = try pixel(image, x: x, y: y)
            for index in 0..<4 {
                XCTAssertEqual(Double(actual[index]), Double(expected[index]), accuracy: tolerance,
                               "pixel (\(x),\(y)) channel \(index): \(actual) != \(expected)", file: file, line: line)
            }
        } catch { XCTFail("Cannot inspect pixel: \(error)", file: file, line: line) }
    }
    static func scaled(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
    static func render(_ set: AnnotationSet, source: CGImage, store: AnnotationAssetStore? = nil,
                       maximumDimension: CGFloat? = nil, applyCrop: Bool = true,
                       coordinateSize: CGSize? = nil) async throws -> CGImage {
        let image = await AnnotationRenderer.render(annotations: set, onto: source, assetStore: store,
                                                    maximumDimension: maximumDimension, applyCrop: applyCrop,
                                                    coordinateSize: coordinateSize)
        return try XCTUnwrap(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }
}
