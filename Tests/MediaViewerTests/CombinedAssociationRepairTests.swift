import XCTest
import GRDB
@testable import MediaViewer

final class CombinedAssociationRepairTests: XCTestCase {
    private var root: URL!
    private var archive: URL!
    private var database: DatabaseManager!
    private var coordinator: AppCoordinator!
    private var store: MediaStore!

    override func setUp() async throws {
        root = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("combined-repair-\(UUID())")
        archive = root.appendingPathComponent("archive/2026-03")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: root.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        coordinator = AppCoordinator(database: database, archivePath: archive)
        store = await coordinator.getMediaStore()
    }

    override func tearDown() async throws {
        coordinator = nil
        store = nil
        database = nil
        try FileManager.default.removeItem(at: root)
    }

    private func item(stem: String, source: String, media: [URL] = [], context: URL? = nil, combined: Bool = false) async throws -> MediaItem {
        let sidecar = archive.appendingPathComponent(stem + ".md")
        try "---\nsource: \(source)\narchived: 2026-03-10T12:00:00Z\ndeleted: \(combined)\n---\n".write(to: sidecar, atomically: true, encoding: .utf8)
        var item = MediaItem(id: UUID(), basePath: archive, metadataFile: sidecar, mediaFiles: media,
                             contextImage: context, metadata: try MetadataParser.parse(fileAt: sidecar), aspectRatio: 1)
        if combined { item.deletionReason = .combined }
        let record = MediaItemRecord(from: item)
        try await database.write { db in try MetadataOutbox.importing(in: db) { try record.insertWithFTSSync(db: db) } }
        return item
    }

    private func file(_ name: String) throws -> URL {
        let url = archive.appendingPathComponent(name)
        try ImportDurabilityTests.png.write(to: url)
        return url
    }

    private func assertActiveCount(_ expected: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let count = try await store.countItems()
        XCTAssertEqual(count, expected, file: file, line: line)
    }

    private func scan() async throws {
        _ = try await coordinator.performInitialScan(watcher: ArchiveWatcher(archivePath: archive))
    }

    func testCamOflageLeftoversJoinKnownSurvivingPostAndStayAttachedOnReplay() async throws {
        let stem = "2026-03-10-twitter-Sample_Artist-1000000000000000008"
        let video = try file(stem + "-1.mp4")
        let context = try file(stem + "-1.context.png")
        let post = try await item(stem: stem, source: "https://x.com/Sample_Artist/status/1000000000000000008")
        let tombstone = try await item(stem: stem + "-1", source: "https://twitter.com/Sample_Artist/status/1000000000000000008", media: [video], context: context, combined: true)
        try await assertActiveCount(0)
        let discovered = try await ArchiveWatcher(archivePath: archive).scanArchive()
        _ = try await store.reconcileCombinedAssociations(discovered)
        let immediatelyRepaired = try await store.fetchItem(id: post.id)
        XCTAssertEqual(immediatelyRepaired?.mediaFiles, [video])
        XCTAssertEqual(immediatelyRepaired?.contextImage, context)
        try await scan()
        try await scan()
        let owner = try await store.fetchItem(id: post.id)
        XCTAssertEqual(owner?.mediaFiles, [video])
        XCTAssertEqual(owner?.contextImage, context)
        let retired = try await store.fetchItem(id: tombstone.id)
        XCTAssertEqual(retired?.deletionReason, .combined)
        XCTAssertTrue(try XCTUnwrap(retired).metadata.deleted)
        try await assertActiveCount(1)
    }

    func testOnlyCopyRestoresWhenSurvivorIsUnknownAndDeletedSidecarCannotUndoIt() async throws {
        let stem = "2026-03-10-twitter-Sample_Artist-1000000000000000008-1"
        let video = try file(stem + ".mp4")
        let context = try file(stem + ".context.png")
        let tombstone = try await item(stem: stem, source: "https://x.com/Sample_Artist/status/1000000000000000008", media: [video], context: context, combined: true)
        try await assertActiveCount(0)
        try await scan()
        var restored = try await store.fetchItem(id: tombstone.id)
        XCTAssertFalse(try XCTUnwrap(restored).metadata.deleted)
        XCTAssertNil(restored?.deletionReason)
        XCTAssertEqual(restored?.mediaFiles, [video])
        XCTAssertEqual(restored?.contextImage, context)
        // Force a refresh while the original deleted:true sidecar is still present.
        try await database.write { db in try db.execute(sql: "DELETE FROM archive_scan_cache") }
        try await scan()
        restored = try await store.fetchItem(id: tombstone.id)
        XCTAssertFalse(try XCTUnwrap(restored).metadata.deleted)
        await store.writeBackQueue.flushNow()
        XCTAssertFalse(try MetadataParser.parse(fileAt: tombstone.metadataFile).deleted)
        try await scan()
        try await assertActiveCount(1)
    }

