import XCTest
@testable import MediaViewer

// MARK: - Mock Media Store Actor

/// Actor-based mock for thread-safe state tracking in tests.
/// Used to verify that undoable actions perform the expected operations.
actor MockMediaStoreState {
    var items: [UUID: MockItem] = [:]
    var callLog: [String] = []

    struct MockItem: Equatable {
        var starred: Bool = false
        var tags: [String] = []
        var notes: String? = nil
        var isDeleted: Bool = false
    }

    func getItem(_ id: UUID) -> MockItem {
        items[id] ?? MockItem()
    }

    func setItem(_ id: UUID, _ item: MockItem) {
        items[id] = item
    }

    func log(_ message: String) {
        callLog.append(message)
    }

    func reset() {
        items.removeAll()
        callLog.removeAll()
    }

    // Convenience methods to match MediaStore API
    func toggleStar(id: UUID) {
        var item = items[id] ?? MockItem()
        item.starred.toggle()
        items[id] = item
        callLog.append("toggleStar(\(id))")
    }

    func setStar(id: UUID, starred: Bool) {
        var item = items[id] ?? MockItem()
        item.starred = starred
        items[id] = item
        callLog.append("setStar(\(id), \(starred))")
    }

    func addTag(id: UUID, tag: String) {
        var item = items[id] ?? MockItem()
        if !item.tags.contains(tag) {
            item.tags.append(tag)
        }
        items[id] = item
        callLog.append("addTag(\(id), \(tag))")
    }

    func removeTag(id: UUID, tag: String) {
        var item = items[id] ?? MockItem()
        item.tags.removeAll { $0 == tag }
        items[id] = item
        callLog.append("removeTag(\(id), \(tag))")
    }

    func updateNotes(id: UUID, notes: String?) {
        var item = items[id] ?? MockItem()
        item.notes = notes
        items[id] = item
        callLog.append("updateNotes(\(id), \(notes ?? "nil"))")
    }

    func softDelete(ids: [UUID]) {
        for id in ids {
            var item = items[id] ?? MockItem()
            item.isDeleted = true
            items[id] = item
        }
        callLog.append("softDelete(\(ids.count) items)")
    }

    func restoreDeleted(ids: [UUID]) {
        for id in ids {
            var item = items[id] ?? MockItem()
            item.isDeleted = false
            items[id] = item
        }
        callLog.append("restoreDeleted(\(ids.count) items)")
    }
}

private final class UndoCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    func markCalled() {
        lock.withLock {
            called = true
        }
    }

    var wasCalled: Bool {
        lock.withLock {
            called
        }
    }
}

// MARK: - Test Action Implementations

/// Test version of ToggleStarAction that uses MockMediaStoreState
struct TestToggleStarAction: UndoableAction {
    let itemId: UUID
    let wasStarred: Bool
    let mockState: MockMediaStoreState

    var description: String {
        wasStarred ? "Unstarred item" : "Starred item"
    }

    func execute() async throws {
        await mockState.toggleStar(id: itemId)
    }

    func undo() async throws {
        await mockState.toggleStar(id: itemId)
    }
}

/// Test version of AddTagAction
struct TestAddTagAction: UndoableAction {
    let itemId: UUID
    let tag: String
    let mockState: MockMediaStoreState

    var description: String {
        "Added tag '\(tag)'"
    }

    func execute() async throws {
        await mockState.addTag(id: itemId, tag: tag)
    }

    func undo() async throws {
        await mockState.removeTag(id: itemId, tag: tag)
    }
}

/// Test version of RemoveTagAction
struct TestRemoveTagAction: UndoableAction {
    let itemId: UUID
    let tag: String
    let mockState: MockMediaStoreState

    var description: String {
        "Removed tag '\(tag)'"
    }

    func execute() async throws {
        await mockState.removeTag(id: itemId, tag: tag)
    }

    func undo() async throws {
        await mockState.addTag(id: itemId, tag: tag)
    }
}

/// Test version of BatchStarAction
struct TestBatchStarAction: UndoableAction {
    let itemIds: [UUID]
    let setStarred: Bool
    let mockState: MockMediaStoreState

    var description: String {
        let action = setStarred ? "Starred" : "Unstarred"
        return "\(action) \(itemIds.count) item\(itemIds.count == 1 ? "" : "s")"
    }

    func execute() async throws {
        for id in itemIds {
            await mockState.setStar(id: id, starred: setStarred)
        }
    }

    func undo() async throws {
        for id in itemIds {
            await mockState.setStar(id: id, starred: !setStarred)
        }
    }
}

