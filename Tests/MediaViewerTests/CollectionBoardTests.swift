import XCTest
import GRDB
@testable import MediaViewer

final class CollectionBoardTests: XCTestCase {

    // MARK: - CollectionBoard Creation Tests

    func testBoardCreationWithDefaults() {
        let board = CollectionBoard(name: "Test Board")

        XCTAssertEqual(board.name, "Test Board")
        XCTAssertNil(board.description)
        XCTAssertNil(board.coverItemId)
        XCTAssertEqual(board.sortOrder, 0)
        XCTAssertNotNil(board.id)
    }

    func testBoardCreationWithAllFields() {
        let id = UUID()
        let coverId = UUID()
        let created = Date(timeIntervalSince1970: 1700000000)
        let updated = Date(timeIntervalSince1970: 1700100000)

        let board = CollectionBoard(
            id: id,
            name: "Custom Board",
            description: "A test board",
            coverItemId: coverId,
            sortOrder: 5,
            createdAt: created,
            updatedAt: updated
        )

        XCTAssertEqual(board.id, id)
        XCTAssertEqual(board.name, "Custom Board")
        XCTAssertEqual(board.description, "A test board")
        XCTAssertEqual(board.coverItemId, coverId)
        XCTAssertEqual(board.sortOrder, 5)
        XCTAssertEqual(board.createdAt, created)
        XCTAssertEqual(board.updatedAt, updated)
    }

    // MARK: - GRDB Record Tests

    func testBoardRecordRoundtrip() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try db.create(table: "media_items") { t in
                t.column("id", .text).primaryKey()
            }
            try CollectionBoard.createTable(in: db)

            let original = CollectionBoard(
                name: "Test Board",
                description: "Description here",
                sortOrder: 3
            )

            try original.insert(db)

            let fetched = try CollectionBoard.fetchOne(db)
            XCTAssertNotNil(fetched)
            XCTAssertEqual(fetched?.id, original.id)
            XCTAssertEqual(fetched?.name, "Test Board")
            XCTAssertEqual(fetched?.description, "Description here")
            XCTAssertEqual(fetched?.sortOrder, 3)
        }
    }

    func testBoardUpdate() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try db.create(table: "media_items") { t in
                t.column("id", .text).primaryKey()
            }
            try CollectionBoard.createTable(in: db)

            var board = CollectionBoard(name: "Original")
            try board.insert(db)

            board.name = "Updated"
            board.description = "Added description"
            try board.update(db)

            let fetched = try CollectionBoard.fetchOne(db)
            XCTAssertEqual(fetched?.name, "Updated")
            XCTAssertEqual(fetched?.description, "Added description")
        }
    }

    func testBoardDelete() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try db.create(table: "media_items") { t in
                t.column("id", .text).primaryKey()
            }
            try CollectionBoard.createTable(in: db)

            let board = CollectionBoard(name: "ToDelete")
            try board.insert(db)

            XCTAssertEqual(try CollectionBoard.fetchCount(db), 1)

            try board.delete(db)

            XCTAssertEqual(try CollectionBoard.fetchCount(db), 0)
        }
    }

    func testBoardOrdering() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try db.create(table: "media_items") { t in
                t.column("id", .text).primaryKey()
            }
            try CollectionBoard.createTable(in: db)

            let board1 = CollectionBoard(name: "Third", sortOrder: 2)
            let board2 = CollectionBoard(name: "First", sortOrder: 0)
            let board3 = CollectionBoard(name: "Second", sortOrder: 1)

            try board1.insert(db)
            try board2.insert(db)
            try board3.insert(db)

            let ordered = try CollectionBoard.orderedRequest().fetchAll(db)
            XCTAssertEqual(ordered.count, 3)
            XCTAssertEqual(ordered[0].name, "First")
            XCTAssertEqual(ordered[1].name, "Second")
            XCTAssertEqual(ordered[2].name, "Third")
        }
    }

    // MARK: - Equatable Tests

    func testBoardEquality() {
        let id = UUID()
        let date = Date()

        let board1 = CollectionBoard(
            id: id,
            name: "Test",
            description: "Desc",
            coverItemId: nil,
            sortOrder: 0,
            createdAt: date,
            updatedAt: date
        )

        let board2 = CollectionBoard(
            id: id,
            name: "Test",
            description: "Desc",
            coverItemId: nil,
            sortOrder: 0,
            createdAt: date,
            updatedAt: date
        )

        XCTAssertEqual(board1, board2)
    }
}

// MARK: - BoardMembership Tests

final class BoardMembershipTests: XCTestCase {

    func testMembershipCreation() {
        let boardId = UUID()
        let itemId = UUID()

        let membership = BoardMembership(boardId: boardId, itemId: itemId, position: 5)

        XCTAssertEqual(membership.boardId, boardId)
        XCTAssertEqual(membership.itemId, itemId)
        XCTAssertEqual(membership.position, 5)
    }

    func testMembershipRecordRoundtrip() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            // Create tables (boards and memberships - no media_items for this test)
            try db.create(table: "collection_boards") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("coverItemId", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "media_items") { t in
                t.column("id", .text).primaryKey()
            }

            try BoardMembership.createTable(in: db)

            // Create a board and "item"
            let board = CollectionBoard(name: "Test Board")
            try board.insert(db)

            let itemId = UUID()
            try db.execute(sql: "INSERT INTO media_items (id) VALUES (?)", arguments: [itemId.uuidString])

