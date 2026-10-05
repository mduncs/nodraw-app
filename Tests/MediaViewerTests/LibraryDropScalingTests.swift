import XCTest
import GRDB
@testable import MediaViewer

final class LibraryDropScalingTests: XCTestCase {
    func testEightThousandItemsAndFiftyFileDropBuildsOneIndex() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["NODRAW_DROP_SCALE_BENCH"] == "1" else {
            throw XCTSkip("Set NODRAW_DROP_SCALE_BENCH=1 to run the synthetic import scaling benchmark")
        }
        let output = URL(fileURLWithPath: try XCTUnwrap(environment["NODRAW_DROP_SCALE_ROOT"]))
        let fixture = output.appendingPathComponent("fixture-\(UUID())")
        let archive = fixture.appendingPathComponent("archive")
        let inputs = fixture.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let database = DatabaseManager(databaseURL: fixture.appendingPathComponent("fixture.sqlite"))
        try await database.initialize()
        let store = MediaStore(database: database)
        let itemCount = 8_000
        let duplicateCount = 25
        let newCount = 25
        var records: [MediaItemRecord] = []
        records.reserveCapacity(itemCount)
        let fixtureStarted = ProcessInfo.processInfo.systemUptime
        for index in 0..<itemCount {
            try Task.checkCancellation()
            try autoreleasepool {
                let stem = String(format: "post-%04d", index)
                let media = archive.appendingPathComponent(stem + ".png")
                let sidecar = archive.appendingPathComponent(stem + ".md")
                try Self.mediaBytes(index).write(to: media)
                try "---\nsource: https://example.com/scale/\(index)\nplatform: test\n---\n".write(
                    to: sidecar, atomically: false, encoding: .utf8)
                let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
                let item = MediaItem(id: id, basePath: archive.appendingPathComponent(stem),
                    metadataFile: sidecar, mediaFiles: [media],
                    metadata: MediaMetadata(source: URL(string: "https://example.com/scale/\(index)")!, platform: "test"))
                records.append(MediaItemRecord(from: item))
            }
        }
        let inserted = records
        try await database.write { db in
            for record in inserted { try record.insertWithFTSSync(db: db) }
        }
        records.removeAll()
        var dropped: [URL] = []
        for index in 0..<duplicateCount {
            let source = inputs.appendingPathComponent("existing-\(index).png")
            try Self.mediaBytes(index).write(to: source)
            dropped.append(source)
        }
        for index in 0..<newCount {
            let source = inputs.appendingPathComponent("new-\(index).png")
            var bytes = Self.mediaBytes(itemCount + index)
            bytes.append(Data(repeating: 91, count: 512))
            try bytes.write(to: source)
            dropped.append(source)
        }
        let fixtureSeconds = ProcessInfo.processInfo.systemUptime - fixtureStarted
        let observations = Observations()
        let importer = ImportService(mediaStore: store, visionQueue: nil, archivePath: archive,
            libraryFileVersionReader: { url in
                observations.recordRead(url)
                return try DuplicateFileVersion.read(url)
            }, libraryIndexDidBuild: { observations.recordBuild($0) })
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await importer.importFiles(dropped, options: .fileDrop)
        let totalSeconds = ProcessInfo.processInfo.systemUptime - started
        let state = observations.snapshot()
        let metrics = try XCTUnwrap(state.builds.first)
        let remainingSeconds = max(0, totalSeconds - metrics.durationSeconds)
        let rows = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items") ?? 0 }
        let cacheRows = try await database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM duplicate_digest_cache") ?? 0 }
        let journalCount = try ImportOperationJournal(archivePath: archive).operations().count
        let report: [String: Any] = [
            "methodology": "8,000 live items seeded in one SQLite write; each has a real PNG-plus-padding media file and sidecar. Fifty external files are dropped through real ImportService: 25 byte-identical copies of the first 25 items and 25 unique files of a different size. Elapsed time includes duplicate checks, hashing, durable copying, sidecars, journals and DB publication for all 25 new files. Remaining average subtracts only the measured one-time index duration; it includes these publication costs and is not pure lookup latency. Media are tiny synthetic files, not representative large videos.",
            "fixtureRoot": fixture.path,
            "fixtureCreationSeconds": fixtureSeconds,
            "libraryItemsBefore": itemCount,
            "dropCount": dropped.count,
            "importedCount": result.importedCount,
            "skippedCount": result.skippedCount,
            "failedCount": result.failedCount,
            "errors": result.errors.map(\.reason),
            "libraryRowsAfter": rows,
            "journalCount": journalCount,
            "digestCacheRows": cacheRows,
            "indexBuildCount": state.builds.count,
            "indexItemCount": metrics.itemCount,
            "indexFileCount": metrics.fileCount,
            "indexPageCount": metrics.pageCount,
            "indexVersionReadCalls": state.reads.values.reduce(0, +),
            "indexUniquePathsRead": state.reads.count,
            "indexMaximumReadsPerPath": state.reads.values.max() ?? 0,
            "indexDurationSeconds": metrics.durationSeconds,
            "totalDropSeconds": totalSeconds,
            "remainingSecondsAfterIndex": remainingSeconds,
            "remainingAverageSecondsPerDroppedFile": remainingSeconds / Double(dropped.count)
        ]
        let reportURL = output.appendingPathComponent("library-drop-scaling.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
        print("Library drop scaling report: \(reportURL.path)")
        XCTAssertEqual(result.importedCount, newCount)
        XCTAssertEqual(result.skippedCount, duplicateCount)
        XCTAssertEqual(result.failedCount, 0, result.errors.map(\.reason).joined(separator: "; "))
        XCTAssertEqual(result.skippedItems.count, duplicateCount)
        XCTAssertEqual(rows, itemCount + newCount)
        XCTAssertEqual(journalCount, newCount)
        XCTAssertEqual(state.builds.count, 1)
        XCTAssertEqual(metrics.itemCount, itemCount)
        XCTAssertEqual(metrics.fileCount, itemCount)
        XCTAssertGreaterThanOrEqual(metrics.pageCount, 40)
        XCTAssertEqual(state.reads.count, itemCount)
        XCTAssertTrue(state.reads.values.allSatisfy { $0 == 1 })
        await store.writeBackQueue.flushNow()
    }

    private static func mediaBytes(_ index: Int) -> Data {
        var bytes = ImportDurabilityTests.png
        bytes.append(Data(String(format: "%032d", index).utf8))
        return bytes
    }

    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var reads: [String: Int] = [:]
        private var builds: [ImportLibraryDuplicatePrevention.IndexMetrics] = []

        func recordRead(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            reads[url.path, default: 0] += 1
        }

        func recordBuild(_ metrics: ImportLibraryDuplicatePrevention.IndexMetrics) {
            lock.lock()
            defer { lock.unlock() }
            builds.append(metrics)
        }

        func snapshot() -> (reads: [String: Int], builds: [ImportLibraryDuplicatePrevention.IndexMetrics]) {
            lock.lock()
            defer { lock.unlock() }
            return (reads, builds)
        }
    }
}
