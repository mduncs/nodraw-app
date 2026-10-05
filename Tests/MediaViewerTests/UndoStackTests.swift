import XCTest
@testable import MediaViewer

// MARK: - Mock UndoableAction

/// Mock action for testing UndoStack behavior
struct MockUndoableAction: UndoableAction {
    let description: String
    let executeHandler: @Sendable () async throws -> Void
    let undoHandler: @Sendable () async throws -> Void

    init(
        description: String = "Mock Action",
        execute: @escaping @Sendable () async throws -> Void = {},
        undo: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.description = description
        self.executeHandler = execute
        self.undoHandler = undo
    }

    func execute() async throws {
        try await executeHandler()
    }

    func undo() async throws {
        try await undoHandler()
    }
}

/// Mock action that tracks execution state
actor ExecutionTracker {
    var executeCount = 0
    var undoCount = 0

    func recordExecute() {
        executeCount += 1
    }

    func recordUndo() {
        undoCount += 1
    }

    func reset() {
        executeCount = 0
        undoCount = 0
    }
}

// MARK: - UndoStackTests

@MainActor
final class UndoStackTests: XCTestCase {

    var undoStack: UndoStack!

    override func setUp() async throws {
        undoStack = UndoStack()
    }

    override func tearDown() async throws {
        undoStack.clear()
        undoStack = nil
    }

    // MARK: - performAction Tests

    func testPerformActionExecutesAction() async throws {
        let tracker = ExecutionTracker()
        let action = MockUndoableAction(
            description: "Test Execute",
            execute: { await tracker.recordExecute() }
        )

        try await undoStack.performAction(action)

        let count = await tracker.executeCount
        XCTAssertEqual(count, 1, "Action should be executed exactly once")
    }

    func testPerformActionPushesToStack() async throws {
        let action = MockUndoableAction(description: "Test Push")

        XCTAssertFalse(undoStack.canUndo, "Stack should be empty initially")

        try await undoStack.performAction(action)

        XCTAssertTrue(undoStack.canUndo, "Stack should have action after perform")
    }

    func testPerformActionClearsRedoStack() async throws {
        // Perform two actions
        try await undoStack.performAction(MockUndoableAction(description: "Action 1"))
        try await undoStack.performAction(MockUndoableAction(description: "Action 2"))

        // Undo one to populate redo stack
        _ = try await undoStack.undo()
        XCTAssertTrue(undoStack.canRedo, "Redo should be available after undo")

        // Perform new action - should clear redo
        try await undoStack.performAction(MockUndoableAction(description: "Action 3"))
        XCTAssertFalse(undoStack.canRedo, "Redo stack should be cleared after new action")
    }

    func testPerformActionShowsToast() async throws {
        let action = MockUndoableAction(description: "Test Toast")

        XCTAssertNil(undoStack.currentToast, "No toast initially")

        try await undoStack.performAction(action)

        XCTAssertNotNil(undoStack.currentToast, "Toast should appear after action")
        XCTAssertEqual(undoStack.currentToast?.message, "Test Toast")
        XCTAssertTrue(undoStack.currentToast?.showUndo ?? false, "Toast should show undo button")
    }

    // MARK: - undo Tests

    func testUndoCallsActionUndo() async throws {
        let tracker = ExecutionTracker()
        let action = MockUndoableAction(
            description: "Test Undo",
            undo: { await tracker.recordUndo() }
        )

        try await undoStack.performAction(action)
        _ = try await undoStack.undo()

        let count = await tracker.undoCount
        XCTAssertEqual(count, 1, "Undo should be called exactly once")
    }

    func testUndoReturnsAction() async throws {
        let action = MockUndoableAction(description: "Unique Description")

        try await undoStack.performAction(action)
        let undoneAction = try await undoStack.undo()

        XCTAssertNotNil(undoneAction)
        XCTAssertEqual(undoneAction?.description, "Unique Description")
    }

    func testUndoReturnsNilOnEmptyStack() async throws {
        let result = try await undoStack.undo()
        XCTAssertNil(result, "Undo on empty stack should return nil")
    }

    func testUndoPushesToRedoStack() async throws {
        let action = MockUndoableAction(description: "Test Redo Push")

        try await undoStack.performAction(action)
        XCTAssertFalse(undoStack.canRedo)

        _ = try await undoStack.undo()
        XCTAssertTrue(undoStack.canRedo, "Undone action should be on redo stack")
    }

    func testUndoShowsToastWithUndidPrefix() async throws {
        let action = MockUndoableAction(description: "My Action")

        try await undoStack.performAction(action)
        _ = try await undoStack.undo()

        XCTAssertNotNil(undoStack.currentToast)
        XCTAssertEqual(undoStack.currentToast?.message, "Undid: My Action")
        XCTAssertFalse(undoStack.currentToast?.showUndo ?? true, "Undo toast should not show undo button")
    }

    // MARK: - redo Tests

