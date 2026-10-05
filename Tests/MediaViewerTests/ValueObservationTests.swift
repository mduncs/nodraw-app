import XCTest
import GRDB
import Combine
@testable import MediaViewer

/// Tests for GRDB ValueObservation integration.
/// Validates that observation fires on background writes, removeDuplicates works,
/// and observation recreation on window change functions correctly.
@MainActor
final class ValueObservationTests: XCTestCase {

    private var testPool: DatabasePool!
    private var tempDir: URL!
    private var cancellables: Set<AnyCancellable> = []

    override func setUpWithError() throws {
        // Create temp directory
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ValueObservationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create test database
        let dbPath = tempDir.appendingPathComponent("test.sqlite")
        testPool = try DatabasePool(path: dbPath.path)

        // Run migrations
        try testPool.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try MediaItemRecord.createTable(in: db)
            try SmartFolder.createTable(in: db)

            // Add columns from migrations
            try? db.execute(sql: "ALTER TABLE media_items ADD COLUMN deletedAt DATETIME")

            // Create junction tables
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS media_tags (
                    item_id TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    PRIMARY KEY (item_id, tag),
                    FOREIGN KEY (item_id) REFERENCES media_items(id) ON DELETE CASCADE
                )
            """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS media_colors (
                    item_id TEXT NOT NULL,
                    color_bucket TEXT NOT NULL,
                    PRIMARY KEY (item_id, color_bucket),
                    FOREIGN KEY (item_id) REFERENCES media_items(id) ON DELETE CASCADE
                )
            """)
        }
    }

    override func tearDownWithError() throws {
        cancellables.removeAll()
        testPool = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Basic Observation Tests

    func testObservationFiresOnInsert() async throws {
        let expectation = XCTestExpectation(description: "Observation fires on insert")
        expectation.expectedFulfillmentCount = 2 // Initial + after insert

        var receivedCounts: [Int] = []

        // Create observation
        let observation = ValueObservation.tracking { db in
            try MediaItemRecord.fetchAll(db)
        }

        let cancellable = observation
            .publisher(in: testPool, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { records in
                    receivedCounts.append(records.count)
                    expectation.fulfill()
                }
            )
        cancellables.insert(cancellable)

        // Insert an item
        let item = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(receivedCounts.count, 2)
        XCTAssertEqual(receivedCounts[0], 0) // Initial empty
        XCTAssertEqual(receivedCounts[1], 1) // After insert
    }

    func testObservationFiresOnUpdate() async throws {
        // Insert initial item
        let item = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        let expectation = XCTestExpectation(description: "Observation fires on update")
        expectation.expectedFulfillmentCount = 2 // Initial + after update

        var receivedRecords: [[MediaItemRecord]] = []

        // Create observation
        let observation = ValueObservation.tracking { db in
            try MediaItemRecord.fetchAll(db)
        }

        let cancellable = observation
            .publisher(in: testPool, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { records in
                    receivedRecords.append(records)
                    expectation.fulfill()
                }
            )
        cancellables.insert(cancellable)

        // Update the item
        try await testPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET starred = 1 WHERE id = ?",
                arguments: [item.id.uuidString]
            )
        }

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(receivedRecords.count, 2)
        XCTAssertFalse(receivedRecords[0].first?.starred ?? true) // Initial unstarred
        XCTAssertTrue(receivedRecords[1].first?.starred ?? false) // After update starred
    }

    func testObservationFiresOnDelete() async throws {
        // Insert initial item
        let item = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        let expectation = XCTestExpectation(description: "Observation fires on delete")
        expectation.expectedFulfillmentCount = 2 // Initial + after delete

        var receivedCounts: [Int] = []

        // Create observation
        let observation = ValueObservation.tracking { db in
            try MediaItemRecord.fetchAll(db)
        }

        let cancellable = observation
            .publisher(in: testPool, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { records in
                    receivedCounts.append(records.count)
                    expectation.fulfill()
                }
            )
        cancellables.insert(cancellable)

        // Delete the item
        try await testPool.write { db in
            try db.execute(
                sql: "DELETE FROM media_items WHERE id = ?",
                arguments: [item.id.uuidString]
            )
        }

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(receivedCounts.count, 2)
        XCTAssertEqual(receivedCounts[0], 1) // Initial with item
        XCTAssertEqual(receivedCounts[1], 0) // After delete
    }

    // MARK: - RemoveDuplicates Tests

    func testRemoveDuplicatesPreventsspuriousUpdates() async throws {
        // Insert initial item
        let item = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        let expectation = XCTestExpectation(description: "RemoveDuplicates filters spurious updates")
        // Should only receive initial value, not repeated identical values
        expectation.expectedFulfillmentCount = 1

        var receivedCount = 0

        // Create observation with removeDuplicates
        let observation = ValueObservation.tracking { db in
            try MediaItemRecord.fetchAll(db)
        }

        let cancellable = observation
            .removeDuplicates()
            .publisher(in: testPool, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { _ in
                    receivedCount += 1
                    expectation.fulfill()
                }
            )
        cancellables.insert(cancellable)

        // Trigger a read (no actual change) - this should NOT fire observation
        // because removeDuplicates filters identical results
        _ = try await testPool.read { db in
            try MediaItemRecord.fetchCount(db)
        }

        // Wait briefly to ensure no additional updates
        try await Task.sleep(for: .milliseconds(100))

        // Should only have received initial value
        XCTAssertEqual(receivedCount, 1)
    }

    func testRemoveDuplicatesAllowsDifferentValues() async throws {
        // Insert initial item
        let item = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: item).insert(db)
        }

        let expectation = XCTestExpectation(description: "RemoveDuplicates allows different values")
        expectation.expectedFulfillmentCount = 2 // Initial + actual change

        var receivedRecords: [[MediaItemRecord]] = []

        // Create observation with removeDuplicates
        let observation = ValueObservation.tracking { db in
            try MediaItemRecord.fetchAll(db)
        }

        let cancellable = observation
            .removeDuplicates()
            .publisher(in: testPool, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { records in
                    receivedRecords.append(records)
                    expectation.fulfill()
                }
            )
        cancellables.insert(cancellable)

        // Make an actual change
        try await testPool.write { db in
            try db.execute(
                sql: "UPDATE media_items SET notes = ? WHERE id = ?",
                arguments: ["Updated notes", item.id.uuidString]
            )
        }

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(receivedRecords.count, 2)
        XCTAssertNil(receivedRecords[0].first?.notes)
        XCTAssertEqual(receivedRecords[1].first?.notes, "Updated notes")
    }

    // MARK: - Windowed Observation Tests

    func testWindowedObservationWithLimit() async throws {
        // Insert 10 items
        for i in 0..<10 {
            let item = createTestMediaItem(platform: "platform_\(i)")
            try await testPool.write { db in
                try MediaItemRecord(from: item).insert(db)
            }
        }

        let expectation = XCTestExpectation(description: "Windowed observation respects limit")

        var receivedCount = 0

        // Create windowed observation with limit 5
        let observation = ValueObservation.tracking { db in
            try MediaItemRecord
                .order(Column("archivedDate").desc)
                .limit(5, offset: 0)
                .fetchAll(db)
        }

        let cancellable = observation
            .publisher(in: testPool, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { records in
                    receivedCount = records.count
                    expectation.fulfill()
                }
            )
        cancellables.insert(cancellable)

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(receivedCount, 5) // Only 5 items due to limit
    }

    func testWindowedObservationWithOffset() async throws {
        // Insert 10 items with sequential dates
        for i in 0..<10 {
            let item = createTestMediaItem(
                platform: "platform_\(String(format: "%02d", i))",
                archivedDate: Date().addingTimeInterval(Double(i) * 60) // Staggered by 1 minute
            )
            try await testPool.write { db in
                try MediaItemRecord(from: item).insert(db)
            }
        }

        let expectation = XCTestExpectation(description: "Windowed observation respects offset")

        var receivedRecords: [MediaItemRecord] = []

        // Create windowed observation with offset 5
        let observation = ValueObservation.tracking { db in
            try MediaItemRecord
                .order(Column("platform").asc)
                .limit(5, offset: 5)
                .fetchAll(db)
        }

        let cancellable = observation
            .publisher(in: testPool, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { records in
                    receivedRecords = records
                    expectation.fulfill()
                }
            )
        cancellables.insert(cancellable)

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(receivedRecords.count, 5)
        // Should have items 5-9 (platform_05 through platform_09)
        XCTAssertEqual(receivedRecords.first?.platform, "platform_05")
    }

    func testWindowedObservationUpdatesOnRelevantChange() async throws {
        // Insert 10 items
        for i in 0..<10 {
            let item = createTestMediaItem(platform: "platform_\(i)")
            try await testPool.write { db in
                try MediaItemRecord(from: item).insert(db)
            }
        }

        let expectation = XCTestExpectation(description: "Windowed observation updates on change")
        expectation.expectedFulfillmentCount = 2 // Initial + after new insert in window

        var receivedCounts: [Int] = []

        // Observe first 5 items
        let observation = ValueObservation.tracking { db in
            try MediaItemRecord
                .order(Column("archivedDate").desc)
                .limit(5, offset: 0)
                .fetchAll(db)
        }

        let cancellable = observation
            .publisher(in: testPool, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { records in
                    receivedCounts.append(records.count)
                    expectation.fulfill()
                }
            )
        cancellables.insert(cancellable)

        // Insert a new item (should appear in window due to desc order)
        let newItem = createTestMediaItem(platform: "newest")
        try await testPool.write { db in
            try MediaItemRecord(from: newItem).insert(db)
        }

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(receivedCounts.count, 2)
        XCTAssertEqual(receivedCounts[0], 5) // Initial 5
        XCTAssertEqual(receivedCounts[1], 5) // Still 5 (newest pushed one out)
    }

    // MARK: - Background Write Detection

    func testObservationFiresOnBackgroundWrite() async throws {
        let expectation = XCTestExpectation(description: "Observation fires on background write")
        expectation.expectedFulfillmentCount = 2 // Initial + after background write

        var receivedCounts: [Int] = []

        // Create observation on main thread
        let observation = ValueObservation.tracking { db in
            try MediaItemRecord.fetchAll(db)
        }

        let cancellable = observation
            .publisher(in: testPool, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { records in
                    receivedCounts.append(records.count)
                    expectation.fulfill()
                }
            )
        cancellables.insert(cancellable)

        // Create item on main thread, then write on background queue
        let item = createTestMediaItem()
        let record = MediaItemRecord(from: item)
        Task.detached { [testPool] in
            try await testPool!.write { db in
                try record.insert(db)
            }
        }

        await fulfillment(of: [expectation], timeout: 2.0)

        XCTAssertEqual(receivedCounts.count, 2)
        XCTAssertEqual(receivedCounts[0], 0) // Initial empty
        XCTAssertEqual(receivedCounts[1], 1) // After background insert
    }

    // MARK: - Observation Recreation Tests

    func testObservationCanBeCancelledAndRecreated() async throws {
        // Insert initial items
        for i in 0..<5 {
            let item = createTestMediaItem(platform: "platform_\(i)")
            try await testPool.write { db in
                try MediaItemRecord(from: item).insert(db)
            }
        }

        let expectation1 = XCTestExpectation(description: "First observation")
        let expectation2 = XCTestExpectation(description: "Second observation")

        var observation1Count = 0
        var observation2Count = 0

        // First observation
        let observation1 = ValueObservation.tracking { db in
            try MediaItemRecord.limit(3, offset: 0).fetchAll(db)
        }

        var cancellable1: AnyCancellable? = observation1
            .publisher(in: testPool, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { records in
                    observation1Count = records.count
                    expectation1.fulfill()
                }
            )

        await fulfillment(of: [expectation1], timeout: 2.0)
        XCTAssertEqual(observation1Count, 3)

        // Cancel first observation
        cancellable1?.cancel()
        cancellable1 = nil

        // Create second observation with different window
        let observation2 = ValueObservation.tracking { db in
            try MediaItemRecord.limit(2, offset: 2).fetchAll(db)
        }

        let cancellable2 = observation2
            .publisher(in: testPool, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in },
                receiveValue: { records in
                    observation2Count = records.count
                    expectation2.fulfill()
                }
            )
        cancellables.insert(cancellable2)

        await fulfillment(of: [expectation2], timeout: 2.0)
        XCTAssertEqual(observation2Count, 2)
    }

    // MARK: - Helpers

    private func createTestMediaItem(
        platform: String = "twitter",
        author: String? = nil,
        archivedDate: Date = Date()
    ) -> MediaItem {
        let id = UUID()
        let basePath = URL(fileURLWithPath: "/test/archive/2025-01")
        let metadataFile = basePath.appendingPathComponent("\(id.uuidString).md")

        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: metadataFile,
            mediaFiles: [basePath.appendingPathComponent("\(id.uuidString).jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://\(platform).com/test/\(id.uuidString)")!,
                platform: platform,
                author: author ?? "@testuser",
                originalDate: Date(),
                archivedDate: archivedDate
            )
        )
    }
}
