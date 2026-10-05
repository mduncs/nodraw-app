import XCTest
@testable import MediaViewer

final class DocumentIntegrityTests: XCTestCase {
    func testStructuralCommandsUndoAndRedoExactDocument() {
        let original = decoratedDocument()
        let middle = original.layers[1].id
        let commands: [AnnotationCommand] = [
            .removeLayer(layerId: middle),
            .mergeLayerDown(layerId: middle),
            .flattenLayers,
            .clearAll,
            .duplicateLayer(layerId: middle, newLayerId: UUID()),
            .moveLayer(fromIndex: 1, toIndex: 3),
            .deleteShapes(shapeIds: [original.layers[0].shapes[1].id, original.layers[1].shapes[0].id]),
            .bringToFront(shapeId: original.layers[0].shapes[1].id),
            .sendToBack(shapeId: original.layers[0].shapes[1].id)
        ]
        for command in commands {
            var document = original
            let edit = document.apply(command)
            XCTAssertTrue(edit.didChange, "Expected an edit for \(command)")
            let edited = document
            let undo = document.apply(edit.inverse)
            XCTAssertTrue(undo.didChange)
            XCTAssertEqual(document, original, "Undo must restore every field and array position")
            document.apply(undo.inverse)
            XCTAssertEqual(document, edited, "Redo must restore exact generated IDs and settings")
        }
    }

    func testGroupedUnlockAndStructuralUndoRestoresLocksAndLayerSettings() {
        var document = decoratedDocument()
        document.layers[0].isLocked = true
        document.layers[1].isLocked = true
        let original = document
        let result = document.apply(.group([
            .setLayerLocked(layerId: document.layers[0].id, locked: false),
            .setLayerLocked(layerId: document.layers[1].id, locked: false),
            .clearAll
        ]))
        XCTAssertEqual(document, .empty)
        let undo = document.apply(result.inverse)
        XCTAssertEqual(document, original)
        document.apply(undo.inverse)
        XCTAssertEqual(document, .empty)
    }

    func testClearCropAndAdjustmentsOnlyIsUndoable() {
        var document = AnnotationSet(cropRegion: .init(x: 0.1, y: 0.2, width: 0.6, height: 0.5), adjustments: PhotoAdjustments(brightness: 0.2))
        let original = document
        let result = document.apply(.clearAll)
        XCTAssertTrue(result.didChange)
        XCTAssertEqual(document, .empty)
        document.apply(result.inverse)
        XCTAssertEqual(document, original)
    }

    func testMergeRetargetsActiveLayerAndUndoRestoresIt() {
        var document = decoratedDocument()
        document.activeLayerId = document.layers[1].id
        let original = document
        let result = document.apply(.mergeLayerDown(layerId: document.layers[1].id))
        XCTAssertEqual(document.activeLayerId, document.layers[0].id)
        XCTAssertEqual(document.layers[0].shapes, original.layers[0].shapes + original.layers[1].shapes)
        document.apply(result.inverse)
        XCTAssertEqual(document, original)
    }

