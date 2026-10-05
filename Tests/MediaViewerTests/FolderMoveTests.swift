import XCTest
import GRDB
@testable import MediaViewer

/// Dropping items on a sidebar folder row moves the item's base folder. Captures and imports
/// share their month folder, so that used to move every item of the month.
final class FolderMoveTests: XCTestCase {
    private var tempDir: URL!
    private var archive: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderMoveTests-\(UUID().uuidString)", isDirectory: true)
        archive = tempDir.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        database = DatabaseManager(databaseURL: tempDir.appendingPathComponent("move.sqlite"))
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

    private func makeItem(folder: String, stem: String, basePath: URL? = nil) throws -> MediaItem {
        let directory = archive.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sidecar = directory.appendingPathComponent("\(stem).md")
        let media = directory.appendingPathComponent("\(stem).jpg")
        try "---\nsource: https://example.com/\(stem)\n---\n".write(to: sidecar, atomically: true, encoding: .utf8)
        try "jpeg".write(to: media, atomically: true, encoding: .utf8)
        return MediaItem(
            id: UUID(),
            basePath: basePath ?? directory,
            metadataFile: sidecar,
            mediaFiles: [media],
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/\(stem)")!,
                platform: "web",
                archivedDate: Date()
            )
        )
    }

    private func moveRefusal(_ ids: [UUID], to folder: String) async -> MediaStore.FolderMoveError? {
        do {
            try await store.moveItemsToFolder(ids: ids, targetFolder: folder, archivePath: archive)
            return nil
        } catch {
            return error as? MediaStore.FolderMoveError
        }
    }

    private func files(in folder: String) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: archive.appendingPathComponent(folder).path))
    }

    func testCaptureInASharedMonthFolderIsNotMovedWithItsNeighbours() async throws {
        // Imports and runtime indexing record the month folder as the base path.
        let dragged = try makeItem(folder: "2026-10", stem: "dragged")
        let neighbour = try makeItem(folder: "2026-10", stem: "neighbour")
        try await store.insertItem(dragged)
        try await store.insertItem(neighbour)

        let refusal = await moveRefusal([dragged.id], to: "2026-09")

        XCTAssertNotNil(refusal)
        XCTAssertEqual(try files(in: "2026-10"), ["dragged.md", "dragged.jpg", "neighbour.md", "neighbour.jpg"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.appendingPathComponent("2026-09/2026-10").path))
        let stored = try await store.fetchItem(id: dragged.id)
        XCTAssertEqual(stored?.basePath.standardizedFileURL, dragged.basePath.standardizedFileURL)
    }

    func testStartupScannedItemIsRefusedInsteadOfFailingQuietly() async throws {
        // The startup scan records the sidecar's path without its extension.
        let month = archive.appendingPathComponent("2026-10", isDirectory: true)
        let item = try makeItem(folder: "2026-10", stem: "scanned", basePath: month.appendingPathComponent("scanned"))
        try await store.insertItem(item)

        let refusal = await moveRefusal([item.id], to: "2026-09")

        XCTAssertEqual(refusal?.errorDescription, MediaStore.FolderMoveError.sharedFolder(count: 1).errorDescription)
        XCTAssertEqual(try files(in: "2026-10"), ["scanned.md", "scanned.jpg"])
    }

    func testItemThatOwnsItsFolderStillMoves() async throws {
        let item = try makeItem(folder: "2025-12_01-15-30", stem: "own")
        try "lock".write(
            to: archive.appendingPathComponent("2025-12_01-15-30/.own.md.nodraw-lock"),
            atomically: true,
            encoding: .utf8
        )
        try await store.insertItem(item)

        let refusal = await moveRefusal([item.id], to: "keep")

        XCTAssertNil(refusal)
        let moved = archive.appendingPathComponent("keep/2025-12_01-15-30")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("own.md").path))
        let stored = try await store.fetchItem(id: item.id)
        XCTAssertEqual(stored?.metadataFile.standardizedFileURL.path, moved.appendingPathComponent("own.md").standardizedFileURL.path)
    }
}
