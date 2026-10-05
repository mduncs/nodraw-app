import XCTest
@testable import MediaViewer

/// Tests for the canonical hierarchy mover `TagSettings.move(tagId:toParent:atIndex:)`
/// and the methods that route through it (`reparent`, `moveSortOrder`).
@MainActor
final class TagTreeMoveTests: XCTestCase {
    private var saved: [TagDefinition] = []

    override func setUp() {
        super.setUp()
        saved = TagSettings.shared.definitions
    }

    override func tearDown() {
        TagSettings.shared.definitions = saved
        super.tearDown()
    }

    // MARK: - Builders / helpers

    private func makeTag(_ name: String, parent: UUID? = nil, order: Int) -> TagDefinition {
        var t = TagDefinition(name: name)
        t.parentId = parent
        t.sortOrder = order
        return t
    }

    private func childNames(of parent: UUID?, _ settings: TagSettings) -> [String] {
        let defs = parent == nil ? settings.rootTags() : settings.children(of: parent!)
        return defs.map(\.name)
    }

    private func sortOrders(of parent: UUID?, _ settings: TagSettings) -> [Int] {
        let defs = parent == nil ? settings.rootTags() : settings.children(of: parent!)
        return defs.map(\.sortOrder)
    }

    // MARK: - Reordering among siblings

    func testReorderMovesToSlotAndKeepsSortOrderContiguous() {
        let s = TagSettings.shared
        let a = makeTag("a", order: 0)
        let b = makeTag("b", order: 1)
        let c = makeTag("c", order: 2)
        s.definitions = [a, b, c]

        // Move c to the front (slot 0 in the destination order).
        XCTAssertTrue(s.move(tagId: c.id, toParent: nil, atIndex: 0))
        XCTAssertEqual(childNames(of: nil, s), ["c", "a", "b"])
        XCTAssertEqual(sortOrders(of: nil, s), [0, 1, 2], "sortOrder must stay contiguous 0..n")
    }

    func testMoveSortOrderUpAndDownStillSwaps() {
        let s = TagSettings.shared
        let a = makeTag("a", order: 0)
        let b = makeTag("b", order: 1)
        let c = makeTag("c", order: 2)
        s.definitions = [a, b, c]

        s.moveSortOrder(tagId: b.id, direction: -1) // up
        XCTAssertEqual(childNames(of: nil, s), ["b", "a", "c"])

        s.moveSortOrder(tagId: b.id, direction: 1) // down
        XCTAssertEqual(childNames(of: nil, s), ["a", "b", "c"])

        s.moveSortOrder(tagId: c.id, direction: 1) // already last -> no change
        XCTAssertEqual(childNames(of: nil, s), ["a", "b", "c"])
    }

    // MARK: - Reparenting

    func testReparentNestsAndCompactsSource() {
        let s = TagSettings.shared
        let a = makeTag("a", order: 0)
        let b = makeTag("b", order: 1)
        let c = makeTag("c", order: 2)
        s.definitions = [a, b, c]

        // Nest b under a.
        XCTAssertTrue(s.move(tagId: b.id, toParent: a.id, atIndex: 0))
        XCTAssertEqual(childNames(of: a.id, s), ["b"])
        // Source (root) is now [a, c] with contiguous order.
        XCTAssertEqual(childNames(of: nil, s), ["a", "c"])
        XCTAssertEqual(sortOrders(of: nil, s), [0, 1])
    }

    func testReparentAppendsToEnd() {
        let s = TagSettings.shared
        let parent = makeTag("parent", order: 0)
        let x = makeTag("x", parent: parent.id, order: 0)
        let y = makeTag("y", parent: parent.id, order: 1)
        let loose = makeTag("loose", order: 1)
        s.definitions = [parent, x, y, loose]

        XCTAssertTrue(s.reparent(tagId: loose.id, newParentId: parent.id))
        XCTAssertEqual(childNames(of: parent.id, s), ["x", "y", "loose"])
        XCTAssertEqual(sortOrders(of: parent.id, s), [0, 1, 2])
    }