/// Test version of BatchTagAction
struct TestBatchTagAction: UndoableAction {
    let itemIds: [UUID]
    let tag: String
    let wasAdded: Bool
    let mockState: MockMediaStoreState

    var description: String {
        let action = wasAdded ? "Added" : "Removed"
        return "\(action) tag '\(tag)' on \(itemIds.count) item\(itemIds.count == 1 ? "" : "s")"
    }

    func execute() async throws {
        if wasAdded {
            for id in itemIds {
                await mockState.addTag(id: id, tag: tag)
            }
        } else {
            for id in itemIds {
                await mockState.removeTag(id: id, tag: tag)
            }
        }
    }

    func undo() async throws {
        if wasAdded {
            for id in itemIds {
                await mockState.removeTag(id: id, tag: tag)
            }
        } else {
            for id in itemIds {
                await mockState.addTag(id: id, tag: tag)
            }
        }
    }
}

/// Test version of UpdateNotesAction
struct TestUpdateNotesAction: UndoableAction {
    let itemId: UUID
    let oldNotes: String?
    let newNotes: String?
    let mockState: MockMediaStoreState

    var description: String {
        if oldNotes == nil && newNotes != nil {
            return "Added notes"
        } else if oldNotes != nil && newNotes == nil {
            return "Removed notes"
        } else {
            return "Updated notes"
        }
    }

    func execute() async throws {
        await mockState.updateNotes(id: itemId, notes: newNotes)
    }

    func undo() async throws {
        await mockState.updateNotes(id: itemId, notes: oldNotes)
    }
}

/// Test version of DeleteItemsAction
struct TestDeleteItemsAction: UndoableAction {
    let itemIds: [UUID]
    let mockState: MockMediaStoreState

    var description: String {
        "Moved \(itemIds.count) item\(itemIds.count == 1 ? "" : "s") to Trash"
    }

    func execute() async throws {
        await mockState.softDelete(ids: itemIds)
    }

    func undo() async throws {
        await mockState.restoreDeleted(ids: itemIds)
    }
}

// MARK: - ToggleStarAction Tests

final class ToggleStarActionTests: XCTestCase {

    var mockState: MockMediaStoreState!
    let testId = UUID()

    override func setUp() async throws {
        mockState = MockMediaStoreState()
    }

    override func tearDown() async throws {
        await mockState.reset()
        mockState = nil
    }

    func testExecuteStarsItem() async throws {
        // Item starts unstarred
        await mockState.setItem(testId, .init(starred: false))

        let action = TestToggleStarAction(itemId: testId, wasStarred: false, mockState: mockState)
        try await action.execute()

        let item = await mockState.getItem(testId)
        XCTAssertTrue(item.starred, "Execute should toggle to starred")
    }

    func testExecuteUnstarsItem() async throws {
        // Item starts starred
        await mockState.setItem(testId, .init(starred: true))

        let action = TestToggleStarAction(itemId: testId, wasStarred: true, mockState: mockState)
        try await action.execute()

        let item = await mockState.getItem(testId)
        XCTAssertFalse(item.starred, "Execute should toggle to unstarred")
    }

    func testUndoRevertsToggle() async throws {
        await mockState.setItem(testId, .init(starred: false))

        let action = TestToggleStarAction(itemId: testId, wasStarred: false, mockState: mockState)
        try await action.execute()

        var item = await mockState.getItem(testId)
        XCTAssertTrue(item.starred)

        try await action.undo()

        item = await mockState.getItem(testId)
        XCTAssertFalse(item.starred, "Undo should revert to original state")
    }

    func testDescriptionWhenStarring() {
        let action = TestToggleStarAction(itemId: testId, wasStarred: false, mockState: mockState)
        XCTAssertEqual(action.description, "Starred item")
    }

    func testDescriptionWhenUnstarring() {
        let action = TestToggleStarAction(itemId: testId, wasStarred: true, mockState: mockState)
        XCTAssertEqual(action.description, "Unstarred item")
    }
}

// MARK: - AddTagAction Tests

final class AddTagActionTests: XCTestCase {

    var mockState: MockMediaStoreState!
    let testId = UUID()

    override func setUp() async throws {
        mockState = MockMediaStoreState()
    }

    override func tearDown() async throws {
        await mockState.reset()
        mockState = nil
    }

