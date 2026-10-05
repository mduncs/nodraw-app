import XCTest
import GRDB
@testable import MediaViewer

final class MediaStoreSearchTests: XCTestCase {
    private var databaseURL: URL!
    private var databaseManager: DatabaseManager!
    private var mediaStore: MediaStore!

    override func setUpWithError() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaStoreSearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        databaseURL = tempDir.appendingPathComponent("test.sqlite")
        databaseManager = DatabaseManager(databaseURL: databaseURL)
        mediaStore = MediaStore(database: databaseManager)
    }

    override func tearDown() async throws {
        databaseManager = nil
        mediaStore = nil

        if let databaseURL {
            let tempDir = databaseURL.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
            try? FileManager.default.removeItem(at: tempDir)
        }

        databaseURL = nil
        try await super.tearDown()
    }

    func testStructuredSearchFiltersVideoRecentAndUntaggedItems() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        var videoFilter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &videoFilter,
            filterText: "type:video",
            searchScope: .all,
            allowVisualSearch: false
        )
        let videoItems = try await mediaStore.fetchItems(filter: videoFilter.withUnlimitedLimit())
        XCTAssertEqual(Set(videoItems.map(\.metadata.author)), ["@video_recent", "@video_old"])

        var untaggedFilter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &untaggedFilter,
            filterText: "tags:none",
            searchScope: .all,
            allowVisualSearch: false
        )
        let untaggedItems = try await mediaStore.fetchItems(filter: untaggedFilter.withUnlimitedLimit())
        XCTAssertEqual(untaggedItems.map(\.metadata.author), ["@image_recent"])

        var recentFilter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &recentFilter,
            filterText: "recent:7d",
            searchScope: .all,
            allowVisualSearch: false
        )
        let recentItems = try await mediaStore.fetchItems(filter: recentFilter.withUnlimitedLimit())
        XCTAssertEqual(Set(recentItems.map(\.metadata.author)), ["@video_recent", "@image_recent"])
    }

    func testStructuredSearchCombinesPlatformAliasTagAndFreeText() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        var filter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &filter,
            filterText: "platform:bsky tag:art sunset",
            searchScope: .all,
            allowVisualSearch: false
        )

        let items = try await mediaStore.fetchItems(filter: filter.withUnlimitedLimit())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.metadata.author, "@video_old")
    }

    @MainActor
    func testTagFiltersSupportSubtreeExclusionAndExactParentOnly() async throws {
        let savedDefinitions = TagSettings.shared.definitions
        defer { TagSettings.shared.definitions = savedDefinitions }

        var parent = TagDefinition(name: "art")
        parent.sortOrder = 0
        var child = TagDefinition(name: "clips")
        child.parentId = parent.id
        child.sortOrder = 0
        TagSettings.shared.definitions = [parent, child]

        try await databaseManager.initialize()
        try await insertFixtures()

        var subtree = FilterState()
        subtree.tags = ["art"]
        let subtreeItems = try await mediaStore.fetchItems(filter: subtree.withUnlimitedLimit())
        XCTAssertEqual(Set(subtreeItems.compactMap(\.metadata.author)), ["@video_recent", "@video_old"])

        var exact = FilterState()
        exact.tagFilters = [TagFilter(name: "art", scope: .exact)]
        let exactItems = try await mediaStore.fetchItems(filter: exact.withUnlimitedLimit())
        XCTAssertEqual(exactItems.compactMap(\.metadata.author), ["@video_old"])

        var excludingSubtree = FilterState()
        excludingSubtree.tagFilters = [TagFilter(name: "art", polarity: .exclude)]
        let excludedItems = try await mediaStore.fetchItems(filter: excludingSubtree.withUnlimitedLimit())
        XCTAssertFalse(excludedItems.contains { $0.metadata.author == "@video_recent" })
        XCTAssertFalse(excludedItems.contains { $0.metadata.author == "@video_old" })
        XCTAssertEqual(excludedItems.count, 4)
    }

    @MainActor
    func testTagFiltersUseUnicodeCaseFoldedKeys() async throws {
        let savedDefinitions = TagSettings.shared.definitions
        defer { TagSettings.shared.definitions = savedDefinitions }
        var parent = TagDefinition(name: "Straße")
        parent.sortOrder = 0
        var child = TagDefinition(name: "Nebenstraße")
        child.parentId = parent.id
        child.sortOrder = 0
        TagSettings.shared.definitions = [parent, child]

        try await databaseManager.initialize()
        try await insertFixtures()
        try await databaseManager.write { db in
            try db.execute(
                sql: "UPDATE media_tags SET tag = ? WHERE tag = 'art'",
                arguments: [TagCanonicalizer.key("Straße")]
            )
            try db.execute(
                sql: "UPDATE media_tags SET tag = ? WHERE tag = 'clips'",
                arguments: [TagCanonicalizer.key("NEBENSTRASSE")]
            )
        }

        var exact = FilterState()
        exact.tagFilters = [TagFilter(name: "STRASSE", scope: .exact)]
        let exactItems = try await mediaStore.fetchItems(filter: exact.withUnlimitedLimit())
        XCTAssertEqual(exactItems.compactMap(\.metadata.author), ["@video_old"])

        var subtree = FilterState()
        subtree.tagFilters = [TagFilter(name: "STRASSE")]
        let subtreeItems = try await mediaStore.fetchItems(filter: subtree.withUnlimitedLimit())
        XCTAssertEqual(Set(subtreeItems.compactMap(\.metadata.author)), ["@video_old", "@video_recent"])

        var excluded = FilterState()
        excluded.tagFilters = [TagFilter(name: "straße", polarity: .exclude)]
        let excludedItems = try await mediaStore.fetchItems(filter: excluded.withUnlimitedLimit())
        XCTAssertFalse(excludedItems.contains { $0.metadata.author == "@video_old" })
        XCTAssertFalse(excludedItems.contains { $0.metadata.author == "@video_recent" })
    }

    func testMigration37CanonicalizesAndDeduplicatesLegacyTagRows() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        let itemID = try await databaseManager.write { db -> String in
            let itemID = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT id FROM media_items ORDER BY id LIMIT 1")
            )
            let tagsJSON = String(
                data: try JSONEncoder().encode([" Art ", "art", "Straße", "STRASSE", "É", "E\u{301}", "  "]),
                encoding: .utf8
            )!
            try db.execute(
                sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                arguments: [tagsJSON, itemID]
            )
            try db.execute(sql: "DELETE FROM media_tags WHERE item_id = ?", arguments: [itemID])
            try db.execute(
                sql: "INSERT INTO media_tags (item_id, tag) VALUES (?, ?)",
                arguments: [itemID, "stale-junction-only"]
            )
            // Recreate a v36 database even when later migrations have been added.
            // DatabaseManager advances from MAX(version), so leaving a newer row
            // would correctly prevent migration 37 from running.
            try ProductionAssetFixture.removePost38Schema(in: db)
            try db.execute(sql: "DELETE FROM schema_migrations WHERE version >= 37")
            return itemID
        }

        mediaStore = nil
        databaseManager = nil
        let migratedDatabase = DatabaseManager(databaseURL: databaseURL)
        try await migratedDatabase.initialize()
        databaseManager = migratedDatabase
        mediaStore = MediaStore(database: migratedDatabase)

        let migratedTags = try await migratedDatabase.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT tag FROM media_tags WHERE item_id = ? ORDER BY tag",
                arguments: [itemID]
            )
        }
        XCTAssertEqual(migratedTags, ["art", "strasse", "é"])
    }

    func testCaseOnlyGlobalRenameUpdatesPresentationWithoutChangingLookupKey() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        try await mediaStore.renameTagGlobally(oldName: "art", newName: "Art")

        let result = try await databaseManager.read { db -> (String, [String]) in
            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                    SELECT media_items.tagsJSON, media_tags.tag
                    FROM media_items
                    JOIN media_tags ON media_tags.item_id = media_items.id
                    WHERE media_items.author = '@video_old'
                    """
            ))
            let tagsJSON: String = row["tagsJSON"]
            let tags = try JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))
            let lookupKey: String = row["tag"]
            return (lookupKey, tags)
        }
        XCTAssertEqual(result.0, "art")
        XCTAssertEqual(result.1, ["Art"])
    }

    func testFetchAllTagsUsesCanonicalJunctionAndPreservesDisplaySpelling() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        try await databaseManager.write { db in
            let itemID = try XCTUnwrap(String.fetchOne(
                db,
                sql: "SELECT id FROM media_items WHERE author = '@video_old'"
            ))
            let tagsJSON = String(
                data: try JSONEncoder().encode(["Straße"]),
                encoding: .utf8
            )!
            try db.execute(
                sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                arguments: [tagsJSON, itemID]
            )
            try db.execute(
                sql: "UPDATE media_tags SET tag = ? WHERE item_id = ?",
                arguments: [TagCanonicalizer.key("STRASSE"), itemID]
            )
        }

        let tags = try await mediaStore.fetchAllTags()
        XCTAssertTrue(tags.contains("Straße"))
        XCTAssertFalse(tags.contains("strasse"))
    }

    func testTagMutationsHealJSONAndJunctionDriftWithoutCanonicalDuplicates() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        let ids = try await databaseManager.read { db -> [String: UUID] in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, author FROM media_items WHERE author IN ('@video_old', '@video_recent', '@image_recent')"
            )
            return try Dictionary(uniqueKeysWithValues: rows.map { row in
                let author: String = row["author"]
                let idString: String = row["id"]
                return (author, try XCTUnwrap(UUID(uuidString: idString)))
            })
        }
        let oldVideoID = try XCTUnwrap(ids["@video_old"])
        let recentVideoID = try XCTUnwrap(ids["@video_recent"])
        let imageID = try XCTUnwrap(ids["@image_recent"])

        try await databaseManager.write { db in
            try db.execute(
                sql: "DELETE FROM media_tags WHERE item_id = ? AND tag = 'art'",
                arguments: [oldVideoID.uuidString]
            )
            try db.execute(
                sql: "INSERT INTO media_tags (item_id, tag) VALUES (?, 'ghost')",
                arguments: [recentVideoID.uuidString]
            )
            try db.execute(
                sql: "INSERT INTO media_tags (item_id, tag) VALUES (?, 'strasse')",
                arguments: [imageID.uuidString]
            )
        }

        try await mediaStore.addTag(id: oldVideoID, tag: "ART")
        try await mediaStore.removeTag(id: recentVideoID, tag: "GHOST")
        try await mediaStore.addTagToItems(ids: [oldVideoID, imageID], tag: "Straße")

        let result = try await databaseManager.read { db -> ([String], [String], [String]) in
            func tagsJSON(for id: UUID) throws -> [String] {
                let encoded = try XCTUnwrap(String.fetchOne(
                    db,
                    sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                    arguments: [id.uuidString]
                ))
                return try JSONDecoder().decode([String].self, from: Data(encoded.utf8))
            }
            let oldLookup = try String.fetchAll(
                db,
                sql: "SELECT tag FROM media_tags WHERE item_id = ? ORDER BY tag",
                arguments: [oldVideoID.uuidString]
            )
            let recentLookup = try String.fetchAll(
                db,
                sql: "SELECT tag FROM media_tags WHERE item_id = ? ORDER BY tag",
                arguments: [recentVideoID.uuidString]
            )
            return (oldLookup, recentLookup, try tagsJSON(for: imageID))
        }

        XCTAssertEqual(result.0, ["art", "strasse"])
        XCTAssertEqual(result.1, ["clips"])
        XCTAssertEqual(result.2, ["Straße"])
    }

    func testStructuredSearchSupportsAuthorAndFileTypeFilters() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        var filter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &filter,
            filterText: "author:image_recent ext:jpg",
            searchScope: .all,
            allowVisualSearch: false
        )

        let items = try await mediaStore.fetchItems(filter: filter.withUnlimitedLimit())
        XCTAssertEqual(items.map(\.metadata.author), ["@image_recent"])
    }

    func testStructuredSearchTreatsSpecificTypeValuesAsFileExtensions() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        var filter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &filter,
            filterText: "type:mov",
            searchScope: .all,
            allowVisualSearch: false
        )

        let items = try await mediaStore.fetchItems(filter: filter.withUnlimitedLimit())
        XCTAssertEqual(items.map(\.metadata.author), ["@video_old"])
    }

    func testStructuredSearchSupportsMediaTypeAliases() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        var imageFilter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &imageFilter,
            filterText: "type:image",
            searchScope: .all,
            allowVisualSearch: false
        )
        let imageItems = try await mediaStore.fetchItems(filter: imageFilter.withUnlimitedLimit())
        XCTAssertEqual(Set(imageItems.map(\.metadata.author)), ["@image_recent", "@gif_loop"])

        var gifFilter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &gifFilter,
            filterText: "type:gif",
            searchScope: .all,
            allowVisualSearch: false
        )
        let gifItems = try await mediaStore.fetchItems(filter: gifFilter.withUnlimitedLimit())
        XCTAssertEqual(gifItems.map(\.metadata.author), ["@gif_loop"])

        var audioFilter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &audioFilter,
            filterText: "type:audio",
            searchScope: .all,
            allowVisualSearch: false
        )
        let audioItems = try await mediaStore.fetchItems(filter: audioFilter.withUnlimitedLimit())
        XCTAssertEqual(audioItems.map(\.metadata.author), ["@audio_clip"])

        var documentFilter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &documentFilter,
            filterText: "type:pdf/document",
            searchScope: .all,
            allowVisualSearch: false
        )
        let documentItems = try await mediaStore.fetchItems(filter: documentFilter.withUnlimitedLimit())
        XCTAssertEqual(documentItems.map(\.metadata.author), ["@pdf_doc"])
    }

    func testStructuredSearchSupportsSourceAndAspectRatioFilters() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        var sourceFilter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &sourceFilter,
            filterText: "source:example.com ratio:3:2",
            searchScope: .all,
            allowVisualSearch: false
        )

        let sourceItems = try await mediaStore.fetchItems(filter: sourceFilter.withUnlimitedLimit())
        XCTAssertEqual(Set(sourceItems.map(\.metadata.author)), ["@gif_loop", "@audio_clip", "@pdf_doc"])

        var mismatchedRatioFilter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &mismatchedRatioFilter,
            filterText: "source:example.com ratio:16:9",
            searchScope: .all,
            allowVisualSearch: false
        )

        let mismatchedItems = try await mediaStore.fetchItems(filter: mismatchedRatioFilter.withUnlimitedLimit())
        XCTAssertTrue(mismatchedItems.isEmpty)
    }

    func testStructuredSearchSupportsQuotedOCRPhraseQueries() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        var filter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &filter,
            filterText: "ocr:\"sunset painting\"",
            searchScope: .all,
            allowVisualSearch: false
        )

        let items = try await mediaStore.fetchItems(filter: filter.withUnlimitedLimit())
        XCTAssertEqual(items.map(\.metadata.author), ["@image_recent"])
    }

    func testStructuredSearchSupportsQuotedNotesPhraseQueries() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        var filter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &filter,
            filterText: "notes:\"save for later\"",
            searchScope: .all,
            allowVisualSearch: false
        )

        let items = try await mediaStore.fetchItems(filter: filter.withUnlimitedLimit())
        XCTAssertEqual(items.map(\.metadata.author), ["@video_recent"])
    }

    func testScopedOCRSearchSupportsQuotedPhrases() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        var filter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &filter,
            filterText: "\"sunset painting\"",
            searchScope: .ocrOnly,
            allowVisualSearch: false
        )

        let items = try await mediaStore.fetchItems(filter: filter.withUnlimitedLimit())
        XCTAssertEqual(items.map(\.metadata.author), ["@image_recent"])
    }

    func testSmartFolderFileExtensionRuleUsesActualMediaExtensions() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        var filter = FilterState()
        filter.smartFolder = SmartFolder(
            name: "JPEGs",
            rules: [.fileExtension(["jpg"])],
            matchAll: true
        )

        let items = try await mediaStore.fetchItems(filter: filter.withUnlimitedLimit())
        XCTAssertEqual(items.map(\.metadata.author), ["@image_recent"])
    }

    func testShuffleOrderIsStableAndPaginatesAfterShuffle() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        var filter = FilterState()
        filter.shuffleSeed = 0xC0FFEE
        filter.limit = -1

        let firstPass = try await mediaStore.fetchItems(filter: filter)
        let secondPass = try await mediaStore.fetchItems(filter: filter)
        let shuffledAuthors = firstPass.map(\.metadata.author)

        XCTAssertEqual(shuffledAuthors, secondPass.map(\.metadata.author))

        var pageFilter = filter
        pageFilter.limit = 2
        pageFilter.offset = 1
        let page = try await mediaStore.fetchItems(filter: pageFilter)

        XCTAssertEqual(page.map(\.metadata.author), Array(shuffledAuthors.dropFirst().prefix(2)))
    }

    func testShuffleRelativeOrderSurvivesAdditionalFilters() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        var allFilter = FilterState()
        allFilter.shuffleSeed = 0xBADA55
        allFilter.limit = -1
        let allItems = try await mediaStore.fetchItems(filter: allFilter)
        let allAuthors = allItems.map(\.metadata.author)

        var videoFilter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &videoFilter,
            filterText: "type:video",
            searchScope: .all,
            allowVisualSearch: false
        )
        videoFilter.shuffleSeed = allFilter.shuffleSeed
        videoFilter.limit = -1

        let videoItems = try await mediaStore.fetchItems(filter: videoFilter)
        let videoAuthors = videoItems.map(\.metadata.author)
        let expectedVideoAuthors = allAuthors.filter { ["@video_recent", "@video_old"].contains($0) }

        XCTAssertEqual(videoAuthors, expectedVideoAuthors)
    }

    func testHasTextFilterCombinesWithTypeFilters() async throws {
        try await databaseManager.initialize()
        try await insertFixtures()

        var filter = FilterState()
        _ = try await MediaFilterBuilder.applySearch(
            to: &filter,
            filterText: "type:video",
            searchScope: .all,
            allowVisualSearch: false
        )
        filter.hasOCR = true

        let items = try await mediaStore.fetchItems(filter: filter.withUnlimitedLimit())
        XCTAssertEqual(Set(items.map(\.metadata.author)), ["@video_recent", "@video_old"])
    }

    private func insertFixtures() async throws {
        let now = Date()
        let oldArchivedDate = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        let basePath = databaseURL.deletingLastPathComponent()

        let recentVideo = SampleData.createMediaItem(
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("recent-video.md"),
            mediaFiles: [basePath.appendingPathComponent("recent-video.mp4")],
            source: "https://twitter.com/video/recent",
            platform: "twitter",
            author: "@video_recent",
            archivedDate: now,
            starred: false,
            tags: ["clips"],
            notes: "save for later reference",
            ocrText: "dance clip"
        )

        let recentImage = SampleData.createMediaItem(
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("recent-image.md"),
            mediaFiles: [basePath.appendingPathComponent("recent-image.jpg")],
            source: "https://bsky.app/profile/example/post/1",
            platform: "bluesky",
            author: "@image_recent",
            archivedDate: now,
            starred: false,
            tags: [],
            ocrText: "sunset painting"
        )

        let oldVideo = SampleData.createMediaItem(
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("old-video.md"),
            mediaFiles: [basePath.appendingPathComponent("old-video.mov")],
            source: "https://bsky.app/profile/example/post/2",
            platform: "bsky",
            author: "@video_old",
            archivedDate: oldArchivedDate,
            starred: false,
            tags: ["art"],
            ocrText: "sunset timelapse"
        )

        let animatedGif = SampleData.createMediaItem(
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("animated-gif.md"),
            mediaFiles: [basePath.appendingPathComponent("animated-gif.gif")],
            source: "https://example.com/gif",
            platform: "tumblr",
            author: "@gif_loop",
            archivedDate: oldArchivedDate,
            starred: false,
            tags: ["loops"],
            ocrText: "looping animation"
        )

        let audioClip = SampleData.createMediaItem(
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("audio-clip.md"),
            mediaFiles: [basePath.appendingPathComponent("audio-clip.m4a")],
            source: "https://example.com/audio",
            platform: "mastodon",
            author: "@audio_clip",
            archivedDate: oldArchivedDate,
            starred: false,
            tags: ["sound"],
            ocrText: "audio transcript"
        )

        let pdfDocument = SampleData.createMediaItem(
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("document.md"),
            mediaFiles: [basePath.appendingPathComponent("document.pdf")],
            source: "https://example.com/document",
            platform: "web",
            author: "@pdf_doc",
            archivedDate: oldArchivedDate,
            starred: false,
            tags: ["docs"],
            ocrText: "document text"
        )

        try await databaseManager.write { db in
            try MediaItemRecord(from: recentVideo).insertWithFTSSync(db: db)
            try MediaItemRecord(from: recentImage).insertWithFTSSync(db: db)
            try MediaItemRecord(from: oldVideo).insertWithFTSSync(db: db)
            try MediaItemRecord(from: animatedGif).insertWithFTSSync(db: db)
            try MediaItemRecord(from: audioClip).insertWithFTSSync(db: db)
            try MediaItemRecord(from: pdfDocument).insertWithFTSSync(db: db)
        }
    }
}
