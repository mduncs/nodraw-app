import XCTest
import GRDB
@testable import MediaViewer

/// Smoke tests for the annotation editor subsystem.
/// This target compiles independently from MediaViewerTests so annotation
/// work is never blocked by unrelated test-suite compile failures.
final class AnnotationEditorSmokeTests: XCTestCase {

    // MARK: - Model Smoke

    func testAnnotationSetRoundtrip() throws {
        let id = UUID()
        let shape = AnnotationShape.rectangle(
            id: id,
            rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            style: .defaultRectangle
        )

        var set = AnnotationSet()
        set.addShape(shape)

        XCTAssertFalse(set.isEmpty)
        XCTAssertEqual(set.shapes.count, 1)
        XCTAssertEqual(set.shapes.first?.id, id)
    }

    func testLayerCreationAndActivation() {
        var set = AnnotationSet()
        let layer = set.addLayer(name: "Test Layer")

        XCTAssertEqual(set.layers.count, 1)
        XCTAssertEqual(set.activeLayerId, layer.id)
        XCTAssertEqual(set.activeLayer?.name, "Test Layer")
    }

    func testMultiLayerShapeIsolation() {
        var set = AnnotationSet()
        let layer1 = set.addLayer(name: "Layer 1")
        let shape1Id = UUID()
        set.addShape(.rectangle(id: shape1Id, rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5), style: .defaultRectangle))

        let layer2 = set.addLayer(name: "Layer 2")
        let shape2Id = UUID()
        set.addShape(.ellipse(id: shape2Id, rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3), style: .defaultEllipse))

        // Each layer should contain its own shape
        XCTAssertEqual(set.layers.first(where: { $0.id == layer1.id })?.shapes.count, 1)
        XCTAssertEqual(set.layers.first(where: { $0.id == layer2.id })?.shapes.count, 1)

        // Total shapes across all layers
        XCTAssertEqual(set.shapes.count, 2)
    }

    func testShapeLocationLookup() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let shapeId = UUID()
        set.addShape(.rectangle(id: shapeId, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))

        let location = set.shapeLocation(id: shapeId)
        XCTAssertNotNil(location)
        XCTAssertEqual(location?.layerIndex, 0)
        XCTAssertEqual(location?.shapeIndex, 0)
    }

    func testUpdateShapeInPlace() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let shapeId = UUID()
        set.addShape(.rectangle(id: shapeId, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))

        let updated = set.updateShape(id: shapeId) { shape in
            if case .rectangle(let id, _, let style) = shape {
                shape = .rectangle(id: id, rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3), style: style)
            }
        }

        XCTAssertTrue(updated)
        if case .rectangle(_, let rect, _) = set.shape(id: shapeId) {
            XCTAssertEqual(rect.x, 0.5, accuracy: 0.001)
        } else {
            XCTFail("Shape should still be a rectangle")
        }
    }

    func testRemoveShapeCrossLayer() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let shapeId = UUID()
        set.addShape(.rectangle(id: shapeId, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))

        set.removeShape(id: shapeId)
        XCTAssertNil(set.shape(id: shapeId))
        XCTAssertEqual(set.shapes.count, 0)
    }

    // MARK: - Serialization Smoke

    func testLayeredAnnotationSetCodable() throws {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "Shapes")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), style: .defaultRectangle))
        set.addShape(.text(id: UUID(), position: NormalizedPoint(x: 0.5, y: 0.5), content: "Hello", style: .default))
        let _ = set.addLayer(name: "Masks")
        set.addShape(.mask(id: UUID(), maskData: Data([0xFF, 0x00]), bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1), blendMode: .maskRemove, opacity: 1.0, featherRadius: 2.0))

        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(AnnotationSet.self, from: data)

        XCTAssertEqual(decoded.layers.count, 2)
        XCTAssertEqual(decoded.layers[0].name, "Shapes")
        XCTAssertEqual(decoded.layers[0].shapes.count, 2)
        XCTAssertEqual(decoded.layers[1].name, "Masks")
        XCTAssertEqual(decoded.layers[1].shapes.count, 1)
    }

    func testLegacyFlatShapesDecoding() throws {
        // Simulate legacy JSON with flat "shapes" array instead of "layers"
        let legacyJSON = """
        {
            "shapes": [
                {
                    "rectangle": {
                        "id": "\(UUID().uuidString)",
                        "rect": {"x": 0.1, "y": 0.2, "width": 0.3, "height": 0.4},
                        "style": {"strokeColor": 4283782911, "strokeWidth": 3}
                    }
                }
            ]
        }
        """
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnnotationSet.self, from: data)

        XCTAssertEqual(decoded.layers.count, 1, "Legacy shapes should be placed in a default layer")
        XCTAssertEqual(decoded.shapes.count, 1)
    }

    // MARK: - Database Smoke

    func testAnnotationRecordRoundtrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("item.jpg")
        try Data("fixture".utf8).write(to: file)
        let dbQueue = DatabaseManager(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        try await dbQueue.initialize()
        try await dbQueue.write { db in

            var set = AnnotationSet()
            let _ = set.addLayer(name: "Test")
            set.addShape(.ellipse(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse))

            let itemId = UUID()
            let item = MediaItem(id: itemId, basePath: directory, metadataFile: directory.appendingPathComponent("item.md"), mediaFiles: [file], metadata: MediaMetadata(source: URL(string: "https://example.com/item")!, platform: "test"))
            try MediaItemRecord(from: item).insert(db)
            let record = AnnotationRecord(itemId: itemId, mediaFileIndex: 0, annotationSet: set)
            try record.upsert(db: db)

            let fetched = try AnnotationRecord.fetch(db: db, itemId: itemId, mediaFileIndex: 0)
            XCTAssertNotNil(fetched)

            let recovered = fetched!.toAnnotationSet()
            XCTAssertEqual(recovered.layers.count, 1)
            XCTAssertEqual(recovered.shapes.count, 1)
        }
    }

    // MARK: - Transform Smoke

    func testShapeTransformIdentity() {
        let t = ShapeTransform.identity
        XCTAssertEqual(t.offset.x, 0)
        XCTAssertEqual(t.offset.y, 0)
        XCTAssertEqual(t.scale, 1.0)
        XCTAssertEqual(t.rotation, 0)
    }

    func testShapeTransformTranslation() {
        let t = ShapeTransform.identity.translated(by: NormalizedPoint(x: 0.1, y: 0.2))
        XCTAssertEqual(t.offset.x, 0.1, accuracy: 0.001)
        XCTAssertEqual(t.offset.y, 0.2, accuracy: 0.001)
    }

    func testMirrorHorizontalPreservesLayers() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let shapeId = UUID()
        set.addShape(.rectangle(id: shapeId, rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), style: .defaultRectangle))

        let shape = set.shape(id: shapeId)!
        let mirrored = shape.mirroredHorizontally()

        if case .rectangle(_, let rect, _) = mirrored {
            XCTAssertEqual(rect.x, 0.6, accuracy: 0.001) // 1.0 - 0.1 - 0.3
        } else {
            XCTFail("Mirror should preserve shape type")
        }
    }
}
