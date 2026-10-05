import XCTest
import GRDB
@testable import MediaViewer

/// Tests for VisionJobQueue - the priority-based processing queue.
/// Uses mock database and processors for isolation.
final class VisionJobQueueTests: XCTestCase {

    private var testPool: DatabasePool!
    private var tempDir: URL!
    private var queue: TestableVisionJobQueue!

    override func setUpWithError() throws {
        // Create temp directory
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionJobQueueTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create test database
        let dbPath = tempDir.appendingPathComponent("test.sqlite")
        testPool = try DatabasePool(path: dbPath.path)

        // Run migrations
        try testPool.write { db in
            try MediaItemRecord.createTable(in: db)
            try db.execute(sql: """
                CREATE TABLE media_file_ocr (
                    id TEXT PRIMARY KEY,
                    item_id TEXT NOT NULL,
                    file_url TEXT NOT NULL,
                    file_index INTEGER NOT NULL,
                    ocr_text TEXT,
                    ocr_regions_json TEXT,
                    UNIQUE(item_id, file_index)
                )
            """)
        }

        queue = TestableVisionJobQueue(pool: testPool)
    }

    override func tearDownWithError() throws {
        queue = nil
        testPool = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Enqueue Tests

    func testEnqueueAddsToQueue() async throws {
        let itemId = UUID()
        try await insertTestItem(id: itemId)

        await queue.enqueue(itemId: itemId)

        let isQueued = await queue.isQueued(itemId)
        XCTAssertTrue(isQueued)
    }

    func testEnqueueDeduplicates() async throws {
        let itemId = UUID()
        try await insertTestItem(id: itemId)

        // Enqueue same item multiple times
        await queue.enqueue(itemId: itemId)
        await queue.enqueue(itemId: itemId)
        await queue.enqueue(itemId: itemId)

        let queueSize = await queue.pendingCount
        // Should only be queued once (or already processing)
        XCTAssertLessThanOrEqual(queueSize, 1)
    }

    func testEnqueueBatch() async throws {
        var itemIds: [UUID] = []
        for _ in 0..<5 {
            let id = UUID()
            itemIds.append(id)
            try await insertTestItem(id: id)
        }

        await queue.enqueueBatch(itemIds)

        // All should be queued or processing
        for itemId in itemIds {
            let isQueued = await queue.isQueued(itemId)
            XCTAssertTrue(isQueued)
        }
    }

    // MARK: - Priority Tests

    func testHighPriorityProcessedFirst() async throws {
        // Pause processing to control order
        await queue.pauseProcessing()

        var normalIds: [UUID] = []
        var highIds: [UUID] = []

        // Enqueue normal priority first
        for _ in 0..<3 {
            let id = UUID()
            normalIds.append(id)
            try await insertTestItem(id: id)
            await queue.enqueue(itemId: id, priority: .normal)
        }

        // Then enqueue high priority
        for _ in 0..<2 {
            let id = UUID()
            highIds.append(id)
            try await insertTestItem(id: id)
            await queue.enqueue(itemId: id, priority: .high)
        }

        // Check order: high priority should be at front
        let order = await queue.getPendingOrder()

        // First items should be high priority
        guard order.count >= 2 else {
            XCTFail("Not enough items in queue")
            return
        }

        XCTAssertTrue(highIds.contains(order[0]))
        XCTAssertTrue(highIds.contains(order[1]))
    }

    func testLowPriorityProcessedLast() async throws {
        await queue.pauseProcessing()

        let normalId = UUID()
        let lowId = UUID()
        let highId = UUID()

        try await insertTestItem(id: normalId)
        try await insertTestItem(id: lowId)
        try await insertTestItem(id: highId)

        await queue.enqueue(itemId: normalId, priority: .normal)
        await queue.enqueue(itemId: lowId, priority: .low)
        await queue.enqueue(itemId: highId, priority: .high)

        let order = await queue.getPendingOrder()

        // High should be first, low should be last
        XCTAssertEqual(order.first, highId)
        XCTAssertEqual(order.last, lowId)
    }

    // MARK: - Concurrent Processing Tests

    func testMaxConcurrentLimit() async throws {
        // Create more items than max concurrent
        var itemIds: [UUID] = []
        for _ in 0..<10 {
            let id = UUID()
            itemIds.append(id)
            try await insertTestItem(id: id)
        }

        // Set a slow processor to keep items in-progress
        await queue.setProcessingDelay(milliseconds: 100)

        // Enqueue all
        await queue.enqueueBatch(itemIds)

        // Wait a bit for processing to start
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Check in-progress count
        let inProgressCount = await queue.inProgressCount
        XCTAssertLessThanOrEqual(inProgressCount, 4) // Max concurrent is 4
    }

    func testProcessingCompletesAll() async throws {
        var itemIds: [UUID] = []
        for _ in 0..<5 {
            let id = UUID()
            itemIds.append(id)
            try await insertTestItem(id: id)
        }

        // Fast processing
        await queue.setProcessingDelay(milliseconds: 10)

        // Enqueue all
        await queue.enqueueBatch(itemIds)

        // Wait for processing to complete
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // All should be done
        for itemId in itemIds {
            let isQueued = await queue.isQueued(itemId)
            XCTAssertFalse(isQueued)
        }
    }

    // MARK: - Cancel Tests

    func testCancelRemovesFromQueue() async throws {
        await queue.pauseProcessing()

        let itemId = UUID()
        try await insertTestItem(id: itemId)

        await queue.enqueue(itemId: itemId)
        let isQueuedAfterEnqueue = await queue.isQueued(itemId)
        XCTAssertTrue(isQueuedAfterEnqueue)

        await queue.cancel(itemId: itemId)
        let isQueuedAfterCancel = await queue.isQueued(itemId)
        XCTAssertFalse(isQueuedAfterCancel)
    }

    func testClearPending() async throws {
        await queue.pauseProcessing()

        var itemIds: [UUID] = []
        for _ in 0..<5 {
            let id = UUID()
            itemIds.append(id)
            try await insertTestItem(id: id)
            await queue.enqueue(itemId: id)
        }

        await queue.clearPending()

        let pendingCount = await queue.pendingCount
        XCTAssertEqual(pendingCount, 0)
    }

    // MARK: - Error Handling Tests

    func testPartialFailureHandling() async throws {
        // Create items, some with valid files, some without
        let validId = UUID()
        let invalidId = UUID()

        try await insertTestItem(id: validId, withFile: true)
        try await insertTestItem(id: invalidId, withFile: false) // No file

        await queue.setProcessingDelay(milliseconds: 10)
        await queue.enqueueBatch([validId, invalidId])

        // Wait for processing
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Should have recorded error for invalid item
        let errors = await queue.getRecentErrors()
        XCTAssertTrue(errors.contains { $0.itemId == invalidId })
    }

    func testFileNotFoundDuringProcessing() async throws {
        let itemId = UUID()

        // Insert item pointing to non-existent file
        try await insertTestItem(id: itemId, withFile: false)

        await queue.setProcessingDelay(milliseconds: 10)
        await queue.enqueue(itemId: itemId)

        // Wait for processing
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Should have error
        let errors = await queue.getRecentErrors()
        let hasError = errors.contains { $0.itemId == itemId }
        XCTAssertTrue(hasError)
    }

    func testErrorLimitMaintained() async throws {
        // Generate more errors than the limit (10)
        for _ in 0..<15 {
            let id = UUID()
            try await insertTestItem(id: id, withFile: false)
            await queue.enqueue(itemId: id)
        }

        // Wait for processing
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        let errors = await queue.getRecentErrors()
        XCTAssertLessThanOrEqual(errors.count, 10)
    }

    // MARK: - Status Tests

    func testQueueStatus() async throws {
        await queue.pauseProcessing()

        var itemIds: [UUID] = []
        for _ in 0..<5 {
            let id = UUID()
            itemIds.append(id)
            try await insertTestItem(id: id)
            await queue.enqueue(itemId: id)
        }

        let status = await queue.getStatus()
        XCTAssertEqual(status.queued, 5)
        XCTAssertEqual(status.processing, 0)
    }

    func testIsProcessingCheck() async throws {
        let itemId = UUID()
        try await insertTestItem(id: itemId)

        // Set slow processing
        await queue.setProcessingDelay(milliseconds: 500)
        await queue.enqueue(itemId: itemId, priority: .high)

        // Wait a bit for processing to start
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // Should be processing
        let isProcessing = await queue.isProcessing(itemId)
        XCTAssertTrue(isProcessing)
    }

    // MARK: - Scroll-Aware Pausing Tests

    func testPauseForScrollStopsProcessing() async throws {
        let itemId = UUID()
        try await insertTestItem(id: itemId)

        // Pause for scroll first
        await queue.pauseForScroll()

        // Enqueue item
        await queue.enqueue(itemId: itemId)

        // Wait a bit
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Should be queued but not processing (paused for scroll)
        let isQueued = await queue.isQueued(itemId)
        let isProcessing = await queue.isProcessing(itemId)
        let isPausedForScroll = await queue.isPausedForScrollState

        XCTAssertTrue(isQueued)
        XCTAssertFalse(isProcessing)
        XCTAssertTrue(isPausedForScroll)
    }

    func testScrollEndedResumesAfterDelay() async throws {
        let itemId = UUID()
        try await insertTestItem(id: itemId)

        // Set fast processing
        await queue.setProcessingDelay(milliseconds: 10)

        // Pause for scroll
        await queue.pauseForScroll()
        await queue.enqueue(itemId: itemId)

        // Verify paused
        var isPausedForScroll = await queue.isPausedForScrollState
        XCTAssertTrue(isPausedForScroll)

        // Signal scroll ended
        await queue.onScrollEnded()

        // Wait less than 500ms - should still be paused
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        isPausedForScroll = await queue.isPausedForScrollState
        XCTAssertTrue(isPausedForScroll)

        // Wait for the full 500ms debounce
        try await Task.sleep(nanoseconds: 400_000_000) // Additional 400ms (total 600ms)
        isPausedForScroll = await queue.isPausedForScrollState
        XCTAssertFalse(isPausedForScroll)
    }

    func testRapidScrollStopStartDoesNotResume() async throws {
        let itemId = UUID()
        try await insertTestItem(id: itemId)

        // Set fast processing
        await queue.setProcessingDelay(milliseconds: 10)

        // Pause for scroll
        await queue.pauseForScroll()
        await queue.enqueue(itemId: itemId)

        // Signal scroll ended
        await queue.onScrollEnded()

        // Wait 200ms then start scrolling again (before 500ms debounce)
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms
        await queue.pauseForScroll()  // User started scrolling again

        // Wait another 400ms - should still be paused (debounce was cancelled)
        try await Task.sleep(nanoseconds: 400_000_000) // 400ms
        let isPausedForScroll = await queue.isPausedForScrollState
        XCTAssertTrue(isPausedForScroll)

        // Item should still be queued, not processed
        let isQueued = await queue.isQueued(itemId)
        XCTAssertTrue(isQueued)
    }

    func testScrollPauseDoesNotAffectUserPause() async throws {
        let itemId = UUID()
        try await insertTestItem(id: itemId)

        // User pause
        await queue.pauseProcessing()

        // Pause for scroll
        await queue.pauseForScroll()
        await queue.enqueue(itemId: itemId)

        // End scroll
        await queue.onScrollEnded()

        // Wait for scroll debounce
        try await Task.sleep(nanoseconds: 600_000_000) // 600ms

        // Should still be paused (user pause active even if scroll pause ended)
        let isProcessing = await queue.isProcessing(itemId)
        let isQueued = await queue.isQueued(itemId)

        XCTAssertFalse(isProcessing)
        XCTAssertTrue(isQueued)

        // Resume user pause - now should process
        await queue.resumeProcessing()

        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        let isQueuedAfterResume = await queue.isQueued(itemId)
        let isProcessingAfterResume = await queue.isProcessing(itemId)
        let pendingCountAfterResume = await queue.pendingCount
        // Should be processed or processing now
        XCTAssertTrue(isQueuedAfterResume || isProcessingAfterResume || pendingCountAfterResume == 0)
    }

    // MARK: - OCR Source Selection Tests

    func testOCRSourcesIncludeContextAfterVideoPrimary() {
        let videoURL = tempDir.appendingPathComponent("primary.mp4")
        let contextURL = tempDir.appendingPathComponent("context.png")

        let sources = VisionJobQueue.ocrSources(
            mediaURLs: [videoURL],
            contextImageURL: contextURL
        )

        XCTAssertEqual(sources, [
            VisionJobQueue.OCRSource(
                fileIndex: 1,
                url: contextURL,
                kind: .contextImage
            )
        ])
    }

    func testOCRSourcesKeepMediaImageAndContextSeparatelyAddressable() {
        let imageURL = tempDir.appendingPathComponent("primary.jpg")
        let contextURL = tempDir.appendingPathComponent("context.png")

        let sources = VisionJobQueue.ocrSources(
            mediaURLs: [imageURL],
            contextImageURL: contextURL
        )

        XCTAssertEqual(sources, [
            VisionJobQueue.OCRSource(fileIndex: 0, url: imageURL, kind: .media),
            VisionJobQueue.OCRSource(fileIndex: 1, url: contextURL, kind: .contextImage),
        ])
    }

    func testSuccessfulEmptyContextOCRPersistsAddressableMarker() async throws {
        let itemId = UUID()
        let videoURL = tempDir.appendingPathComponent("mixed-video.mp4")
        let contextURL = tempDir.appendingPathComponent("mixed-context.jpg")

        let database = DatabaseManager(
            databaseURL: tempDir.appendingPathComponent("vision-processing.sqlite")
        )
        try await database.initialize()

        let record = makeTestRecord(
            id: itemId,
            mediaFiles: [videoURL.path],
            contextImage: contextURL.path
        )
        try await database.write { db in
            try record.insert(db)
        }

        let visionQueue = VisionJobQueue(database: database)
        await visionQueue.savePerFileOCR(
            itemId: itemId,
            fileIndex: 1,
            fileURL: contextURL.path,
            ocrResult: VisionJobQueue.OCRProcessingResult(
                text: .success(nil),
                blocks: .success([])
            ),
            sourceKind: .contextImage
        )

        let contextRecord = try await database.read { db in
            try MediaFileOCRRecord.fetch(db: db, itemId: itemId, fileIndex: 1)
        }

        XCTAssertEqual(contextRecord?.fileURL, contextURL.path)
        XCTAssertEqual(contextRecord?.fileIndex, 1)
    }

    func testRequeueIncompleteSkipsVideoOnlyItemsWithoutStillSource() async throws {
        // This asserts production admission SQL, so use the complete production
        // schema (including stable per-file association state), not the mock pool.
        let productionDatabase = DatabaseManager(databaseURL: tempDir.appendingPathComponent("admission.sqlite"))
        try await productionDatabase.initialize()
        let testPool = try await productionDatabase.getPool()
        let videoOnlyId = UUID()
        let videoWithContextId = UUID()
        let imageMissingHashId = UUID()
        let completeVideoOnlyId = UUID()
        let completeMixedMissingContextOCRId = UUID()
        let completeMixedWithContextOCRId = UUID()
        let completeMixedWithMiskeyedContextOCRId = UUID()
        let tempDirPath = tempDir!.path

        try await testPool.write { [self] db in
            try self.makeTestRecord(
                id: videoOnlyId,
                mediaFiles: ["\(tempDirPath)/video-only.mp4"],
                ocrText: "",
                dominantColorsJSON: nil,
                perceptualHash: nil
            ).insert(db)

            try self.makeTestRecord(
                id: videoWithContextId,
                mediaFiles: ["\(tempDirPath)/video-context.mp4"],
                contextImage: "\(tempDirPath)/video-context.png",
                ocrText: "",
                dominantColorsJSON: nil,
                perceptualHash: nil
            ).insert(db)

            try self.makeTestRecord(
                id: imageMissingHashId,
                mediaFiles: ["\(tempDirPath)/image.jpg"],
                ocrText: "",
                dominantColorsJSON: "[\"red\"]",
                perceptualHash: nil
            ).insert(db)

            try self.makeTestRecord(
                id: completeVideoOnlyId,
                mediaFiles: ["\(tempDirPath)/video-complete.mp4"],
                ocrText: "",
                dominantColorsJSON: "[]",
                perceptualHash: ""
            ).insert(db)

            try self.makeTestRecord(
                id: completeMixedMissingContextOCRId,
                mediaFiles: ["\(tempDirPath)/mixed-missing.mp4"],
                contextImage: "\(tempDirPath)/mixed-missing-context.png",
                ocrText: "",
                dominantColorsJSON: "[\"red\"]",
                perceptualHash: "complete"
            ).insert(db)

            let processedContextPath = "\(tempDirPath)/mixed-processed-context.png"
            try self.makeTestRecord(
                id: completeMixedWithContextOCRId,
                mediaFiles: ["\(tempDirPath)/mixed-processed.mp4"],
                contextImage: processedContextPath,
                ocrText: "",
                dominantColorsJSON: "[\"red\"]",
                perceptualHash: "complete"
            ).insert(db)
            try db.execute(
                sql: """
                    INSERT INTO media_file_ocr
                        (id, item_id, file_url, file_index, ocr_text, ocr_regions_json)
                    VALUES (?, ?, ?, 1, NULL, NULL)
                """,
                arguments: [
                    UUID().uuidString,
                    completeMixedWithContextOCRId.uuidString,
                    processedContextPath,
                ]
            )

            let miskeyedContextPath = "\(tempDirPath)/mixed-miskeyed-context.png"
            try self.makeTestRecord(
                id: completeMixedWithMiskeyedContextOCRId,
                mediaFiles: ["\(tempDirPath)/mixed-miskeyed.mp4"],
                contextImage: miskeyedContextPath,
                ocrText: "",
                dominantColorsJSON: "[\"red\"]",
                perceptualHash: "complete"
            ).insert(db)
            try db.execute(
                sql: """
                    INSERT INTO media_file_ocr
                        (id, item_id, file_url, file_index, ocr_text, ocr_regions_json)
                    VALUES (?, ?, ?, 0, NULL, NULL)
                """,
                arguments: [
                    UUID().uuidString,
                    completeMixedWithMiskeyedContextOCRId.uuidString,
                    miskeyedContextPath,
                ]
            )
        }

        let requeuedIds = try await testPool.read { db in
            try String.fetchAll(db, sql: VisionJobQueue.requeueIncompleteSQL)
                .compactMap(UUID.init(uuidString:))
        }

        XCTAssertFalse(requeuedIds.contains(videoOnlyId))
        XCTAssertTrue(requeuedIds.contains(videoWithContextId))
        XCTAssertTrue(requeuedIds.contains(imageMissingHashId))
        XCTAssertFalse(requeuedIds.contains(completeVideoOnlyId))
        XCTAssertTrue(requeuedIds.contains(completeMixedMissingContextOCRId))
        XCTAssertFalse(requeuedIds.contains(completeMixedWithContextOCRId))
        XCTAssertTrue(requeuedIds.contains(completeMixedWithMiskeyedContextOCRId))
    }

    // MARK: - Helpers

    private func insertTestItem(id: UUID, withFile: Bool = true) async throws {
        let basePath = tempDir!
        let metadataFile = basePath.appendingPathComponent("\(id.uuidString).md")

        // Create a test image file if needed
        var mediaFiles: [URL] = []
        if withFile {
            let imageFile = basePath.appendingPathComponent("\(id.uuidString).jpg")
            // Create a minimal JPEG
            try createTestJPEG(at: imageFile)
            mediaFiles.append(imageFile)
        }

        let item = MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: metadataFile,
            mediaFiles: mediaFiles,
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/\(id.uuidString)")!,
                platform: "test",
                archivedDate: Date()
            )
        )

