import XCTest
import AppKit
@testable import MediaViewer

@MainActor
final class SessionTests: XCTestCase {

    func testSessionExecuteAndUndo() {
        let session = AnnotationEditorSession(itemId: UUID())
        let layerId = UUID()
        session.execute(.addLayer(name: "L1", id: layerId), description: "Add layer")
        session.execute(
            .addShape(shape: .rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle), layerId: nil),
            description: "Add rectangle"
        )

        XCTAssertEqual(session.annotationSet.shapes.count, 1)
        XCTAssertTrue(session.canUndo)
        XCTAssertEqual(session.undoCount, 2)

        session.undo()
        XCTAssertEqual(session.annotationSet.shapes.count, 0)
        XCTAssertTrue(session.canRedo)

        session.redo()
        XCTAssertEqual(session.annotationSet.shapes.count, 1)
    }

    func testSessionDirtyTracking() {
        let session = AnnotationEditorSession(itemId: UUID())
        XCTAssertFalse(session.isDirty)

        session.execute(.addLayer(name: "L1"))
        XCTAssertTrue(session.isDirty)
    }

    func testSessionSelection() {
        let session = AnnotationEditorSession(itemId: UUID())
        session.execute(.addLayer(name: "L1"))
        let id1 = UUID(), id2 = UUID()
        session.execute(.addShape(shape: .rectangle(id: id1, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle), layerId: nil))
        session.execute(.addShape(shape: .ellipse(id: id2, rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse), layerId: nil))

        session.select(id1)
        XCTAssertTrue(session.isSelected(id1))
        XCTAssertFalse(session.isSelected(id2))
        XCTAssertEqual(session.selectedShapes.count, 1)

        session.toggleSelection(id2)
        XCTAssertEqual(session.selectedShapeIds.count, 2)

        session.toggleSelection(id1)
        XCTAssertEqual(session.selectedShapeIds.count, 1)
        XCTAssertTrue(session.isSelected(id2))

        session.selectAll()
        XCTAssertEqual(session.selectedShapeIds.count, 2)

        session.clearSelection()
        XCTAssertTrue(session.selectedShapeIds.isEmpty)
    }

    func testSessionDeleteSelected() {
        let session = AnnotationEditorSession(itemId: UUID())
        session.execute(.addLayer(name: "L1"))
        let id1 = UUID(), id2 = UUID()
        session.execute(.addShape(shape: .rectangle(id: id1, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle), layerId: nil))
        session.execute(.addShape(shape: .ellipse(id: id2, rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse), layerId: nil))

        session.select(id1)
        session.deleteSelected()
        XCTAssertEqual(session.annotationSet.shapes.count, 1)
        XCTAssertNil(session.annotationSet.shape(id: id1))
        XCTAssertTrue(session.selectedShapeIds.isEmpty)

        // Undo restores
        session.undo()
        XCTAssertEqual(session.annotationSet.shapes.count, 2)
    }

    func testSessionClearHistoryResetsState() {
        let session = AnnotationEditorSession(itemId: UUID())
        session.execute(.addLayer(name: "L1"))
        session.execute(.addShape(shape: .rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle), layerId: nil))
        XCTAssertTrue(session.canUndo)

        session.clearHistory()
        XCTAssertFalse(session.canUndo)
        XCTAssertFalse(session.canRedo)
        XCTAssertEqual(session.undoCount, 0)
    }

    func testSessionUndoDescriptions() {
        let session = AnnotationEditorSession(itemId: UUID())
        session.execute(.addLayer(name: "L1"), description: "Add layer")
        XCTAssertEqual(session.undoDescription, "Add layer")

        session.undo()
        XCTAssertEqual(session.redoDescription, "Add layer")
    }

    func testNewCommandClearsRedoStack() {
        let session = AnnotationEditorSession(itemId: UUID())
        session.execute(.addLayer(name: "L1"))
        session.execute(.addShape(shape: .rectangle(id: UUID(), rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle), layerId: nil))

        session.undo()
        XCTAssertTrue(session.canRedo)

        // New command clears redo
        session.execute(.addShape(shape: .ellipse(id: UUID(), rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2), style: .defaultEllipse), layerId: nil))
        XCTAssertFalse(session.canRedo)
    }

    // MARK: - Clipboard

    func testCopyPasteShapes() {
        let pasteboard = NSPasteboard(name: .init("NoDraw.AnnotationEditorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let session = AnnotationEditorSession(itemId: UUID(), pasteboard: pasteboard)
        session.execute(.addLayer(name: "L1"))

        let id1 = UUID()
        session.execute(.addShape(shape: .rectangle(id: id1, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle), layerId: nil))

        session.select(id1)
        session.copySelected()

        // Paste creates new shapes with different IDs
        XCTAssertTrue(session.pasteFromClipboard())
        XCTAssertEqual(session.annotationSet.shapeCount, 2)

        // Pasted shapes are selected, original is not
        XCTAssertEqual(session.selectedShapeIds.count, 1)
        XCTAssertFalse(session.isSelected(id1))

        // Undo removes pasted shapes
        session.undo()
        XCTAssertEqual(session.annotationSet.shapeCount, 1)
    }

    func testCutRemovesOriginal() {
        let pasteboard = NSPasteboard(name: .init("NoDraw.AnnotationEditorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let session = AnnotationEditorSession(itemId: UUID(), pasteboard: pasteboard)
        session.execute(.addLayer(name: "L1"))

        let id1 = UUID()
        session.execute(.addShape(shape: .rectangle(id: id1, rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), style: .defaultRectangle), layerId: nil))

        session.select(id1)
        XCTAssertTrue(session.cutSelected())
        XCTAssertEqual(session.annotationSet.shapeCount, 0)

        // Paste brings it back with a new ID
        XCTAssertTrue(session.pasteFromClipboard())
        XCTAssertEqual(session.annotationSet.shapeCount, 1)
        XCTAssertFalse(session.isSelected(id1)) // New ID, not original
    }

    func testPasteLegacyTypeUsesOnlyInjectedPrivatePasteboard() throws {
        let pasteboard = NSPasteboard(name: .init("NoDraw.AnnotationEditorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let session = AnnotationEditorSession(itemId: UUID(), pasteboard: pasteboard)
        let shape = AnnotationShape.text(id: UUID(), position: .init(x: 0.3, y: 0.4), content: "Legacy clipboard", style: .default)
        pasteboard.setData(try JSONEncoder().encode([shape]), forType: .init("com.mediaviewer.annotation.shapes"))
        XCTAssertTrue(session.pasteFromClipboard())
        XCTAssertEqual(session.annotationSet.shapeCount, 1)
        XCTAssertNotEqual(session.annotationSet.shapes[0].id, shape.id)
        session.undo()
        XCTAssertEqual(session.annotationSet, .empty)
    }

}
