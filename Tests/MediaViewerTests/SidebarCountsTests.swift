import XCTest
import AppKit
@testable import MediaViewer

/// The grouped sidebar count queries must answer exactly what the old one-`countItems`-per-row
/// refresh answered, including hidden rows, platform aliases and tag hierarchy expansion.
@MainActor
final class SidebarCountsTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!
    private var savedDefinitions: [TagDefinition] = []

    override func setUp() async throws {
        savedDefinitions = TagSettings.shared.definitions
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SidebarCounts-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        store = MediaStore(database: database)

        var parent = TagDefinition(name: "Parent")
        parent.sortOrder = 0
        var child = TagDefinition(name: "Child")
        child.parentId = parent.id
        child.sortOrder = 0
        var other = TagDefinition(name: "Other")
        other.sortOrder = 1
        TagSettings.shared.definitions = [parent, child, other]

        let junk = item("junk", folder: "2026-03_x", platform: "import", tags: ["Other"])
        let deleted = item("deleted", folder: "2026-03", platform: "twitter", tags: ["Parent"])
        try await store.insertItemsBatch([
            item("a", folder: "2026-01", platform: "twitter", tags: ["Parent"]),
            item("b", folder: "2026-01", platform: "bsky", tags: ["Child"]),
            item("c", folder: "2026-02", platform: "Bluesky", tags: ["Child", "Other"]),
            item("d", folder: "2026-02", platform: "twitter", tags: ["parent"]),
            item("e", folder: "2026_03", platform: "import", tags: []),
            junk,
            deleted
        ])
        try await database.write { db in
            try db.execute(
                sql: "INSERT INTO media_attributes (item_id, module, key, value) VALUES (?, 'junk', 'is_junk', 0.9)",
                arguments: [junk.id.uuidString]
            )
        }
        try await store.softDelete(ids: [deleted.id])
    }

    override func tearDown() async throws {
        TagSettings.shared.definitions = savedDefinitions
        store = nil
        database = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func item(_ name: String, folder: String, platform: String, tags: [String]) -> MediaItem {
        let base = directory.appendingPathComponent(folder)
        return SampleData.createMediaItem(basePath: base,
            metadataFile: base.appendingPathComponent(name + ".md"),
            mediaFiles: [base.appendingPathComponent(name + ".jpg")],
            source: "https://example.com/\(name)", platform: platform,
            author: name, tags: tags)
    }

    func testGroupedCountsMatchPerRowCountItems() async throws {
        let folders = ["2026-01", "2026-02", "2026-03", "2026-03_x", "2026_03", "1999-01"]
        let platforms = ["twitter", "bsky", "bluesky", "Bluesky", "import", "tumblr"]
        let tags = ["Parent", "Child", "Other", "parent", "Missing"]

        let grouped = try await store.fetchSidebarCounts(folders: folders, platforms: platforms, tags: tags)

        let total = try await store.countItems()
        XCTAssertEqual(grouped.total, total)
        for folder in folders {
            var filter = FilterState()
            filter.folderPath = folder
            let expected = try await store.countItems(filter: filter)
            XCTAssertEqual(grouped.folders[folder] ?? 0, expected, "folder \(folder)")
        }
        for platform in platforms {
            var filter = FilterState()
            filter.platform = platform
            let expected = try await store.countItems(filter: filter)
            XCTAssertEqual(grouped.platforms[platform] ?? 0, expected, "platform \(platform)")
        }
        for tag in tags {
            var filter = FilterState()
            filter.tags = [tag]
            let expected = try await store.countItems(filter: filter)
            XCTAssertEqual(grouped.tags[TagCanonicalizer.key(tag)] ?? 0, expected, "tag \(tag)")
        }

        // Pin the fixture so an empty store cannot pass the parity checks trivially.
        XCTAssertEqual(grouped.total, 5, "junk and deleted rows stay out of every count")
        XCTAssertEqual(grouped.tags[TagCanonicalizer.key("Parent")], 4, "parent counts its descendants")
        XCTAssertEqual(grouped.folders["2026-02"], 2)
    }
}

/// Grid context clicks are claimed only by the visible part of a cell, through one
/// shared monitor instead of one per cell.
@MainActor
final class GridContextClickRoutingTests: XCTestCase {
    private func anchor(_ frame: NSRect) -> RightClickView {
        let view = RightClickView(onRightClick: { _ in })
        view.frame = frame
        return view
    }

    func testClippedCellClaimsOnlyItsVisibleRect() {
        // A 100pt cell whose lower half is scrolled out of its clip. (AppKit does not compute
        // visibleRect for a never-ordered-in test window, so the clipped rect is spelled out.)
        let visible = NSRect(x: 0, y: 50, width: 100, height: 50)
        XCTAssertTrue(GridContextClickHitTest.claims(NSPoint(x: 10, y: 75), visibleRect: visible))
        XCTAssertFalse(GridContextClickHitTest.claims(NSPoint(x: 10, y: 25), visibleRect: visible),
                       "the clipped half belongs to whatever is drawn there, not this cell")
        XCTAssertFalse(GridContextClickHitTest.claims(NSPoint(x: 150, y: 75), visibleRect: visible))
        XCTAssertFalse(GridContextClickHitTest.claims(NSPoint(x: 10, y: 10), visibleRect: .zero),
                       "a fully scrolled-out cell claims nothing")
        XCTAssertNil(anchor(NSRect(x: 0, y: 0, width: 100, height: 100)).hitTest(NSPoint(x: 10, y: 75)),
                     "the anchor never steals ordinary clicks")
    }

    func testCellsShareOneRouterRegistration() {
        let router = GridContextClickRouter.shared
        let baseline = router.registeredViewCount
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = host
        let cells = (0..<3).map { anchor(NSRect(x: CGFloat($0) * 50, y: 0, width: 50, height: 50)) }
        cells.forEach(host.addSubview)
        XCTAssertEqual(router.registeredViewCount, baseline + 3)
        cells.forEach { $0.removeFromSuperview() }
        XCTAssertEqual(router.registeredViewCount, baseline)
    }

    func testPersistedTableModeReopensInGridWhileTableIsHidden() {
        XCTAssertFalse(FeatureFlags.tableBrowser)
        XCTAssertEqual(AppState.restoredBrowseMode("table"), .grid)
        XCTAssertEqual(AppState.restoredBrowseMode("grid"), .grid)
        XCTAssertEqual(AppState.restoredBrowseMode(nil), .grid)
    }
}
