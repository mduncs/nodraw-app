import XCTest
@testable import MediaViewer

@MainActor
final class AnnotationSessionRegistryTests: XCTestCase {
    func testRegistryOwnsFailedSessionAfterViewReleasesItAndRetryReleasesCleanSession() async {
        let registry = AnnotationSessionRegistry()
        let source = fixtureSource()
        let itemID = UUID()
        let assetID = UUID()
        var session: AnnotationEditorSession? = AnnotationEditorSession(itemId: itemID, assetID: assetID, autosaveInterval: nil)
        weak var retained = session
        session?.onSave = { _ in throw CocoaError(.fileWriteOutOfSpace) }
        session?.execute(.addLayer(name: "Retained draft"))
        registry.retain(session!, sourceURL: source)
        session = nil
        XCTAssertNotNil(retained, "Recovery must outlive the editor view's ownership")
        XCTAssertTrue(registry.session(itemID: itemID, assetID: assetID, index: 0, sourceURL: source) === retained)

        await registry.flush()
        XCTAssertEqual(registry.retainedCount, 1)
        XCTAssertEqual(registry.failedSessions.count, 1)
        XCTAssertTrue(registry.failedSessions.first?.session === retained)
        XCTAssertEqual(registry.failedSessions.first?.sourceURL, source)
        XCTAssertNotNil(retained?.saveError)
        XCTAssertTrue(retained?.isDirty == true)

        retained?.onSave = { _ in }
        await registry.flush()
        XCTAssertEqual(registry.retainedCount, 0)
        XCTAssertTrue(registry.failedSessions.isEmpty)
        XCTAssertNil(registry.session(itemID: itemID, assetID: assetID, index: 0, sourceURL: source))
        XCTAssertNil(retained, "A successful clean retry should release recovery ownership")
    }

    func testStableAssetIdentitySurvivesIndexReorderWithoutMixingOtherDocuments() {
        let registry = AnnotationSessionRegistry()
        let source = fixtureSource()
        let itemID = UUID()
        let assetID = UUID()
        let session = dirtySession(itemID: itemID, assetID: assetID, index: 2)
        registry.retain(session, sourceURL: source)
        XCTAssertTrue(registry.session(itemID: itemID, assetID: assetID, index: 8, sourceURL: source) === session)
        XCTAssertNil(registry.session(itemID: itemID, assetID: UUID(), index: 2, sourceURL: source))
        XCTAssertNil(registry.session(itemID: UUID(), assetID: assetID, index: 2, sourceURL: source))
        XCTAssertNil(registry.session(itemID: itemID, assetID: assetID, index: 2, sourceURL: fixtureSource()))

        let legacy = dirtySession(itemID: itemID, assetID: nil, index: 3)
        registry.retain(legacy, sourceURL: source)
        XCTAssertTrue(registry.session(itemID: itemID, assetID: nil, index: 3, sourceURL: source) === legacy)
        XCTAssertNil(registry.session(itemID: itemID, assetID: nil, index: 4, sourceURL: source))
        XCTAssertEqual(registry.retainedCount, 2)
    }

    func testReleaseDoesNotDiscardNewEditsThatArriveDuringFlush() async throws {
        let registry = AnnotationSessionRegistry()
        let session = dirtySession()
        let source = fixtureSource()
        let started = expectation(description: "Retained save started")
        var continuation: CheckedContinuation<Void, Error>?
        session.onSave = { _ in
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
                started.fulfill()
            }
        }
        registry.retain(session, sourceURL: source)
        let flush = Task { await registry.flush() }
        await fulfillment(of: [started], timeout: 2)
        registry.releaseIfClean(session)
        XCTAssertEqual(registry.retainedCount, 1)
        session.execute(.addLayer(name: "Edited during flush"))
        continuation?.resume()
        await flush.value
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(registry.retainedCount, 1)
        XCTAssertTrue(registry.failedSessions.isEmpty)

        var saved: AnnotationSet?
        session.onSave = { saved = $0 }
        await registry.flush()
        XCTAssertEqual(saved, session.annotationSet)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(registry.retainedCount, 0)
    }

    func testRetryFailureInOneDocumentDoesNotPreventOtherDocumentsSaving() async {
        let registry = AnnotationSessionRegistry()
        let failing = dirtySession()
        failing.onSave = { _ in throw CocoaError(.fileWriteNoPermission) }
        let succeeding = dirtySession()
        succeeding.onSave = { _ in }
        registry.retain(failing, sourceURL: fixtureSource())
        registry.retain(succeeding, sourceURL: fixtureSource())
        await registry.flush()
        XCTAssertTrue(failing.isDirty)
        XCTAssertFalse(succeeding.isDirty)
        XCTAssertEqual(registry.retainedCount, 1)
        XCTAssertEqual(registry.failedSessions.count, 1)
        XCTAssertTrue(registry.failedSessions.first?.session === failing)
    }

    func testIdempotentRetentionAndExternallySuccessfulSaveReleaseOwnership() async throws {
        let registry = AnnotationSessionRegistry()
        let session = dirtySession()
        session.onSave = { _ in }
        let source = fixtureSource()
        registry.retain(session, sourceURL: source)
        registry.retain(session, sourceURL: source)
        XCTAssertEqual(registry.retainedCount, 1)
        try await session.saveNow()
        XCTAssertEqual(registry.retainedCount, 0, "Autosave/manual save success also clears recovery ownership")
        registry.retain(session, sourceURL: source)
        XCTAssertEqual(registry.retainedCount, 0, "Clean sessions do not need retry ownership")
    }

    private func dirtySession(itemID: UUID = UUID(), assetID: UUID? = UUID(), index: Int = 0) -> AnnotationEditorSession {
        let session = AnnotationEditorSession(itemId: itemID, mediaFileIndex: index, assetID: assetID, autosaveInterval: nil)
        session.execute(.addLayer(name: "Unsaved"))
        return session
    }

    private func fixtureSource() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("registry-\(UUID().uuidString).png")
    }
}
