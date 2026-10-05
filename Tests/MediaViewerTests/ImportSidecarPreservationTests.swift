import XCTest
import Yams
@testable import MediaViewer

final class ImportSidecarPreservationTests: XCTestCase {
    private var root: URL!
    private var archive: URL!
    private var source: URL!
    private var database: DatabaseManager!
    private var store: MediaStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ImportSidecar-\(UUID())")
        archive = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        source = root.appendingPathComponent("source.png")
        try ImportDurabilityTests.png.write(to: source)
        database = DatabaseManager(databaseURL: root.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        store = MediaStore(database: database)
    }

    override func tearDown() async throws {
        store = nil
        database = nil
        try? FileManager.default.removeItem(at: root)
    }

    private var sidecar: URL { source.deletingPathExtension().appendingPathExtension("md") }
    private var journal: ImportOperationJournal { ImportOperationJournal(archivePath: archive) }
    private func service(checkpoint: (@Sendable (ImportOperation.Phase) throws -> Void)? = nil) -> ImportService {
        ImportService(mediaStore: store, visionQueue: nil, archivePath: archive, checkpoint: checkpoint)
    }

    private let header = """
    source: https://example.com/post
    platform: twitter
    archived: 2001-01-01T00:00:00Z
    starred: true
    tags: [source, SOURCE, ' spaced ']
    notes: captured notes
    author: alice
    date: 2024-01-02T03:04:05Z
    created: 1999-01-01T00:00:00Z
    download_date: 2024-01-03T03:04:05Z
    import_date: 2001-01-01T00:00:00Z
    upload_date: 2024-01-04T03:04:05Z
    import_operation_id: source-marker
    deleted: true
    annotated: true
    title: 'Captured: café'
    capture_id: capture-123
    tweet_id: '1234567890123456789'
    media_count: 2
    links: [https://example.com/a, https://example.com/b]
    details:
      counts: {images: 2, videos: 0}
      flags: [true, false]
      timestamps: [2026-10-02T23:33:13.640333, 2026-10-02T23:33:13.123456Z, 1999-01-02T03:04:05.123456Z]
    posted: 2026-10-02T23:33:13
    """

    private let managedKeys: Set<String> = [
        "source", "platform", "archived", "starred", "tags", "notes", "author", "date", "created",
        "download_date", "import_date", "upload_date", "import_operation_id", "deleted", "annotated"
    ]

    private func values(_ content: String) throws -> [String: Any] {
        let bounds = try FrontmatterWriter.parseBoundaries(content)
        return try XCTUnwrap(SidecarYAML.load(yaml: bounds.yamlText) as? [String: Any])
    }

