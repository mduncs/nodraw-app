import XCTest
import AppKit
import SwiftUI
@testable import MediaViewer

/// Zoom/pan geometry, document-relative defaults, text anchoring and editor key routing.
final class EditorCanvasTests: XCTestCase {
    // MARK: Viewport

    func testFitCentersLargeImagesAndNeverEnlargesSmallOnes() {
        let large = EditorViewport(imageSize: CGSize(width: 4000, height: 3000), viewportSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(large.scale, min(944.0 / 4000, 744.0 / 3000), accuracy: 0.000_1)
        XCTAssertEqual(large.imageFrame.midX, 500, accuracy: 0.01)
        XCTAssertEqual(large.imageFrame.midY, 400, accuracy: 0.01)
        XCTAssertTrue(large.isFitted)

        let small = EditorViewport(imageSize: CGSize(width: 400, height: 300), viewportSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(small.scale, 1)
        XCTAssertEqual(small.origin, CGPoint(x: 300, y: 250))
    }

    func testZoomKeepsTheImagePointUnderThePointerStationary() {
        var viewport = EditorViewport(imageSize: CGSize(width: 4000, height: 3000), viewportSize: CGSize(width: 1000, height: 800))
        let anchor = CGPoint(x: 300, y: 300)
        let before = viewport.normalizedPoint(atViewport: anchor)
        viewport.zoom(to: 1, anchor: anchor)
        let after = viewport.normalizedPoint(atViewport: anchor)
        XCTAssertEqual(viewport.zoomPercent, 100)
        XCTAssertFalse(viewport.isFitted)
        XCTAssertEqual(before.x, after.x, accuracy: 0.000_1)
        XCTAssertEqual(before.y, after.y, accuracy: 0.000_1)
    }

    func testPanIsClampedAndAFittedImageKeepsFollowingResizes() {
        var viewport = EditorViewport(imageSize: CGSize(width: 4000, height: 3000), viewportSize: CGSize(width: 1000, height: 800))
        let fitted = viewport.origin
        viewport.pan(by: CGSize(width: 300, height: -200))
        XCTAssertEqual(viewport.origin, fitted, "A fully visible image stays centered")
        XCTAssertTrue(viewport.isFitted)
        viewport.resize(viewport: CGSize(width: 2000, height: 1600))
        XCTAssertEqual(viewport.scale, min(1944.0 / 4000, 1544.0 / 3000), accuracy: 0.000_1)

        viewport.zoom(to: 1, anchor: viewport.viewportCenter)
        viewport.pan(by: CGSize(width: 100_000, height: 100_000))
        XCTAssertEqual(viewport.origin, CGPoint(x: EditorViewport.padding, y: EditorViewport.padding))
        viewport.pan(by: CGSize(width: -100_000, height: -100_000))
        XCTAssertEqual(viewport.imageFrame.maxX, 2000 - EditorViewport.padding, accuracy: 0.01)
        XCTAssertEqual(viewport.imageFrame.maxY, 1600 - EditorViewport.padding, accuracy: 0.01)
    }

    func testZoomedResizeKeepsCenteredPointAndStepsAreBounded() {
        var viewport = EditorViewport(imageSize: CGSize(width: 4000, height: 3000), viewportSize: CGSize(width: 1000, height: 800))
        viewport.zoom(to: 1, anchor: viewport.viewportCenter)
        let center = viewport.normalizedPoint(atViewport: viewport.viewportCenter)
        viewport.resize(viewport: CGSize(width: 1200, height: 700))
        let moved = viewport.normalizedPoint(atViewport: viewport.viewportCenter)
        XCTAssertEqual(center.x, moved.x, accuracy: 0.000_1)
        XCTAssertEqual(center.y, moved.y, accuracy: 0.000_1)
        viewport.stepZoom(in: true)
        XCTAssertEqual(viewport.scale, 1.5, accuracy: 0.000_1)
        for _ in 0..<20 { viewport.stepZoom(in: true) }
        XCTAssertEqual(viewport.scale, 4, accuracy: 0.000_1, "4,000 px sources stop at the 16,000 pt canvas bound")
        for _ in 0..<40 { viewport.stepZoom(in: false) }
        XCTAssertEqual(viewport.scale, viewport.minimumScale, accuracy: 0.000_1)
    }

    func testZoomToSelectionCentersTheSelection() {
        var viewport = EditorViewport(imageSize: CGSize(width: 4000, height: 3000), viewportSize: CGSize(width: 1000, height: 800))
        viewport.zoom(toFit: NormalizedRect(x: 0.6, y: 0.6, width: 0.1, height: 0.1))
        let center = viewport.normalizedPoint(atViewport: viewport.viewportCenter)
        XCTAssertEqual(center.x, 0.65, accuracy: 0.001)
        XCTAssertEqual(center.y, 0.65, accuracy: 0.001)
        XCTAssertEqual(viewport.scale, min(888.0 / 400, 688.0 / 300), accuracy: 0.001)
    }

    @MainActor
    func testViewportModelRoutesCommandsToOneViewport() {
        let model = EditorViewportModel()
        model.zoomIn()
        XCTAssertNil(model.viewport, "Commands before layout are ignored")
        model.layout(imageSize: CGSize(width: 3000, height: 2000), viewportSize: CGSize(width: 900, height: 600))
        model.actualSize()
        XCTAssertEqual(model.viewport?.zoomPercent, 100)
        model.fit()
        XCTAssertEqual(model.viewport?.isFitted, true)
        model.layout(imageSize: CGSize(width: 3000, height: 2000), viewportSize: CGSize(width: 1800, height: 1200))
        XCTAssertEqual(model.viewport?.scale ?? 0, min(1744.0 / 3000, 1144.0 / 2000), accuracy: 0.000_1)
        model.isSpacePanning = true
        model.isSpacePanning = false
    }

    // MARK: Document-relative defaults

    func testDocumentScaleKeepsScreenshotsAndGrowsForLargePhotos() {
        XCTAssertEqual(EditorDocumentScale.factor(for: CGSize(width: 1200, height: 800)), 1)
        XCTAssertEqual(EditorDocumentScale.factor(for: CGSize(width: 1600, height: 1000)), 1)
        XCTAssertEqual(EditorDocumentScale.factor(for: CGSize(width: 4000, height: 3000)), 2.5)
        XCTAssertEqual(EditorDocumentScale.factor(for: CGSize(width: 4000, height: 6000)), 4)
        XCTAssertEqual(EditorDocumentScale.factor(for: CGSize(width: 40_000, height: 100)), 8)
        XCTAssertEqual(EditorDocumentScale.factor(for: .zero), 1)
        XCTAssertEqual(EditorDocumentScale.scaled(.defaultFreeform, by: 2.5).strokeWidth, 10)
        let text = EditorDocumentScale.scaled(.memeModern, by: 4)
        XCTAssertEqual(text.fontSize, 144)
        XCTAssertEqual(text.shadowRadius, 16)
        XCTAssertEqual(text.strokeWidth, TextStyle.memeModern.strokeWidth, "Outline width is relative to font size")
        XCTAssertEqual(EditorDocumentScale.range(1...80, by: 2.5), 1...200)
        XCTAssertEqual(EditorDocumentScale.range(8...160, by: 8, limit: 1_000), 8...1_000)
    }

    // MARK: Text anchoring

    func testTextRendersBelowItsTopLeftAnchorInsideItsSelectionBounds() async throws {
        let source = EditorPixels.image(width: 400, height: 240) { _, _ in [255, 255, 255, 255] }
        let style = TextStyle(fontSize: 40, textColor: 0x000000FF, backgroundColor: nil, fontWeight: .bold)
        let shape = AnnotationShape.text(id: UUID(), position: NormalizedPoint(x: 0.1, y: 0.25), content: "HH", style: style)
        let rendered = try await EditorPixels.render(AnnotationSet(shapes: [shape]), source: source)
        let bounds = EditorShapeGeometry.bounds(of: shape, imageSize: CGSize(width: 400, height: 240))
        let frame = CGRect(x: bounds.x * 400, y: bounds.y * 240, width: bounds.width * 400, height: bounds.height * 240)
        let red = try redChannel(rendered)
        var inkRows: [Int] = []
        var outside = 0
        for y in 0..<240 {
            for x in 0..<400 where red[y * 400 + x] < 100 {
                inkRows.append(y)
                if !frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: x, y: y)) { outside += 1 }
            }
        }
        let top = try XCTUnwrap(inkRows.min()), bottom = try XCTUnwrap(inkRows.max())
        XCTAssertGreaterThanOrEqual(top, 60, "Glyphs start at the anchor (y = 60), not above it")
        XCTAssertLessThanOrEqual(bottom, Int(frame.maxY) + 1)
        XCTAssertEqual(outside, 0, "Every glyph pixel lies inside the selection/hit bounds")
    }

