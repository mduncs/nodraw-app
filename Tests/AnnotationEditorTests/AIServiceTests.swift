import XCTest
import CoreGraphics
@testable import MediaViewer

/// Tests for AI service command generation, ImageMasking utilities, and job lifecycle.
final class AIServiceTests: XCTestCase {

    // MARK: - ImageMasking Tests

    func testCGImageToPNGRoundTrip() {
        // Create a simple 2x2 red image
        let image = createTestImage(width: 2, height: 2, color: (255, 0, 0, 255))
        let pngData = ImageMasking.cgImageToPNGData(image)

        XCTAssertFalse(pngData.isEmpty, "PNG data should not be empty")

        // Verify PNG signature
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        let headerBytes = Array(pngData.prefix(8))
        XCTAssertEqual(headerBytes, signature, "Should have valid PNG header")

        // Round-trip: decode back
        let nsImage = NSImage(data: pngData)
        XCTAssertNotNil(nsImage, "Should decode back to NSImage")

        let cgImage = nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        XCTAssertNotNil(cgImage, "Should get CGImage back")
        XCTAssertEqual(cgImage?.width, 2)
        XCTAssertEqual(cgImage?.height, 2)
    }

    func testCGImageToPNGPreservesDimensions() {
        let image = createTestImage(width: 100, height: 50, color: (0, 128, 255, 255))
        let pngData = ImageMasking.cgImageToPNGData(image)

        let nsImage = NSImage(data: pngData)
        let cgImage = nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        XCTAssertEqual(cgImage?.width, 100)
        XCTAssertEqual(cgImage?.height, 50)
    }

    func testExtractWithTransparency() {
        // Create a 4x4 source image (all white)
        let source = createTestImage(width: 4, height: 4, color: (255, 255, 255, 255))

        // Create a 4x4 mask (left half white = keep, right half black = remove)
        let mask = createGrayscaleMask(width: 4, height: 4) { x, _ in
            return x < 2 ? UInt8(255) : UInt8(0)
        }

        let result = ImageMasking.extractWithTransparency(source: source, mask: mask)
        XCTAssertNotNil(result, "Should produce extracted image")
        XCTAssertEqual(result?.width, 4)
        XCTAssertEqual(result?.height, 4)
    }

    func testExtractWithTransparencyScalesMask() {
        // Source is 4x4, mask is 2x2 — should scale mask up
        let source = createTestImage(width: 4, height: 4, color: (255, 0, 0, 255))
        let mask = createGrayscaleMask(width: 2, height: 2) { _, _ in UInt8(255) }

        let result = ImageMasking.extractWithTransparency(source: source, mask: mask)
        XCTAssertNotNil(result, "Should handle mask dimension mismatch")
        XCTAssertEqual(result?.width, 4)
        XCTAssertEqual(result?.height, 4)
    }

    // MARK: - Command Structure Tests

    func testRemoveBackgroundCommandStructure() async throws {
        // We can't call VisionProcessor without real images, so test the command
        // shape that removeBackground would produce by building it directly
        let maskData = ImageMasking.cgImageToPNGData(
            createGrayscaleMask(width: 10, height: 10) { _, _ in UInt8(200) }
        )

        let shape = AnnotationShape.mask(
            id: UUID(),
            maskData: maskData,
            bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            blendMode: .maskRemove,
            opacity: 1.0,
            featherRadius: 3.0
        )
        let command = AnnotationCommand.addShape(shape: shape, layerId: nil)

        // Apply to annotation set
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let result = set.apply(command)

        XCTAssertTrue(result.didChange)
        XCTAssertEqual(set.shapes.count, 1)

        // Verify it's a mask with correct blend mode
        if case .mask(_, _, _, let blendMode, _, let feather) = set.shapes.first {
            XCTAssertEqual(blendMode, .maskRemove)
            XCTAssertEqual(feather, 3.0)
        } else {
            XCTFail("Shape should be a mask")
        }

        // Undo should remove it
        let undoResult = set.apply(result.inverse)
        XCTAssertTrue(undoResult.didChange)
        XCTAssertEqual(set.shapes.count, 0)
    }

    func testIsolatePersonCommandStructure() {
        let maskData = ImageMasking.cgImageToPNGData(
            createGrayscaleMask(width: 10, height: 10) { _, _ in UInt8(200) }
        )

        let shape = AnnotationShape.mask(
            id: UUID(),
            maskData: maskData,
            bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            blendMode: .maskKeep,
            opacity: 1.0,
            featherRadius: 2.0
        )
        let command = AnnotationCommand.addShape(shape: shape, layerId: nil)

        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let result = set.apply(command)

        XCTAssertTrue(result.didChange)
        if case .mask(_, _, _, let blendMode, _, _) = set.shapes.first {
            XCTAssertEqual(blendMode, .maskKeep)
        } else {
            XCTFail("Shape should be a mask with maskKeep")
        }
    }

