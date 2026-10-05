import XCTest
@testable import SubjectIsolation

final class SegmentationTests: XCTestCase {

    let isolator = SubjectIsolator()

    // MARK: - Availability

    func testIsAvailable() {
        XCTAssertTrue(SubjectIsolator.isAvailable, "Should be available on macOS 14+")
    }

    func testAvailableTypesIncludesPublicAPIs() {
        let types = isolator.availableTypes
        XCTAssertTrue(types.contains(.foregroundInstance))
        XCTAssertTrue(types.contains(.personInstance))
        XCTAssertTrue(types.contains(.personSegmentation))
    }

    // MARK: - Isolation with synthetic image

    func testIsolateEmptyImageReturnsNoSubjects() async throws {
        // 100x100 solid black image — no subjects to detect
        let cgImage = createSolidImage(width: 100, height: 100, gray: 0.0)
        let result = try await isolator.isolate(image: cgImage, options: .default)
        XCTAssertFalse(result.hasSubjects)
        XCTAssertEqual(result.subjectCount, 0)
        XCTAssertNil(result.foregroundMask)
    }

    func testPersonSegmentationEmptyImage() async throws {
        // VNGeneratePersonSegmentationRequest always returns a pixel buffer
        // observation, even for blank images. personDetected should only be
        // true when the returned matte contains foreground pixels.
        let cgImage = createSolidImage(width: 100, height: 100, gray: 0.0)
        let result = try await isolator.segmentPersons(image: cgImage, quality: .fast)
        XCTAssertNotNil(result.mask, "Vision always returns a mask buffer")
        XCTAssertFalse(result.personDetected)
        XCTAssertEqual(result.quality, .fast)
    }

    func testRemoveBackgroundEmptyImageThrowsNoSubjects() async throws {
        let cgImage = createSolidImage(width: 100, height: 100, gray: 0.0)

        do {
            _ = try await isolator.removeBackground(image: cgImage, quality: .fast)
            XCTFail("Expected noSubjectsDetected")
        } catch IsolationError.noSubjectsDetected {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testIsolateReturnsCorrectImageSize() async throws {
        let cgImage = createSolidImage(width: 200, height: 150, gray: 0.5)
        let result = try await isolator.isolate(image: cgImage)
        XCTAssertEqual(result.imageSize.width, 200)
        XCTAssertEqual(result.imageSize.height, 150)
    }

    // MARK: - Quality levels

    func testAllQualityLevelsWork() async throws {
        let cgImage = createSolidImage(width: 100, height: 100, gray: 0.5)
        for quality in [SegmentationQuality.fast, .balanced, .accurate] {
            let result = try await isolator.segmentPersons(image: cgImage, quality: quality)
            XCTAssertEqual(result.quality, quality)
        }
    }

    // MARK: - Options

    func testDefaultOptions() {
        let opts = IsolationOptions.default
        XCTAssertTrue(opts.requestedTypes.contains(.foregroundInstance))
        XCTAssertTrue(opts.generatePaths)
        XCTAssertEqual(opts.contourSimplification, 0.005)
    }

    func testAllTypesOptions() {
        let opts = IsolationOptions.allTypes
        XCTAssertEqual(opts.requestedTypes.count, SegmentationType.allCases.count)
        XCTAssertEqual(opts.contourSimplification, 0.005)
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
}
