import XCTest
import GRDB
@testable import MediaViewer

/// Integration tests for file system change handling:
/// Add/modify/delete/rename files -> Database updates accordingly
final class FileChangeTests: XCTestCase {

    var testDatabase: TestDatabase!
    var testArchive: TestArchive!
    var dbPool: DatabasePool!

    override func setUp() async throws {
        try await super.setUp()
        testDatabase = TestDatabase()
        dbPool = try await testDatabase.initialize()
        testArchive = try TestArchive()
    }

    override func tearDown() async throws {
        try testArchive.cleanup()
        await testDatabase.tearDown()
        testArchive = nil
        testDatabase = nil
        dbPool = nil
        try await super.tearDown()
    }

    // MARK: - Helper Functions

    /// Insert an item into the database from a metadata file
    private func importItem(metadataURL: URL, mediaURL: URL) async throws -> MediaItem {
        let metadata = try MetadataParser.parse(fileAt: metadataURL)
        let item = MediaItem(
            id: UUID(),
            basePath: metadataURL.deletingLastPathComponent(),
            metadataFile: metadataURL,
            mediaFiles: [mediaURL],
            metadata: metadata
        )

        let record = MediaItemRecord(from: item)
        try await dbPool.write { db in
            try record.insertWithFTSSync(db: db)
        }

        return item
    }

    /// Fetch an item by metadata file path
    private func fetchItem(byMetadataPath path: String) async throws -> MediaItemRecord? {
        try await dbPool.read { db in
            try MediaItemRecord.fetchOne(
                db,
                sql: "SELECT * FROM media_items WHERE metadataFileString = ?",
                arguments: [path]
            )
        }
    }

