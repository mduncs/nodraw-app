import XCTest
import Combine
@testable import MediaViewer

@MainActor
final class MediaStoreChangeTests: XCTestCase {
    func testKnownItemUpdatePublishesIDAndKeepsLegacyNotification() async throws {
        let (store, item, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var detailed: [MediaStoreChange] = []
        var legacyCount = 0
        let detailedToken = store.detailedChanges.sink { detailed.append($0) }
        let legacyToken = store.changes.sink { legacyCount += 1 }
        defer { detailedToken.cancel(); legacyToken.cancel() }

        try await store.updateItem(item)

        XCTAssertEqual(detailed, [.items([item.id])])
        XCTAssertEqual(legacyCount, 1)
    }

    func testTileAndAssetMutationsPublishOnlyTheirItem() async throws {
        let (store, item, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var detailed: [MediaStoreChange] = []
        let token = store.detailedChanges.sink { detailed.append($0) }
        defer { token.cancel() }

        try await store.toggleStar(id: item.id)
        try await store.setStar(id: item.id, starred: false)
        try await store.updateNotes(id: item.id, notes: "Updated")
        try await store.removeTag(id: item.id, tag: "absent")
        try await store.setPreferredDisplayRole(itemId: item.id, prefersContextImage: true)
        try await store.refreshAssets(itemID: item.id)
        try await store.updateMediaFiles(id: item.id, files: [])

        XCTAssertEqual(detailed, Array(repeating: .items([item.id]), count: 7))
    }

    func testDeletesPublishIDsForInPlaceRemoval() async throws {
        let (store, item, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var detailed: [MediaStoreChange] = []
        let token = store.detailedChanges.sink { detailed.append($0) }
        defer { token.cancel() }

        try await store.softDelete(ids: [item.id])
        try await store.deleteItem(id: item.id)

        XCTAssertEqual(detailed, [.deleted([item.id]), .deleted([item.id])])
    }

    func testInsertAndGlobalTagChangesRequestRangeReload() async throws {
        let (store, item, directory) = try await fixture(insert: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var detailed: [MediaStoreChange] = []
        var legacyCount = 0
        let detailedToken = store.detailedChanges.sink { detailed.append($0) }
        let legacyToken = store.changes.sink { legacyCount += 1 }
        defer { detailedToken.cancel(); legacyToken.cancel() }

        try await store.insertItem(item)
        _ = try await store.removeTagGlobally(tag: "absent")

        XCTAssertEqual(detailed, [.reload, .reload])
        XCTAssertEqual(legacyCount, 2)
    }

    func testRestoreRequestsReloadBecauseItemCanReenterRange() async throws {
        let (store, item, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.softDelete(ids: [item.id])
        var detailed: [MediaStoreChange] = []
        let token = store.detailedChanges.sink { detailed.append($0) }
        defer { token.cancel() }

        try await store.restoreDeleted(ids: [item.id])

        XCTAssertEqual(detailed, [.reload])
    }

    private func fixture(insert: Bool = true) async throws -> (MediaStore, MediaItem, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaStoreChangeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = DatabaseManager(databaseURL: directory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        let store = MediaStore(database: database)
        let item = MediaItem(
            id: UUID(),
            basePath: directory,
            metadataFile: directory.appendingPathComponent("item.md"),
            mediaFiles: [],
            metadata: MediaMetadata(source: URL(string: "https://example.com/item")!, platform: "test")
        )
        if insert { try await store.insertItem(item) }
        return (store, item, directory)
    }
}
