import XCTest
@testable import SubjectIsolation

final class TrimapGeneratorTests: XCTestCase {

    func testGenerateRectTrimapUsesOnlyThreeClasses() {
        let path = CGMutablePath()
        path.addRect(CGRect(x: 5, y: 5, width: 30, height: 30))

        let trimap = TrimapGenerator(boundaryWidth: 4).generate(
            path: path,
            width: 40,
            height: 40
        )

        XCTAssertNotNil(trimap)
        XCTAssertEqual(Set(trimap!.data), [
            TrimapResult.background,
            TrimapResult.unknown,
            TrimapResult.foreground,
        ])
        XCTAssertTrue(trimap!.isValid)
    }

    func testGenerateRejectsInvalidDimensions() {
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: 10, height: 10))

        XCTAssertNil(TrimapGenerator().generate(path: path, width: 0, height: 10))
        XCTAssertNil(TrimapGenerator().generate(path: path, width: 10, height: 0))
    }

    func testGenerateRejectsTrimapWithoutUnknownBoundary() {
        let path = CGMutablePath()
        path.addRect(CGRect(x: 2, y: 2, width: 6, height: 6))

        let trimap = TrimapGenerator(boundaryWidth: 0).generate(
            path: path,
            width: 10,
            height: 10
        )

        XCTAssertNil(trimap)
    }
}