    func testExecuteAddsTag() async throws {
        await mockState.setItem(testId, .init(tags: []))

        let action = TestAddTagAction(itemId: testId, tag: "nature", mockState: mockState)
        try await action.execute()

        let item = await mockState.getItem(testId)
        XCTAssertTrue(item.tags.contains("nature"))
    }

    func testUndoRemovesTag() async throws {
        await mockState.setItem(testId, .init(tags: []))

        let action = TestAddTagAction(itemId: testId, tag: "landscape", mockState: mockState)
        try await action.execute()

        var item = await mockState.getItem(testId)
        XCTAssertTrue(item.tags.contains("landscape"))

        try await action.undo()

        item = await mockState.getItem(testId)
        XCTAssertFalse(item.tags.contains("landscape"), "Undo should remove added tag")
    }

    func testDescription() {
        let action = TestAddTagAction(itemId: testId, tag: "travel", mockState: mockState)
        XCTAssertEqual(action.description, "Added tag 'travel'")
    }

    func testExecuteDoesNotDuplicateTag() async throws {
        await mockState.setItem(testId, .init(tags: ["existing"]))

        let action = TestAddTagAction(itemId: testId, tag: "existing", mockState: mockState)
        try await action.execute()

        let item = await mockState.getItem(testId)
        let tagCount = item.tags.filter { $0 == "existing" }.count
        XCTAssertEqual(tagCount, 1, "Should not duplicate existing tag")
    }
}

// MARK: - RemoveTagAction Tests

final class RemoveTagActionTests: XCTestCase {

    var mockState: MockMediaStoreState!
    let testId = UUID()

    override func setUp() async throws {
        mockState = MockMediaStoreState()
    }

    override func tearDown() async throws {
        await mockState.reset()
        mockState = nil
    }

    func testExecuteRemovesTag() async throws {
        await mockState.setItem(testId, .init(tags: ["art", "photo"]))

        let action = TestRemoveTagAction(itemId: testId, tag: "art", mockState: mockState)
        try await action.execute()

        let item = await mockState.getItem(testId)
        XCTAssertFalse(item.tags.contains("art"))
        XCTAssertTrue(item.tags.contains("photo"), "Other tags should remain")
    }

    func testUndoRestoresTag() async throws {
        await mockState.setItem(testId, .init(tags: ["music"]))

        let action = TestRemoveTagAction(itemId: testId, tag: "music", mockState: mockState)
        try await action.execute()

        var item = await mockState.getItem(testId)
        XCTAssertFalse(item.tags.contains("music"))

        try await action.undo()

        item = await mockState.getItem(testId)
        XCTAssertTrue(item.tags.contains("music"), "Undo should restore removed tag")
    }

    func testDescription() {
        let action = TestRemoveTagAction(itemId: testId, tag: "vintage", mockState: mockState)
        XCTAssertEqual(action.description, "Removed tag 'vintage'")
    }
}

// MARK: - BatchStarAction Tests

final class BatchStarActionTests: XCTestCase {

    var mockState: MockMediaStoreState!
    let testIds = [UUID(), UUID(), UUID()]

    override func setUp() async throws {
        mockState = MockMediaStoreState()
    }

    override func tearDown() async throws {
        await mockState.reset()
        mockState = nil
    }

    func testExecuteStarsAllItems() async throws {
        for id in testIds {
            await mockState.setItem(id, .init(starred: false))
        }

        let action = TestBatchStarAction(itemIds: testIds, setStarred: true, mockState: mockState)
        try await action.execute()

        for id in testIds {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.starred, "All items should be starred")
        }
    }

    func testExecuteUnstarsAllItems() async throws {
        for id in testIds {
            await mockState.setItem(id, .init(starred: true))
        }

        let action = TestBatchStarAction(itemIds: testIds, setStarred: false, mockState: mockState)
        try await action.execute()

        for id in testIds {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.starred, "All items should be unstarred")
        }
    }

    func testUndoRevertsAllStars() async throws {
        for id in testIds {
            await mockState.setItem(id, .init(starred: false))
        }

        let action = TestBatchStarAction(itemIds: testIds, setStarred: true, mockState: mockState)
        try await action.execute()
        try await action.undo()

        for id in testIds {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.starred, "Undo should revert all to unstarred")
        }
    }

    func testDescriptionSingular() {
        let action = TestBatchStarAction(itemIds: [UUID()], setStarred: true, mockState: mockState)
        XCTAssertEqual(action.description, "Starred 1 item")
    }

    func testDescriptionPlural() {
        let action = TestBatchStarAction(itemIds: testIds, setStarred: true, mockState: mockState)
        XCTAssertEqual(action.description, "Starred 3 items")
    }

    func testDescriptionUnstar() {
        let action = TestBatchStarAction(itemIds: testIds, setStarred: false, mockState: mockState)
        XCTAssertEqual(action.description, "Unstarred 3 items")
    }
}

