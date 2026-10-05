import XCTest
import AppKit
import GRDB
@testable import MediaViewer

final class PreferredDisplayRoleTests: XCTestCase {
    private var tempDirectory: URL!
    private var databaseURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreferredDisplayRoleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        databaseURL = tempDirectory.appendingPathComponent("test.sqlite")
    }

    override func tearDown() async throws {
        databaseURL = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try await super.tearDown()
    }

    func testPreferredDisplaySourceHonorsFlagWithSensibleMissingRoleFallbacks() throws {
        let mixed = try makeItem(prefersContextImage: false)
        let mediaURL = try XCTUnwrap(mixed.mediaFiles.first)
        let contextURL = try XCTUnwrap(mixed.contextImage)

        XCTAssertTrue(mixed.hasSwappablePresentationSources)
        XCTAssertEqual(mixed.availableDisplaySources, [.downloaded, .context])
        XCTAssertEqual(mixed.effectiveDisplaySource, .downloaded)
        XCTAssertEqual(mixed.preferredDisplaySource, mediaURL)
        XCTAssertEqual(mixed.thumbnailSource, mediaURL)

        var contextPreferred = mixed
        contextPreferred.prefersContextImage = true
        XCTAssertEqual(contextPreferred.effectiveDisplaySource, .context)
        XCTAssertEqual(contextPreferred.preferredDisplaySource, contextURL)
        XCTAssertEqual(contextPreferred.thumbnailSource, contextURL)
        XCTAssertEqual(contextPreferred.mediaFiles, mixed.mediaFiles)
        XCTAssertEqual(contextPreferred.contextImage, mixed.contextImage)

        var mediaOnly = mixed
        mediaOnly.contextImage = nil
        mediaOnly.prefersContextImage = true
        XCTAssertFalse(mediaOnly.hasSwappablePresentationSources)
        XCTAssertEqual(mediaOnly.availableDisplaySources, [.downloaded])
        XCTAssertEqual(mediaOnly.effectiveDisplaySource, .downloaded)
        XCTAssertTrue(mediaOnly.canDisplay(.downloaded))
        XCTAssertFalse(mediaOnly.canDisplay(.context))
        XCTAssertEqual(mediaOnly.preferredDisplaySource, mediaURL)

        var contextOnly = mixed
        contextOnly.mediaFiles = []
        contextOnly.prefersContextImage = false
        XCTAssertFalse(contextOnly.hasSwappablePresentationSources)
        XCTAssertEqual(contextOnly.availableDisplaySources, [.context])
        XCTAssertEqual(contextOnly.effectiveDisplaySource, .context)
        XCTAssertFalse(contextOnly.canDisplay(.downloaded))
        XCTAssertTrue(contextOnly.canDisplay(.context))
        XCTAssertEqual(contextOnly.preferredDisplaySource, contextURL)

        var empty = contextOnly
        empty.contextImage = nil
        XCTAssertTrue(empty.availableDisplaySources.isEmpty)
        XCTAssertNil(empty.effectiveDisplaySource)
        XCTAssertNil(empty.preferredDisplaySource)
    }

    func testDisplaySourceLabelsAreConcreteAndStable() {
        XCTAssertEqual(MediaItemDisplaySource.downloaded.label, "Downloaded")
        XCTAssertEqual(MediaItemDisplaySource.context.label, "Context")
    }

    func testTrimEligibilityUsesTheEffectiveDisplayedSourceAndExactSupportedFormats() throws {
        for ext in ["mp4", "MOV", "m4v"] {
            XCTAssertTrue(
                MediaItemDisplayActionPolicy.isTrimmable(
                    URL(fileURLWithPath: "/tmp/clip.\(ext)")
                ),
                "\(ext) should be accepted by the trim pipeline"
            )
        }
        for ext in ["webm", "avi", "mkv", "png"] {
            XCTAssertFalse(
                MediaItemDisplayActionPolicy.isTrimmable(
                    URL(fileURLWithPath: "/tmp/asset.\(ext)")
                ),
                "\(ext) should not advertise trimming"
            )
        }
        XCTAssertFalse(MediaItemDisplayActionPolicy.isTrimmable(nil))

        var item = try makeItem(prefersContextImage: false)
        item.mediaFiles = [tempDirectory.appendingPathComponent("downloaded.mp4")]
        XCTAssertEqual(item.effectiveDisplaySource, .downloaded)
        XCTAssertTrue(item.isPreferredDisplaySourceTrimmable)

        item.prefersContextImage = true
        XCTAssertEqual(item.effectiveDisplaySource, .context)
        XCTAssertFalse(
            item.isPreferredDisplaySourceTrimmable,
            "Showing a context image must not expose actions for the downloaded video"
        )
    }

    @MainActor
    func testRevealCommandEnablementTracksEffectiveDisplaySourceAvailability() throws {
        let registry = CommandRegistry.shared
        registry.clearAll()
        defer { registry.clearAll() }

        let appState = AppState()
        registry.registerDefaultCommands(appState: appState)
        let reveal = try XCTUnwrap(registry.command(id: "action.revealFinder"))
        let openSource = try XCTUnwrap(registry.command(id: "action.openSource"))

        var item = try makeItem(prefersContextImage: true)
        appState.focusedItem = item
        XCTAssertEqual(item.effectiveDisplaySource, .context)
        XCTAssertTrue(reveal.isEnabled(appState))
        XCTAssertTrue(openSource.isEnabled(appState))

        item.mediaFiles = []
        item.contextImage = nil
        appState.focusedItem = item
        XCTAssertNil(item.effectiveDisplaySource)
        XCTAssertFalse(reveal.isEnabled(appState))
        XCTAssertTrue(
            openSource.isEnabled(appState),
            "Opening the metadata source URL does not require a displayable local file"
        )
    }

    func testMigration35AndTargetedPersistenceSurviveFreshStore() async throws {
        let database = DatabaseManager(databaseURL: databaseURL)
        try await database.initialize()
        let store = MediaStore(database: database)
        let item = try makeItem(prefersContextImage: false)
        let originalSidecarData = try Data(contentsOf: item.metadataFile)
        try await store.insertItem(item)

        let migrationAndColumn = try await database.read { db in
            let migrationExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version = 35)"
            ) ?? false
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_items)")
            let hasColumn = columns.contains { ($0["name"] as String?) == "prefersContextImage" }
            return (migrationExists, hasColumn)
        }
        XCTAssertTrue(migrationAndColumn.0)
        XCTAssertTrue(migrationAndColumn.1)

        try await store.setPreferredDisplayRole(itemId: item.id, prefersContextImage: true)
        let firstFetchedValue = try await store.fetchItem(id: item.id)
        let firstFetched = try XCTUnwrap(firstFetchedValue)
        XCTAssertTrue(firstFetched.prefersContextImage)
        XCTAssertEqual(firstFetched.mediaFiles, item.mediaFiles)
        XCTAssertEqual(firstFetched.contextImage, item.contextImage)
        XCTAssertEqual(try Data(contentsOf: item.metadataFile), originalSidecarData)

        // A new manager/store reading the same SQLite file models process restart persistence.
        let restartedDatabase = DatabaseManager(databaseURL: databaseURL)
        try await restartedDatabase.initialize()
        let restartedStore = MediaStore(database: restartedDatabase)
        let restartedFetchedValue = try await restartedStore.fetchItem(id: item.id)
        let restartedFetched = try XCTUnwrap(restartedFetchedValue)
        XCTAssertTrue(restartedFetched.prefersContextImage)
        XCTAssertEqual(restartedFetched.thumbnailSource, item.contextImage)

        try await restartedStore.setPreferredDisplayRole(itemId: item.id, prefersContextImage: false)
        let resetFetchedValue = try await restartedStore.fetchItem(id: item.id)
        let resetFetched = try XCTUnwrap(resetFetchedValue)
        XCTAssertFalse(resetFetched.prefersContextImage)
        XCTAssertEqual(resetFetched.thumbnailSource, item.mediaFiles.first)
    }

    func testRecordRoundTripCarriesPreferredDisplayFlag() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try MediaItemRecord.createTable(in: db)
        }

        let item = try makeItem(prefersContextImage: true)
        try queue.write { db in
            try MediaItemRecord(from: item).insert(db)
        }
        let fetched = try queue.read { db in
            try MediaItemRecord.fetchOne(db, key: item.id.uuidString)?.toMediaItem()
        }

        let roundTripped = try XCTUnwrap(fetched)
        XCTAssertTrue(roundTripped.prefersContextImage)
        XCTAssertEqual(roundTripped.preferredDisplaySource, item.contextImage)
    }

    func testStartupReparsePreservesPreferredDisplayFlag() throws {
        let existing = try makeItem(prefersContextImage: true)
        let reparsedMedia = tempDirectory.appendingPathComponent("reparsed.jpg")
        let reparsedContext = tempDirectory.appendingPathComponent("reparsed.context.png")
        let parsed = MediaItem(
            id: UUID(),
            basePath: tempDirectory,
            metadataFile: existing.metadataFile,
            mediaFiles: [reparsedMedia],
            contextImage: reparsedContext,
            metadata: existing.metadata,
            aspectRatio: 2
        )

        let updated = AppCoordinator.changedScannedItem(parsed, preserving: existing)

        XCTAssertTrue(updated.prefersContextImage)
        XCTAssertEqual(updated.mediaFiles, parsed.mediaFiles)
        XCTAssertEqual(updated.contextImage, parsed.contextImage)
        XCTAssertEqual(updated.preferredDisplaySource, reparsedContext)
    }

    func testUnmodifiedXKeyRoutingDoesNotStealModifiedOrRepeatedEvents() {
        XCTAssertTrue(SingleFocusKeyRouting.shouldTogglePreferredDisplay(
            charactersIgnoringModifiers: "x",
            modifierFlags: [],
            isRepeat: false
        ))
        XCTAssertTrue(SingleFocusKeyRouting.shouldTogglePreferredDisplay(
            charactersIgnoringModifiers: "X",
            modifierFlags: [.capsLock],
            isRepeat: false
        ))

        for modifier: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            XCTAssertFalse(SingleFocusKeyRouting.shouldTogglePreferredDisplay(
                charactersIgnoringModifiers: "x",
                modifierFlags: modifier,
                isRepeat: false
            ))
        }
        XCTAssertFalse(SingleFocusKeyRouting.shouldTogglePreferredDisplay(
            charactersIgnoringModifiers: "x",
            modifierFlags: [],
            isRepeat: true
        ))
        XCTAssertFalse(SingleFocusKeyRouting.shouldTogglePreferredDisplay(
            charactersIgnoringModifiers: "s",
            modifierFlags: [],
            isRepeat: false
        ))
    }

    func testThumbnailIdentityAndDiskVariantFollowEffectiveDisplaySource() throws {
        let mediaItem = try makeItem(prefersContextImage: false)
        var contextItem = mediaItem
        contextItem.prefersContextImage = true

        XCTAssertNotEqual(
            ImageCache.thumbnailLoadIdentity(for: mediaItem),
            ImageCache.thumbnailLoadIdentity(for: contextItem)
        )
        XCTAssertNil(ImageCache.diskCacheVariant(for: mediaItem))
        XCTAssertNotNil(ImageCache.diskCacheVariant(for: contextItem))

        var replacedContext = contextItem
        replacedContext.contextImage = tempDirectory.appendingPathComponent("replacement.context.png")
        XCTAssertNotEqual(
            ImageCache.thumbnailLoadIdentity(for: contextItem),
            ImageCache.thumbnailLoadIdentity(for: replacedContext)
        )
        XCTAssertNotEqual(
            ImageCache.diskCacheVariant(for: contextItem),
            ImageCache.diskCacheVariant(for: replacedContext)
        )
    }

    func testCacheToggleAndFreshCacheNeverReusePrimaryThumbnailForContext() async throws {
        var mediaItem = try makeItem(prefersContextImage: false)
        let mediaURL = try XCTUnwrap(mediaItem.mediaFiles.first)
        let contextURL = try XCTUnwrap(mediaItem.contextImage)
        try writeSolidJPEG(size: NSSize(width: 80, height: 20), color: .red, to: mediaURL)
        try writeSolidJPEG(size: NSSize(width: 20, height: 80), color: .blue, to: contextURL)
        defer { ThumbnailGenerator.deleteThumbnails(for: mediaItem.id) }

        let cache = ImageCache()
        await cache.clearAll(itemId: mediaItem.id)
        let loadedPrimary = await cache.loadThumbnail(for: mediaItem)
        let primary = try XCTUnwrap(loadedPrimary)
        XCTAssertGreaterThan(primary.size.width, primary.size.height)

        mediaItem.prefersContextImage = true
        let loadedContext = await cache.loadThumbnail(for: mediaItem)
        let context = try XCTUnwrap(loadedContext)
        XCTAssertGreaterThan(context.size.height, context.size.width)

        let restartedCache = ImageCache()
        let loadedRestartedContext = await restartedCache.loadThumbnail(for: mediaItem)
        let restartedContext = try XCTUnwrap(loadedRestartedContext)
        XCTAssertGreaterThan(restartedContext.size.height, restartedContext.size.width)
    }

    func testMasonryCellEqualityIncludesPreferredSource() throws {
        let mediaItem = try makeItem(prefersContextImage: false)
        var contextItem = mediaItem
        contextItem.prefersContextImage = true

        func cell(_ item: MediaItem) -> MasonryCell {
            MasonryCell(
                item: item,
                isSelected: false,
                isMultiSelectMode: false,
                showColorBar: false,
                selectedIDs: [],
                onSelect: {},
                onToggleSelect: {},
                onExtendSelect: {},
                onDoubleClick: {},
                onShowContextMenu: nil
            )
        }

        XCTAssertNotEqual(cell(mediaItem), cell(contextItem))
        XCTAssertFalse(MasonryPresentationPolicy.isPresentingContext(mediaItem))
        XCTAssertTrue(MasonryPresentationPolicy.isPresentingContext(contextItem))
        XCTAssertEqual(MasonryPresentationPolicy.layoutAspectRatio(for: contextItem), 1)
    }

    func testChangingPresentationSourceInvalidatesLegacyItemThumbnail() async throws {
        let database = DatabaseManager(databaseURL: databaseURL)
        try await database.initialize()
        let store = MediaStore(database: database)
        var item = try makeItem(prefersContextImage: false)
        let originalURL = try XCTUnwrap(item.mediaFiles.first)
        try writeSolidJPEG(size: NSSize(width: 60, height: 20), color: .red, to: originalURL)
        try await store.insertItem(item)
        defer { ThumbnailGenerator.deleteThumbnails(for: item.id) }

        let generated = await ImageCache.shared.loadThumbnail(for: item)
        XCTAssertNotNil(generated)
        XCTAssertTrue(ThumbnailGenerator.thumbnailExists(for: item.id, size: .small))

        let replacementURL = tempDirectory.appendingPathComponent("replacement.jpg")
        try writeSolidJPEG(size: NSSize(width: 20, height: 60), color: .blue, to: replacementURL)
        item.mediaFiles = [replacementURL]
        try await store.updateItem(item)

        XCTAssertFalse(
            ThumbnailGenerator.thumbnailExists(for: item.id, size: .small),
            "A changed primary source must not inherit the previous source's disk thumbnail"
        )
    }

    private func writeSolidJPEG(size: NSSize, color: NSColor, to url: URL) throws {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(ThumbnailGenerator.jpegData(from: image, quality: 1))
        try data.write(to: url, options: .atomic)
    }

    private func makeItem(prefersContextImage: Bool) throws -> MediaItem {
        let id = UUID()
        let metadataFile = tempDirectory.appendingPathComponent("\(id.uuidString).md")
        let mediaFile = tempDirectory.appendingPathComponent("\(id.uuidString).jpg")
        let contextImage = tempDirectory.appendingPathComponent("\(id.uuidString).context.png")
        try "---\nsource: https://example.com/item\n---\n".write(
            to: metadataFile,
            atomically: true,
            encoding: .utf8
        )
        FileManager.default.createFile(atPath: mediaFile.path, contents: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        FileManager.default.createFile(atPath: contextImage.path, contents: Data([0x89, 0x50, 0x4E, 0x47]))

        return MediaItem(
            id: id,
            basePath: tempDirectory,
            metadataFile: metadataFile,
            mediaFiles: [mediaFile],
            contextImage: contextImage,
            prefersContextImage: prefersContextImage,
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/item")!,
                platform: "test",
                archivedDate: Date(timeIntervalSince1970: 1_788_393_600)
            ),
            aspectRatio: 1
        )
    }
}