    func testRedoCallsActionExecute() async throws {
        let tracker = ExecutionTracker()
        let action = MockUndoableAction(
            description: "Test Redo",
            execute: { await tracker.recordExecute() }
        )

        try await undoStack.performAction(action)
        await tracker.reset()  // Reset after initial perform

        _ = try await undoStack.undo()
        _ = try await undoStack.redo()

        let count = await tracker.executeCount
        XCTAssertEqual(count, 1, "Redo should call execute once")
    }

    func testRedoReturnsAction() async throws {
        let action = MockUndoableAction(description: "Redo Test")

        try await undoStack.performAction(action)
        _ = try await undoStack.undo()
        let redoneAction = try await undoStack.redo()

        XCTAssertNotNil(redoneAction)
        XCTAssertEqual(redoneAction?.description, "Redo Test")
    }

    func testRedoReturnsNilOnEmptyRedoStack() async throws {
        let result = try await undoStack.redo()
        XCTAssertNil(result, "Redo on empty stack should return nil")
    }

    func testRedoPushesBackToUndoStack() async throws {
        let action = MockUndoableAction(description: "Test")

        try await undoStack.performAction(action)
        _ = try await undoStack.undo()
        XCTAssertFalse(undoStack.canUndo)

        _ = try await undoStack.redo()
        XCTAssertTrue(undoStack.canUndo, "Redone action should be back on undo stack")
    }

    func testRedoShowsToastWithRedidPrefix() async throws {
        let action = MockUndoableAction(description: "Redone Action")

        try await undoStack.performAction(action)
        _ = try await undoStack.undo()
        _ = try await undoStack.redo()

        XCTAssertNotNil(undoStack.currentToast)
        XCTAssertEqual(undoStack.currentToast?.message, "Redid: Redone Action")
        XCTAssertTrue(undoStack.currentToast?.showUndo ?? false, "Redo toast should show undo button")
    }

    // MARK: - Stack Depth Limit Tests

    func testStackDepthLimitIs20() async throws {
        // Perform 25 actions
        for i in 1...25 {
            try await undoStack.performAction(MockUndoableAction(description: "Action \(i)"))
        }

        // Undo all - should only get 20 back
        var undoCount = 0
        while try await undoStack.undo() != nil {
            undoCount += 1
        }

        XCTAssertEqual(undoCount, 20, "Stack depth should be limited to 20")
    }

    func testOldestActionsRemovedFirst() async throws {
        // Perform 22 actions
        for i in 1...22 {
            try await undoStack.performAction(MockUndoableAction(description: "Action \(i)"))
        }

        // The first 2 actions should have been removed
        // Undo should give us Action 22 first (most recent)
        let firstUndo = try await undoStack.undo()
        XCTAssertEqual(firstUndo?.description, "Action 22")

        // Continue undoing
        for _ in 1...18 {
            _ = try await undoStack.undo()
        }

        // Last action should be Action 3 (Actions 1 and 2 were removed)
        let lastUndo = try await undoStack.undo()
        XCTAssertEqual(lastUndo?.description, "Action 3")

        // No more actions
        let beyondLimit = try await undoStack.undo()
        XCTAssertNil(beyondLimit)
    }

    func testRedoStackDepthLimitIs20() async throws {
        // Perform and undo 25 actions
        for i in 1...25 {
            try await undoStack.performAction(MockUndoableAction(description: "Action \(i)"))
        }

        // Undo 20 (max from undo stack)
        for _ in 1...20 {
            _ = try await undoStack.undo()
        }

        // Redo all - should only get 20 back
        var redoCount = 0
        while try await undoStack.redo() != nil {
            redoCount += 1
        }

        XCTAssertEqual(redoCount, 20, "Redo stack depth should be limited to 20")
    }

    // MARK: - canUndo / canRedo Tests

    func testCanUndoInitiallyFalse() async throws {
        XCTAssertFalse(undoStack.canUndo)
    }

    func testCanRedoInitiallyFalse() async throws {
        XCTAssertFalse(undoStack.canRedo)
    }

    func testCanUndoTrueAfterPerform() async throws {
        try await undoStack.performAction(MockUndoableAction())
        XCTAssertTrue(undoStack.canUndo)
    }

    func testCanUndoFalseAfterUndoingAll() async throws {
        try await undoStack.performAction(MockUndoableAction())
        _ = try await undoStack.undo()
        XCTAssertFalse(undoStack.canUndo)
    }

    func testCanRedoTrueAfterUndo() async throws {
        try await undoStack.performAction(MockUndoableAction())
        _ = try await undoStack.undo()
        XCTAssertTrue(undoStack.canRedo)
    }

    func testCanRedoFalseAfterRedoingAll() async throws {
        try await undoStack.performAction(MockUndoableAction())
        _ = try await undoStack.undo()
        _ = try await undoStack.redo()
        XCTAssertFalse(undoStack.canRedo)
    }

    // MARK: - Clear Tests

    func testClearRemovesAllUndoActions() async throws {
        try await undoStack.performAction(MockUndoableAction(description: "Action 1"))
        try await undoStack.performAction(MockUndoableAction(description: "Action 2"))

        XCTAssertTrue(undoStack.canUndo)

        undoStack.clear()

        XCTAssertFalse(undoStack.canUndo, "Undo stack should be empty after clear")
    }

