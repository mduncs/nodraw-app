import Foundation
import GRDB
import CryptoKit

/// Review does not combine records or reclaim disk space. Its only item mutation is a
/// recoverable deletion flag; assets, sidecars, annotations and references remain owned
/// by their original item. One SQLite transaction owns both the decision and its history.
enum TriageDecision: String, Codable, Sendable {
    case keepSelected, keepAll, notDuplicates, later

    var title: String {
        switch self {
        case .keepSelected: return "Keep selected copies"
        case .keepAll: return "Keep all copies"
        case .notDuplicates: return "Not duplicates"
        case .later: return "Review later"
        }
    }
}

struct DuplicateReviewMember: Codable, Equatable, Sendable {
    let id: UUID
    let fingerprint: String
    let annotationCount: Int
    let boardCount: Int
    let canvasCount: Int
    let fileBytes: Int64
}

struct DuplicateReviewSnapshot: Codable, Equatable, Sendable {
    let groupID: UUID
    let groupUpdatedAt: Date
    let previousStatus: String
    let previousPrimaryID: UUID?
    let method: String
    let similarity: Float
    let createdAt: Date
    let members: [DuplicateReviewMember]
    let evidenceKey: String?
    let evidence: DuplicateEvidence?
    var itemIDs: [UUID] { members.map(\.id) }
    var group: DuplicateGroup {
        DuplicateGroup(id: groupID, itemIds: itemIDs, primaryItemId: previousPrimaryID,
                       status: DuplicateGroup.Status(rawValue: previousStatus) ?? .pending,
                       detectionMethod: DuplicateGroup.DetectionMethod(rawValue: method) ?? .perceptualHash,
                       similarity: similarity, createdAt: createdAt, updatedAt: groupUpdatedAt,
                       evidenceKey: evidenceKey, evidence: evidence)
    }
}

struct DuplicateReviewDetail {
    let snapshot: DuplicateReviewSnapshot
    let items: [MediaItem]
}

struct DuplicateReviewRequest: Codable, Equatable, Sendable {
    let id: UUID
    let snapshot: DuplicateReviewSnapshot
    let decision: TriageDecision
    let keptIDs: Set<UUID>
    init(id: UUID = UUID(), snapshot: DuplicateReviewSnapshot, decision: TriageDecision, keptIDs: Set<UUID>) {
        self.id = id; self.snapshot = snapshot; self.decision = decision; self.keptIDs = keptIDs
    }
    var rejectedIDs: [UUID] {
        decision == .keepSelected ? snapshot.itemIDs.filter { !keptIDs.contains($0) } : []
    }
}

struct DuplicateReviewHistoryEntry: Identifiable, Sendable {
    let id: UUID
    let title: String
    let date: Date
    let movedCount: Int
    let isUndone: Bool
}

protocol DuplicateReviewServicing: Sendable {
    func fetchGroups(includeLater: Bool, exactOnly: Bool?) async throws -> [DuplicateGroup]
    func load(groupID: UUID) async throws -> DuplicateReviewDetail
    func apply(_ request: DuplicateReviewRequest) async throws
    func undo(_ operationID: UUID) async throws
    func redo(_ operationID: UUID) async throws
    func history() async throws -> [DuplicateReviewHistoryEntry]
}

