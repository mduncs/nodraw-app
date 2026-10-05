import Foundation
import GRDB

/// A stable snapshot of a sidecar at the point where it is considered for parsing.
/// The canonical path prevents aliases and symlinks from creating duplicate failure rows.
struct SidecarFileIdentity: Equatable, Sendable {
    let canonicalPath: String
    let fingerprint: MetadataFileFingerprint

    static func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    static func current(
        for url: URL,
        fileManager: FileManager = .default
    ) -> SidecarFileIdentity? {
        guard let fingerprint = MetadataFileFingerprint.current(for: url, fileManager: fileManager) else {
            return nil
        }

        return SidecarFileIdentity(
            canonicalPath: canonicalPath(for: url),
            fingerprint: fingerprint
        )
    }
}

/// Query model for a sidecar that failed strict metadata parsing.
///
/// This deliberately stores diagnostics only. It never rewrites or repairs the source file,
/// and exposes the original file URL so a future Issues surface can reveal it in Finder.
struct SidecarParseFailure: FetchableRecord, Equatable, Identifiable, Sendable {
    static let databaseTableName = "sidecar_parse_failures"

    let canonicalPath: String
    let metadataFileModifiedAt: Double
    let metadataFileSize: Int64
    let parseError: String
    let firstFailedAt: Date
    let lastFailedAt: Date
    let failureCount: Int

    var id: String { canonicalPath }
    var fileURL: URL { URL(fileURLWithPath: canonicalPath) }
    var fileName: String { fileURL.lastPathComponent }
    var parentDirectoryURL: URL { fileURL.deletingLastPathComponent() }

    init(row: Row) throws {
        canonicalPath = row["canonicalPath"]
        metadataFileModifiedAt = row["metadataFileModifiedAt"]
        metadataFileSize = row["metadataFileSize"]
        parseError = row["parseError"]
        firstFailedAt = Date(timeIntervalSince1970: row["firstFailedAt"])
        lastFailedAt = Date(timeIntervalSince1970: row["lastFailedAt"])
        failureCount = row["failureCount"]
    }

    func matches(_ identity: SidecarFileIdentity) -> Bool {
        canonicalPath == identity.canonicalPath &&
            metadataFileModifiedAt == identity.fingerprint.modifiedAt &&
            metadataFileSize == identity.fingerprint.fileSize
    }

    static func createTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS sidecar_parse_failures (
                canonicalPath TEXT PRIMARY KEY,
                metadataFileModifiedAt REAL NOT NULL,
                metadataFileSize INTEGER NOT NULL,
                parseError TEXT NOT NULL,
                firstFailedAt REAL NOT NULL,
                lastFailedAt REAL NOT NULL,
                failureCount INTEGER NOT NULL DEFAULT 1
            )
        """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_sidecar_parse_failures_last_failed
            ON sidecar_parse_failures(lastFailedAt DESC)
        """)
    }
}

struct SidecarParseFailureCandidate: Equatable, Sendable {
    let identity: SidecarFileIdentity
    let parseError: String

    init(identity: SidecarFileIdentity, parseError: String) {
        self.identity = identity
        let normalizedError = parseError.trimmingCharacters(in: .whitespacesAndNewlines)
        self.parseError = normalizedError.isEmpty ? "Unknown metadata parse error" : normalizedError
    }
}

extension DatabaseManager {
    /// Returns issue-ready failure details, newest failure first.
    func fetchSidecarParseFailures() async throws -> [SidecarParseFailure] {
        try await read { db in
            try SidecarParseFailure.fetchAll(
                db,
                sql: """
                    SELECT canonicalPath, metadataFileModifiedAt, metadataFileSize,
                           parseError, firstFailedAt, lastFailedAt, failureCount
                    FROM sidecar_parse_failures
                    ORDER BY lastFailedAt DESC, canonicalPath ASC
                """
            )
        }
    }

    /// Applies the outcomes of a scan in one transaction. Successful retries clear an old
    /// negative-cache entry; failures replace it when the file changed and increment it when
    /// the exact same file generation was explicitly retried.
    func applySidecarParseResults(
        successfulCanonicalPaths: Set<String>,
        failures: [SidecarParseFailureCandidate]
    ) async throws {
        guard !successfulCanonicalPaths.isEmpty || !failures.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        try await write { db in
            for canonicalPath in successfulCanonicalPaths {
                try db.execute(
                    sql: "DELETE FROM sidecar_parse_failures WHERE canonicalPath = ?",
                    arguments: [canonicalPath]
                )
            }

            for failure in failures {
                try db.execute(
                    sql: """
                        INSERT INTO sidecar_parse_failures (
                            canonicalPath, metadataFileModifiedAt, metadataFileSize,
                            parseError, firstFailedAt, lastFailedAt, failureCount
                        )
                        VALUES (?, ?, ?, ?, ?, ?, 1)
                        ON CONFLICT(canonicalPath) DO UPDATE SET
                            firstFailedAt = CASE
                                WHEN metadataFileModifiedAt = excluded.metadataFileModifiedAt
                                 AND metadataFileSize = excluded.metadataFileSize
                                 AND parseError = excluded.parseError
                                THEN firstFailedAt
                                ELSE excluded.firstFailedAt
                            END,
                            failureCount = CASE
                                WHEN metadataFileModifiedAt = excluded.metadataFileModifiedAt
                                 AND metadataFileSize = excluded.metadataFileSize
                                 AND parseError = excluded.parseError
                                THEN failureCount + 1
                                ELSE 1
                            END,
                            metadataFileModifiedAt = excluded.metadataFileModifiedAt,
                            metadataFileSize = excluded.metadataFileSize,
                            parseError = excluded.parseError,
                            lastFailedAt = excluded.lastFailedAt
                    """,
                    arguments: [
                        failure.identity.canonicalPath,
                        failure.identity.fingerprint.modifiedAt,
                        failure.identity.fingerprint.fileSize,
                        failure.parseError,
                        now,
                        now
                    ]
                )
            }
        }
    }

    /// Removes failures for sidecars no longer present in the current archive scan.
    @discardableResult
    func pruneSidecarParseFailures(keepingCanonicalPaths existingPaths: Set<String>) async throws -> Int {
        try await write { db in
            let cachedPaths = try String.fetchAll(
                db,
                sql: "SELECT canonicalPath FROM sidecar_parse_failures"
            )
            var prunedCount = 0

            for canonicalPath in cachedPaths where !existingPaths.contains(canonicalPath) {
                try db.execute(
                    sql: "DELETE FROM sidecar_parse_failures WHERE canonicalPath = ?",
                    arguments: [canonicalPath]
                )
                prunedCount += db.changesCount
            }

            return prunedCount
        }
    }
}
