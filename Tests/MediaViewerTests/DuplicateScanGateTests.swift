import XCTest
import CryptoKit
import GRDB
@testable import MediaViewer

final class DuplicateScanGateTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!

    override func setUp() async throws {
        // Canonical like the scanner's paths: macOS drops "/private" from /private/tmp paths.
        directory = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("duplicate-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
    }

    override func tearDown() async throws {
        database = nil
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testArrivalDoesNotRejectStartingGroupsAndIsIncludedOnNextScan() async throws {
        let pairs = try await makePairs()
        try await addHashingTail()
        let detector = DuplicateDetector(db: database)
        let scan = Task { try await detector.detectDuplicates() }
        do {
            try await waitForHashingTail(detector)
            let arrival = try await item(100, contents: Data("first pair".utf8))
            let count = try await scan.value
            XCTAssertEqual(count, 2)
            let groups = try await detector.fetchAllGroups()
            XCTAssertEqual(Set(groups.map { Set($0.itemIds) }), [Set(pairs[0].map(\.id)), Set(pairs[1].map(\.id))])
            let progress = await detector.getProgress()
            XCTAssertEqual(progress, .complete(groupsFound: 2, arrivals: 1))
            XCTAssertTrue(progress.displayText.contains("1 new items arrived; scan again to include them."))
            let nextCount = try await detector.detectDuplicates()
            XCTAssertEqual(nextCount, 2)
            let nextGroups = try await detector.fetchAllGroups()
            XCTAssertTrue(nextGroups.contains { Set($0.itemIds) == Set(pairs[0].map(\.id) + [arrival.id]) })
            let nextProgress = await detector.getProgress()
            XCTAssertEqual(nextProgress, .complete(groupsFound: 2))
        } catch {
            await detector.cancelDetection()
            _ = await scan.result
            throw error
        }
    }

    func testStartingMemberReassignmentDropsOnlyItsGroup() async throws {
        try await assertChangedMember { database, item in
            try await database.write { db in
                try db.execute(sql: "UPDATE media_items SET mediaFilesJSON = '[]' WHERE id = ?", arguments: [item.id.uuidString])
            }
        }
    }

    func testStartingMemberRemovalDropsOnlyItsGroup() async throws {
        try await assertChangedMember { database, item in
            try await database.write { db in
                try db.execute(sql: "DELETE FROM media_items WHERE id = ?", arguments: [item.id.uuidString])
            }
        }
    }

    func testStartingFileReplacementDropsOnlyItsGroup() async throws {
        try await assertChangedMember { _, item in
            try Data("replacement with a different length".utf8).write(to: item.mediaFiles[0], options: .atomic)
        }
    }

    func testUnavailableCountSurvivesCompletionWithoutSuppressingGoodGroups() async throws {
        let pairs = try await makePairs()
        let missing = try await item(5, contents: Data("missing".utf8))
        try FileManager.default.removeItem(at: missing.mediaFiles[0])
        _ = try await item(6, contents: nil)
        let detector = DuplicateDetector(db: database)
        let count = try await detector.detectDuplicates()
        XCTAssertEqual(count, 2)
        let groups = try await detector.fetchAllGroups()
        XCTAssertEqual(Set(groups.map { Set($0.itemIds) }), [Set(pairs[0].map(\.id)), Set(pairs[1].map(\.id))])
        let progress = await detector.getProgress()
        XCTAssertEqual(progress, .complete(groupsFound: 2, unavailableItems: 2))
        XCTAssertTrue(progress.displayText.contains("2 files couldn't be read."))
    }

    func testCancellationKeepsCompletedDigestVersionsAndPublishedGroupsThenRestarts() async throws {
        _ = try await makePairs()
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()
        let original = try await detector.fetchAllGroups()
        let cacheBefore = try await cacheRows()
        try await addHashingTail()
        let scan = Task { try await detector.detectDuplicates() }
        do {
            try await waitForHashingTail(detector, minimum: 6)
            await detector.cancelDetection()
            do { _ = try await scan.value; XCTFail("Cancelled scan completed") }
            catch is CancellationError {}
            let progress = await detector.getProgress()
            XCTAssertEqual(progress, .idle)
            let after = try await detector.fetchAllGroups()
            XCTAssertEqual(after, original, "Cancellation must leave the last atomic result publication intact")
            let cached = try await cacheRows()
            XCTAssertGreaterThan(cached.count, cacheBefore.count, "Completed tail hashes must survive cancellation")
            XCTAssertLessThan(cached.count, 12, "The interruption must happen before all files are hashed")
            for row in cached {
                let version = try JSONDecoder().decode(DuplicateFileVersion.self, from: Data(row.versionJSON.utf8))
                XCTAssertEqual(version, try DuplicateFileVersion.read(URL(fileURLWithPath: row.path)))
                let digest = try autoreleasepool {
                    SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: row.path))).map { String(format: "%02x", $0) }.joined()
                }
                XCTAssertEqual(row.sha256, digest, "A cache checkpoint must contain a complete file digest")
                if let before = cacheBefore.first(where: { $0.path == row.path }) { XCTAssertEqual(row.sha256, before.sha256) }
            }
            let rerun = try await detector.detectDuplicates()
            XCTAssertEqual(rerun, 2)
            let final = try await detector.fetchAllGroups()
            XCTAssertEqual(Set(final.map(\.id)), Set(original.map(\.id)))
            let finalCache = try await cacheRows()
            XCTAssertEqual(finalCache.count, 12)
            for row in cached { XCTAssertTrue(finalCache.contains(row), "Warm rerun must preserve completed cache evidence") }
        } catch {
            await detector.cancelDetection()
            _ = await scan.result
            throw error
        }
    }

    func testLegacyFingerprintEnrichmentPreservesOnlyUnchangedReviewEvidence() async throws {
        let pairs = try await makePairs()
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()
        let groups = try await detector.fetchAllGroups()
        var legacy = try XCTUnwrap(groups.first { Set($0.itemIds) == Set(pairs[0].map(\.id)) })
        let legacyJSON = "{\"hash\":42,\"aspectRatio\":1.5,\"meanLuminance\":0.4,\"contrast\":0.2}"
        let fingerprint = try JSONDecoder().decode(DuplicateVisualFingerprint.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(fingerprint.luminanceSketch, "Old cache JSON must decode without the new derived field")
        for index in legacy.evidence!.items.indices { legacy.evidence!.items[index].files[0].visual = fingerprint }
        let recorded = legacy
        let decisionID = UUID()
        let primary = pairs[0][0].id
        try await database.write { db in
            for item in recorded.evidence!.items {
                try db.execute(sql: "UPDATE duplicate_digest_cache SET visualJSON = ? WHERE path = ?", arguments: [legacyJSON, item.files[0].path])
            }
            try DuplicateGroupRecord(from: recorded).upsert(db: db)
            try DuplicateEvidencePersistence.recordDecision(recorded, status: .dismissed, primaryItemID: primary, decisionID: decisionID, in: db)
        }
        let encoded = try await database.read { try String.fetchOne($0, sql: "SELECT visualJSON FROM duplicate_digest_cache WHERE path = ?", arguments: [recorded.evidence!.items[0].files[0].path]) }
        let cached = try JSONDecoder().decode(DuplicateVisualFingerprint.self, from: Data(try XCTUnwrap(encoded).utf8))
        XCTAssertEqual(cached, fingerprint)
        let before = try await database.read { try DuplicateEvidencePersistence.latestDecision(for: recorded, in: $0) }
        XCTAssertEqual(before?.id, decisionID)

        var enriched = recorded
        for index in enriched.evidence!.items.indices {
            enriched.evidence!.items[index].files[0].visual!.luminanceSketch = Data(repeating: 64, count: 64)
        }
        let enrichedGroup = enriched
        let after = try await database.read { try DuplicateEvidencePersistence.latestDecision(for: enrichedGroup, in: $0) }
        XCTAssertEqual(after?.id, decisionID)
        XCTAssertEqual(after?.status, .dismissed)
        XCTAssertEqual(after?.primaryItemID, primary)
        let changes: [(String, (inout DuplicateItemEvidence) -> Void)] = [
            ("declared files", { $0.mediaFilesJSON = "[]" }),
            ("context source", { $0.contextImageString = "different-context.png" }),
            ("media-set digest", { $0.mediaSetDigest = "different-set" }),
            ("file path", { $0.files[0].path += ".moved" }),
            ("file version", { $0.files[0].version.modifiedNanos += 1 }),
            ("full digest", { $0.files[0].sha256 = "different-digest" }),
            ("DCT hash", { $0.files[0].visual!.hash ^= 1 }),
            ("aspect ratio", { $0.files[0].visual!.aspectRatio += 0.1 }),
            ("luminance", { $0.files[0].visual!.meanLuminance += 0.1 }),
            ("contrast", { $0.files[0].visual!.contrast += 0.1 })
        ]
        for (name, change) in changes {
            var changed = enrichedGroup
            change(&changed.evidence!.items[0])
            let changedGroup = changed
            let decision = try await database.read { try DuplicateEvidencePersistence.latestDecision(for: changedGroup, in: $0) }
            XCTAssertNil(decision, "Sketch normalization must not hide a changed \(name)")
        }
    }

    func testSpatialSketchAcceptsBrightnessAndContrastButRejectsUnrelatedOrMissingStructure() {
        let pixels = (0..<64).map(UInt8.init)
        let original = DuplicateVisualFingerprint(hash: 42, aspectRatio: 1, meanLuminance: 0.2, contrast: 0.1, luminanceSketch: Data(pixels))
        var affine = original
        affine.luminanceSketch = Data(pixels.map { $0 * 2 + 32 })
        affine.meanLuminance = 0.4
        affine.contrast = 0.2
        XCTAssertTrue(original.hasSimilarStructure(to: affine))
        XCTAssertTrue(affine.hasSimilarStructure(to: original))

        var permuted = original
        permuted.luminanceSketch = Data((0..<64).map { pixels[($0 * 17) % 64] })
        XCTAssertFalse(original.hasSimilarStructure(to: permuted), "Equal pixel distributions must not imply equal spatial structure")
        XCTAssertFalse(permuted.hasSimilarStructure(to: original))
        for sketch in [nil, Data(repeating: 1, count: 63), Data(repeating: 1, count: 65), Data(repeating: 1, count: 64)] as [Data?] {
            var unavailable = original
            unavailable.luminanceSketch = sketch
            XCTAssertFalse(original.hasSimilarStructure(to: unavailable))
            XCTAssertFalse(unavailable.hasSimilarStructure(to: original))
            XCTAssertFalse(unavailable.hasSimilarStructure(to: unavailable), "Missing or constant structure must fail closed")
        }
    }

    private func assertChangedMember(_ change: (DatabaseManager, MediaItem) async throws -> Void) async throws {
        let pairs = try await makePairs()
        try await addHashingTail()
        let detector = DuplicateDetector(db: database)
        let scan = Task { try await detector.detectDuplicates() }
        do {
            try await waitForHashingTail(detector)
            try await change(database, pairs[0][0])
            let count = try await scan.value
            XCTAssertEqual(count, 1)
            let groups = try await detector.fetchAllGroups()
            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(Set(try XCTUnwrap(groups.first).itemIds), Set(pairs[1].map(\.id)))
            let progress = await detector.getProgress()
            XCTAssertEqual(progress, .complete(groupsFound: 1, changedItems: 1))
        } catch {
            await detector.cancelDetection()
            _ = await scan.result
            throw error
        }
    }

    private func waitForHashingTail(_ detector: DuplicateDetector, minimum: Int = 4) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var observedScanning = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            let progress = await detector.getProgress()
            if case .scanning(let phase, let current, let total) = progress {
                observedScanning = true
                if phase == "Verifying media bytes", current >= minimum, current < total - 1 { return }
            }
            // The scan Task may not have started yet; its predecessor's terminal
            // progress must not end this wait before the new scan is observed.
            if observedScanning {
                if case .complete = progress { break }
                if case .failed = progress { break }
            }
            await Task.yield()
        }
        XCTFail("Scan did not expose a mid-hash checkpoint")
        throw GateError.missedCheckpoint
    }

    private func makePairs() async throws -> [[MediaItem]] {
        let first = Data("first pair".utf8), second = Data("second pair".utf8)
        return [[try await item(1, contents: first), try await item(2, contents: first)],
                [try await item(3, contents: second), try await item(4, contents: second)]]
    }

    private func addHashingTail() async throws {
        // Real, bounded reads keep the scan busy after the small pair evidence is complete.
        for index in 5...12 {
            _ = try await item(index, contents: Data(repeating: UInt8(index), count: 8 * 1024 * 1024))
        }
    }

    private func item(_ index: Int, contents: Data?) async throws -> MediaItem {
        let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
        let folder = directory.appendingPathComponent("item-\(index)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("media.bin")
        if let contents { try contents.write(to: file) }
        let value = MediaItem(id: id, basePath: folder, metadataFile: folder.appendingPathComponent("item.md"),
            mediaFiles: contents == nil ? [] : [file], metadata: MediaMetadata(source: URL(string: "https://example.com/\(index)")!, platform: "test"))
        let record = MediaItemRecord(from: value)
        try await database.write { try record.insert($0) }
        return value
    }

    private struct CacheRow: Equatable, Sendable {
        let path: String
        let versionJSON: String
        let sha256: String
    }

    private func cacheRows() async throws -> [CacheRow] {
        try await database.read { database in
            try Row.fetchAll(database, sql: "SELECT path, versionJSON, sha256 FROM duplicate_digest_cache ORDER BY path").map {
                CacheRow(path: $0["path"], versionJSON: $0["versionJSON"], sha256: $0["sha256"])
            }
        }
    }

    private enum GateError: Error { case missedCheckpoint }
}
