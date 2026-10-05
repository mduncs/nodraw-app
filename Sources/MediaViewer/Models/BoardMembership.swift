import Foundation
import GRDB

// MARK: - BoardMembership

/// Junction table linking media items to collection boards with position ordering.
struct BoardMembership: Codable, Equatable {
    let boardId: UUID
    let itemId: UUID
    var position: Int

    init(boardId: UUID, itemId: UUID, position: Int) {
        self.boardId = boardId
        self.itemId = itemId
        self.position = position
    }
}

// MARK: - GRDB Record

extension BoardMembership: FetchableRecord, PersistableRecord {
    static let databaseTableName = "board_memberships"

    /// Association to the board
    static let board = belongsTo(CollectionBoard.self)

    /// Association to the media item
    static let item = belongsTo(MediaItemRecord.self, using: ForeignKey(["itemId"]))

    static func createTable(in db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) { t in
            t.column("boardId", .text).notNull()
                .references("collection_boards", onDelete: .cascade)
            t.column("itemId", .text).notNull()
                .references("media_items", onDelete: .cascade)
            t.column("position", .integer).notNull()
            t.primaryKey(["boardId", "itemId"])
        }

        // Index for fast position queries within a board
        try db.create(
            index: "idx_board_memberships_position",
            on: databaseTableName,
            columns: ["boardId", "position"],
            ifNotExists: true
        )

        // Index for finding which boards an item belongs to
        try db.create(
            index: "idx_board_memberships_item",
            on: databaseTableName,
            columns: ["itemId"],
            ifNotExists: true
        )
    }

    // MARK: - Custom Encoding

    func encode(to container: inout PersistenceContainer) {
        container["boardId"] = boardId.uuidString
        container["itemId"] = itemId.uuidString
        container["position"] = position
    }

    // MARK: - Custom Decoding

    init(row: Row) throws {
        guard let boardIdString: String = row["boardId"],
              let boardId = UUID(uuidString: boardIdString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid or missing UUID in boardId column"
                )
            )
        }
        guard let itemIdString: String = row["itemId"],
              let itemId = UUID(uuidString: itemIdString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid or missing UUID in itemId column"
                )
            )
        }
        self.boardId = boardId
        self.itemId = itemId
        self.position = row["position"]
    }
}

// MARK: - Batch Operations

extension BoardMembership {
    /// Get next available position in a board
    static func nextPosition(db: Database, boardId: UUID) throws -> Int {
        let maxPosition = try Int.fetchOne(
            db,
            sql: "SELECT MAX(position) FROM board_memberships WHERE boardId = ?",
            arguments: [boardId.uuidString]
        ) ?? -1
        return maxPosition + 1
    }

    /// Reorder items in a board by moving item at oldPosition to newPosition
    static func reorder(
        db: Database,
        boardId: UUID,
        from oldPosition: Int,
        to newPosition: Int
    ) throws {
        guard oldPosition != newPosition else { return }

        // Identify the item being moved (by position, before any shifts)
        guard let movedItemId = try String.fetchOne(
            db,
            sql: "SELECT itemId FROM board_memberships WHERE boardId = ? AND position = ?",
            arguments: [boardId.uuidString, oldPosition]
        ) else { return }

        // Stash the moved item at a temporary position to avoid conflicts
        try db.execute(
            sql: """
                UPDATE board_memberships
                SET position = -1
                WHERE boardId = ? AND itemId = ?
            """,
            arguments: [boardId.uuidString, movedItemId]
        )

        if oldPosition < newPosition {
            // Moving down: shift items in range [old+1, new] up by 1
            try db.execute(
                sql: """
                    UPDATE board_memberships
                    SET position = position - 1
                    WHERE boardId = ? AND position > ? AND position <= ?
                """,
                arguments: [boardId.uuidString, oldPosition, newPosition]
            )
        } else {
            // Moving up: shift items in range [new, old-1] down by 1
            try db.execute(
                sql: """
                    UPDATE board_memberships
                    SET position = position + 1
                    WHERE boardId = ? AND position >= ? AND position < ?
                """,
                arguments: [boardId.uuidString, newPosition, oldPosition]
            )
        }

        // Place the moved item at its final position (match by itemId, not sentinel)
        try db.execute(
            sql: """
                UPDATE board_memberships
                SET position = ?
                WHERE boardId = ? AND itemId = ?
            """,
            arguments: [newPosition, boardId.uuidString, movedItemId]
        )
    }

    /// Remove item from board and compact positions
    static func removeAndCompact(db: Database, boardId: UUID, itemId: UUID) throws {
        // Get current position
        guard let membership = try BoardMembership
            .filter(Column("boardId") == boardId.uuidString && Column("itemId") == itemId.uuidString)
            .fetchOne(db) else {
            return
        }

        let removedPosition = membership.position

        // Delete the membership
        try db.execute(
            sql: "DELETE FROM board_memberships WHERE boardId = ? AND itemId = ?",
            arguments: [boardId.uuidString, itemId.uuidString]
        )

        // Compact positions (shift all items after removed position up by 1)
        try db.execute(
            sql: """
                UPDATE board_memberships
                SET position = position - 1
                WHERE boardId = ? AND position > ?
            """,
            arguments: [boardId.uuidString, removedPosition]
        )
    }

    /// Fetch all boards that contain a specific item
    static func boardsContaining(db: Database, itemId: UUID) throws -> [CollectionBoard] {
        try CollectionBoard
            .joining(required: CollectionBoard.memberships.filter(Column("itemId") == itemId.uuidString))
            .fetchAll(db)
    }
}
