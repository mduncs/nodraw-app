import XCTest
import GRDB
@testable import MediaViewer

/// Tests for Infinite Canvas functionality including:
/// - SpatialHash for viewport queries
/// - CanvasLOD transitions
/// - CanvasLayoutManager operations
/// - Position persistence
final class CanvasTests: XCTestCase {

    // MARK: - SpatialHash Tests

    func testSpatialHashInsertAndQuery() {
        let hash = SpatialHash(cellSize: 100)

        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        // Insert items in different locations
        hash.upsert(id: id1, frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        hash.upsert(id: id2, frame: CGRect(x: 150, y: 150, width: 50, height: 50))
        hash.upsert(id: id3, frame: CGRect(x: 500, y: 500, width: 50, height: 50))

        XCTAssertEqual(hash.itemCount, 3)

        // Query viewport that includes id1 and id2
        let visibleInViewport1 = hash.query(rect: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertTrue(visibleInViewport1.contains(id1))
        XCTAssertTrue(visibleInViewport1.contains(id2))
        XCTAssertFalse(visibleInViewport1.contains(id3))

        // Query viewport that only includes id3
        let visibleInViewport2 = hash.query(rect: CGRect(x: 450, y: 450, width: 200, height: 200))
        XCTAssertFalse(visibleInViewport2.contains(id1))
        XCTAssertFalse(visibleInViewport2.contains(id2))
        XCTAssertTrue(visibleInViewport2.contains(id3))
    }

    func testSpatialHashUpdate() {
        let hash = SpatialHash(cellSize: 100)
        let id = UUID()

        // Insert at one location
        hash.upsert(id: id, frame: CGRect(x: 0, y: 0, width: 50, height: 50))

        // Verify visible in original location
        var visible = hash.query(rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertTrue(visible.contains(id))

        // Move to new location
        hash.upsert(id: id, frame: CGRect(x: 500, y: 500, width: 50, height: 50))

        // Should NOT be visible in original location
        visible = hash.query(rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(visible.contains(id))

        // Should be visible in new location
        visible = hash.query(rect: CGRect(x: 450, y: 450, width: 100, height: 100))
        XCTAssertTrue(visible.contains(id))
    }

    func testSpatialHashRemove() {
        let hash = SpatialHash(cellSize: 100)
        let id = UUID()

        hash.upsert(id: id, frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(hash.itemCount, 1)

        hash.remove(id: id)
        XCTAssertEqual(hash.itemCount, 0)

        let visible = hash.query(rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(visible.contains(id))
    }

    func testSpatialHashClear() {
        let hash = SpatialHash(cellSize: 100)

        for i in 0..<100 {
            let id = UUID()
            hash.upsert(id: id, frame: CGRect(x: CGFloat(i * 10), y: CGFloat(i * 10), width: 50, height: 50))
        }
        XCTAssertEqual(hash.itemCount, 100)

        hash.clear()
        XCTAssertEqual(hash.itemCount, 0)
        XCTAssertEqual(hash.bucketCount, 0)
    }

    func testSpatialHashLargeItemSpanningCells() {
        let hash = SpatialHash(cellSize: 100)
        let id = UUID()

        // Insert large item spanning multiple cells
        hash.upsert(id: id, frame: CGRect(x: 50, y: 50, width: 200, height: 200))

        // Should be visible from any overlapping cell
        XCTAssertTrue(hash.query(rect: CGRect(x: 0, y: 0, width: 50, height: 50)).contains(id))
        XCTAssertTrue(hash.query(rect: CGRect(x: 100, y: 100, width: 50, height: 50)).contains(id))
        XCTAssertTrue(hash.query(rect: CGRect(x: 200, y: 200, width: 50, height: 50)).contains(id))

        // Should NOT be visible from non-overlapping areas
        XCTAssertFalse(hash.query(rect: CGRect(x: 300, y: 300, width: 50, height: 50)).contains(id))
    }

    // MARK: - CanvasLOD Tests

    func testCanvasLODForScale() {
        // Test threshold boundaries
        XCTAssertEqual(CanvasLOD.forScale(0.05), .dot)
        XCTAssertEqual(CanvasLOD.forScale(0.09), .dot)
        XCTAssertEqual(CanvasLOD.forScale(0.1), .micro)
        XCTAssertEqual(CanvasLOD.forScale(0.24), .micro)
        XCTAssertEqual(CanvasLOD.forScale(0.25), .thumb)
        XCTAssertEqual(CanvasLOD.forScale(0.74), .thumb)
        XCTAssertEqual(CanvasLOD.forScale(0.75), .preview)
        XCTAssertEqual(CanvasLOD.forScale(1.49), .preview)
        XCTAssertEqual(CanvasLOD.forScale(1.5), .full)
        XCTAssertEqual(CanvasLOD.forScale(4.0), .full)
    }

    func testCanvasLODComparable() {
        XCTAssertTrue(CanvasLOD.dot < CanvasLOD.micro)
        XCTAssertTrue(CanvasLOD.micro < CanvasLOD.thumb)
        XCTAssertTrue(CanvasLOD.thumb < CanvasLOD.preview)
        XCTAssertTrue(CanvasLOD.preview < CanvasLOD.full)
    }

    func testCanvasLODThumbnailSize() {
        XCTAssertNil(CanvasLOD.dot.thumbnailSize)
        XCTAssertEqual(CanvasLOD.micro.thumbnailSize, .small)
        XCTAssertEqual(CanvasLOD.thumb.thumbnailSize, .small)
        XCTAssertEqual(CanvasLOD.preview.thumbnailSize, .medium)
        XCTAssertEqual(CanvasLOD.full.thumbnailSize, .medium)
    }

    // MARK: - CanvasDocument Model Tests

    func testCanvasDocumentInit() {
        let canvas = CanvasDocument(
            folderId: "2025-01",
            name: "My Canvas",
            viewportX: 100,
            viewportY: 200,
            zoomLevel: 1.5
        )

        XCTAssertEqual(canvas.folderId, "2025-01")
        XCTAssertEqual(canvas.name, "My Canvas")
        XCTAssertEqual(canvas.viewport, CGPoint(x: 100, y: 200))
        XCTAssertEqual(canvas.zoomLevel, 1.5)
    }

    func testCanvasDocumentViewportProperty() {
        var canvas = CanvasDocument()

        canvas.viewport = CGPoint(x: 500, y: 600)

        XCTAssertEqual(canvas.viewportX, 500)
        XCTAssertEqual(canvas.viewportY, 600)
        XCTAssertEqual(canvas.viewport, CGPoint(x: 500, y: 600))
    }

    // MARK: - CanvasItemPlacement Model Tests

    func testCanvasItemPlacementInit() {
        let canvasId = UUID()
        let mediaItemId = UUID()

        let placement = CanvasItemPlacement(
            canvasId: canvasId,
            mediaItemId: mediaItemId,
            x: 100,
            y: 200,
            width: 300,
            height: 400,
            zIndex: 5,
            isManuallyPlaced: true
        )

        XCTAssertEqual(placement.canvasId, canvasId)
        XCTAssertEqual(placement.mediaItemId, mediaItemId)
        XCTAssertEqual(placement.position, CGPoint(x: 100, y: 200))
        XCTAssertEqual(placement.size, CGSize(width: 300, height: 400))
        XCTAssertEqual(placement.frame, CGRect(x: 100, y: 200, width: 300, height: 400))
        XCTAssertEqual(placement.zIndex, 5)
        XCTAssertTrue(placement.isManuallyPlaced)
    }

    func testCanvasItemPlacementFrameProperty() {
        var placement = CanvasItemPlacement(
            canvasId: UUID(),
            mediaItemId: UUID()
        )

        placement.position = CGPoint(x: 50, y: 100)
        placement.size = CGSize(width: 200, height: 150)

        XCTAssertEqual(placement.frame, CGRect(x: 50, y: 100, width: 200, height: 150))
    }

    // MARK: - Performance Tests

    func testSpatialHashPerformanceWith10000Items() {
        let hash = SpatialHash(cellSize: 500)

        // Insert 10,000 items
        var ids: [UUID] = []
        for i in 0..<10000 {
            let id = UUID()
            ids.append(id)
            let x = CGFloat(i % 100) * 200
            let y = CGFloat(i / 100) * 200
            hash.upsert(id: id, frame: CGRect(x: x, y: y, width: 150, height: 150))
        }

        XCTAssertEqual(hash.itemCount, 10000)

        // Measure query performance
        measure {
            for _ in 0..<1000 {
                let x = CGFloat.random(in: 0...20000)
                let y = CGFloat.random(in: 0...20000)
                _ = hash.query(rect: CGRect(x: x, y: y, width: 1000, height: 800))
            }
        }
    }

    func testSpatialHashQueryReturnsCorrectSubset() {
        let hash = SpatialHash(cellSize: 100)

        // Create a grid of items
        var allIds: [UUID] = []
        for row in 0..<10 {
            for col in 0..<10 {
                let id = UUID()
                allIds.append(id)
                let x = CGFloat(col) * 100
                let y = CGFloat(row) * 100
                hash.upsert(id: id, frame: CGRect(x: x, y: y, width: 80, height: 80))
            }
        }

        // Query a 3x3 area in the middle
        let visible = hash.query(rect: CGRect(x: 250, y: 250, width: 300, height: 300))

        // Should return a subset (approximately 9-16 items due to buffer)
        XCTAssertGreaterThan(visible.count, 0)
        XCTAssertLessThan(visible.count, 100)
    }
}

// MARK: - Database Integration Tests

final class CanvasDatabaseTests: XCTestCase {

    private var testPool: DatabasePool!
    private var tempDir: URL!

    override func setUpWithError() throws {
        // Create temp directory
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create test database
        let dbPath = tempDir.appendingPathComponent("test.sqlite")
        testPool = try DatabasePool(path: dbPath.path)

        // Run migrations
        try testPool.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try MediaItemRecord.createTable(in: db)
            try CanvasDocument.createTable(in: db)
            try CanvasItemPlacement.createTable(in: db)
        }
    }

    override func tearDownWithError() throws {
        testPool = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testCanvasDocumentPersistence() async throws {
        let canvas = CanvasDocument(
            folderId: "2025-01",
            name: "Test Canvas",
            viewportX: 100,
            viewportY: 200,
            zoomLevel: 1.5
        )

        // Insert
        try await testPool.write { db in
            try canvas.insert(db)
        }

        // Fetch
        let fetched = try await testPool.read { db in
            try CanvasDocument.fetchOne(
                db,
                sql: "SELECT * FROM canvas_documents WHERE id = ?",
                arguments: [canvas.id.uuidString]
            )
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, canvas.id)
        XCTAssertEqual(fetched?.folderId, "2025-01")
        XCTAssertEqual(fetched?.name, "Test Canvas")
        XCTAssertEqual(fetched?.viewportX, 100)
        XCTAssertEqual(fetched?.viewportY, 200)
        XCTAssertEqual(fetched?.zoomLevel, 1.5)
    }

    func testCanvasItemPlacementPersistence() async throws {
        // First create a canvas
        let canvas = CanvasDocument(folderId: "test")
        try await testPool.write { db in
            try canvas.insert(db)
        }

        // Create a media item
        let mediaItem = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: mediaItem).insert(db)
        }

        // Create placement
        let placement = CanvasItemPlacement(
            canvasId: canvas.id,
            mediaItemId: mediaItem.id,
            x: 100,
            y: 200,
            width: 300,
            height: 400,
            zIndex: 5,
            isManuallyPlaced: true
        )

        try await testPool.write { db in
            try placement.insert(db)
        }

        // Fetch
        let fetched = try await testPool.read { db in
            try CanvasItemPlacement.fetchForCanvas(db: db, canvasId: canvas.id)
        }

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.mediaItemId, mediaItem.id)
        XCTAssertEqual(fetched.first?.x, 100)
        XCTAssertEqual(fetched.first?.y, 200)
        XCTAssertEqual(fetched.first?.width, 300)
        XCTAssertEqual(fetched.first?.height, 400)
        XCTAssertEqual(fetched.first?.zIndex, 5)
        XCTAssertEqual(fetched.first?.isManuallyPlaced, true)
    }

    func testFetchPlacementsInViewport() async throws {
        // Create canvas
        let canvas = CanvasDocument(folderId: "test")
        try await testPool.write { db in
            try canvas.insert(db)
        }

        // Create media items and placements at different positions
        for i in 0..<10 {
            let mediaItem = createTestMediaItem()
            try await testPool.write { db in
                try MediaItemRecord(from: mediaItem).insert(db)

                let placement = CanvasItemPlacement(
                    canvasId: canvas.id,
                    mediaItemId: mediaItem.id,
                    x: CGFloat(i * 500),  // Spread out horizontally
                    y: 0,
                    width: 200,
                    height: 200,
                    zIndex: i
                )
                try placement.insert(db)
            }
        }

        // Fetch only items in viewport (first 1000px)
        let visiblePlacements = try await testPool.read { db in
            try CanvasItemPlacement.fetchInViewport(
                db: db,
                canvasId: canvas.id,
                viewport: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                buffer: 100
            )
        }

        // Should get ~3 items (0, 500, 1000 positions within 1000px + 100 buffer)
        XCTAssertGreaterThan(visiblePlacements.count, 0)
        XCTAssertLessThan(visiblePlacements.count, 10)
    }

    func testCanvasLayoutManagerVisibilityStateReportsOffscreenItems() async throws {
        let databaseURL = tempDir.appendingPathComponent("canvas-layout.sqlite")
        let database = DatabaseManager(databaseURL: databaseURL)
        try await database.initialize()

        let canvas = CanvasDocument(folderId: "test")
        let visibleItem = createTestMediaItem()
        let offscreenItem = createTestMediaItem()

        try await database.write { db in
            try canvas.insert(db)
            try MediaItemRecord(from: visibleItem).insert(db)
            try MediaItemRecord(from: offscreenItem).insert(db)

            try CanvasItemPlacement(
                canvasId: canvas.id,
                mediaItemId: visibleItem.id,
                x: 0,
                y: 0,
                width: 200,
                height: 200,
                zIndex: 0
            ).insert(db)

            try CanvasItemPlacement(
                canvasId: canvas.id,
                mediaItemId: offscreenItem.id,
                x: 5000,
                y: 5000,
                width: 200,
                height: 200,
                zIndex: 1
            ).insert(db)
        }

        let manager = CanvasLayoutManager(database: database, cellSize: 500)
        try await manager.loadCanvas(canvas.id)

        let state = await manager.visibilityState(
            in: CGRect(x: 0, y: 0, width: 400, height: 400),
            buffer: 0
        )

        XCTAssertEqual(state.totalCount, 2)
        XCTAssertEqual(state.indexedCount, 2)
        XCTAssertEqual(state.visiblePlacements.count, 1)
        XCTAssertEqual(state.visiblePlacements.first?.mediaItemId, visibleItem.id)

        let emptyViewportState = await manager.visibilityState(
            in: CGRect(x: 1000, y: 1000, width: 400, height: 400),
            buffer: 0
        )

        XCTAssertEqual(emptyViewportState.totalCount, 2)
        XCTAssertEqual(emptyViewportState.indexedCount, 2)
        XCTAssertTrue(emptyViewportState.visiblePlacements.isEmpty)
    }

    func testCascadeDeleteOnCanvasDelete() async throws {
        // Create canvas
        let canvas = CanvasDocument(folderId: "test")
        try await testPool.write { db in
            try canvas.insert(db)
        }

        // Create media item and placement
        let mediaItem = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: mediaItem).insert(db)

            let placement = CanvasItemPlacement(
                canvasId: canvas.id,
                mediaItemId: mediaItem.id,
                x: 0, y: 0, width: 100, height: 100
            )
            try placement.insert(db)
        }

        // Verify placement exists
        var count = try await testPool.read { db in
            try CanvasItemPlacement.fetchCount(db)
        }
        XCTAssertEqual(count, 1)

        // Delete canvas
        try await testPool.write { db in
            try db.execute(
                sql: "DELETE FROM canvas_documents WHERE id = ?",
                arguments: [canvas.id.uuidString]
            )
        }

        // Placement should be cascade deleted
        count = try await testPool.read { db in
            try CanvasItemPlacement.fetchCount(db)
        }
        XCTAssertEqual(count, 0)
    }

    func testCascadeDeleteOnMediaItemDelete() async throws {
        // Create canvas
        let canvas = CanvasDocument(folderId: "test")
        try await testPool.write { db in
            try canvas.insert(db)
        }

        // Create media item and placement
        let mediaItem = createTestMediaItem()
        try await testPool.write { db in
            try MediaItemRecord(from: mediaItem).insert(db)

            let placement = CanvasItemPlacement(
                canvasId: canvas.id,
                mediaItemId: mediaItem.id,
                x: 0, y: 0, width: 100, height: 100
            )
            try placement.insert(db)
        }

        // Delete media item
        try await testPool.write { db in
            try db.execute(
                sql: "DELETE FROM media_items WHERE id = ?",
                arguments: [mediaItem.id.uuidString]
            )
        }

        // Placement should be cascade deleted
        let count = try await testPool.read { db in
            try CanvasItemPlacement.fetchCount(db)
        }
        XCTAssertEqual(count, 0)

        // Canvas should still exist
        let canvasExists = try await testPool.read { db in
            try CanvasDocument.fetchOne(
                db,
                sql: "SELECT * FROM canvas_documents WHERE id = ?",
                arguments: [canvas.id.uuidString]
            )
        }
        XCTAssertNotNil(canvasExists)
    }

    // MARK: - Helpers

    private func createTestMediaItem() -> MediaItem {
        MediaItem(
            id: UUID(),
            basePath: URL(fileURLWithPath: "/tmp/test"),
            metadataFile: URL(fileURLWithPath: "/tmp/test/\(UUID().uuidString).md"),
            mediaFiles: [URL(fileURLWithPath: "/tmp/test/media.jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/post")!,
                platform: "test",
                author: "@test"
            )
        )
    }
}
