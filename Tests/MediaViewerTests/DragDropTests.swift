import XCTest
import UniformTypeIdentifiers
import GRDB
@testable import MediaViewer

/// Tests for drag-drop functionality: MediaItemDragData, serialization, and drop handling.
final class DragDropTests: XCTestCase {

    private var tempDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in tempDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        tempDirectories.removeAll()
    }

    // MARK: - MediaItemDragData Tests

    func testDragDataSingleItem() {
        let itemId = UUID()
        let dragData = MediaItemDragData(itemId: itemId)

        XCTAssertEqual(dragData.itemIds.count, 1)
        XCTAssertEqual(dragData.itemIds.first, itemId)
    }

    func testDragDataMultipleItems() {
        let itemIds = [UUID(), UUID(), UUID()]
        let dragData = MediaItemDragData(itemIds: itemIds)

        XCTAssertEqual(dragData.itemIds.count, 3)
        XCTAssertEqual(dragData.itemIds, itemIds)
    }

    func testDragDataEquatable() {
        let itemId = UUID()
        let data1 = MediaItemDragData(itemId: itemId)
        let data2 = MediaItemDragData(itemId: itemId)
        let data3 = MediaItemDragData(itemId: UUID())

        XCTAssertEqual(data1, data2)
        XCTAssertNotEqual(data1, data3)
    }

    // MARK: - Serialization Tests

    func testDragDataCodable() throws {
        let itemIds = [UUID(), UUID()]
        let dragData = MediaItemDragData(itemIds: itemIds)

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(dragData)

        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MediaItemDragData.self, from: data)

        XCTAssertEqual(decoded.itemIds, itemIds)
    }

    func testDragDataEmptyArray() throws {
        let dragData = MediaItemDragData(itemIds: [])

        XCTAssertTrue(dragData.itemIds.isEmpty)

        // Should still encode/decode correctly
        let data = try JSONEncoder().encode(dragData)
        let decoded = try JSONDecoder().decode(MediaItemDragData.self, from: data)

        XCTAssertTrue(decoded.itemIds.isEmpty)
    }

    // MARK: - UTType Tests

    func testMediaViewerItemUTType() {
        // Verify the custom UTType is registered
        let utType = UTType.mediaViewerItem

        XCTAssertEqual(utType.identifier, kMediaViewerItemTypeIdentifier)
    }

    // MARK: - External Drag Provider Tests

    func testDragProviderSingleExternalFile() throws {
        let fileURL = try makeTempFile(named: "single.txt", contents: "single")
        let dragData = MediaItemDragData(itemId: UUID())

        let provider = try XCTUnwrap(makeMediaItemDragItemProviders(
            dragData: dragData,
            externalFileURLs: [fileURL]
        ).first)

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(kMediaViewerItemTypeIdentifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))

        let exportedURL = try loadURLItem(from: provider)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
        XCTAssertEqual(exportedURL.lastPathComponent, fileURL.lastPathComponent)
    }

    func testDragProviderMultiExternalFilesAreSeparateOrderedURLs() throws {
        let root = try makeTempDirectory()
        let firstDir = root.appendingPathComponent("a", isDirectory: true)
        let secondDir = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)

        let first = firstDir.appendingPathComponent("duplicate-name.jpg")
        let second = secondDir.appendingPathComponent("duplicate-name.jpg")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        let providers = try makeMediaItemDragItemProviders(
            dragData: MediaItemDragData(itemIds: [UUID(), UUID()]),
            externalFileURLs: [first, second]
        )

        XCTAssertEqual(providers.count, 2)
        XCTAssertEqual(try providers.map { try loadURLItem(from: $0) }, [first, second])
    }

    func testDragProviderPreservesInternalPayloadWithExternalFiles() throws {
        let fileURL = try makeTempFile(named: "internal-payload.txt", contents: "payload")
        let dragData = MediaItemDragData(itemIds: [UUID(), UUID()])

        let provider = try XCTUnwrap(makeMediaItemDragItemProviders(
            dragData: dragData,
            externalFileURLs: [fileURL]
        ).first)

        let expectation = expectation(description: "load internal drag payload")
        var loaded: MediaItemDragData?
        loadMediaItemDragData(from: provider) { data in
            loaded = data
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
        XCTAssertEqual(loaded, dragData)
    }

    // MARK: - Large Selection Tests

    func testDragDataLargeSelection() throws {
        // Test with many items (simulating large selection)
        let itemIds = (0..<100).map { _ in UUID() }
        let dragData = MediaItemDragData(itemIds: itemIds)

        XCTAssertEqual(dragData.itemIds.count, 100)

        // Verify serialization still works
        let data = try JSONEncoder().encode(dragData)
        let decoded = try JSONDecoder().decode(MediaItemDragData.self, from: data)

        XCTAssertEqual(decoded.itemIds.count, 100)
        XCTAssertEqual(decoded.itemIds, itemIds)
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DragDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectories.append(dir)
        return dir
    }

    private func makeTempFile(named: String, contents: String) throws -> URL {
        let dir = try makeTempDirectory()
        let fileURL = dir.appendingPathComponent(named)
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }

    private func loadURLItem(from provider: NSItemProvider) throws -> URL {
        let expectation = expectation(description: "load file url item")
        var loadedURL: URL?
        var loadedError: Error?

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            defer { expectation.fulfill() }

            if let error {
                loadedError = error
                return
            }

            if let url = item as? URL {
                loadedURL = url
                return
            }
            if let nsURL = item as? NSURL {
                loadedURL = nsURL as URL
                return
            }
            if let data = item as? Data,
               let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: raw) {
                loadedURL = url
            }
        }

        wait(for: [expectation], timeout: 2.0)
        if let loadedError { throw loadedError }
        return try XCTUnwrap(loadedURL)
    }
}