    func testPromoteToRoot() {
        let s = TagSettings.shared
        let parent = makeTag("parent", order: 0)
        let child = makeTag("child", parent: parent.id, order: 0)
        s.definitions = [parent, child]

        XCTAssertTrue(s.move(tagId: child.id, toParent: nil, atIndex: 1))
        XCTAssertEqual(childNames(of: nil, s), ["parent", "child"])
        XCTAssertTrue(s.children(of: parent.id).isEmpty)
    }

    func testMovingParentCarriesItsSubtree() {
        let s = TagSettings.shared
        let host = makeTag("host", order: 0)
        let parent = makeTag("parent", order: 1)
        let child = makeTag("child", parent: parent.id, order: 0)
        s.definitions = [host, parent, child]

        // Move `parent` under `host`; `child` should remain under `parent`.
        XCTAssertTrue(s.move(tagId: parent.id, toParent: host.id, atIndex: 0))
        XCTAssertEqual(childNames(of: host.id, s), ["parent"])
        XCTAssertEqual(childNames(of: parent.id, s), ["child"])
    }

    // MARK: - Illegal moves

    func testCycleRejected() {
        let s = TagSettings.shared
        let parent = makeTag("parent", order: 0)
        let child = makeTag("child", parent: parent.id, order: 0)
        s.definitions = [parent, child]

        // Moving `parent` under its own `child` must be rejected.
        XCTAssertFalse(s.move(tagId: parent.id, toParent: child.id, atIndex: 0))
        XCTAssertNil(s.definitions.first(where: { $0.id == parent.id })?.parentId)
        XCTAssertEqual(s.definitions.first(where: { $0.id == child.id })?.parentId, parent.id)
    }

    func testSelfDropRejected() {
        let s = TagSettings.shared
        let a = makeTag("a", order: 0)
        s.definitions = [a]
        XCTAssertFalse(s.move(tagId: a.id, toParent: a.id, atIndex: 0))
    }

    func testNoOpReturnsFalse() {
        let s = TagSettings.shared
        let a = makeTag("a", order: 0)
        let b = makeTag("b", order: 1)
        s.definitions = [a, b]

        // a is already at slot 0 under root.
        XCTAssertFalse(s.move(tagId: a.id, toParent: nil, atIndex: 0))
        XCTAssertEqual(childNames(of: nil, s), ["a", "b"])
    }

    func testIndexClampsIntoRange() {
        let s = TagSettings.shared
        let a = makeTag("a", order: 0)
        let b = makeTag("b", order: 1)
        let c = makeTag("c", order: 2)
        s.definitions = [a, b, c]

        // Oversized index clamps to end.
        XCTAssertTrue(s.move(tagId: a.id, toParent: nil, atIndex: 999))
        XCTAssertEqual(childNames(of: nil, s), ["b", "c", "a"])
        XCTAssertEqual(sortOrders(of: nil, s), [0, 1, 2])
    }

    // MARK: - Undo round-trip

    func testMoveTagActionUndoRestoresPosition() async throws {
        let s = TagSettings.shared
        let a = makeTag("a", order: 0)
        let b = makeTag("b", order: 1)
        let c = makeTag("c", order: 2)
        s.definitions = [a, b, c]

        let oldIndex = s.siblingIndex(of: c.id) ?? -1
        XCTAssertEqual(oldIndex, 2)

        XCTAssertTrue(s.move(tagId: c.id, toParent: nil, atIndex: 0))
        let newIndex = s.siblingIndex(of: c.id) ?? -1
        XCTAssertEqual(newIndex, 0)

        let action = MoveTagAction(
            tagId: c.id,
            tagName: "c",
            oldParentId: nil,
            oldIndex: oldIndex,
            newParentId: nil,
            newIndex: newIndex
        )
        try await action.undo()
        XCTAssertEqual(childNames(of: nil, s), ["a", "b", "c"], "undo restores original order")

        try await action.execute()
        XCTAssertEqual(childNames(of: nil, s), ["c", "a", "b"], "redo re-applies the move")
    }
}