// MARK: - BatchTagAction Tests

final class BatchTagActionTests: XCTestCase {

    var mockState: MockMediaStoreState!
    let testIds = [UUID(), UUID()]

    override func setUp() async throws {
        mockState = MockMediaStoreState()
    }

    override func tearDown() async throws {
        await mockState.reset()
        mockState = nil
    }

    func testExecuteAddsTagToAll() async throws {
        for id in testIds {
            await mockState.setItem(id, .init(tags: []))
        }

        let action = TestBatchTagAction(itemIds: testIds, tag: "batch-tag", wasAdded: true, mockState: mockState)
        try await action.execute()

        for id in testIds {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.tags.contains("batch-tag"))
        }
    }

    func testExecuteRemovesTagFromAll() async throws {
        for id in testIds {
            await mockState.setItem(id, .init(tags: ["remove-me"]))
        }

        let action = TestBatchTagAction(itemIds: testIds, tag: "remove-me", wasAdded: false, mockState: mockState)
        try await action.execute()

        for id in testIds {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.tags.contains("remove-me"))
        }
    }

    func testUndoRevertsAddedTags() async throws {
        for id in testIds {
            await mockState.setItem(id, .init(tags: []))
        }

        let action = TestBatchTagAction(itemIds: testIds, tag: "test", wasAdded: true, mockState: mockState)
        try await action.execute()
        try await action.undo()

        for id in testIds {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.tags.contains("test"), "Undo should remove added tags")
        }
    }

    func testUndoRestoresRemovedTags() async throws {
        for id in testIds {
            await mockState.setItem(id, .init(tags: ["keep-me"]))
        }

        let action = TestBatchTagAction(itemIds: testIds, tag: "keep-me", wasAdded: false, mockState: mockState)
        try await action.execute()
        try await action.undo()

        for id in testIds {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.tags.contains("keep-me"), "Undo should restore removed tags")
        }
    }

    func testDescriptionAddedSingular() {
        let action = TestBatchTagAction(itemIds: [UUID()], tag: "art", wasAdded: true, mockState: mockState)
        XCTAssertEqual(action.description, "Added tag 'art' on 1 item")
    }

    func testDescriptionAddedPlural() {
        let action = TestBatchTagAction(itemIds: testIds, tag: "nature", wasAdded: true, mockState: mockState)
        XCTAssertEqual(action.description, "Added tag 'nature' on 2 items")
    }

    func testDescriptionRemoved() {
        let action = TestBatchTagAction(itemIds: testIds, tag: "old", wasAdded: false, mockState: mockState)
        XCTAssertEqual(action.description, "Removed tag 'old' on 2 items")
    }
}

// MARK: - UpdateNotesAction Tests

final class UpdateNotesActionTests: XCTestCase {

    var mockState: MockMediaStoreState!
    let testId = UUID()

    override func setUp() async throws {
        mockState = MockMediaStoreState()
    }

    override func tearDown() async throws {
        await mockState.reset()
        mockState = nil
    }

    func testExecuteUpdatesNotes() async throws {
        await mockState.setItem(testId, .init(notes: nil))

        let action = TestUpdateNotesAction(
            itemId: testId,
            oldNotes: nil,
            newNotes: "New note content",
            mockState: mockState
        )
        try await action.execute()

        let item = await mockState.getItem(testId)
        XCTAssertEqual(item.notes, "New note content")
    }

    func testUndoRevertsToOldNotes() async throws {
        await mockState.setItem(testId, .init(notes: "Original note"))

        let action = TestUpdateNotesAction(
            itemId: testId,
            oldNotes: "Original note",
            newNotes: "Updated note",
            mockState: mockState
        )
        try await action.execute()

        var item = await mockState.getItem(testId)
        XCTAssertEqual(item.notes, "Updated note")

        try await action.undo()

        item = await mockState.getItem(testId)
        XCTAssertEqual(item.notes, "Original note", "Undo should revert to old notes")
    }

    func testDescriptionAddedNotes() {
        let action = TestUpdateNotesAction(
            itemId: testId,
            oldNotes: nil,
            newNotes: "Some notes",
            mockState: mockState
        )
        XCTAssertEqual(action.description, "Added notes")
    }