    func testNumberedGeneratedContextJoinsPostAndOtherContextsRemainVisible() async throws {
        let stem = "2026-03-10-twitter-sample902-1000000000000000009"
        let media = try file(stem + "-1.png")
        let originalContext = try file(stem + ".context.png")
        let context = try file(stem + "-4.context.png")
        let post = try await item(stem: stem, source: "https://x.com/sample902/status/1000000000000000009", media: [media], context: originalContext)
        let tombstone = try await item(stem: stem + "-4.context", source: context.absoluteString, context: context, combined: true)
        try "---\nsource: \(context.absoluteString)\narchived: 2026-03-10T12:00:00Z\n---\n".write(to: tombstone.metadataFile, atomically: true, encoding: .utf8)
        try await scan()
        try await scan()
        let owner = try await store.fetchItem(id: post.id)
        let paths = Set((owner?.mediaFiles ?? []) + [owner?.contextImage].compactMap { $0 })
        XCTAssertEqual(paths, Set([media, originalContext, context]))
        let retired = try await store.fetchItem(id: tombstone.id)
        XCTAssertEqual(retired?.deletionReason, .combined)
        XCTAssertTrue(try XCTUnwrap(retired).metadata.deleted)
        try await assertActiveCount(1)
    }

    func testSharedFilesNeverResurrectTombstoneEvenWithDifferentSourceURLs() async throws {
        let shared = try file("secondary.png")
        let extraContext = try file("secondary.context.png")
        let post = try await item(stem: "primary", source: "https://example.com/primary", media: [shared])
        let tombstone = try await item(stem: "secondary", source: "https://example.com/secondary", media: [shared], context: extraContext, combined: true)
        try await scan()
        try await scan()
        let owner = try await store.fetchItem(id: post.id)
        XCTAssertEqual(owner?.mediaFiles, [shared])
        XCTAssertEqual(owner?.contextImage, extraContext)
        let retired = try await store.fetchItem(id: tombstone.id)
        XCTAssertEqual(retired?.deletionReason, .combined)
        XCTAssertTrue(try XCTUnwrap(retired).metadata.deleted)
        try await assertActiveCount(1)
    }

    func testAssociationMaintenanceKeepsFilesAdoptedBySuffixedSurvivor() async throws {
        let shared = try file("secondary.png")
        let own = try file("primary-1.png")
        let post = try await item(stem: "primary-1", source: "https://example.com/primary", media: [own, shared])
        _ = try await item(stem: "secondary", source: "https://example.com/secondary", media: [shared], combined: true)
        try await scan()
        let repaired = await coordinator.fixMetadataMediaAssociations()
        XCTAssertTrue(repaired)
        let owner = try await store.fetchItem(id: post.id)
        XCTAssertEqual(Set(owner?.mediaFiles ?? []), Set([own, shared]))
        try await assertActiveCount(1)
    }

    func testSharedNonliteralFileKeepsMergeOwnershipEvidenceAcrossScans() async throws {
        let media = try file("canonical.png")
        _ = try await item(stem: "canonical", source: "https://example.com/canonical", media: [media])
        let post = try await item(stem: "primary", source: "https://example.com/primary", media: [media])
        let tombstone = try await item(stem: "secondary", source: "https://example.com/secondary", media: [media], combined: true)
        try await scan()
        try await scan()
        let owner = try await store.fetchItem(id: post.id)
        XCTAssertEqual(owner?.mediaFiles, [media])
        let retired = try await store.fetchItem(id: tombstone.id)
        XCTAssertEqual(retired?.mediaFiles, [media])
        XCTAssertTrue(try XCTUnwrap(retired).metadata.deleted)
        try await assertActiveCount(2)
    }

    func testMissingFilesAndUserTombstonesAreNotRestored() async throws {
        let missing = archive.appendingPathComponent("missing.png")
        let tombstone = try await item(stem: "missing", source: "https://x.com/user/status/123", media: [missing], combined: true)
        let media = try file("manual.png")
        let manual = try await item(stem: "manual", source: "https://x.com/user/status/456", media: [media])
        try await store.softDelete(ids: [manual.id])
        try await scan()
        let retired = try await store.fetchItem(id: tombstone.id)
        let deleted = try await store.fetchItem(id: manual.id)
        XCTAssertTrue(try XCTUnwrap(retired).metadata.deleted)
        XCTAssertTrue(try XCTUnwrap(deleted).metadata.deleted)
        try await assertActiveCount(0)
    }

