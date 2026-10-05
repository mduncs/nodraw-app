import XCTest
@testable import MediaViewer

// MARK: - BatchOperationsTests

/// Tests for batch operations using the mock action implementations from UndoableActionsTests.
/// These tests verify that batch operations:
/// - Update multiple items correctly
/// - Are properly undoable
/// - Work correctly with the UndoStack
final class BatchOperationsTests: XCTestCase {

    var mockState: MockMediaStoreState!

    override func setUp() async throws {
        mockState = MockMediaStoreState()
    }

    override func tearDown() async throws {
        await mockState.reset()
        mockState = nil
    }

    // MARK: - Star Operations

    func testStarAllUpdatesMultipleItems() async throws {
        let ids = [UUID(), UUID(), UUID()]
        for id in ids {
            await mockState.setItem(id, .init(starred: false))
        }

        let action = TestBatchStarAction(itemIds: ids, setStarred: true, mockState: mockState)
        try await action.execute()

        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.starred, "Item should be starred")
        }
    }

    func testUnstarAllUpdatesMultipleItems() async throws {
        let ids = [UUID(), UUID(), UUID()]
        for id in ids {
            await mockState.setItem(id, .init(starred: true))
        }

        let action = TestBatchStarAction(itemIds: ids, setStarred: false, mockState: mockState)
        try await action.execute()

        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.starred, "Item should be unstarred")
        }
    }

    func testStarAllIsUndoable() async throws {
        let ids = [UUID(), UUID()]
        for id in ids {
            await mockState.setItem(id, .init(starred: false))
        }

        let action = TestBatchStarAction(itemIds: ids, setStarred: true, mockState: mockState)
        try await action.execute()

        // Verify starred
        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.starred)
        }

        // Undo
        try await action.undo()

        // Verify unstarred
        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.starred, "Undo should revert star state")
        }
    }

    // MARK: - Tag Operations

    func testAddTagToMultipleItems() async throws {
        let ids = [UUID(), UUID(), UUID()]
        for id in ids {
            await mockState.setItem(id, .init(tags: []))
        }

        let action = TestBatchTagAction(itemIds: ids, tag: "batch", wasAdded: true, mockState: mockState)
        try await action.execute()

        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.tags.contains("batch"))
        }
    }

    func testRemoveTagFromMultipleItems() async throws {
        let ids = [UUID(), UUID()]
        for id in ids {
            await mockState.setItem(id, .init(tags: ["common-tag", "other"]))
        }

        let action = TestBatchTagAction(itemIds: ids, tag: "common-tag", wasAdded: false, mockState: mockState)
        try await action.execute()

        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.tags.contains("common-tag"))
            XCTAssertTrue(item.tags.contains("other"), "Other tags should remain")
        }
    }

    func testAddTagIsUndoable() async throws {
        let ids = [UUID(), UUID()]
        for id in ids {
            await mockState.setItem(id, .init(tags: ["existing"]))
        }

        let action = TestBatchTagAction(itemIds: ids, tag: "new-tag", wasAdded: true, mockState: mockState)
        try await action.execute()
        try await action.undo()

        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.tags.contains("new-tag"), "Undo should remove added tag")
            XCTAssertTrue(item.tags.contains("existing"), "Existing tags should remain")
        }
    }

    func testRemoveTagIsUndoable() async throws {
        let ids = [UUID(), UUID()]
        for id in ids {
            await mockState.setItem(id, .init(tags: ["restore-me"]))
        }

        let action = TestBatchTagAction(itemIds: ids, tag: "restore-me", wasAdded: false, mockState: mockState)
        try await action.execute()
        try await action.undo()

        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.tags.contains("restore-me"), "Undo should restore removed tag")
        }
    }

    // MARK: - Delete Operations

    func testDeleteAllSoftDeletesItems() async throws {
        let ids = [UUID(), UUID(), UUID()]
        for id in ids {
            await mockState.setItem(id, .init(isDeleted: false))
        }

        let action = TestDeleteItemsAction(itemIds: ids, mockState: mockState)
        try await action.execute()

        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.isDeleted, "Item should be soft deleted")
        }
    }

    func testDeleteIsUndoable() async throws {
        let ids = [UUID(), UUID()]
        for id in ids {
            await mockState.setItem(id, .init(isDeleted: false))
        }

        let action = TestDeleteItemsAction(itemIds: ids, mockState: mockState)
        try await action.execute()

        // Verify deleted
        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.isDeleted)
        }

        // Undo
        try await action.undo()

        // Verify restored
        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.isDeleted, "Undo should restore deleted items")
        }
    }

    // MARK: - Empty Set Handling

    func testStarEmptySetNoOp() async throws {
        let action = TestBatchStarAction(itemIds: [], setStarred: true, mockState: mockState)

        // Should not throw
        try await action.execute()
        try await action.undo()

        XCTAssertEqual(action.itemIds.count, 0)
    }

    func testTagEmptySetNoOp() async throws {
        let action = TestBatchTagAction(itemIds: [], tag: "test", wasAdded: true, mockState: mockState)

        try await action.execute()
        try await action.undo()

        XCTAssertEqual(action.itemIds.count, 0)
    }

    func testDeleteEmptySetNoOp() async throws {
        let action = TestDeleteItemsAction(itemIds: [], mockState: mockState)

        try await action.execute()
        try await action.undo()

        XCTAssertEqual(action.itemIds.count, 0)
    }

    // MARK: - Integration with UndoStack

    @MainActor
    func testBatchActionsWorkWithUndoStack() async throws {
        let undoStack = UndoStack()
        let ids = [UUID(), UUID()]

        for id in ids {
            await mockState.setItem(id, .init(starred: false, tags: []))
        }

        // Perform star action through undo stack
        let starAction = TestBatchStarAction(itemIds: ids, setStarred: true, mockState: mockState)
        try await undoStack.performAction(starAction)

        XCTAssertTrue(undoStack.canUndo)

        // Verify starred
        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.starred)
        }

        // Undo through undo stack
        _ = try await undoStack.undo()

        // Verify unstarred
        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.starred)
        }

        XCTAssertTrue(undoStack.canRedo)
    }

    @MainActor
    func testMultipleBatchActionsInSequence() async throws {
        let undoStack = UndoStack()
        let ids = [UUID(), UUID()]

        for id in ids {
            await mockState.setItem(id, .init(starred: false, tags: []))
        }

        // Star all
        try await undoStack.performAction(TestBatchStarAction(itemIds: ids, setStarred: true, mockState: mockState))

        // Add tag
        try await undoStack.performAction(TestBatchTagAction(itemIds: ids, tag: "tagged", wasAdded: true, mockState: mockState))

        // Verify state
        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.starred)
            XCTAssertTrue(item.tags.contains("tagged"))
        }

        // Undo tag
        _ = try await undoStack.undo()

        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.starred, "Star should still be set")
            XCTAssertFalse(item.tags.contains("tagged"), "Tag should be removed")
        }

        // Undo star
        _ = try await undoStack.undo()

        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.starred, "Star should be removed")
        }
    }

    // MARK: - Large Batch Tests

    func testLargeBatchStar() async throws {
        let ids = (0..<100).map { _ in UUID() }
        for id in ids {
            await mockState.setItem(id, .init(starred: false))
        }

        let action = TestBatchStarAction(itemIds: ids, setStarred: true, mockState: mockState)
        try await action.execute()

        var starredCount = 0
        for id in ids {
            if await mockState.getItem(id).starred {
                starredCount += 1
            }
        }

        XCTAssertEqual(starredCount, 100, "All 100 items should be starred")
    }

    func testLargeBatchUndo() async throws {
        let ids = (0..<50).map { _ in UUID() }
        for id in ids {
            await mockState.setItem(id, .init(starred: false))
        }

        let action = TestBatchStarAction(itemIds: ids, setStarred: true, mockState: mockState)
        try await action.execute()
        try await action.undo()

        var unstarredCount = 0
        for id in ids {
            let item = await mockState.getItem(id)
            if !item.starred {
                unstarredCount += 1
            }
        }

        XCTAssertEqual(unstarredCount, 50, "All 50 items should be unstarred after undo")
    }

    // MARK: - Mixed State Tests

    func testBatchStarWithMixedInitialState() async throws {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        // Set up mixed state: some starred, some not
        await mockState.setItem(ids[0], .init(starred: true))
        await mockState.setItem(ids[1], .init(starred: false))
        await mockState.setItem(ids[2], .init(starred: true))
        await mockState.setItem(ids[3], .init(starred: false))

        // Star all - even already-starred items
        let action = TestBatchStarAction(itemIds: ids, setStarred: true, mockState: mockState)
        try await action.execute()

        // All should be starred
        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.starred)
        }

        // Undo - all should be unstarred (batch undo doesn't preserve original mixed state)
        try await action.undo()

        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.starred)
        }
    }

    func testBatchTagWithSomeAlreadyTagged() async throws {
        let ids = [UUID(), UUID(), UUID()]
        await mockState.setItem(ids[0], .init(tags: ["new-tag"]))  // Already has tag
        await mockState.setItem(ids[1], .init(tags: []))
        await mockState.setItem(ids[2], .init(tags: ["other"]))

        let action = TestBatchTagAction(itemIds: ids, tag: "new-tag", wasAdded: true, mockState: mockState)
        try await action.execute()

        // All should have the tag
        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.tags.contains("new-tag"))
        }

        // First item should not have duplicates
        let firstItem = await mockState.getItem(ids[0])
        let tagCount = firstItem.tags.filter { $0 == "new-tag" }.count
        XCTAssertEqual(tagCount, 1, "Should not duplicate tag")
    }
}

