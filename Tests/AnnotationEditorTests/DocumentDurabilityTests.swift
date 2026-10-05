import XCTest
import AppKit
import Combine
import GRDB
@testable import MediaViewer

@MainActor
final class DocumentDurabilityTests: XCTestCase {
    private enum SaveFailure: LocalizedError {
        case diskUnavailable
        var errorDescription: String? { "Fixture disk unavailable" }
    }

    func testSuspendedSaveDoesNotMarkNewerEditsClean() async throws {
        let session = AnnotationEditorSession(itemId: UUID(), autosaveInterval: nil)
        let started = expectation(description: "First save started")
        var resumeSave: CheckedContinuation<Void, Error>?
        var written: [AnnotationSet] = []
        session.onSave = { snapshot in
            written.append(snapshot)
            try await withCheckedThrowingContinuation { continuation in
                resumeSave = continuation
                started.fulfill()
            }
        }
        session.execute(.addLayer(name: "First"))
        let firstSnapshot = session.snapshot()
        let firstRevision = session.revision
        let save = Task { try await session.saveNow() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(session.isSaving)

        session.execute(.addLayer(name: "Edited during save"))
        let newestSnapshot = session.snapshot()
        resumeSave?.resume()
        try await save.value

        XCTAssertEqual(written, [firstSnapshot])
        XCTAssertEqual(session.savedRevision, firstRevision)
        XCTAssertGreaterThan(session.revision, firstRevision)
        XCTAssertEqual(session.annotationSet, newestSnapshot)
        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(session.isSaving)

        session.onSave = { written.append($0) }
        try await session.saveNow()
        XCTAssertEqual(written.last, newestSnapshot)
        XCTAssertEqual(session.savedRevision, session.revision)
        XCTAssertFalse(session.isDirty)
    }

    func testConcurrentSaveRequestsWriteInRevisionOrder() async throws {
        let session = AnnotationEditorSession(itemId: UUID(), autosaveInterval: nil)
        let firstStarted = expectation(description: "First write started")
        let secondStarted = expectation(description: "Second write started")
        let secondRequested = expectation(description: "Second save requested")
        var continuations: [CheckedContinuation<Void, Error>] = []
        var snapshots: [AnnotationSet] = []
        var completed: [AnnotationSet] = []
        var activeWrites = 0
        var maximumActiveWrites = 0
        session.onSave = { snapshot in
            activeWrites += 1
            maximumActiveWrites = max(maximumActiveWrites, activeWrites)
            snapshots.append(snapshot)
            try await withCheckedThrowingContinuation { continuation in
                continuations.append(continuation)
                if snapshots.count == 1 { firstStarted.fulfill() } else { secondStarted.fulfill() }
            }
            completed.append(snapshot)
            activeWrites -= 1
        }
        session.execute(.addLayer(name: "Earlier"))
        let earlier = session.snapshot()
        let first = Task { try await session.saveNow() }
        await fulfillment(of: [firstStarted], timeout: 2)
        session.execute(.addLayer(name: "Latest"))
        let latest = session.snapshot()
        let second = Task {
            secondRequested.fulfill()
            try await session.saveNow()
        }
        await fulfillment(of: [secondRequested], timeout: 2)
        XCTAssertEqual(snapshots, [earlier], "A newer write must wait for the suspended old write")
        continuations.first?.resume()
        try await first.value
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(session.isSaving)
        continuations.last?.resume()
        try await second.value

        XCTAssertEqual(maximumActiveWrites, 1)
        XCTAssertEqual(completed, [earlier, latest])
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(session.isSaving)
        XCTAssertEqual(session.revision, session.savedRevision)
    }

    func testAutosaveFailureRemainsVisibleAndRetrySavesEdits() async throws {
        let session = AnnotationEditorSession(itemId: UUID(), autosaveInterval: 0.001)
        let failurePublished = expectation(description: "Autosave error is observable")
        let observation = session.$saveError.compactMap { $0 }.prefix(1).sink { error in
            XCTAssertEqual(error, SaveFailure.diskUnavailable.localizedDescription)
            failurePublished.fulfill()
        }
        defer { observation.cancel() }
        session.onSave = { _ in throw SaveFailure.diskUnavailable }
        session.execute(.addLayer(name: "Keep this draft"))
        await fulfillment(of: [failurePublished], timeout: 2)
        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(session.isSaving)
        XCTAssertNotNil(session.saveError)
        let draft = session.snapshot()
        XCTAssertTrue(session.canUndo)

        var saved: AnnotationSet?
        session.onSave = { saved = $0 }
        try await session.saveNow()
        XCTAssertEqual(saved, draft)
        XCTAssertEqual(session.annotationSet, draft)
        XCTAssertNil(session.saveError)
        XCTAssertFalse(session.isDirty)
        XCTAssertTrue(session.canUndo)
    }

    func testMissingPersistenceSinkDoesNotPretendToSave() async {
        let session = AnnotationEditorSession(itemId: UUID(), autosaveInterval: nil)
        session.execute(.addLayer(name: "Unsaved"))
        do {
            try await session.saveNow()
            XCTFail("A session without a store must not report successful persistence")
        } catch {
            XCTAssertTrue(error is AnnotationEditorSession.PersistenceError)
        }
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(session.savedRevision, 0)
        XCTAssertNotNil(session.saveError)
        XCTAssertFalse(session.isSaving)
    }

    func testRetainedDraftFailureStillRequiresUserAttention() async {
        let session = AnnotationEditorSession(itemId: UUID(), assetID: UUID(), autosaveInterval: nil)
        session.onSave = { _ in throw ItemAssetStore.AssociationError.draftRetained }
        session.execute(.addLayer(name: "Original asset draft"))
        do {
            try await session.saveNow()
            XCTFail("Retained drafts must not be presented as an attached save")
        } catch ItemAssetStore.AssociationError.draftRetained {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(session.isDirty)
        XCTAssertNotNil(session.saveError)
        XCTAssertEqual(session.annotationSet.layers.first?.name, "Original asset draft")
    }

    func testCorruptStoreDocumentThrowsWithoutReplacingPersistedData() async throws {
        try await withStoredDocument { database, itemID, store in
            let corrupt = #"{"formatVersion":2,"layers":[{"id":"not-a-uuid","name":"Damaged","shapes":[]}],"shapes":[]}"#
            try await database.write { db in
                try db.execute(sql: "UPDATE annotations SET annotationsJSON = ? WHERE itemId = ?", arguments: [corrupt, itemID.uuidString])
            }
            let session = AnnotationEditorSession(itemId: itemID, store: store, autosaveInterval: nil)
            do {
                try await session.load()
                XCTFail("A damaged layered document must not become an empty editor")
            } catch { XCTAssertTrue(error is DecodingError) }
            do {
                _ = try await store.fetchAllAnnotations(itemId: itemID)
                XCTFail("Bulk reads must propagate the same corruption")
            } catch { XCTAssertTrue(error is DecodingError) }
            let persisted = try await database.read { db in
                try String.fetchOne(db, sql: "SELECT annotationsJSON FROM annotations WHERE itemId = ?", arguments: [itemID.uuidString])
            }
            XCTAssertEqual(persisted, corrupt)
            XCTAssertFalse(session.isDirty)
        }
    }

    func testEmptyLayerSettingsSurviveSaveAndInvalidEncodingCannotReplaceDocument() async throws {
        try await withStoredDocument { _, itemID, store in
            let layer = AnnotationLayer(name: "Empty but intentional", isVisible: false, isLocked: true, opacity: 0.4, blendMode: .screen)
            let document = AnnotationSet(layers: [layer])
            try await store.saveAnnotations(itemId: itemID, annotationSet: document, recordUndo: false)
            let loaded = try await store.fetchAnnotations(itemId: itemID)
            XCTAssertEqual(loaded, document)

            var invalid = document
            invalid.adjustments = PhotoAdjustments(brightness: .nan)
            do {
                try await store.saveAnnotations(itemId: itemID, annotationSet: invalid, recordUndo: false)
                XCTFail("Non-encodable values must not replace a valid document with {}")
            } catch { XCTAssertTrue(error is EncodingError) }
            let stillStored = try await store.fetchAnnotations(itemId: itemID)
            XCTAssertEqual(stillStored, document)
        }
    }

    private func withStoredDocument(_ body: (DatabaseManager, UUID, AnnotationStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-durability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("image.jpg")
        try Data("fixture image".utf8).write(to: file)
        let database = DatabaseManager(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        try await database.initialize()
        let itemID = UUID()
        try await database.write { db in
            let item = MediaItem(id: itemID, basePath: directory, metadataFile: directory.appendingPathComponent("item.md"), mediaFiles: [file], metadata: MediaMetadata(source: URL(string: "https://example.com/fixture")!, platform: "test"))
            try MediaItemRecord(from: item).insert(db)
            let document = AnnotationSet(shapes: [.text(id: UUID(), position: .init(x: 0.2, y: 0.3), content: "Preserve", style: .default)])
            try AnnotationRecord(itemId: itemID, annotationSet: document).upsert(db: db)
        }
        try await body(database, itemID, AnnotationStore(database: database))
    }
}