    func testTextBackgroundWrapsTheGlyphsSymmetrically() async throws {
        let source = EditorPixels.image(width: 400, height: 240) { _, _ in [255, 255, 255, 255] }
        let style = TextStyle(fontSize: 40, textColor: 0xFFFFFFFF, backgroundColor: 0x000000FF)
        let shape = AnnotationShape.text(id: UUID(), position: NormalizedPoint(x: 0.25, y: 0.25), content: "Hi", style: style)
        let rendered = try await EditorPixels.render(AnnotationSet(shapes: [shape]), source: source)
        let layout = AnnotationRenderer.textLayout(content: "Hi", style: style)
        let padding = AnnotationRenderer.textBackgroundPadding(for: style)
        // Just inside each padded edge is background; just outside is the white source.
        XCTAssertLessThan(try EditorPixels.pixel(rendered, x: 120, y: Int(60 - padding + 2))[0], 40)
        XCTAssertGreaterThan(try EditorPixels.pixel(rendered, x: 120, y: Int(60 - padding - 3))[0], 200)
        XCTAssertLessThan(try EditorPixels.pixel(rendered, x: 120, y: Int(60 + layout.size.height + padding - 2))[0], 40)
        XCTAssertGreaterThan(try EditorPixels.pixel(rendered, x: 120, y: Int(60 + layout.size.height + padding + 3))[0], 200)
        XCTAssertLessThan(try EditorPixels.pixel(rendered, x: Int(100 - padding + 2), y: 80)[0], 40)
        XCTAssertGreaterThan(try EditorPixels.pixel(rendered, x: Int(100 - padding - 3), y: 80)[0], 200)
    }

