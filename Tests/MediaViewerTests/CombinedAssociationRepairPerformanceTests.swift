import XCTest
import GRDB
@testable import MediaViewer

final class CombinedAssociationRepairPerformanceTests: XCTestCase {
    private var root: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!

    override func setUp() async throws {
        root = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("combined-event-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("archive"), withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: root.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        store = MediaStore(database: database)
    }

    override func tearDown() async throws {
        store = nil
        database = nil
        try FileManager.default.removeItem(at: root)
    }

    private func seed(count: Int, combinedCount: Int) async throws {
        let directory = root.appendingPathComponent("archive").path
        try await database.write { db in
            try db.execute(sql: """
                WITH RECURSIVE sequence(i) AS (
                    SELECT 0 UNION ALL SELECT i + 1 FROM sequence WHERE i + 1 < ?
                )
                INSERT INTO media_items (
                    id, basePathString, metadataFileString, mediaFilesJSON, contextImageString,
                    sourceURL, platform, archivedDate, deletedAt, deletionReason
                )
                SELECT printf('00000000-0000-0000-0000-%012d', i), ?, ? || '/item-' || i || '.md',
                    json_array(? || '/item-' || i || '.png'), ? || '/item-' || i || '.context.png',
                    'https://example.com/post/' || i, 'test', '2026-01-01 00:00:00.000',
                    CASE WHEN i < ? THEN '2026-01-02 00:00:00.000' END,
                    CASE WHEN i < ? THEN 'combined' END
                FROM sequence
                """, arguments: [count, directory, directory, directory, directory, combinedCount, combinedCount])
        }
    }

    private func unrelatedEvent() throws -> [URL: ArchiveItemFiles] {
        let directory = root.appendingPathComponent("live-event")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sidecar = directory.appendingPathComponent("post.md")
        let first = directory.appendingPathComponent("z.png")
        let second = directory.appendingPathComponent("a.png")
        try ImportDurabilityTests.png.write(to: first)
        try ImportDurabilityTests.png.write(to: second)
        return [sidecar.deletingPathExtension(): ArchiveItemFiles(metadataFile: sidecar, mediaFiles: [first, second])]
    }

    func testUnrelatedEventDoesNotUseWriterOrDecodeActiveRows() async throws {
        try await seed(count: 8, combinedCount: 7)
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET mediaFilesJSON = 'invalid JSON' WHERE deletionReason IS NULL")
        }
        let input = try unrelatedEvent()
        let pool = try await database.getPool()
        let trace = WriterTrace()
        try await pool.writeWithoutTransaction { db in db.trace { trace.append(String(describing: $0)) } }
        let result = try await store.reconcileCombinedAssociations(input)
        try await pool.writeWithoutTransaction { db in db.trace(options: []) }
        XCTAssertTrue(trace.statements.isEmpty, "Unrelated events must never acquire the writer transaction")
        XCTAssertEqual(result.keys.sorted(by: { $0.path < $1.path }), input.keys.sorted(by: { $0.path < $1.path }))
        XCTAssertEqual(result.values.first?.metadataFile, input.values.first?.metadataFile)
        XCTAssertEqual(result.values.first?.mediaFiles, input.values.first?.mediaFiles)
    }

    func testLiteralSidecarKeyStillEntersFullRepairWithNoStoredMedia() async throws {
        try await seed(count: 2, combinedCount: 1)
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET mediaFilesJSON = '[]', contextImageString = NULL WHERE deletionReason = 'combined'")
        }
        let key = root.appendingPathComponent("archive/item-0")
        let input = [key: ArchiveItemFiles(metadataFile: key.appendingPathExtension("md"))]
        let pool = try await database.getPool()
        let trace = WriterTrace()
        try await pool.writeWithoutTransaction { db in db.trace { trace.append(String(describing: $0)) } }
        _ = try await store.reconcileCombinedAssociations(input)
        try await pool.writeWithoutTransaction { db in db.trace(options: []) }
        XCTAssertTrue(trace.statements.contains { $0.uppercased().contains("BEGIN") })
    }

    func testEmptyEventDoesNotReadUnrelatedMalformedCombinedMetadata() async throws {
        try await seed(count: 1, combinedCount: 1)
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET mediaFilesJSON = 'invalid JSON'")
        }
        let result = try await store.reconcileCombinedAssociations([:])
        XCTAssertTrue(result.isEmpty)
    }

    func testLiveEventRepairCostWith8000RowsAnd7CombinedRows() async throws {
        try await seed(count: 8_000, combinedCount: 7)
        let input = try unrelatedEvent()
        let counts = try await database.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE deletionReason = 'combined'"))
        }
        XCTAssertEqual(counts.0, 8_000)
        XCTAssertEqual(counts.1, 7)
        // The full helper is the unchanged pre-optimization implementation.
        // Alternate pair order after warmup to reduce timing bias.
        for _ in 0..<2 {
            _ = try await store.reconcileCombinedAssociationsFullScan(input)
            _ = try await store.reconcileCombinedAssociations(input)
        }
        var before: [Double] = []
        var after: [Double] = []
        func measureFullScan() async throws -> Double {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = try await store.reconcileCombinedAssociationsFullScan(input)
            return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        }
        func measureUnrelatedEvent() async throws -> Double {
            let started = DispatchTime.now().uptimeNanoseconds
            let result = try await store.reconcileCombinedAssociations(input)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            XCTAssertEqual(result.values.first?.mediaFiles, input.values.first?.mediaFiles)
            return elapsed
        }
        for event in 0..<12 {
            if event.isMultiple(of: 2) {
                before.append(try await measureFullScan())
                after.append(try await measureUnrelatedEvent())
            } else {
                after.append(try await measureUnrelatedEvent())
                before.append(try await measureFullScan())
            }
        }
        func summary(_ samples: [Double]) -> [String: Double] {
            let sorted = samples.sorted()
            return ["median_ms": (sorted[5] + sorted[6]) / 2,
                    "mean_ms": samples.reduce(0, +) / Double(samples.count), "max_ms": sorted.last!]
        }
        let report: [String: Any] = ["rows": 8_000, "combined_rows": 7, "events_per_path": 12, "discovered_groups": input.count,
                                   "before": summary(before), "after": summary(after)]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("COMBINED_LIVE_EVENT_COST " + String(decoding: data, as: UTF8.self))
    }
}

private final class WriterTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ statement: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(statement)
    }

    var statements: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
