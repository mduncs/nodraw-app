import XCTest
import GRDB
@testable import MediaViewer

/// Integration tests for undo/redo flow:
/// Action execution -> UndoStack -> Undo -> Verify state reverted -> Redo -> Verify state restored
final class UndoFlowTests: XCTestCase {

    var testDatabase: TestDatabase!
    var dbPool: DatabasePool!
    var undoStack: UndoStack!

    // Sample items for testing
    var testItems: [MediaItem] = []

    override func setUp() async throws {
        try await super.setUp()
        testDatabase = TestDatabase()
        dbPool = try await testDatabase.initialize()
        undoStack = await UndoStack()

        // Insert sample items
        testItems = await insertSampleItems()
    }

    override func tearDown() async throws {
        await undoStack.clear()
        await testDatabase.tearDown()
        testDatabase = nil
        dbPool = nil
        undoStack = nil
        testItems = []
        try await super.tearDown()
    }

    private func insertSampleItems() async -> [MediaItem] {
        let items = [
            SampleData.createMediaItem(
                id: UUID(),
                platform: "twitter",
                author: "@alice",
                starred: false,
                tags: ["art"]
            ),
            SampleData.createMediaItem(
                id: UUID(),
                platform: "instagram",
                author: "@bob",
                starred: false,
                tags: []
            ),
            SampleData.createMediaItem(
                id: UUID(),
                platform: "reddit",
                author: "u/charlie",
                starred: true,
                tags: ["meme", "funny"]
            ),
        ]

        for item in items {
            let record = MediaItemRecord(from: item)
            do {
                try await dbPool.write { db in
                    try record.insert(db)
                }
            } catch {
                XCTFail("Failed to insert sample item: \(error)")
            }
        }

        return items
    }

    // MARK: - Helper Functions

