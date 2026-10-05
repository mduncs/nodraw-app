import Foundation
import GRDB

/// Manual, local evidence scan. Full media-set identity and visual suggestions are separate.
/// No semantic embedding all-pairs pass; no scan mutates archive files or review decisions.
actor DuplicateDetector {
    private let db: DatabaseManager
    private var currentDetectionTask: Task<DuplicateScanResult, Error>?
    private var cancellation: DuplicateScanCancellation?
    private var scanID: UUID?
    private(set) var progress: DetectionProgress = .idle
    let minGroupSize = 2

    var hashThreshold: Int {
        let stored = UserDefaults.standard.object(forKey: "duplicateHashThreshold") as? Int ?? 6
        return min(8, max(0, stored))
    }
    /// Retained for old settings callers; semantic vectors no longer produce duplicate groups.
    var vectorThreshold: Float { 0.92 }

    init(db: DatabaseManager = .shared) { self.db = db }

    enum DetectionProgress: Equatable {
        case idle
        case scanning(phase: String, current: Int, total: Int)
        case complete(groupsFound: Int, unavailableItems: Int = 0, changedItems: Int = 0, arrivals: Int = 0)
        case failed(String)
        var displayText: String {
            switch self {
            case .idle: return "Ready"
            case .scanning(let phase, let current, let total): return "\(phase): \(current)/\(total)"
            case .complete(let count, _, _, _):
                return (["Scan complete: \(count) groups to review."] + completionDetails).joined(separator: " ")
            case .failed(let error): return "Failed: \(error)"
            }
        }
        var completionDetails: [String] {
            guard case .complete(_, let unavailable, let changed, let arrivals) = self else { return [] }
            var parts: [String] = []
            if unavailable > 0 { parts.append("\(unavailable) files couldn't be read.") }
            if changed > 0 { parts.append("\(changed) items changed during the scan; their groups were left out.") }
            if arrivals > 0 { parts.append("\(arrivals) new items arrived; scan again to include them.") }
            return parts
        }
        var isScanning: Bool { if case .scanning = self { return true }; return false }
    }

    func getProgress() -> DetectionProgress { progress }

    func cancelDetection() {
        cancellation?.cancel()
        currentDetectionTask?.cancel()
        // Keep ownership until the worker exits, so a new scan cannot overtake cancellation.
    }

    func detectDuplicates() async throws -> Int {
        guard currentDetectionTask == nil else { throw DuplicateEvidenceError.scanAlreadyRunning }
        let identifier = UUID()
        let token = DuplicateScanCancellation()
        let database = db
        let threshold = hashThreshold
        scanID = identifier
        cancellation = token
        progress = .scanning(phase: "Reading archive", current: 0, total: 0)
        let task = Task.detached(priority: .utility) { [weak self] in
            try await DuplicateScan.run(db: database, threshold: threshold, cancellation: token) { value in
                await self?.setProgress(value, for: identifier)
            }
        }
        currentDetectionTask = task
        do {
            let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: {
                token.cancel()
                task.cancel()
            })
            currentDetectionTask = nil
            cancellation = nil
            scanID = nil
            progress = .complete(groupsFound: result.groupsFound, unavailableItems: result.unavailableItems,
                                 changedItems: result.changedItems, arrivals: result.arrivals)
            await notifyGroupsDidChange()
            return result.groupsFound
        } catch {
            currentDetectionTask = nil
            cancellation = nil
            scanID = nil
            progress = error is CancellationError ? .idle : .failed(error.localizedDescription)
            throw error
        }
    }

    /// Cache-backed whole-index reconciliation is deliberate: new arrivals must also match
    /// already-reviewed members, without extending a dismissed group with stale evidence.
    func detectDuplicatesForItems(_ itemIds: [UUID]) async throws -> Int {
        guard !itemIds.isEmpty else { return 0 }
        return try await detectDuplicates()
    }

    private func setProgress(_ value: DetectionProgress, for id: UUID) {
        guard scanID == id else { return }
        progress = value
    }

    func fetchAllGroups(status: DuplicateGroup.Status? = nil) async throws -> [DuplicateGroup] {
        try await db.read { database in
            let predicate = status == nil ? "" : " AND status = ?"
            let records = try DuplicateGroupRecord.fetchAll(database, sql: "SELECT * FROM duplicate_groups WHERE isCurrent = 1\(predicate)",
                arguments: status.map { StatementArguments([$0.rawValue]) } ?? StatementArguments())
            var groups: [DuplicateGroup] = []
            for record in records {
                let ids = try Self.activeMemberIDs(record.id, in: database)
                guard ids.count >= 2, let group = record.toDuplicateGroup(itemIds: ids),
                      group.hasVerifiedEvidence,
                      Set(group.evidence?.items.map(\.itemID) ?? []) == Set(ids) else { continue }
                groups.append(group)
            }
            return groups.sorted { lhs, rhs in
                if lhs.detectionMethod != rhs.detectionMethod { return lhs.detectionMethod == .exactDuplicate }
                if lhs.similarity != rhs.similarity { return lhs.similarity > rhs.similarity }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    func countPendingGroups() async throws -> Int { try await fetchAllGroups(status: .pending).count }

    func updateGroupStatus(_ groupId: UUID, status: DuplicateGroup.Status) async throws {
        try await db.write { database in
            guard let group = try Self.loadGroup(groupId, in: database) else { return }
            try DuplicateEvidencePersistence.recordDecision(group, status: status, primaryItemID: group.primaryItemId, in: database)
        }
        await notifyGroupsDidChange()
    }

    func setPrimaryItem(_ groupId: UUID, itemId: UUID) async throws {
        try await db.write { database in
            guard var group = try Self.loadGroup(groupId, in: database),
                  try Self.activeMemberIDs(groupId, in: database).contains(itemId) else { throw DuplicateEvidenceError.invalidPrimary }
            group.primaryItemId = itemId
            try DuplicateEvidencePersistence.recordDecision(group, status: group.status, primaryItemID: itemId, in: database)
        }
        await notifyGroupsDidChange()
    }

    func removeItemFromGroup(_ groupId: UUID, itemId: UUID) async throws {
        try await removeItemsFromGroup(groupId, itemIds: [itemId])
    }

    func removeItemsFromGroup(_ groupId: UUID, itemIds: [UUID]) async throws {
        let removed = Set(itemIds)
        guard !removed.isEmpty else { return }
        try await db.write { database in
            guard var group = try Self.loadGroup(groupId, in: database) else { return }
            for itemID in removed { try DuplicateGroupMemberRecord.delete(db: database, groupId: groupId, itemId: itemID) }
            group.itemIds.removeAll { removed.contains($0) }
            group.evidence?.items.removeAll { removed.contains($0.itemID) }
            if let primary = group.primaryItemId, !group.itemIds.contains(primary) { group.primaryItemId = group.itemIds.first }
            try DuplicateGroupRecord(from: group).upsert(db: database)
            try database.execute(sql: "UPDATE duplicate_group_members SET isPrimary = CASE WHEN itemId = ? THEN 1 ELSE 0 END WHERE groupId = ?",
                                 arguments: [group.primaryItemId?.uuidString, groupId.uuidString])
            if group.itemIds.count < 2 {
                try database.execute(sql: "UPDATE duplicate_groups SET isCurrent = 0 WHERE id = ?", arguments: [groupId.uuidString])
            }
        }
        await notifyGroupsDidChange()
    }

    func restoreGroup(_ group: DuplicateGroup) async throws {
        try await db.write { database in
            try DuplicateGroupRecord(from: group).upsert(db: database)
            try DuplicateGroupMemberRecord.deleteAll(db: database, groupId: group.id)
            for id in group.itemIds {
                try DuplicateGroupMemberRecord(groupId: group.id, itemId: id, isPrimary: id == group.primaryItemId).insert(db: database)
            }
            try database.execute(sql: "UPDATE duplicate_groups SET isCurrent = ? WHERE id = ?", arguments: [group.hasVerifiedEvidence && group.count >= 2, group.id.uuidString])
            try DuplicateEvidencePersistence.recordDecision(group, status: group.status, primaryItemID: group.primaryItemId, in: database)
        }
        await notifyGroupsDidChange()
    }

    /// Retire a stale result without deleting historical evidence/decisions.
    func deleteGroup(_ groupId: UUID) async throws {
        try await db.write { try $0.execute(sql: "UPDATE duplicate_groups SET isCurrent = 0 WHERE id = ?", arguments: [groupId.uuidString]) }
        await notifyGroupsDidChange()
    }

    /// Clear the current view, not the review history. Rescans recover prior decisions.
    func clearAllGroups() async throws {
        cancelDetection()
        try await db.write { try $0.execute(sql: "UPDATE duplicate_groups SET isCurrent = 0") }
        await notifyGroupsDidChange()
    }

    private nonisolated static func activeMemberIDs(_ groupID: UUID, in db: Database) throws -> [UUID] {
        try String.fetchAll(db, sql: """
            SELECT member.itemId FROM duplicate_group_members member
            JOIN media_items item ON item.id = member.itemId
            WHERE member.groupId = ? AND COALESCE(item.deletedAt, '') = ''
            ORDER BY member.isPrimary DESC, member.itemId ASC
            """, arguments: [groupID.uuidString]).compactMap(UUID.init(uuidString:))
    }

    private nonisolated static func loadGroup(_ id: UUID, in db: Database) throws -> DuplicateGroup? {
        try DuplicateGroupRecord.fetch(db: db, id: id)?.toDuplicateGroup(itemIds: DuplicateGroupMemberRecord.fetchItemIds(db: db, groupId: id))
    }

    private func notifyGroupsDidChange() async {
        await MainActor.run { NotificationCenter.default.post(name: .duplicateGroupsDidChange, object: nil) }
    }
}

private struct DuplicateScanResult: Sendable {
    let groupsFound: Int
    let unavailableItems: Int
    let changedItems: Int
    let arrivals: Int
}

/// Cancellation is checked on I/O chunks, candidate loops, and inside the publication
/// transaction. The scan task is owned until exit; cancelled partial scans never publish.
final class DuplicateScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value || Task.isCancelled { throw CancellationError() }
    }
}

