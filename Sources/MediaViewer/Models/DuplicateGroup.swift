import Foundation
import GRDB

// MARK: - DuplicateGroup

/// A group of media items detected as duplicates.
/// Evidence distinguishes complete byte-identical media sets from visual review candidates.
struct DuplicateGroup: Identifiable, Equatable, Hashable {
    let id: UUID
    var itemIds: [UUID]
    var primaryItemId: UUID?
    var status: Status
    var detectionMethod: DetectionMethod
    var similarity: Float
    var createdAt: Date
    var updatedAt: Date
    var evidenceKey: String?
    var evidence: DuplicateEvidence?

    init(
        id: UUID = UUID(),
        itemIds: [UUID],
        primaryItemId: UUID? = nil,
        status: Status = .pending,
        detectionMethod: DetectionMethod,
        similarity: Float,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        evidenceKey: String? = nil,
        evidence: DuplicateEvidence? = nil
    ) {
        self.id = id
        self.itemIds = itemIds
        self.primaryItemId = primaryItemId
        self.status = status
        self.detectionMethod = detectionMethod
        self.similarity = similarity
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.evidenceKey = evidenceKey
        self.evidence = evidence
    }

    // MARK: - Status

    enum Status: String, Codable, CaseIterable {
        case pending      // Awaiting review
        case reviewed     // User has seen but not resolved
        case resolved     // User has merged/kept/deleted
        case dismissed    // User marked as not duplicates

        var displayName: String {
            switch self {
            case .pending: return "Pending"
            case .reviewed: return "Reviewed"
            case .resolved: return "Resolved"
            case .dismissed: return "Dismissed"
            }
        }
    }

    // MARK: - Detection Method

    enum DetectionMethod: String, Codable, CaseIterable {
        case exactDuplicate   // Complete streaming SHA-256 of every declared media file
        case perceptualHash   // Bounded thumbnail DCT candidates; not proof of identity
        case featureVector    // Legacy semantic similarity; never produced by current detector

        var displayName: String {
            switch self {
            case .exactDuplicate: return "Identical media"
            case .perceptualHash: return "Visual candidate"
            case .featureVector: return "Legacy similarity"
            }
        }

        var icon: String {
            switch self {
            case .exactDuplicate: return "doc.on.doc"
            case .perceptualHash: return "number.square"
            case .featureVector: return "eye"
            }
        }
    }

    // MARK: - Computed Properties

    /// Number of items in this group
    var count: Int { itemIds.count }

    /// Whether all items have been removed (empty group)
    var isEmpty: Bool { itemIds.isEmpty }

    var hasVerifiedEvidence: Bool { evidence?.isCurrent == true }

    /// Similarity as a percentage string
    var similarityPercent: String {
        String(format: "%.0f%%", similarity * 100)
    }
}

// MARK: - DuplicateGroupRecord

/// Database record for DuplicateGroup
struct DuplicateGroupRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "duplicate_groups"

    let id: UUID
    var primaryItemId: UUID?
    var status: String
    var detectionMethod: String
    var similarity: Float
    var createdAt: Date
    var updatedAt: Date
    var evidenceKey: String?
    var evidenceJSON: String?
    var evidence: DuplicateEvidence? { evidenceJSON.flatMap { try? JSONDecoder().decode(DuplicateEvidence.self, from: Data($0.utf8)) } }

    init(from group: DuplicateGroup) {
        self.id = group.id
        self.primaryItemId = group.primaryItemId
        self.status = group.status.rawValue
        self.detectionMethod = group.detectionMethod.rawValue
        self.similarity = group.similarity
        self.createdAt = group.createdAt
        self.updatedAt = group.updatedAt
        self.evidenceKey = group.evidenceKey
        self.evidenceJSON = group.evidence.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - GRDB PersistableRecord

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["primaryItemId"] = primaryItemId?.uuidString
        container["status"] = status
        container["detectionMethod"] = detectionMethod
        container["similarity"] = similarity
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
        container["evidenceKey"] = evidenceKey
        container["evidenceJSON"] = evidenceJSON
    }

    // MARK: - GRDB FetchableRecord

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

        if let primaryString: String = row["primaryItemId"] {
            self.primaryItemId = UUID(uuidString: primaryString)
        } else {
            self.primaryItemId = nil
        }

        self.status = row["status"]
        self.detectionMethod = row["detectionMethod"]
        self.similarity = row["similarity"]
        self.createdAt = row["createdAt"]
        self.updatedAt = row["updatedAt"]
        self.evidenceKey = row["evidenceKey"]
        self.evidenceJSON = row["evidenceJSON"]
    }

    /// Convert to domain model (requires fetching member IDs separately)
    func toDuplicateGroup(itemIds: [UUID]) -> DuplicateGroup? {
        guard let status = DuplicateGroup.Status(rawValue: status),
              let method = DuplicateGroup.DetectionMethod(rawValue: detectionMethod) else {
            return nil
        }

        return DuplicateGroup(
            id: id,
            itemIds: itemIds,
            primaryItemId: primaryItemId,
            status: status,
            detectionMethod: method,
            similarity: similarity,
            createdAt: createdAt,
            updatedAt: updatedAt,
            evidenceKey: evidenceKey,
            evidence: evidenceJSON.flatMap { try? JSONDecoder().decode(DuplicateEvidence.self, from: Data($0.utf8)) }
        )
    }
}

// MARK: - DuplicateGroupMemberRecord

