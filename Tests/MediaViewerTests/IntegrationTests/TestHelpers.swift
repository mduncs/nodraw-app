import Foundation
import GRDB
@testable import MediaViewer

// MARK: - TestDatabase

/// File-based GRDB database for testing.
/// Uses temp file to support WAL mode properly.
actor TestDatabase {
    private var pool: DatabasePool?
    private var tempPath: String?

    /// Initialize a temp file database with schema
    func initialize() async throws -> DatabasePool {
        // Create temp file for database (WAL mode requires file-based db)
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("TestDB_\(UUID().uuidString).sqlite").path
        self.tempPath = dbPath

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let pool = try DatabasePool(
            path: dbPath,
            configuration: config
        )

        try await pool.write { db in
            try self.createSchema(db)
        }

        self.pool = pool
        return pool
    }

    /// Create the database schema (same as production)
    private nonisolated func createSchema(_ db: Database) throws {
        // Schema migrations table
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
        """)

        // Media items table
        try MediaItemRecord.createTable(in: db)

        // Junction tables (created by migrations 4 and 7 in production)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS media_tags (
                item_id TEXT NOT NULL,
                tag TEXT NOT NULL,
                PRIMARY KEY (item_id, tag),
                FOREIGN KEY (item_id) REFERENCES media_items(id) ON DELETE CASCADE
            )
        """)
        try db.create(index: "idx_media_tags_tag", on: "media_tags", columns: ["tag"], ifNotExists: true)

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS media_colors (
                item_id TEXT NOT NULL,
                color_bucket TEXT NOT NULL,
                PRIMARY KEY (item_id, color_bucket),
                FOREIGN KEY (item_id) REFERENCES media_items(id) ON DELETE CASCADE
            )
        """)
        try db.create(index: "idx_media_colors_bucket", on: "media_colors", columns: ["color_bucket"], ifNotExists: true)

        // Smart folders table
        try SmartFolder.createTable(in: db)
    }

    /// Get the database pool
    func getPool() throws -> DatabasePool {
        guard let pool = pool else {
            throw TestError.databaseNotInitialized
        }
        return pool
    }

    /// Clean up
    func tearDown() async {
        pool = nil
        // Remove temp database files
        if let path = tempPath {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + "-wal")
            try? FileManager.default.removeItem(atPath: path + "-shm")
        }
        tempPath = nil
    }
}

// MARK: - IntegrationTestDBManager

/// Database manager wrapper for integration tests.
/// Provides the same interface as DatabaseManager but with a test database pool.
actor IntegrationTestDBManager {
    private var pool: DatabasePool?

    init(pool: DatabasePool) {
        self.pool = pool
    }

    func read<T>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        guard let pool = pool else {
            throw TestError.databaseNotInitialized
        }
        return try await pool.read(block)
    }

    func write<T>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        guard let pool = pool else {
            throw TestError.databaseNotInitialized
        }
        return try await pool.write(block)
    }

    func getPool() throws -> DatabasePool {
        guard let pool = pool else {
            throw TestError.databaseNotInitialized
        }
        return pool
    }
}

// MARK: - TestArchive

/// Creates a temporary directory structure mimicking MediaArchive for testing.
final class TestArchive: @unchecked Sendable {
    let rootURL: URL
    private let fileManager = FileManager.default

    init() throws {
        // Create temp directory
        let tempDir = fileManager.temporaryDirectory
        let archiveName = "TestArchive_\(UUID().uuidString)"
        rootURL = tempDir.appendingPathComponent(archiveName, isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    deinit {
        // Clean up on deallocation - schedule cleanup asynchronously
        let url = rootURL
        let fm = fileManager
        Task.detached {
            try? fm.removeItem(at: url)
        }
    }

    /// Remove the test archive directory
    func cleanup() throws {
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
    }

    /// Create a year-month folder (e.g., "2025-01")
    @discardableResult
    func createFolder(_ name: String) throws -> URL {
        let folderURL = rootURL.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }

    /// Create a metadata .md file with frontmatter
    @discardableResult
    func createMetadataFile(
        in folder: String,
        name: String,
        source: String,
        platform: String = "twitter",
        author: String? = nil,
        date: String? = nil,
        starred: Bool = false,
        tags: [String] = []
    ) throws -> URL {
        let folderURL = try createFolder(folder)
        let fileURL = folderURL.appendingPathComponent("\(name).md")

        var yaml = """
        ---
        source: \(source)
        platform: \(platform)
        """

        if let author = author {
            yaml += "\nauthor: \"\(author)\""
        }

        if let date = date {
            yaml += "\ndate: \(date)"
        }

        yaml += "\narchived: 2025-01-15"

        if starred {
            yaml += "\nstarred: true"
        }

        if !tags.isEmpty {
            yaml += "\ntags:\n"
            for tag in tags {
                yaml += "  - \(tag)\n"
            }
        }

        yaml += "\n---\n"

        try yaml.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Create a dummy image file
    @discardableResult
    func createImageFile(in folder: String, name: String, extension ext: String = "jpg") throws -> URL {
        let folderURL = try createFolder(folder)
        let fileURL = folderURL.appendingPathComponent("\(name).\(ext)")

        // Create a minimal valid image (1x1 PNG - smallest valid image)
        let pngData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, // IDAT chunk
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F,
            0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59,
            0xE7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, // IEND chunk
            0x44, 0xAE, 0x42, 0x60, 0x82
        ])

        try pngData.write(to: fileURL)
        return fileURL
    }

    /// Create a complete archive item (metadata + image)
    func createItem(
        in folder: String,
        baseName: String,
        source: String,
        platform: String = "twitter",
        author: String? = nil,
        date: String? = nil,
        starred: Bool = false,
        tags: [String] = [],
        imageExtension: String = "jpg"
    ) throws -> (metadata: URL, image: URL) {
        let metadataURL = try createMetadataFile(
            in: folder,
            name: baseName,
            source: source,
            platform: platform,
            author: author,
            date: date,
            starred: starred,
            tags: tags
        )
        let imageURL = try createImageFile(in: folder, name: baseName, extension: imageExtension)
        return (metadataURL, imageURL)
    }

    /// Modify an existing metadata file
    func updateMetadataFile(_ url: URL, newContent: String) throws {
        try newContent.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Delete a file
    func deleteFile(_ url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    /// Rename a file
    func renameFile(from oldURL: URL, to newName: String) throws -> URL {
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)
        try fileManager.moveItem(at: oldURL, to: newURL)
        return newURL
    }
}

// MARK: - SampleData

/// Factory methods for creating test data
enum SampleData {
    /// Create a MediaItem for testing
    static func createMediaItem(
        id: UUID = UUID(),
        basePath: URL = URL(fileURLWithPath: "/test/2025-01"),
        metadataFile: URL? = nil,
        mediaFiles: [URL]? = nil,
        source: String = "https://twitter.com/user/status/123",
        platform: String = "twitter",
        author: String? = "@testuser",
        originalDate: Date? = nil,
        archivedDate: Date = Date(),
        starred: Bool = false,
        tags: [String] = [],
        notes: String? = nil,
        ocrText: String? = nil,
        parseStatus: ParseStatus = .success
    ) -> MediaItem {
        // Use unique paths based on id to avoid UNIQUE constraint violations
        let actualMetadataFile = metadataFile ?? basePath.appendingPathComponent("\(id.uuidString).md")
        let actualMediaFiles = mediaFiles ?? [basePath.appendingPathComponent("\(id.uuidString).jpg")]

        let metadata = MediaMetadata(
            source: URL(string: source)!,
            platform: platform,
            author: author,
            originalDate: originalDate,
            archivedDate: archivedDate,
            starred: starred,
            tags: tags,
            notes: notes
        )

        var indexedContent: IndexedContent? = nil
        if let ocrText = ocrText {
            indexedContent = IndexedContent(ocrText: ocrText)
        }

        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: actualMetadataFile,
            mediaFiles: actualMediaFiles,
            contextImage: nil,
            metadata: metadata,
            indexedContent: indexedContent,
            aspectRatio: 1.5,
            parseStatus: parseStatus
        )
    }

    /// Create a MediaItemRecord for direct database insertion
    static func createRecord(from item: MediaItem) -> MediaItemRecord {
        MediaItemRecord(from: item)
    }

    /// Create a SmartFolder for testing
    static func createSmartFolder(
        id: UUID = UUID(),
        name: String = "Test Folder",
        rules: [FilterRule],
        matchAll: Bool = true
    ) -> SmartFolder {
        SmartFolder(
            id: id,
            name: name,
            icon: "folder",
            rules: rules,
            matchAll: matchAll,
            sortOrder: .archivedDateDescending
        )
    }

    /// Sample items with varied metadata for filter testing
    static func sampleItems() -> [MediaItem] {
        let baseDate = Date()
        let calendar = Calendar.current

        return [
            createMediaItem(
                id: UUID(),
                platform: "twitter",
                author: "@alice",
                originalDate: calendar.date(byAdding: .day, value: -1, to: baseDate),
                starred: true,
                tags: ["art", "illustration"],
                ocrText: "Beautiful sunset painting"
            ),
            createMediaItem(
                id: UUID(),
                platform: "instagram",
                author: "@bob",
                originalDate: calendar.date(byAdding: .day, value: -7, to: baseDate),
                starred: false,
                tags: ["photo"],
                ocrText: "Mountain landscape"
            ),
            createMediaItem(
                id: UUID(),
                platform: "twitter",
                author: "@charlie",
                originalDate: calendar.date(byAdding: .month, value: -1, to: baseDate),
                starred: true,
                tags: ["meme"],
                ocrText: "Funny cat meme text"
            ),
            createMediaItem(
                id: UUID(),
                platform: "reddit",
                author: "u/dave",
                originalDate: calendar.date(byAdding: .day, value: -3, to: baseDate),
                starred: false,
                tags: [],
                ocrText: nil
            ),
            createMediaItem(
                id: UUID(),
                platform: "twitter",
                author: "@alice",
                originalDate: calendar.date(byAdding: .hour, value: -2, to: baseDate),
                starred: false,
                tags: ["art"],
                notes: "Remember to share this"
            ),
        ]
    }
}

// MARK: - TestError

enum TestError: Error, LocalizedError {
    case databaseNotInitialized
    case archiveNotFound
    case timeout
    case unexpectedState(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "Test database not initialized"
        case .archiveNotFound:
            return "Test archive directory not found"
        case .timeout:
            return "Operation timed out"
        case .unexpectedState(let message):
            return "Unexpected state: \(message)"
        }
    }
}

// MARK: - Async Test Helpers

/// Wait for a condition with timeout
func waitFor(
    timeout: TimeInterval = 5.0,
    interval: TimeInterval = 0.1,
    condition: @escaping () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }

    throw TestError.timeout
}

/// Assert async operation completes within timeout
func assertEventually<T: Equatable>(
    timeout: TimeInterval = 5.0,
    interval: TimeInterval = 0.1,
    _ expression: @escaping () async throws -> T,
    equals expected: T
) async throws {
    let deadline = Date().addingTimeInterval(timeout)

    var lastValue: T?
    while Date() < deadline {
        do {
            lastValue = try await expression()
            if lastValue == expected {
                return
            }
        } catch {
            // Retry on error
        }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }

    throw TestError.unexpectedState("Expected \(expected), got \(String(describing: lastValue))")
}