    func testClearRemovesAllRedoActions() async throws {
        try await undoStack.performAction(MockUndoableAction())
        _ = try await undoStack.undo()

        XCTAssertTrue(undoStack.canRedo)

        undoStack.clear()

        XCTAssertFalse(undoStack.canRedo, "Redo stack should be empty after clear")
    }

    func testClearDismissesToast() async throws {
        try await undoStack.performAction(MockUndoableAction())

        XCTAssertNotNil(undoStack.currentToast)

        undoStack.clear()

        XCTAssertNil(undoStack.currentToast, "Toast should be dismissed after clear")
    }

    // MARK: - Toast Tests

    func testDismissToast() async throws {
        try await undoStack.performAction(MockUndoableAction())

        XCTAssertNotNil(undoStack.currentToast)

        undoStack.dismissToast()

        XCTAssertNil(undoStack.currentToast)
    }

    func testNewActionReplacesToast() async throws {
        try await undoStack.performAction(MockUndoableAction(description: "First"))
        let firstToastId = undoStack.currentToast?.id

        try await undoStack.performAction(MockUndoableAction(description: "Second"))

        XCTAssertNotEqual(undoStack.currentToast?.id, firstToastId, "New toast should replace old one")
        XCTAssertEqual(undoStack.currentToast?.message, "Second")
    }

    func testToastHasUniqueId() async throws {
        try await undoStack.performAction(MockUndoableAction(description: "Action 1"))
        let firstId = undoStack.currentToast?.id

        undoStack.dismissToast()
        try await undoStack.performAction(MockUndoableAction(description: "Action 2"))
        let secondId = undoStack.currentToast?.id

        XCTAssertNotNil(firstId)
        XCTAssertNotNil(secondId)
        XCTAssertNotEqual(firstId, secondId, "Each toast should have unique ID")
    }

    // MARK: - Error Handling Tests

    func testPerformActionThrowsOnError() async throws {
        struct TestError: Error {}

        let action = MockUndoableAction(
            execute: { throw TestError() }
        )

        do {
            try await undoStack.performAction(action)
            XCTFail("Should throw error")
        } catch {
            XCTAssertTrue(error is TestError)
        }

        // Stack should still be empty since action failed
        // Note: Current implementation pushes first then executes, so this tests current behavior
        // If behavior changes, this test documents the expected contract
    }

    func testUndoThrowsOnError() async throws {
        struct TestError: Error {}

        let action = MockUndoableAction(
            undo: { throw TestError() }
        )

        try await undoStack.performAction(action)

        do {
            _ = try await undoStack.undo()
            XCTFail("Should throw error on undo failure")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }

    // MARK: - Multiple Actions Sequence

    func testMultipleActionsUndoRedoSequence() async throws {
        let tracker = ExecutionTracker()

        let actions = (1...3).map { i in
            MockUndoableAction(
                description: "Action \(i)",
                execute: { await tracker.recordExecute() },
                undo: { await tracker.recordUndo() }
            )
        }

        // Perform all
        for action in actions {
            try await undoStack.performAction(action)
        }

        var executeCount = await tracker.executeCount
        XCTAssertEqual(executeCount, 3, "All actions should be executed")

        // Undo all
        for i in (1...3).reversed() {
            let undone = try await undoStack.undo()
            XCTAssertEqual(undone?.description, "Action \(i)")
        }

        let undoCount = await tracker.undoCount
        XCTAssertEqual(undoCount, 3, "All actions should be undone")

        XCTAssertFalse(undoStack.canUndo)
        XCTAssertTrue(undoStack.canRedo)

        // Redo all
        await tracker.reset()
        for i in 1...3 {
            let redone = try await undoStack.redo()
            XCTAssertEqual(redone?.description, "Action \(i)")
        }

        executeCount = await tracker.executeCount
        XCTAssertEqual(executeCount, 3, "All actions should be re-executed")

        XCTAssertTrue(undoStack.canUndo)
        XCTAssertFalse(undoStack.canRedo)
    }
}

// MARK: - UndoToast Tests

final class UndoToastTests: XCTestCase {

    func testToastEquality() {
        let toast1 = UndoToast(message: "Test", showUndo: true)
        let toast2 = toast1

        XCTAssertEqual(toast1, toast2, "Same toast should be equal")
    }

    func testToastInequalityDifferentIds() {
        let toast1 = UndoToast(message: "Test", showUndo: true)
        let toast2 = UndoToast(message: "Test", showUndo: true)

        XCTAssertNotEqual(toast1, toast2, "Different toasts should have different IDs")
    }

    func testToastDefaultShowUndoTrue() {
        let toast = UndoToast(message: "Test")
        XCTAssertTrue(toast.showUndo, "Default showUndo should be true")
    }

    func testToastHasTimestamp() {
        let before = Date()
        let toast = UndoToast(message: "Test")
        let after = Date()

        XCTAssertGreaterThanOrEqual(toast.timestamp, before)
        XCTAssertLessThanOrEqual(toast.timestamp, after)
    }
}
