import Foundation
import GRDB
import Combine

// MARK: - AddResult

/// Result of adding items to a board
enum BoardAddResult: Sendable {
    case added(count: Int)
    case allExisted
    case partial(added: Int, existed: Int)
}

// MARK: - BoardStore

/// Service for managing collection boards and their memberships.
/// Provides CRUD operations and observation for live UI updates.
final class BoardStore: @unchecked Sendable {
    private let database: DatabaseManager

    /// Publisher for board changes - views can observe this
    @MainActor
    private let changesSubject = PassthroughSubject<Void, Never>()

    @MainActor
    var changes: AnyPublisher<Void, Never> {
        changesSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    // MARK: - Board CRUD

    /// Fetch all boards ordered by sortOrder
    func fetchBoards() async throws -> [CollectionBoard] {
        try await database.read { db in
            try CollectionBoard.orderedRequest().fetchAll(db)
        }
    }

    /// Fetch a single board by ID
    func fetchBoard(id: UUID) async throws -> CollectionBoard? {
        try await database.read { db in
            try CollectionBoard
                .filter(Column("id") == id.uuidString)
                .fetchOne(db)
        }
    }

    /// Create a new board
    func createBoard(name: String, description: String? = nil) async throws -> CollectionBoard {
        let board = try await database.write { db -> CollectionBoard in
            // Get next sort order
            let maxSortOrder = try Int.fetchOne(
                db,
                sql: "SELECT MAX(sortOrder) FROM collection_boards"
            ) ?? -1

            let board = CollectionBoard(
                name: name,
                description: description,
                sortOrder: maxSortOrder + 1
            )
            try board.insert(db)
            return board
        }

        await notifyChange()
        return board
    }

    /// Update an existing board
    func updateBoard(_ board: CollectionBoard) async throws {
        let updated = CollectionBoard(
            id: board.id,
            name: board.name,
            description: board.description,
            coverItemId: board.coverItemId,
            sortOrder: board.sortOrder,
            createdAt: board.createdAt,
            updatedAt: Date()
        )

        try await database.write { db in
            try updated.update(db)
        }
        await notifyChange()
    }

    /// Delete a board and all its memberships (CASCADE handles memberships)
    func deleteBoard(id: UUID) async throws {
        // Get cover item ID before deletion for cache cleanup
        let coverItemId = try await database.read { db -> UUID? in
            guard let board = try CollectionBoard
                .filter(Column("id") == id.uuidString)
                .fetchOne(db) else {
                return nil
            }
            return try board.effectiveCoverId(db: db)
        }

        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM collection_boards WHERE id = ?",
                arguments: [id.uuidString]
            )
        }

        // Clean up cached cover thumbnail to prevent orphan cache entries
        if let coverItemId = coverItemId {
            await ImageCache.shared.evict(itemId: coverItemId)
        }

