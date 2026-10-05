import XCTest
import GRDB
@testable import MediaViewer

/// Removing one file from a multi-file/carousel item used to shift every later file's index
/// down by one without re-keying the per-file side tables (media_file_ocr, video_segments,
/// transcript_segments), leaving them attributed to the wrong file. R2-B Task 8 — see
/// docs/archive/round-2/ux-bugfix-batch.md.
final class DeleteServiceReindexTests: XCTestCase {
    private var tempDir: URL!
    private var databaseURL: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!
    private var deleteService: DeleteService!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeleteServiceReindexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        databaseURL = tempDir.appendingPathComponent("reindex.sqlite")
        database = DatabaseManager(databaseURL: databaseURL)
        try await database.initialize()
        store = MediaStore(database: database)
        // Never alter the user's delete preference or touch system Trash.
        deleteService = DeleteService(mediaStore: store, deleteFromDisk: false)
    }

    override func tearDown() async throws {
        deleteService = nil
        store = nil
        database = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// Builds a 3-file item and seeds media_file_ocr / video_segments / transcript_segments
    /// rows at indices 0, 1, 2 — one distinguishable row per table per index.
    private func makeThreeFileItemWithSideRows() async throws -> MediaItem {
        let itemDir = tempDir.appendingPathComponent("carousel", isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)

        let mediaFiles = (0..<3).map { itemDir.appendingPathComponent("file\($0).mp4") }
        for url in mediaFiles {
            try Data([0x01]).write(to: url)
        }
        let mdURL = itemDir.appendingPathComponent("carousel.md")
        try "---\nsource: https://example.com/carousel\nplatform: test\ntags: []\n---\n".write(
            to: mdURL, atomically: true, encoding: .utf8
        )

        let item = MediaItem(
            id: UUID(),
            basePath: itemDir,
            metadataFile: mdURL,
            mediaFiles: mediaFiles,
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/carousel")!,
                platform: "test",
                author: "@carousel",
                originalDate: Date(),
                archivedDate: Date()
            )
        )
        try await store.insertItem(item)

        try await database.write { db in
            for index in 0..<3 {
                try MediaFileOCRRecord(
                    itemId: item.id,
                    fileURL: mediaFiles[index].path,
                    fileIndex: index,
                    ocrText: "ocr-\(index)"
                ).insert(db)

                try VideoSegmentRecord(segment: VideoSegment(
                    id: UUID(),
                    itemId: item.id,
                    mediaFileIndex: index,
                    sourcePath: mediaFiles[index].path,
                    startTime: 0,
                    endTime: 1,
                    summary: "segment-\(index)",
                    labels: [],
                    confidence: 1,
                    analysisSource: "native_vision",
                    version: 1
                )).insert(db)

                try TranscriptSegmentRecord(segment: TranscriptSegment(
                    id: UUID(),
                    itemId: item.id,
                    mediaFileIndex: index,
                    sourcePath: mediaFiles[index].path,
                    startTime: 0,
                    endTime: 1,
                    text: "transcript-\(index)",
                    confidence: 1,
                    language: "en",
                    model: "parakeet",
                    version: 1
                )).insert(db)
            }
        }

        return item
    }

    private func ocrTexts(for itemID: UUID) async throws -> [Int: String] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT file_index, ocr_text FROM media_file_ocr WHERE item_id = ? AND association_state = 'attached'", arguments: [itemID.uuidString])
            var result: [Int: String] = [:]
            for row in rows { result[row["file_index"]] = row["ocr_text"] }
            return result
        }
    }

    private func segmentSummaries(for itemID: UUID) async throws -> [Int: String] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT media_file_index, summary FROM video_segments WHERE item_id = ? AND association_state = 'attached'", arguments: [itemID.uuidString])
            var result: [Int: String] = [:]
            for row in rows { result[row["media_file_index"]] = row["summary"] }
            return result
        }
    }

    private func transcriptTexts(for itemID: UUID) async throws -> [Int: String] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT media_file_index, text FROM transcript_segments WHERE item_id = ? AND association_state = 'attached'", arguments: [itemID.uuidString])
            var result: [Int: String] = [:]
            for row in rows { result[row["media_file_index"]] = row["text"] }
            return result
        }
    }

    // MARK: - Removing the first index shifts everything down

    private func assertRetainedData(itemID: UUID, removedIndex: Int) async throws {
        let values = try await database.read { db -> [String] in
            var values: [String] = []
            for (table, column, ordinal) in [("media_file_ocr", "ocr_text", "file_index"), ("video_segments", "summary", "media_file_index"), ("transcript_segments", "text", "media_file_index")] {
                values += try String.fetchAll(db, sql: "SELECT \(column) FROM \(table) WHERE item_id = ? AND association_state = 'removed' AND \(ordinal) < 0", arguments: [itemID.uuidString])
            }
            return values
        }
        XCTAssertEqual(values, ["ocr-\(removedIndex)", "segment-\(removedIndex)", "transcript-\(removedIndex)"], "Removed-file contents remain recoverable, outside current ordinal slots")
    }

    func testRemoveFirstIndexShiftsLaterRowsDown() async throws {
        let item = try await makeThreeFileItemWithSideRows()

        let updated = try await deleteService.removeFile(from: item, at: 0).updatedItem
        try await assertRetainedData(itemID: item.id, removedIndex: 0)

        XCTAssertEqual(updated.mediaFiles.count, 2)

        let ocr = try await ocrTexts(for: item.id)
        XCTAssertEqual(ocr, [0: "ocr-1", 1: "ocr-2"], "old index 0 gone, old 1->0, old 2->1")

        let segments = try await segmentSummaries(for: item.id)
        XCTAssertEqual(segments, [0: "segment-1", 1: "segment-2"])

        let transcripts = try await transcriptTexts(for: item.id)
        XCTAssertEqual(transcripts, [0: "transcript-1", 1: "transcript-2"])

        // Returned item's in-memory perFileOCR reflects the same re-keying immediately,
        // without waiting for a reload.
        XCTAssertNil(updated.perFileOCR[2])
    }

    // MARK: - Removing a middle index

    func testRemoveMiddleIndexShiftsOnlyLaterRows() async throws {
        let item = try await makeThreeFileItemWithSideRows()

        let updated = try await deleteService.removeFile(from: item, at: 1).updatedItem
        try await assertRetainedData(itemID: item.id, removedIndex: 1)

        XCTAssertEqual(updated.mediaFiles.count, 2)

        let ocr = try await ocrTexts(for: item.id)
        XCTAssertEqual(ocr, [0: "ocr-0", 1: "ocr-2"], "index 0 untouched, old 1 gone, old 2->1")

        let segments = try await segmentSummaries(for: item.id)
        XCTAssertEqual(segments, [0: "segment-0", 1: "segment-2"])

        let transcripts = try await transcriptTexts(for: item.id)
        XCTAssertEqual(transcripts, [0: "transcript-0", 1: "transcript-2"])
    }

    // MARK: - Removing the last index needs no shift

    func testRemoveLastIndexNeedsNoShift() async throws {
        let item = try await makeThreeFileItemWithSideRows()

        let updated = try await deleteService.removeFile(from: item, at: 2).updatedItem
        try await assertRetainedData(itemID: item.id, removedIndex: 2)

        XCTAssertEqual(updated.mediaFiles.count, 2)

        let ocr = try await ocrTexts(for: item.id)
        XCTAssertEqual(ocr, [0: "ocr-0", 1: "ocr-1"], "indices 0/1 untouched, index 2 gone")

        let segments = try await segmentSummaries(for: item.id)
        XCTAssertEqual(segments, [0: "segment-0", 1: "segment-1"])

        let transcripts = try await transcriptTexts(for: item.id)
        XCTAssertEqual(transcripts, [0: "transcript-0", 1: "transcript-1"])
    }
}
