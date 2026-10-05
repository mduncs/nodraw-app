import XCTest
import GRDB
@testable import MediaViewer

final class ImportServiceTests: XCTestCase {
    private var tempDir: URL!
    private var archiveURL: URL!
    private var sourceURL: URL!
    private var databaseManager: DatabaseManager!
    private var mediaStore: MediaStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportServiceTests-\(UUID().uuidString)", isDirectory: true)
        archiveURL = tempDir.appendingPathComponent("archive", isDirectory: true)
        sourceURL = tempDir.appendingPathComponent("source", isDirectory: true)

        try FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)

        let dbURL = tempDir.appendingPathComponent("test.sqlite")
        databaseManager = DatabaseManager(databaseURL: dbURL)
        try await databaseManager.initialize()
        mediaStore = MediaStore(database: databaseManager)
    }

    override func tearDown() async throws {
        mediaStore = nil
        databaseManager = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        archiveURL = nil
        sourceURL = nil
    }

    func testWebMIsSupportedForImport() {
        XCTAssertTrue(ImportService.videoExtensions.contains("webm"))
        XCTAssertTrue(ImportService.supportedExtensions.contains("webm"))
    }

    func testImportUsesFileDateAsArchiveDateWithoutVisionQueue() async throws {
        let sourceFile = sourceURL.appendingPathComponent("sample.png")
        try Self.minimalPNG.write(to: sourceFile)

        // 2019-07-15T12:00:00Z (month chosen to avoid timezone edge cases)
        let fileDate = Date(timeIntervalSince1970: 1_563_192_000)
        try FileManager.default.setAttributes(
            [.creationDate: fileDate, .modificationDate: fileDate],
            ofItemAtPath: sourceFile.path
        )

        let service = ImportService(
            mediaStore: mediaStore,
            visionQueue: nil,
            archivePath: archiveURL
        )

        let result = try await service.importFiles(
            [sourceFile],
            options: ImportOptions(useFileDateAsArchiveDate: true)
        )

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.createdItemIds.count, 1)

        let expectedFolder = archiveURL.appendingPathComponent("2019-07", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFolder.path))

        let archivedDate: Date? = try await databaseManager.read { db in
            try Date.fetchOne(db, sql: "SELECT archivedDate FROM media_items LIMIT 1")
        }
        XCTAssertNotNil(archivedDate)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        if let archivedDate {
            XCTAssertEqual(formatter.string(from: archivedDate), "2019-07")
        }
    }

    private static let minimalPNG = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F,
        0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59,
        0xE7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82
    ])
}
