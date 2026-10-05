import GRDB
import XCTest
@testable import MediaViewer

final class TranscriptionReplacementTests: XCTestCase {
    func testSavingTranscriptReplacesVerifiedAliasAtSameMediaIndex() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionReplacementTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let database = DatabaseManager(databaseURL: tempDirectory.appendingPathComponent("test.sqlite"))
        try await database.initialize()

        let itemID = UUID()
        let currentDirectory = tempDirectory.appendingPathComponent("current")
        try FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)
        let currentPath = currentDirectory.appendingPathComponent("clip.mp4").path
        let otherPath = currentDirectory.appendingPathComponent("other.mp4").path
        try Data("clip".utf8).write(to: URL(fileURLWithPath: currentPath))
        try Data("other".utf8).write(to: URL(fileURLWithPath: otherPath))
        let alias = tempDirectory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: currentDirectory)
        let aliasPath = alias.appendingPathComponent("clip.mp4").path
        try await database.write { db in
            try Self.insertItem(itemID, paths: [currentPath, otherPath], in: db)
            try Self.insertSegment(
                itemID: itemID,
                mediaFileIndex: 0,
                sourcePath: aliasPath,
                text: "stale alias",
                in: db
            )
            try Self.insertSegment(
                itemID: itemID,
                mediaFileIndex: 1,
                sourcePath: otherPath,
                text: "other carousel entry",
                in: db
            )
        }

        let replacement = TranscriptSegment(
            id: UUID(),
            itemId: itemID,
            mediaFileIndex: 0,
            sourcePath: currentPath,
            startTime: 0,
            endTime: 1,
            text: "replacement transcript",
            confidence: 0.95,
            language: "en",
            model: TranscriptTimelineBuilder.defaultModelName,
            version: TranscriptTimelineBuilder.currentVersion
        )

        let queue = TranscriptionQueue(database: database)
        await queue.pause()
        try await queue.saveSegments(
            itemId: itemID,
            mediaFileIndex: 0,
            sourcePath: replacement.sourcePath,
            segments: [replacement]
        )

        let rows = try await database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT media_file_index, source_path, text
                    FROM transcript_segments
                    WHERE item_id = ?
                    ORDER BY media_file_index, start_time
                """,
                arguments: [itemID.uuidString]
            )
        }

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["media_file_index"] as Int, 0)
        XCTAssertEqual(rows[0]["source_path"] as String, currentPath)
        XCTAssertEqual(rows[0]["text"] as String, "replacement transcript")
        XCTAssertEqual(rows[1]["media_file_index"] as Int, 1)
        XCTAssertEqual(rows[1]["source_path"] as String, otherPath)
        XCTAssertEqual(rows[1]["text"] as String, "other carousel entry")
    }

    private static func insertItem(_ id: UUID, paths: [String], in db: Database) throws {
        let mediaFilesJSON = String(
            decoding: try JSONEncoder().encode(paths),
            as: UTF8.self
        )
        try db.execute(
            sql: """
                INSERT INTO media_items (
                    id, basePathString, metadataFileString, mediaFilesJSON,
                    sourceURL, platform, archivedDate, starred, tagsJSON, parseStatus
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 0, '[]', 'success')
            """,
            arguments: [
                id.uuidString,
                URL(fileURLWithPath: paths[0]).deletingLastPathComponent().path,
                URL(fileURLWithPath: paths[0]).deletingPathExtension().appendingPathExtension("md").path,
                mediaFilesJSON,
                "https://example.invalid/item/\(id.uuidString)",
                "test",
                Date()
            ]
        )
    }

    private static func insertSegment(
        itemID: UUID,
        mediaFileIndex: Int,
        sourcePath: String,
        text: String,
        in db: Database
    ) throws {
        try TranscriptSegmentRecord(
            segment: TranscriptSegment(
                id: UUID(),
                itemId: itemID,
                mediaFileIndex: mediaFileIndex,
                sourcePath: sourcePath,
                startTime: 0,
                endTime: 1,
                text: text,
                confidence: 0.9,
                language: "en",
                model: "fixture",
                version: 1
            )
        ).insert(db)
    }
}
