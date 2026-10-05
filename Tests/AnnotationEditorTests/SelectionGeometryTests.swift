import XCTest
@testable import MediaViewer

/// Production geometry used by canvas move/resize, including multi-selection and scaled image layers.
final class SelectionGeometryTests: XCTestCase {
    func testMovingMixedSelectionPreservesDocumentThroughUndo() {
        let shapes: [AnnotationShape] = [
            .rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3), style: .defaultRectangle),
            .text(id: UUID(), position: NormalizedPoint(x: 0.3, y: 0.4), content: "Caption", style: .default),
            .freeform(id: UUID(), points: [NormalizedPoint(x: 0.2, y: 0.3), NormalizedPoint(x: 0.4, y: 0.5)], style: .defaultFreeform),
            .mask(id: UUID(), maskData: Data([1, 2, 3]), bounds: NormalizedRect(x: 0, y: 0, width: 0.7, height: 0.8), blendMode: .maskRemove, opacity: 0.5)
        ]
        var document = AnnotationSet(layers: [AnnotationLayer(name: "Mixed", opacity: 0.6, shapes: shapes)])
        let original = document
        let delta = NormalizedPoint(x: 0.12, y: -0.07)
        let moved = shapes.map { EditorShapeGeometry.moved($0, by: delta) }
        let result = document.apply(.group(moved.map { .replaceShape(shapeId: $0.id, newShape: $0) }))
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(document.shapes.map(\.id), shapes.map(\.id))
        XCTAssertEqual(document.layers[0].opacity, 0.6)
        if case .text(_, let point, let text, _) = document.shapes[1] {
            XCTAssertEqual(point.x, 0.42, accuracy: 0.0001)
            XCTAssertEqual(point.y, 0.33, accuracy: 0.0001)
            XCTAssertEqual(text, "Caption")
        } else { XCTFail("Text shape lost during move") }
        _ = document.apply(result.inverse)
        XCTAssertEqual(document, original)
    }

    func testResizeImageObjectUsesVisibleBoundsWithoutApplyingScaleTwice() {
        let shape = AnnotationShape.extractedSubject(
            id: UUID(), assetKey: "subject.png", bounds: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.2),
            opacity: 0.7, transform: ShapeTransform(offset: NormalizedPoint(x: 0.05, y: -0.1), scale: 2, rotation: 0), sourceSubjectId: UUID()
        )
        let old = shape.boundingRect
        let target = NormalizedRect(x: 0.2, y: 0.3, width: 0.3, height: 0.6)
        let resized = EditorShapeGeometry.resized(shape, from: old, to: target)
        XCTAssertEqual(resized.boundingRect.x, target.x, accuracy: 0.0001)
        XCTAssertEqual(resized.boundingRect.y, target.y, accuracy: 0.0001)
        XCTAssertEqual(resized.boundingRect.width, target.width, accuracy: 0.0001)
        XCTAssertEqual(resized.boundingRect.height, target.height, accuracy: 0.0001)
        XCTAssertEqual(resized.id, shape.id)
        if case .extractedSubject(_, let key, _, let opacity, let transform, let source) = resized {
            XCTAssertEqual(key, "subject.png")
            XCTAssertEqual(opacity, 0.7)
            XCTAssertEqual(transform.scale, 2)
            XCTAssertNotNil(source)
        } else { XCTFail("Image layer lost during resize") }
    }

    func testGroupResizeMaintainsRelativePlacementAndArrowDirection() {
        let arrow = AnnotationShape.arrow(id: UUID(), from: NormalizedPoint(x: 0.4, y: 0.5), to: NormalizedPoint(x: 0.2, y: 0.3), style: .defaultArrow)
        let resized = EditorShapeGeometry.resized(arrow,
            from: NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4),
            to: NormalizedRect(x: 0.2, y: 0.3, width: 0.2, height: 0.6))
        if case .arrow(_, let from, let to, _) = resized {
            XCTAssertEqual(from.x, 0.35, accuracy: 0.0001)
            XCTAssertEqual(from.y, 0.9, accuracy: 0.0001)
            XCTAssertEqual(to.x, 0.25, accuracy: 0.0001)
            XCTAssertEqual(to.y, 0.6, accuracy: 0.0001)
        } else { XCTFail("Arrow lost during resize") }
    }

    func testUnionIncludesEverySelectedObjectAndEmptySelectionHasNoFrame() {
        XCTAssertNil(EditorShapeGeometry.union([]))
        let union = EditorShapeGeometry.union([
            NormalizedRect(x: -0.1, y: 0.4, width: 0.3, height: 0.2),
            NormalizedRect(x: 0.5, y: 0.2, width: 0.1, height: 0.2)
        ])
        XCTAssertEqual(union?.x, -0.1)
        XCTAssertEqual(union?.y, 0.2)
        XCTAssertEqual(union!.width, 0.7, accuracy: 0.0001)
        XCTAssertEqual(union!.height, 0.4, accuracy: 0.0001)
    }
}
