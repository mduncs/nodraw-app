import XCTest
@testable import MediaViewer

/// The detail view's Related panel: same author, same parent folder, shared tags.
final class FocusRelatedQueriesTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusRelatedQueriesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try await super.tearDown()
    }

    func testRelatedQueriesMatchAuthorParentFolderAndSharedTags() async throws {
        let folder = tempDirectory.appendingPathComponent("2025-12", isDirectory: true)
        let focus = try makeItem(in: folder, name: "focus", author: "alice", tags: ["demo"], day: 3)
        let sibling = try makeItem(in: folder, name: "sibling", author: "alice", tags: ["other"], day: 2)
        let nested = try makeItem(
            in: folder.appendingPathComponent("sub", isDirectory: true),
            name: "nested", author: "bob", tags: ["demo"], day: 1
        )

        let database = DatabaseManager(databaseURL: tempDirectory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        let store = MediaStore(database: database)
        for item in [focus, sibling, nested] {
            try await store.insertItem(item)
        }

        let byAuthor = try await store.fetchByAuthor("alice", excluding: focus.id)
        XCTAssertEqual(byAuthor.map(\.id), [sibling.id])

        // The panel passes the focused item's parent directory; deeper folders are not siblings.
        let parentPath = focus.basePath.deletingLastPathComponent().path
        let inFolder = try await store.fetchInFolder(parentPath, excluding: focus.id)
        XCTAssertEqual(inFolder.map(\.id), [sibling.id])

        let bySharedTags = try await store.fetchBySharedTags(focus.metadata.tags, excluding: focus.id)
        XCTAssertEqual(bySharedTags.map(\.id), [nested.id])
    }

    func testRelatedSectionsShowEachItemOnceInPriorityOrder() throws {
        let folder = tempDirectory.appendingPathComponent("2025-12", isDirectory: true)
        let items = try (0..<6).map { try makeItem(in: folder, name: "item\($0)", author: "alice", tags: ["demo"], day: $0 + 1) }
        let (a, b, c, d, e, f) = (items[0], items[1], items[2], items[3], items[4], items[5])

        // b is by the author and in the folder; c and d are in the folder and share tags.
        let sections = FocusContextSidebar.distinctSections(
            author: [a, b], folder: [b, c, d], tags: [a, c, d, e, f], limit: 3)
        XCTAssertEqual(sections.author.map(\.id), [a.id, b.id])
        XCTAssertEqual(sections.folder.map(\.id), [c.id, d.id])
        // Over-fetched results refill the section after duplicates drop out, up to the limit.
        XCTAssertEqual(sections.tags.map(\.id), [e.id, f.id])

        let allTaken = FocusContextSidebar.distinctSections(author: [a], folder: [a], tags: [a])
        XCTAssertEqual(allTaken.author.map(\.id), [a.id])
        XCTAssertTrue(allTaken.folder.isEmpty, "a section with only duplicates ends up empty and is hidden")
        XCTAssertTrue(allTaken.tags.isEmpty)

        let capped = FocusContextSidebar.distinctSections(author: [], folder: [], tags: items, limit: 4)
        XCTAssertEqual(capped.tags.map(\.id), items.prefix(4).map(\.id))
    }

    private func makeItem(in folder: URL, name: String, author: String, tags: [String], day: Int) throws -> MediaItem {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let basePath = folder.appendingPathComponent(name)
        let metadataFile = folder.appendingPathComponent("\(name).md")
        let mediaFile = folder.appendingPathComponent("\(name).jpg")
        try "---\nsource: https://example.com/\(name)\n---\n".write(to: metadataFile, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: mediaFile.path, contents: Data([0xFF, 0xD8, 0xFF, 0xD9]))

        return MediaItem(
            id: UUID(),
            basePath: basePath,
            metadataFile: metadataFile,
            mediaFiles: [mediaFile],
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/\(name)")!,
                platform: "test",
                author: author,
                archivedDate: Date(timeIntervalSince1970: 1_788_393_600 + Double(day) * 86_400),
                tags: tags
            ),
            aspectRatio: 1
        )
    }
}