actor DuplicateReviewService: DuplicateReviewServicing {
    enum ReviewError: LocalizedError {
        case changed, invalidSelection, unavailable, conflict
        var errorDescription: String? {
            switch self {
            case .changed: return "These copies changed while you were reviewing them. Nothing was moved. Reload this group and review the current items."
            case .invalidSelection: return "Choose at least one item to keep. Only items in this group can be selected."
            case .unavailable: return "This review is no longer available. Reload the queue."
            case .conflict: return "This decision cannot be changed because its items or review state were changed elsewhere. Reload to inspect their current state; no items were changed."
            }
        }
    }

    private let database: DatabaseManager
    private let mediaStore: MediaStore
    init(database: DatabaseManager, mediaStore: MediaStore) {
        self.database = database; self.mediaStore = mediaStore
    }

    static func migrate(_ db: Database) throws {
        // No cascading foreign keys: history must survive later explicit purges.
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS duplicate_review_history (
                id TEXT PRIMARY KEY, groupId TEXT NOT NULL, requestJSON TEXT NOT NULL,
                appliedAt DATETIME NOT NULL, undoneAt DATETIME,
                committedGroupAt DATETIME NOT NULL, ledgerDecisionID TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_duplicate_review_history_group
                ON duplicate_review_history(groupId, appliedAt);
            """)
    }

    func fetchGroups(includeLater: Bool = false, exactOnly: Bool? = nil) async throws -> [DuplicateGroup] {
        try await database.read { db in
            let categoryCondition = exactOnly.map { $0 ? "AND detectionMethod = 'exactDuplicate'" : "AND detectionMethod != 'exactDuplicate'" } ?? ""
            let records = try DuplicateGroupRecord.fetchAll(db, sql: """
                SELECT * FROM duplicate_groups WHERE status = ? AND isCurrent = 1 \(categoryCondition)
                  AND (SELECT COUNT(*) FROM duplicate_group_members gm JOIN media_items mi ON mi.id = gm.itemId
                       WHERE gm.groupId = duplicate_groups.id AND COALESCE(mi.deletedAt, '') = '') >= 2
                  AND NOT EXISTS (SELECT 1 FROM duplicate_group_members gm JOIN media_items mi ON mi.id = gm.itemId
                                  WHERE gm.groupId = duplicate_groups.id AND COALESCE(mi.deletedAt, '') != '')
                ORDER BY CASE WHEN detectionMethod = 'exactDuplicate' THEN 0 ELSE 1 END, createdAt, id
                LIMIT 200
                """, arguments: [includeLater ? "reviewed" : "pending"])
            return try records.compactMap { record in
                let ids = try DuplicateGroupMemberRecord.fetchItemIds(db: db, groupId: record.id)
                guard let group = record.toDuplicateGroup(itemIds: ids), group.hasVerifiedEvidence,
                      Set(group.evidence?.items.map(\.itemID) ?? []) == Set(ids) else { return nil }
                return group
            }
        }
    }

    func load(groupID: UUID) async throws -> DuplicateReviewDetail {
        try await database.read { db in
            guard let group = try DuplicateGroupRecord.fetch(db: db, id: groupID) else { throw ReviewError.unavailable }
            let ids = try DuplicateGroupMemberRecord.fetchItemIds(db: db, groupId: groupID).sorted { $0.uuidString < $1.uuidString }
            guard ids.count >= 2 else { throw ReviewError.unavailable }
            let assets = try ItemAssetStore.fetchBatch(in: db, itemIDs: ids)
            var items: [MediaItem] = []
            var members: [DuplicateReviewMember] = []
            for id in ids {
                guard let record = try MediaItemRecord.fetchOne(db, sql: "SELECT * FROM media_items WHERE id = ? AND COALESCE(deletedAt, '') = ''", arguments: [id.uuidString]),
                      var item = record.toMediaItem() else { throw ReviewError.changed }
                item.assets = assets[id] ?? []
                members.append(try Self.member(db, item: item))
                items.append(item)
            }
            return DuplicateReviewDetail(snapshot: DuplicateReviewSnapshot(groupID: groupID, groupUpdatedAt: group.updatedAt, previousStatus: group.status, previousPrimaryID: group.primaryItemId, method: group.detectionMethod, similarity: group.similarity, createdAt: group.createdAt, members: members, evidenceKey: group.evidenceKey, evidence: group.toDuplicateGroup(itemIds: ids)?.evidence), items: items)
        }
    }

    func apply(_ request: DuplicateReviewRequest) async throws {
        let alreadyApplied = try await database.read { db -> Bool in
            guard let row = try Row.fetchOne(db, sql: "SELECT requestJSON, undoneAt FROM duplicate_review_history WHERE id = ?", arguments: [request.id.uuidString]) else { return false }
            let undone: Date? = row["undoneAt"]
            guard try Self.decode(row["requestJSON"]) == request, undone == nil else { throw ReviewError.conflict }
            return true
        }
        if alreadyApplied { return }
        try await DuplicateEvidenceService.revalidate(request.snapshot.group, db: database)
        let changed = try await database.write { db -> Bool in
            // A retried UI/network task cannot apply a second deletion or replace history.
            if let existing = try Row.fetchOne(db, sql: "SELECT requestJSON, undoneAt FROM duplicate_review_history WHERE id = ?", arguments: [request.id.uuidString]) {
                let json: String = existing["requestJSON"]
                let undone: Date? = existing["undoneAt"]
                guard try Self.decode(json) == request, undone == nil else { throw ReviewError.conflict }
                return false
            }
            try Self.validate(db, request: request, expectApplied: false)
            let now = Date()
            try Self.setApplied(db, request: request, at: now)
            let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            try db.execute(sql: "INSERT INTO duplicate_review_history(id, groupId, requestJSON, appliedAt, committedGroupAt, ledgerDecisionID) VALUES (?, ?, ?, ?, ?, ?)", arguments: [request.id.uuidString, request.snapshot.groupID.uuidString, json, now, now, request.id.uuidString])
            return true
        }
        if changed { await didChange(request.snapshot.itemIDs) }
    }

    func undo(_ operationID: UUID) async throws {
        if let request = try await requestForTransition(operationID, undo: true) {
            try await DuplicateEvidenceService.revalidate(request.snapshot.group, db: database, allowingDeleted: true)
        }
        let ids = try await database.write { db -> [UUID] in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM duplicate_review_history WHERE id = ?", arguments: [operationID.uuidString]) else { throw ReviewError.unavailable }
            let undone: Date? = row["undoneAt"]
            if undone != nil { return [] }
            let request = try Self.decode(row["requestJSON"])
            let ledgerID: String = row["ledgerDecisionID"]
            try Self.validateHistory(db, request: request, ledgerID: ledgerID)
            try Self.restoreMembershipForUndo(db, request: request)
            try Self.validate(db, request: request, expectApplied: true, checkOriginalGroup: false)
            for id in request.rejectedIDs {
                try db.execute(sql: "UPDATE media_items SET deletedAt = NULL, deletionReason = NULL WHERE id = ?", arguments: [id.uuidString])
            }
            let now = Date()
            let undoID = UUID()
            try Self.undoPairDecision(db, request: request, id: undoID)
            try Self.setGroup(db, request: request, status: request.snapshot.previousStatus, primaryID: request.snapshot.previousPrimaryID, at: now)
            try db.execute(sql: "UPDATE duplicate_review_history SET undoneAt = ?, committedGroupAt = ?, ledgerDecisionID = ? WHERE id = ?", arguments: [now, now, undoID.uuidString, operationID.uuidString])
            return request.snapshot.itemIDs
        }
        if !ids.isEmpty { await didChange(ids) }
    }

    func redo(_ operationID: UUID) async throws {
        if let request = try await requestForTransition(operationID, undo: false) {
            try await DuplicateEvidenceService.revalidate(request.snapshot.group, db: database)
        }
        let ids = try await database.write { db -> [UUID] in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM duplicate_review_history WHERE id = ?", arguments: [operationID.uuidString]) else { throw ReviewError.unavailable }
            let undone: Date? = row["undoneAt"]
            if undone == nil { return [] }
            let request = try Self.decode(row["requestJSON"])
            let ledgerID: String = row["ledgerDecisionID"]
            try Self.validateHistory(db, request: request, ledgerID: ledgerID)
            try Self.validate(db, request: request, expectApplied: false, checkOriginalGroup: false)
            let now = Date()
            try Self.setApplied(db, request: request, at: now)
            try db.execute(sql: "UPDATE duplicate_review_history SET undoneAt = NULL, committedGroupAt = ?, ledgerDecisionID = ? WHERE id = ?", arguments: [now, request.id.uuidString, operationID.uuidString])
            return request.snapshot.itemIDs
        }
        if !ids.isEmpty { await didChange(ids) }
    }

    func history() async throws -> [DuplicateReviewHistoryEntry] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM duplicate_review_history ORDER BY appliedAt DESC LIMIT 50").map { row in
                let request = try Self.decode(row["requestJSON"])
                let undone: Date? = row["undoneAt"]
                return DuplicateReviewHistoryEntry(id: request.id, title: request.decision.title, date: row["appliedAt"], movedCount: request.rejectedIDs.count, isUndone: undone != nil)
            }
        }
    }

    private func requestForTransition(_ id: UUID, undo: Bool) async throws -> DuplicateReviewRequest? {
        try await database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT requestJSON, undoneAt FROM duplicate_review_history WHERE id = ?", arguments: [id.uuidString]) else { throw ReviewError.unavailable }
            let undone: Date? = row["undoneAt"]
            guard (undone == nil) == undo else { return nil }
            return try Self.decode(row["requestJSON"])
        }
    }

    private static func decode(_ json: String) throws -> DuplicateReviewRequest {
        try JSONDecoder().decode(DuplicateReviewRequest.self, from: Data(json.utf8))
    }

    private static func validateHistory(_ db: Database, request: DuplicateReviewRequest, ledgerID: String) throws {
        // A later decision on the scanner's survivor subset is still a later decision
        // on this group; matching only the original full snapshot would miss it.
        let latest = try String.fetchOne(db, sql: "SELECT id FROM duplicate_review_decisions WHERE groupId = ? ORDER BY createdAt DESC, rowid DESC LIMIT 1", arguments: [request.snapshot.groupID.uuidString])
        guard latest == ledgerID else { throw ReviewError.conflict }
    }

    private static func restoreMembershipForUndo(_ db: Database, request: DuplicateReviewRequest) throws {
        let snapshot = request.snapshot
        let currentIDs = Set(try DuplicateGroupMemberRecord.fetchItemIds(db: db, groupId: snapshot.groupID))
        let originalIDs = Set(snapshot.itemIDs)
        let survivors = originalIDs.subtracting(request.rejectedIDs)
        guard currentIDs == originalIDs || currentIDs == survivors else { throw ReviewError.conflict }
        // A normal scan can republish a keep-many group's surviving subset. Restore
        // only that exact operation-owned shape, never overwrite an arrival or decision.
        guard try DuplicateGroupRecord.fetch(db: db, id: snapshot.groupID) != nil else { throw ReviewError.conflict }
        try DuplicateGroupRecord(from: snapshot.group).upsert(db: db)
        try DuplicateGroupMemberRecord.deleteAll(db: db, groupId: snapshot.groupID)
        for id in snapshot.itemIDs {
            try DuplicateGroupMemberRecord(groupId: snapshot.groupID, itemId: id,
                isPrimary: id == snapshot.previousPrimaryID).insert(db: db)
        }
    }

    private static func validate(_ db: Database, request: DuplicateReviewRequest, expectApplied: Bool, checkOriginalGroup: Bool = true) throws {
        let snapshot = request.snapshot
        try DuplicateEvidenceService.validateSnapshot(snapshot.group, in: db, allowingDeleted: expectApplied)
        let ids = Set(snapshot.itemIDs)
        guard ids.count >= 2, !request.keptIDs.isEmpty, request.keptIDs.isSubset(of: ids) else { throw ReviewError.invalidSelection }
        guard let group = try DuplicateGroupRecord.fetch(db: db, id: snapshot.groupID),
              Set(try DuplicateGroupMemberRecord.fetchItemIds(db: db, groupId: snapshot.groupID)) == ids else { throw ReviewError.changed }
        if checkOriginalGroup {
            guard abs(group.updatedAt.timeIntervalSince(snapshot.groupUpdatedAt)) < 0.001,
                  group.status == snapshot.previousStatus,
                  group.status == "pending" || group.status == "reviewed" else { throw ReviewError.changed }
        }
        for expected in snapshot.members {
            guard let record = try MediaItemRecord.fetchOne(db, sql: "SELECT * FROM media_items WHERE id = ?", arguments: [expected.id.uuidString]), let item = record.toMediaItem() else { throw ReviewError.changed }
            if expectApplied && request.rejectedIDs.contains(expected.id) {
                guard record.deletedAt != nil, record.deletionReason == "duplicateReview:\(request.id.uuidString)" else { throw ReviewError.conflict }
            } else if record.deletedAt != nil { throw ReviewError.changed }
            guard try member(db, item: item).fingerprint == expected.fingerprint else { throw ReviewError.changed }
        }
    }

    private static func setApplied(_ db: Database, request: DuplicateReviewRequest, at date: Date) throws {
        for id in request.rejectedIDs {
            try db.execute(sql: "UPDATE media_items SET deletedAt = ?, deletionReason = ? WHERE id = ?", arguments: [date, "duplicateReview:\(request.id.uuidString)", id.uuidString])
        }
        let status = request.decision == .notDuplicates ? "dismissed" : request.decision == .later ? "reviewed" : "resolved"
        let primary = request.decision == .keepSelected ? request.keptIDs.sorted { $0.uuidString < $1.uuidString }.first : request.snapshot.previousPrimaryID
        try recordPairDecision(db, request: request, at: date)
        try setGroup(db, request: request, status: status, primaryID: primary, at: date)
    }

    private static func setGroup(_ db: Database, request: DuplicateReviewRequest, status: String, primaryID: UUID?, at date: Date) throws {
        try db.execute(sql: "UPDATE duplicate_groups SET status = ?, primaryItemId = ?, updatedAt = ?, isCurrent = 1 WHERE id = ?", arguments: [status, primaryID?.uuidString, date, request.snapshot.groupID.uuidString])
        try db.execute(sql: "UPDATE duplicate_group_members SET isPrimary = (itemId = ?) WHERE groupId = ?", arguments: [primaryID?.uuidString ?? "", request.snapshot.groupID.uuidString])
    }

    // Detector-ledger integration is intentionally isolated from item mutation logic.
    private static func recordPairDecision(_ db: Database, request: DuplicateReviewRequest, at date: Date) throws {
        let status: DuplicateGroup.Status = request.decision == .notDuplicates ? .dismissed : request.decision == .later ? .reviewed : .resolved
        let primary = request.decision == .keepSelected ? request.keptIDs.sorted { $0.uuidString < $1.uuidString }.first : request.snapshot.previousPrimaryID
        try DuplicateEvidencePersistence.recordDecision(request.snapshot.group, status: status, primaryItemID: primary, decisionID: request.id, in: db)
    }
    private static func undoPairDecision(_ db: Database, request: DuplicateReviewRequest, id: UUID) throws {
        try DuplicateEvidencePersistence.recordDecision(request.snapshot.group,
            status: DuplicateGroup.Status(rawValue: request.snapshot.previousStatus) ?? .pending,
            primaryItemID: request.snapshot.previousPrimaryID, decisionID: id, in: db)
    }

    private static func member(_ db: Database, item: MediaItem) throws -> DuplicateReviewMember {
        // Only user-owned/context state participates: asynchronous OCR/model writes must not
        // invalidate a decision. Full ordered asset paths, edit documents and filesystem
        // identity do participate. Missing files make the decision fail closed.
        let row = try Row.fetchOne(db, sql: "SELECT sourceURL, platform, author, tagsJSON, notes, starred, mediaFilesJSON, contextImageString, metadataFileString FROM media_items WHERE id = ?", arguments: [item.id.uuidString])!
        var fields = Array(row.columnNames.map { column -> String in
            let value: DatabaseValue = row[column]
            return "\(column)=\(value)"
        })
        let annotations = try Row.fetchAll(db, sql: "SELECT id, annotationsJSON, asset_id, association_state FROM annotations WHERE itemId = ? ORDER BY id", arguments: [item.id.uuidString])
        fields.append(contentsOf: annotations.map { $0.description })
        let boardRows = try Row.fetchAll(db, sql: "SELECT boardId, position FROM board_memberships WHERE itemId = ? ORDER BY boardId", arguments: [item.id.uuidString])
        let canvasRows = try Row.fetchAll(db, sql: "SELECT id, canvasId, x, y, width, height, zIndex, rotation FROM canvas_placements WHERE mediaItemId = ? ORDER BY id", arguments: [item.id.uuidString])
        fields.append(contentsOf: boardRows.map { $0.description })
        fields.append(contentsOf: canvasRows.map { $0.description })
        var bytes: Int64 = 0
        let urls = item.mediaFiles + (item.contextImage.map { [$0] } ?? [])
        guard !urls.isEmpty else { throw ReviewError.changed }
        for url in urls {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = attrs[.size] as? NSNumber,
                  let modified = attrs[.modificationDate] as? Date else { throw ReviewError.changed }
            bytes += size.int64Value
            fields.append("\(url.path)|\(size)|\(modified.timeIntervalSince1970)|\(try DuplicateFileVersion.read(url))")
        }
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
        return DuplicateReviewMember(id: item.id, fingerprint: digest, annotationCount: annotations.count, boardCount: boardRows.count, canvasCount: canvasRows.count, fileBytes: bytes)
    }

    private func didChange(_ ids: [UUID]) async {
        await mediaStore.didCommitDuplicateReview(itemIDs: ids)
        await MainActor.run { NotificationCenter.default.post(name: .duplicateGroupsDidChange, object: nil) }
    }
}

struct DuplicateTriageUndoAction: UndoableAction {
    let operationID: UUID
    let description: String
    let service: any DuplicateReviewServicing
    func execute() async throws { try await service.redo(operationID) }
    func undo() async throws { try await service.undo(operationID) }
}