    func testLockedLayerCannotBeChangedThroughCommands() {
        var document = decoratedDocument()
        document.layers[1].isLocked = true
        document.activeLayerId = document.layers[1].id
        let original = document
        let lockedLayer = document.layers[1]
        let lockedShape = lockedLayer.shapes[0]
        let commands: [AnnotationCommand] = [
            .addShape(shape: rectangle(), layerId: nil),
            .addShape(shape: rectangle(), layerId: lockedLayer.id),
            .removeShape(shapeId: lockedShape.id),
            .replaceShape(shapeId: lockedShape.id, newShape: lockedShape.translated(by: .init(x: 0.2, y: 0.1))),
            .translateShape(shapeId: lockedShape.id, delta: .init(x: 0.2, y: 0.1)),
            .resizeShape(shapeId: lockedShape.id, newRect: .init(x: 0, y: 0, width: 1, height: 1)),
            .deleteShapes(shapeIds: [lockedShape.id]),
            .moveShapes(shapeIds: [lockedShape.id], delta: .init(x: 0.2, y: 0.1)),
            .duplicateShapes(shapeIds: [lockedShape.id], newShapes: [lockedShape.duplicated()]),
            .bringForward(shapeId: lockedShape.id),
            .bringToFront(shapeId: lockedShape.id),
            .sendBackward(shapeId: lockedShape.id),
            .sendToBack(shapeId: lockedShape.id),
            .removeLayer(layerId: lockedLayer.id),
            .setLayerOpacity(layerId: lockedLayer.id, opacity: 0.9),
            .setLayerBlendMode(layerId: lockedLayer.id, blendMode: .normal),
            .moveLayer(fromIndex: 1, toIndex: 0),
            .mergeLayerDown(layerId: lockedLayer.id),
            .mergeLayerDown(layerId: document.layers[2].id),
            .flattenLayers,
            .clearAll
        ]
        for command in commands {
            XCTAssertFalse(document.apply(command).didChange, "Locked edit: \(command)")
            XCTAssertEqual(document, original)
        }
    }

    func testMultiShapeMoveAndDeleteKeepLockedContentAndExactUndo() {
        var document = decoratedDocument()
        document.layers[1].isLocked = true
        let original = document
        let allIDs = document.shapes.map(\.id)
        let moved = document.apply(.moveShapes(shapeIds: allIDs, delta: .init(x: 0.05, y: -0.04)))
        XCTAssertTrue(moved.didChange)
        XCTAssertEqual(document.layers[1], original.layers[1])
        XCTAssertNotEqual(document.layers[0].shapes, original.layers[0].shapes)
        document.apply(moved.inverse)
        XCTAssertEqual(document, original)

        let deleted = document.apply(.deleteShapes(shapeIds: allIDs))
        XCTAssertEqual(document.shapes, original.layers[1].shapes)
        document.apply(deleted.inverse)
        XCTAssertEqual(document, original)
    }

    func testInvalidAndNoOpCommandsDoNotCreateHistoryOrRevision() async {
        await MainActor.run {
            let document = decoratedDocument()
            let session = AnnotationEditorSession(itemId: UUID(), annotationSet: document, autosaveInterval: nil)
            XCTAssertFalse(session.execute(.setActiveLayer(layerId: UUID())))
            XCTAssertFalse(session.execute(.addShape(shape: rectangle(), layerId: UUID())))
            XCTAssertFalse(session.execute(.removeShape(shapeId: UUID())))
            XCTAssertFalse(session.execute(.setAdjustments(document.adjustments)))
            XCTAssertFalse(session.execute(.setLayerOpacity(layerId: document.layers[0].id, opacity: document.layers[0].opacity)))
            XCTAssertFalse(session.execute(.moveLayer(fromIndex: 0, toIndex: 1)))
            XCTAssertEqual(session.annotationSet, document)
            XCTAssertEqual(session.revision, 0)
            XCTAssertFalse(session.isDirty)
            XCTAssertFalse(session.canUndo)
        }
    }