// MARK: - Drag-to-Tag Integration Tests

/// Integration tests for tag operations via drag-drop using in-memory GRDB database.
final class DragToTagIntegrationTests: XCTestCase {

    private var testPool: DatabasePool!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DragToTagTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dbPath = tempDir.appendingPathComponent("test.sqlite")
        testPool = try DatabasePool(path: dbPath.path)

        try testPool.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try MediaItemRecord.createTable(in: db)

            // Create media_tags junction table (from migration 4)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS media_tags (
                    item_id TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    PRIMARY KEY (item_id, tag),
                    FOREIGN KEY (item_id) REFERENCES media_items(id) ON DELETE CASCADE
                )
            """)
            try db.create(
                index: "idx_media_tags_tag",
                on: "media_tags",
                columns: ["tag"],
                ifNotExists: true
            )
        }
    }

    override func tearDownWithError() throws {
        testPool = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Tag Operations

    func testAddTagToSingleItem() async throws {
        let item = createTestMediaItem(tags: [])
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        // Simulate drag-to-tag: add "favorite" tag
        try await testPool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                arguments: [item.id.uuidString]
            ) else {
                XCTFail("Item not found")
                return
            }

            let json: String = row["tagsJSON"]
            var tags = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
            tags.append("favorite")
            let newJSON = (try? JSONEncoder().encode(tags))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

            try db.execute(
                sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                arguments: [newJSON, item.id.uuidString]
            )

            // Sync to junction table
            try db.execute(
                sql: "INSERT OR IGNORE INTO media_tags (item_id, tag) VALUES (?, ?)",
                arguments: [item.id.uuidString, "favorite"]
            )
        }

        // Verify tag was added
        let finalTags = try await testPool.read { db -> [String] in
            let json: String = try String.fetchOne(
                db,
                sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                arguments: [item.id.uuidString]
            )!
            return try JSONDecoder().decode([String].self, from: Data(json.utf8))
        }
        XCTAssertEqual(finalTags, ["favorite"])

        // Verify junction table sync
        let junctionCount = try await testPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_tags WHERE item_id = ? AND tag = ?",
                arguments: [item.id.uuidString, "favorite"]
            )
        }
        XCTAssertEqual(junctionCount, 1)
    }

    func testAddTagToMultipleItems() async throws {
        let items = (0..<5).map { _ in createTestMediaItem(tags: []) }
        let itemsToInsert = items
        try await testPool.write { db in
            for item in itemsToInsert {
                try MediaItemRecord(from: item).insert(db)
            }
        }

        // Simulate batch drag-to-tag: add "batch-tag" to all items
        let tagToAdd = "batch-tag"
        try await testPool.write { db in
            for item in items {
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                    arguments: [item.id.uuidString]
                ) else { continue }

                let json: String = row["tagsJSON"]
                var tags = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
                if !tags.contains(tagToAdd) {
                    tags.append(tagToAdd)
                    let newJSON = (try? JSONEncoder().encode(tags))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                    try db.execute(
                        sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                        arguments: [newJSON, item.id.uuidString]
                    )
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO media_tags (item_id, tag) VALUES (?, ?)",
                        arguments: [item.id.uuidString, tagToAdd]
                    )
                }
            }
        }

        // Verify all items have the tag
        let taggedCount = try await testPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_tags WHERE tag = ?",
                arguments: [tagToAdd]
            )
        }
        XCTAssertEqual(taggedCount, 5)
    }

    func testTagDeduplication() async throws {
        let item = createTestMediaItem(tags: ["existing-tag"])
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
            try db.execute(
                sql: "INSERT OR IGNORE INTO media_tags (item_id, tag) VALUES (?, ?)",
                arguments: [item.id.uuidString, "existing-tag"]
            )
        }

        // Try adding the same tag again (drag to same tag)
        try await testPool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                arguments: [item.id.uuidString]
            ) else { return }

            let json: String = row["tagsJSON"]
            var tags = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []

            // Only add if not already present (deduplication)
            if !tags.contains("existing-tag") {
                tags.append("existing-tag")
                let newJSON = (try? JSONEncoder().encode(tags))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try db.execute(
                    sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                    arguments: [newJSON, item.id.uuidString]
                )
            }

            // INSERT OR IGNORE handles junction table deduplication
            try db.execute(
                sql: "INSERT OR IGNORE INTO media_tags (item_id, tag) VALUES (?, ?)",
                arguments: [item.id.uuidString, "existing-tag"]
            )
        }

        // Verify tag count is still 1 (not duplicated)
        let finalTags = try await testPool.read { db -> [String] in
            let json: String = try String.fetchOne(
                db,
                sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                arguments: [item.id.uuidString]
            )!
            return try JSONDecoder().decode([String].self, from: Data(json.utf8))
        }
        XCTAssertEqual(finalTags.count, 1)
        XCTAssertEqual(finalTags, ["existing-tag"])

        // Verify junction table also has only one entry
        let junctionCount = try await testPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_tags WHERE item_id = ?",
                arguments: [item.id.uuidString]
            )
        }
        XCTAssertEqual(junctionCount, 1)
    }

    func testBatchTagWithMixedExisting() async throws {
        // Item1: no tags, Item2: already has "shared", Item3: no tags
        let item1 = createTestMediaItem(tags: [])
        let item2 = createTestMediaItem(tags: ["shared"])
        let item3 = createTestMediaItem(tags: [])

        try await testPool.write { db in
            try MediaItemRecord(from: item1).insert(db)
            try MediaItemRecord(from: item2).insert(db)
            try MediaItemRecord(from: item3).insert(db)
            try db.execute(
                sql: "INSERT OR IGNORE INTO media_tags (item_id, tag) VALUES (?, ?)",
                arguments: [item2.id.uuidString, "shared"]
            )
        }

        // Batch add "shared" tag to all items
        let itemIds = [item1.id, item2.id, item3.id]
        let tagToAdd = "shared"

        try await testPool.write { db in
            for itemId in itemIds {
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                    arguments: [itemId.uuidString]
                ) else { continue }

                let json: String = row["tagsJSON"]
                var tags = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
                if !tags.contains(tagToAdd) {
                    tags.append(tagToAdd)
                    let newJSON = (try? JSONEncoder().encode(tags))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                    try db.execute(
                        sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                        arguments: [newJSON, itemId.uuidString]
                    )
                }
                try db.execute(
                    sql: "INSERT OR IGNORE INTO media_tags (item_id, tag) VALUES (?, ?)",
                    arguments: [itemId.uuidString, tagToAdd]
                )
            }
        }

        // Verify all 3 items have the "shared" tag
        let taggedCount = try await testPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_tags WHERE tag = ?",
                arguments: [tagToAdd]
            )
        }
        XCTAssertEqual(taggedCount, 3)

        // Verify item2 still has exactly 1 entry for "shared" (not duplicated)
        let item2Count = try await testPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_tags WHERE item_id = ? AND tag = ?",
                arguments: [item2.id.uuidString, tagToAdd]
            )
        }
        XCTAssertEqual(item2Count, 1)
    }

    // MARK: - Helpers

    private func createTestMediaItem(tags: [String] = [], platform: String = "twitter") -> MediaItem {
        let id = UUID()
        let basePath = URL(fileURLWithPath: "/test/archive/2025-01")
        let metadataFile = basePath.appendingPathComponent("\(id.uuidString).md")

        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: metadataFile,
            mediaFiles: [basePath.appendingPathComponent("\(id.uuidString).jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://\(platform).com/test/\(id.uuidString)")!,
                platform: platform,
                author: "@testuser",
                originalDate: Date(),
                archivedDate: Date(),
                tags: tags
            )
        )
    }
}

// MARK: - Drag-to-Board Integration Tests

/// Integration tests for board operations via drag-drop.
final class DragToBoardIntegrationTests: XCTestCase {

    private var testPool: DatabasePool!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DragToBoardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dbPath = tempDir.appendingPathComponent("test.sqlite")
        testPool = try DatabasePool(path: dbPath.path)

        try testPool.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try MediaItemRecord.createTable(in: db)
            try CollectionBoard.createTable(in: db)
            try BoardMembership.createTable(in: db)
        }
    }

    override func tearDownWithError() throws {
        testPool = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Board Add Operations

    func testAddSingleItemToBoard() async throws {
        let item = createTestMediaItem()
        let board = CollectionBoard(name: "Test Board")

        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
            try board.insert(db)
        }

        // Simulate drag-to-board: add item to board
        try await testPool.write { db in
            let position = try BoardMembership.nextPosition(db: db, boardId: board.id)
            let membership = BoardMembership(boardId: board.id, itemId: item.id, position: position)
            try membership.insert(db)
        }

        // Verify item is in board
        let membership = try await testPool.read { db in
            try BoardMembership
                .filter(Column("boardId") == board.id.uuidString && Column("itemId") == item.id.uuidString)
                .fetchOne(db)
        }
        XCTAssertNotNil(membership)
        XCTAssertEqual(membership?.position, 0)
    }

    func testAddMultipleItemsToBoard() async throws {
        let items = (0..<5).map { _ in createTestMediaItem() }
        let board = CollectionBoard(name: "Multi-Item Board")

        try await testPool.write { db in
            for item in items {
                try MediaItemRecord(from: item).insert(db)
            }
            try board.insert(db)
        }

        // Simulate batch drag-to-board
        try await testPool.write { db in
            var nextPosition = try BoardMembership.nextPosition(db: db, boardId: board.id)
            for item in items {
                let membership = BoardMembership(boardId: board.id, itemId: item.id, position: nextPosition)
                try membership.insert(db)
                nextPosition += 1
            }
        }

        // Verify all items are in board with correct positions
        let memberships = try await testPool.read { db in
            try BoardMembership
                .filter(Column("boardId") == board.id.uuidString)
                .order(Column("position").asc)
                .fetchAll(db)
        }

        XCTAssertEqual(memberships.count, 5)
        for (index, membership) in memberships.enumerated() {
            XCTAssertEqual(membership.position, index)
            XCTAssertEqual(membership.itemId, items[index].id)
        }
    }

    func testAddItemToExistingBoard() async throws {
        let existingItems = (0..<3).map { _ in createTestMediaItem() }
        let newItem = createTestMediaItem()
        let board = CollectionBoard(name: "Existing Board")

        try await testPool.write { db in
            for item in existingItems {
                try MediaItemRecord(from: item).insert(db)
            }
            try MediaItemRecord(from: newItem).insert(db)
            try board.insert(db)

            // Add existing items
            for (index, item) in existingItems.enumerated() {
                let membership = BoardMembership(boardId: board.id, itemId: item.id, position: index)
                try membership.insert(db)
            }
        }

        // Drag new item to board
        try await testPool.write { db in
            let position = try BoardMembership.nextPosition(db: db, boardId: board.id)
            XCTAssertEqual(position, 3) // Should be 3 (0, 1, 2 taken)

            let membership = BoardMembership(boardId: board.id, itemId: newItem.id, position: position)
            try membership.insert(db)
        }

        // Verify new item added at end
        let newMembership = try await testPool.read { db in
            try BoardMembership
                .filter(Column("boardId") == board.id.uuidString && Column("itemId") == newItem.id.uuidString)
                .fetchOne(db)
        }
        XCTAssertNotNil(newMembership)
        XCTAssertEqual(newMembership?.position, 3)

        // Verify total count
        let totalCount = try await testPool.read { db in
            try BoardMembership
                .filter(Column("boardId") == board.id.uuidString)
                .fetchCount(db)
        }
        XCTAssertEqual(totalCount, 4)
    }

    func testAddDuplicateItemToBoard() async throws {
        let item = createTestMediaItem()
        let board = CollectionBoard(name: "Duplicate Test Board")

        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
            try board.insert(db)

            // Add item first time
            let membership = BoardMembership(boardId: board.id, itemId: item.id, position: 0)
            try membership.insert(db)
        }

        // Try to add same item again (should be skipped)
        try await testPool.write { db in
            let exists = try BoardMembership
                .filter(Column("boardId") == board.id.uuidString && Column("itemId") == item.id.uuidString)
                .fetchCount(db) > 0

            if !exists {
                let position = try BoardMembership.nextPosition(db: db, boardId: board.id)
                let membership = BoardMembership(boardId: board.id, itemId: item.id, position: position)
                try membership.insert(db)
            }
        }

        // Verify only one membership exists
        let count = try await testPool.read { db in
            try BoardMembership
                .filter(Column("boardId") == board.id.uuidString && Column("itemId") == item.id.uuidString)
                .fetchCount(db)
        }
        XCTAssertEqual(count, 1)
    }

    func testPositionOrderingWhenAddingToBoard() async throws {
        let board = CollectionBoard(name: "Ordering Test Board")
        let items = (0..<10).map { _ in createTestMediaItem() }

        try await testPool.write { db in
            try board.insert(db)
            for item in items {
                try MediaItemRecord(from: item).insert(db)
            }
        }

        // Add items in batches to test position continuity
        // First batch: items 0-4
        try await testPool.write { db in
            var nextPosition = try BoardMembership.nextPosition(db: db, boardId: board.id)
            for i in 0..<5 {
                let membership = BoardMembership(boardId: board.id, itemId: items[i].id, position: nextPosition)
                try membership.insert(db)
                nextPosition += 1
            }
        }

        // Second batch: items 5-9
        try await testPool.write { db in
            var nextPosition = try BoardMembership.nextPosition(db: db, boardId: board.id)
            XCTAssertEqual(nextPosition, 5) // Should continue from 5

            for i in 5..<10 {
                let membership = BoardMembership(boardId: board.id, itemId: items[i].id, position: nextPosition)
                try membership.insert(db)
                nextPosition += 1
            }
        }

        // Verify positions are sequential 0-9
        let memberships = try await testPool.read { db in
            try BoardMembership
                .filter(Column("boardId") == board.id.uuidString)
                .order(Column("position").asc)
                .fetchAll(db)
        }

        XCTAssertEqual(memberships.count, 10)
        for i in 0..<10 {
            XCTAssertEqual(memberships[i].position, i)
            XCTAssertEqual(memberships[i].itemId, items[i].id)
        }
    }

    func testBatchAddWithSomeExisting() async throws {
        let board = CollectionBoard(name: "Mixed Add Board")
        let item1 = createTestMediaItem()
        let item2 = createTestMediaItem()
        let item3 = createTestMediaItem()

        try await testPool.write { db in
            try board.insert(db)
            try MediaItemRecord(from: item1).insert(db)
            try MediaItemRecord(from: item2).insert(db)
            try MediaItemRecord(from: item3).insert(db)

            // item1 already in board
            let membership = BoardMembership(boardId: board.id, itemId: item1.id, position: 0)
            try membership.insert(db)
        }

        // Batch add all 3 items (item1 already exists)
        let itemIds = [item1.id, item2.id, item3.id]
        try await testPool.write { db in
            var nextPosition = try BoardMembership.nextPosition(db: db, boardId: board.id)

            for itemId in itemIds {
                let exists = try BoardMembership
                    .filter(Column("boardId") == board.id.uuidString && Column("itemId") == itemId.uuidString)
                    .fetchCount(db) > 0

                if !exists {
                    let membership = BoardMembership(boardId: board.id, itemId: itemId, position: nextPosition)
                    try membership.insert(db)
                    nextPosition += 1
                }
            }
        }

        // Verify: item1 at 0, item2 at 1, item3 at 2
        let memberships = try await testPool.read { db in
            try BoardMembership
                .filter(Column("boardId") == board.id.uuidString)
                .order(Column("position").asc)
                .fetchAll(db)
        }

        XCTAssertEqual(memberships.count, 3)
        XCTAssertEqual(memberships[0].itemId, item1.id)
        XCTAssertEqual(memberships[0].position, 0)
        XCTAssertEqual(memberships[1].itemId, item2.id)
        XCTAssertEqual(memberships[1].position, 1)
        XCTAssertEqual(memberships[2].itemId, item3.id)
        XCTAssertEqual(memberships[2].position, 2)
    }

    // MARK: - Helpers

    private func createTestMediaItem(platform: String = "twitter") -> MediaItem {
        let id = UUID()
        let basePath = URL(fileURLWithPath: "/test/archive/2025-01")
        let metadataFile = basePath.appendingPathComponent("\(id.uuidString).md")

        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: metadataFile,
            mediaFiles: [basePath.appendingPathComponent("\(id.uuidString).jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://\(platform).com/test/\(id.uuidString)")!,
                platform: platform,
                author: "@testuser",
                originalDate: Date(),
                archivedDate: Date()
            )
        )
    }
}

// MARK: - Drag-to-Folder Integration Tests

/// Integration tests for folder operations via drag-drop.
final class DragToFolderIntegrationTests: XCTestCase {

    private var testPool: DatabasePool!
    private var tempDir: URL!
    private var archiveDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DragToFolderTests-\(UUID().uuidString)")
        archiveDir = tempDir.appendingPathComponent("archive")

        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: archiveDir.appendingPathComponent("2025-01"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: archiveDir.appendingPathComponent("2025-02"),
            withIntermediateDirectories: true
        )

        let dbPath = tempDir.appendingPathComponent("test.sqlite")
        testPool = try DatabasePool(path: dbPath.path)

        try testPool.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try MediaItemRecord.createTable(in: db)
        }
    }

    override func tearDownWithError() throws {
        testPool = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Folder Move Operations

    func testMoveItemToFolder_DatabaseUpdate() async throws {
        // Create item in 2025-01 folder
        let itemSubdir = archiveDir.appendingPathComponent("2025-01/item-folder")
        try FileManager.default.createDirectory(at: itemSubdir, withIntermediateDirectories: true)

        let item = createTestMediaItem(basePath: itemSubdir)
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        // Verify original basePath
        let originalBasePath = try await testPool.read { db -> String? in
            try String.fetchOne(
                db,
                sql: "SELECT basePathString FROM media_items WHERE id = ?",
                arguments: [item.id.uuidString]
            )
        }
        XCTAssertTrue(originalBasePath?.contains("2025-01") ?? false)

        // Simulate drag-to-folder: move to 2025-02
        let newBasePath = archiveDir.appendingPathComponent("2025-02/item-folder")
        try await testPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET basePathString = ? WHERE id = ?",
                arguments: [newBasePath.path, item.id.uuidString]
            )
        }

        // Verify database updated
        let updatedBasePath = try await testPool.read { db -> String? in
            try String.fetchOne(
                db,
                sql: "SELECT basePathString FROM media_items WHERE id = ?",
                arguments: [item.id.uuidString]
            )
        }
        XCTAssertTrue(updatedBasePath?.contains("2025-02") ?? false)
        XCTAssertFalse(updatedBasePath?.contains("2025-01") ?? true)
    }

    func testMoveMultipleItemsToFolder() async throws {
        // Create items in 2025-01
        var items: [MediaItem] = []
        for i in 0..<3 {
            let itemSubdir = archiveDir.appendingPathComponent("2025-01/item-\(i)")
            try FileManager.default.createDirectory(at: itemSubdir, withIntermediateDirectories: true)
            let item = createTestMediaItem(basePath: itemSubdir)
            items.append(item)
        }

        let itemsToInsertForMove = items
        try await testPool.write { db in
            for item in itemsToInsertForMove {
                try MediaItemRecord(from: item).insert(db)
            }
        }

        // Batch move to 2025-02
        let targetFolder = "2025-02"
        let archiveURL = self.archiveDir!
        let itemsToMove = items
        try await testPool.write { db in
            for item in itemsToMove {
                let oldBasePath = URL(fileURLWithPath: item.basePath.path)
                let itemSubdirName = oldBasePath.lastPathComponent
                let newBasePath = archiveURL.appendingPathComponent(targetFolder).appendingPathComponent(itemSubdirName)

                try db.execute(
                    sql: "UPDATE media_items SET basePathString = ? WHERE id = ?",
                    arguments: [newBasePath.path, item.id.uuidString]
                )
            }
        }

        // Verify all items moved
        let itemsIn2025_02 = try await testPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_items WHERE basePathString LIKE ?",
                arguments: ["%/2025-02/%"]
            )
        }
        XCTAssertEqual(itemsIn2025_02, 3)

        let itemsIn2025_01 = try await testPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_items WHERE basePathString LIKE ?",
                arguments: ["%/2025-01/%"]
            )
        }
        XCTAssertEqual(itemsIn2025_01, 0)
    }

    func testMediaFilesPathsUpdateWithMove() async throws {
        // Create item with multiple media files
        let itemSubdir = archiveDir.appendingPathComponent("2025-01/multi-media-item")
        try FileManager.default.createDirectory(at: itemSubdir, withIntermediateDirectories: true)

        let id = UUID()
        let metadataFile = itemSubdir.appendingPathComponent("\(id.uuidString).md")
        let mediaFiles = [
            itemSubdir.appendingPathComponent("image1.jpg"),
            itemSubdir.appendingPathComponent("image2.jpg"),
            itemSubdir.appendingPathComponent("video.mp4")
        ]

        // Create placeholder files
        for file in mediaFiles {
            try "placeholder".write(to: file, atomically: true, encoding: .utf8)
        }

        let item = MediaItem(
            id: id,
            basePath: itemSubdir,
            metadataFile: metadataFile,
            mediaFiles: mediaFiles,
            metadata: MediaMetadata(
                source: URL(string: "https://twitter.com/test/\(id.uuidString)")!,
                platform: "twitter",
                archivedDate: Date()
            )
        )

        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        // Verify original paths
        let originalMediaFilesJSON = try await testPool.read { db -> String? in
            try String.fetchOne(
                db,
                sql: "SELECT mediaFilesJSON FROM media_items WHERE id = ?",
                arguments: [item.id.uuidString]
            )
        }
        XCTAssertTrue(originalMediaFilesJSON?.contains("2025-01") ?? false)

        // Simulate path update after move (MediaStore.moveItemsToFolder would do this)
        let newItemSubdir = archiveDir.appendingPathComponent("2025-02/multi-media-item")
        let newMediaFiles = mediaFiles.map { oldURL in
            newItemSubdir.appendingPathComponent(oldURL.lastPathComponent)
        }
        let newMediaFilesJSON = (try? JSONEncoder().encode(newMediaFiles.map(\.path)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        try await testPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET basePathString = ?, mediaFilesJSON = ? WHERE id = ?",
                arguments: [newItemSubdir.path, newMediaFilesJSON, item.id.uuidString]
            )
        }

        // Verify paths updated
        let updatedMediaFilesJSON = try await testPool.read { db -> String? in
            try String.fetchOne(
                db,
                sql: "SELECT mediaFilesJSON FROM media_items WHERE id = ?",
                arguments: [item.id.uuidString]
            )
        }
        XCTAssertTrue(updatedMediaFilesJSON?.contains("2025-02") ?? false)
        XCTAssertFalse(updatedMediaFilesJSON?.contains("2025-01") ?? true)
    }

    func testFolderFilterAfterMove() async throws {
        // Create items - 2 in 2025-01, 1 in 2025-02
        let item1Subdir = archiveDir.appendingPathComponent("2025-01/item1")
        let item2Subdir = archiveDir.appendingPathComponent("2025-01/item2")
        let item3Subdir = archiveDir.appendingPathComponent("2025-02/item3")

        try FileManager.default.createDirectory(at: item1Subdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: item2Subdir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: item3Subdir, withIntermediateDirectories: true)

        let item1 = createTestMediaItem(basePath: item1Subdir)
        let item2 = createTestMediaItem(basePath: item2Subdir)
        let item3 = createTestMediaItem(basePath: item3Subdir)

        try await testPool.write { db in
            try MediaItemRecord(from: item1).insert(db)
            try MediaItemRecord(from: item2).insert(db)
            try MediaItemRecord(from: item3).insert(db)
        }

        // Initial counts
        var count2025_01 = try await testPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_items WHERE basePathString LIKE ?",
                arguments: ["%/2025-01/%"]
            )
        }
        XCTAssertEqual(count2025_01, 2)

        // Move item1 to 2025-02
        let newItem1Subdir = archiveDir.appendingPathComponent("2025-02/item1")
        try await testPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET basePathString = ? WHERE id = ?",
                arguments: [newItem1Subdir.path, item1.id.uuidString]
            )
        }

        // Verify filter counts changed
        count2025_01 = try await testPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_items WHERE basePathString LIKE ?",
                arguments: ["%/2025-01/%"]
            )
        }
        XCTAssertEqual(count2025_01, 1)

        let count2025_02 = try await testPool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_items WHERE basePathString LIKE ?",
                arguments: ["%/2025-02/%"]
            )
        }
        XCTAssertEqual(count2025_02, 2)
    }

    // MARK: - Helpers

    private func createTestMediaItem(basePath: URL, platform: String = "twitter") -> MediaItem {
        let id = UUID()
        let metadataFile = basePath.appendingPathComponent("\(id.uuidString).md")

        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: metadataFile,
            mediaFiles: [basePath.appendingPathComponent("\(id.uuidString).jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://\(platform).com/test/\(id.uuidString)")!,
                platform: platform,
                author: "@testuser",
                originalDate: Date(),
                archivedDate: Date()
            )
        )
    }
}
