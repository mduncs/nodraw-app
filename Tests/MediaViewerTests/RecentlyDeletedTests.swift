import XCTest
import GRDB
@testable import MediaViewer

final class RecentlyDeletedTests: XCTestCase {
    private var tempDirectory: URL!
    private var databaseManager: DatabaseManager!
    private var mediaStore: MediaStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentlyDeletedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        databaseManager = DatabaseManager(databaseURL: tempDirectory.appendingPathComponent("test.sqlite"))
        mediaStore = MediaStore(database: databaseManager)
        try await databaseManager.initialize()
    }

    override func tearDown() async throws {
        mediaStore = nil
        databaseManager = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try await super.tearDown()
    }

    func testSoftDeleteIsRecoverableAndPreservesDerivedAnalysis() async throws {
        let item = try await insertItem(named: "recoverable", createMediaFile: true)
        try await databaseManager.write { db in
            try db.execute(
                sql: "INSERT INTO media_attributes (item_id, module, key, value) VALUES (?, 'quality', 'score', 0.8)",
                arguments: [item.id.uuidString]
            )
            try db.execute(
                sql: "INSERT INTO clip_vectors (itemId, vectorData, version, extractedAt) VALUES (?, ?, 1, ?)",
                arguments: [item.id.uuidString, Data([0, 1]), Date()]
            )
        }

        try await mediaStore.softDelete(ids: [item.id])

        let activeCountAfterDelete = try await mediaStore.countItems()
        XCTAssertEqual(activeCountAfterDelete, 0)
        var deletedFilter = FilterState()
        deletedFilter.deletionScope = .deletedOnly
        let deleted = try await mediaStore.fetchItems(filter: deletedFilter.withUnlimitedLimit())
        XCTAssertEqual(deleted.map(\.id), [item.id])
        XCTAssertEqual(deleted.first?.deletionReason, .user)

        let derivedCounts = try await databaseManager.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_attributes WHERE item_id = ?", arguments: [item.id.uuidString]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_vectors WHERE itemId = ?", arguments: [item.id.uuidString]) ?? 0
            )
        }
        XCTAssertEqual(derivedCounts.0, 1)
        XCTAssertEqual(derivedCounts.1, 1)

        try await mediaStore.restoreDeletedWithFileValidation(ids: [item.id])
        let activeCountAfterRestore = try await mediaStore.countItems()
        XCTAssertEqual(activeCountAfterRestore, 1)
        let restored = try await mediaStore.fetchItem(id: item.id)
        XCTAssertNil(restored?.deletionReason)
    }

    func testDeletedOnlyIncludesMissingFileRowsButValidatedRestoreRejectsThem() async throws {
        let item = try await insertItem(named: "missing", createMediaFile: false)
        try await mediaStore.softDelete(ids: [item.id], reason: .missingFiles)

        var deletedFilter = FilterState()
        deletedFilter.deletionScope = .deletedOnly
        let deleted = try await mediaStore.fetchItems(filter: deletedFilter.withUnlimitedLimit())
        XCTAssertEqual(deleted.map(\.id), [item.id])
        XCTAssertEqual(deleted.first?.deletionReason, .missingFiles)

        do {
            try await mediaStore.restoreDeletedWithFileValidation(ids: [item.id])
            XCTFail("Expected restore validation to reject an item with no displayable files")
        } catch DeletedItemRecoveryError.noDisplayableFiles(let ids) {
            XCTAssertEqual(ids, [item.id])
        }
    }

    func testCombineTombstonesAreHiddenAndCannotBeRestored() async throws {
        let item = try await insertItem(named: "combined", createMediaFile: true)
        try await mediaStore.softDelete(ids: [item.id], reason: .combined)

        var deletedFilter = FilterState()
        deletedFilter.deletionScope = .deletedOnly
        let visibleDeletedItems = try await mediaStore.fetchItems(filter: deletedFilter.withUnlimitedLimit())
        XCTAssertTrue(visibleDeletedItems.isEmpty)

        do {
            try await mediaStore.restoreDeleted(ids: [item.id])
            XCTFail("Expected combine tombstone restoration to be rejected")
        } catch DeletedItemRecoveryError.combinedItemsCannotBeRestored {
            // Expected.
        }
    }

    func testCombinedReasonSurvivesOrdinaryDeleteAndStaleItemUpdate() async throws {
        let item = try await insertItem(named: "combined-invariant", createMediaFile: true)
        try await mediaStore.softDelete(ids: [item.id], reason: .combined)

        // A stale caller must not reclassify the tombstone as a user deletion.
        try await mediaStore.softDelete(ids: [item.id], reason: .user)
        let fetchedStaleItem = try await mediaStore.fetchItem(id: item.id)
        var staleItem = try XCTUnwrap(fetchedStaleItem)
        XCTAssertEqual(staleItem.deletionReason, .combined)

        // Nor may an unrelated full-record update resurrect it or clear provenance.
        staleItem.metadata.deleted = false
        staleItem.deletionReason = nil
        try await mediaStore.updateItem(staleItem)

        let fetchedPreserved = try await mediaStore.fetchItem(id: item.id)
        let preserved = try XCTUnwrap(fetchedPreserved)
        XCTAssertTrue(preserved.metadata.deleted)
        XCTAssertEqual(preserved.deletionReason, .combined)

        do {
            _ = try await mediaStore.makeDeletedItemPurgePlan(ids: [item.id])
            XCTFail("Expected combine tombstone purge planning to be rejected")
        } catch DeletedItemPurgeError.combinedItemsIncluded {
            // Expected before any filesystem work.
        }
        do {
            _ = try await mediaStore.purgeDeletedRecords(ids: [item.id])
            XCTFail("Expected combine tombstone record purge to be rejected")
        } catch DeletedItemPurgeError.combinedItemsIncluded {
            // Expected.
        }
    }

    func testSidecarAndStaleFullRecordCannotResurrectAnyDeletionReason() async throws {
        for reason in ["user", "missingFiles", "duplicateReview:\(UUID().uuidString)"] {
            let item = try await insertItem(named: "tombstone-\(UUID().uuidString)", createMediaFile: true)
            await mediaStore.writeBackQueue.flushNow()
            let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
            try await databaseManager.write { db in
                try db.execute(sql: "UPDATE media_items SET deletedAt = ?, deletionReason = ? WHERE id = ?",
                               arguments: [timestamp, reason, item.id.uuidString])
                // Reproduce an already-acknowledged deletion, not pending-outbox protection.
                try db.execute(sql: "DELETE FROM metadata_outbox WHERE itemID = ?", arguments: [item.id.uuidString])
            }
            try "---\nsource: https://example.com/tombstone\ndeleted: false\nnotes: external update\n---\n".write(to: item.metadataFile, atomically: true, encoding: .utf8)
            try await mediaStore.updateItem(item, source: .sidecar)
            try await mediaStore.updateItem(item) // older in-memory snapshot, too
            let row = try await databaseManager.read { db in
                try Row.fetchOne(db, sql: "SELECT deletedAt, deletionReason FROM media_items WHERE id = ?", arguments: [item.id.uuidString])!
            }
            XCTAssertEqual(row["deletedAt"] as Date?, timestamp)
            XCTAssertEqual(row["deletionReason"] as String?, reason)
        }
    }

    func testPurgePlanProtectsPathsReferencedByEveryNonTargetRow() async throws {
        let activeShared = tempDirectory.appendingPathComponent("active-shared.jpg")
        let deletedShared = tempDirectory.appendingPathComponent("deleted-shared.jpg")
        let targetOnly = tempDirectory.appendingPathComponent("target-only.jpg")

        let active = SampleData.createMediaItem(
            basePath: tempDirectory,
            metadataFile: tempDirectory.appendingPathComponent("active-holder.md"),
            mediaFiles: [activeShared],
            source: "https://example.com/active-holder"
        )
        let otherDeleted = SampleData.createMediaItem(
            basePath: tempDirectory,
            metadataFile: tempDirectory.appendingPathComponent("deleted-holder.md"),
            mediaFiles: [deletedShared],
            source: "https://example.com/deleted-holder"
        )
        let target = SampleData.createMediaItem(
            basePath: tempDirectory,
            metadataFile: tempDirectory.appendingPathComponent("purge-target.md"),
            mediaFiles: [activeShared, deletedShared, targetOnly],
            source: "https://example.com/purge-target"
        )
        try await mediaStore.insertItem(active)
        try await mediaStore.insertItem(otherDeleted)
        try await mediaStore.insertItem(target)
        try await mediaStore.softDelete(ids: [otherDeleted.id, target.id], reason: .user)

        let plan = try await mediaStore.makeDeletedItemPurgePlan(ids: [target.id])
        let entry = try XCTUnwrap(plan.entries.first)
        let plannedPaths = Set(entry.fileURLs.map { $0.standardizedFileURL.path })
        XCTAssertFalse(plannedPaths.contains(activeShared.standardizedFileURL.path))
        XCTAssertFalse(plannedPaths.contains(deletedShared.standardizedFileURL.path))
        XCTAssertTrue(plannedPaths.contains(targetOnly.standardizedFileURL.path))
        XCTAssertTrue(plannedPaths.contains(target.metadataFile.standardizedFileURL.path))
    }

    func testMigration36QuarantinesOnlyLegacyDeletedRowsSharingActiveDisplayPaths() async throws {
        let shared = tempDirectory.appendingPathComponent("legacy-shared.jpg")
        let active = SampleData.createMediaItem(
            basePath: tempDirectory,
            metadataFile: tempDirectory.appendingPathComponent("legacy-active.md"),
            mediaFiles: [shared],
            source: "https://example.com/legacy-active"
        )
        let sharedLegacy = SampleData.createMediaItem(
            basePath: tempDirectory,
            metadataFile: tempDirectory.appendingPathComponent("legacy-shared-deleted.md"),
            mediaFiles: [shared],
            source: "https://example.com/legacy-shared-deleted"
        )
        let recoverableLegacy = SampleData.createMediaItem(
            basePath: tempDirectory,
            metadataFile: tempDirectory.appendingPathComponent("legacy-recoverable.md"),
            mediaFiles: [tempDirectory.appendingPathComponent("legacy-recoverable.jpg")],
            source: "https://example.com/legacy-recoverable"
        )
        try await mediaStore.insertItem(active)
        try await mediaStore.insertItem(sharedLegacy)
        try await mediaStore.insertItem(recoverableLegacy)
        try await databaseManager.write { db in
            try db.execute(
                sql: "UPDATE media_items SET deletedAt = ?, deletionReason = NULL WHERE id IN (?, ?)",
                arguments: [Date(), sharedLegacy.id.uuidString, recoverableLegacy.id.uuidString]
            )
            // Simulate a database last opened before migration 36. Leaving any later
            // version recorded would keep MAX(version) above 36 and correctly skip it.
            try ProductionAssetFixture.removePost38Schema(in: db)
            try db.execute(sql: "DELETE FROM schema_migrations WHERE version >= 36")
        }

        let databaseURL = tempDirectory.appendingPathComponent("test.sqlite")
        mediaStore = nil
        databaseManager = nil
        let migratedDatabase = DatabaseManager(databaseURL: databaseURL)
        try await migratedDatabase.initialize()
        let migratedStore = MediaStore(database: migratedDatabase)
        databaseManager = migratedDatabase
        mediaStore = migratedStore

        let fetchedSharedResult = try await migratedStore.fetchItem(id: sharedLegacy.id)
        let fetchedRecoverableResult = try await migratedStore.fetchItem(id: recoverableLegacy.id)
        let sharedResult = try XCTUnwrap(fetchedSharedResult)
        let recoverableResult = try XCTUnwrap(fetchedRecoverableResult)
        XCTAssertEqual(sharedResult.deletionReason, .combined)
        XCTAssertNil(recoverableResult.deletionReason)

        var deletedFilter = FilterState()
        deletedFilter.deletionScope = .deletedOnly
        deletedFilter.hideJunk = false
        deletedFilter.hideSafetyFlagged = false
        let visibleIDs = Set(try await migratedStore.fetchItems(filter: deletedFilter.withUnlimitedLimit()).map(\.id))
        XCTAssertFalse(visibleIDs.contains(sharedLegacy.id))
        XCTAssertTrue(visibleIDs.contains(recoverableLegacy.id))
    }

    func testFilesystemSyncSoftDeletesMissingContextOnlyItem() async throws {
        var item = SampleData.createMediaItem(
            basePath: tempDirectory,
            metadataFile: tempDirectory.appendingPathComponent("context-only.md"),
            mediaFiles: [],
            source: "https://example.com/context-only"
        )
        item.contextImage = tempDirectory.appendingPathComponent("missing.context.png")
        try await mediaStore.insertItem(item)

        let result = try await mediaStore.syncWithFilesystem()
        XCTAssertEqual(result.softDeletedCount, 1)
        let fetchedDeleted = try await mediaStore.fetchItem(id: item.id)
        let deleted = try XCTUnwrap(fetchedDeleted)
        XCTAssertTrue(deleted.metadata.deleted)
        XCTAssertEqual(deleted.deletionReason, .missingFiles)
    }

    func testPermanentRecordPurgeCascadesDerivedRowsAndFTS() async throws {
        let item = try await insertItem(named: "purge-cascade", createMediaFile: false)
        try await databaseManager.write { db in
            try db.execute(
                sql: "INSERT INTO media_attributes (item_id, module, key, value) VALUES (?, 'quality', 'score', 0.8)",
                arguments: [item.id.uuidString]
            )
        }
        try await mediaStore.softDelete(ids: [item.id], reason: .user)

        let purgeCount = try await mediaStore.purgeDeletedRecords(ids: [item.id])
        XCTAssertEqual(purgeCount, 1)
        let counts = try await databaseManager.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE id = ?", arguments: [item.id.uuidString]) ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_attributes WHERE item_id = ?", arguments: [item.id.uuidString]) ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items_fts WHERE rowid NOT IN (SELECT rowid FROM media_items)") ?? -1
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
        XCTAssertEqual(counts.2, 0)
    }

    private func insertItem(named name: String, createMediaFile: Bool) async throws -> MediaItem {
        let mediaURL = tempDirectory.appendingPathComponent("\(name).jpg")
        if createMediaFile {
            try Data([0]).write(to: mediaURL)
        }
        let item = SampleData.createMediaItem(
            basePath: tempDirectory,
            metadataFile: tempDirectory.appendingPathComponent("\(name).md"),
            mediaFiles: [mediaURL],
            source: "https://example.com/\(name)",
            platform: "test",
            author: "@\(name)",
            archivedDate: Date(),
            starred: false,
            tags: []
        )
        try await mediaStore.insertItem(item)
        return item
    }
}