        await notifyChange()
    }

    /// Reorder boards in the sidebar
    func reorderBoards(from sourceIndex: Int, to destinationIndex: Int) async throws {
        try await database.write { db in
            // Fetch all boards in current order
            var boards = try CollectionBoard.orderedRequest().fetchAll(db)
            guard sourceIndex < boards.count, destinationIndex <= boards.count else { return }

            // Perform the reorder
            let moved = boards.remove(at: sourceIndex)
            let insertIndex = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
            boards.insert(moved, at: insertIndex)

            // Update sort orders
            for (index, var board) in boards.enumerated() {
                board.sortOrder = index
                board.updatedAt = Date()
                try board.update(db)
            }
        }
        await notifyChange()
    }

    // MARK: - Board Membership Operations

    /// Add an item to a board at the end
    func addItem(_ itemId: UUID, to boardId: UUID) async throws {
        try await database.write { db in
            // Check if already in board
            let exists = try BoardMembership
                .filter(Column("boardId") == boardId.uuidString && Column("itemId") == itemId.uuidString)
                .fetchCount(db) > 0

            guard !exists else { return }

            let position = try BoardMembership.nextPosition(db: db, boardId: boardId)
            let membership = BoardMembership(boardId: boardId, itemId: itemId, position: position)
            try membership.insert(db)

            // Update board's updatedAt
            try db.execute(
                sql: "UPDATE collection_boards SET updatedAt = ? WHERE id = ?",
                arguments: [Date(), boardId.uuidString]
            )
        }
        await notifyChange()
    }

    /// Add multiple items to a board
    /// Returns result indicating how many were added vs already existed
    @discardableResult
    func addItems(_ itemIds: [UUID], to boardId: UUID) async throws -> BoardAddResult {
        let result = try await database.write { db -> BoardAddResult in
            var nextPosition = try BoardMembership.nextPosition(db: db, boardId: boardId)
            var addedCount = 0
            var existedCount = 0

            for itemId in itemIds {
                // Check if already in board
                let exists = try BoardMembership
                    .filter(Column("boardId") == boardId.uuidString && Column("itemId") == itemId.uuidString)
                    .fetchCount(db) > 0

                if exists {
                    existedCount += 1
                    continue
                }

                let membership = BoardMembership(boardId: boardId, itemId: itemId, position: nextPosition)
                try membership.insert(db)
                nextPosition += 1
                addedCount += 1
            }

            // Update board's updatedAt
            try db.execute(
                sql: "UPDATE collection_boards SET updatedAt = ? WHERE id = ?",
                arguments: [Date(), boardId.uuidString]
            )

            // Return appropriate result
            if addedCount == 0 {
                return .allExisted
            } else if existedCount == 0 {
                return .added(count: addedCount)
            } else {
                return .partial(added: addedCount, existed: existedCount)
            }
        }
        await notifyChange()
        return result
    }

    /// Remove an item from a board
    func removeItem(_ itemId: UUID, from boardId: UUID) async throws {
        try await database.write { db in
            try BoardMembership.removeAndCompact(db: db, boardId: boardId, itemId: itemId)

            // If this item was the cover, clear it
            try db.execute(
                sql: "UPDATE collection_boards SET coverItemId = NULL, updatedAt = ? WHERE id = ? AND coverItemId = ?",
                arguments: [Date(), boardId.uuidString, itemId.uuidString]
            )
        }
        await notifyChange()
    }

    /// Remove multiple items from a board
    func removeItems(_ itemIds: [UUID], from boardId: UUID) async throws {
        try await database.write { db in
            for itemId in itemIds {
                try BoardMembership.removeAndCompact(db: db, boardId: boardId, itemId: itemId)
            }

            // Clear cover if it was one of the removed items
            let itemIdStrings = itemIds.map(\.uuidString)
            for idString in itemIdStrings {
                try db.execute(
                    sql: "UPDATE collection_boards SET coverItemId = NULL WHERE id = ? AND coverItemId = ?",
                    arguments: [boardId.uuidString, idString]
                )
            }

            // Update board's updatedAt
            try db.execute(
                sql: "UPDATE collection_boards SET updatedAt = ? WHERE id = ?",
                arguments: [Date(), boardId.uuidString]
            )
        }
        await notifyChange()
    }

    /// Reorder an item within a board
    func reorderItem(in boardId: UUID, from oldPosition: Int, to newPosition: Int) async throws {
        try await database.write { db in
            try BoardMembership.reorder(db: db, boardId: boardId, from: oldPosition, to: newPosition)

            // Update board's updatedAt
            try db.execute(
                sql: "UPDATE collection_boards SET updatedAt = ? WHERE id = ?",
                arguments: [Date(), boardId.uuidString]
            )
        }
        await notifyChange()
    }

    /// Set the cover image for a board
    func setCover(boardId: UUID, itemId: UUID?) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE collection_boards SET coverItemId = ?, updatedAt = ? WHERE id = ?",
                arguments: [itemId?.uuidString, Date(), boardId.uuidString]
            )
        }
        await notifyChange()
    }

    // MARK: - Query Operations

    /// Fetch items in a board ordered by position
    func fetchItems(in boardId: UUID) async throws -> [MediaItem] {
        try await database.read { db in
            guard let board = try CollectionBoard
                .filter(Column("id") == boardId.uuidString)
                .fetchOne(db) else {
                return []
            }
            return try board.fetchItems(db: db)
        }
    }

    /// Get item count for a board
    func itemCount(boardId: UUID) async throws -> Int {
        try await database.read { db in
            try BoardMembership
                .filter(Column("boardId") == boardId.uuidString)
                .fetchCount(db)
        }
    }

    /// Get all boards containing a specific item
    func boardsContaining(itemId: UUID) async throws -> [CollectionBoard] {
        try await database.read { db in
            try BoardMembership.boardsContaining(db: db, itemId: itemId)
        }
    }

    /// Check if an item is in a specific board
    func isItemInBoard(itemId: UUID, boardId: UUID) async throws -> Bool {
        try await database.read { db in
            try BoardMembership
                .filter(Column("boardId") == boardId.uuidString && Column("itemId") == itemId.uuidString)
                .fetchCount(db) > 0
        }
    }

    /// Get cover item for a board (explicit or first item)
    func fetchCoverItem(boardId: UUID) async throws -> MediaItem? {
        try await database.read { db in
            guard let board = try CollectionBoard
                .filter(Column("id") == boardId.uuidString)
                .fetchOne(db) else {
                return nil
            }

            guard let coverId = try board.effectiveCoverId(db: db) else {
                return nil
            }

            guard let record = try MediaItemRecord
                .filter(Column("id") == coverId.uuidString)
                .fetchOne(db) else {
                return nil
            }

            return record.toMediaItem()
        }
    }

    // MARK: - Board with Item Counts

    /// Fetch all boards with their item counts
    func fetchBoardsWithCounts() async throws -> [(board: CollectionBoard, itemCount: Int)] {
        try await database.read { db in
            let boards = try CollectionBoard.orderedRequest().fetchAll(db)
            return try boards.map { board in
                let count = try board.itemCount(db: db)
                return (board: board, itemCount: count)
            }
        }
    }

    // MARK: - Private Helpers

    @MainActor
    private func notifyChange() {
        changesSubject.send()
    }
}
