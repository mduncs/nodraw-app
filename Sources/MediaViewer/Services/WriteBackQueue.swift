import Foundation
import GRDB

/// SQLite owns pending intent; enqueue only wakes the debounced projection worker.
/// Failed IO and interrupted in-flight revisions remain retryable across restart.
actor WriteBackQueue {
    private var debounceTask: Task<Void, Never>?
    private var flushing = false
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    private let database: DatabaseManager
    private let selfWriteTracker: SelfWriteTracker

    init(database: DatabaseManager, selfWriteTracker: SelfWriteTracker) {
        self.database = database
        self.selfWriteTracker = selfWriteTracker
        Task { [weak self] in await self?.resume() }
    }

    deinit { debounceTask?.cancel() }

    func resume() { scheduleFlush(after: .seconds(1.5)) }
    func enqueue(_ itemId: UUID) { scheduleFlush(after: .seconds(1.5)) }
    func enqueue(_ itemIds: [UUID]) { scheduleFlush(after: .seconds(1.5)) }

    func isPending(_ itemId: UUID) async -> Bool {
        do {
            return try await database.read { db in
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM metadata_outbox WHERE itemID = ? AND state != 'synced')", arguments: [itemId.uuidString]) ?? false
            }
        } catch {
            // A failed query must not authorize overwriting potentially pending data.
            return true
        }
    }

    func statuses(itemID: UUID? = nil) async throws -> [MetadataOutbox.Status] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT o.*, mi.metadataFileString FROM metadata_outbox o JOIN media_items mi ON mi.id = o.itemID
                WHERE o.state != 'synced'
                \(itemID == nil ? "" : "AND o.itemID = ?") ORDER BY o.revision
                """, arguments: itemID.map { StatementArguments([$0.uuidString]) } ?? StatementArguments())
            return rows.map { MetadataOutbox.Status(itemID: $0["itemID"], metadataPath: $0["metadataFileString"], field: $0["field"], revision: $0["revision"], state: $0["state"], error: $0["error"], externalJSON: $0["externalJSON"], baseJSON: $0["baseJSON"], desiredJSON: $0["desiredJSON"]) }
        }
    }

    /// Retry failed publication without discarding any conflict evidence.
    func retry() async {
        scheduleFlush(after: .zero)
    }

    /// An explicit resolution always names the revision shown to the user.
    /// A stale decision cannot clear a newer edit/conflict. History is retained.
    func resolveConflict(itemID: UUID, field: String, revision: Int64, keepLocal: Bool) async throws {
        if field == "annotated" && !keepLocal {
            throw NSError(domain: "MetadataProjection", code: 2, userInfo: [NSLocalizedDescriptionKey: "The file's annotation flag cannot replace or remove local annotation assets"])
        }
        try await database.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT o.*, mi.metadataFileString FROM metadata_outbox o JOIN media_items mi ON mi.id = o.itemID
                WHERE o.itemID = ? AND o.field = ? AND o.revision = ? AND o.state = 'conflict'
                """, arguments: [itemID.uuidString, field, revision]) else { return }
            let path: String = row["metadataFileString"]
            try FrontmatterWriter.withLockedSidecar(at: URL(fileURLWithPath: path)) { target in
            let content = try String(contentsOf: target, encoding: .utf8)
            var externalJSON = "null"
            _ = try FrontmatterWriter.processContent(content) { yaml in
                externalJSON = try Self.normalizedJSON(field: field, yaml: yaml)
            }
            try db.execute(sql: "UPDATE metadata_projection_clock SET revision = revision + 1 WHERE id = 1")
            let shownExternal: String = row["externalJSON"] ?? "null"
            if externalJSON != (try Self.canonicalJSON(shownExternal)) {
                // The user chose between the displayed versions, not a third
                // version written since. Retain it as a fresh reviewable conflict.
                try db.execute(sql: """
                    UPDATE metadata_outbox SET revision = (SELECT revision FROM metadata_projection_clock WHERE id = 1),
                        externalJSON = ?, error = 'The file changed again; review its latest value'
                    WHERE itemID = ? AND field = ? AND revision = ?
                    """, arguments: [externalJSON, itemID.uuidString, field, revision])
                try db.execute(sql: """
                    INSERT OR IGNORE INTO metadata_projection_conflicts(itemID, field, revision, baseJSON, desiredJSON, externalJSON)
                    SELECT itemID, field, revision, baseJSON, desiredJSON, externalJSON FROM metadata_outbox WHERE itemID = ? AND field = ?
                    """, arguments: [itemID.uuidString, field])
                return
            }
            if !keepLocal {
                try MetadataOutbox.importing(in: db) {
                    switch field {
                    case "tags":
                        try db.execute(sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?", arguments: [externalJSON, itemID.uuidString])
                    case "notes":
                        try db.execute(sql: "UPDATE media_items SET notes = json_extract(?, '$') WHERE id = ?", arguments: [externalJSON, itemID.uuidString])
                    case "starred":
                        try db.execute(sql: "UPDATE media_items SET starred = ? WHERE id = ?", arguments: [externalJSON == "true", itemID.uuidString])
                    case "deleted":
                        if externalJSON == "false",
                           try String.fetchOne(db, sql: "SELECT deletionReason FROM media_items WHERE id = ?", arguments: [itemID.uuidString]) == MediaItemDeletionReason.combined.rawValue {
                            throw NSError(domain: "MetadataProjection", code: 1, userInfo: [NSLocalizedDescriptionKey: "Combined items cannot be restored from a metadata flag"])
                        }
                        try db.execute(sql: "UPDATE media_items SET deletedAt = CASE WHEN ? THEN COALESCE(deletedAt, CURRENT_TIMESTAMP) ELSE NULL END WHERE id = ?", arguments: [externalJSON == "true", itemID.uuidString])
                    default: break // annotated describes local assets; never delete those from a sidecar flag
                    }
                    // Keep normalized lookup and FTS indexes in step with every
                    // accepted external field, including searchable notes.
                    if let record = try MediaItemRecord.fetchOne(db, key: itemID.uuidString) { try record.updateWithFTSSync(db: db) }
                }
            }
            try db.execute(sql: """
                UPDATE metadata_outbox SET revision = (SELECT revision FROM metadata_projection_clock WHERE id = 1),
                    baseJSON = ?, desiredJSON = CASE WHEN ? THEN desiredJSON ELSE ? END,
                    state = ?, error = NULL, externalJSON = NULL WHERE itemID = ? AND field = ? AND revision = ?
                """, arguments: [externalJSON, keepLocal, externalJSON, keepLocal ? "pending" : "synced", itemID.uuidString, field, revision])
            }
        }
        scheduleFlush(after: .zero)
    }

    func flushNow() async {
        debounceTask?.cancel()
        debounceTask = nil
        // Shutdown and explicit flushes must not wait forever for an unopened DB.
        // The durable outbox is picked up automatically when initialization succeeds.
        guard await database.isInitialized else {
            scheduleFlush(after: .zero)
            return
        }
        if flushing {
            await withCheckedContinuation { continuation in flushWaiters.append(continuation) }
        }
        await flush()
    }

    /// Explicit one-time legacy enrichment projection, not a blanket migration.
    /// Commit its snapshots before marking the maintenance operation complete.
    func persistBackfill(_ itemIDs: [UUID]) async throws {
        try await database.write { db in
            for id in itemIDs {
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT mi.*, EXISTS(SELECT 1 FROM annotations a WHERE a.itemId = mi.id) AS annotated
                    FROM media_items mi WHERE id = ?
                    """, arguments: [id.uuidString]) else { continue }
                // A stale backfill selection must not publish an internal context retirement.
                if (row["deletionReason"] as String?) == MediaItemDeletionReason.contextReattached.rawValue { continue }
                let path: String = row["metadataFileString"]
                let content = try? String(contentsOfFile: path, encoding: .utf8)
                var existing: [String: Any] = [:]
                if let content {
                    _ = try FrontmatterWriter.processContent(content) { existing = $0 }
                }
                let desired: [String: String] = [
                    "tags": row["tagsJSON"] ?? "[]",
                    "notes": try Self.encode((row["notes"] as String?) ?? NSNull() as Any),
                    "starred": (row["starred"] as Bool? ?? false) ? "true" : "false",
                    "deleted": (row["deletedAt"] as String?).map { !$0.isEmpty } == true ? "true" : "false",
                    "annotated": (row["annotated"] as Bool? ?? false) ? "true" : "false"
                ]
                for (field, value) in desired {
                    let base = try Self.normalizedJSON(field: field, yaml: existing)
                    guard base != value else { continue }
                    try db.execute(sql: "UPDATE metadata_projection_clock SET revision = revision + 1 WHERE id = 1")
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO metadata_outbox(itemID, field, revision, baseJSON, desiredJSON)
                        VALUES (?, ?, (SELECT revision FROM metadata_projection_clock WHERE id = 1), ?, ?)
                        """, arguments: [id.uuidString, field, base, value])
                }
            }
        }
        scheduleFlush(after: .seconds(1.5))
    }

    private func scheduleFlush(after delay: Duration) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, database] in
            do {
                guard await database.waitUntilInitialized(), !Task.isCancelled else { return }
                try await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.flush()
            } catch {}
        }
    }

    private func flush() async {
        guard await database.isInitialized else {
            scheduleFlush(after: .zero)
            return
        }
        guard !flushing else { return }
        flushing = true
        defer {
            flushing = false
            let waiters = flushWaiters
            flushWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        do {
            let intents = try await database.write { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT o.*, mi.metadataFileString FROM metadata_outbox o
                    JOIN media_items mi ON mi.id = o.itemID
                    WHERE o.state NOT IN ('synced', 'conflict')
                    ORDER BY o.revision LIMIT 256
                    """)
                let intents = rows.map { MetadataOutbox.Intent(itemID: $0["itemID"], path: $0["metadataFileString"], field: $0["field"], revision: $0["revision"], baseJSON: $0["baseJSON"], desiredJSON: $0["desiredJSON"]) }
                for intent in intents {
                    try db.execute(sql: "UPDATE metadata_outbox SET state = 'inFlight' WHERE itemID = ? AND field = ? AND revision = ?", arguments: [intent.itemID, intent.field, intent.revision])
                }
                return intents
            }
            for group in Dictionary(grouping: intents, by: \.itemID).values {
                await publish(group)
            }
            let remaining = try await database.read { db in
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM metadata_outbox WHERE state NOT IN ('synced', 'conflict'))") ?? false
            }
            // Low-frequency recovery also catches transactions whose caller
            // never reached enqueue (including annotation stores without a queue).
            scheduleFlush(after: remaining ? .seconds(5) : .seconds(30))
        } catch {
            logError("WriteBackQueue: durable projection failed: \(error.localizedDescription)")
            scheduleFlush(after: .seconds(5))
        }
    }

    private struct Publication: Sendable {
        let content: String
        let applied: [MetadataOutbox.Intent]
        let conflicts: [(MetadataOutbox.Intent, String)]
    }

    private func publish(_ intents: [MetadataOutbox.Intent]) async {
        guard let first = intents.first else { return }
        do {
            let result = try await Task.detached(priority: .utility) {
                var applied: [MetadataOutbox.Intent] = []
                var conflicts: [(MetadataOutbox.Intent, String)] = []
                let content = try FrontmatterWriter.processFrontmatter(at: URL(fileURLWithPath: first.path)) { yaml in
                    for intent in intents {
                        let current = try Self.normalizedJSON(field: intent.field, yaml: yaml)
                        let base = try Self.canonicalJSON(intent.baseJSON)
                        let desired = try Self.canonicalJSON(intent.desiredJSON)
                        guard current == base || current == desired else {
                            conflicts.append((intent, current))
                            continue
                        }
                        // Yams requires Swift-native representable values, not
                        // Foundation's private NSString/NSNumber subclasses.
                        let data = Data(desired.utf8)
                        switch intent.field {
                        case "tags": yaml[intent.field] = try JSONDecoder().decode([String].self, from: data)
                        case "notes":
                            if let notes = try JSONDecoder().decode(String?.self, from: data) {
                                yaml[intent.field] = notes
                            } else if yaml["description"] != nil {
                                yaml[intent.field] = ""
                            } else { yaml.removeValue(forKey: intent.field) }
                        default:
                            if try JSONDecoder().decode(Bool.self, from: data) {
                                yaml[intent.field] = true
                            } else if intent.field == "starred", yaml["favorite"] != nil {
                                yaml[intent.field] = false
                            } else { yaml.removeValue(forKey: intent.field) }
                        }
                        if intent.field == "notes" { yaml.removeValue(forKey: "notes_trimmed") }
                        applied.append(intent)
                    }
                }
                return Publication(content: content, applied: applied, conflicts: conflicts)
            }.value
            await selfWriteTracker.markPublished(first.path, content: result.content)
            try await database.write { db in
                for intent in result.applied { try MetadataOutbox.acknowledge(intent, in: db) }
                for (intent, current) in result.conflicts {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO metadata_projection_conflicts(itemID, field, revision, baseJSON, desiredJSON, externalJSON)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [intent.itemID, intent.field, intent.revision, intent.baseJSON, intent.desiredJSON, current])
                    try db.execute(sql: """
                        UPDATE metadata_outbox SET state = 'conflict', error = 'This field also changed in the metadata file', externalJSON = ?
                        WHERE itemID = ? AND field = ? AND revision = ?
                        """, arguments: [current, intent.itemID, intent.field, intent.revision])
                }
            }
        } catch {
            logError("WriteBackQueue: \(first.path): \(error.localizedDescription)")
            let message = error.localizedDescription
            do {
                try await database.write { db in
                    for intent in intents {
                        try db.execute(sql: """
                            UPDATE metadata_outbox SET state = 'retry', error = ?
                            WHERE itemID = ? AND field = ? AND revision = ?
                            """, arguments: [message, intent.itemID, intent.field, intent.revision])
                    }
                }
            } catch { logError("WriteBackQueue: unable to persist failure: \(error.localizedDescription)") }
        }
    }

    private nonisolated static func encode(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }

    private nonisolated static func canonicalJSON(_ json: String) throws -> String {
        try encode(JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]))
    }

    private nonisolated static func normalizedJSON(field: String, yaml: [String: Any]) throws -> String {
        let values = MetadataParser.userValues(yaml)
        switch field {
        case "tags": return try encode(values.tags)
        case "notes":
            return try encode(values.notes.flatMap { $0.isEmpty ? nil : $0 } ?? NSNull() as Any)
        case "starred": return try encode(values.starred)
        default: return try encode(yaml[field] as? Bool ?? false)
        }
    }
}