    // The pre-preservation writer's output, including omission of empty optional fields.
    private func legacyContent(_ operation: ImportOperation) throws -> String {
        let metadata = operation.metadata
        let formatter = ISO8601DateFormatter()
        var yaml: [String: Any] = [
            "source": metadata.source.absoluteString, "platform": metadata.platform,
            "archived": formatter.string(from: metadata.archivedDate), "starred": metadata.starred,
            "tags": metadata.tags, "import_operation_id": operation.id.uuidString
        ]
        for (key, date) in [("download_date", metadata.downloadDate), ("import_date", metadata.importDate),
                            ("upload_date", metadata.uploadDate)] {
            if let date { yaml[key] = formatter.string(from: date) }
        }
        if let author = metadata.author, !author.isEmpty { yaml["author"] = author }
        if let date = metadata.originalDate {
            yaml["date"] = formatter.string(from: date)
            yaml["created"] = formatter.string(from: date)
        }
        if let notes = metadata.notes, !notes.isEmpty { yaml["notes"] = notes }
        let frontmatter = try Yams.dump(object: yaml, allowUnicode: true, sortKeys: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "---\n\(frontmatter)\n---\n"
    }

    private func checkPreserved(_ operation: ImportOperation, original: String, body: String) throws {
        let imported = try String(contentsOf: operation.metadataURL, encoding: .utf8)
        let actual = try values(imported)
        let sourceValues = try values(original)
        XCTAssertEqual(actual.filter { !managedKeys.contains($0.key) } as NSDictionary,
                       sourceValues.filter { !managedKeys.contains($0.key) } as NSDictionary)
        XCTAssertEqual(actual.filter { managedKeys.contains($0.key) } as NSDictionary,
                       try values(legacyContent(operation)) as NSDictionary)
        let bounds = try FrontmatterWriter.parseBoundaries(imported)
        XCTAssertEqual(Data(imported[bounds.bodyStartIndex...].utf8), Data(body.utf8))
        let posted = try XCTUnwrap(actual["posted"] as? Date)
        XCTAssertEqual(posted, sourceValues["posted"] as? Date)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone.current
        XCTAssertEqual(posted, local.date(from: DateComponents(year: 2026, month: 10, day: 2,
                                                              hour: 23, minute: 33, second: 13)))
    }

    func testImportPreservesExtraHeaderValuesAndExactMarkdownBody() async throws {
        let body = "\n\n# Captured café 👋\n\n> tweet  \n![[source.png]]\n---\nNotes: e\u{301}\t\nNo final newline"
        let original = "---\n\(header)\n---\(body)"
        try original.write(to: sidecar, atomically: true, encoding: .utf8)
        let result = try await service().importFiles([source], tags: ["SOURCE", "preset"])
        XCTAssertEqual(result.importedCount, 1)
        let operation = try XCTUnwrap(journal.operations().first)
        XCTAssertEqual(operation.metadata.tags, ["source", "spaced", "preset"])
        try checkPreserved(operation, original: original, body: body)
        XCTAssertEqual(try Data(contentsOf: sidecar), Data(original.utf8))
        let imported = try MetadataParser.parse(fileAt: operation.metadataURL)
        XCTAssertFalse(imported.deleted)
        XCTAssertFalse(imported.annotated)
    }

    func testImportPreservesCRLFBodyAndOmitsEmptyOrInvalidManagedFields() async throws {
        let body = "\r\n\r\nCaptured text  \r\n\t![[source.png]]\r\n"
        let fields = header.replacingOccurrences(of: "notes: captured notes", with: "notes: ''")
            .replacingOccurrences(of: "author: alice", with: "author: ''")
            .replacingOccurrences(of: "download_date: 2024-01-03T03:04:05Z", with: "download_date: invalid")
            .replacingOccurrences(of: "upload_date: 2024-01-04T03:04:05Z", with: "upload_date: invalid")
        let original = "---\r\n\(fields.replacingOccurrences(of: "\n", with: "\r\n"))\r\n---\(body)"
        try original.write(to: sidecar, atomically: true, encoding: .utf8)
        let result = try await service().importFiles([source])
        XCTAssertEqual(result.importedCount, 1)
        let operation = try XCTUnwrap(journal.operations().first)
        try checkPreserved(operation, original: original, body: body)
        let imported = try values(String(contentsOf: operation.metadataURL, encoding: .utf8))
        for key in ["notes", "author", "download_date", "upload_date"] { XCTAssertNil(imported[key], key) }
    }

    func testNoSidecarKeepsLegacyOutput() async throws {
        let result = try await service().importFiles([source], tags: ["preset"])
        XCTAssertEqual(result.importedCount, 1)
        let operation = try XCTUnwrap(journal.operations().first)
        XCTAssertEqual(try Data(contentsOf: operation.metadataURL), Data(try legacyContent(operation).utf8))
    }

    func testMalformedSidecarKeepsLegacyFallback() async throws {
        let original = "---\nsource: [broken YAML\n---\n# Body ignored by legacy fallback\n"
        try original.write(to: sidecar, atomically: true, encoding: .utf8)
        let result = try await service().importFiles([source], tags: ["preset"])
        XCTAssertEqual(result.importedCount, 1)
        let operation = try XCTUnwrap(journal.operations().first)
        XCTAssertEqual(try Data(contentsOf: operation.metadataURL), Data(try legacyContent(operation).utf8))
        XCTAssertEqual(try Data(contentsOf: sidecar), Data(original.utf8))
    }

    func testSourceChangeAfterPreparationFailsWithoutMixingVersions() async throws {
        let sidecarURL = sidecar
        let original = "---\n\(header)\n---\nOriginal body"
        try original.write(to: sidecarURL, atomically: true, encoding: .utf8)
        let result = try await service().importFiles([source], progress: { progress in
            if progress.completed == 0 {
                try? "---\nsource: https://example.com/changed\ntitle: changed\n---\nChanged body"
                    .write(to: sidecarURL, atomically: true, encoding: .utf8)
            }
        })
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.importedCount, 0)
        let operation = try XCTUnwrap(journal.operations().first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: operation.metadataURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: operation.destinationURL.path))
        XCTAssertTrue(result.errors.first?.reason.localizedCaseInsensitiveContains("sidecar changed") == true)
    }

    func testStagedRecoveryPreservesSidecarWithoutSourceFiles() async throws {
        let body = "\n# Recovery body  \n![[source.png]]"
        let original = "---\n\(header)\n---\(body)"
        try original.write(to: sidecar, atomically: true, encoding: .utf8)
        let result = try await service(checkpoint: { phase in
            if phase == .staged { throw CocoaError(.fileWriteOutOfSpace) }
        }).importFiles([source])
        XCTAssertEqual(result.failedCount, 1)
        let operation = try XCTUnwrap(journal.operations().first)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.removeItem(at: sidecar)
        let recovered = await service().recoverInterruptedImports()
        XCTAssertEqual(recovered.failedCount, 0)
        XCTAssertEqual(recovered.createdItemIds, [operation.itemID])
        try checkPreserved(operation, original: original, body: body)
    }

    func testOldJournalWithoutSourceEvidenceDecodesAndRecovers() async throws {
        let result = try await service(checkpoint: { phase in
            if phase == .staged { throw CocoaError(.fileWriteOutOfSpace) }
        }).importFiles([source])
        XCTAssertEqual(result.failedCount, 1)
        let operation = try XCTUnwrap(journal.operations().first)
        let record = journal.recordURL(operation.id)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        for key in ["sourceEvidence", "sourceSidecarEvidence", "hadSourceSidecar"] { json.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: json).write(to: record)
        XCTAssertNil(try journal.operations().first?.hadSourceSidecar)
        try FileManager.default.removeItem(at: source)
        let recovered = await service().recoverInterruptedImports()
        XCTAssertEqual(recovered.failedCount, 0)
        XCTAssertEqual(recovered.createdItemIds, [operation.itemID])
        XCTAssertEqual(try Data(contentsOf: operation.metadataURL), Data(try legacyContent(operation).utf8))
    }

    func testOldJournalWithoutSourceEvidenceRetriesWithLegacyGeneratedSidecar() async throws {
        try "---\n\(header)\n---\nOriginal body".write(to: sidecar, atomically: true, encoding: .utf8)
        let result = try await service(checkpoint: { phase in
            if phase == .staged { throw CocoaError(.fileWriteOutOfSpace) }
        }).importFiles([source])
        XCTAssertEqual(result.failedCount, 1)
        let operation = try XCTUnwrap(journal.operations().first)
        let record = journal.recordURL(operation.id)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        for key in ["sourceEvidence", "sourceSidecarEvidence", "hadSourceSidecar", "sidecarEvidence"] {
            json.removeValue(forKey: key)
        }
        try JSONSerialization.data(withJSONObject: json).write(to: record)
        try FileManager.default.removeItem(at: journal.stagedSidecar(operation))
        try "---\nsource: https://example.com/changed\ntitle: newer\n---\nNewer body"
            .write(to: sidecar, atomically: true, encoding: .utf8)
        let retried = try await service().importFiles([source])
        XCTAssertEqual(retried.failedCount, 0)
        XCTAssertEqual(retried.createdItemIds, [operation.itemID])
        XCTAssertEqual(try Data(contentsOf: operation.metadataURL), Data(try legacyContent(operation).utf8))
    }
}