private enum DuplicateScan {
    private static let algorithmVersion = 1
    private static let maxBucketEntries = 512
    private static let maxComparisonsPerItem = 2048
    private static let maxVisualGroupSize = 32
    private static let cacheCheckpointSize = 64

    struct CacheEntry: Sendable {
        var version: DuplicateFileVersion
        var sha256: String
        var visual: DuplicateVisualFingerprint?
    }

    static func run(db: DatabaseManager, threshold: Int, cancellation: DuplicateScanCancellation,
                    progress: @Sendable (DuplicateDetector.DetectionProgress) async -> Void) async throws -> DuplicateScanResult {
        let sources = try await db.read { try DuplicateEvidenceService.Source.fetch(in: $0) }
        var cache = try await db.read { database -> [String: CacheEntry] in
            var result: [String: CacheEntry] = [:]
            for row in try Row.fetchAll(database, sql: "SELECT * FROM duplicate_digest_cache WHERE algorithmVersion = ?", arguments: [algorithmVersion]) {
                let path: String = row["path"]
                let versionJSON: String = row["versionJSON"]
                guard let version = try? JSONDecoder().decode(DuplicateFileVersion.self, from: Data(versionJSON.utf8)) else { continue }
                let visualJSON: String? = row["visualJSON"]
                result[path] = CacheEntry(version: version, sha256: row["sha256"], visual: visualJSON.flatMap { try? JSONDecoder().decode(DuplicateVisualFingerprint.self, from: Data($0.utf8)) })
            }
            return result
        }
        var changedCache: [String: CacheEntry] = [:]
        var items: [DuplicateItemEvidence] = []
        var skipped = 0
        do {
            for (index, source) in sources.enumerated() {
                try cancellation.check()
                await progress(.scanning(phase: "Verifying media bytes", current: index, total: sources.count))
                guard let urls = source.urls else { skipped += 1; continue }
                do {
                    var files: [DuplicateFileEvidence] = []
                    for url in urls {
                        try cancellation.check()
                        let version = try DuplicateFileVersion.read(url)
                        let entry: CacheEntry
                        if var cached = cache[url.path], cached.version == version {
                            if urls.count == 1 && cached.visual?.luminanceSketch == nil {
                                cached.visual = DuplicateEvidenceService.visualFingerprint(url)
                                guard try DuplicateFileVersion.read(url) == version else { throw DuplicateEvidenceError.stale }
                                cache[url.path] = cached
                                changedCache[url.path] = cached
                            }
                            entry = cached
                        } else {
                            let digest = try DuplicateEvidenceService.sha256(url: url, cancellation: { try cancellation.check() })
                            let visual = urls.count == 1 ? DuplicateEvidenceService.visualFingerprint(url) : nil
                            guard try DuplicateFileVersion.read(url) == version else { throw DuplicateEvidenceError.stale }
                            entry = CacheEntry(version: version, sha256: digest, visual: visual)
                            cache[url.path] = entry
                            changedCache[url.path] = entry
                        }
                        files.append(DuplicateFileEvidence(path: url.path, version: version, sha256: entry.sha256, visual: entry.visual))
                        if changedCache.count >= cacheCheckpointSize {
                            try await checkpoint(changedCache, db: db)
                            changedCache.removeAll(keepingCapacity: true)
                        }
                    }
                    items.append(DuplicateItemEvidence(itemID: source.id, mediaFilesJSON: source.mediaFilesJSON, contextImageString: source.contextImageString, files: files, mediaSetDigest: DuplicateEvidenceService.mediaSetDigest(files)))
                } catch is CancellationError { throw CancellationError() }
                catch let error as GRDB.DatabaseError { throw error }
                catch { skipped += 1 }
            }
            try await checkpoint(changedCache, db: db)
            changedCache.removeAll(keepingCapacity: true)
        } catch {
            // Retain stable completed hashes even when the scan is cancelled mid-item.
            try? await checkpoint(changedCache, db: db)
            throw error
        }
        try cancellation.check()
        var candidates: [DuplicateGroup] = []
        let exact = Dictionary(grouping: items, by: \.mediaSetDigest)
        for key in exact.keys.sorted() {
            try cancellation.check()
            guard let members = exact[key], members.count >= 2 else { continue }
            candidates.append(DuplicateGroup(itemIds: members.map(\.itemID), detectionMethod: .exactDuplicate, similarity: 1,
                evidenceKey: "sha256-set-v1:\(key)", evidence: DuplicateEvidence(items: members, mediaSetDigest: key, visualDistance: nil,
                    explanation: "Every declared media file matches in full (SHA-256, including file count). Source context, notes, annotations and extra attachments may differ and are not proven duplicates.")))
        }
        let previousAnchors = try await db.read { database -> Set<UUID> in
            let keys = try String.fetchAll(database, sql: "SELECT evidenceKey FROM duplicate_groups WHERE evidenceKey LIKE 'thumbnail-dct-v1:%'")
            return Set(keys.compactMap { UUID(uuidString: String($0.dropFirst("thumbnail-dct-v1:".count))) })
        }
        let orderedVisualItems = items.filter { $0.files.count == 1 && $0.files[0].visual != nil }
            .sorted { $0.itemID.uuidString < $1.itemID.uuidString }
        // One representative per byte-identical set can bridge A=B exact with reencoded C.
        // Overlapping exact/visual groups are suggestions; review revalidates active members.
        var representedDigests = Set<String>()
        let visualItems = orderedVisualItems.filter { representedDigests.insert($0.mediaSetDigest).inserted }
        var buckets: [Int: [Int]] = [:]
        for (index, item) in visualItems.enumerated() {
            let hash = item.files[0].visual!.hash
            for band in 0..<8 {
                let key = band * 256 + Int((hash >> (band * 8)) & 255)
                if buckets[key, default: []].count < maxBucketEntries { buckets[key, default: []].append(index) }
            }
        }
        var assigned = Set<Int>()
        for (index, item) in visualItems.enumerated() {
            try cancellation.check()
            if index.isMultiple(of: 64) { await progress(.scanning(phase: "Checking bounded visual candidates", current: index, total: visualItems.count)) }
            guard !assigned.contains(index), let visual = item.files[0].visual else { continue }
            var potential = Set<Int>()
            for band in 0..<8 {
                for candidate in buckets[band * 256 + Int((visual.hash >> (band * 8)) & 255)] ?? [] where candidate > index && !assigned.contains(candidate) {
                    potential.insert(candidate)
                }
            }
            // Rank the bounded pool before spending the comparison budget. UUID is
            // only a tie-breaker; persisted anchors do not change matching order.
            var ranked: [(index: Int, distance: Int, luminanceDelta: Double)] = []
            for otherIndex in potential {
                try cancellation.check()
                let fingerprint = visualItems[otherIndex].files[0].visual!
                let distance = (visual.hash ^ fingerprint.hash).nonzeroBitCount
                let luminanceDelta = abs(visual.meanLuminance - fingerprint.meanLuminance)
                guard distance <= threshold, luminanceDelta <= 0.12,
                      abs(log(visual.aspectRatio / fingerprint.aspectRatio)) <= 0.04 else { continue }
                ranked.append((otherIndex, distance, luminanceDelta))
            }
            ranked.sort {
                if $0.distance != $1.distance { return $0.distance < $1.distance }
                if $0.luminanceDelta != $1.luminanceDelta { return $0.luminanceDelta < $1.luminanceDelta }
                return $0.index < $1.index
            }
            var members = [item]
            var memberIndices = [index]
            var worstDistance = 0
            for candidate in ranked.prefix(maxComparisonsPerItem) {
                try cancellation.check()
                let otherIndex = candidate.index
                let other = visualItems[otherIndex]
                let fingerprint = other.files[0].visual!
                let distance = candidate.distance
                // Wider candidate coverage also finds DCT collisions. Confirm borderline
                // suggestions with independent coarse spatial structure.
                guard distance <= 4 || visual.hasSimilarStructure(to: fingerprint) else { continue }
                members.append(other)
                memberIndices.append(otherIndex)
                worstDistance = max(worstDistance, distance)
                if members.count == maxVisualGroupSize { break }
            }
            guard members.count >= 2 else { continue }
            assigned.formUnion(memberIndices)
            // Stable anchor identity; evidence revisions prevent decisions following changed bytes.
            let anchor = members.first { previousAnchors.contains($0.itemID) }?.itemID ?? item.itemID
            let key = "thumbnail-dct-v1:\(anchor.uuidString)"
            candidates.append(DuplicateGroup(itemIds: members.map(\.itemID), detectionMethod: .perceptualHash,
                similarity: 1 - Float(worstDistance) / 63, evidenceKey: key,
                evidence: DuplicateEvidence(items: members, mediaSetDigest: nil, visualDistance: worstDistance,
                    explanation: "Similar thumbnail structure (up to \(worstDistance) of 63 bits differ from the first item); not identical bytes. Bounded candidates can miss matches. Compare every item before deciding.")))
        }
        try cancellation.check()
        await progress(.scanning(phase: "Publishing verified results\(skipped > 0 ? " (\(skipped) unavailable items skipped)" : "")", current: candidates.count, total: candidates.count))
        let published = candidates
        let unavailableItems = skipped
        return try await db.write { database in
            try cancellation.check()
            let live = try DuplicateEvidenceService.Source.fetch(in: database)
            let liveByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
            let startingIDs = Set(sources.map(\.id))
            let arrivals = live.filter { !startingIDs.contains($0.id) }.count
            var changedIDs = Set(sources.compactMap { source -> UUID? in
                guard let current = liveByID[source.id], current.mediaFilesJSON == source.mediaFilesJSON,
                      current.contextImageString == source.contextImageString else { return source.id }
                return nil
            })
            // Unrelated arrivals are outside this scan. Changed starting items invalidate
            // only their groups; a missing file must not roll back unaffected results.
            let oldRecords = try DuplicateGroupRecord.fetchAll(db: database)
            let oldByKey = Dictionary(uniqueKeysWithValues: oldRecords.compactMap { record in record.evidenceKey.map { ($0, record) } })
            try database.execute(sql: "UPDATE duplicate_groups SET isCurrent = 0 WHERE isCurrent = 1")
            var currentGroups: [DuplicateGroup] = []
            var pendingCount = 0
            for var group in published {
                try cancellation.check()
                guard let evidence = group.evidence else { continue }
                for item in evidence.items where !changedIDs.contains(item.itemID) {
                    try cancellation.check()
                    for file in item.files {
                        try cancellation.check()
                        if (try? DuplicateFileVersion.read(URL(fileURLWithPath: file.path))) != file.version {
                            changedIDs.insert(item.itemID)
                            break
                        }
                    }
                }
                guard !evidence.items.contains(where: { changedIDs.contains($0.itemID) }) else { continue }
                if let key = group.evidenceKey, let previous = oldByKey[key] {
                    group = DuplicateGroup(id: previous.id, itemIds: group.itemIds, primaryItemId: previous.primaryItemId.flatMap { group.itemIds.contains($0) ? $0 : nil },
                        status: .pending, detectionMethod: group.detectionMethod, similarity: group.similarity, createdAt: previous.createdAt,
                        evidenceKey: group.evidenceKey, evidence: group.evidence)
                }
                if let decision = try DuplicateEvidencePersistence.decision(for: group, in: database) {
                    group.status = decision.0
                    group.primaryItemId = decision.1.flatMap { group.itemIds.contains($0) ? $0 : nil }
                }
                if group.status == .pending { pendingCount += 1 }
                try cancellation.check()
                try DuplicateGroupRecord(from: group).upsert(db: database)
                try cancellation.check()
                try DuplicateGroupMemberRecord.deleteAll(db: database, groupId: group.id)
                for id in group.itemIds {
                    try cancellation.check()
                    try DuplicateGroupMemberRecord(groupId: group.id, itemId: id, isPrimary: id == group.primaryItemId).insert(db: database)
                }
                try database.execute(sql: "UPDATE duplicate_groups SET isCurrent = 1 WHERE id = ?", arguments: [group.id.uuidString])
                currentGroups.append(group)
            }
            // Recheck after writing: a later changed member can invalidate an earlier
            // overlapping group, while unaffected groups still publish together.
            for group in currentGroups {
                for item in group.evidence?.items ?? [] where !changedIDs.contains(item.itemID) {
                    try cancellation.check()
                    for file in item.files {
                        try cancellation.check()
                        if (try? DuplicateFileVersion.read(URL(fileURLWithPath: file.path))) != file.version {
                            changedIDs.insert(item.itemID)
                            break
                        }
                    }
                }
            }
            for group in currentGroups where group.itemIds.contains(where: { changedIDs.contains($0) }) {
                try cancellation.check()
                try database.execute(sql: "UPDATE duplicate_groups SET isCurrent = 0 WHERE id = ?", arguments: [group.id.uuidString])
                if group.status == .pending { pendingCount -= 1 }
            }
            try cancellation.check()
            return DuplicateScanResult(groupsFound: pendingCount, unavailableItems: unavailableItems,
                                       changedItems: changedIDs.count, arrivals: arrivals)
        }
    }

    private static func checkpoint(_ entries: [String: CacheEntry], db: DatabaseManager) async throws {
        guard !entries.isEmpty else { return }
        // A small independent transaction finishes even if its parent scan is cancelled.
        let writing = Task.detached(priority: .utility) {
            try await db.write { database in
                for (path, entry) in entries {
                    try database.execute(sql: """
                        INSERT INTO duplicate_digest_cache(path, algorithmVersion, versionJSON, sha256, visualJSON)
                        VALUES (?, ?, ?, ?, ?) ON CONFLICT(path) DO UPDATE SET algorithmVersion=excluded.algorithmVersion,
                        versionJSON=excluded.versionJSON, sha256=excluded.sha256, visualJSON=excluded.visualJSON
                        """, arguments: [path, algorithmVersion, try DuplicateEvidencePersistence.json(entry.version), entry.sha256,
                                          try entry.visual.map { try DuplicateEvidencePersistence.json($0) }])
                }
            }
        }
        try await writing.value
    }
}
