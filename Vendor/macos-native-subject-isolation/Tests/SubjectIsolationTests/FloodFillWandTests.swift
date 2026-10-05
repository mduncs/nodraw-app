import XCTest
@testable import SubjectIsolation

final class FloodFillWandTests: XCTestCase {

    func testUniformImageSelectsAllConnectedPixels() {
        let rgba = makeRGBA(width: 3, height: 3) { _, _ in
            (255, 0, 0, 255)
        }

        let wand = FloodFillWand(rgba: rgba, width: 3, height: 3, seedX: 1, seedY: 1)
        let result = wand?.computeMask(tolerance: 0)

        XCTAssertEqual(result?.data, Array(repeating: 0xFF, count: 9))
    }

    func testExactToleranceDoesNotCrossColorBoundary() {
        let rgba = makeRGBA(width: 4, height: 3) { x, _ in
            x < 2 ? (255, 0, 0, 255) : (0, 0, 255, 255)
        }

        let wand = FloodFillWand(rgba: rgba, width: 4, height: 3, seedX: 0, seedY: 1)
        let result = wand?.computeMask(tolerance: 0)

        XCTAssertEqual(result?.data, [
            0xFF, 0xFF, 0x00, 0x00,
            0xFF, 0xFF, 0x00, 0x00,
            0xFF, 0xFF, 0x00, 0x00,
        ])
    }

    private func makeRGBA(
        width: Int,
        height: Int,
        colorAt: (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> [UInt8] {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = colorAt(x, y)
                pixels.append(r)
                pixels.append(g)
                pixels.append(b)
                pixels.append(a)
            }
        }

        return pixels
    }
}
