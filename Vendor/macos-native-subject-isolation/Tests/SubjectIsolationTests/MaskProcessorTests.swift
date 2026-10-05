import XCTest
import CoreGraphics
@testable import SubjectIsolation

final class MaskProcessorTests: XCTestCase {

    let processor = MaskProcessor.shared

    // MARK: - Mask Application

    func testApplyMaskProducesCorrectDimensions() {
        let image = createRGBImage(width: 200, height: 150, r: 1.0, g: 0.0, b: 0.0)
        let mask = createGrayImage(width: 200, height: 150, gray: 1.0)
        let result = processor.applyMask(image: image, mask: mask)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.width, 200)
        XCTAssertEqual(result?.height, 150)
    }

    func testApplyMaskScalesWhenDimensionsDiffer() {
        let image = createRGBImage(width: 400, height: 300, r: 1.0, g: 0.0, b: 0.0)
        let mask = createGrayImage(width: 100, height: 75, gray: 1.0)
        let result = processor.applyMask(image: image, mask: mask)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.width, 400)
        XCTAssertEqual(result?.height, 300)
    }

    // MARK: - Mask Combination

    func testCombineMasksEmptyReturnsNil() {
        XCTAssertNil(processor.combineMasks([]))
    }

    func testCombineMasksSingleReturnsSame() {
        let mask = createGrayImage(width: 100, height: 100, gray: 0.5)
        let result = processor.combineMasks([mask])
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.width, 100)
        XCTAssertEqual(result!.height, 100)
    }

    func testCombineMasksMultiple() {
        let mask1 = createGrayImage(width: 100, height: 100, gray: 0.3)
        let mask2 = createGrayImage(width: 100, height: 100, gray: 0.7)
        let result = processor.combineMasks([mask1, mask2])
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.width, 100)
    }

    // MARK: - Mask Scaling

    func testScaleMask() {
        let mask = createGrayImage(width: 50, height: 50, gray: 1.0)
        let scaled = processor.scaleMask(mask, to: CGSize(width: 200, height: 200))
        XCTAssertNotNil(scaled)
        XCTAssertEqual(scaled?.width, 200)
        XCTAssertEqual(scaled?.height, 200)
    }

    // MARK: - Mask Inspection

    func testContainsForegroundIsFalseForBlackMask() {
        let mask = createGrayImage(width: 10, height: 10, gray: 0.0)
        XCTAssertFalse(processor.containsForeground(mask))
    }

    func testContainsForegroundIsTrueForWhiteMask() {
        let mask = createGrayImage(width: 10, height: 10, gray: 1.0)
        XCTAssertTrue(processor.containsForeground(mask))
    }

    func testContainsForegroundHonorsThreshold() {
        let mask = createGrayImage(width: 10, height: 10, gray: 0.03)
        XCTAssertTrue(processor.containsForeground(mask, threshold: 0))
        XCTAssertFalse(processor.containsForeground(mask, threshold: 15))
    }

    // MARK: - Helpers

    private func createGrayImage(width: Int, height: Int, gray: CGFloat) -> CGImage {
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

    private func createRGBImage(width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: r, green: g, blue: b, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
