import XCTest
@testable import MediaViewer

/// Integration tests covering the full annotation lifecycle.
/// Verifies the end-to-end flow: session creation → shape operations →
/// undo/redo → adjustments → serialization → reload.
final class IntegrationTests: XCTestCase {

    // MARK: - Full Lifecycle

    @MainActor
    func testFullAnnotationLifecycle() throws {
        // 1. Create session
        let session = AnnotationEditorSession(itemId: UUID())
        XCTAssertTrue(session.annotationSet.isEmpty)
        XCTAssertFalse(session.isDirty)

        // 2. Add layer + shapes via commands
        session.execute(.addLayer(name: "Shapes"), description: "Add shapes layer")
        let rectId = UUID()
        session.execute(
            .addShape(shape: .rectangle(id: rectId, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2), style: .defaultRectangle), layerId: nil),
            description: "Add rectangle"
        )
        let ellipseId = UUID()
        session.execute(
            .addShape(shape: .ellipse(id: ellipseId, rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse), layerId: nil),
            description: "Add ellipse"
        )

        XCTAssertEqual(session.annotationSet.shapeCount, 2)
        XCTAssertTrue(session.isDirty)

        // 3. Resize shape
        let newRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.4)
        session.execute(.resizeShape(shapeId: rectId, newRect: newRect), description: "Resize rectangle")

        if case .rectangle(_, let rect, _) = session.annotationSet.shape(id: rectId)! {
            XCTAssertEqual(rect.width, 0.5, accuracy: 0.001)
        }

        // 4. Apply photo adjustments
        let adjustments = PhotoAdjustments(brightness: 0.1, contrast: 1.2, saturation: 0.9)
        session.execute(.setAdjustments(adjustments), description: "Adjust photo")
        XCTAssertTrue(session.annotationSet.adjustments?.isModified ?? false)

        // 5. Selection
        session.select(rectId)
        XCTAssertTrue(session.isSelected(rectId))
        XCTAssertEqual(session.selectedShapes.count, 1)

        session.toggleSelection(ellipseId)
        XCTAssertEqual(session.selectedShapeIds.count, 2)

        // 6. Delete selected
        session.deleteSelected()
        XCTAssertEqual(session.annotationSet.shapeCount, 0)
        XCTAssertTrue(session.selectedShapeIds.isEmpty)

        // 7. Undo chain (delete → adjustments → resize → ellipse → rect → layer)
        XCTAssertEqual(session.undoCount, 6) // add layer, add rect, add ellipse, resize, adjust, delete

        session.undo() // undo delete
        XCTAssertEqual(session.annotationSet.shapeCount, 2)

        session.undo() // undo adjustments
        XCTAssertNil(session.annotationSet.adjustments)

        session.undo() // undo resize
        if case .rectangle(_, let rect, _) = session.annotationSet.shape(id: rectId)! {
            XCTAssertEqual(rect.width, 0.3, accuracy: 0.001) // back to original
        }

        // 8. Redo
        session.redo() // redo resize
        if case .rectangle(_, let rect, _) = session.annotationSet.shape(id: rectId)! {
            XCTAssertEqual(rect.width, 0.5, accuracy: 0.001)
        }

        // 9. Serialize and deserialize
        let data = try JSONEncoder().encode(session.annotationSet)
        let decoded = try JSONDecoder().decode(AnnotationSet.self, from: data)

        XCTAssertEqual(decoded.shapeCount, session.annotationSet.shapeCount)
        XCTAssertEqual(decoded.layers.count, session.annotationSet.layers.count)
    }

    // MARK: - Serialization Round-Trip

    func testAnnotationSetRoundTrip() throws {
        // Build a complex annotation set
        var set = AnnotationSet()
        _ = set.addLayer(name: "Drawings")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))
        set.addShape(.arrow(id: UUID(), from: NormalizedPoint(x: 0.1, y: 0.1), to: NormalizedPoint(x: 0.9, y: 0.9), style: .defaultArrow))

        let l2 = set.addLayer(name: "Text")
        set.activeLayerId = l2.id
        set.addShape(.text(id: UUID(), position: NormalizedPoint(x: 0.5, y: 0.5), content: "Hello", style: .memeClassic))

        set.cropRegion = NormalizedRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        set.adjustments = PhotoAdjustments(brightness: 0.1, contrast: 1.1, saturation: 0.9, vignette: 0.5)
        set.layers[0].isLocked = true
        set.layers[1].opacity = 0.8

        // Round-trip
        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(AnnotationSet.self, from: data)

        XCTAssertEqual(decoded.layers.count, 2)
        XCTAssertEqual(decoded.layers[0].name, "Drawings")
        XCTAssertEqual(decoded.layers[0].isLocked, true)
        XCTAssertEqual(decoded.layers[0].shapes.count, 2)
        XCTAssertEqual(decoded.layers[1].name, "Text")
        XCTAssertEqual(decoded.layers[1].opacity, 0.8, accuracy: 0.001)
        XCTAssertEqual(decoded.layers[1].shapes.count, 1)
        XCTAssertNotNil(decoded.cropRegion)
        XCTAssertNotNil(decoded.adjustments)
        XCTAssertEqual(Double(decoded.adjustments?.brightness ?? 0), 0.1, accuracy: 0.001)
        XCTAssertEqual(Double(decoded.adjustments?.vignette ?? 0), 0.5, accuracy: 0.001)

        // Verify text style preserves meme preset fields
        if case .text(_, _, _, let style) = decoded.layers[1].shapes[0] {
            XCTAssertEqual(style.fontWeight, .bold)
            XCTAssertEqual(style.alignment, .center)
            XCTAssertEqual(style.strokeColor, 0x000000FF)
            XCTAssertEqual(style.strokeWidth, 2)
            XCTAssertEqual(style.fontFamily, "Impact")
        } else {
            XCTFail("Expected text shape")
        }
    }

    // MARK: - Legacy Format Migration

    func testLegacyFormatMigration() throws {
        // Legacy JSON: flat shapes array, no layers
        let legacyJSON = """
        {
            "shapes": [
                {
                    "rectangle": {
                        "id": "11111111-1111-1111-1111-111111111111",
                        "rect": { "x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2 },
                        "style": { "strokeColor": 4284481535, "strokeWidth": 3 }
                    }
                }
            ]
        }
        """

        let data = legacyJSON.data(using: .utf8)!
        let set = try JSONDecoder().decode(AnnotationSet.self, from: data)

        // Should migrate to single layer
        XCTAssertEqual(set.layers.count, 1)
        XCTAssertEqual(set.layers[0].name, "Layer 1")
        XCTAssertEqual(set.shapes.count, 1)
        XCTAssertFalse(set.layers[0].isLocked) // Default
        XCTAssertNil(set.adjustments) // Not present in legacy
    }

    // MARK: - Viewport Filtering

    func testVisibleShapesInViewport() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.0, y: 0.0, width: 0.1, height: 0.1), style: .defaultRectangle))
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), style: .defaultRectangle))
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1), style: .defaultRectangle))

        // Full viewport
        let all = set.visibleShapes(in: NormalizedRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(all.count, 3)

        // Top-left quadrant
        let topLeft = set.visibleShapes(in: NormalizedRect(x: 0, y: 0, width: 0.3, height: 0.3))
        XCTAssertEqual(topLeft.count, 1)

        // Bottom-right quadrant
        let bottomRight = set.visibleShapes(in: NormalizedRect(x: 0.7, y: 0.7, width: 0.3, height: 0.3))
        XCTAssertEqual(bottomRight.count, 1)
    }

    // MARK: - Complex Command Scenarios

    func testLayerOperationsWithShapes() {
        var set = AnnotationSet()

        // Add two layers with shapes
        let l1Id = UUID()
        set.apply(.addLayer(name: "Bottom", id: l1Id))
        set.apply(.addShape(shape: .rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle), layerId: l1Id))

        let l2Id = UUID()
        set.apply(.addLayer(name: "Top", id: l2Id))
        set.apply(.addShape(shape: .ellipse(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse), layerId: l2Id))

        // Duplicate top layer
        let dupId = UUID()
        set.apply(.duplicateLayer(layerId: l2Id, newLayerId: dupId))
        XCTAssertEqual(set.layers.count, 3)
        XCTAssertEqual(set.layers[2].name, "Top Copy")

        // Solo bottom layer
        set.apply(.soloLayer(layerId: l1Id))
        XCTAssertTrue(set.layers[0].isVisible)
        XCTAssertFalse(set.layers[1].isVisible)
        XCTAssertFalse(set.layers[2].isVisible)

        // Flatten everything
        set.apply(.flattenLayers)
        XCTAssertEqual(set.layers.count, 1)
        XCTAssertEqual(set.shapes.count, 3) // rect + ellipse + duplicate ellipse
    }

    @MainActor
    func testSessionDuplicateSelected() {
        let session = AnnotationEditorSession(itemId: UUID())
        session.execute(.addLayer(name: "L1"))

        let id1 = UUID()
        session.execute(.addShape(shape: .rectangle(id: id1, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle), layerId: nil))

        session.select(id1)
        session.duplicateSelected()

        XCTAssertEqual(session.annotationSet.shapeCount, 2)
        // Selection should be the new duplicate
        XCTAssertEqual(session.selectedShapeIds.count, 1)
        XCTAssertFalse(session.isSelected(id1)) // Original not selected

        // Undo should remove the duplicate
        session.undo()
        XCTAssertEqual(session.annotationSet.shapeCount, 1)
    }
}
