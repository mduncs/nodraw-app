import XCTest
import CoreGraphics
@testable import SubjectIsolation

final class GlowParameterTests: XCTestCase {

    // MARK: - Thin Parameters

    func testThinAtRetina2x() {
        let params = GlowParameters.thin(viewScale: 1.0, screenScale: 2.0)
        XCTAssertEqual(params.minThickness, 0.5)
        XCTAssertEqual(params.maxThickness, 1.5)
        XCTAssertEqual(params.blurRadius, 1.5)
        XCTAssertEqual(params.strokeLengthFraction, 0.25)
        XCTAssertEqual(params.strokeTaperLength, 200.0)
        XCTAssertEqual(params.minOpacity, 1.0)
        XCTAssertEqual(params.maxOpacity, 1.0)
        XCTAssertEqual(params.strokeCount, 8)
    }

    func testThinAt1x() {
        let params = GlowParameters.thin(viewScale: 1.0, screenScale: 1.0)
        XCTAssertEqual(params.strokeCount, 6)
    }

    func testThinAt3x() {
        let params = GlowParameters.thin(viewScale: 1.0, screenScale: 3.0)
        XCTAssertEqual(params.strokeCount, 12)
    }

    func testThinScalesWithViewScale() {
        let params = GlowParameters.thin(viewScale: 2.0, screenScale: 2.0)
        XCTAssertEqual(params.minThickness, 1.0)
        XCTAssertEqual(params.maxThickness, 3.0)
        XCTAssertEqual(params.blurRadius, 3.0)
        XCTAssertEqual(params.strokeTaperLength, 400.0)
    }

    // MARK: - Thick Parameters

    func testThickParameters() {
        let params = GlowParameters.thick(viewScale: 1.0)
        XCTAssertEqual(params.minThickness, 4.0)
        XCTAssertEqual(params.maxThickness, 16.0)
        XCTAssertEqual(params.blurRadius, 20.0)
        XCTAssertEqual(params.strokeLengthFraction, 0.25)
        XCTAssertEqual(params.strokeTaperLength, 200.0)
        XCTAssertEqual(params.minOpacity, 0.3)
        XCTAssertEqual(params.maxOpacity, 0.5)
        XCTAssertEqual(params.strokeCount, 3)
    }

    // MARK: - Duration Calculation

    func testCycleDurationClampsMinimum() {
        // pathLength / 600 = 0.5 → clamped to 4.5
        XCTAssertEqual(GlowParameters.cycleDuration(pathLength: 300), 4.5)
    }

    func testCycleDurationClampsMaximum() {
        // pathLength / 600 = 10.0 → clamped to 6.0
        XCTAssertEqual(GlowParameters.cycleDuration(pathLength: 6000), 6.0)
    }

    func testCycleDurationMidRange() {
        // pathLength / 600 = 5.0 → within [4.5, 6.0]
        XCTAssertEqual(GlowParameters.cycleDuration(pathLength: 3000), 5.0)
    }

    // MARK: - Constants

    func testFadeInDuration() {
        XCTAssertEqual(GlowParameters.fadeInDuration, 2.0)
    }

    func testOpacityTransitionDuration() {
        XCTAssertEqual(GlowParameters.opacityTransitionDuration, 0.35)
    }

    func testColorMatrixShape() {
        XCTAssertEqual(GlowParameters.colorMatrixValues.count, 4)  // 4 rows
        for row in GlowParameters.colorMatrixValues {
            XCTAssertEqual(row.count, 5)  // 5 columns (RGBA + bias)
        }
    }

    func testColorMatrixRedBias() {
        XCTAssertEqual(GlowParameters.colorMatrixValues[0][4], 0.5)
    }

    func testColorMatrixAlphaBias() {
        XCTAssertEqual(GlowParameters.colorMatrixValues[3][4], 0.3)
    }
}
