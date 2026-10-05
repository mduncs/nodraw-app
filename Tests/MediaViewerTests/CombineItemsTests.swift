import XCTest
import GRDB
@testable import MediaViewer

final class CombineItemsTests: XCTestCase {
    private var tempDir: URL!
    private var databaseURL: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CombineItemsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        databaseURL = tempDir.appendingPathComponent("combine.sqlite")
        database = DatabaseManager(databaseURL: databaseURL)
        try await database.initialize()
        store = MediaStore(database: database)
    }

    override func tearDown() async throws {
        store = nil
        database = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testCombineItemsMergesUserDataAndRelations() async throws {
        let board = CollectionBoard(name: "refs")

        let primary = try makeItem(
            stem: "primary",
            tags: ["keep"],
            notes: "primary notes",
            starred: false,
            archivedDate: Date(timeIntervalSince1970: 10)
        )
        let secondary = try makeItem(
            stem: "secondary",
            tags: ["merge"],
            notes: "secondary notes",
            starred: true,
            archivedDate: Date(timeIntervalSince1970: 20)
        )
        let primaryID = primary.id
        let secondaryID = secondary.id

        try await store.insertItem(primary)
        try await store.insertItem(secondary)

        try await database.write { db in
            try board.insert(db)
            try BoardMembership(boardId: board.id, itemId: secondaryID, position: 0).insert(db)
            try ViewEventRecord(
                id: nil,
                itemId: secondaryID,
                viewedAt: Date(),
                durationSeconds: 4,
                action: .view
            ).insert(db)
        }

        _ = try await store.combineItems(primaryID: primaryID, secondaryIDs: [secondaryID])

        let mergedItem = try await store.fetchItem(id: primaryID)
        let merged = try XCTUnwrap(mergedItem)
        XCTAssertEqual(merged.mediaFiles.count, 2)
        XCTAssertEqual(Set(merged.metadata.tags), Set(["keep", "merge"]))
        XCTAssertTrue(merged.metadata.starred)
        XCTAssertEqual(
            merged.metadata.notes,
            "primary notes\n\n---\n\n[Combined from secondary]\nsecondary notes"
        )

        let secondaryDeleted = try await database.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT deletedAt FROM media_items WHERE id = ?",
                arguments: [secondaryID.uuidString]
            )
        }
        XCTAssertNotNil(secondaryDeleted)

        let boardMembershipItemID = try await database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT itemId FROM board_memberships WHERE boardId = ?",
                arguments: [board.id.uuidString]
            )
        }
        XCTAssertEqual(boardMembershipItemID, primary.id.uuidString)

        let viewEventCount = try await database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM view_events WHERE itemId = ?",
                arguments: [primaryID.uuidString]
            )
        }
        XCTAssertEqual(viewEventCount, 1)
    }

    /// Combining must preserve the PRIMARY's derived data (caption/ML attributes/per-file OCR) —
    /// its files keep their indices (they're first in the merged mediaFiles array), so nothing
    /// about them becomes stale. Only the secondaries' derived rows should be invalidated, and
    /// the merged item should be re-enqueued for vision so the newly-appended secondary file
    /// gets analyzed. R2-B Task 7 — see docs/archive/round-2/ux-bugfix-batch.md.
    func testCombinePreservesPrimaryDerivedDataAndInvalidatesSecondaries() async throws {
        let primary = try makeItem(
            stem: "primary",
            tags: ["keep"],
            notes: "primary notes",
            starred: false,
            archivedDate: Date(timeIntervalSince1970: 10),
            generatedCaption: "A detailed narrative caption describing the primary's scene in full."
        )
        let secondary = try makeItem(
            stem: "secondary",
            tags: ["merge"],
            notes: "secondary notes",
            starred: false,
            archivedDate: Date(timeIntervalSince1970: 20),
            generatedCaption: "A secondary narrative caption that should be discarded on combine."
        )
        let primaryID = primary.id
        let secondaryID = secondary.id

        try await store.insertItem(primary)
        try await store.insertItem(secondary)

        try await database.write { db in
            try MediaAttribute(itemId: primaryID, module: .quality, key: "aesthetics", value: 0.75).insert(db)
            try MediaFileOCRRecord(
                itemId: primaryID,
                fileURL: primary.mediaFiles[0].path,
                fileIndex: 0,
                ocrText: "primary ocr text"
            ).insert(db)

            try MediaAttribute(itemId: secondaryID, module: .quality, key: "aesthetics", value: 0.25).insert(db)
            try MediaFileOCRRecord(
                itemId: secondaryID,
                fileURL: secondary.mediaFiles[0].path,
                fileIndex: 0,
                ocrText: "secondary ocr text"
            ).insert(db)
        }

        _ = try await store.combineItems(primaryID: primaryID, secondaryIDs: [secondaryID])

        let mergedItem = try await store.fetchItem(id: primaryID)
        let merged = try XCTUnwrap(mergedItem)

        // Primary's own caption / ML attributes / per-file OCR survive the merge.
        XCTAssertEqual(merged.generatedCaption, "A detailed narrative caption describing the primary's scene in full.")
        XCTAssertEqual(merged.mlAttributes["quality.aesthetics"], 0.75)
        XCTAssertEqual(merged.perFileOCR[0]?.ocrText, "primary ocr text")

        // Secondary is soft-deleted.
        let secondaryDeleted = try await database.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT deletedAt FROM media_items WHERE id = ?",
                arguments: [secondaryID.uuidString]
            )
        }
        XCTAssertNotNil(secondaryDeleted)

        // Secondary's derived rows are gone (primary's untouched by the invalidation pass).
        let secondaryAttrCount = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_attributes WHERE item_id = ?", arguments: [secondaryID.uuidString])
        }
        XCTAssertEqual(secondaryAttrCount, 0)
        let secondaryOCRCount = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_file_ocr WHERE item_id = ?", arguments: [secondaryID.uuidString])
        }
        XCTAssertEqual(secondaryOCRCount, 0)

        let primaryAttrCount = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_attributes WHERE item_id = ?", arguments: [primaryID.uuidString])
        }
        XCTAssertEqual(primaryAttrCount, 1)
        let primaryOCRCount = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_file_ocr WHERE item_id = ?", arguments: [primaryID.uuidString])
        }
        XCTAssertEqual(primaryOCRCount, 2, "Secondary per-asset OCR transfers to its adopted stable asset instead of being discarded")
        let adoptedText = try await database.read { db in
            try String.fetchAll(db, sql: "SELECT ocr_text FROM media_file_ocr WHERE item_id = ? AND association_state = 'attached' ORDER BY file_index", arguments: [primaryID.uuidString])
        }
        XCTAssertEqual(adoptedText, ["primary ocr text", "secondary ocr text"])
    }

    /// Combine folds every secondary media file into the primary's carousel (shared paths), so
    /// those must never appear as orphans — otherwise disk-delete would trash the primary's own
    /// files. Only a secondary context image the primary didn't adopt is a real orphan.
    func testCombineOrphansExcludeSharedMediaAndIncludeUnadoptedContext() async throws {
        var primary = try makeItem(stem: "porphan", tags: [], notes: nil, starred: false,
                                   archivedDate: Date(timeIntervalSince1970: 10))
        let primaryCtx = tempDir.appendingPathComponent("porphan/porphan.context.png")
        try Data([0x02]).write(to: primaryCtx)
        primary.contextImage = primaryCtx  // primary has its own → no secondary ctx gets adopted

        var secondary = try makeItem(stem: "sorphan", tags: [], notes: nil, starred: false,
                                     archivedDate: Date(timeIntervalSince1970: 20))
        let secondaryCtx = tempDir.appendingPathComponent("sorphan/sorphan.context.png")
        try Data([0x03]).write(to: secondaryCtx)
        secondary.contextImage = secondaryCtx

        let primaryID = primary.id
        let secondaryID = secondary.id
        let secondaryMedia = secondary.mediaFiles[0]

        try await store.insertItem(primary)
        try await store.insertItem(secondary)

        let result = try await store.combineItems(primaryID: primaryID, secondaryIDs: [secondaryID])

        XCTAssertFalse(result.orphanedFileURLs.contains(secondaryMedia),
                       "secondary media is unioned into the primary carousel — must not be orphaned")
        XCTAssertFalse(result.orphanedFileURLs.contains(primaryCtx),
                       "primary's own context image must not be orphaned")
        XCTAssertTrue(result.orphanedFileURLs.contains(secondaryCtx),
                      "unadopted secondary context image should be reported as an orphan")
    }

    /// When the primary has no context image, the first secondary's is adopted as the merged
    /// primary's — so it's live, not an orphan, and nothing should be reported for trashing.
    func testCombineAdoptedSecondaryContextIsNotOrphaned() async throws {
        let primary = try makeItem(stem: "padopt", tags: [], notes: nil, starred: false,
                                   archivedDate: Date(timeIntervalSince1970: 10))

        var secondary = try makeItem(stem: "sadopt", tags: [], notes: nil, starred: false,
                                     archivedDate: Date(timeIntervalSince1970: 20))
        let secondaryCtx = tempDir.appendingPathComponent("sadopt/sadopt.context.png")
        try Data([0x04]).write(to: secondaryCtx)
        secondary.contextImage = secondaryCtx

        let primaryID = primary.id
        try await store.insertItem(primary)
        try await store.insertItem(secondary)

        let result = try await store.combineItems(primaryID: primaryID, secondaryIDs: [secondary.id])

        XCTAssertFalse(result.orphanedFileURLs.contains(secondaryCtx),
                       "adopted secondary context image is now the primary's — not an orphan")
        XCTAssertTrue(result.orphanedFileURLs.isEmpty,
                      "nothing is orphaned when all secondary files are absorbed")
    }

    private func makeItem(
        stem: String,
        tags: [String],
        notes: String?,
        starred: Bool,
        archivedDate: Date,
        generatedCaption: String? = nil
    ) throws -> MediaItem {
        let itemDir = tempDir.appendingPathComponent(stem, isDirectory: true)
        try FileManager.default.createDirectory(at: itemDir, withIntermediateDirectories: true)

        let mediaURL = itemDir.appendingPathComponent("\(stem).jpg")
        let mdURL = itemDir.appendingPathComponent("\(stem).md")

        try Data([0x01]).write(to: mediaURL)
        try "---\nsource: https://example.com/\(stem)\nplatform: test\ntags: []\n---\n".write(
            to: mdURL,
            atomically: true,
            encoding: .utf8
        )

        return MediaItem(
            id: UUID(),
            basePath: itemDir,
            metadataFile: mdURL,
            mediaFiles: [mediaURL],
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/\(stem)")!,
                platform: "test",
                author: "@\(stem)",
                originalDate: Date(),
                archivedDate: archivedDate,
                starred: starred,
                tags: tags,
                notes: notes
            ),
            generatedCaption: generatedCaption
        )
    }
}
