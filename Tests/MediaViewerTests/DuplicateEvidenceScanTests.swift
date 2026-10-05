import XCTest
import GRDB
import CryptoKit
import AppKit
@testable import MediaViewer

final class DuplicateEvidenceScanTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("duplicate-evidence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        store = MediaStore(database: database)
    }

    override func tearDown() async throws {
        await store?.writeBackQueue.flushNow()
        store = nil
        database = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func item(_ name: String, contents: [Data], context: Data? = nil, ext: String = "jpg") async throws -> MediaItem {
        let folder = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sidecar = folder.appendingPathComponent("item.md")
        try "---\nsource: https://example.com/\(name)\nplatform: test\n---\n".write(to: sidecar, atomically: false, encoding: .utf8)
        let files = try contents.enumerated().map { index, data -> URL in
            let file = folder.appendingPathComponent("\(index).\(ext)")
            try data.write(to: file)
            return file
        }
        let contextURL = context.map { _ in folder.appendingPathComponent("context.jpg") }
        if let context, let contextURL { try context.write(to: contextURL) }
        let value = MediaItem(id: UUID(), basePath: folder, metadataFile: sidecar, mediaFiles: files, contextImage: contextURL,
                              metadata: MediaMetadata(source: URL(string: "https://example.com/\(name)")!, platform: "test"))
        try await store.insertItem(value)
        return value
    }

    func testFullDigestRejectsDifferencesOutsideOldThreeSamples() async throws {
        let original = Data(repeating: 17, count: 131_072)
        var altered = original
        altered[16_384] = 92 // Outside old 4KB head/middle/tail samples.
        _ = try await item("first", contents: [original])
        _ = try await item("altered", contents: [altered])
        let detector = DuplicateDetector(db: database)
        let found = try await detector.detectDuplicates()
        XCTAssertEqual(found, 0)
        let groups = try await detector.fetchAllGroups()
        XCTAssertTrue(groups.isEmpty)
        let digests = try await database.read { try String.fetchAll($0, sql: "SELECT sha256 FROM duplicate_digest_cache") }
        XCTAssertEqual(Set(digests).count, 2)
        XCTAssertTrue(digests.contains(SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()))
    }

    func testExactRequiresCompleteMultisetAndNeverUsesContextAsMedia() async throws {
        let same = Data("same".utf8)
        let extra = Data("extra".utf8)
        let a = try await item("a", contents: [same, extra], context: Data("context A".utf8))
        let b = try await item("b", contents: [extra, same], context: Data("different context".utf8))
        _ = try await item("prefix-only", contents: [same])
        _ = try await item("duplicate-count", contents: [same, extra, extra])
        _ = try await item("context-only", contents: [], context: same)
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()
        let groups = try await detector.fetchAllGroups()
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(Set(group.itemIds), [a.id, b.id])
        XCTAssertEqual(group.detectionMethod, .exactDuplicate)
        XCTAssertTrue(group.evidence?.explanation.contains("may differ") == true)
        XCTAssertEqual(group.evidence?.items.map { $0.files.count }, [2, 2])
    }

    func testMissingSecondaryFileDoesNotDegradeToFirstFileExactMatch() async throws {
        let a = try await item("a", contents: [Data("same".utf8), Data("other".utf8)])
        _ = try await item("b", contents: [Data("same".utf8)])
        try FileManager.default.removeItem(at: a.mediaFiles[1])
        let found = try await DuplicateDetector(db: database).detectDuplicates()
        XCTAssertEqual(found, 0)
    }

    func testDismissalAndPrimaryPersistButNewArrivalReopensWithSameGroup() async throws {
        let bytes = Data("duplicate media".utf8)
        let a = try await item("a", contents: [bytes])
        let b = try await item("b", contents: [bytes])
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()
        let firstGroups = try await detector.fetchAllGroups()
        let original = try XCTUnwrap(firstGroups.first)
        try await detector.setPrimaryItem(original.id, itemId: b.id)
        try await detector.updateGroupStatus(original.id, status: .dismissed)
        let sameScan = try await detector.detectDuplicates()
        XCTAssertEqual(sameScan, 0)
        let reopenedDetector = DuplicateDetector(db: database)
        let reviewed = try await reopenedDetector.fetchAllGroups(status: .dismissed)
        XCTAssertEqual(reviewed.first?.id, original.id)
        XCTAssertEqual(reviewed.first?.primaryItemId, b.id)
        let c = try await item("c", contents: [bytes])
        let count = try await reopenedDetector.detectDuplicatesForItems([c.id])
        XCTAssertEqual(count, 1)
        let nextGroups = try await reopenedDetector.fetchAllGroups(status: .pending)
        let next = try XCTUnwrap(nextGroups.first)
        XCTAssertEqual(next.id, original.id)
        XCTAssertEqual(Set(next.itemIds), [a.id, b.id, c.id])
        XCTAssertEqual(next.primaryItemId, b.id)
        let historyCount = try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM duplicate_review_decisions WHERE status = 'dismissed'") }
        XCTAssertEqual(historyCount, 1)
    }

    func testUnchangedSurvivorsInheritKeepDecisionAndUndoOverridesIt() async throws {
        let bytes = Data("same media".utf8)
        let a = try await item("a", contents: [bytes])
        let b = try await item("b", contents: [bytes])
        let c = try await item("c", contents: [bytes])
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()
        let groups = try await detector.fetchAllGroups()
        let original = try XCTUnwrap(groups.first)
        let service = DuplicateReviewService(database: database, mediaStore: store)
        let detail = try await service.load(groupID: original.id)
        let request = DuplicateReviewRequest(snapshot: detail.snapshot, decision: .keepSelected, keptIDs: [a.id, b.id])
        try await service.apply(request)
        let found = try await detector.detectDuplicates()
        XCTAssertEqual(found, 0, "Unchanged explicitly kept survivors should not be presented again")
        let survivors = try await detector.fetchAllGroups(status: .resolved)
        XCTAssertEqual(survivors.first?.id, original.id)
        XCTAssertEqual(Set(try XCTUnwrap(survivors.first).itemIds), [a.id, b.id])
        let current = try XCTUnwrap(survivors.first)
        let inherited = try await database.read { try DuplicateEvidencePersistence.latestDecision(for: current, in: $0) }
        XCTAssertEqual(inherited?.id, request.id)
        // Model an explicit undo ledger snapshot without depending on history UI reconciliation.
        try await database.write { db in
            try DuplicateEvidencePersistence.recordDecision(original, status: .pending, primaryItemID: nil, in: db)
        }
        let reopened = try await detector.detectDuplicates()
        XCTAssertEqual(reopened, 1, "Newer pending/Undo decisions must beat earlier resolved supersets")
        let newCopy = try await item("new-copy", contents: [bytes])
        _ = try await detector.detectDuplicatesForItems([newCopy.id])
        let pending = try await detector.fetchAllGroups(status: .pending)
        XCTAssertEqual(Set(try XCTUnwrap(pending.first).itemIds), [a.id, b.id, newCopy.id])
        XCTAssertFalse(pending.first!.itemIds.contains(c.id))
    }

    func testCachedReplacementInvalidatesAndStaleReviewRevalidationRejects() async throws {
        let a = try await item("a", contents: [Data("original bytes".utf8)])
        _ = try await item("b", contents: [Data("original bytes".utf8)])
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()
        let groups = try await detector.fetchAllGroups()
        let original = try XCTUnwrap(groups.first)
        try await DuplicateEvidenceService.revalidate(original, db: database)
        try Data("changed! bytes".utf8).write(to: a.mediaFiles[0], options: .atomic)
        do { try await DuplicateEvidenceService.revalidate(original, db: database); XCTFail("Stale evidence accepted") }
        catch DuplicateEvidenceError.stale {}
        let newCount = try await detector.detectDuplicates()
        XCTAssertEqual(newCount, 0)
        let current = try await detector.fetchAllGroups()
        XCTAssertTrue(current.isEmpty)
        let retained = try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM duplicate_groups") }
        XCTAssertEqual(retained, 1, "Historical result should remain recoverable")
    }

    func testPrimaryMustBeActiveMemberAndRemovalRepairsDanglingPrimary() async throws {
        let a = try await item("a", contents: [Data("copy".utf8)])
        let b = try await item("b", contents: [Data("copy".utf8)])
        let c = try await item("c", contents: [Data("copy".utf8)])
        let outsider = try await item("outsider", contents: [Data("different".utf8)])
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()
        let groups = try await detector.fetchAllGroups()
        let group = try XCTUnwrap(groups.first)
        do { try await detector.setPrimaryItem(group.id, itemId: outsider.id); XCTFail("Nonmember primary accepted") }
        catch DuplicateEvidenceError.invalidPrimary {}
        try await detector.setPrimaryItem(group.id, itemId: a.id)
        try await detector.removeItemFromGroup(group.id, itemId: a.id)
        let nextGroups = try await detector.fetchAllGroups()
        let next = try XCTUnwrap(nextGroups.first)
        XCTAssertEqual(Set(next.itemIds), [b.id, c.id])
        XCTAssertTrue(next.primaryItemId.map { next.itemIds.contains($0) } == true)
    }

    func testCancelledScanPreservesPublishedSnapshotAndCanRestart() async throws {
        _ = try await item("a", contents: [Data("copy".utf8)])
        _ = try await item("b", contents: [Data("copy".utf8)])
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()
        let original = try await detector.fetchAllGroups()
        for index in 0..<12 { _ = try await item("large-\(index)", contents: [Data(repeating: UInt8(index), count: 2_000_000)]) }
        let scan = Task { try await detector.detectDuplicates() }
        while !(await detector.getProgress()).isScanning { await Task.yield() }
        await detector.cancelDetection()
        do { _ = try await scan.value; XCTFail("Cancelled scan completed") } catch is CancellationError {}
        let after = try await detector.fetchAllGroups()
        XCTAssertEqual(after, original)
        let progress = await detector.getProgress()
        XCTAssertEqual(progress, .idle)
        _ = try await detector.detectDuplicates()
        let final = try await detector.fetchAllGroups()
        XCTAssertEqual(final.first?.id, original.first?.id)
    }

    func testVisualCandidatesUseCurrentBoundedThumbnailsNotLegacySemanticVectors() async throws {
        let image = try makeImage()
        var alteredEncoding = image
        alteredEncoding.append(Data("nonpixel png trailer".utf8))
        let a = try await item("visual-a", contents: [image], ext: "png")
        let b = try await item("visual-b", contents: [alteredEncoding], ext: "png")
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()
        let groups = try await detector.fetchAllGroups()
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(Set(group.itemIds), [a.id, b.id])
        XCTAssertEqual(group.detectionMethod, .perceptualHash)
        XCTAssertEqual(group.evidence?.visualDistance, 0)
        XCTAssertTrue(group.evidence?.explanation.contains("not identical bytes") == true)
        XCTAssertNotEqual(group.evidence?.items[0].mediaSetDigest, group.evidence?.items[1].mediaSetDigest)
    }

    func testExactSetStillBridgesToReencodedVisualCandidate() async throws {
        let image = try makeImage()
        var reencoded = image
        reencoded.append(Data("different encoding".utf8))
        let a = try await item("a", contents: [image], ext: "png")
        let b = try await item("b", contents: [image], ext: "png")
        let c = try await item("c", contents: [reencoded], ext: "png")
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()
        let groups = try await detector.fetchAllGroups()
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(try XCTUnwrap(groups.first { $0.detectionMethod == .exactDuplicate }).itemIds), [a.id, b.id])
        let visual = try XCTUnwrap(groups.first { $0.detectionMethod == .perceptualHash })
        XCTAssertEqual(visual.itemIds.count, 2)
        XCTAssertTrue(visual.itemIds.contains(c.id))
        XCTAssertEqual(Set(visual.itemIds).intersection([a.id, b.id]).count, 1)
    }

    func testCachedMultiassetFileGainsVisualFingerprintWhenMadeSingleasset() async throws {
        let image = try makeImage()
        var reencoded = image
        reencoded.append(Data("different encoding".utf8))
        let a = try await item("a", contents: [image, Data("second asset".utf8)], ext: "png")
        let b = try await item("b", contents: [reencoded], ext: "png")
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()
        let before = try await detector.fetchAllGroups()
        XCTAssertTrue(before.isEmpty)
        try await store.updateMediaFiles(id: a.id, files: [a.mediaFiles[0]])
        _ = try await detector.detectDuplicates()
        let after = try await detector.fetchAllGroups()
        XCTAssertEqual(Set(try XCTUnwrap(after.first).itemIds), [a.id, b.id])
        XCTAssertEqual(after.first?.detectionMethod, .perceptualHash)
    }

    func testLegacyGroupNeverDisplayedAsVerifiedExactAndClearDoesNotEraseDecision() async throws {
        let a = try await item("a", contents: [Data("copy".utf8)])
        let b = try await item("b", contents: [Data("copy".utf8)])
        let legacy = DuplicateGroup(itemIds: [a.id, b.id], status: .dismissed, detectionMethod: .exactDuplicate, similarity: 1)
        try await database.write { db in
            try DuplicateGroupRecord(from: legacy).upsert(db: db)
            for id in legacy.itemIds { try DuplicateGroupMemberRecord(groupId: legacy.id, itemId: id).insert(db: db) }
        }
        let detector = DuplicateDetector(db: database)
        let before = try await detector.fetchAllGroups()
        XCTAssertTrue(before.isEmpty)
        _ = try await detector.detectDuplicates()
        let current = try await detector.fetchAllGroups()
        let verified = try XCTUnwrap(current.first)
        XCTAssertNotEqual(verified.id, legacy.id)
        try await detector.updateGroupStatus(verified.id, status: .dismissed)
        try await detector.clearAllGroups()
        _ = try await detector.detectDuplicates()
        let restored = try await detector.fetchAllGroups(status: .dismissed)
        XCTAssertEqual(restored.first?.id, verified.id)
    }

    private func makeImage() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 240, bitsPerPixel: 24))
        let pixels = try XCTUnwrap(rep.bitmapData)
        for y in 0..<60 { for x in 0..<80 {
            let offset = y * 240 + x * 3
            let bright: UInt8 = (x < 27 && y > 12) || (x > 50 && y < 38) ? 220 : 30
            pixels[offset] = bright
            pixels[offset + 1] = bright
            pixels[offset + 2] = bright
        } }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
