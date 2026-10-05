import XCTest
import GRDB
@testable import MediaViewer

final class SidecarParseFailureTests: XCTestCase {
    private var tempDirectory: URL!
    private var database: DatabaseManager!

    override func setUp() async throws {
        try await super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarParseFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        database = DatabaseManager(databaseURL: tempDirectory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
    }

    override func tearDown() async throws {
        database = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try await super.tearDown()
    }

    func testMigration34CreatesPersistentFailureTable() async throws {
        let migrationAndTable = try await database.read { db in
            let migrationExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM schema_migrations WHERE version = 34)"
            ) ?? false
            return (migrationExists, try db.tableExists(SidecarParseFailure.databaseTableName))
        }

        XCTAssertTrue(migrationAndTable.0)
        XCTAssertTrue(migrationAndTable.1)
    }

    func testUnchangedFailureMatchesAndExplicitRetryIncrementsCount() async throws {
        let sidecar = try makeSidecar(named: "malformed.md", content: malformedYAML)
        let identity = try XCTUnwrap(MetadataParser.sidecarIdentity(fileAt: sidecar))
        let candidate = SidecarParseFailureCandidate(
            identity: identity,
            parseError: "YAML parse error: unexpected end"
        )

        try await database.applySidecarParseResults(
            successfulCanonicalPaths: [],
            failures: [candidate]
        )

        var failures = try await database.fetchSidecarParseFailures()
        var failure = try XCTUnwrap(failures.first)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failure.matches(identity))
        XCTAssertEqual(failure.fileURL.path, identity.canonicalPath)
        XCTAssertEqual(failure.fileName, "malformed.md")
        XCTAssertEqual(failure.parentDirectoryURL.path, SidecarFileIdentity.canonicalPath(for: tempDirectory))
        XCTAssertEqual(failure.parseError, candidate.parseError)
        XCTAssertEqual(failure.failureCount, 1)

        let firstFailedAt = failure.firstFailedAt
        try await database.applySidecarParseResults(
            successfulCanonicalPaths: [],
            failures: [candidate]
        )

        failures = try await database.fetchSidecarParseFailures()
        failure = try XCTUnwrap(failures.first)
        XCTAssertEqual(failure.failureCount, 2)
        XCTAssertEqual(failure.firstFailedAt, firstFailedAt)
        XCTAssertGreaterThanOrEqual(failure.lastFailedAt, firstFailedAt)
    }

    func testChangedFileDoesNotMatchAndSuccessfulRetryClearsFailure() async throws {
        let sidecar = try makeSidecar(named: "repairable.md", content: malformedYAML)
        let failedIdentity = try XCTUnwrap(MetadataParser.sidecarIdentity(fileAt: sidecar))
        try await database.applySidecarParseResults(
            successfulCanonicalPaths: [],
            failures: [SidecarParseFailureCandidate(identity: failedIdentity, parseError: "Invalid YAML")]
        )

        try validYAML.write(to: sidecar, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: failedIdentity.fingerprint.modifiedAt + 5)],
            ofItemAtPath: sidecar.path
        )

        let changedIdentity = try XCTUnwrap(MetadataParser.sidecarIdentity(fileAt: sidecar))
        let cachedFailures = try await database.fetchSidecarParseFailures()
        let cachedFailure = try XCTUnwrap(cachedFailures.first)
        XCTAssertFalse(cachedFailure.matches(changedIdentity))
        XCTAssertNoThrow(try MetadataParser.parse(fileAt: sidecar))

        try await database.applySidecarParseResults(
            successfulCanonicalPaths: [changedIdentity.canonicalPath],
            failures: []
        )
        let remainingFailures = try await database.fetchSidecarParseFailures()
        XCTAssertTrue(remainingFailures.isEmpty)
    }

    func testChangedFileFailureReplacesGenerationAndResetsCount() async throws {
        let sidecar = try makeSidecar(named: "still-bad.md", content: malformedYAML)
        let originalIdentity = try XCTUnwrap(MetadataParser.sidecarIdentity(fileAt: sidecar))
        let originalCandidate = SidecarParseFailureCandidate(identity: originalIdentity, parseError: "First error")
        try await database.applySidecarParseResults(successfulCanonicalPaths: [], failures: [originalCandidate])
        try await database.applySidecarParseResults(successfulCanonicalPaths: [], failures: [originalCandidate])

        let changedMalformedYAML = "---\nsource: [still, malformed\n---\n"
        try changedMalformedYAML.write(to: sidecar, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: originalIdentity.fingerprint.modifiedAt + 5)],
            ofItemAtPath: sidecar.path
        )
        let changedIdentity = try XCTUnwrap(MetadataParser.sidecarIdentity(fileAt: sidecar))
        let changedCandidate = SidecarParseFailureCandidate(identity: changedIdentity, parseError: "Second error")

        try await database.applySidecarParseResults(successfulCanonicalPaths: [], failures: [changedCandidate])

        let failures = try await database.fetchSidecarParseFailures()
        let failure = try XCTUnwrap(failures.first)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failure.matches(changedIdentity))
        XCTAssertEqual(failure.parseError, "Second error")
        XCTAssertEqual(failure.failureCount, 1)
    }

    func testPruneRemovesMissingSidecarsOnly() async throws {
        let retainedSidecar = try makeSidecar(named: "retained.md", content: malformedYAML)
        let removedSidecar = try makeSidecar(named: "removed.md", content: malformedYAML)
        let retainedIdentity = try XCTUnwrap(MetadataParser.sidecarIdentity(fileAt: retainedSidecar))
        let removedIdentity = try XCTUnwrap(MetadataParser.sidecarIdentity(fileAt: removedSidecar))

        try await database.applySidecarParseResults(
            successfulCanonicalPaths: [],
            failures: [
                SidecarParseFailureCandidate(identity: retainedIdentity, parseError: "Retained"),
                SidecarParseFailureCandidate(identity: removedIdentity, parseError: "Removed")
            ]
        )
        try FileManager.default.removeItem(at: removedSidecar)

        let prunedCount = try await database.pruneSidecarParseFailures(
            keepingCanonicalPaths: [retainedIdentity.canonicalPath]
        )
        let failures = try await database.fetchSidecarParseFailures()

        XCTAssertEqual(prunedCount, 1)
        XCTAssertEqual(failures.map(\.canonicalPath), [retainedIdentity.canonicalPath])
    }

    func testIdentityCanonicalizesSymlinkAndParserDoesNotRewriteMalformedFile() throws {
        let sidecar = try makeSidecar(named: "source.md", content: malformedYAML)
        let alias = tempDirectory.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sidecar)
        let originalData = try Data(contentsOf: sidecar)

        let identity = try XCTUnwrap(MetadataParser.sidecarIdentity(fileAt: alias))
        XCTAssertEqual(identity.canonicalPath, SidecarFileIdentity.canonicalPath(for: sidecar))
        XCTAssertThrowsError(try MetadataParser.parse(fileAt: alias))
        XCTAssertEqual(try Data(contentsOf: sidecar), originalData)
    }

    private var malformedYAML: String {
        "---\nsource: [unterminated\n---\n"
    }

    private var validYAML: String {
        "---\nsource: https://example.com/repaired\narchived: 2026-09-03\n---\n"
    }

    private func makeSidecar(named name: String, content: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