    /// Fetch an item by ID
    private func fetchItem(byId id: UUID) async throws -> MediaItemRecord? {
        try await dbPool.read { db in
            try MediaItemRecord.fetchOne(
                db,
                sql: "SELECT * FROM media_items WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    /// Count all items
    private func countItems() async throws -> Int {
        try await dbPool.read { db in
            try MediaItemRecord.fetchCount(db)
        }
    }

    // MARK: - Add File Tests

    func testNewFileAppearsInDatabase() async throws {
        // Create a new item in the archive
        let (mdURL, imageURL) = try testArchive.createItem(
            in: "2025-01",
            baseName: "new_item",
            source: "https://twitter.com/test/123",
            author: "@testuser"
        )

        // Import it
        _ = try await importItem(metadataURL: mdURL, mediaURL: imageURL)

        // Verify it's in the database
        let fetched = try await fetchItem(byMetadataPath: mdURL.path)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.author, "@testuser")
        XCTAssertEqual(fetched?.platform, "twitter")
    }

    func testMultipleNewFilesAddedSequentially() async throws {
        // Create and import multiple items
        for i in 0..<5 {
            let (mdURL, imageURL) = try testArchive.createItem(
                in: "2025-01",
                baseName: "item_\(i)",
                source: "https://example.com/\(i)",
                author: "@user\(i)"
            )
            _ = try await importItem(metadataURL: mdURL, mediaURL: imageURL)
        }

        // Verify all items in database
        let count = try await countItems()
        XCTAssertEqual(count, 5)
    }

    func testNewFileInDifferentFolders() async throws {
        // Create items in different year-month folders
        let (md1, img1) = try testArchive.createItem(
            in: "2024-12",
            baseName: "old_item",
            source: "https://example.com/old",
            author: "@old"
        )

        let (md2, img2) = try testArchive.createItem(
            in: "2025-01",
            baseName: "new_item",
            source: "https://example.com/new",
            author: "@new"
        )

        _ = try await importItem(metadataURL: md1, mediaURL: img1)
        _ = try await importItem(metadataURL: md2, mediaURL: img2)

        // Verify both items exist
        let count = try await countItems()
        XCTAssertEqual(count, 2)

        // Verify correct folder paths
        let item1 = try await fetchItem(byMetadataPath: md1.path)
        let item2 = try await fetchItem(byMetadataPath: md2.path)

        XCTAssertTrue(item1?.basePathString.contains("2024-12") ?? false)
        XCTAssertTrue(item2?.basePathString.contains("2025-01") ?? false)
    }

    // MARK: - Modify File Tests

    func testModifyMetadataUpdatesDatabase() async throws {
        // Create and import initial item
        let (mdURL, imageURL) = try testArchive.createItem(
            in: "2025-01",
            baseName: "modifiable_item",
            source: "https://twitter.com/test/456",
            author: "@original",
            starred: false,
            tags: ["initial"]
        )

        let item = try await importItem(metadataURL: mdURL, mediaURL: imageURL)

        // Verify initial state
        var fetched = try await fetchItem(byId: item.id)
        XCTAssertEqual(fetched?.author, "@original")
        XCTAssertFalse(fetched?.starred ?? true)

        // Modify the metadata file
        let newContent = """
        ---
        source: https://twitter.com/test/456
        platform: twitter
        author: "@updated"
        starred: true
        tags:
          - updated
          - modified
        archived: 2025-01-15
        ---
        Updated content
        """
        try testArchive.updateMetadataFile(mdURL, newContent: newContent)

        // Re-parse and update
        let newMetadata = try MetadataParser.parse(fileAt: mdURL)
        var updatedItem = item
        updatedItem.metadata = newMetadata

        let record = MediaItemRecord(from: updatedItem)
        try await dbPool.write { db in
            try record.updateWithFTSSync(db: db)
        }

        // Verify updated state
        fetched = try await fetchItem(byId: item.id)
        XCTAssertEqual(fetched?.author, "@updated")
        XCTAssertTrue(fetched?.starred ?? false)

        // Verify tags updated
        let tagsJSON = fetched?.tagsJSON ?? "[]"
        let tags = (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? []
        XCTAssertTrue(tags.contains("updated"))
        XCTAssertTrue(tags.contains("modified"))
        XCTAssertFalse(tags.contains("initial"))
    }

    func testModifyPreservesUserData() async throws {
        // Create and import item
        let (mdURL, imageURL) = try testArchive.createItem(
            in: "2025-01",
            baseName: "preserve_item",
            source: "https://example.com/preserve",
            author: "@author"
        )

        let item = try await importItem(metadataURL: mdURL, mediaURL: imageURL)

        // Add user data: star and notes
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET starred = ?, notes = ? WHERE id = ?",
                arguments: [true, "My personal note", item.id.uuidString]
            )
        }

        // Verify user data was set
        var fetched = try await fetchItem(byId: item.id)
        XCTAssertTrue(fetched?.starred ?? false)
        XCTAssertEqual(fetched?.notes, "My personal note")

        // Modify the metadata file (simulating external edit)
        let newContent = """
        ---
        source: https://example.com/preserve
        platform: example
        author: "@newauthor"
        archived: 2025-01-15
        ---
        """
        try testArchive.updateMetadataFile(mdURL, newContent: newContent)

        // Update only metadata fields, preserving user data
        let newMetadata = try MetadataParser.parse(fileAt: mdURL)

        try await dbPool.write { db in
            // Update only metadata fields, keep starred, notes, tags
            try db.execute(
                sql: """
                    UPDATE media_items
                    SET author = ?, platform = ?
                    WHERE id = ?
                """,
                arguments: [newMetadata.author, newMetadata.platform, item.id.uuidString]
            )
        }

        // Verify metadata updated but user data preserved
        fetched = try await fetchItem(byId: item.id)
        XCTAssertEqual(fetched?.author, "@newauthor")
        XCTAssertTrue(fetched?.starred ?? false, "Starred should be preserved")
        XCTAssertEqual(fetched?.notes, "My personal note", "Notes should be preserved")
    }

    // MARK: - Delete File Tests

    func testDeleteFileRemovesFromDatabase() async throws {
        // Create and import item
        let (mdURL, imageURL) = try testArchive.createItem(
            in: "2025-01",
            baseName: "deletable_item",
            source: "https://example.com/delete",
            author: "@delete"
        )

        let item = try await importItem(metadataURL: mdURL, mediaURL: imageURL)

        // Verify item exists
        var count = try await countItems()
        XCTAssertEqual(count, 1)

        // Delete the metadata file
        try testArchive.deleteFile(mdURL)

        // Remove from database
        try await dbPool.write { db in
            try MediaItemRecord.deleteFromFTS(db: db, id: item.id)
            try db.execute(
                sql: "DELETE FROM media_items WHERE id = ?",
                arguments: [item.id.uuidString]
            )
        }

        // Verify item removed
        count = try await countItems()
        XCTAssertEqual(count, 0)
    }

    func testDeleteOneOfMultiple() async throws {
        // Create three items
        var items: [MediaItem] = []
        for i in 0..<3 {
            let (mdURL, imageURL) = try testArchive.createItem(
                in: "2025-01",
                baseName: "item_\(i)",
                source: "https://example.com/\(i)",
                author: "@user\(i)"
            )
            items.append(try await importItem(metadataURL: mdURL, mediaURL: imageURL))
        }

        // Verify all three exist
        var count = try await countItems()
        XCTAssertEqual(count, 3)

        // Delete the middle item
        let itemToDelete = items[1]
        try await dbPool.write { db in
            try MediaItemRecord.deleteFromFTS(db: db, id: itemToDelete.id)
            try db.execute(
                sql: "DELETE FROM media_items WHERE id = ?",
                arguments: [itemToDelete.id.uuidString]
            )
        }

        // Verify only 2 remain
        count = try await countItems()
        XCTAssertEqual(count, 2)

        // Verify correct items remain
        let remaining0 = try await fetchItem(byId: items[0].id)
        let remaining2 = try await fetchItem(byId: items[2].id)
        let deleted = try await fetchItem(byId: items[1].id)

        XCTAssertNotNil(remaining0)
        XCTAssertNotNil(remaining2)
        XCTAssertNil(deleted)
    }

    // MARK: - Rename File Tests

    func testRenameFileUpdatesPath() async throws {
        // Create and import item
        let (mdURL, imageURL) = try testArchive.createItem(
            in: "2025-01",
            baseName: "original_name",
            source: "https://example.com/rename",
            author: "@rename"
        )

        let item = try await importItem(metadataURL: mdURL, mediaURL: imageURL)

        // Verify original path
        var fetched = try await fetchItem(byId: item.id)
        XCTAssertTrue(fetched?.metadataFileString.contains("original_name") ?? false)

        // Rename the file
        let newMdURL = try testArchive.renameFile(from: mdURL, to: "renamed_item.md")

        // Update the path in database
        let updated = try await dbPool.write { db in
            try MediaItemRecord.updateFilePath(
                db: db,
                oldPath: mdURL.path,
                newPath: newMdURL.path
            )
        }
        XCTAssertTrue(updated)

        // Verify new path
        fetched = try await fetchItem(byId: item.id)
        XCTAssertTrue(fetched?.metadataFileString.contains("renamed_item") ?? false)
        XCTAssertFalse(fetched?.metadataFileString.contains("original_name") ?? true)

        // Verify user data preserved
        XCTAssertEqual(fetched?.author, "@rename")
    }

    func testRenamePreservesUserData() async throws {
        // Create and import item
        let (mdURL, imageURL) = try testArchive.createItem(
            in: "2025-01",
            baseName: "star_then_rename",
            source: "https://example.com/starename",
            author: "@starename"
        )

        let item = try await importItem(metadataURL: mdURL, mediaURL: imageURL)

        // Add user data
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET starred = ?, notes = ?, tagsJSON = ? WHERE id = ?",
                arguments: [true, "Important note", "[\"favorite\",\"art\"]", item.id.uuidString]
            )
        }

