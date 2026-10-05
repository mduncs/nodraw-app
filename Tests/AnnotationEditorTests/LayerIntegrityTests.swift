import XCTest
@testable import MediaViewer

/// Tests for layer integrity under all mutation operations.
/// Verifies that no operation can corrupt layer boundaries.
final class LayerIntegrityTests: XCTestCase {

    // MARK: - Add Shape

    func testAddShapeToActiveLayer() {
        var set = AnnotationSet()
        let layer1 = set.addLayer(name: "L1")
        let layer2 = set.addLayer(name: "L2")
        set.activeLayerId = layer1.id

        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))

        XCTAssertEqual(set.layers.first(where: { $0.id == layer1.id })?.shapes.count, 1)
        XCTAssertEqual(set.layers.first(where: { $0.id == layer2.id })?.shapes.count, 0)
    }

    func testAddShapeToSpecificLayer() {
        var set = AnnotationSet()
        let layer1 = set.addLayer(name: "L1")
        let layer2 = set.addLayer(name: "L2")
        set.activeLayerId = layer1.id

        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle), toLayerId: layer2.id)

        XCTAssertEqual(set.layers.first(where: { $0.id == layer1.id })?.shapes.count, 0)
        XCTAssertEqual(set.layers.first(where: { $0.id == layer2.id })?.shapes.count, 1)
    }

    func testAddShapeCreatesDefaultLayerWhenEmpty() {
        var set = AnnotationSet()
        XCTAssertTrue(set.layers.isEmpty)

        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))

        XCTAssertEqual(set.layers.count, 1)
        XCTAssertEqual(set.layers[0].shapes.count, 1)
        XCTAssertNotNil(set.activeLayerId)
    }

    // MARK: - Remove Shape

    func testRemoveShapeFromCorrectLayer() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let shapeId = UUID()
        set.addShape(.rectangle(id: shapeId, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))

        let _ = set.addLayer(name: "L2")
        set.addShape(.ellipse(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse))

        set.removeShape(id: shapeId)

        XCTAssertEqual(set.layers[0].shapes.count, 0, "Shape removed from L1")
        XCTAssertEqual(set.layers[1].shapes.count, 1, "L2 untouched")
    }

    func testRemoveNonexistentShapeIsNoOp() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))

        set.removeShape(id: UUID()) // nonexistent

        XCTAssertEqual(set.layers[0].shapes.count, 1, "No change")
    }

    // MARK: - Update Shape

    func testUpdateShapeInPlace() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let shapeId = UUID()
        set.addShape(.rectangle(id: shapeId, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))

        let _ = set.addLayer(name: "L2")
        set.addShape(.ellipse(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse))

        set.updateShape(id: shapeId) { shape in
            if case .rectangle(let id, _, let style) = shape {
                shape = .rectangle(id: id, rect: NormalizedRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1), style: style)
            }
        }

        // Updated in L1
        if case .rectangle(_, let rect, _) = set.layers[0].shapes[0] {
            XCTAssertEqual(rect.x, 0.9, accuracy: 0.001)
        } else {
            XCTFail("Should still be rectangle")
        }
        // L2 untouched
        XCTAssertEqual(set.layers[1].shapes.count, 1)
    }

    func testReplaceShape() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let shapeId = UUID()
        set.addShape(.rectangle(id: shapeId, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))

        let replacement = AnnotationShape.ellipse(id: shapeId, rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3), style: .defaultEllipse)
        let success = set.replaceShape(id: shapeId, with: replacement)

        XCTAssertTrue(success)
        if case .ellipse = set.layers[0].shapes[0] {
            // ok
        } else {
            XCTFail("Shape should now be an ellipse")
        }
    }

    // MARK: - Mirror Operations

    func testMirrorHorizontalPreservesAllLayers() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "Shapes")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), style: .defaultRectangle))
        let _ = set.addLayer(name: "Masks")
        set.addShape(.mask(id: UUID(), maskData: Data([0xFF]), bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), blendMode: .maskRemove, opacity: 1.0, featherRadius: 2.0))
        let _ = set.addLayer(name: "Subjects")
        set.addShape(.extractedSubject(id: UUID(), assetKey: "test", bounds: NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5), opacity: 1.0, transform: .identity, sourceSubjectId: nil))

        set.mirrorAllHorizontally()

        XCTAssertEqual(set.layers.count, 3)
        XCTAssertEqual(set.layers[0].shapes.count, 1)
        XCTAssertEqual(set.layers[1].shapes.count, 1)
        XCTAssertEqual(set.layers[2].shapes.count, 1)

        // Verify mirror actually happened
        if case .rectangle(_, let rect, _) = set.layers[0].shapes[0] {
            XCTAssertEqual(rect.x, 0.6, accuracy: 0.001) // 1.0 - 0.1 - 0.3
        }
    }

    func testMirrorVerticalPreservesAllLayers() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), style: .defaultRectangle))
        let _ = set.addLayer(name: "L2")
        set.addShape(.ellipse(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse))

        set.mirrorAllVertically()

        XCTAssertEqual(set.layers[0].shapes.count, 1)
        XCTAssertEqual(set.layers[1].shapes.count, 1)

        if case .rectangle(_, let rect, _) = set.layers[0].shapes[0] {
            XCTAssertEqual(rect.y, 0.4, accuracy: 0.001) // 1.0 - 0.2 - 0.4
        }
    }

    // MARK: - Feather Update

    func testFeatherUpdateOnlyAffectsTargetMask() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "Masks")
        let mask1Id = UUID()
        let mask2Id = UUID()
        set.addShape(.mask(id: mask1Id, maskData: Data([0xFF]), bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1), blendMode: .maskRemove, opacity: 1.0, featherRadius: 2.0))
        set.addShape(.mask(id: mask2Id, maskData: Data([0x00]), bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1), blendMode: .maskKeep, opacity: 1.0, featherRadius: 3.0))

        let _ = set.addLayer(name: "Shapes")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))

        // Update only mask1
        set.updateShape(id: mask1Id) { shape in
            shape = shape.withFeatherRadius(8.0)
        }

        // mask1 updated
        XCTAssertEqual(set.shape(id: mask1Id)?.featherRadius, 8.0)
        // mask2 untouched
        XCTAssertEqual(set.shape(id: mask2Id)?.featherRadius, 3.0)
        // Shapes layer untouched
        XCTAssertEqual(set.layers[1].shapes.count, 1)
    }

    // MARK: - Transform Operations

    func testTranslateExtractedSubject() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "Subjects")
        let subjectId = UUID()
        set.addShape(.extractedSubject(id: subjectId, assetKey: "test", bounds: NormalizedRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5), opacity: 1.0, transform: .identity, sourceSubjectId: nil))

        let _ = set.addLayer(name: "Other")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))

        let success = set.translateShape(id: subjectId, delta: NormalizedPoint(x: 0.1, y: -0.05))

        XCTAssertTrue(success)
        if case .extractedSubject(_, _, _, _, let transform, _) = set.shape(id: subjectId) {
            XCTAssertEqual(transform.offset.x, 0.1, accuracy: 0.001)
            XCTAssertEqual(transform.offset.y, -0.05, accuracy: 0.001)
        }
        // Other layer untouched
        XCTAssertEqual(set.layers[1].shapes.count, 1)
    }

    // MARK: - TransformAllShapes

    func testTransformAllShapesIsolatesLayers() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))
        set.addShape(.ellipse(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse))

        let _ = set.addLayer(name: "L2")
        let maskId = UUID()
        set.addShape(.mask(id: maskId, maskData: Data([0xFF]), bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1), blendMode: .maskRemove, opacity: 1.0, featherRadius: 1.0))

        set.transformAllShapes { $0.withFeatherRadius(10.0) }

        // Layer structure preserved
        XCTAssertEqual(set.layers[0].shapes.count, 2)
        XCTAssertEqual(set.layers[1].shapes.count, 1)

        // Mask feather updated
        XCTAssertEqual(set.shape(id: maskId)?.featherRadius, 10.0)
    }

    // MARK: - Layer Operations

    func testLayerReorderPreservesShapes() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "Bottom")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))
        let _ = set.addLayer(name: "Middle")
        set.addShape(.ellipse(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse))
        let _ = set.addLayer(name: "Top")
        set.addShape(.text(id: UUID(), position: NormalizedPoint(x: 0.5, y: 0.5), content: "text", style: .default))

        set.moveLayer(from: 0, to: 3) // Move Bottom to top

        XCTAssertEqual(set.layers[0].name, "Middle")
        XCTAssertEqual(set.layers[1].name, "Top")
        XCTAssertEqual(set.layers[2].name, "Bottom")
        XCTAssertEqual(set.shapes.count, 3, "Total shapes unchanged")
    }

    func testLayerDeletePreservesOtherLayers() {
        var set = AnnotationSet()
        let layer1 = set.addLayer(name: "Keep")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))
        let layer2 = set.addLayer(name: "Delete")
        set.addShape(.ellipse(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse))
        set.activeLayerId = layer2.id

        set.removeLayer(id: layer2.id)

        XCTAssertEqual(set.layers.count, 1)
        XCTAssertEqual(set.layers[0].name, "Keep")
        XCTAssertEqual(set.layers[0].shapes.count, 1)
        XCTAssertEqual(set.activeLayerId, layer1.id, "Active layer should fall back")
    }

    // MARK: - Serialization Roundtrip

    func testMultiLayerSerializationRoundtrip() throws {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "Shapes")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), style: .defaultRectangle))
        let _ = set.addLayer(name: "Masks")
        set.addShape(.mask(id: UUID(), maskData: Data([0xFF, 0x00]), bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1), blendMode: .maskRemove, opacity: 1.0, featherRadius: 3.5))
        set.cropRegion = NormalizedRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)

        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(AnnotationSet.self, from: data)

        XCTAssertEqual(decoded.layers.count, 2)
        XCTAssertEqual(decoded.layers[0].name, "Shapes")
        XCTAssertEqual(decoded.layers[0].shapes.count, 1)
        XCTAssertEqual(decoded.layers[1].name, "Masks")
        XCTAssertEqual(decoded.layers[1].shapes.count, 1)
        XCTAssertNotNil(decoded.cropRegion)

        // Verify feather survived roundtrip
        if case .mask(_, _, _, _, _, let feather) = decoded.layers[1].shapes[0] {
            XCTAssertEqual(feather, 3.5)
        } else {
            XCTFail("Expected mask")
        }
    }

    // MARK: - Stress: Many Layers

    func testManyLayersPreserveIntegrity() {
        var set = AnnotationSet()
        for i in 0..<20 {
            let _ = set.addLayer(name: "Layer \(i)")
            set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: CGFloat(i) / 20.0, y: 0.1, width: 0.04, height: 0.1), style: .defaultRectangle))
        }

        XCTAssertEqual(set.layers.count, 20)
        XCTAssertEqual(set.shapes.count, 20)

        // Mirror all
        set.mirrorAllHorizontally()

        // Still 20 layers, 20 shapes
        XCTAssertEqual(set.layers.count, 20)
        XCTAssertEqual(set.shapes.count, 20)

        // Each layer still has exactly 1 shape
        for layer in set.layers {
            XCTAssertEqual(layer.shapes.count, 1, "Layer '\(layer.name)' should have exactly 1 shape")
        }
    }
}