    private func redChannel(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { bytes[$0 * 4] }
    }

    func testMultilineTextStacksLinesDownward() {
        let style = TextStyle(fontSize: 30)
        let one = AnnotationRenderer.textLayout(content: "Line", style: style)
        let two = AnnotationRenderer.textLayout(content: "Line\nLonger line", style: style)
        XCTAssertEqual(two.lines.count, 2)
        XCTAssertEqual(two.size.height, one.size.height * 2, accuracy: 0.5)
        XCTAssertGreaterThan(two.size.width, one.size.width)
    }

    // MARK: Workflow placement

    func testOnlyPlacedImageObjectsAreSelectedAfterLiftOrImport() {
        let subject = AnnotationShape.extractedSubject(id: UUID(), assetKey: "k", bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                                                       opacity: 1, transform: .identity, sourceSubjectId: nil)
        let mask = AnnotationShape.rectangle(id: UUID(), rect: NormalizedRect(x: 0, y: 0, width: 1, height: 1), style: .defaultRectangle)
        let layer = UUID()
        let command = AnnotationCommand.group([.addLayer(name: "Subject 1", id: layer),
                                               .group([.addShape(shape: mask, layerId: layer)]),
                                               .addShape(shape: subject, layerId: layer), .setActiveLayer(layerId: layer)])
        XCTAssertEqual(ImageEditorWorkflow.placedImageObjects(in: command), [subject.id])
        XCTAssertTrue(ImageEditorWorkflow.placedImageObjects(in: .addShape(shape: mask, layerId: nil)).isEmpty)
    }

    // MARK: Keyboard routing

    @MainActor
    func testEditorKeysRouteZoomArrangeConfirmAndToolsWithoutTouchingOtherShortcuts() throws {
        let back = UUID(), front = UUID()
        let layer = AnnotationLayer(name: "Marks", shapes: [
            .rectangle(id: back, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle),
            .ellipse(id: front, rect: NormalizedRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2), style: .defaultEllipse)
        ])
        let session = AnnotationEditorSession(itemId: UUID(), annotationSet: AnnotationSet(layers: [layer], activeLayerId: layer.id))
        let view = EditorKeyboardMonitorView()
        view.session = session
        var commands: [EditorKeyCommand] = []
        var doneCount = 0
        view.onCommand = { commands.append($0); return true }
        view.onDone = { doneCount += 1 }

