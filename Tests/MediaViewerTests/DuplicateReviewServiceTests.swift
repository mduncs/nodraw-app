import XCTest
import GRDB
@testable import MediaViewer

final class DuplicateReviewServiceTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!
    private var service: DuplicateReviewService!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("duplicate-review-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        store = MediaStore(database: database)
        service = DuplicateReviewService(database: database, mediaStore: store)
    }
    override func tearDown() async throws {
        await store?.writeBackQueue.flushNow()
        service = nil; store = nil; database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testKeepMultipleIsAtomicRecoverableAndRedoRestoresSameDecision() async throws {
        let group = try await fixture(count: 3)
        let detail = try await service.load(groupID: group.id)
        let kept = Set(detail.items.prefix(2).map(\.id))
        let rejected = try XCTUnwrap(detail.items.last)
        let request = DuplicateReviewRequest(snapshot: detail.snapshot, decision: .keepSelected, keptIDs: kept)
        let before = try await dependentCounts(rejected.id)
        let bytes = try Data(contentsOf: rejected.primaryMedia!)
        try await service.apply(request)
        try await service.apply(request) // replay is idempotent, not a second history item
        var rows = try await records(group.itemIds)
        XCTAssertEqual(rows.filter { $0.deletedAt != nil }.map(\.id), [rejected.id])
        XCTAssertEqual(rows.first { $0.id == rejected.id }?.notes, "Human notes 2")
        let after = try await dependentCounts(rejected.id)
        XCTAssertEqual(before, after)
        XCTAssertEqual(try Data(contentsOf: rejected.primaryMedia!), bytes)
        var history = try await service.history()
        XCTAssertEqual(history.count, 1)
        XCTAssertFalse(history[0].isUndone)
        try await service.undo(request.id)
        rows = try await records(group.itemIds)
        XCTAssertTrue(rows.allSatisfy { $0.deletedAt == nil })
        try await service.redo(request.id)
        rows = try await records(group.itemIds)
        XCTAssertEqual(rows.filter { $0.deletedAt != nil }.map(\.id), [rejected.id])
        history = try await service.history()
        XCTAssertFalse(history[0].isUndone)
    }

    func testHumanMetadataChangedAfterSnapshotRejectsAllMutations() async throws {
        let group = try await fixture(count: 2)
        let detail = try await service.load(groupID: group.id)
        let changedID = detail.items.last!.id
        try await database.write { db in try db.execute(sql: "UPDATE media_items SET notes = 'Newer work' WHERE id = ?", arguments: [changedID.uuidString]) }
        let request = DuplicateReviewRequest(snapshot: detail.snapshot, decision: .keepSelected, keptIDs: [detail.items[0].id])
        do { try await service.apply(request); XCTFail("Stale metadata must reject review") } catch {}
        let rows = try await records(group.itemIds), history = try await service.history()
        XCTAssertTrue(rows.allSatisfy { $0.deletedAt == nil })
        XCTAssertTrue(history.isEmpty)
        let record = try await database.read { try DuplicateGroupRecord.fetch(db: $0, id: group.id) }
        XCTAssertEqual(record?.status, "pending")
    }

    func testChangedSourceBytesFailClosedWithoutPartialHistory() async throws {
        let group = try await fixture(count: 2)
        let detail = try await service.load(groupID: group.id)
        try Data("changed source bytes".utf8).write(to: detail.items[1].primaryMedia!)
        let request = DuplicateReviewRequest(snapshot: detail.snapshot, decision: .keepSelected, keptIDs: [detail.items[0].id])
        do { try await service.apply(request); XCTFail("Changed source must reject review") } catch {}
        let rows = try await records(group.itemIds), history = try await service.history()
        XCTAssertTrue(rows.allSatisfy { $0.deletedAt == nil }); XCTAssertTrue(history.isEmpty)
    }

    func testDatabaseFailureRollsBackItemFlagsGroupAndDecisionLedgerTogether() async throws {
        let group = try await fixture(count: 2)
        let detail = try await service.load(groupID: group.id)
        try await database.write { db in try db.execute(sql: "CREATE TRIGGER reject_review BEFORE INSERT ON duplicate_review_history BEGIN SELECT RAISE(ABORT, 'fixture history failure'); END") }
        let request = DuplicateReviewRequest(snapshot: detail.snapshot, decision: .keepSelected, keptIDs: [detail.items[0].id])
        do { try await service.apply(request); XCTFail("Expected transactional failure") } catch {}
        let rows = try await records(group.itemIds)
        XCTAssertTrue(rows.allSatisfy { $0.deletedAt == nil })
        let state = try await database.read { db -> (String?, Int) in
            (try DuplicateGroupRecord.fetch(db: db, id: group.id)?.status, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM duplicate_review_decisions WHERE groupId = ?", arguments: [group.id.uuidString]) ?? 0)
        }
        XCTAssertEqual(state.0, "pending"); XCTAssertEqual(state.1, 0)
    }

    func testLaterKeepAllAndNotDuplicatesHaveDistinctDurableStatesAndMoveNothing() async throws {
        for (decision, status) in [(TriageDecision.later, "reviewed"), (.keepAll, "resolved"), (.notDuplicates, "dismissed")] {
            let group = try await fixture(count: 2)
            let detail = try await service.load(groupID: group.id)
            let request = DuplicateReviewRequest(snapshot: detail.snapshot, decision: decision, keptIDs: Set(group.itemIds))
            try await service.apply(request)
            let rows = try await records(group.itemIds)
            XCTAssertTrue(rows.allSatisfy { $0.deletedAt == nil })
            let record = try await database.read { try DuplicateGroupRecord.fetch(db: $0, id: group.id) }
            XCTAssertEqual(record?.status, status)
            let ledger = try await database.read { try DuplicateEvidencePersistence.decision(for: group, in: $0) }
            XCTAssertEqual(ledger?.0.rawValue, status)
            try await service.undo(request.id)
            let undoneLedger = try await database.read { try DuplicateEvidencePersistence.decision(for: group, in: $0) }
            XCTAssertEqual(undoneLedger?.0, .pending)
        }
    }

    func testHistorySurvivesServiceRecreationAndGroupRefreshButRejectsExternalRestore() async throws {
        let group = try await fixture(count: 2)
        let detail = try await service.load(groupID: group.id)
        let request = DuplicateReviewRequest(snapshot: detail.snapshot, decision: .keepSelected, keptIDs: [detail.items[0].id])
        try await service.apply(request)
        // Detector publication may refresh group timestamp; ledger ownership, not that
        // timestamp, guards history operations across scans.
        try await database.write { db in try db.execute(sql: "UPDATE duplicate_groups SET updatedAt = ? WHERE id = ?", arguments: [Date().addingTimeInterval(10), group.id.uuidString]) }
        let relaunched = DuplicateReviewService(database: database, mediaStore: store)
        try await relaunched.undo(request.id)
        try await relaunched.redo(request.id)
        try await store.restoreDeleted(ids: request.rejectedIDs)
        do { try await relaunched.undo(request.id); XCTFail("External restore must not be overwritten") } catch {}
        let rows = try await records(group.itemIds)
        XCTAssertTrue(rows.allSatisfy { $0.deletedAt == nil })
    }

    func testKeepTwoOfThreeUndoAndRedoSurviveProductionRescan() async throws {
        _ = try await fixture(count: 3)
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()
        let groups = try await detector.fetchAllGroups(status: .pending)
        let group = try XCTUnwrap(groups.first)
        let detail = try await service.load(groupID: group.id)
        let request = DuplicateReviewRequest(snapshot: detail.snapshot, decision: .keepSelected, keptIDs: Set(detail.items.prefix(2).map(\.id)))
        try await service.apply(request)
        _ = try await detector.detectDuplicates()
        let survivors = try await database.read { try DuplicateGroupMemberRecord.fetchItemIds(db: $0, groupId: group.id) }
        XCTAssertEqual(Set(survivors), request.keptIDs)
        try await service.undo(request.id)
        let restored = try await records(group.itemIds)
        XCTAssertTrue(restored.allSatisfy { $0.deletedAt == nil })
        let restoredMembers = try await database.read { try DuplicateGroupMemberRecord.fetchItemIds(db: $0, groupId: group.id) }
        XCTAssertEqual(Set(restoredMembers), Set(group.itemIds))
        try await service.redo(request.id)
        let redone = try await records(group.itemIds)
        XCTAssertEqual(Set(redone.filter { $0.deletedAt != nil }.map(\.id)), Set(request.rejectedIDs))
    }

    func testNewDecisionOnSurvivorSubsetPreventsOlderUndo() async throws {
        _ = try await fixture(count: 3)
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()
        let groups = try await detector.fetchAllGroups(status: .pending)
        let group = try XCTUnwrap(groups.first)
        let detail = try await service.load(groupID: group.id)
        let request = DuplicateReviewRequest(snapshot: detail.snapshot, decision: .keepSelected, keptIDs: Set(detail.items.prefix(2).map(\.id)))
        try await service.apply(request)
        _ = try await detector.detectDuplicates()
        try await database.write { db in
            let record = try DuplicateGroupRecord.fetch(db: db, id: group.id)!
            let subset = record.toDuplicateGroup(itemIds: try DuplicateGroupMemberRecord.fetchItemIds(db: db, groupId: group.id))!
            try DuplicateEvidencePersistence.recordDecision(subset, status: .dismissed, primaryItemID: subset.primaryItemId, in: db)
        }
        do { try await service.undo(request.id); XCTFail("A newer survivor decision must conflict") } catch {}
        let rows = try await records(group.itemIds)
        XCTAssertEqual(Set(rows.filter { $0.deletedAt != nil }.map(\.id)), Set(request.rejectedIDs))
    }

    func testOverlappingGroupWithDeletedMemberIsNotOfferedAsActionable() async throws {
        let group = try await fixture(count: 3)
        let visual = DuplicateGroup(itemIds: group.itemIds, detectionMethod: .perceptualHash, similarity: 0.95,
            evidenceKey: UUID().uuidString, evidence: group.evidence)
        try await database.write { db in
            try DuplicateGroupRecord(from: visual).upsert(db: db)
            for id in visual.itemIds { try DuplicateGroupMemberRecord(groupId: visual.id, itemId: id).insert(db: db) }
            try db.execute(sql: "UPDATE duplicate_groups SET isCurrent = 1 WHERE id = ?", arguments: [visual.id.uuidString])
        }
        let detail = try await service.load(groupID: group.id)
        try await service.apply(DuplicateReviewRequest(snapshot: detail.snapshot, decision: .keepSelected, keptIDs: Set(detail.items.prefix(2).map(\.id))))
        let queue = try await service.fetchGroups(includeLater: false, exactOnly: nil)
        XCTAssertFalse(queue.contains { $0.id == visual.id })
    }

    func testCategoryFilterRunsBeforeBoundedQueueLimit() async throws {
        let template = try await fixture(count: 2)
        try await database.write { db in
            for index in 0..<205 {
                var group = DuplicateGroup(itemIds: template.itemIds, detectionMethod: index == 204 ? .perceptualHash : .exactDuplicate, similarity: 1, evidenceKey: UUID().uuidString, evidence: template.evidence)
                group.createdAt = template.createdAt.addingTimeInterval(Double(index))
                try DuplicateGroupRecord(from: group).upsert(db: db)
                for id in group.itemIds { try DuplicateGroupMemberRecord(groupId: group.id, itemId: id).insert(db: db) }
                try db.execute(sql: "UPDATE duplicate_groups SET isCurrent = 1 WHERE id = ?", arguments: [group.id.uuidString])
            }
        }
        let bounded = try await service.fetchGroups(includeLater: false, exactOnly: nil)
        XCTAssertEqual(bounded.count, 200)
        let visual = try await service.fetchGroups(includeLater: false, exactOnly: false)
        XCTAssertEqual(visual.count, 1)
        XCTAssertEqual(visual.first?.detectionMethod, .perceptualHash)
    }

    private func fixture(count: Int) async throws -> DuplicateGroup {
        var items: [MediaItem] = []
        for index in 0..<count {
            let id = UUID(), folder = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let media = folder.appendingPathComponent("image.jpg"), sidecar = folder.appendingPathComponent("item.md")
            try Data("identical fixture image bytes".utf8).write(to: media)
            try "---\nsource: https://example.com/\(id)\nplatform: test\ntags: []\n---\n".write(to: sidecar, atomically: true, encoding: .utf8)
            let item = MediaItem(id: id, basePath: folder, metadataFile: sidecar, mediaFiles: [media], metadata: MediaMetadata(source: URL(string: "https://example.com/\(id)")!, platform: "test", tags: ["tag-\(index)"], notes: "Human notes \(index)"))
            try await store.insertItem(item)
            items.append(item)
        }
        // Stable ordering makes assertions independent of generated UUID order.
        items.sort { $0.id.uuidString < $1.id.uuidString }
        let finalID = items.last!.id
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET notes = 'Human notes 2' WHERE id = ?", arguments: [finalID.uuidString])
            let board = CollectionBoard(name: "Preserved board")
            try board.insert(db)
            try BoardMembership(boardId: board.id, itemId: finalID, position: 0).insert(db)
            let canvas = CanvasDocument(name: "Preserved canvas")
            try canvas.insert(db)
            try CanvasItemPlacement(canvasId: canvas.id, mediaItemId: finalID).insert(db)
            var annotation = AnnotationSet.empty
            annotation.addShape(.text(id: UUID(), position: NormalizedPoint(x: 0.2, y: 0.3), content: "Preserve this", style: .default))
            try AnnotationRecord(itemId: finalID, mediaFileIndex: 0, annotationSet: annotation).upsert(db: db)
        }
        let evidenceItems = try await database.read { db in
            try items.map { item -> DuplicateItemEvidence in
                let row = try Row.fetchOne(db, sql: "SELECT mediaFilesJSON, contextImageString FROM media_items WHERE id = ?", arguments: [item.id.uuidString])!
                let url = item.primaryMedia!
                let file = DuplicateFileEvidence(path: url.path, version: try DuplicateFileVersion.read(url), sha256: try DuplicateEvidenceService.sha256(url: url), visual: nil)
                return DuplicateItemEvidence(itemID: item.id, mediaFilesJSON: row["mediaFilesJSON"], contextImageString: row["contextImageString"], files: [file], mediaSetDigest: DuplicateEvidenceService.mediaSetDigest([file]))
            }
        }
        let group = DuplicateGroup(itemIds: items.map(\.id), detectionMethod: .exactDuplicate, similarity: 1,
            evidenceKey: UUID().uuidString, evidence: DuplicateEvidence(items: evidenceItems, mediaSetDigest: evidenceItems[0].mediaSetDigest, visualDistance: nil, explanation: "Fixture byte match"))
        try await database.write { db in
            try DuplicateGroupRecord(from: group).upsert(db: db)
            for item in items { try DuplicateGroupMemberRecord(groupId: group.id, itemId: item.id).insert(db: db) }
            try db.execute(sql: "UPDATE duplicate_groups SET isCurrent = 1 WHERE id = ?", arguments: [group.id.uuidString])
        }
        return group
    }

    private func records(_ ids: [UUID]) async throws -> [MediaItemRecord] {
        try await database.read { db in try ids.compactMap { try MediaItemRecord.fetchOne(db, sql: "SELECT * FROM media_items WHERE id = ?", arguments: [$0.uuidString]) } }
    }
    private func dependentCounts(_ id: UUID) async throws -> [Int] {
        try await database.read { db in
            try [("annotations", "itemId"), ("board_memberships", "itemId"), ("canvas_placements", "mediaItemId"), ("item_assets", "item_id")].map { table, column in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) = ?", arguments: [id.uuidString]) ?? 0
            }
        }
    }
}
