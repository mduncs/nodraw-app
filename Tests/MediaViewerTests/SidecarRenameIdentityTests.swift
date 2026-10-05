import XCTest
import GRDB
@testable import MediaViewer

/// A sidecar renamed or moved while the app runs must never cost the item its identity or send
/// its still-present media to the Trash (the watcher sees the old path only after it vanished).
final class SidecarRenameIdentityTests: XCTestCase {
    private var root: URL!
    private var archive: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SidecarRename-\(UUID())")
        archive = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: root.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        store = MediaStore(database: database)
    }

    override func tearDown() async throws {
        store = nil
        database = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func importedItem() async throws -> MediaItem {
        let source = root.appendingPathComponent("source.png")
        try ImportDurabilityTests.png.write(to: source)
        let result = try await ImportService(mediaStore: store, visionQueue: nil, archivePath: archive)
            .importFiles([source], tags: ["keep-me"])
        let id = try XCTUnwrap(result.createdItemIds.first)
        return try await XCTUnwrapAsync(await store.fetchItem(id: id))
    }

    private func deletion(_ id: UUID) async throws -> (deleted: Bool, reason: String?) {
        try await database.read { db in
            let row = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT deletedAt, deletionReason FROM media_items WHERE id = ?", arguments: [id.uuidString]))
            let deletedAt: String? = row["deletedAt"]
            return (deletedAt.map { !$0.isEmpty } ?? false, row["deletionReason"])
        }
    }

    func testRenamedSidecarKeepsMediaAndReattachesToOriginalItem() async throws {
        let item = try await importedItem()
        let oldSidecar = item.metadataFile
        let newSidecar = oldSidecar.deletingLastPathComponent().appendingPathComponent("renamed.md")
        try FileManager.default.moveItem(at: oldSidecar, to: newSidecar)

        try await store.markSidecarMissing(id: item.id)
        for media in item.mediaFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: media.path), "media must not be trashed")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldSidecar.path), "no write-back may resurrect the old sidecar")
        let hidden = try await deletion(item.id)
        XCTAssertTrue(hidden.deleted)
        XCTAssertEqual(hidden.reason, MediaItemDeletionReason.missingFiles.rawValue)

        let adopted = try await store.adoptMovedSidecar(at: newSidecar, mediaFiles: item.mediaFiles)
        XCTAssertEqual(adopted, item.id)
        let restored = try await XCTUnwrapAsync(await store.fetchItem(byMetadataPath: newSidecar.path))
        XCTAssertEqual(restored.id, item.id)
        XCTAssertEqual(restored.metadata.tags, item.metadata.tags)
        let visible = try await deletion(item.id)
        XCTAssertFalse(visible.deleted)
    }

    func testAdoptionRequiresSameMediaAndNeverRevivesUserDeletion() async throws {
        let item = try await importedItem()
        let newSidecar = item.metadataFile.deletingLastPathComponent().appendingPathComponent("other.md")
        try FileManager.default.moveItem(at: item.metadataFile, to: newSidecar)

        try await store.softDelete(ids: [item.id])
        let userDeleted = try await store.adoptMovedSidecar(at: newSidecar, mediaFiles: item.mediaFiles)
        XCTAssertNil(userDeleted)

        try await store.restoreDeleted(ids: [item.id])
        try await store.markSidecarMissing(id: item.id)
        let unrelated = root.appendingPathComponent("unrelated.png")
        let mismatched = try await store.adoptMovedSidecar(at: newSidecar, mediaFiles: [unrelated])
        XCTAssertNil(mismatched)
        let stillHidden = try await deletion(item.id)
        XCTAssertTrue(stillHidden.deleted)
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