/// Junction table record linking groups to items
struct DuplicateGroupMemberRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "duplicate_group_members"

    let groupId: UUID
    let itemId: UUID
    var isPrimary: Bool

    // MARK: - GRDB PersistableRecord

    func encode(to container: inout PersistenceContainer) {
        container["groupId"] = groupId.uuidString
        container["itemId"] = itemId.uuidString
        container["isPrimary"] = isPrimary
    }

    // MARK: - GRDB FetchableRecord

    init(row: Row) throws {
        guard let groupIdString: String = row["groupId"],
              let groupId = UUID(uuidString: groupIdString),
              let itemIdString: String = row["itemId"],
              let itemId = UUID(uuidString: itemIdString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid UUIDs in duplicate_group_members"
                )
            )
        }
        self.groupId = groupId
        self.itemId = itemId
        self.isPrimary = row["isPrimary"]
    }

    init(groupId: UUID, itemId: UUID, isPrimary: Bool = false) {
        self.groupId = groupId
        self.itemId = itemId
        self.isPrimary = isPrimary
    }
}

// MARK: - Static Query Methods

extension DuplicateGroupRecord {
    /// Fetch all groups with a given status
    static func fetchAll(db: Database, status: DuplicateGroup.Status? = nil) throws -> [DuplicateGroupRecord] {
        if let status = status {
            return try DuplicateGroupRecord.fetchAll(
                db,
                sql: "SELECT * FROM duplicate_groups WHERE status = ? ORDER BY createdAt DESC",
                arguments: [status.rawValue]
            )
        } else {
            return try DuplicateGroupRecord.fetchAll(
                db,
                sql: "SELECT * FROM duplicate_groups ORDER BY createdAt DESC"
            )
        }
    }

    /// Fetch a single group by ID
    static func fetch(db: Database, id: UUID) throws -> DuplicateGroupRecord? {
        try DuplicateGroupRecord.fetchOne(
            db,
            sql: "SELECT * FROM duplicate_groups WHERE id = ?",
            arguments: [id.uuidString]
        )
    }

    /// Count groups by status
    static func count(db: Database, status: DuplicateGroup.Status? = nil) throws -> Int {
        if let status = status {
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM duplicate_groups WHERE status = ?",
                arguments: [status.rawValue]
            ) ?? 0
        } else {
            return try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM duplicate_groups"
            ) ?? 0
        }
    }

    /// Delete a group by ID
    static func delete(db: Database, id: UUID) throws {
        try db.execute(
            sql: "DELETE FROM duplicate_groups WHERE id = ?",
            arguments: [id.uuidString]
        )
    }

    /// Upsert a group record
    func upsert(db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO duplicate_groups (id, primaryItemId, status, detectionMethod, similarity, createdAt, updatedAt, evidenceKey, evidenceJSON)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    primaryItemId = excluded.primaryItemId,
                    status = excluded.status,
                    detectionMethod = excluded.detectionMethod,
                    similarity = excluded.similarity,
                    evidenceKey = excluded.evidenceKey,
                    evidenceJSON = excluded.evidenceJSON,
                    updatedAt = excluded.updatedAt
            """,
            arguments: [
                id.uuidString,
                primaryItemId?.uuidString,
                status,
                detectionMethod,
                similarity,
                createdAt,
                updatedAt,
                evidenceKey,
                evidenceJSON
            ]
        )
    }
}

extension DuplicateGroupMemberRecord {
    /// Fetch all member IDs for a group
    static func fetchItemIds(db: Database, groupId: UUID) throws -> [UUID] {
        let strings = try String.fetchAll(
            db,
            sql: "SELECT itemId FROM duplicate_group_members WHERE groupId = ? ORDER BY isPrimary DESC, itemId ASC",
            arguments: [groupId.uuidString]
        )
        return strings.compactMap { UUID(uuidString: $0) }
    }

    /// Fetch all groups that contain a specific item
    static func fetchGroupIds(db: Database, itemId: UUID) throws -> [UUID] {
        let strings = try String.fetchAll(
            db,
            sql: "SELECT groupId FROM duplicate_group_members WHERE itemId = ?",
            arguments: [itemId.uuidString]
        )
        return strings.compactMap { UUID(uuidString: $0) }
    }

    /// Insert a member record
    func insert(db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO duplicate_group_members (groupId, itemId, isPrimary)
                VALUES (?, ?, ?)
                ON CONFLICT(groupId, itemId) DO UPDATE SET isPrimary = excluded.isPrimary
            """,
            arguments: [groupId.uuidString, itemId.uuidString, isPrimary]
        )
    }

    /// Delete all members for a group
    static func deleteAll(db: Database, groupId: UUID) throws {
        try db.execute(
            sql: "DELETE FROM duplicate_group_members WHERE groupId = ?",
            arguments: [groupId.uuidString]
        )
    }

    /// Delete a specific member from a group
    static func delete(db: Database, groupId: UUID, itemId: UUID) throws {
        try db.execute(
            sql: "DELETE FROM duplicate_group_members WHERE groupId = ? AND itemId = ?",
            arguments: [groupId.uuidString, itemId.uuidString]
        )
    }

    /// Check if an item is already in any group
    static func isInAnyGroup(db: Database, itemId: UUID) throws -> Bool {
        let count = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM duplicate_group_members WHERE itemId = ?",
            arguments: [itemId.uuidString]
        ) ?? 0
        return count > 0
    }
}
