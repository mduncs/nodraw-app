import Foundation
import GRDB

struct VisionPendingJob: Sendable {
    let itemId: UUID
    let priority: JobPriority
    let revision: Int
    let sequence: Int64
}

/// Storage seam for exercising the production queue with deterministic suspended IO.
protocol VisionQueueStorage: Sendable {
    func enqueue(_ itemId: UUID, priority: JobPriority) async throws -> VisionPendingJob?
    func seedIncomplete() async throws -> Int
    func load(limit: Int, excluding: Set<UUID>) async throws -> [VisionPendingJob]
    func cancel(_ itemId: UUID) async throws
    func clear(excluding: Set<UUID>) async throws
    func finish(_ job: VisionPendingJob, succeeded: Bool) async throws
    func contains(_ itemId: UUID) async throws -> Bool
}

struct DatabaseVisionQueueStorage: VisionQueueStorage {
    let database: DatabaseManager

    func enqueue(_ itemId: UUID, priority: JobPriority) async throws -> VisionPendingJob? {
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO vision_pending_jobs(item_id, priority)
                SELECT id, ? FROM media_items WHERE id = ? AND (deletedAt IS NULL OR deletedAt = '')
                ON CONFLICT(item_id) DO UPDATE SET
                    priority = MAX(priority, excluded.priority), retry_count = 0, revision = revision + 1
                """, arguments: [priority.rawValue, itemId.uuidString])
            return try Row.fetchOne(db, sql: "SELECT item_id, priority, revision, sequence FROM vision_pending_jobs WHERE item_id = ?",
                                    arguments: [itemId.uuidString]).flatMap(Self.job)
        }
    }

    func seedIncomplete() async throws -> Int {
        try await database.write { db in
            // Kept entirely in SQLite: neither restoration nor bulk reprocessing materializes
            // the library's IDs in Swift. Exhausted rows deliberately survive this insertion.
            try db.execute(sql: """
                INSERT OR IGNORE INTO vision_pending_jobs(item_id, priority)
                SELECT id, 0 FROM (\(VisionJobQueue.requeueIncompleteSQL)) ORDER BY id
                """)
            return db.changesCount
        }
    }

    func load(limit: Int, excluding: Set<UUID>) async throws -> [VisionPendingJob] {
        let ids = excluding.map(\.uuidString)
        return try await database.read { db in
            let exclusion = ids.isEmpty ? "" : "AND item_id NOT IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))"
            var arguments = StatementArguments(ids)
            arguments += [limit]
            return try Row.fetchAll(db, sql: """
                SELECT item_id, priority, revision, sequence FROM vision_pending_jobs
                JOIN media_items ON media_items.id = item_id
                WHERE retry_count < 3 AND (deletedAt IS NULL OR deletedAt = '') \(exclusion)
                ORDER BY priority DESC, sequence LIMIT ?
                """, arguments: arguments).compactMap(Self.job)
        }
    }

    func cancel(_ itemId: UUID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM vision_pending_jobs WHERE item_id = ?", arguments: [itemId.uuidString])
        }
    }

    func clear(excluding: Set<UUID>) async throws {
        let ids = excluding.map(\.uuidString)
        try await database.write { db in
            let exclusion = ids.isEmpty ? "" : "WHERE item_id NOT IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))"
            try db.execute(sql: "DELETE FROM vision_pending_jobs \(exclusion)", arguments: StatementArguments(ids))
        }
    }

    func contains(_ itemId: UUID) async throws -> Bool {
        try await database.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM vision_pending_jobs
                JOIN media_items ON media_items.id = item_id
                WHERE item_id = ? AND retry_count < 3 AND (deletedAt IS NULL OR deletedAt = ''))
                """,
                              arguments: [itemId.uuidString]) ?? false
        }
    }

    func finish(_ job: VisionPendingJob, succeeded: Bool) async throws {
        try await database.write { db in
            if succeeded {
                try db.execute(sql: "DELETE FROM vision_pending_jobs WHERE item_id = ? AND revision = ? AND sequence = ?",
                               arguments: [job.itemId.uuidString, job.revision, job.sequence])
            } else {
                try db.execute(sql: "UPDATE vision_pending_jobs SET retry_count = retry_count + 1 WHERE item_id = ? AND revision = ? AND sequence = ?",
                               arguments: [job.itemId.uuidString, job.revision, job.sequence])
            }
        }
    }

    private static func job(_ row: Row) -> VisionPendingJob? {
        guard let id = UUID(uuidString: row["item_id"]), let priority = JobPriority(rawValue: row["priority"]) else { return nil }
        return VisionPendingJob(itemId: id, priority: priority, revision: row["revision"], sequence: row["sequence"])
    }
}

/// Three FIFO lanes keep ordinary admission/dequeue O(1)-amortized. Only bounded,
/// relatively rare promotion/cancellation scans a lane.
struct VisionPendingBuffer {
    private var lanes = (0...2).map { _ in DeduplicatingFIFOBuffer<UUID>() }
    private var jobs: [UUID: VisionPendingJob] = [:]
    var count: Int { jobs.count }
    var isEmpty: Bool { jobs.isEmpty }
    func contains(_ id: UUID) -> Bool { jobs[id] != nil }
    func priority(_ id: UUID) -> JobPriority? { jobs[id]?.priority }

    mutating func append(_ job: VisionPendingJob) {
        if let previous = jobs[job.itemId] {
            if previous.priority == job.priority { jobs[job.itemId] = job; return }
            lanes[previous.priority.rawValue].removeAll { $0 == job.itemId }
        }
        jobs[job.itemId] = job
        lanes[job.priority.rawValue].append(job.itemId)
    }

    mutating func pop(highOnly: Bool = false) -> VisionPendingJob? {
        for index in stride(from: 2, through: highOnly ? 2 : 0, by: -1) {
            if let id = lanes[index].popFirst() { return jobs.removeValue(forKey: id) }
        }
        return nil
    }

    mutating func evictBelow(_ priority: JobPriority) -> Bool {
        for index in 0..<priority.rawValue {
            if let id = lanes[index].popFirst() { jobs.removeValue(forKey: id); return true }
        }
        return false
    }

    mutating func remove(_ id: UUID) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        lanes[job.priority.rawValue].removeAll { $0 == id }
    }

    mutating func removeAll() { self = Self() }
}