// MARK: - BatchResult Tests

final class BatchResultTests: XCTestCase {

    func testEmptyResult() {
        let result = BatchResult.empty

        XCTAssertEqual(result.successCount, 0)
        XCTAssertEqual(result.failureCount, 0)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.isFullSuccess)
    }

    func testFullSuccessResult() {
        let result = BatchResult(successCount: 10, failureCount: 0, errors: [])

        XCTAssertTrue(result.isFullSuccess)
    }

    func testPartialSuccessResult() {
        let result = BatchResult(
            successCount: 8,
            failureCount: 2,
            errors: ["Item 1 failed", "Item 2 failed"]
        )

        XCTAssertFalse(result.isFullSuccess)
        XCTAssertEqual(result.errors.count, 2)
    }

    func testAllFailedResult() {
        let result = BatchResult(
            successCount: 0,
            failureCount: 5,
            errors: ["All failed"]
        )

        XCTAssertFalse(result.isFullSuccess)
        XCTAssertEqual(result.failureCount, 5)
    }
}

// MARK: - Concurrent Batch Operations

final class ConcurrentBatchOperationsTests: XCTestCase {

    var mockState: MockMediaStoreState!

    override func setUp() async throws {
        mockState = MockMediaStoreState()
    }

    override func tearDown() async throws {
        await mockState.reset()
        mockState = nil
    }