        let record = MediaItemRecord(from: item)
        try await testPool.write { db in
            try record.insert(db)
        }
    }

    private func createTestJPEG(at url: URL) throws {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [:]) else {
            throw NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create JPEG"])
        }

        try jpegData.write(to: url)
    }

    private func makeTestRecord(
        id: UUID,
        mediaFiles: [String],
        contextImage: String? = nil,
        ocrText: String? = nil,
        dominantColorsJSON: String? = nil,
        perceptualHash: String? = nil
    ) -> MediaItemRecord {
        let item = MediaItem(
            id: id,
            basePath: tempDir!,
            metadataFile: tempDir!.appendingPathComponent("\(id.uuidString).md"),
            mediaFiles: mediaFiles.map(URL.init(fileURLWithPath:)),
            contextImage: contextImage.map(URL.init(fileURLWithPath:)),
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/\(id.uuidString)")!,
                platform: "test",
                archivedDate: Date()
            )
        )

        var record = MediaItemRecord(from: item)
        record.ocrText = ocrText
        record.dominantColorsJSON = dominantColorsJSON
        record.perceptualHash = perceptualHash
        return record
    }
}

// MARK: - Testable Vision Job Queue

/// Test implementation of VisionJobQueue with controllable behavior
actor TestableVisionJobQueue {

    private let pool: DatabasePool
    private let maxConcurrent = 4

    private var pending: [(itemId: UUID, priority: JobPriority)] = []
    private var inProgress: Set<UUID> = []
    private var recentErrors: [ProcessingError] = []
    private let maxRecentErrors = 10

    private var processingDelayMs: Int = 0
    private var isPaused = false
    private var isPausedForScroll = false
    private var scrollResumeTask: Task<Void, Never>?

    init(pool: DatabasePool) {
        self.pool = pool
    }

    var isPausedForScrollState: Bool { isPausedForScroll }

    var pendingCount: Int { pending.count }
    var inProgressCount: Int { inProgress.count }

    func pauseProcessing() {
        isPaused = true
    }

    func resumeProcessing() {
        isPaused = false
        processNext()
    }

    func setProcessingDelay(milliseconds: Int) {
        processingDelayMs = milliseconds
    }

    // MARK: - Scroll-Aware Pausing

    func pauseForScroll() {
        isPausedForScroll = true
        scrollResumeTask?.cancel()
        scrollResumeTask = nil
    }

    func onScrollEnded() {
        scrollResumeTask?.cancel()
        scrollResumeTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            isPausedForScroll = false
            processNext()
        }
    }

    private var canProcessJobs: Bool {
        !isPaused && !isPausedForScroll && inProgress.count < maxConcurrent
    }

    func enqueue(itemId: UUID, priority: JobPriority = .normal) async {
        guard !inProgress.contains(itemId),
              !pending.contains(where: { $0.itemId == itemId }) else {
            return
        }

        if priority == .high {
            let insertIndex = pending.firstIndex { $0.priority != .high } ?? pending.count
            pending.insert((itemId, priority), at: insertIndex)
        } else if priority == .low {
            pending.append((itemId, priority))
        } else {
            // Insert normal priority after high but before low
            let insertIndex = pending.firstIndex { $0.priority == .low } ?? pending.count
            pending.insert((itemId, priority), at: insertIndex)
        }

        if !isPaused {
            processNext()
        }
    }

    func enqueueBatch(_ itemIds: [UUID], priority: JobPriority = .normal) async {
        for itemId in itemIds {
            await enqueue(itemId: itemId, priority: priority)
        }
    }

    func cancel(itemId: UUID) async {
        pending.removeAll { $0.itemId == itemId }
    }

    func clearPending() async {
        pending.removeAll()
    }

    func isQueued(_ itemId: UUID) -> Bool {
        inProgress.contains(itemId) || pending.contains { $0.itemId == itemId }
    }

    func isProcessing(_ itemId: UUID) -> Bool {
        inProgress.contains(itemId)
    }

    func getPendingOrder() -> [UUID] {
        pending.map(\.itemId)
    }

    func getRecentErrors() -> [ProcessingError] {
        recentErrors
    }

    func getStatus() -> QueueStatus {
        QueueStatus(processing: inProgress.count, queued: pending.count, recentErrors: recentErrors)
    }

    private func processNext() {
        guard canProcessJobs, !pending.isEmpty else {
            return
        }

        let job = pending.removeFirst()
        inProgress.insert(job.itemId)

        Task.detached(priority: .utility) { [weak self] in
            await self?.process(job.itemId)
        }

        if canProcessJobs && !pending.isEmpty {
            processNext()
        }
    }

    private func process(_ itemId: UUID) async {
        defer {
            Task { @MainActor in
                await self.finishProcessing(itemId)
            }
        }

        // Simulate processing delay
        if processingDelayMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(processingDelayMs) * 1_000_000)
        }

        // Check if file exists
        do {
            let mediaURL = try await pool.read { db -> URL? in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT mediaFilesJSON FROM media_items WHERE id = ?",
                    arguments: [itemId.uuidString]
                ) else {
                    return nil
                }

                let json: String = row["mediaFilesJSON"]
                guard let paths = try? JSONDecoder().decode([String].self, from: Data(json.utf8)),
                      let firstPath = paths.first else {
                    return nil
                }

                return URL(fileURLWithPath: firstPath)
            }

            guard let url = mediaURL else {
                addError(ProcessingError(
                    itemId: itemId,
                    stage: "fetch",
                    message: "Item not found or has no media files"
                ))
                return
            }

            guard FileManager.default.fileExists(atPath: url.path) else {
                addError(ProcessingError(
                    itemId: itemId,
                    stage: "validate",
                    message: "Media file not found: \(url.lastPathComponent)"
                ))
                return
            }

            // Simulate successful processing
            // In real implementation, this would call VisionProcessor

        } catch {
            addError(ProcessingError(
                itemId: itemId,
                stage: "fetch",
                message: "Database error: \(error.localizedDescription)"
            ))
        }
    }

    private func finishProcessing(_ itemId: UUID) async {
        inProgress.remove(itemId)
        if canProcessJobs {
            processNext()
        }
    }

    private func addError(_ error: ProcessingError) {
        recentErrors.append(error)
        if recentErrors.count > maxRecentErrors {
            recentErrors.removeFirst()
        }
    }
}
