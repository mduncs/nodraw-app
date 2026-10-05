import XCTest
import CoreGraphics
@testable import SubjectIsolation

final class ContourTracerTests: XCTestCase {

    let tracer = ContourTracer()

    // MARK: - Contour Tracing

    func testTraceContoursOnWhiteCircle() {
        // White circle on black background — should produce contours
        let mask = createCircleMask(size: 200, radius: 60)
        let (full, outer) = tracer.traceContours(mask: mask, simplification: 0.01)
        XCTAssertNotNil(full, "Should detect contour of white circle")
        XCTAssertNotNil(outer, "Should have outer contour")
    }

    func testTraceContoursOnBlackImage() {
        // All black — no contours
        let mask = createSolidImage(width: 100, height: 100, gray: 0.0)
        let (full, outer) = tracer.traceContours(mask: mask, simplification: 0)
        XCTAssertNil(full)
        XCTAssertNil(outer)
    }

    func testSimplificationReducesPoints() {
        let mask = createCircleMask(size: 200, radius: 60)
        let (exactFull, _) = tracer.traceContours(mask: mask, simplification: 0)
        let (simpleFull, _) = tracer.traceContours(mask: mask, simplification: 5.0)

        // Both should exist
        if let exact = exactFull, let simple = simpleFull {
            // Simplified should have fewer or equal path elements
            let exactCount = countPathElements(exact)
            let simpleCount = countPathElements(simple)
            XCTAssertLessThanOrEqual(simpleCount, exactCount,
                "Simplified path should have fewer or equal elements")
        }
    }

    // MARK: - Bounding Box

    func testBoundingBoxOfFullWhite() {
        let mask = createSolidImage(width: 100, height: 100, gray: 1.0)
        let bbox = tracer.boundingBox(of: mask)
        // Should cover the full image (approximately)
        XCTAssertGreaterThan(bbox.width, 0.9)
        XCTAssertGreaterThan(bbox.height, 0.9)
    }

    func testBoundingBoxOfBlack() {
        let mask = createSolidImage(width: 100, height: 100, gray: 0.0)
        let bbox = tracer.boundingBox(of: mask)
        XCTAssertEqual(bbox, .zero)
    }

    // MARK: - Path Length

    func testPathLengthEstimation() {
        // Square path: 100x100 → perimeter ~400
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: 100, height: 100))
        let length = PathUtilities.estimatePathLength(path)
        XCTAssertEqual(length, 400, accuracy: 1.0)
    }

    // MARK: - Path Transform

    func testTransformPathScales() {
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: 1, height: 1))
        let transformed = PathUtilities.transformPath(path, to: CGRect(x: 0, y: 0, width: 500, height: 300))
        let bbox = transformed.boundingBoxOfPath
        XCTAssertEqual(bbox.width, 500, accuracy: 1.0)
        XCTAssertEqual(bbox.height, 300, accuracy: 1.0)
    }

    func testTransformPathAppliesTargetOrigin() {
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: 1, height: 1))
        let transformed = PathUtilities.transformPath(path, to: CGRect(x: 50, y: 25, width: 500, height: 300))
        let bbox = transformed.boundingBoxOfPath
        XCTAssertEqual(bbox.minX, 50, accuracy: 1.0)
        XCTAssertEqual(bbox.minY, 25, accuracy: 1.0)
        XCTAssertEqual(bbox.width, 500, accuracy: 1.0)
        XCTAssertEqual(bbox.height, 300, accuracy: 1.0)
    }

    // MARK: - Helpers

    private func createSolidImage(width: Int, height: Int, gray: CGFloat) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace, bitmapInfo: 0
        )!
        context.setFillColor(gray: gray, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func createCircleMask(size: Int, radius: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size,
            space: colorSpace, bitmapInfo: 0
        )!
        // Black background
        context.setFillColor(gray: 0.0, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // White circle
        context.setFillColor(gray: 1.0, alpha: 1.0)
        let center = CGFloat(size) / 2
        let r = CGFloat(radius)
        context.fillEllipse(in: CGRect(x: center - r, y: center - r, width: r * 2, height: r * 2))
        return context.makeImage()!
    }

    private func countPathElements(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { _ in count += 1 }
        return count
    }
}