        // Rename the file
        let newMdURL = try testArchive.renameFile(from: mdURL, to: "renamed_starred.md")

        // Update the path in database
        let updated = try await dbPool.write { db in
            try MediaItemRecord.updateFilePath(
                db: db,
                oldPath: mdURL.path,
                newPath: newMdURL.path
            )
        }
        XCTAssertTrue(updated)

        // Verify all user data preserved
        let fetched = try await fetchItem(byId: item.id)
        XCTAssertTrue(fetched?.starred ?? false, "Starred should be preserved after rename")
        XCTAssertEqual(fetched?.notes, "Important note", "Notes should be preserved after rename")

        let tagsJSON = fetched?.tagsJSON ?? "[]"
        let tags = (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? []
        XCTAssertTrue(tags.contains("favorite"), "Tags should be preserved after rename")
        XCTAssertTrue(tags.contains("art"), "Tags should be preserved after rename")
    }

    // MARK: - Batch Path Update Tests

    func testBatchPathUpdate() async throws {
        // Create multiple items in the same folder
        var items: [MediaItem] = []
        let folderName = "2025-01"

        for i in 0..<3 {
            let (mdURL, imageURL) = try testArchive.createItem(
                in: folderName,
                baseName: "batch_item_\(i)",
                source: "https://example.com/batch/\(i)",
                author: "@batch\(i)"
            )
            items.append(try await importItem(metadataURL: mdURL, mediaURL: imageURL))
        }

        // Get old base path
        let oldBasePath = testArchive.rootURL.appendingPathComponent(folderName).path

        // Create new folder and "move" (simulate rename)
        let newFolderName = "2025-02"
        let newFolderURL = try testArchive.createFolder(newFolderName)
        let newBasePath = newFolderURL.path

        // Update all paths in batch
        let updateCount = try await dbPool.write { db in
            try MediaItemRecord.updatePaths(
                db: db,
                oldBasePath: oldBasePath,
                newBasePath: newBasePath
            )
        }
        XCTAssertEqual(updateCount, 3)

        // Verify all items updated
        for item in items {
            let fetched = try await fetchItem(byId: item.id)
            XCTAssertTrue(fetched?.basePathString.contains(newFolderName) ?? false)
            XCTAssertFalse(fetched?.basePathString.contains(folderName) ?? true)
        }
    }

    // MARK: - Edge Cases

