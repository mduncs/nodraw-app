import XCTest
import PhotoPipeline
@testable import MediaViewer

final class OCRSocialMetadataSanitizerTests: XCTestCase {
    func testSplitDisplayNameAndStrongMarkerAreRemoved() {
        let observations = [
            observation("Samuel James", x: 0.10, y: 0.91, width: 0.18, height: 0.04),
            observation("@Digitalliturgy • [+31 • 7h", x: 0.31, y: 0.905, width: 0.31, height: 0.05),
            observation("Post content remains.", x: 0.10, y: 0.82, width: 0.50, height: 0.04)
        ]

        let sanitized = VisionProcessor.sanitizeSocialMetadataNoise(observations)

        XCTAssertEqual(sanitized.map(\.text), ["Post content remains"])
    }

    func testStandaloneTwoWordNameRemains() {
        let observations = [
            observation("Samuel James", x: 0.10, y: 0.91, width: 0.18, height: 0.04)
        ]

        let sanitized = VisionProcessor.sanitizeSocialMetadataNoise(observations)

        XCTAssertEqual(sanitized.map(\.text), ["Samuel James"])
    }

    func testMergedHeaderPreservesTrailingContent() {
        let observations = [
            observation(
                "Samuel James @Digitalliturgy • [+3] • 7h Post content remains.",
                x: 0.10,
                y: 0.82,
                width: 0.80,
                height: 0.05
            )
        ]

        let sanitized = VisionProcessor.sanitizeSocialMetadataNoise(observations)

        XCTAssertEqual(sanitized.map(\.text), ["Post content remains"])
    }

    private func observation(
        _ text: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> TextObservation {
        TextObservation(
            text: text,
            boundingBox: CGRect(x: x, y: y, width: width, height: height),
            confidence: 1
        )
    }
}