    func testLiftSubjectCommandGroupStructure() {
        // Simulate the command group that liftSubject produces
        let masksLayerId = UUID()
        let subjectLayerId = UUID()
        let extractedSubjectId = UUID()

        let cutoutMask = AnnotationShape.mask(
            id: UUID(),
            maskData: Data([0x89, 0x50, 0x4E, 0x47]),  // PNG header stub
            bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            blendMode: .maskRemove,
            opacity: 1.0,
            featherRadius: 2.0
        )
        let extractedSubject = AnnotationShape.extractedSubject(
            id: extractedSubjectId,
            assetKey: "test-asset-key",
            bounds: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            opacity: 1.0,
            transform: .identity,
            sourceSubjectId: nil
        )

        let commands: [AnnotationCommand] = [
            .addLayer(name: "Background Masks", id: masksLayerId),
            .addShape(shape: cutoutMask, layerId: masksLayerId),
            .addLayer(name: "Subject 1", id: subjectLayerId),
            .addShape(shape: extractedSubject, layerId: subjectLayerId),
            .setActiveLayer(layerId: subjectLayerId),
        ]

        var set = AnnotationSet()
        let _ = set.addLayer(name: "Base")

        // Apply as group
        let result = set.apply(.group(commands))
        XCTAssertTrue(result.didChange)

        // Should have 3 layers: Base + Background Masks + Subject 1
        XCTAssertEqual(set.layers.count, 3)
        XCTAssertTrue(set.layers.contains(where: { $0.name == "Background Masks" }))
        XCTAssertTrue(set.layers.contains(where: { $0.name == "Subject 1" }))

        // Should have 2 shapes total
        XCTAssertEqual(set.shapes.count, 2)

        // Active layer should be the subject layer
        XCTAssertEqual(set.activeLayerId, subjectLayerId)

        // Undo entire group
        let undoResult = set.apply(result.inverse)
        XCTAssertTrue(undoResult.didChange)

        // Back to just "Base" layer, no shapes
        XCTAssertEqual(set.layers.count, 1)
        XCTAssertEqual(set.shapes.count, 0)
    }

    func testLiftSubjectReusesExistingBackgroundMasksLayer() {
        // If "Background Masks" layer already exists, don't create a duplicate
        var set = AnnotationSet()
        let _ = set.addLayer(name: "Base")
        let masksLayer = set.addLayer(name: "Background Masks")

        let subjectLayerId = UUID()
        let cutoutMask = AnnotationShape.mask(
            id: UUID(),
            maskData: Data(),
            bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
            blendMode: .maskRemove,
            opacity: 1.0,
            featherRadius: 2.0
        )
        let extractedSubject = AnnotationShape.extractedSubject(
            id: UUID(),
            assetKey: "key",
            bounds: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            opacity: 1.0,
            transform: .identity,
            sourceSubjectId: nil
        )

        // Note: when "Background Masks" already exists, the service skips addLayer for it
        let commands: [AnnotationCommand] = [
            .addShape(shape: cutoutMask, layerId: masksLayer.id),
            .addLayer(name: "Subject 1", id: subjectLayerId),
            .addShape(shape: extractedSubject, layerId: subjectLayerId),
            .setActiveLayer(layerId: subjectLayerId),
        ]

        let result = set.apply(.group(commands))
        XCTAssertTrue(result.didChange)

        // Should have 3 layers (not 4): Base + Background Masks + Subject 1
        XCTAssertEqual(set.layers.count, 3)
        XCTAssertEqual(set.shapes.count, 2)
    }

    // MARK: - AIJob Tests

    func testAIJobInitialization() {
        let job = AIJob(id: UUID(), operation: "Remove Background", startTime: Date(), status: .running)
        XCTAssertEqual(job.operation, "Remove Background")
        XCTAssertEqual(job.status, .running)
    }

    func testAIJobStatusEquality() {
        XCTAssertEqual(AIJob.Status.running, AIJob.Status.running)
        XCTAssertEqual(AIJob.Status.completed, AIJob.Status.completed)
        XCTAssertEqual(AIJob.Status.cancelled, AIJob.Status.cancelled)
        XCTAssertEqual(AIJob.Status.failed("err"), AIJob.Status.failed("err"))
        XCTAssertNotEqual(AIJob.Status.running, AIJob.Status.completed)
        XCTAssertNotEqual(AIJob.Status.failed("a"), AIJob.Status.failed("b"))
    }

    @MainActor
    func testAIServiceInitialState() {
        let service = AnnotationAIService()
        XCTAssertNil(service.currentJob)
        XCTAssertFalse(service.isProcessing)
        XCTAssertNil(service.processingStartTime)
    }

    // MARK: - Helpers

    /// Create a test CGImage filled with a solid color
    private func createTestImage(width: Int, height: Int, color: (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4 + 0] = color.0  // R
            pixels[i * 4 + 1] = color.1  // G
            pixels[i * 4 + 2] = color.2  // B
            pixels[i * 4 + 3] = color.3  // A
        }

        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    /// Create a grayscale mask image
    private func createGrayscaleMask(width: Int, height: Int, generator: (Int, Int) -> UInt8) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = generator(x, y)
            }
        }

        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
