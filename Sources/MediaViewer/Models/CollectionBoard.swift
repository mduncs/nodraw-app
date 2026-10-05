import Foundation
import GRDB

// MARK: - CollectionBoard

/// A user-curated collection of media items, like a Pinterest board.
/// Items are manually added and can be ordered within the board.
struct CollectionBoard: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var description: String?
    var coverItemId: UUID?       // Optional cover image from board items
    var sortOrder: Int           // Position in sidebar list
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        coverItemId: UUID? = nil,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.coverItemId = coverItemId
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - GRDB Record

extension CollectionBoard: FetchableRecord, PersistableRecord {
    static let databaseTableName = "collection_boards"

    /// Association to board memberships
    static let memberships = hasMany(BoardMembership.self)

    /// Through association to media items
    static let items = hasMany(
        MediaItemRecord.self,
        through: memberships,
        using: BoardMembership.item
    )

    static func createTable(in db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("description", .text)
            t.column("coverItemId", .text).references("media_items", onDelete: .setNull)
            t.column("sortOrder", .integer).notNull().defaults(to: 0)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }

        // Index for sorting boards in sidebar
        try db.create(
            index: "idx_collection_boards_sortOrder",
            on: databaseTableName,
            columns: ["sortOrder"],
            ifNotExists: true
        )
    }

    // MARK: - Custom Encoding

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["name"] = name
        container["description"] = description
        container["coverItemId"] = coverItemId?.uuidString
        container["sortOrder"] = sortOrder
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
    }

    // MARK: - Custom Decoding

    init(row: Row) throws {
        guard let idString: String = row["id"],
              let id = UUID(uuidString: idString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid or missing UUID in id column"
                )
            )
        }
        self.id = id
        self.name = row["name"]
        self.description = row["description"]

        if let coverIdString: String = row["coverItemId"] {
            self.coverItemId = UUID(uuidString: coverIdString)
        } else {
            self.coverItemId = nil
        }

        self.sortOrder = row["sortOrder"]
        self.createdAt = row["createdAt"]
        self.updatedAt = row["updatedAt"]
    }
}

// MARK: - Request Helpers

extension CollectionBoard {
    /// Request for boards ordered by sortOrder
    static func orderedRequest() -> QueryInterfaceRequest<CollectionBoard> {
        CollectionBoard.order(Column("sortOrder").asc, Column("createdAt").desc)
    }

    /// Count of items in this board
    func itemCount(db: Database) throws -> Int {
        try BoardMembership
            .filter(Column("boardId") == id.uuidString)
            .fetchCount(db)
    }

    /// Fetch media items in this board, ordered by position
    func fetchItems(db: Database) throws -> [MediaItem] {
        let memberships = try BoardMembership
            .filter(Column("boardId") == id.uuidString)
            .order(Column("position").asc)
            .fetchAll(db)

        var items: [MediaItem] = []
        for membership in memberships {
            if let record = try MediaItemRecord
                .filter(Column("id") == membership.itemId.uuidString)
                .fetchOne(db),
               let item = record.toMediaItem() {
                items.append(item)
            }
        }
        return items
    }

    /// Get first item to use as cover if no cover is explicitly set
    func effectiveCoverId(db: Database) throws -> UUID? {
        if let coverId = coverItemId {
            return coverId
        }
        // Use first item as default cover
        return try BoardMembership
            .filter(Column("boardId") == id.uuidString)
            .order(Column("position").asc)
            .fetchOne(db)
            .map(\.itemId)
    }
}