    func testConcurrentBatchOperations() async throws {
        let ids1 = [UUID(), UUID()]
        let ids2 = [UUID(), UUID()]

        for id in ids1 + ids2 {
            await mockState.setItem(id, .init(starred: false, tags: []))
        }

        let starAction = TestBatchStarAction(itemIds: ids1, setStarred: true, mockState: mockState)
        let tagAction = TestBatchTagAction(itemIds: ids2, tag: "concurrent", wasAdded: true, mockState: mockState)

        // Execute concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await starAction.execute()
            }
            group.addTask {
                try await tagAction.execute()
            }
            try await group.waitForAll()
        }

        // Verify ids1 are starred
        for id in ids1 {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.starred)
        }

        // Verify ids2 have tag
        for id in ids2 {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.tags.contains("concurrent"))
        }
    }

    func testConcurrentUndoOperations() async throws {
        let ids1 = [UUID(), UUID()]
        let ids2 = [UUID(), UUID()]

        for id in ids1 {
            await mockState.setItem(id, .init(starred: false))
        }
        for id in ids2 {
            await mockState.setItem(id, .init(tags: []))
        }

        let starAction = TestBatchStarAction(itemIds: ids1, setStarred: true, mockState: mockState)
        let tagAction = TestBatchTagAction(itemIds: ids2, tag: "test", wasAdded: true, mockState: mockState)

        try await starAction.execute()
        try await tagAction.execute()

        // Undo concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await starAction.undo()
            }
            group.addTask {
                try await tagAction.undo()
            }
            try await group.waitForAll()
        }

        // Verify ids1 are unstarred
        for id in ids1 {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.starred)
        }

        // Verify ids2 have no tag
        for id in ids2 {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.tags.contains("test"))
        }
    }

    func testConcurrentOperationsOnSameItems() async throws {
        // Test that actor isolation prevents race conditions
        let ids = [UUID(), UUID()]
        for id in ids {
            await mockState.setItem(id, .init(starred: false, tags: []))
        }

        // Multiple concurrent operations on the same items
        let action1 = TestBatchStarAction(itemIds: ids, setStarred: true, mockState: mockState)
        let action2 = TestBatchTagAction(itemIds: ids, tag: "tag1", wasAdded: true, mockState: mockState)
        let action3 = TestBatchTagAction(itemIds: ids, tag: "tag2", wasAdded: true, mockState: mockState)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await action1.execute() }
            group.addTask { try await action2.execute() }
            group.addTask { try await action3.execute() }
            try await group.waitForAll()
        }

        // All operations should have completed
        for id in ids {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.starred)
            XCTAssertTrue(item.tags.contains("tag1"))
            XCTAssertTrue(item.tags.contains("tag2"))
        }
    }
}