    func testDeleteNonexistentItem() async throws {
        let nonexistentId = UUID()

        // Try to delete item that doesn't exist
        let deletedCount = try await dbPool.write { db -> Int in
            try db.execute(
                sql: "DELETE FROM media_items WHERE id = ?",
                arguments: [nonexistentId.uuidString]
            )
            return db.changesCount
        }

        XCTAssertEqual(deletedCount, 0)
    }

    func testRenameNonexistentPath() async throws {
        // Try to update path that doesn't exist
        let updated = try await dbPool.write { db in
            try MediaItemRecord.updateFilePath(
                db: db,
                oldPath: "/nonexistent/path.md",
                newPath: "/new/path.md"
            )
        }

        XCTAssertFalse(updated)
    }

    func testParseStatusPreservedOnUpdate() async throws {
        // Create item with partial parse status
        let item = SampleData.createMediaItem(
            id: UUID(),
            source: "https://example.com/partial",
            author: "@partial",
            parseStatus: .partial
        )

        // Create record with parse errors
        let record = MediaItemRecord(from: MediaItem(
            id: item.id,
            basePath: item.basePath,
            metadataFile: item.metadataFile,
            mediaFiles: item.mediaFiles,
            metadata: item.metadata,
            parseStatus: .partial,
            parseErrors: ["Ambiguous date format"]
        ))

        try await dbPool.write { [record] db in
            try record.insert(db)
        }

        // Verify parse status
        var fetched = try await fetchItem(byId: item.id)
        XCTAssertEqual(fetched?.parseStatus, "partial")

        // Update some field
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET starred = ? WHERE id = ?",
                arguments: [true, item.id.uuidString]
            )
        }

        // Verify parse status still preserved
        fetched = try await fetchItem(byId: item.id)
        XCTAssertEqual(fetched?.parseStatus, "partial")
        XCTAssertTrue(fetched?.starred ?? false)
    }

    // MARK: - FTS Sync on File Changes

    func testFTSSyncAfterMetadataUpdate() async throws {
        // Create and import item with OCR text
        let (mdURL, imageURL) = try testArchive.createItem(
            in: "2025-01",
            baseName: "fts_item",
            source: "https://example.com/fts",
            author: "@ftstest"
        )

        let item = try await importItem(metadataURL: mdURL, mediaURL: imageURL)
        let itemId = item.id.uuidString

        // Add OCR text — content-synced FTS triggers handle index sync automatically
        try await dbPool.write { [itemId] db in
            try db.execute(
                sql: "UPDATE media_items SET ocrText = ? WHERE id = ?",
                arguments: ["Original OCR text here", itemId]
            )
        }

        // Search should find the item
        var results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE ocrText LIKE ?
            """, arguments: ["%Original%"])
        }
        XCTAssertEqual(results.count, 1)

        // Update OCR text — triggers handle FTS sync
        try await dbPool.write { [itemId] db in
            try db.execute(
                sql: "UPDATE media_items SET ocrText = ? WHERE id = ?",
                arguments: ["Updated OCR content completely different", itemId]
            )
        }

        // Search for old text should find nothing
        results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE ocrText LIKE ?
            """, arguments: ["%Original%"])
        }
        XCTAssertEqual(results.count, 0)

        // Search for new text should find the item
        results = try await dbPool.read { db in
            try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE ocrText LIKE ?
            """, arguments: ["%Updated%"])
        }
        XCTAssertEqual(results.count, 1)
    }

    func testFTSCleanupOnDelete() async throws {
        // Create and import item
        let (mdURL, imageURL) = try testArchive.createItem(
            in: "2025-01",
            baseName: "fts_delete_item",
            source: "https://example.com/ftsdelete",
            author: "@ftsdelete"
        )

        let item = try await importItem(metadataURL: mdURL, mediaURL: imageURL)

        // Add OCR text and sync to FTS
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET ocrText = ? WHERE id = ?",
                arguments: ["Searchable text for FTS delete test", item.id.uuidString]
            )

            // Add to FTS (contentless FTS5 - just add, can't update)
            try db.execute(
                sql: """
                    INSERT INTO media_items_fts (id, ocrText, notes, author)
                    SELECT id, ocrText, notes, author FROM media_items WHERE id = ?
                """,
                arguments: [item.id.uuidString]
            )
        }

        // Delete from main table
        try await dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM media_items WHERE id = ?",
                arguments: [item.id.uuidString]
            )
        }

        // Verify main table is empty
        let mainCount = try await dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE id = ?", arguments: [item.id.uuidString])
        }
        XCTAssertEqual(mainCount, 0)

        // Note: Contentless FTS5 with UNINDEXED id column doesn't support
        // DELETE WHERE id = ?, so orphaned FTS entries may remain.
        // Production should use rebuildFTSIndex periodically to clean up.
    }
}