    func testDescriptionRemovedNotes() {
        let action = TestUpdateNotesAction(
            itemId: testId,
            oldNotes: "Had notes",
            newNotes: nil,
            mockState: mockState
        )
        XCTAssertEqual(action.description, "Removed notes")
    }

    func testDescriptionUpdatedNotes() {
        let action = TestUpdateNotesAction(
            itemId: testId,
            oldNotes: "Old notes",
            newNotes: "New notes",
            mockState: mockState
        )
        XCTAssertEqual(action.description, "Updated notes")
    }

    func testUndoFromNilToNil() async throws {
        // Edge case: both old and new are nil (shouldn't happen but handle gracefully)
        await mockState.setItem(testId, .init(notes: nil))

        let action = TestUpdateNotesAction(
            itemId: testId,
            oldNotes: nil,
            newNotes: nil,
            mockState: mockState
        )

        // Should not throw
        try await action.execute()
        try await action.undo()

        let item = await mockState.getItem(testId)
        XCTAssertNil(item.notes)
    }
}

// MARK: - DeleteItemsAction Tests

final class DeleteItemsActionTests: XCTestCase {

    var mockState: MockMediaStoreState!
    let testIds = [UUID(), UUID(), UUID()]

    override func setUp() async throws {
        mockState = MockMediaStoreState()
    }

    override func tearDown() async throws {
        await mockState.reset()
        mockState = nil
    }

    func testExecuteSoftDeletesItems() async throws {
        for id in testIds {
            await mockState.setItem(id, .init(isDeleted: false))
        }

        let action = TestDeleteItemsAction(itemIds: testIds, mockState: mockState)
        try await action.execute()

        for id in testIds {
            let item = await mockState.getItem(id)
            XCTAssertTrue(item.isDeleted, "All items should be soft deleted")
        }
    }

    func testUndoRestoresDeletedItems() async throws {
        for id in testIds {
            await mockState.setItem(id, .init(isDeleted: false))
        }

        let action = TestDeleteItemsAction(itemIds: testIds, mockState: mockState)
        try await action.execute()
        try await action.undo()

        for id in testIds {
            let item = await mockState.getItem(id)
            XCTAssertFalse(item.isDeleted, "All items should be restored")
        }
    }

    func testDescriptionSingular() {
        let action = TestDeleteItemsAction(itemIds: [UUID()], mockState: mockState)
        XCTAssertEqual(action.description, "Moved 1 item to Trash")
    }

    func testDescriptionPlural() {
        let action = TestDeleteItemsAction(itemIds: testIds, mockState: mockState)
        XCTAssertEqual(action.description, "Moved 3 items to Trash")
    }

    func testDeleteEmptyArrayNoOp() async throws {
        let action = TestDeleteItemsAction(itemIds: [], mockState: mockState)

        // Should not throw
        try await action.execute()
        try await action.undo()

        XCTAssertEqual(action.description, "Moved 0 items to Trash")
    }
}

// MARK: - Legacy UndoAction Tests

final class LegacyUndoActionTests: XCTestCase {

    func testLegacyActionUndo() {
        let recorder = UndoCallRecorder()

        let action = LegacyUndoAction(description: "Legacy Test") {
            recorder.markCalled()
        }

        action.undo()

        XCTAssertTrue(recorder.wasCalled)
    }

    func testLegacyActionDescription() {
        let action = LegacyUndoAction(description: "Custom Description") {}
        XCTAssertEqual(action.description, "Custom Description")
    }
}

// MARK: - LegacyUndoActionWrapper Tests

final class LegacyUndoActionWrapperTests: XCTestCase {

    func testWrapperDescription() {
        let legacy = LegacyUndoAction(description: "Wrapped Action") {}
        let wrapper = LegacyUndoActionWrapper(legacyAction: legacy)

        XCTAssertEqual(wrapper.description, "Wrapped Action")
    }

    func testWrapperExecuteNoOp() async throws {
        let legacy = LegacyUndoAction(description: "Test") {}
        let wrapper = LegacyUndoActionWrapper(legacyAction: legacy)

        // Execute should not throw (it's a no-op for legacy actions)
        try await wrapper.execute()
    }

    func testWrapperUndoCallsLegacyUndo() async throws {
        let recorder = UndoCallRecorder()

        let legacy = LegacyUndoAction(description: "Test") {
            recorder.markCalled()
        }
        let wrapper = LegacyUndoActionWrapper(legacyAction: legacy)

        try await wrapper.undo()

        XCTAssertTrue(recorder.wasCalled)
    }
}
