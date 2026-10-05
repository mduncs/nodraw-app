import XCTest
import AppKit
@testable import MediaViewer

final class MaskBrushRasterizerTests: XCTestCase {
    func testFortyEightMegapixelStrokeUsesBoundedSingleChannelMask() throws {
        let mask = try XCTUnwrap(MaskBrushRasterizer.image(
            points: [NormalizedPoint(x: 0.1, y: 0.25), NormalizedPoint(x: 0.9, y: 0.25)],
            sourceSize: CGSize(width: 8000, height: 6000), brushSize: 40))
        XCTAssertEqual(mask.width, 2048)
        XCTAssertEqual(mask.height, 1536)
        XCTAssertEqual(mask.bitsPerPixel, 8)
        XCTAssertLessThanOrEqual(mask.bytesPerRow * mask.height, 4 * 1024 * 1024)
        let bitmap = NSBitmapImageRep(cgImage: mask)
        XCTAssertGreaterThan(luminance(bitmap, x: 1024, y: 384), 0.95, "Normalized top-left stroke should be at one-quarter height")
        XCTAssertLessThan(luminance(bitmap, x: 1024, y: 1152), 0.05, "Stroke must not be vertically mirrored")
        XCTAssertLessThan(luminance(bitmap, x: 1024, y: 400), 0.05, "Source-pixel brush diameter must scale with the bounded raster")
    }

    func testStrokePathIsContinuousAndSingleClickPaintsRoundDab() throws {
        let stroke = try XCTUnwrap(MaskBrushRasterizer.image(
            points: [NormalizedPoint(x: 0.1, y: 0.5), NormalizedPoint(x: 0.9, y: 0.5)],
            sourceSize: CGSize(width: 200, height: 100), brushSize: 10))
        let bitmap = NSBitmapImageRep(cgImage: stroke)
        for x in 20..<180 { XCTAssertGreaterThan(luminance(bitmap, x: x, y: 50), 0.95) }
        XCTAssertLessThan(luminance(bitmap, x: 100, y: 60), 0.05)
        let data = try XCTUnwrap(MaskBrushRasterizer.pngData(points: [NormalizedPoint(x: 0.5, y: 0.5)],
            sourceSize: CGSize(width: 100, height: 100), brushSize: 20))
        let dab = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertGreaterThan(luminance(dab, x: 50, y: 50), 0.95)
        XCTAssertLessThan(luminance(dab, x: 60, y: 60), 0.05)
        XCTAssertLessThan(luminance(dab, x: 0, y: 0), 0.05)
    }

    func testEmptyAndInvalidStrokesDoNotAllocateMasks() {
        XCTAssertNil(MaskBrushRasterizer.image(points: [], sourceSize: CGSize(width: 100, height: 100), brushSize: 10))
        XCTAssertNil(MaskBrushRasterizer.image(points: [NormalizedPoint(x: .nan, y: 0)], sourceSize: CGSize(width: 100, height: 100), brushSize: 10))
        XCTAssertNil(MaskBrushRasterizer.image(points: [NormalizedPoint(x: 0, y: 0)], sourceSize: .zero, brushSize: 10))
        XCTAssertNil(MaskBrushRasterizer.image(points: [NormalizedPoint(x: 0, y: 0)], sourceSize: CGSize(width: 100, height: 100), brushSize: 0))
    }

    private func luminance(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
        bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray)?.whiteComponent ?? -1
    }
}
