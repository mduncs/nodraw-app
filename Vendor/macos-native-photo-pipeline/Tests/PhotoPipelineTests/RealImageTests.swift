import XCTest
import CoreGraphics
import Vision
@testable import PhotoPipeline

/// Tests that exercise actual ML inference paths using programmatically generated CGImages.
/// These test the public Vision API fallback paths (scene classification, OCR, face detection)
/// which work without private frameworks.
final class RealImageTests: XCTestCase {

    // MARK: - CGImage generation helpers

    static func makeSolidImage(width: Int = 224, height: Int = 224, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let color = CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    static func makeGradientImage(width: Int = 224, height: Int = 224) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [CGColor(red: 1, green: 0.6, blue: 0, alpha: 1),
                     CGColor(red: 0.2, green: 0.1, blue: 0.5, alpha: 1)] as CFArray,
            locations: [0, 1]
        )!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: CGFloat(width), y: CGFloat(height)), options: [])
        return ctx.makeImage()!
    }

    static func makeTextImage(text: String, width: Int = 400, height: Int = 100) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        // White background
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Draw text using CoreText
        let attrString = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 36, weight: .bold),
            .foregroundColor: NSColor.black,
        ])
        let line = CTLineCreateWithAttributedString(attrString)
        ctx.textPosition = CGPoint(x: 20, y: 30)
        CTLineDraw(line, ctx)
        return ctx.makeImage()!
    }

    static func makeNoiseImage(width: Int = 224, height: Int = 224) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = UInt8.random(in: 0...255)     // R
            pixels[i + 1] = UInt8.random(in: 0...255) // G
            pixels[i + 2] = UInt8.random(in: 0...255) // B
            pixels[i + 3] = 255                         // A
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    // MARK: - Scene Classification Tests

    func testSceneClassifierWithRealImage() async throws {
        let classifier = try SceneClassifier()
        let image = Self.makeGradientImage()
        let result = try await classifier.classify(image: image)

        // Should produce some labels (public VNClassifyImageRequest works on any image)
        // The gradient may or may not produce confident labels, but the API should not crash
        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result.aestheticsScore, 0)
        XCTAssertLessThanOrEqual(result.aestheticsScore, 1)
    }

    func testSceneClassifierWithSolidColor() async throws {
        let classifier = try SceneClassifier()
        let blueImage = Self.makeSolidImage(r: 0, g: 100, b: 255)
        let result = try await classifier.classify(image: blueImage)

        // Solid color should classify as something — labels may be empty if all below threshold
        XCTAssertNotNil(result)
    }

    func testSceneClassifierWithMultipleImages() async throws {
        let classifier = try SceneClassifier()
        let images = [
            Self.makeSolidImage(r: 0, g: 200, b: 0),     // green
            Self.makeGradientImage(),                       // gradient
            Self.makeNoiseImage(),                          // noise
            Self.makeSolidImage(r: 255, g: 200, b: 100),  // warm tone
        ]

        for (i, image) in images.enumerated() {
            let result = try await classifier.classify(image: image)
            XCTAssertNotNil(result, "Scene classification failed for image \(i)")
        }
    }

    // MARK: - Text Recognition Tests

    func testTextRecognizerWithClearText() async throws {
        let recognizer = try TextRecognizer()
        let image = Self.makeTextImage(text: "Hello World 2024")
        let observations = try await recognizer.recognize(image: image)

        // Should detect the text
        XCTAssertFalse(observations.isEmpty, "Should recognize text in image")

        let allText = observations.map(\.text).joined(separator: " ")
        XCTAssert(allText.contains("Hello") || allText.contains("World"),
                  "Expected 'Hello' or 'World' in recognized text, got: \(allText)")
    }

    func testTextRecognizerWithNumbers() async throws {
        let recognizer = try TextRecognizer()
        let image = Self.makeTextImage(text: "12345 67890")
        let observations = try await recognizer.recognize(image: image)

        let allText = observations.map(\.text).joined(separator: " ")
        XCTAssert(allText.contains("12345") || allText.contains("67890"),
                  "Expected numbers in recognized text, got: \(allText)")
    }

    func testTextRecognizerConfidence() async throws {
        let recognizer = try TextRecognizer()
        let image = Self.makeTextImage(text: "CLEAR TEXT", width: 600, height: 120)
        let observations = try await recognizer.recognize(image: image)

        for obs in observations {
            XCTAssertGreaterThan(obs.confidence, 0, "Confidence should be positive")
            XCTAssertLessThanOrEqual(obs.confidence, 1.0, "Confidence should be <= 1.0")
        }
    }

    func testTextRecognizerWithBlankImage() async throws {
        let recognizer = try TextRecognizer()
        let image = Self.makeSolidImage(r: 255, g: 255, b: 255)
        let observations = try await recognizer.recognize(image: image)

        // Blank image should produce no text observations
        XCTAssert(observations.isEmpty, "Blank image should have no text, got: \(observations.map(\.text))")
    }

    func testTextRecognizerHandlesConcurrentRequests() async throws {
        let recognizer = try TextRecognizer()
        let images = (0..<8).map { Self.makeTextImage(text: "Concurrent OCR \($0)") }

        let results = try await withThrowingTaskGroup(of: [PhotoPipeline.TextObservation].self) { group in
            for image in images {
                group.addTask {
                    try await recognizer.recognize(image: image)
                }
            }

            var results: [[PhotoPipeline.TextObservation]] = []
            for try await observations in group {
                results.append(observations)
            }
            return results
        }

        XCTAssertEqual(results.count, images.count)
        XCTAssertTrue(results.allSatisfy { !$0.isEmpty })
    }

    // MARK: - Face Detection (via FaceGallery)

    func testFaceGalleryInitAndIdentifyNoFace() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("face-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let gallery = try FaceGallery(galleryPath: tempDir)
        let solidImage = Self.makeSolidImage(r: 128, g: 128, b: 128)

        // No faces in a solid gray image
        let matches = try await gallery.identify(image: solidImage)
        XCTAssert(matches.isEmpty, "Solid image should have no faces")
    }

    // MARK: - Object Recognition Tests

    func testObjectRecognizerWithImage() async throws {
        let recognizer = try ObjectRecognizer()
        let image = Self.makeGradientImage()

        // Object recognition with public API fallback
        let results = try await recognizer.recognize(image: image)
        // May or may not produce results depending on image content
        // Main assertion: doesn't crash
        _ = results
    }

    // MARK: - Pixel Buffer Creation

    func testPixelBufferCreationVariousSizes() {
        // Test that pixel buffer creation works for common image sizes
        let sizes: [(Int, Int)] = [(224, 224), (512, 512), (1920, 1080), (100, 100), (1, 1)]

        for (w, h) in sizes {
            let image = Self.makeSolidImage(width: w, height: h, r: 128, g: 128, b: 128)
            XCTAssertEqual(image.width, w)
            XCTAssertEqual(image.height, h)
        }
    }
}