// MARK: - Transaction Atomicity Tests

/// Tests to verify batch operations maintain consistency.
/// Note: These use the mock implementation which is inherently atomic per-item.
/// Real database operations would need transaction support for true atomicity.
final class BatchTransactionTests: XCTestCase {

    var mockState: MockMediaStoreState!

    override func setUp() async throws {
        mockState = MockMediaStoreState()
    }

    override func tearDown() async throws {
        await mockState.reset()
        mockState = nil
    }

    func testBatchOperationProcessesAllItems() async throws {
        let ids = (0..<10).map { _ in UUID() }
        for id in ids {
            await mockState.setItem(id, .init(starred: false))
        }

        let action = TestBatchStarAction(itemIds: ids, setStarred: true, mockState: mockState)
        try await action.execute()

        // Verify ALL items were processed
        var processedCount = 0
        for id in ids {
            if await mockState.getItem(id).starred {
                processedCount += 1
            }
        }

        XCTAssertEqual(processedCount, ids.count, "All items should be processed")
    }

    func testBatchUndoRevertsAllItems() async throws {
        let ids = (0..<10).map { _ in UUID() }
        for id in ids {
            await mockState.setItem(id, .init(starred: false))
        }

        let action = TestBatchStarAction(itemIds: ids, setStarred: true, mockState: mockState)
        try await action.execute()
        try await action.undo()

        // Verify ALL items were reverted
        var revertedCount = 0
        for id in ids {
            let item = await mockState.getItem(id)
            if !item.starred {
                revertedCount += 1
            }
        }

        XCTAssertEqual(revertedCount, ids.count, "All items should be reverted")
    }

    func testMultipleBatchOperationsAreIndependent() async throws {
        let ids1 = [UUID(), UUID()]
        let ids2 = [UUID(), UUID()]

        for id in ids1 + ids2 {
            await mockState.setItem(id, .init(starred: false))
        }

        let action1 = TestBatchStarAction(itemIds: ids1, setStarred: true, mockState: mockState)
        let action2 = TestBatchStarAction(itemIds: ids2, setStarred: true, mockState: mockState)

        try await action1.execute()
        try await action2.execute()

        // Undo only action1
        try await action1.undo()

        // ids1 should be unstarred
        for id in ids1 {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.starred)
        }

        // ids2 should still be starred
        for id in ids2 {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.starred)
        }
    }
}