    private func getStarred(id: UUID) async throws -> Bool {
        try await dbPool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT starred FROM media_items WHERE id = ?",
                arguments: [id.uuidString]
            )
            return row?["starred"] ?? false
        }
    }

    private func setStarred(id: UUID, starred: Bool) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET starred = ? WHERE id = ?",
                arguments: [starred, id.uuidString]
            )
        }
    }

    private func toggleStar(id: UUID) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET starred = NOT starred WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    private func getTags(id: UUID) async throws -> [String] {
        try await dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return [] }

            let json: String = row["tagsJSON"]
            return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        }
    }

    private func addTag(id: UUID, tag: String) async throws {
        try await dbPool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return }

            let json: String = row["tagsJSON"]
            var tags = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []

            if !tags.contains(tag) {
                tags.append(tag)
                let newJSON = (try? JSONEncoder().encode(tags))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                try db.execute(
                    sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                    arguments: [newJSON, id.uuidString]
                )
            }
        }
    }

    private func removeTag(id: UUID, tag: String) async throws {
        try await dbPool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return }

            let json: String = row["tagsJSON"]
            var tags = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []

            if let index = tags.firstIndex(of: tag) {
                tags.remove(at: index)
                let newJSON = (try? JSONEncoder().encode(tags))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                try db.execute(
                    sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                    arguments: [newJSON, id.uuidString]
                )
            }
        }
    }

    private func getNotes(id: UUID) async throws -> String? {
        try await dbPool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT notes FROM media_items WHERE id = ?",
                arguments: [id.uuidString]
            )
            return row?["notes"]
        }
    }

    private func setNotes(id: UUID, notes: String?) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET notes = ? WHERE id = ?",
                arguments: [notes, id.uuidString]
            )
        }
    }

    // MARK: - Test-specific UndoableAction implementations

    /// Simple toggle star action for testing
    struct TestToggleStarAction: UndoableAction {
        let itemId: UUID
        let pool: DatabasePool

        var description: String { "Toggled star" }

        func execute() async throws {
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE media_items SET starred = NOT starred WHERE id = ?",
                    arguments: [itemId.uuidString]
                )
            }
        }

        func undo() async throws {
            // Toggle again to revert
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE media_items SET starred = NOT starred WHERE id = ?",
                    arguments: [itemId.uuidString]
                )
            }
        }
    }

    /// Set star to specific value action
    struct TestSetStarAction: UndoableAction {
        let itemId: UUID
        let setTo: Bool
        let pool: DatabasePool

        var description: String { setTo ? "Starred item" : "Unstarred item" }

        func execute() async throws {
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE media_items SET starred = ? WHERE id = ?",
                    arguments: [setTo, itemId.uuidString]
                )
            }
        }

        func undo() async throws {
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE media_items SET starred = ? WHERE id = ?",
                    arguments: [!setTo, itemId.uuidString]
                )
            }
        }
    }

    /// Batch star action for testing
    struct TestBatchStarAction: UndoableAction {
        let itemIds: [UUID]
        let setTo: Bool
        let pool: DatabasePool

        var description: String {
            "\(setTo ? "Starred" : "Unstarred") \(itemIds.count) items"
        }

        func execute() async throws {
            try await pool.write { db in
                for id in itemIds {
                    try db.execute(
                        sql: "UPDATE media_items SET starred = ? WHERE id = ?",
                        arguments: [setTo, id.uuidString]
                    )
                }
            }
        }

        func undo() async throws {
            try await pool.write { db in
                for id in itemIds {
                    try db.execute(
                        sql: "UPDATE media_items SET starred = ? WHERE id = ?",
                        arguments: [!setTo, id.uuidString]
                    )
                }
            }
        }
    }

    /// Add tag action for testing
    struct TestAddTagAction: UndoableAction {
        let itemId: UUID
        let tag: String
        let pool: DatabasePool

        var description: String { "Added tag '\(tag)'" }

        func execute() async throws {
            try await pool.write { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                    arguments: [itemId.uuidString]
                ) else { return }

                let json: String = row["tagsJSON"]
                var tags = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []

                if !tags.contains(tag) {
                    tags.append(tag)
                    let newJSON = (try? JSONEncoder().encode(tags))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                    try db.execute(
                        sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                        arguments: [newJSON, itemId.uuidString]
                    )
                }
            }
        }

        func undo() async throws {
            try await pool.write { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                    arguments: [itemId.uuidString]
                ) else { return }

                let json: String = row["tagsJSON"]
                var tags = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []

                if let index = tags.firstIndex(of: tag) {
                    tags.remove(at: index)
                    let newJSON = (try? JSONEncoder().encode(tags))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                    try db.execute(
                        sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                        arguments: [newJSON, itemId.uuidString]
                    )
                }
            }
        }
    }

    /// Update notes action for testing
    struct TestUpdateNotesAction: UndoableAction {
        let itemId: UUID
        let oldNotes: String?
        let newNotes: String?
        let pool: DatabasePool

        var description: String { "Updated notes" }

        func execute() async throws {
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE media_items SET notes = ? WHERE id = ?",
                    arguments: [newNotes, itemId.uuidString]
                )
            }
        }

        func undo() async throws {
            try await pool.write { db in
                try db.execute(
                    sql: "UPDATE media_items SET notes = ? WHERE id = ?",
                    arguments: [oldNotes, itemId.uuidString]
                )
            }
        }
    }

    // MARK: - Toggle Star Tests

    func testToggleStarUndoRedo() async throws {
        let item = testItems[0]  // @alice, not starred

        // Verify initial state
        let wasStarred = try await getStarred(id: item.id)
        XCTAssertFalse(wasStarred)

        // Create and perform action
        let action = TestToggleStarAction(itemId: item.id, pool: dbPool)
        try await undoStack.performAction(action)

        // Verify starred state changed
        let nowStarred = try await getStarred(id: item.id)
        XCTAssertTrue(nowStarred, "Item should be starred after action")

        // Verify undo is available
        let canUndo = await undoStack.canUndo
        XCTAssertTrue(canUndo)

        // Undo
        try await undoStack.undo()

        // Verify starred state reverted
        let afterUndo = try await getStarred(id: item.id)
        XCTAssertFalse(afterUndo, "Item should be unstarred after undo")

        // Verify redo is available
        let canRedo = await undoStack.canRedo
        XCTAssertTrue(canRedo)

        // Redo
        try await undoStack.redo()

        // Verify starred state restored
        let afterRedo = try await getStarred(id: item.id)
        XCTAssertTrue(afterRedo, "Item should be starred after redo")
    }

    func testSetStarUndoRedo() async throws {
        let item = testItems[0]  // @alice, not starred

        // Create and perform action to star the item
        let action = TestSetStarAction(itemId: item.id, setTo: true, pool: dbPool)
        try await undoStack.performAction(action)

        var starred = try await getStarred(id: item.id)
        XCTAssertTrue(starred)

        // Undo
        try await undoStack.undo()
        starred = try await getStarred(id: item.id)
        XCTAssertFalse(starred)

        // Redo
        try await undoStack.redo()
        starred = try await getStarred(id: item.id)
        XCTAssertTrue(starred)
    }

    func testMultipleActionsUndoSequence() async throws {
        let item = testItems[0]
        var starred: Bool

        // Action 1: star the item
        let action1 = TestSetStarAction(itemId: item.id, setTo: true, pool: dbPool)
        try await undoStack.performAction(action1)
        starred = try await getStarred(id: item.id)
        XCTAssertTrue(starred)

        // Action 2: unstar the item
        let action2 = TestSetStarAction(itemId: item.id, setTo: false, pool: dbPool)
        try await undoStack.performAction(action2)
        starred = try await getStarred(id: item.id)
        XCTAssertFalse(starred)

        // Undo action 2 - should be starred again
        try await undoStack.undo()
        starred = try await getStarred(id: item.id)
        XCTAssertTrue(starred)

        // Undo action 1 - should be unstarred
        try await undoStack.undo()
        starred = try await getStarred(id: item.id)
        XCTAssertFalse(starred)

        // Redo action 1
        try await undoStack.redo()
        starred = try await getStarred(id: item.id)
        XCTAssertTrue(starred)

        // Redo action 2
        try await undoStack.redo()
        starred = try await getStarred(id: item.id)
        XCTAssertFalse(starred)
    }

    // MARK: - Batch Star Tests

    func testBatchStarUndoRedo() async throws {
        let itemIds = testItems.map { $0.id }

        // Batch star all items
        let action = TestBatchStarAction(itemIds: itemIds, setTo: true, pool: dbPool)
        try await undoStack.performAction(action)

        // Verify all are now starred
        for id in itemIds {
            let starred = try await getStarred(id: id)
            XCTAssertTrue(starred, "Item \(id) should be starred")
        }

        // Undo
        try await undoStack.undo()

        // Verify all are now unstarred
        for id in itemIds {
            let starred = try await getStarred(id: id)
            XCTAssertFalse(starred, "Item \(id) should be unstarred after undo")
        }

        // Redo
        try await undoStack.redo()

        // Verify all are starred again
        for id in itemIds {
            let starred = try await getStarred(id: id)
            XCTAssertTrue(starred, "Item \(id) should be starred after redo")
        }
    }

    // MARK: - Tag Tests

    func testAddTagUndoRedo() async throws {
        let item = testItems[1]  // @bob, no tags

        // Verify no tags initially (empty array)
        var tags = try await getTags(id: item.id)
        XCTAssertTrue(tags.isEmpty)

        // Add tag
        let action = TestAddTagAction(itemId: item.id, tag: "nature", pool: dbPool)
        try await undoStack.performAction(action)

        // Verify tag added
        tags = try await getTags(id: item.id)
        XCTAssertTrue(tags.contains("nature"))

        // Undo
        try await undoStack.undo()

        // Verify tag removed
        tags = try await getTags(id: item.id)
        XCTAssertFalse(tags.contains("nature"))

        // Redo
        try await undoStack.redo()

        // Verify tag restored
        tags = try await getTags(id: item.id)
        XCTAssertTrue(tags.contains("nature"))
    }

    // MARK: - Notes Tests

    func testUpdateNotesUndoRedo() async throws {
        let item = testItems[0]  // @alice, no notes

        // Verify no notes initially
        var notes = try await getNotes(id: item.id)
        XCTAssertNil(notes)

        // Add notes
        let action = TestUpdateNotesAction(
            itemId: item.id,
            oldNotes: nil,
            newNotes: "This is a great image",
            pool: dbPool
        )
        try await undoStack.performAction(action)

        // Verify notes added
        notes = try await getNotes(id: item.id)
        XCTAssertEqual(notes, "This is a great image")

        // Undo
        try await undoStack.undo()

        // Verify notes removed
        notes = try await getNotes(id: item.id)
        XCTAssertNil(notes)

        // Redo
        try await undoStack.redo()

        // Verify notes restored
        notes = try await getNotes(id: item.id)
        XCTAssertEqual(notes, "This is a great image")
    }

    // MARK: - UndoStack Behavior Tests

    func testUndoStackClearsRedoOnNewAction() async throws {
        let item = testItems[0]

        // Perform action
        let action1 = TestToggleStarAction(itemId: item.id, pool: dbPool)
        try await undoStack.performAction(action1)

        // Undo
        try await undoStack.undo()

        // Verify redo is available
        var canRedo = await undoStack.canRedo
        XCTAssertTrue(canRedo)

        // Perform NEW action (should clear redo stack)
        let action2 = TestAddTagAction(itemId: item.id, tag: "test", pool: dbPool)
        try await undoStack.performAction(action2)

        // Verify redo is no longer available
        canRedo = await undoStack.canRedo
        XCTAssertFalse(canRedo, "Redo should be cleared after new action")
    }

    func testUndoStackMaxDepth() async throws {
        let item = testItems[0]

        // Perform 25 actions (more than maxDepth of 20)
        for i in 0..<25 {
            let action = TestAddTagAction(itemId: item.id, tag: "tag\(i)", pool: dbPool)
            try await undoStack.performAction(action)
        }

        // Undo 20 times (max depth)
        var undoCount = 0
        while await undoStack.canUndo {
            try await undoStack.undo()
            undoCount += 1
            if undoCount > 25 { break }  // Safety limit
        }

        // Should only be able to undo 20 times
        XCTAssertEqual(undoCount, 20)
    }

    func testEmptyUndoReturnsNil() async throws {
        // Verify can't undo with empty stack
        let canUndo = await undoStack.canUndo
        XCTAssertFalse(canUndo)

        // Undo should return nil
        let action = try await undoStack.undo()
        XCTAssertNil(action)
    }

    func testEmptyRedoReturnsNil() async throws {
        // Verify can't redo with empty stack
        let canRedo = await undoStack.canRedo
        XCTAssertFalse(canRedo)

        // Redo should return nil
        let action = try await undoStack.redo()
        XCTAssertNil(action)
    }

    // MARK: - Toast Tests

    func testToastShownAfterAction() async throws {
        let item = testItems[0]

        let action = TestSetStarAction(itemId: item.id, setTo: true, pool: dbPool)
        try await undoStack.performAction(action)

        // Check toast is shown
        let toast = await undoStack.currentToast
        XCTAssertNotNil(toast)
        XCTAssertEqual(toast?.message, "Starred item")
        XCTAssertTrue(toast?.showUndo ?? false)
    }

    func testToastShownAfterUndo() async throws {
        let item = testItems[0]

        let action = TestSetStarAction(itemId: item.id, setTo: true, pool: dbPool)
        try await undoStack.performAction(action)
        try await undoStack.undo()

        let toast = await undoStack.currentToast
        XCTAssertNotNil(toast)
        XCTAssertTrue(toast?.message.contains("Undid") ?? false)
        XCTAssertFalse(toast?.showUndo ?? true)  // No undo button after undo
    }

    func testToastDismiss() async throws {
        let item = testItems[0]

        let action = TestSetStarAction(itemId: item.id, setTo: true, pool: dbPool)
        try await undoStack.performAction(action)

        // Toast should be visible
        var toast = await undoStack.currentToast
        XCTAssertNotNil(toast)

        // Dismiss
        await undoStack.dismissToast()

        // Toast should be nil
        toast = await undoStack.currentToast
        XCTAssertNil(toast)
    }

    // MARK: - Clear Tests

    func testClearUndoStack() async throws {
        let item = testItems[0]

        // Perform some actions
        let action = TestToggleStarAction(itemId: item.id, pool: dbPool)
        try await undoStack.performAction(action)
        try await undoStack.undo()

        // Verify stacks have content
        var canUndo = await undoStack.canUndo
        var canRedo = await undoStack.canRedo
        XCTAssertFalse(canUndo)  // Just undid
        XCTAssertTrue(canRedo)

        // Clear
        await undoStack.clear()

        // Verify both stacks empty
        canUndo = await undoStack.canUndo
        canRedo = await undoStack.canRedo
        XCTAssertFalse(canUndo)
        XCTAssertFalse(canRedo)

        // Toast should also be cleared
        let toast = await undoStack.currentToast
        XCTAssertNil(toast)
    }

    // MARK: - Complex Undo Scenarios

    func testInterleavedActionsOnDifferentItems() async throws {
        let item1 = testItems[0]  // alice
        let item2 = testItems[1]  // bob

        // Star item1
        try await undoStack.performAction(TestSetStarAction(itemId: item1.id, setTo: true, pool: dbPool))

        // Star item2
        try await undoStack.performAction(TestSetStarAction(itemId: item2.id, setTo: true, pool: dbPool))

        // Add tag to item1
        try await undoStack.performAction(TestAddTagAction(itemId: item1.id, tag: "featured", pool: dbPool))

        // Verify current states
        var starred1 = try await getStarred(id: item1.id)
        var starred2 = try await getStarred(id: item2.id)
        var tags = try await getTags(id: item1.id)
        XCTAssertTrue(starred1)
        XCTAssertTrue(starred2)
        XCTAssertTrue(tags.contains("featured"))

        // Undo add tag
        try await undoStack.undo()
        tags = try await getTags(id: item1.id)
        starred1 = try await getStarred(id: item1.id)
        starred2 = try await getStarred(id: item2.id)
        XCTAssertFalse(tags.contains("featured"))
        XCTAssertTrue(starred1, "Item1 should still be starred")
        XCTAssertTrue(starred2, "Item2 should still be starred")

        // Undo star item2
        try await undoStack.undo()
        starred1 = try await getStarred(id: item1.id)
        starred2 = try await getStarred(id: item2.id)
        XCTAssertFalse(starred2, "Item2 should now be unstarred")
        XCTAssertTrue(starred1, "Item1 should still be starred")

        // Undo star item1
        try await undoStack.undo()
        starred1 = try await getStarred(id: item1.id)
        XCTAssertFalse(starred1, "Item1 should now be unstarred")
    }
}
