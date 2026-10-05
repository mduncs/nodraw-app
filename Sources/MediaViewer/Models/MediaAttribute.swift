import Foundation
import GRDB

// MARK: - MediaAttribute

/// GRDB record for the `media_attributes` EAV table.
/// Stores ML pipeline results as (item_id, module, key, value, metadata).
struct MediaAttribute: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "media_attributes"

    let itemId: String
    let module: String
    let key: String
    let value: Double
    let metadata: String?
    let version: Int

    // MARK: - Convenience Init

    init(itemId: UUID, module: PipelineModule, key: String, value: Double, metadata: String? = nil, version: Int = 1) {
        self.itemId = itemId.uuidString
        self.module = module.rawValue
        self.key = key
        self.value = value
        self.metadata = metadata
        self.version = version
    }

    // MARK: - GRDB PersistableRecord

    func encode(to container: inout PersistenceContainer) {
        container["item_id"] = itemId
        container["module"] = module
        container["key"] = key
        container["value"] = value
        container["metadata"] = metadata
        container["version"] = version
    }

    // MARK: - GRDB FetchableRecord

    init(row: Row) throws {
        self.itemId = row["item_id"]
        self.module = row["module"]
        self.key = row["key"]
        self.value = row["value"]
        self.metadata = row["metadata"]
        self.version = row["version"]
    }
}

// MARK: - Batch Operations

extension MediaAttribute {
    /// Upsert a single attribute (insert or replace on conflict).
    func upsert(db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO media_attributes (item_id, module, key, value, metadata, version)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(item_id, module, key) DO UPDATE SET
                    value = excluded.value,
                    metadata = excluded.metadata,
                    version = excluded.version
            """,
            arguments: [itemId, module, key, value, metadata, version]
        )
    }

    /// Upsert multiple attributes in a single transaction.
    static func upsertBatch(_ attributes: [MediaAttribute], db: Database) throws {
        for attr in attributes {
            try attr.upsert(db: db)
        }
    }

    /// Delete all attributes for an item.
    static func deleteAll(db: Database, itemId: UUID) throws {
        try db.execute(
            sql: "DELETE FROM media_attributes WHERE item_id = ?",
            arguments: [itemId.uuidString]
        )
    }

    /// Delete attributes for a specific module.
    static func deleteModule(db: Database, itemId: UUID, module: PipelineModule) throws {
        try db.execute(
            sql: "DELETE FROM media_attributes WHERE item_id = ? AND module = ?",
            arguments: [itemId.uuidString, module.rawValue]
        )
    }

    /// Fetch all attributes for an item.
    static func fetchAll(db: Database, itemId: UUID) throws -> [MediaAttribute] {
        try MediaAttribute.fetchAll(
            db,
            sql: "SELECT * FROM media_attributes WHERE item_id = ? ORDER BY module, key",
            arguments: [itemId.uuidString]
        )
    }

    /// Fetch attributes for a specific module.
    static func fetchModule(db: Database, itemId: UUID, module: PipelineModule) throws -> [MediaAttribute] {
        try MediaAttribute.fetchAll(
            db,
            sql: "SELECT * FROM media_attributes WHERE item_id = ? AND module = ?",
            arguments: [itemId.uuidString, module.rawValue]
        )
    }

    /// Fetch distinct keys for a module (for building filter facets).
    static func distinctKeys(db: Database, module: PipelineModule, minValue: Double = 0.5) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT key FROM media_attributes
                WHERE module = ? AND value >= ?
                ORDER BY key
            """,
            arguments: [module.rawValue, minValue]
        )
    }

    /// Count items matching an attribute filter.
    static func countMatching(db: Database, module: PipelineModule, key: String, minValue: Double = 0) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(DISTINCT item_id) FROM media_attributes
                WHERE module = ? AND key = ? AND value >= ?
            """,
            arguments: [module.rawValue, key, minValue]
        ) ?? 0
    }

    /// Top labels across a set of items, ranked by frequency.
    /// Returns (module, key, count) tuples for the most common scene/object labels.
    static func fetchTopLabels(
        db: Database,
        itemIds: [UUID],
        modules: [PipelineModule] = [.scene, .object],
        minConfidence: Double = 0.5,
        topK: Int = 5
    ) throws -> [(module: String, key: String, count: Int)] {
        guard !itemIds.isEmpty else { return [] }

        let idPlaceholders = itemIds.map { _ in "?" }.joined(separator: ",")
        let moduleList = modules.map { $0.rawValue }
        let modulePlaceholders = moduleList.map { _ in "?" }.joined(separator: ",")

        var args: [DatabaseValueConvertible] = []
        args.append(contentsOf: itemIds.map { $0.uuidString })
        args.append(contentsOf: moduleList)
        args.append(minConfidence)
        args.append(topK)

        let rows = try Row.fetchAll(db, sql: """
            SELECT module, key, COUNT(*) as cnt
            FROM media_attributes
            WHERE item_id IN (\(idPlaceholders))
              AND module IN (\(modulePlaceholders))
              AND value >= ?
            GROUP BY module, key
            ORDER BY cnt DESC
            LIMIT ?
        """, arguments: StatementArguments(args))

        return rows.map { row in
            (module: row["module"] as String,
             key: row["key"] as String,
             count: row["cnt"] as Int)
        }
    }
}