        func press(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], shifted: String? = nil) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: 0, context: nil, characters: shifted ?? characters,
                                         charactersIgnoringModifiers: shifted ?? characters, isARepeat: false, keyCode: keyCode)!
            return view.handle(event, session: session)
        }

        XCTAssertTrue(press("=", 24, .command))
        XCTAssertTrue(press("-", 27, .command))
        XCTAssertTrue(press("0", 29, .command))
        XCTAssertTrue(press("1", 18, .command))
        XCTAssertTrue(press("2", 19, .command))
        XCTAssertTrue(press("\r", 36))
        XCTAssertTrue(press("t", 17))
        XCTAssertTrue(press("c", 8))
        XCTAssertTrue(press(" ", 49))
        XCTAssertEqual(commands, [.zoomIn, .zoomOut, .zoomToFit, .actualSize, .zoomToSelection, .confirm,
                                  .selectTool(.text), .selectTool(.ellipse), .spacePan(true)])

        session.select(back)
        XCTAssertTrue(press("]", 30, .command))
        XCTAssertEqual(session.annotationSet.layers[0].shapes.map(\.id), [front, back])
        XCTAssertTrue(press("[", 33, [.command, .shift], shifted: "{"))
        XCTAssertEqual(session.annotationSet.layers[0].shapes.map(\.id), [back, front])
        XCTAssertTrue(press("}", 30, [.command, .shift]))
        XCTAssertEqual(session.annotationSet.layers[0].shapes.map(\.id), [front, back])
        session.undo()
        XCTAssertEqual(session.annotationSet.layers[0].shapes.map(\.id), [back, front], "Arrange is undoable")

        // Keys the app owns elsewhere are left alone.
        XCTAssertFalse(press("o", 31))
        XCTAssertFalse(press("t", 17, .option))
        XCTAssertFalse(press("]", 30, .option))

        XCTAssertTrue(press("\u{1b}", 53))
        XCTAssertTrue(session.selectedShapeIds.isEmpty)
        XCTAssertEqual(doneCount, 0, "Esc first clears the object selection")
        XCTAssertTrue(press("\u{1b}", 53))
        XCTAssertEqual(doneCount, 1)
    }

    @MainActor
    func testReturnPassesThroughWhenNothingIsPending() {
        let session = AnnotationEditorSession(itemId: UUID())
        let view = EditorKeyboardMonitorView()
        view.session = session
        view.onCommand = { _ in false }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        XCTAssertFalse(view.handle(event, session: session))
    }

    // MARK: Workbench entry

    @MainActor
    func testHasEditsDotSitsOnTheToggleIconNotItsLabel() throws {
        func render(_ hasAnnotations: Bool) throws -> CGImage {
            let renderer = ImageRenderer(content: AnnotationModeToggle(isActive: .constant(false), hasAnnotations: hasAnnotations)
                .environment(\.colorScheme, .dark))
            renderer.scale = 2
            return try XCTUnwrap(renderer.cgImage)
        }
        let plain = try render(false), marked = try render(true)
        XCTAssertEqual(plain.width, marked.width, "The indicator must not change the toggle's layout")
        let a = try rgba(plain), b = try rgba(marked)
        var changed: [Int] = []
        for index in stride(from: 0, to: min(a.count, b.count), by: 4)
        where abs(Int(a[index]) - Int(b[index])) + abs(Int(a[index + 1]) - Int(b[index + 1])) + abs(Int(a[index + 2]) - Int(b[index + 2])) > 60 {
            changed.append((index / 4) % marked.width)
        }
        let dotX = try XCTUnwrap(changed.max(), "No indicator dot was drawn")
        // Icon: 12 pt leading padding + ~17 pt glyph. The "Edit image" label starts after it.
        XCTAssertLessThan(CGFloat(dotX) / 2, 36, "The dot drifted onto the label")
        XCTAssertGreaterThan(CGFloat(try XCTUnwrap(changed.min())) / 2, 16, "The dot should mark the icon's trailing corner")
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }
}