    @MainActor
    func testLegacyBindingBridgeRejectsLockedMutationButRecordsValidChanges() {
        var document = decoratedDocument()
        document.layers[0].isLocked = true
        let session = AnnotationEditorSession(itemId: UUID(), annotationSet: document, autosaveInterval: nil)
        var attemptedEdit = document
        attemptedEdit.layers[0].shapes.removeAll()
        XCTAssertFalse(session.replaceDocument(attemptedEdit))
        XCTAssertEqual(session.annotationSet, document)
        XCTAssertEqual(session.revision, 0)

        var validEdit = document
        validEdit.layers[1].shapes.append(rectangle())
        XCTAssertTrue(session.replaceDocument(validEdit, description: "Legacy canvas edit"))
        XCTAssertEqual(session.annotationSet, validEdit)
        XCTAssertEqual(session.undoDescription, "Legacy canvas edit")
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.annotationSet, document)
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.annotationSet, validEdit)
    }

    func testAddingFirstShapeUndoRestoresTrulyEmptyDocument() {
        var document = AnnotationSet.empty
        let edit = document.apply(.addShape(shape: rectangle(), layerId: nil))
        XCTAssertEqual(document.layers.count, 1)
        let added = document
        let undo = document.apply(edit.inverse)
        XCTAssertEqual(document, .empty)
        document.apply(undo.inverse)
        XCTAssertEqual(document, added)
    }

    func testMalformedLayersCannotFallbackToLegacyOrEmptyDocument() throws {
        let malformed = [
            #"{"formatVersion":2,"layers":null,"shapes":[]}"#,
            #"{"formatVersion":2,"layers":"bad","shapes":[]}"#,
            #"{"formatVersion":2,"layers":[{"id":"bad","name":"layer","shapes":[]}],"shapes":[]}"#,
            #"{"formatVersion":2,"layers":[{"id":"11111111-1111-1111-1111-111111111111","name":"layer","shapes":[{}]}]}"#,
            #"{"formatVersion":1,"shapes":[{}]}"#,
            #"{"formatVersion":2}"#
        ]
        for json in malformed {
            XCTAssertThrowsError(try JSONDecoder().decode(AnnotationSet.self, from: Data(json.utf8)), json)
        }
        var record = AnnotationRecord(itemId: UUID(), annotationSet: decoratedDocument())
        record.annotationsJSON = malformed[0]
        XCTAssertThrowsError(try record.decodedAnnotationSet())
    }

    func testV1AndPreLockV2DocumentsRemainCompatible() throws {
        let shape = rectangle()
        let encodedShapes = String(decoding: try JSONEncoder().encode([shape]), as: UTF8.self)
        for version in ["", "\"formatVersion\":1,"] {
            let legacy = Data("{\(version)\"shapes\":\(encodedShapes)}".utf8)
            let decoded = try JSONDecoder().decode(AnnotationSet.self, from: legacy)
            XCTAssertEqual(decoded.shapes, [shape])
            XCTAssertEqual(decoded.activeLayerId, decoded.layers.first?.id)
            XCTAssertEqual(decoded.layers.first?.isLocked, false)
        }
        let layerID = UUID()
        let json = """
        {"formatVersion":2,"layers":[{"id":"\(layerID)","name":"Old layer","shapes":\(encodedShapes)}]}
        """
        let decoded = try JSONDecoder().decode(AnnotationSet.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.layers[0], AnnotationLayer(id: layerID, name: "Old layer", shapes: [shape]))
        XCTAssertEqual(try JSONDecoder().decode(AnnotationSet.self, from: JSONEncoder().encode(decoded)), decoded)
    }

    private func decoratedDocument() -> AnnotationSet {
        let bottom = AnnotationLayer(name: "Bottom", isVisible: false, opacity: 0.27, blendMode: .multiply,
            shapes: [rectangle(), rectangle(), rectangle()])
        let middle = AnnotationLayer(name: "Middle", opacity: 0.63, blendMode: .screen,
            shapes: [rectangle(), .mask(id: UUID(), maskData: Data([0xFA, 0x32]), bounds: .init(x: 0.1, y: 0.3, width: 0.5, height: 0.2), blendMode: .maskKeep, opacity: 0.7, featherRadius: 4)])
        let top = AnnotationLayer(name: "Top", isVisible: false, opacity: 0.82, blendMode: .overlay,
            shapes: [.text(id: UUID(), position: .init(x: 0.1, y: 0.2), content: "Keep style", style: .memeClassic)])
        return AnnotationSet(layers: [bottom, middle, top], activeLayerId: middle.id,
            cropRegion: .init(x: 0.03, y: 0.06, width: 0.8, height: 0.9),
            adjustments: PhotoAdjustments(brightness: 0.2, contrast: 1.3, temperature: 5000, vignette: 0.4))
    }

    private func rectangle() -> AnnotationShape {
        .rectangle(id: UUID(), rect: .init(x: 0.2, y: 0.3, width: 0.4, height: 0.2), style: .defaultRectangle)
    }
}
