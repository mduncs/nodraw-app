import XCTest
import Combine
import GRDB
@testable import MediaViewer

@MainActor
final class ExternalSidecarDeletionTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("external-sidecar-deletion-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: root)
    }

    func testLiveSidecarDeletionHidesItemAndPublishesDeletedID() async throws {
        let fixture = try await makeFixture()
        let store = await fixture.coordinator.getMediaStore()
        let activeBefore = try await store.countItems()
        XCTAssertEqual(activeBefore, 1)
        var changes: [MediaStoreChange] = []
        let subscription = store.detailedChanges.sink { changes.append($0) }
        defer { subscription.cancel() }

        try writeSidecar(at: fixture.item.metadataFile, deleted: true)
        let editedSidecar = try Data(contentsOf: fixture.item.metadataFile)
        await fixture.coordinator.handleFileChange(FileChange(url: fixture.item.metadataFile, type: .modified))

        try await assertRecentlyDeleted(fixture.item.id, in: store)
        XCTAssertEqual(changes, [.deleted([fixture.item.id])])
        XCTAssertEqual(try Data(contentsOf: fixture.item.metadataFile), editedSidecar)
        let pending = try await store.writeBackQueue.statuses()
        XCTAssertTrue(pending.isEmpty)
    }

    func testLiveSidecarDeletionPreservesPendingLocalRecoveryAndPublishesItems() async throws {
        let fixture = try await makeFixture()
        let store = await fixture.coordinator.getMediaStore()
        let id = fixture.item.id.uuidString
        // A conflicted recovery stays unsynced without starting a projection timer.
        try await fixture.database.write { db in
            try db.execute(sql: """
                INSERT INTO metadata_outbox(itemID, field, revision, baseJSON, desiredJSON, state)
                VALUES (?, 'deleted', 1, 'true', 'false', 'conflict')
                """, arguments: [id])
        }
        var changes: [MediaStoreChange] = []
        let subscription = store.detailedChanges.sink { changes.append($0) }
        defer { subscription.cancel() }

        try writeSidecar(at: fixture.item.metadataFile, deleted: true)
        await fixture.coordinator.handleFileChange(FileChange(url: fixture.item.metadataFile, type: .modified))

        let activeCount = try await store.countItems()
        XCTAssertEqual(activeCount, 1)
        let stored = try await store.fetchItem(id: fixture.item.id)
        XCTAssertEqual(stored?.metadata.deleted, false)
        XCTAssertNil(stored?.deletionReason)
        var filter = FilterState()
        filter.deletionScope = .deletedOnly
        let deleted = try await store.fetchItems(filter: filter)
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(changes, [.items([fixture.item.id])])
        let pending = try await store.writeBackQueue.statuses()
        XCTAssertEqual(pending.map(\.field), ["deleted"])
        XCTAssertEqual(pending.first?.desiredJSON, "false")
    }

    func testStartupSidecarDeletionPublishesDeletedID() async throws {
        let fixture = try await makeFixture()
        let store = await fixture.coordinator.getMediaStore()
        var changes: [MediaStoreChange] = []
        let subscription = store.detailedChanges.sink { changes.append($0) }
        defer { subscription.cancel() }
        try writeSidecar(at: fixture.item.metadataFile, deleted: true)

        try await store.updateChangedScannedItemsBatch([(fixture.item, fixture.item.id)])

        try await assertRecentlyDeleted(fixture.item.id, in: store)
        XCTAssertEqual(changes, [.deleted([fixture.item.id])])
    }

    private func assertRecentlyDeleted(_ id: UUID, in store: MediaStore) async throws {
        let active = try await store.fetchItems(filter: .all)
        XCTAssertTrue(active.isEmpty)
        let activeCount = try await store.countItems()
        XCTAssertEqual(activeCount, 0)
        var filter = FilterState()
        filter.deletionScope = .deletedOnly
        let deleted = try await store.fetchItems(filter: filter)
        XCTAssertEqual(deleted.map(\.id), [id])
        XCTAssertEqual(deleted.first?.metadata.deleted, true)
        XCTAssertEqual(deleted.first?.deletionReason, .user)
    }

    private func makeFixture() async throws -> (database: DatabaseManager, coordinator: AppCoordinator, item: MediaItem) {
        let archive = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let sidecar = archive.appendingPathComponent("post.md")
        let media = archive.appendingPathComponent("post.png")
        try ImportDurabilityTests.png.write(to: media)
        try writeSidecar(at: sidecar, deleted: false)
        let item = MediaItem(id: UUID(), basePath: archive, metadataFile: sidecar, mediaFiles: [media],
                             metadata: try MetadataParser.parse(fileAt: sidecar), aspectRatio: 1)
        let database = DatabaseManager(databaseURL: root.appendingPathComponent("fixture.sqlite"))
        try await database.initialize()
        let record = MediaItemRecord(from: item)
        try await database.write { db in
            try MetadataOutbox.importing(in: db) { try record.insertWithFTSSync(db: db) }
        }
        return (database, AppCoordinator(database: database, archivePath: archive), item)
    }

    private func writeSidecar(at url: URL, deleted: Bool) throws {
        try "---\nsource: https://example.com/post\nplatform: test\narchived: 2026-01-11T12:00:00Z\ndeleted: \(deleted)\n---\n"
            .write(to: url, atomically: true, encoding: .utf8)
    }
}
