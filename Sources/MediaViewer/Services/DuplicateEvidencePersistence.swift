import Foundation
import GRDB

/// Small synchronous helpers shared by detector publication and transactional review.
enum DuplicateEvidencePersistence {
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE duplicate_groups ADD COLUMN evidenceKey TEXT;
            ALTER TABLE duplicate_groups ADD COLUMN evidenceJSON TEXT;
            ALTER TABLE duplicate_groups ADD COLUMN isCurrent INTEGER NOT NULL DEFAULT 0;
            CREATE UNIQUE INDEX idx_duplicate_groups_evidence_key ON duplicate_groups(evidenceKey) WHERE evidenceKey IS NOT NULL;
            CREATE TABLE duplicate_digest_cache (
                path TEXT PRIMARY KEY,
                algorithmVersion INTEGER NOT NULL,
                versionJSON TEXT NOT NULL,
                sha256 TEXT NOT NULL,
                visualJSON TEXT
            );
            CREATE TABLE duplicate_review_decisions (
                id TEXT PRIMARY KEY,
                groupId TEXT NOT NULL,
                evidenceKey TEXT,
                status TEXT NOT NULL,
                primaryItemId TEXT,
                membersJSON TEXT NOT NULL,
                createdAt DATETIME NOT NULL
            );
            CREATE INDEX idx_duplicate_review_decisions_key ON duplicate_review_decisions(evidenceKey, createdAt DESC);
            """)
        // Preserve legacy decisions/membership without claiming that sampled MD5 was exact.
        for record in try DuplicateGroupRecord.fetchAll(db: db) {
            guard let group = record.toDuplicateGroup(itemIds: try DuplicateGroupMemberRecord.fetchItemIds(db: db, groupId: record.id)) else { continue }
            if group.status != .pending {
                try recordDecision(group, status: group.status, primaryItemID: group.primaryItemId, in: db)
            }
        }
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// The latest applicable snapshot wins. Undo appends an explicit pending snapshot;
    /// this prevents an older resolved/dismissed decision from resurfacing on the next scan.
    static func recordDecision(_ group: DuplicateGroup, status: DuplicateGroup.Status,
                               primaryItemID: UUID?, decisionID: UUID = UUID(), in db: Database) throws {
        let members = try json(group.evidence?.items.sorted { $0.itemID.uuidString < $1.itemID.uuidString } ?? [])
        try db.execute(sql: """
            INSERT INTO duplicate_review_decisions(id, groupId, evidenceKey, status, primaryItemId, membersJSON, createdAt)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET status=excluded.status, primaryItemId=excluded.primaryItemId,
                membersJSON=excluded.membersJSON, createdAt=excluded.createdAt
            """, arguments: [decisionID.uuidString, group.id.uuidString, group.evidenceKey, status.rawValue, primaryItemID?.uuidString, members, Date()])
        try db.execute(sql: "UPDATE duplicate_groups SET status = ?, primaryItemId = ?, updatedAt = ? WHERE id = ?",
                       arguments: [status.rawValue, primaryItemID?.uuidString, Date(), group.id.uuidString])
        try db.execute(sql: "UPDATE duplicate_group_members SET isPrimary = CASE WHEN itemId = ? THEN 1 ELSE 0 END WHERE groupId = ?",
                       arguments: [primaryItemID?.uuidString, group.id.uuidString])
    }

    struct StoredDecision {
        let id: UUID
        let status: DuplicateGroup.Status
        let primaryItemID: UUID?
    }

    /// A decision covers unchanged survivors of the reviewed snapshot, never a new
    /// arrival or changed source version. Most recent applicable decision wins, so
    /// explicit Undo/pending snapshots supersede earlier keep/dismiss choices.
    static func latestDecision(for group: DuplicateGroup, in db: Database) throws -> StoredDecision? {
        guard let key = group.evidenceKey, let items = group.evidence?.items, !items.isEmpty else { return nil }
        let current = Set(items.map(decisionIdentity))
        let rows = try Row.fetchCursor(db, sql: """
            SELECT id, status, primaryItemId, membersJSON FROM duplicate_review_decisions
            WHERE evidenceKey = ? ORDER BY createdAt DESC, rowid DESC
            """, arguments: [key])
        while let row = try rows.next() {
            let encoded: String = row["membersJSON"]
            guard let previous = try? JSONDecoder().decode([DuplicateItemEvidence].self, from: Data(encoded.utf8)),
                  current.isSubset(of: Set(previous.map(decisionIdentity))),
                  let rawID: String = row["id"], let id = UUID(uuidString: rawID),
                  let rawStatus: String = row["status"], let status = DuplicateGroup.Status(rawValue: rawStatus) else { continue }
            let primary: String? = row["primaryItemId"]
            return StoredDecision(id: id, status: status, primaryItemID: primary.flatMap(UUID.init(uuidString:)))
        }
        return nil
    }

    private static func decisionIdentity(_ item: DuplicateItemEvidence) -> DuplicateItemEvidence {
        // Enriching a thumbnail cache does not change the reviewed files or sources.
        var identity = item
        identity.files = item.files.map { file in
            var identity = file
            identity.visual?.luminanceSketch = nil
            return identity
        }
        return identity
    }

    static func decision(for group: DuplicateGroup, in db: Database) throws -> (DuplicateGroup.Status, UUID?)? {
        try latestDecision(for: group, in: db).map { ($0.status, $0.primaryItemID) }
    }
}