            // Create membership
            let membership = BoardMembership(boardId: board.id, itemId: itemId, position: 0)
            try membership.insert(db)

            // Fetch and verify
            let fetched = try BoardMembership.fetchOne(db)
            XCTAssertNotNil(fetched)
            XCTAssertEqual(fetched?.boardId, board.id)
            XCTAssertEqual(fetched?.itemId, itemId)
            XCTAssertEqual(fetched?.position, 0)
        }
    }

    func testNextPosition() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try db.create(table: "collection_boards") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("coverItemId", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "media_items") { t in
                t.column("id", .text).primaryKey()
            }

            try BoardMembership.createTable(in: db)

            let board = CollectionBoard(name: "Test")
            try board.insert(db)

            // Empty board: next position should be 0
            let firstPosition = try BoardMembership.nextPosition(db: db, boardId: board.id)
            XCTAssertEqual(firstPosition, 0)

            // Add an item at position 0
            let itemId1 = UUID()
            try db.execute(sql: "INSERT INTO media_items (id) VALUES (?)", arguments: [itemId1.uuidString])
            let membership1 = BoardMembership(boardId: board.id, itemId: itemId1, position: 0)
            try membership1.insert(db)

            // Next position should be 1
            let secondPosition = try BoardMembership.nextPosition(db: db, boardId: board.id)
            XCTAssertEqual(secondPosition, 1)

            // Add another at position 1
            let itemId2 = UUID()
            try db.execute(sql: "INSERT INTO media_items (id) VALUES (?)", arguments: [itemId2.uuidString])
            let membership2 = BoardMembership(boardId: board.id, itemId: itemId2, position: 1)
            try membership2.insert(db)

            // Next position should be 2
            let thirdPosition = try BoardMembership.nextPosition(db: db, boardId: board.id)
            XCTAssertEqual(thirdPosition, 2)
        }
    }

    func testRemoveAndCompact() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try db.create(table: "collection_boards") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("coverItemId", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "media_items") { t in
                t.column("id", .text).primaryKey()
            }

            try BoardMembership.createTable(in: db)

            let board = CollectionBoard(name: "Test")
            try board.insert(db)

            // Add 3 items
            let itemIds = (0..<3).map { _ in UUID() }
            for (index, itemId) in itemIds.enumerated() {
                try db.execute(sql: "INSERT INTO media_items (id) VALUES (?)", arguments: [itemId.uuidString])
                let membership = BoardMembership(boardId: board.id, itemId: itemId, position: index)
                try membership.insert(db)
            }

            // Remove the middle item (position 1)
            try BoardMembership.removeAndCompact(db: db, boardId: board.id, itemId: itemIds[1])

            // Should have 2 items left
            let remaining = try BoardMembership
                .filter(Column("boardId") == board.id.uuidString)
                .order(Column("position"))
                .fetchAll(db)

            XCTAssertEqual(remaining.count, 2)
            XCTAssertEqual(remaining[0].itemId, itemIds[0])
            XCTAssertEqual(remaining[0].position, 0)
            XCTAssertEqual(remaining[1].itemId, itemIds[2])
            XCTAssertEqual(remaining[1].position, 1) // Compacted from 2 to 1
        }
    }

    func testReorderMoveDown() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try db.create(table: "collection_boards") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("coverItemId", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "media_items") { t in
                t.column("id", .text).primaryKey()
            }

            try BoardMembership.createTable(in: db)

            let board = CollectionBoard(name: "Test")
            try board.insert(db)

            // Add 4 items at positions 0, 1, 2, 3
            let itemIds = (0..<4).map { _ in UUID() }
            for (index, itemId) in itemIds.enumerated() {
                try db.execute(sql: "INSERT INTO media_items (id) VALUES (?)", arguments: [itemId.uuidString])
                let membership = BoardMembership(boardId: board.id, itemId: itemId, position: index)
                try membership.insert(db)
            }

            // Move item from position 0 to position 2
            try BoardMembership.reorder(db: db, boardId: board.id, from: 0, to: 2)

            let reordered = try BoardMembership
                .filter(Column("boardId") == board.id.uuidString)
                .order(Column("position"))
                .fetchAll(db)

            // New order should be: item1, item2, item0, item3
            XCTAssertEqual(reordered[0].itemId, itemIds[1])
            XCTAssertEqual(reordered[1].itemId, itemIds[2])
            XCTAssertEqual(reordered[2].itemId, itemIds[0])
            XCTAssertEqual(reordered[3].itemId, itemIds[3])
        }
    }

    func testCascadeDeleteBoard() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try db.create(table: "collection_boards") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("description", .text)
                t.column("coverItemId", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "media_items") { t in
                t.column("id", .text).primaryKey()
            }

            try BoardMembership.createTable(in: db)

            let board = CollectionBoard(name: "Test")
            try board.insert(db)

            let itemId = UUID()
            try db.execute(sql: "INSERT INTO media_items (id) VALUES (?)", arguments: [itemId.uuidString])
            let membership = BoardMembership(boardId: board.id, itemId: itemId, position: 0)
            try membership.insert(db)

            XCTAssertEqual(try BoardMembership.fetchCount(db), 1)

            // Delete board - memberships should cascade delete
            try board.delete(db)

            XCTAssertEqual(try BoardMembership.fetchCount(db), 0)
        }
    }
}
