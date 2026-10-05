import XCTest
import GRDB
@testable import MediaViewer

final class TagSubtreeAtomicityTests: XCTestCase {
    private func fixture(tags: [String]) async throws -> (URL, DatabaseManager, MediaStore, UUID) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TagAtomicity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        let store = MediaStore(database: database)
        let item = SampleData.createMediaItem(basePath: directory,
            metadataFile: directory.appendingPathComponent("item.md"),
            mediaFiles: [directory.appendingPathComponent("item.jpg")],
            source: "https://example.com/fixture", platform: "import", author: nil,
            archivedDate: Date(), tags: tags)
        try await store.insertItemsBatch([item])
        return (directory, database, store, item.id)
    }

    private func storedTags(_ database: DatabaseManager, id: UUID) async throws -> Set<String> {
        try await database.read { db in
            let json = try String.fetchOne(db, sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                                           arguments: [id.uuidString]) ?? "[]"
            return Set(try JSONDecoder().decode([String].self, from: Data(json.utf8)).map(TagCanonicalizer.key))
        }
    }

    func testRemovalFailureRollsBackEveryTagAndItsJSON() async throws {
        let (directory, database, store, id) = try await fixture(tags: ["Parent", "Child", "Unrelated"])
        defer { try? FileManager.default.removeItem(at: directory) }
        try await database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_parent_removal BEFORE DELETE ON media_tags
                WHEN OLD.tag = 'parent' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;
                """)
        }
        do {
            _ = try await store.removeTagsGlobally(tags: ["Parent", "Child"])
            XCTFail("Expected the second canonical tag removal to fail")
        } catch { }
        let parentCount = try await store.countItemsTaggedExactly(tag: "Parent")
        let childCount = try await store.countItemsTaggedExactly(tag: "Child")
        let tags = try await storedTags(database, id: id)
        XCTAssertEqual(parentCount, 1)
        XCTAssertEqual(childCount, 1, "The earlier removal must be rolled back too")
        XCTAssertEqual(tags, ["parent", "child", "unrelated"])
    }

    func testRestoreFailureIsAtomicAndCanBeRetried() async throws {
        let (directory, database, store, id) = try await fixture(tags: ["Unrelated"])
        defer { try? FileManager.default.removeItem(at: directory) }
        try await database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_parent_restore BEFORE INSERT ON media_tags
                WHEN NEW.tag = 'parent' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;
                """)
        }
        do {
            try await store.restoreTagAssignments(["Parent": [id], "Child": [id]])
            XCTFail("Expected the later restoration to fail")
        } catch { }
        let childCount = try await store.countItemsTaggedExactly(tag: "Child")
        let afterFailure = try await storedTags(database, id: id)
        XCTAssertEqual(childCount, 0, "No earlier restoration may leak from the failed transaction")
        XCTAssertEqual(afterFailure, ["unrelated"])
        try await database.write { db in try db.execute(sql: "DROP TRIGGER fail_parent_restore") }
        try await store.restoreTagAssignments(["Parent": [id], "Child": [id]])
        let afterRetry = try await storedTags(database, id: id)
        XCTAssertEqual(afterRetry, ["parent", "child", "unrelated"])
        let captured = try await store.removeTagsGlobally(tags: ["PARENT", "child", "Child"])
        XCTAssertEqual(Set(captured.keys), ["parent", "child"])
        XCTAssertEqual(captured["parent"], [id])
        XCTAssertEqual(captured["child"], [id])
        let remaining = try await storedTags(database, id: id)
        XCTAssertEqual(remaining, ["unrelated"])
    }
}
