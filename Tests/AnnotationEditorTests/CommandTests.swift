import XCTest
@testable import MediaViewer

/// Tests for AnnotationCommand application, inverse generation, and undo/redo.
final class CommandTests: XCTestCase {

    // MARK: - Shape Commands

    func testAddShapeAndUndo() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let shape = AnnotationShape.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle)

        let result = set.apply(.addShape(shape: shape, layerId: nil))
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(set.shapes.count, 1)

        // Apply inverse (undo)
        let undoResult = set.apply(result.inverse)
        XCTAssertTrue(undoResult.didChange)
        XCTAssertEqual(set.shapes.count, 0)
    }

    func testRemoveShapeAndUndo() {
        var set = AnnotationSet()
        let layer = set.addLayer(name: "L1")
        let shapeId = UUID()
        let shape = AnnotationShape.rectangle(id: shapeId, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle)
        set.addShape(shape, toLayerId: layer.id)

        let result = set.apply(.removeShape(shapeId: shapeId))
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(set.shapes.count, 0)

        // Undo — shape returns to the correct layer
        let undoResult = set.apply(result.inverse)
        XCTAssertTrue(undoResult.didChange)
        XCTAssertEqual(set.shapes.count, 1)
        XCTAssertNotNil(set.shape(id: shapeId))
    }

    func testReplaceShapeAndUndo() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let shapeId = UUID()
        let original = AnnotationShape.rectangle(id: shapeId, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle)
        set.addShape(original)

        let updated = AnnotationShape.rectangle(id: shapeId, rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3), style: .defaultRectangle)
        let result = set.apply(.replaceShape(shapeId: shapeId, newShape: updated))
        XCTAssertTrue(result.didChange)

        if case .rectangle(_, let rect, _) = set.shape(id: shapeId)! {
            XCTAssertEqual(rect.x, 0.5, accuracy: 0.001)
        }

        // Undo
        set.apply(result.inverse)
        if case .rectangle(_, let rect, _) = set.shape(id: shapeId)! {
            XCTAssertEqual(rect.x, 0.1, accuracy: 0.001)
        }
    }

    func testRemoveNonexistentShapeIsNoChange() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let result = set.apply(.removeShape(shapeId: UUID()))
        XCTAssertFalse(result.didChange)
    }

    // MARK: - Layer Commands

    func testAddLayerAndUndo() {
        var set = AnnotationSet()
        let layerId = UUID()
        let result = set.apply(.addLayer(name: "Test Layer", id: layerId))
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(set.layers.count, 1)
        XCTAssertEqual(set.layers[0].name, "Test Layer")
        XCTAssertEqual(set.activeLayerId, layerId)

        // Undo
        set.apply(result.inverse)
        XCTAssertEqual(set.layers.count, 0)
    }

    func testToggleLayerVisibility() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        XCTAssertTrue(set.layers[0].isVisible)

        let result = set.apply(.toggleLayerVisibility(layerId: set.layers[0].id))
        XCTAssertFalse(set.layers[0].isVisible)

        // Toggle is its own inverse
        set.apply(result.inverse)
        XCTAssertTrue(set.layers[0].isVisible)
    }

    func testSetLayerOpacityAndUndo() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let layerId = set.layers[0].id
        XCTAssertEqual(set.layers[0].opacity, 1.0)

        let result = set.apply(.setLayerOpacity(layerId: layerId, opacity: 0.5))
        XCTAssertEqual(set.layers[0].opacity, 0.5, accuracy: 0.001)

        set.apply(result.inverse)
        XCTAssertEqual(set.layers[0].opacity, 1.0, accuracy: 0.001)
    }

    func testSetLayerLockedAndUndo() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let layerId = set.layers[0].id
        XCTAssertFalse(set.layers[0].isLocked)

        let result = set.apply(.setLayerLocked(layerId: layerId, locked: true))
        XCTAssertTrue(set.layers[0].isLocked)

        set.apply(result.inverse)
        XCTAssertFalse(set.layers[0].isLocked)
    }

    func testRenameLayerAndUndo() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "Original")
        let layerId = set.layers[0].id

        let result = set.apply(.renameLayer(layerId: layerId, name: "Renamed"))
        XCTAssertEqual(set.layers[0].name, "Renamed")

        set.apply(result.inverse)
        XCTAssertEqual(set.layers[0].name, "Original")
    }

    func testSoloAndUnsolo() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let l2 = set.addLayer(name: "L2")
        let _ = set.addLayer(name: "L3")

        let result = set.apply(.soloLayer(layerId: l2.id))
        XCTAssertFalse(set.layers[0].isVisible)
        XCTAssertTrue(set.layers[1].isVisible)
        XCTAssertFalse(set.layers[2].isVisible)

        // Undo restores all visibility
        set.apply(result.inverse)
        XCTAssertTrue(set.layers[0].isVisible)
        XCTAssertTrue(set.layers[1].isVisible)
        XCTAssertTrue(set.layers[2].isVisible)
    }

    func testDuplicateLayerAndUndo() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "Original")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))

        let newLayerId = UUID()
        let result = set.apply(.duplicateLayer(layerId: set.layers[0].id, newLayerId: newLayerId))
        XCTAssertEqual(set.layers.count, 2)
        XCTAssertEqual(set.layers[1].name, "Original Copy")
        XCTAssertEqual(set.layers[1].shapes.count, 1)
        // Duplicate shapes should have new IDs
        XCTAssertNotEqual(set.layers[0].shapes[0].id, set.layers[1].shapes[0].id)

        set.apply(result.inverse)
        XCTAssertEqual(set.layers.count, 1)
    }

    // MARK: - Canvas Commands

    func testMirrorHorizontallyIsOwnInverse() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), style: .defaultRectangle))
        let original = set.layers[0].shapes[0]

        let result = set.apply(.mirrorAllHorizontally)
        XCTAssertTrue(result.didChange)

        // Apply inverse (mirror again)
        set.apply(result.inverse)
        if case .rectangle(_, let rect, _) = set.layers[0].shapes[0],
           case .rectangle(_, let origRect, _) = original {
            XCTAssertEqual(rect.x, origRect.x, accuracy: 0.001)
            XCTAssertEqual(rect.y, origRect.y, accuracy: 0.001)
        }
    }

    func testSetCropRegionAndUndo() {
        var set = AnnotationSet()
        XCTAssertNil(set.cropRegion)

        let crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let result = set.apply(.setCropRegion(crop))
        XCTAssertEqual(set.cropRegion, crop)

        set.apply(result.inverse)
        XCTAssertNil(set.cropRegion)
    }

    func testClearAllAndUndo() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))
        let _ = set.addLayer(name: "L2")
        set.addShape(.ellipse(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse))
        set.cropRegion = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

        let result = set.apply(.clearAll)
        XCTAssertTrue(set.layers.isEmpty)
        XCTAssertNil(set.cropRegion)

        // Undo restores everything
        set.apply(result.inverse)
        XCTAssertEqual(set.layers.count, 2)
        XCTAssertEqual(set.shapes.count, 2)
        XCTAssertNotNil(set.cropRegion)
    }

    // MARK: - Multi-Select Commands

    func testDeleteMultipleShapes() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        set.addShape(.rectangle(id: id1, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))
        set.addShape(.ellipse(id: id2, rect: NormalizedRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2), style: .defaultEllipse))
        set.addShape(.rectangle(id: id3, rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultRectangle))

        let result = set.apply(.deleteShapes(shapeIds: [id1, id3]))
        XCTAssertEqual(set.shapes.count, 1)
        XCTAssertNotNil(set.shape(id: id2))

        // Undo restores deleted shapes
        set.apply(result.inverse)
        XCTAssertEqual(set.shapes.count, 3)
    }

    // MARK: - Arrange Commands

    func testBringForwardAndUndo() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        set.addShape(.rectangle(id: id1, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), style: .defaultRectangle))
        set.addShape(.rectangle(id: id2, rect: NormalizedRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1), style: .defaultRectangle))
        set.addShape(.rectangle(id: id3, rect: NormalizedRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1), style: .defaultRectangle))

        // id1 is at index 0, bring forward to index 1
        let result = set.apply(.bringForward(shapeId: id1))
        XCTAssertEqual(set.layers[0].shapes[0].id, id2)
        XCTAssertEqual(set.layers[0].shapes[1].id, id1)
        XCTAssertEqual(set.layers[0].shapes[2].id, id3)

        // Undo
        set.apply(result.inverse)
        XCTAssertEqual(set.layers[0].shapes[0].id, id1)
        XCTAssertEqual(set.layers[0].shapes[1].id, id2)
        XCTAssertEqual(set.layers[0].shapes[2].id, id3)
    }

    func testBringToFrontAndUndo() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        set.addShape(.rectangle(id: id1, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), style: .defaultRectangle))
        set.addShape(.rectangle(id: id2, rect: NormalizedRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1), style: .defaultRectangle))
        set.addShape(.rectangle(id: id3, rect: NormalizedRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1), style: .defaultRectangle))

        let result = set.apply(.bringToFront(shapeId: id1))
        XCTAssertEqual(set.layers[0].shapes.last?.id, id1)

        set.apply(result.inverse)
        XCTAssertEqual(set.layers[0].shapes.first?.id, id1)
    }

    // MARK: - Group Commands

    func testGroupCommandAndUndo() {
        var set = AnnotationSet()
        let layerId = UUID()
        let shapeId = UUID()

        let commands: [AnnotationCommand] = [
            .addLayer(name: "L1", id: layerId),
            .addShape(shape: .rectangle(id: shapeId, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle), layerId: layerId),
        ]

        let result = set.apply(.group(commands))
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(set.layers.count, 1)
        XCTAssertEqual(set.shapes.count, 1)

        // Undo the whole group
        set.apply(result.inverse)
        XCTAssertEqual(set.shapes.count, 0)
        XCTAssertEqual(set.layers.count, 0)
    }

    // MARK: - Command Determinism

    func testCommandReplayProducesSameResult() {
        // Record a sequence of commands
        let commands: [AnnotationCommand] = [
            .addLayer(name: "Background", id: UUID()),
            .addShape(shape: .rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3), style: .defaultRectangle), layerId: nil),
            .addShape(shape: .ellipse(id: UUID(), rect: NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), style: .defaultEllipse), layerId: nil),
            .mirrorAllHorizontally,
            .setCropRegion(NormalizedRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)),
        ]

        // Play forward
        var set1 = AnnotationSet()
        for cmd in commands {
            set1.apply(cmd)
        }

        // Play forward again from scratch
        var set2 = AnnotationSet()
        for cmd in commands {
            set2.apply(cmd)
        }

        // Results should be identical
        XCTAssertEqual(set1.shapes.count, set2.shapes.count)
        XCTAssertEqual(set1.cropRegion, set2.cropRegion)
        XCTAssertEqual(set1.layers.count, set2.layers.count)

        for i in 0..<set1.layers.count {
            XCTAssertEqual(set1.layers[i].shapes.count, set2.layers[i].shapes.count)
            XCTAssertEqual(set1.layers[i].name, set2.layers[i].name)
        }
    }

    func testFullUndoRestoresEmptyState() {
        var set = AnnotationSet()
        var inverses: [AnnotationCommand] = []

        let layerId = UUID()
        var r = set.apply(.addLayer(name: "L1", id: layerId))
        inverses.append(r.inverse)

        r = set.apply(.addShape(shape: .rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle), layerId: nil))
        inverses.append(r.inverse)

        r = set.apply(.addShape(shape: .ellipse(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse), layerId: nil))
        inverses.append(r.inverse)

        XCTAssertEqual(set.shapes.count, 2)
        XCTAssertEqual(set.layers.count, 1)

        // Undo all in reverse order
        for inverse in inverses.reversed() {
            set.apply(inverse)
        }

        XCTAssertEqual(set.shapes.count, 0)
        XCTAssertEqual(set.layers.count, 0)
    }

    // MARK: - Flatten + Merge

    func testFlattenLayersAndUndo() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))
        let _ = set.addLayer(name: "L2")
        set.addShape(.ellipse(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse))

        let result = set.apply(.flattenLayers)
        XCTAssertEqual(set.layers.count, 1)
        XCTAssertEqual(set.layers[0].name, "Flattened")
        XCTAssertEqual(set.shapes.count, 2)

        // Undo restores both layers
        set.apply(result.inverse)
        XCTAssertEqual(set.layers.count, 2)
        XCTAssertEqual(set.shapes.count, 2)
    }

    func testMergeLayerDown() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "Bottom")
        set.addShape(.rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle))
        let top = set.addLayer(name: "Top")
        set.addShape(.ellipse(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse))

        let result = set.apply(.mergeLayerDown(layerId: top.id))
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(set.layers.count, 1)
        XCTAssertEqual(set.layers[0].name, "Bottom")
        XCTAssertEqual(set.layers[0].shapes.count, 2)
    }

    func testMergeBottomLayerIsNoChange() {
        var set = AnnotationSet()
        let bottom = set.addLayer(name: "Bottom")
        let result = set.apply(.mergeLayerDown(layerId: bottom.id))
        XCTAssertFalse(result.didChange)
    }

    // MARK: - Resize Command

    func testResizeShapeAndUndo() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let shapeId = UUID()
        let original = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        set.addShape(.rectangle(id: shapeId, rect: original, style: .defaultRectangle))

        let newRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.4)
        let result = set.apply(.resizeShape(shapeId: shapeId, newRect: newRect))
        XCTAssertTrue(result.didChange)

        if case .rectangle(_, let rect, _) = set.shape(id: shapeId)! {
            XCTAssertEqual(rect.width, 0.5, accuracy: 0.001)
            XCTAssertEqual(rect.height, 0.4, accuracy: 0.001)
        }

        // Undo
        set.apply(result.inverse)
        if case .rectangle(_, let rect, _) = set.shape(id: shapeId)! {
            XCTAssertEqual(rect.width, 0.2, accuracy: 0.001)
        }
    }

    // MARK: - Photo Adjustments Command

    func testSetAdjustmentsAndUndo() {
        var set = AnnotationSet()
        XCTAssertNil(set.adjustments)

        let adj = PhotoAdjustments(brightness: 0.2, contrast: 1.3, saturation: 0.8)
        let result = set.apply(.setAdjustments(adj))
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(set.adjustments?.brightness, 0.2)
        XCTAssertEqual(set.adjustments?.contrast, 1.3)

        set.apply(result.inverse)
        XCTAssertNil(set.adjustments)
    }

    // MARK: - Marquee Selection

    func testShapesInRect() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        set.addShape(.rectangle(id: id1, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), style: .defaultRectangle))
        set.addShape(.ellipse(id: id2, rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), style: .defaultEllipse))
        set.addShape(.rectangle(id: id3, rect: NormalizedRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1), style: .defaultRectangle))

        // Select top-left area
        let selected = set.shapesInRect(NormalizedRect(x: 0, y: 0, width: 0.3, height: 0.3))
        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first, id1)

        // Select all
        let allSelected = set.shapesInRect(NormalizedRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(allSelected.count, 3)

        // Select none
        let none = set.shapesInRect(NormalizedRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1))
        XCTAssertEqual(none.count, 0)
    }

    func testShapesInRectRespectsLockedLayers() {
        var set = AnnotationSet()
        let _ = set.addLayer(name: "L1")
        let id1 = UUID()
        set.addShape(.rectangle(id: id1, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), style: .defaultRectangle))

        // Lock the layer
        set.layers[0].isLocked = true

        let selected = set.shapesInRect(NormalizedRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(selected.count, 0, "Locked layers should not be selectable")
    }
}
