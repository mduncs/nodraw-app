import XCTest
@testable import MediaViewer

private enum InjectedStarWriteError: Error {
    case unavailable
}

private actor FaultingStarWriter {
    private var values: [UUID: Bool]
    private var failuresRemaining: [UUID: Int]
    private(set) var attemptedIDs: [UUID] = []

    init(values: [UUID: Bool], failuresRemaining: [UUID: Int]) {
        self.values = values
        self.failuresRemaining = failuresRemaining
    }

    func setStarred(_ id: UUID, to value: Bool) throws {
        attemptedIDs.append(id)
        if let remaining = failuresRemaining[id], remaining > 0 {
            failuresRemaining[id] = remaining - 1
            throw InjectedStarWriteError.unavailable
        }
        values[id] = value
    }

    func state(for id: UUID) -> Bool? { values[id] }
}

@MainActor
final class BatchStarRecoveryTests: XCTestCase {
    func testPartialStarCanRetryOnlyFailuresAndUndoOriginalBeforeState() async throws {
        let first = UUID()
        let second = UUID()
        let writer = FaultingStarWriter(
            values: [first: false, second: false],
            failuresRemaining: [second: 1]
        )
        let action = BatchStarAction(
            itemIds: [first, second],
            setStarred: true,
            previousStates: [first: false, second: false],
            setStarredOperation: { id, starred in
                try await writer.setStarred(id, to: starred)
            }
        )
        let stack = UndoStack()

        do {
            try await stack.performAction(action)
            XCTFail("A partial write should be reported")
        } catch let failure as BatchStarPartialFailure {
            XCTAssertEqual(failure.succeededIDs, [first])
            XCTAssertEqual(failure.failedIDs, [second])
        }
        XCTAssertTrue(stack.canUndo, "The successful partial write must remain undoable")
        let firstAfterPartial = await writer.state(for: first)
        XCTAssertEqual(firstAfterPartial, true)

        try await stack.retryBatchStar(action, failedIDs: [second], alreadyUndoable: true)

        let attempts = await writer.attemptedIDs
        XCTAssertEqual(attempts.sorted(by: { $0.uuidString < $1.uuidString }), [first, second, second].sorted(by: { $0.uuidString < $1.uuidString }))
        let firstAfterRetry = await writer.state(for: first)
        let secondAfterRetry = await writer.state(for: second)
        XCTAssertEqual(firstAfterRetry, true)
        XCTAssertEqual(secondAfterRetry, true)

        _ = try await stack.undo()
        let firstAfterUndo = await writer.state(for: first)
        let secondAfterUndo = await writer.state(for: second)
        XCTAssertEqual(firstAfterUndo, false)
        XCTAssertEqual(secondAfterUndo, false)
        XCTAssertFalse(stack.canUndo, "Retry must not add a second undo entry")
    }

    func testRetryRegistersUndoWhenFirstAttemptChangedNothing() async throws {
        let id = UUID()
        let writer = FaultingStarWriter(values: [id: false], failuresRemaining: [id: 1])
        let action = BatchStarAction(
            itemIds: [id],
            setStarred: true,
            previousStates: [id: false],
            setStarredOperation: { itemID, starred in
                try await writer.setStarred(itemID, to: starred)
            }
        )
        let stack = UndoStack()

        do {
            try await stack.performAction(action)
            XCTFail("The first attempt should fail")
        } catch let failure as BatchStarPartialFailure {
            XCTAssertTrue(failure.succeededIDs.isEmpty)
            XCTAssertEqual(failure.failedIDs, [id])
        }
        XCTAssertFalse(stack.canUndo)

        try await stack.retryBatchStar(action, failedIDs: [id], alreadyUndoable: false)
        XCTAssertTrue(stack.canUndo)
        _ = try await stack.undo()
        let stateAfterUndo = await writer.state(for: id)
        XCTAssertEqual(stateAfterUndo, false)
        XCTAssertFalse(stack.canUndo)
    }

    func testRepeatedPartialRetriesKeepOriginalPrestateAndTargetOnlyFailures() async throws {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let writer = FaultingStarWriter(
            values: [first: false, second: false, third: false],
            failuresRemaining: [second: 1, third: 2]
        )
        let action = BatchStarAction(
            itemIds: [first, second, third],
            setStarred: true,
            previousStates: [first: false, second: false, third: false],
            setStarredOperation: { id, starred in
                try await writer.setStarred(id, to: starred)
            }
        )
        let stack = UndoStack()

        do {
            try await stack.performAction(action)
            XCTFail("The first operation should partially fail")
        } catch let failure as BatchStarPartialFailure {
            XCTAssertEqual(failure.succeededIDs, [first])
            XCTAssertEqual(failure.failedIDs, [second, third])
        }

        do {
            try await stack.retryBatchStar(action, failedIDs: [second, third], alreadyUndoable: true)
            XCTFail("The first retry should still report the remaining failure")
        } catch let failure as BatchStarRetryFailure {
            XCTAssertEqual(failure.succeededIDs, [second])
            XCTAssertEqual(failure.failedIDs, [third])
            XCTAssertTrue(failure.isUndoable)
        }

        try await stack.retryBatchStar(action, failedIDs: [third], alreadyUndoable: true)
        let attempts = await writer.attemptedIDs
        XCTAssertEqual(attempts.count, 6)
        XCTAssertEqual(attempts.filter { $0 == first }.count, 1)
        XCTAssertEqual(attempts.filter { $0 == second }.count, 2)
        XCTAssertEqual(attempts.filter { $0 == third }.count, 3)

        _ = try await stack.undo()
        let restoredFirst = await writer.state(for: first)
        let restoredSecond = await writer.state(for: second)
        let restoredThird = await writer.state(for: third)
        let restored = [restoredFirst, restoredSecond, restoredThird]
        XCTAssertEqual(restored.compactMap { $0 }, [false, false, false])
        XCTAssertFalse(stack.canUndo)
    }
}