    func testDeletingSurvivorDoesNotResurrectItsCombinedIdentity() async throws {
        let shared = try file("secondary.png")
        let post = try await item(stem: "primary", source: "https://example.com/primary", media: [shared])
        let tombstone = try await item(stem: "secondary", source: "https://example.com/secondary", media: [shared], combined: true)
        try await store.softDelete(ids: [post.id])
        try await scan()
        let retired = try await store.fetchItem(id: tombstone.id)
        XCTAssertTrue(try XCTUnwrap(retired).metadata.deleted)
        XCTAssertEqual(retired?.deletionReason, .combined)
        try await assertActiveCount(0)
    }

    func testMissingFilesSurvivorDoesNotRestoreCombinedIdentityFirst() async throws {
        let shared = try file("secondary.png")
        let post = try await item(stem: "primary", source: "https://example.com/primary", media: [shared])
        let tombstone = try await item(stem: "secondary", source: "https://example.com/secondary", media: [shared], combined: true)
        try await database.write { db in
            try MetadataOutbox.importing(in: db) {
                try db.execute(sql: "UPDATE media_items SET deletedAt = ?, deletionReason = 'missingFiles' WHERE id = ?", arguments: [Date(), post.id.uuidString])
            }
        }
        try await scan()
        let retired = try await store.fetchItem(id: tombstone.id)
        XCTAssertTrue(try XCTUnwrap(retired).metadata.deleted)
        XCTAssertEqual(retired?.deletionReason, .combined)
        try await assertActiveCount(0)
    }

    func testMultipleActiveCarriersKeepSharedFilesAndAdoptOrphanContext() async throws {
        let firstFile = try file("secondary-1.png")
        let secondFile = try file("secondary-2.png")
        let context = try file("secondary.context.png")
        let first = try await item(stem: "primary-a", source: "https://example.com/a", media: [firstFile])
        let second = try await item(stem: "primary-b", source: "https://example.com/b", media: [secondFile])
        let tombstone = try await item(stem: "secondary", source: "https://example.com/secondary", media: [firstFile, secondFile], context: context, combined: true)
        try await scan()
        try await scan()
        let firstOwner = try await store.fetchItem(id: first.id)
        let secondOwner = try await store.fetchItem(id: second.id)
        XCTAssertEqual(firstOwner?.mediaFiles, [firstFile])
        XCTAssertEqual(secondOwner?.mediaFiles, [secondFile])
        XCTAssertEqual(firstOwner?.contextImage, context)
        let retired = try await store.fetchItem(id: tombstone.id)
        XCTAssertTrue(try XCTUnwrap(retired).metadata.deleted)
        try await assertActiveCount(2)
    }

    func testUnrelatedCaptureOfSameStatusDoesNotBecomeSurvivor() async throws {
        let media = try file("leftover.png")
        let deliberate = try await item(stem: "deliberate-copy", source: "https://x.com/user/status/123")
        let tombstone = try await item(stem: "leftover", source: "https://x.com/user/status/123", media: [media], combined: true)
        try await scan()
        let copy = try await store.fetchItem(id: deliberate.id)
        XCTAssertTrue(try XCTUnwrap(copy).mediaFiles.isEmpty)
        let restored = try await store.fetchItem(id: tombstone.id)
        XCTAssertFalse(try XCTUnwrap(restored).metadata.deleted)
        XCTAssertEqual(restored?.mediaFiles, [media])
    }

    func testCachedStatusAuthorsBackfillDBOnlyAndServeAuthorFilterAndRelated() async throws {
        let first = try await item(stem: "first", source: "https://x.com/Sample_Artist/status/123", media: [file("first.png")])
        let second = try await item(stem: "second", source: "https://twitter.com/Sample_Artist/status/456", media: [file("second.png")])
        try await database.write { db in try db.execute(sql: "UPDATE media_items SET author = NULL") }
        let before = try Data(contentsOf: first.metadataFile)
        let missingAuthors = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE author IS NULL")
        }
        XCTAssertEqual(missingAuthors, 2)
        try await scan()
        let replayBackfilled = try await store.backfillStatusURLAuthors()
        XCTAssertEqual(replayBackfilled, 0)
        var filter = FilterState.all
        filter.author = "Sample_Artist"
        let authors = try await store.fetchItems(filter: filter)
        XCTAssertEqual(Set(authors.map(\.id)), Set([first.id, second.id]))
        let related = try await store.fetchByAuthor("Sample_Artist", excluding: first.id)
        XCTAssertEqual(related.map(\.id), [second.id])
        XCTAssertEqual(try Data(contentsOf: first.metadataFile), before)
        let pending = try await store.writeBackQueue.statuses()
        XCTAssertTrue(pending.isEmpty)
    }
}
