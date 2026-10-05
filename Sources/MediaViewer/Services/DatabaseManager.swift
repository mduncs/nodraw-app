import Foundation
import GRDB
import PhotoPipeline

// MARK: - App Paths (single source of truth)

/// Shared directory paths with one canonical app-data root.
/// Consolidates legacy directories and creates compatibility aliases.
enum AppPaths {
    private static let canonicalDirectoryName = "NoDraw"
    private static let legacyDirectoryNames = [
        "MediaViewer",
        "com.nodraw.app",
        "media-viewer",
        "com.mediaviewer"
    ]

    static let appDataDirectory: URL = {
        let started = StartupMetrics.begin()
        defer { StartupMetrics.end("app_paths", since: started, once: true) }
        return resolveAppDataDirectory()
    }()

    static let thumbnailsDirectory: URL = {
        let dir = appDataDirectory.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let databaseURL: URL = {
        appDataDirectory.appendingPathComponent("media.sqlite")
    }()

    static let binDirectory: URL = {
        let dir = appDataDirectory.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let downloadServerDirectory: URL = {
        let dir = appDataDirectory.appendingPathComponent("download-server", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private struct DirectorySnapshot {
        let url: URL
        let dbBytes: Int64
        let walBytes: Int64
        let newestDate: Date
        let meaningfulEntryCount: Int

        var totalDatabaseBytes: Int64 { dbBytes + walBytes }
        var hasDatabase: Bool { totalDatabaseBytes > 0 }
        var hasMeaningfulData: Bool { hasDatabase || meaningfulEntryCount > 0 }
    }

    private static func resolveAppDataDirectory() -> URL {
        let fm = FileManager.default

        let env = ProcessInfo.processInfo.environment
        if let override = (env["NODRAW_APP_SUPPORT_DIR"] ?? env["MEDIAVIEWER_APP_SUPPORT_DIR"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let overrideURL = URL(fileURLWithPath: override).standardizedFileURL
            try? fm.createDirectory(at: overrideURL, withIntermediateDirectories: true)
            return overrideURL
        }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)

        let canonical = appSupport.appendingPathComponent(canonicalDirectoryName, isDirectory: true)
        try? fm.createDirectory(at: canonical, withIntermediateDirectories: true)

        let candidateNames = directoryCandidates()
        let candidateDirs = candidateNames.map { appSupport.appendingPathComponent($0, isDirectory: true) }

        consolidateDirectories(canonical: canonical, candidates: candidateDirs)
        return canonical
    }

    private static func directoryCandidates() -> [String] {
        var names = [canonicalDirectoryName]
        names.append(contentsOf: legacyDirectoryNames)
        if let bundleID = Bundle.main.bundleIdentifier { names.append(bundleID) }
        if let bundleName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String { names.append(bundleName) }

        var seen = Set<String>()
        return names.compactMap { rawName in
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !seen.contains(name) else { return nil }
            seen.insert(name)
            return name
        }
    }

    private static func consolidateDirectories(canonical: URL, candidates: [URL]) {
        let nonSymlinkCandidates = candidates.filter { candidate in
            directoryExists(candidate) && !isSymbolicLink(candidate)
        }

        let snapshots = nonSymlinkCandidates.compactMap(snapshot(for:))
        let canonicalSnapshot = snapshot(for: canonical)

        if let preferred = preferredSnapshot(from: snapshots),
           preferred.url.standardizedFileURL != canonical.standardizedFileURL {
            if !(canonicalSnapshot?.hasMeaningfulData ?? false) {
                migratePreferredDirectory(preferred.url, to: canonical)
            } else if let canonicalSnapshot, isPreferred(preferred, over: canonicalSnapshot) {
                mergeContents(from: preferred.url, into: canonical)
            }
        }

        for legacy in candidates where legacy.standardizedFileURL != canonical.standardizedFileURL {
            aliasLegacyDirectory(legacy, canonical: canonical)
        }
    }

    private static func preferredSnapshot(from snapshots: [DirectorySnapshot]) -> DirectorySnapshot? {
        snapshots.max { lhs, rhs in
            !isPreferred(lhs, over: rhs)
        }
    }

    private static func isPreferred(_ lhs: DirectorySnapshot, over rhs: DirectorySnapshot) -> Bool {
        if lhs.hasDatabase != rhs.hasDatabase {
            return lhs.hasDatabase
        }
        if lhs.totalDatabaseBytes != rhs.totalDatabaseBytes {
            return lhs.totalDatabaseBytes > rhs.totalDatabaseBytes
        }
        if lhs.newestDate != rhs.newestDate {
            return lhs.newestDate > rhs.newestDate
        }
        if lhs.meaningfulEntryCount != rhs.meaningfulEntryCount {
            return lhs.meaningfulEntryCount > rhs.meaningfulEntryCount
        }
        return lhs.url.lastPathComponent < rhs.url.lastPathComponent
    }

    private static func migratePreferredDirectory(_ source: URL, to canonical: URL) {
        let fm = FileManager.default

        if isTriviallyEmptyDirectory(canonical) {
            do {
                try fm.removeItem(at: canonical)
                try fm.moveItem(at: source, to: canonical)
                logInfo("AppPaths: migrated app data from \(source.lastPathComponent) to \(canonical.lastPathComponent)")
                return
            } catch {
                logWarning("AppPaths: move migration failed (\(error)); falling back to merge copy")
                try? fm.createDirectory(at: canonical, withIntermediateDirectories: true)
            }
        }

        mergeContents(from: source, into: canonical)
    }

    private static func mergeContents(from source: URL, into destination: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else {
            return
        }

        for case let sourceURL as URL in enumerator {
            let relativePath = sourceURL.path.replacingOccurrences(of: source.path + "/", with: "")
            guard !relativePath.isEmpty else { continue }

            let destinationURL = destination.appendingPathComponent(relativePath, isDirectory: false)
            let values = try? sourceURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])

            if values?.isDirectory == true {
                try? fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                continue
            }

            if values?.isSymbolicLink == true {
                guard !fm.fileExists(atPath: destinationURL.path),
                      let linkDestination = try? fm.destinationOfSymbolicLink(atPath: sourceURL.path) else {
                    continue
                }
                try? fm.createSymbolicLink(atPath: destinationURL.path, withDestinationPath: linkDestination)
                continue
            }

            guard values?.isRegularFile == true else { continue }

            let destinationParent = destinationURL.deletingLastPathComponent()
            try? fm.createDirectory(at: destinationParent, withIntermediateDirectories: true)

            if !fm.fileExists(atPath: destinationURL.path) {
                try? fm.copyItem(at: sourceURL, to: destinationURL)
                continue
            }

            if shouldReplace(destinationFile: destinationURL, with: sourceURL) {
                try? fm.removeItem(at: destinationURL)
                try? fm.copyItem(at: sourceURL, to: destinationURL)
            }
        }

        logInfo("AppPaths: merged app data from \(source.lastPathComponent) into \(destination.lastPathComponent)")
    }

    private static func shouldReplace(destinationFile: URL, with sourceFile: URL) -> Bool {
        let sourceSize = fileSize(at: sourceFile)
        let destinationSize = fileSize(at: destinationFile)
        if sourceSize != destinationSize {
            return sourceSize > destinationSize
        }
        return modificationDate(at: sourceFile) > modificationDate(at: destinationFile)
    }

    private static func aliasLegacyDirectory(_ legacy: URL, canonical: URL) {
        let fm = FileManager.default

        if isSymbolicLink(legacy) {
            if legacy.resolvingSymlinksInPath().standardizedFileURL == canonical.standardizedFileURL {
                return
            }
            try? fm.removeItem(at: legacy)
        } else if directoryExists(legacy) {
            if hasMeaningfulData(in: legacy) {
                let backup = backupURL(for: legacy)
                do {
                    try fm.moveItem(at: legacy, to: backup)
                    logInfo("AppPaths: preserved legacy directory at \(backup.path)")
                } catch {
                    logWarning("AppPaths: failed to preserve \(legacy.lastPathComponent): \(error)")
                    return
                }
            } else {
                try? fm.removeItem(at: legacy)
            }
        } else if fm.fileExists(atPath: legacy.path) {
            try? fm.removeItem(at: legacy)
        }

        do {
            try fm.createSymbolicLink(at: legacy, withDestinationURL: canonical)
            logInfo("AppPaths: aliased \(legacy.lastPathComponent) -> \(canonical.lastPathComponent)")
        } catch {
            logWarning("AppPaths: failed to alias \(legacy.lastPathComponent): \(error)")
        }
    }

    private static func backupURL(for directory: URL) -> URL {
        let parent = directory.deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())

        var backup = parent.appendingPathComponent("\(directory.lastPathComponent).legacy-\(timestamp)", isDirectory: true)
        var suffix = 1
        let fm = FileManager.default
        while fm.fileExists(atPath: backup.path) {
            backup = parent.appendingPathComponent("\(directory.lastPathComponent).legacy-\(timestamp)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return backup
    }

    private static func snapshot(for directory: URL) -> DirectorySnapshot? {
        guard directoryExists(directory) else { return nil }

        let dbURL = directory.appendingPathComponent("media.sqlite")
        let walURL = directory.appendingPathComponent("media.sqlite-wal")

        let dbBytes = fileSize(at: dbURL)
        let walBytes = fileSize(at: walURL)
        let newestDate = [
            modificationDate(at: directory),
            modificationDate(at: dbURL),
            modificationDate(at: walURL)
        ].max() ?? .distantPast

        return DirectorySnapshot(
            url: directory,
            dbBytes: dbBytes,
            walBytes: walBytes,
            newestDate: newestDate,
            meaningfulEntryCount: meaningfulEntryCount(in: directory)
        )
    }

    private static func meaningfulEntryCount(in directory: URL) -> Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return 0
        }
        return contents.filter { $0.lastPathComponent != ".lock" }.count
    }

    private static func hasMeaningfulData(in directory: URL) -> Bool {
        guard let snap = snapshot(for: directory) else { return false }
        return snap.hasMeaningfulData
    }

    private static func isTriviallyEmptyDirectory(_ directory: URL) -> Bool {
        !hasMeaningfulData(in: directory)
    }

    private static func directoryExists(_ directory: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    private static func fileSize(at fileURL: URL) -> Int64 {
        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else { return 0 }
        return Int64(size)
    }

    private static func modificationDate(at url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

// MARK: - DatabaseManager

/// Actor-based database manager providing thread-safe access to SQLite via GRDB.
/// Initializes the database pool and runs migrations at app launch.
actor DatabaseManager {
    /// Shared instance for app-wide database access
    static var shared = DatabaseManager()

    /// The database pool for concurrent read access
    private var pool: DatabasePool?
    private var initializationWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    /// Database file location
    private let databaseURL: URL

    private init() {
        self.databaseURL = AppPaths.databaseURL
    }

    /// Create a DatabaseManager with a custom database path (for test isolation)
    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    // MARK: - Initialization

    /// Initialize the database pool and run migrations.
    /// Call this at app launch before any database operations.
    func initialize() async throws {
        guard pool == nil else { return }
        let started = StartupMetrics.begin()
        defer { StartupMetrics.end("database_open_and_migrations", since: started, once: true) }

        var config = Configuration()
        config.prepareDatabase { db in
            // Enable foreign keys
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            PerceptualColorMetric.install(in: db)
        }

        // Use WAL mode for better concurrent read performance
        let pool = try DatabasePool(path: databaseURL.path, configuration: config)

        try await pool.write { db in
            let migrations = StartupMetrics.begin()
            defer { StartupMetrics.end("migrations", since: migrations, once: true) }
            try self.runMigrations(db)
        }

        self.pool = pool
        let waiters = Array(initializationWaiters.values)
        initializationWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: true) }
    }

    var isInitialized: Bool { pool != nil }

    /// Background workers wait for successful migrations, including a later retry
    /// if initialization fails. Canceled workers release their waiters.
    func waitUntilInitialized() async -> Bool {
        guard pool == nil else { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    initializationWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelInitializationWaiter(id) }
        }
    }

    private func cancelInitializationWaiter(_ id: UUID) {
        initializationWaiters.removeValue(forKey: id)?.resume(returning: false)
    }

    // MARK: - Migrations

    private nonisolated func runMigrations(_ db: Database) throws {
        // Create version tracking table
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
        """)

        let currentVersion = try Int.fetchOne(db, sql: "SELECT MAX(version) FROM schema_migrations") ?? 0
        CrashTelemetry.leave("db-migrate from=\(currentVersion)")

        // Migration 1: Initial schema
        if currentVersion < 1 {
            try MediaItemRecord.createTable(in: db)
            try SmartFolder.createTable(in: db)
            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (1)")
        }

        // Migration 2: Add parse status and date debugging columns (idempotent)
        if currentVersion < 2 {
            // Check if columns exist before adding (for idempotency)
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_items)")
            let existingColumns = Set(columns.compactMap { $0["name"] as? String })

            if !existingColumns.contains("originalDateString") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN originalDateString TEXT")
            }
            if !existingColumns.contains("parseStatus") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN parseStatus TEXT NOT NULL DEFAULT 'success'")
            }
            if !existingColumns.contains("parseErrorsJSON") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN parseErrorsJSON TEXT")
            }

            // Add index (ifNotExists handles idempotency)
            try db.create(
                index: "idx_media_items_parseStatus",
                on: "media_items",
                columns: ["parseStatus"],
                ifNotExists: true
            )

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (2)")
        }

        // Migration 3: Add OCR bounding boxes column for text region highlighting
        if currentVersion < 3 {
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_items)")
            let existingColumns = Set(columns.compactMap { $0["name"] as? String })

            if !existingColumns.contains("ocrBoundingBoxesJSON") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN ocrBoundingBoxesJSON TEXT")
            }

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (3)")
        }

        // Migration 4: Add media_tags junction table for fast tag filtering
        if currentVersion < 4 {
            // Create junction table
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS media_tags (
                    item_id TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    PRIMARY KEY (item_id, tag),
                    FOREIGN KEY (item_id) REFERENCES media_items(id) ON DELETE CASCADE
                )
            """)

            // Index for fast tag lookups
            try db.create(
                index: "idx_media_tags_tag",
                on: "media_tags",
                columns: ["tag"],
                ifNotExists: true
            )

            // Populate from existing tagsJSON data
            let rows = try Row.fetchAll(db, sql: "SELECT id, tagsJSON FROM media_items WHERE tagsJSON != '[]'")
            for row in rows {
                let itemId: String = row["id"]
                let tagsJSON: String = row["tagsJSON"]
                if let tags = try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8)) {
                    for tag in tags {
                        let normalizedTag = TagCanonicalizer.key(tag)
                        guard !normalizedTag.isEmpty else { continue }
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO media_tags (item_id, tag) VALUES (?, ?)",
                            arguments: [itemId, normalizedTag]
                        )
                    }
                }
            }

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (4)")
        }

        // Migration 5: Add per-file OCR storage for carousel/multi-image support
        if currentVersion < 5 {
            // Create per-file OCR table
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS media_file_ocr (
                    id TEXT PRIMARY KEY,
                    item_id TEXT NOT NULL,
                    file_url TEXT NOT NULL,
                    file_index INTEGER NOT NULL,
                    ocr_text TEXT,
                    ocr_regions_json TEXT,
                    FOREIGN KEY (item_id) REFERENCES media_items(id) ON DELETE CASCADE,
                    UNIQUE(item_id, file_index)
                )
            """)

            // Index for fast lookups by item
            try db.create(
                index: "idx_media_file_ocr_item",
                on: "media_file_ocr",
                columns: ["item_id"],
                ifNotExists: true
            )

            // Migrate existing OCR data from media_items to media_file_ocr
            // Treat existing OCR as belonging to file_index 0
            let itemsWithOCR = try Row.fetchAll(db, sql: """
                SELECT id, mediaFilesJSON, ocrText, ocrBoundingBoxesJSON
                FROM media_items
                WHERE ocrText IS NOT NULL OR ocrBoundingBoxesJSON IS NOT NULL
            """)

            for row in itemsWithOCR {
                let itemId: String = row["id"]
                let mediaFilesJSON: String = row["mediaFilesJSON"]
                let ocrText: String? = row["ocrText"]
                let ocrBoundingBoxesJSON: String? = row["ocrBoundingBoxesJSON"]

                // Get first media file URL
                var firstFileURL = ""
                if let paths = try? JSONDecoder().decode([String].self, from: Data(mediaFilesJSON.utf8)),
                   let first = paths.first {
                    firstFileURL = first
                }

                let ocrId = UUID().uuidString
                try db.execute(
                    sql: """
                        INSERT INTO media_file_ocr (id, item_id, file_url, file_index, ocr_text, ocr_regions_json)
                        VALUES (?, ?, ?, 0, ?, ?)
                    """,
                    arguments: [ocrId, itemId, firstFileURL, ocrText, ocrBoundingBoxesJSON]
                )
            }

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (5)")
        }

        // Migration 6: Add index on originalDate for smart folder date range queries
        if currentVersion < 6 {
            try db.create(
                index: "idx_media_items_originalDate",
                on: "media_items",
                columns: ["originalDate"],
                ifNotExists: true
            )
            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (6)")
            logInfo("Migration 6 complete: Added originalDate index")
        }

        // Migration 7: Normalize color data to junction table for fast filtering
        if currentVersion < 7 {
            // Create junction table
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS media_colors (
                    item_id TEXT NOT NULL,
                    color_bucket TEXT NOT NULL,
                    PRIMARY KEY (item_id, color_bucket),
                    FOREIGN KEY (item_id) REFERENCES media_items(id) ON DELETE CASCADE
                )
            """)

            // Create index for color lookups
            try db.create(
                index: "idx_media_colors_bucket",
                on: "media_colors",
                columns: ["color_bucket"],
                ifNotExists: true
            )

            // Populate from existing JSON data
            let rows = try Row.fetchAll(db, sql: "SELECT id, dominantColorsJSON FROM media_items WHERE dominantColorsJSON IS NOT NULL")
            for row in rows {
                let itemId: String = row["id"]
                if let json: String = row["dominantColorsJSON"],
                   let data = json.data(using: .utf8),
                   let colors = try? JSONDecoder().decode([String].self, from: data) {
                    for color in colors {
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO media_colors (item_id, color_bucket) VALUES (?, ?)",
                            arguments: [itemId, color]
                        )
                    }
                }
            }

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (7)")
            logInfo("Migration 7 complete: Normalized color data")
        }

        // Migration 8: Add deletedAt column for soft delete
        if currentVersion < 8 {
            // Check if column exists (idempotent)
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_items)")
            let existingColumns = Set(columns.compactMap { $0["name"] as? String })

            if !existingColumns.contains("deletedAt") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN deletedAt DATETIME")
            }

            try db.create(
                index: "idx_media_items_deletedAt",
                on: "media_items",
                columns: ["deletedAt"],
                ifNotExists: true
            )

            try db.execute(sql: "INSERT OR REPLACE INTO schema_migrations (version) VALUES (8)")
            logInfo("Migration 8 complete: Added deletedAt column")
        }

        // Migration 9: Fix NULL ocrText for items that have been processed
        // Items with perceptualHash or dominantColorsJSON set have been through Vision processing
        // but may have NULL ocrText if no text was found. Change to empty string to prevent
        // infinite reprocessing (requeueIncomplete checks for NULL).
        if currentVersion < 9 {
            try db.execute(sql: """
                UPDATE media_items
                SET ocrText = ''
                WHERE ocrText IS NULL
                AND (perceptualHash IS NOT NULL OR dominantColorsJSON IS NOT NULL)
            """)
            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (9)")
            logInfo("Migration 9 complete: Fixed \(db.changesCount) items with NULL ocrText")
        }

        // Migration 10: Aggregate per-file OCR into media_items.ocrText for full-text search
        // Per-file OCR (from carousel images 2, 3, 4+) is stored in media_file_ocr but wasn't
        // being indexed in FTS5. This aggregates all per-file OCR into the main ocrText column.
        if currentVersion < 10 {
            // Aggregate per-file OCR into main ocrText column
            try db.execute(sql: """
                UPDATE media_items
                SET ocrText = (
                    SELECT GROUP_CONCAT(ocr_text, char(10) || char(10) || '---' || char(10) || char(10))
                    FROM media_file_ocr
                    WHERE media_file_ocr.item_id = media_items.id
                      AND ocr_text IS NOT NULL
                      AND ocr_text != ''
                    ORDER BY file_index
                )
                WHERE id IN (SELECT DISTINCT item_id FROM media_file_ocr WHERE ocr_text IS NOT NULL AND ocr_text != '')
            """)

            // Rebuild FTS index with aggregated data
            try MediaItemRecord.rebuildFTSIndex(db: db)

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (10)")
            logInfo("Migration 10 complete: Aggregated per-file OCR for search")
        }

        // Migration 11: Add feature_vectors table for semantic clustering
        // Stores normalized Float16 vectors (4KB/item) in separate table to avoid
        // paging through large BLOBs on every media_items query.
        if currentVersion < 11 {
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS feature_vectors (
                    itemId TEXT PRIMARY KEY REFERENCES media_items(id) ON DELETE CASCADE,
                    vectorData BLOB NOT NULL,
                    extractedAt DATETIME NOT NULL
                )
            """)

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (11)")
            logInfo("Migration 11 complete: Added feature_vectors table")
        }

        // Migration 12: Add collection_boards and board_memberships tables
        // Pinterest-style manual curation boards for organizing media items.
        if currentVersion < 12 {
            try CollectionBoard.createTable(in: db)
            try BoardMembership.createTable(in: db)

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (12)")
            logInfo("Migration 12 complete: Added collection boards tables")
        }

        // Migration 13: Add item_clusters and cluster_centroids tables for semantic clustering
        // Enables visual similarity search and automatic grouping of similar images.
        if currentVersion < 13 {
            // Item-to-cluster assignments
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS item_clusters (
                    itemId TEXT PRIMARY KEY,
                    clusterId INTEGER NOT NULL,
                    clusterVersion INTEGER NOT NULL,
                    similarity REAL,
                    FOREIGN KEY (itemId) REFERENCES media_items(id) ON DELETE CASCADE
                )
            """)

            // Index for fast cluster lookups
            try db.create(
                index: "idx_item_clusters_clusterId",
                on: "item_clusters",
                columns: ["clusterId"],
                ifNotExists: true
            )

            // Cluster centroids for similarity computation
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS cluster_centroids (
                    id INTEGER PRIMARY KEY,
                    version INTEGER NOT NULL,
                    centroid BLOB NOT NULL,
                    itemCount INTEGER NOT NULL
                )
            """)

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (13)")
            logInfo("Migration 13 complete: Added clustering tables")
        }

        // Migration 14: Add FSRS spaced repetition tables for Rediscover feature
        // Tracks review state and view events for surfacing "forgotten" items.
        if currentVersion < 14 {
            try ReviewStateRecord.createTable(in: db)
            try ViewEventRecord.createTable(in: db)

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (14)")
            logInfo("Migration 14 complete: Added FSRS spaced repetition tables")
        }

        // Migration 15: Add duplicate detection tables
        // Stores groups of similar/duplicate items detected by perceptual hash or feature vectors.
        if currentVersion < 15 {
            // Duplicate groups table
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS duplicate_groups (
                    id TEXT PRIMARY KEY,
                    primaryItemId TEXT,
                    status TEXT NOT NULL DEFAULT 'pending',
                    detectionMethod TEXT NOT NULL,
                    similarity REAL NOT NULL,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL,
                    FOREIGN KEY (primaryItemId) REFERENCES media_items(id) ON DELETE SET NULL
                )
            """)

            // Index for fast status filtering
            try db.create(
                index: "idx_duplicate_groups_status",
                on: "duplicate_groups",
                columns: ["status"],
                ifNotExists: true
            )

            // Junction table for group members
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS duplicate_group_members (
                    groupId TEXT NOT NULL,
                    itemId TEXT NOT NULL,
                    isPrimary INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (groupId, itemId),
                    FOREIGN KEY (groupId) REFERENCES duplicate_groups(id) ON DELETE CASCADE,
                    FOREIGN KEY (itemId) REFERENCES media_items(id) ON DELETE CASCADE
                )
            """)

            // Index for fast item lookups
            try db.create(
                index: "idx_duplicate_group_members_itemId",
                on: "duplicate_group_members",
                columns: ["itemId"],
                ifNotExists: true
            )

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (15)")
            logInfo("Migration 15 complete: Added duplicate detection tables")
        }

        // Migration 16: Add canvas_documents and canvas_placements tables
        // PureRef-style infinite canvas for spatial arrangement of media items.
        if currentVersion < 16 {
            try CanvasDocument.createTable(in: db)
            try CanvasItemPlacement.createTable(in: db)

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (16)")
            logInfo("Migration 16 complete: Added infinite canvas tables")
        }

        // Migration 17: Add annotations table for non-destructive drawing overlay
        // Stores annotation shapes (rectangle, ellipse, arrow, freeform, text) with normalized coordinates.
        if currentVersion < 17 {
            try AnnotationRecord.createTable(in: db)

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (17)")
            logInfo("Migration 17 complete: Added annotations table")
        }

        // Migration 18: Add rotation column to canvas_item_placements (Issue #11)
        if currentVersion < 18 {
            // Check if table exists first (may not exist if user never created a canvas)
            let tableExists = try Row.fetchOne(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name='canvas_item_placements'
            """) != nil

            if tableExists {
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(canvas_item_placements)")
                let existingColumns = Set(columns.compactMap { $0["name"] as? String })

                if !existingColumns.contains("rotation") {
                    try db.execute(sql: "ALTER TABLE canvas_item_placements ADD COLUMN rotation REAL NOT NULL DEFAULT 0")
                }
            }
            // If table doesn't exist, the rotation column will be included when table is created

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (18)")
            logInfo("Migration 18 complete: Added rotation column to canvas placements")
        }

        // Migration 19: Add RGB columns to media_colors for precision color search
        // Stores actual RGB values (not just bucket classification) for color distance queries
        if currentVersion < 19 {
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_colors)")
            let existingColumns = Set(columns.compactMap { $0["name"] as? String })

            if !existingColumns.contains("rgb_r") {
                try db.execute(sql: "ALTER TABLE media_colors ADD COLUMN rgb_r INTEGER")
                try db.execute(sql: "ALTER TABLE media_colors ADD COLUMN rgb_g INTEGER")
                try db.execute(sql: "ALTER TABLE media_colors ADD COLUMN rgb_b INTEGER")
                try db.execute(sql: "ALTER TABLE media_colors ADD COLUMN prominence REAL")
            }

            // Create indexes for fast range queries on each RGB channel
            try db.create(
                index: "idx_media_colors_rgb_r",
                on: "media_colors",
                columns: ["rgb_r"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_media_colors_rgb_g",
                on: "media_colors",
                columns: ["rgb_g"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_media_colors_rgb_b",
                on: "media_colors",
                columns: ["rgb_b"],
                ifNotExists: true
            )

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (19)")
            logInfo("Migration 19 complete: Added RGB columns for precision color search")
        }

        // Migration 20: Mark no-media items as "processed" to prevent infinite requeueing
        // Items with mediaFilesJSON = '[]' are orphan metadata files that cannot be processed
        // Setting empty strings for indexed content marks them as complete
        if currentVersion < 20 {
            try db.execute(sql: """
                UPDATE media_items
                SET ocrText = '',
                    dominantColorsJSON = '[]',
                    perceptualHash = ''
                WHERE mediaFilesJSON = '[]'
                AND (contextImageString IS NULL OR contextImageString = '')
                AND (ocrText IS NULL OR dominantColorsJSON IS NULL OR perceptualHash IS NULL)
            """)
            let count = db.changesCount
            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (20)")
            logInfo("Migration 20 complete: Marked \(count) no-media items as processed")
        }

        // Migration 21: Add foreign key to view_events.itemId with ON DELETE CASCADE
        // Prevents orphan view_events when media_items are deleted.
        // SQLite requires table recreation to add foreign keys.
        if currentVersion < 21 {
            // Check if view_events table exists
            let tableExists = try Row.fetchOne(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name='view_events'
            """) != nil

            if tableExists {
                // 1. Create new table with foreign key
                try db.execute(sql: """
                    CREATE TABLE view_events_new (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        itemId TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
                        viewedAt DATETIME NOT NULL,
                        durationSeconds REAL,
                        action TEXT NOT NULL
                    )
                """)

                // 2. Copy data (only rows with valid itemId references)
                try db.execute(sql: """
                    INSERT INTO view_events_new (id, itemId, viewedAt, durationSeconds, action)
                    SELECT ve.id, ve.itemId, ve.viewedAt, ve.durationSeconds, ve.action
                    FROM view_events ve
                    INNER JOIN media_items mi ON ve.itemId = mi.id
                """)

                // 3. Drop old table
                try db.execute(sql: "DROP TABLE view_events")

                // 4. Rename new table
                try db.execute(sql: "ALTER TABLE view_events_new RENAME TO view_events")

                // 5. Recreate indexes
                try db.create(
                    index: "idx_view_events_item",
                    on: "view_events",
                    columns: ["itemId"],
                    ifNotExists: true
                )
                try db.create(
                    index: "idx_view_events_time",
                    on: "view_events",
                    columns: ["viewedAt"],
                    ifNotExists: true
                )
            }

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (21)")
            logInfo("Migration 21 complete: Added foreign key to view_events with CASCADE delete")
        }

        // Migration 22: Add rating column to media_items and tagGroup column to tag_definitions
        if currentVersion < 22 {
            let mediaColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_items)")
            let existingMediaColumns = Set(mediaColumns.compactMap { $0["name"] as? String })

            if !existingMediaColumns.contains("rating") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN rating INTEGER")
            }

            // tag_definitions may be stored in UserDefaults, but add DB column for future migration
            // Check if tag_definitions table exists (it may not if tags are UserDefaults-only)
            let tagTableExists = try Row.fetchOne(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name='tag_definitions'
            """) != nil

            if tagTableExists {
                let tagColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(tag_definitions)")
                let existingTagColumns = Set(tagColumns.compactMap { $0["name"] as? String })

                if !existingTagColumns.contains("tagGroup") {
                    try db.execute(sql: "ALTER TABLE tag_definitions ADD COLUMN tagGroup TEXT")
                }
            }

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (22)")
            logInfo("Migration 22 complete: Added rating and tagGroup columns")
        }

        // Migration 23: Add tag_rules table and source context columns to media_items
        if currentVersion < 23 {
            // Create tag_rules table
            try TagRuleRecord.createTable(in: db)

            // Add source context columns to media_items
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_items)")
            let existingColumns = Set(columns.compactMap { $0["name"] as? String })

            if !existingColumns.contains("subreddit") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN subreddit TEXT")
            }
            if !existingColumns.contains("boardName") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN boardName TEXT")
            }
            if !existingColumns.contains("blogName") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN blogName TEXT")
            }
            if !existingColumns.contains("channelName") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN channelName TEXT")
            }
            if !existingColumns.contains("artistName") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN artistName TEXT")
            }
            if !existingColumns.contains("galleryName") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN galleryName TEXT")
            }
            if !existingColumns.contains("sourceTagsJSON") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN sourceTagsJSON TEXT")
            }
            if !existingColumns.contains("uploadDate") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN uploadDate DATETIME")
            }
            if !existingColumns.contains("viewCount") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN viewCount INTEGER")
            }
            if !existingColumns.contains("likeCount") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN likeCount INTEGER")
            }

            // Indexes for source context columns used in rule matching
            try db.create(index: "idx_media_items_subreddit", on: "media_items", columns: ["subreddit"], ifNotExists: true)
            try db.create(index: "idx_media_items_boardName", on: "media_items", columns: ["boardName"], ifNotExists: true)
            try db.create(index: "idx_media_items_blogName", on: "media_items", columns: ["blogName"], ifNotExists: true)
            try db.create(index: "idx_media_items_channelName", on: "media_items", columns: ["channelName"], ifNotExists: true)
            try db.create(index: "idx_media_items_artistName", on: "media_items", columns: ["artistName"], ifNotExists: true)
            try db.create(index: "idx_media_items_galleryName", on: "media_items", columns: ["galleryName"], ifNotExists: true)

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (23)")
            logInfo("Migration 23 complete: Added tag_rules table and source context columns")
        }

        // Migration 24: Photo pipeline integration
        // - media_attributes EAV table for ML results
        // - clip_vectors table for 768D CLIP embeddings
        // - pipeline_status/pipeline_version columns on media_items
        // - generatedCaption column for FTS
        // - Drop old feature_vectors, item_clusters, cluster_centroids tables
        if currentVersion < 24 {
            // Create media_attributes EAV table
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS media_attributes (
                    item_id    TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
                    module     TEXT NOT NULL,
                    key        TEXT NOT NULL,
                    value      REAL NOT NULL,
                    metadata   TEXT,
                    version    INTEGER NOT NULL DEFAULT 1,
                    PRIMARY KEY (item_id, module, key)
                )
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_attrs_module_key_value
                ON media_attributes(module, key, value)
            """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_attrs_item
                ON media_attributes(item_id, module)
            """)

            // Create clip_vectors table (768D CLIP embeddings, Float16 = 1536 bytes each)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS clip_vectors (
                    itemId      TEXT PRIMARY KEY REFERENCES media_items(id) ON DELETE CASCADE,
                    vectorData  BLOB NOT NULL,
                    version     INTEGER NOT NULL DEFAULT 1,
                    extractedAt TEXT NOT NULL
                )
            """)

            // Pipeline tracking columns on media_items
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_items)")
            let existingColumns = Set(columns.compactMap { $0["name"] as? String })

            if !existingColumns.contains("pipeline_status") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN pipeline_status TEXT DEFAULT 'none'")
            }
            if !existingColumns.contains("pipeline_version") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN pipeline_version INTEGER DEFAULT 0")
            }
            if !existingColumns.contains("generatedCaption") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN generatedCaption TEXT")
            }
            if !existingColumns.contains("pipeline_retry_count") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN pipeline_retry_count INTEGER DEFAULT 0")
            }

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_pipeline_status
                ON media_items(pipeline_status)
            """)

            // Drop old clustering/feature vector tables (replaced by CLIP)
            try db.execute(sql: "DROP TABLE IF EXISTS feature_vectors")
            try db.execute(sql: "DROP TABLE IF EXISTS item_clusters")
            try db.execute(sql: "DROP TABLE IF EXISTS cluster_centroids")

            // Rebuild FTS with the latest schema.
            try MediaItemRecord.rebuildFTSIndex(db: db)

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (24)")
            logInfo("Migration 24 complete: Photo pipeline tables, CLIP vectors, dropped old clustering")
        }

        // Migration 25: Add pipeline failure tracking columns
        // pipeline_last_error stores the error message from the most recent failure.
        // pipeline_failed_at stores the ISO8601 timestamp of when the failure occurred.
        if currentVersion < 25 {
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_items)")
            let existingColumns = Set(columns.compactMap { $0["name"] as? String })

            if !existingColumns.contains("pipeline_last_error") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN pipeline_last_error TEXT")
            }
            if !existingColumns.contains("pipeline_failed_at") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN pipeline_failed_at TEXT")
            }

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (25)")
            logInfo("Migration 25 complete: Added pipeline_last_error and pipeline_failed_at columns")
        }

        // Migration 26: Re-analyze OCR text with TextLayoutAnalyzer for paragraph grouping
        // Converts flat per-line OCRTextRegion data to paragraph-grouped SerializableTextBlock data
        // in the media_file_ocr table, and re-aggregates paragraph-structured text to media_items.ocrText.
        if currentVersion < 26 {
            let analyzer = TextLayoutAnalyzer()

            let rows = try Row.fetchAll(db, sql: "SELECT id, item_id, ocr_regions_json FROM media_file_ocr WHERE ocr_regions_json IS NOT NULL")

            for row in rows {
                guard let id: String = row["id"],
                      let regionsJSON: String = row["ocr_regions_json"] else { continue }

                // Try to decode as legacy OCRTextRegion format first
                // (id: UUID, text: String, boundingBox: SerializableCGRect, confidence: Float)
                struct LegacyRegion: Codable {
                    let id: UUID?
                    let text: String
                    let boundingBox: SerializableCGRect
                    let confidence: Float
                }

                // If it already decodes as SerializableTextBlock, skip (already migrated)
                if (try? JSONDecoder().decode([SerializableTextBlock].self, from: Data(regionsJSON.utf8))) != nil {
                    continue
                }

                guard let legacyRegions = try? JSONDecoder().decode([LegacyRegion].self, from: Data(regionsJSON.utf8)),
                      !legacyRegions.isEmpty else { continue }

                // Convert to TextObservation for the layout analyzer
                let observations = legacyRegions.map { region in
                    TextObservation(
                        text: region.text,
                        boundingBox: region.boundingBox.cgRect,
                        confidence: region.confidence
                    )
                }

                // Group into paragraph blocks with widened line-gap tolerance
                let blocks = OCRParagraphGrouper.group(observations, analyzer: analyzer)
                let serializableBlocks = blocks.map { SerializableTextBlock(from: $0) }

                // Encode new format
                guard let newJSON = try? JSONEncoder().encode(serializableBlocks),
                      let newJSONString = String(data: newJSON, encoding: .utf8) else { continue }

                // Build paragraph-structured text
                let structuredText = blocks.map(\.text).joined(separator: "\n\n")

                // Update per-file OCR
                try db.execute(
                    sql: "UPDATE media_file_ocr SET ocr_regions_json = ?, ocr_text = ? WHERE id = ?",
                    arguments: [newJSONString, structuredText, id]
                )
            }

            // Re-aggregate ocrText for all items that have per-file OCR
            let itemIds = try String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM media_file_ocr WHERE ocr_text IS NOT NULL AND ocr_text != ''")
            for itemId in itemIds {
                let texts = try String.fetchAll(db, sql: """
                    SELECT ocr_text FROM media_file_ocr
                    WHERE item_id = ? AND ocr_text IS NOT NULL AND ocr_text != ''
                    ORDER BY file_index
                """, arguments: [itemId])

                let aggregated = texts.joined(separator: "\n\n---\n\n")
                try db.execute(
                    sql: "UPDATE media_items SET ocrText = ? WHERE id = ?",
                    arguments: [aggregated, itemId]
                )
            }

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (26)")
            logInfo("Migration 26 complete: Re-analyzed OCR with TextLayoutAnalyzer paragraph grouping")
        }

        // Migration 27: Expand FTS coverage for "All" search to include source/context metadata.
        // Applies only to libraries already on 24-26 (older versions get this via migration 24 rebuild).
        if currentVersion >= 24 && currentVersion < 27 {
            try MediaItemRecord.rebuildFTSIndex(db: db)
            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (27)")
            logInfo("Migration 27 complete: Expanded FTS with source metadata and tags")
        }

        // Migration 28: Add true download/import timestamps without repurposing archivedDate.
        if currentVersion < 28 {
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_items)")
            let existingColumns = Set(columns.compactMap { $0["name"] as? String })

            if !existingColumns.contains("downloadDate") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN downloadDate DATETIME")
            }
            if !existingColumns.contains("importDate") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN importDate DATETIME")
            }

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (28)")
            logInfo("Migration 28 complete: Added downloadDate and importDate columns")
        }

        // Migration 29: Cache sidecar fingerprints for fast startup scans.
        if currentVersion < 29 {
            try MediaItemRecord.createStartupScanCacheTable(in: db)

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (29)")
            logInfo("Migration 29 complete: Added archive startup scan cache")
        }

        // Migration 30: Native video understanding timeline storage.
        if currentVersion < 30 {
            try VideoSegmentRecord.createTable(in: db)

            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_items)")
            let existingColumns = Set(columns.compactMap { $0["name"] as? String })

            if !existingColumns.contains("video_understanding_status") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN video_understanding_status TEXT DEFAULT 'none'")
            }
            if !existingColumns.contains("video_understanding_version") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN video_understanding_version INTEGER DEFAULT 0")
            }
            if !existingColumns.contains("video_understanding_retry_count") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN video_understanding_retry_count INTEGER DEFAULT 0")
            }
            if !existingColumns.contains("video_understanding_last_error") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN video_understanding_last_error TEXT")
            }
            if !existingColumns.contains("video_understanding_failed_at") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN video_understanding_failed_at TEXT")
            }

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_video_understanding_status
                ON media_items(video_understanding_status)
            """)

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (30)")
            logInfo("Migration 30 complete: Added native video understanding storage")
        }

        // Migration 31: Local Parakeet transcript timeline storage.
        if currentVersion < 31 {
            try TranscriptSegmentRecord.createTable(in: db)

            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_items)")
            let existingColumns = Set(columns.compactMap { $0["name"] as? String })

            if !existingColumns.contains("transcription_status") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN transcription_status TEXT DEFAULT 'none'")
            }
            if !existingColumns.contains("transcription_version") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN transcription_version INTEGER DEFAULT 0")
            }
            if !existingColumns.contains("transcription_retry_count") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN transcription_retry_count INTEGER DEFAULT 0")
            }
            if !existingColumns.contains("transcription_last_error") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN transcription_last_error TEXT")
            }
            if !existingColumns.contains("transcription_failed_at") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN transcription_failed_at TEXT")
            }

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_transcription_status
                ON media_items(transcription_status)
            """)

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (31)")
            logInfo("Migration 31 complete: Added Parakeet transcript storage")
        }

        // Migration 32: Repair FTS — restore the content-sync triggers that a
        // prior migration dropped without recreating on some databases, expand
        // the index to the full source-metadata column set, and make filenames
        // searchable via a derived `ftsFileNames` column. Rebuilding from
        // media_items also re-indexes any rows that drifted out of sync.
        if currentVersion < 32 {
            try MediaItemRecord.addFileNamesGeneratedColumn(in: db)
            // Drops + recreates the FTS table (new schema incl. ftsFileNames),
            // repopulates from media_items, and reinstalls the sync triggers.
            try MediaItemRecord.rebuildFTSIndex(db: db)

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (32)")
            logInfo("Migration 32 complete: Rebuilt FTS with sync triggers + searchable filenames")
        }

        // Migration 33: Record why an item was soft-deleted. This lets the
        // Recently Deleted surface keep user/missing-file recovery separate
        // from combine tombstones, which must never be restored independently.
        if currentVersion < 33 {
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_items)")
            let existingColumns = Set(columns.compactMap { $0["name"] as? String })
            if !existingColumns.contains("deletionReason") {
                try db.execute(sql: "ALTER TABLE media_items ADD COLUMN deletionReason TEXT")
            }
            try db.create(
                index: "idx_media_items_deletion_reason",
                on: "media_items",
                columns: ["deletionReason"],
                ifNotExists: true
            )
            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (33)")
            logInfo("Migration 33 complete: Added soft-delete provenance")
        }

        // Migration 34: Persist strict sidecar parse failures so an unchanged malformed
        // file is not reparsed and relogged at every startup. The source sidecar remains
        // untouched and can be surfaced by an Issues/Reveal UI for manual repair.
        if currentVersion < 34 {
            try SidecarParseFailure.createTable(in: db)
            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (34)")
            logInfo("Migration 34 complete: Added persistent sidecar parse-failure cache")
        }

        // Migration 35: Persist which existing file role should lead presentation. This is
        // intentionally a flag rather than a path swap: capture, analysis, and OCR indexing
        // continue to use mediaFiles/contextImage in their original roles.
        if currentVersion < 35 {
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(media_items)")
            let existingColumns = Set(columns.compactMap { $0["name"] as? String })
            if !existingColumns.contains("prefersContextImage") {
                try db.execute(
                    sql: "ALTER TABLE media_items ADD COLUMN prefersContextImage BOOLEAN NOT NULL DEFAULT 0"
                )
            }
            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (35)")
            logInfo("Migration 35 complete: Added preferred media/context presentation role")
        }

        // Migration 36: Legacy combine operations predate deletion provenance. Their
        // absorbed rows still reference display files now owned by the surviving item,
        // so exposing or purging those rows independently could remove live media.
        // Conservatively quarantine any legacy deleted row whose media/context path is
        // also referenced by an active row. This is deliberately a new migration rather
        // than an edit to migration 33 so databases opened by an interim build are fixed.
        if currentVersion < 36 {
            let decoder = JSONDecoder()
            let activeRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT mediaFilesJSON, contextImageString
                    FROM media_items
                    WHERE deletedAt IS NULL OR deletedAt = ''
                    """
            )
            var activeDisplayPaths = Set<String>()
            for row in activeRows {
                let mediaFilesJSON: String = row["mediaFilesJSON"]
                if let data = mediaFilesJSON.data(using: .utf8),
                   let paths = try? decoder.decode([String].self, from: data) {
                    activeDisplayPaths.formUnion(paths.filter { !$0.isEmpty })
                }
                if let contextPath: String = row["contextImageString"], !contextPath.isEmpty {
                    activeDisplayPaths.insert(contextPath)
                }
            }

            let legacyRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, mediaFilesJSON, contextImageString
                    FROM media_items
                    WHERE deletedAt IS NOT NULL AND deletedAt != ''
                      AND (deletionReason IS NULL OR deletionReason = '')
                    """
            )
            var quarantinedIDs: [String] = []
            for row in legacyRows {
                let id: String = row["id"]
                let mediaFilesJSON: String = row["mediaFilesJSON"]
                let mediaPaths: [String]
                if let data = mediaFilesJSON.data(using: .utf8) {
                    mediaPaths = (try? decoder.decode([String].self, from: data)) ?? []
                } else {
                    mediaPaths = []
                }
                let contextPath: String? = row["contextImageString"]
                let sharesActiveDisplayPath = mediaPaths.contains(where: activeDisplayPaths.contains)
                    || contextPath.map(activeDisplayPaths.contains) == true
                if sharesActiveDisplayPath {
                    quarantinedIDs.append(id)
                }
            }

            if !quarantinedIDs.isEmpty {
                let placeholders = quarantinedIDs.map { _ in "?" }.joined(separator: ", ")
                try db.execute(
                    sql: "UPDATE media_items SET deletionReason = 'combined' WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(quarantinedIDs)
                )
                guard db.changesCount == quarantinedIDs.count else {
                    throw DatabaseError.migrationFailed(
                        "Expected to quarantine \(quarantinedIDs.count) legacy shared-path tombstones; updated \(db.changesCount)"
                    )
                }
            }

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (36)")
            logInfo("Migration 36 complete: Quarantined \(quarantinedIDs.count) legacy shared-path tombstones")
        }

        // Migration 37: Normalize the tag lookup junction. The source tagsJSON remains
        // presentation-preserving, while this derived table is canonicalized for
        // case-insensitive include/exclude/exact matching. Rebuilding in Swift avoids
        // SQLite LOWER()'s ASCII-only behavior, repairs historical JSON/junction drift,
        // discards orphan junction rows, and safely folds case-colliding tags.
        if currentVersion < 37 {
            let rows = try Row.fetchAll(db, sql: "SELECT id, tagsJSON FROM media_items")
            var normalizedRowsByItem: [String: Set<String>] = [:]
            var values: [(itemID: String, tag: String)] = []

            for row in rows {
                let itemID: String = row["id"]
                let tagsJSON: String = row["tagsJSON"]
                guard let tags = try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8)) else {
                    continue
                }
                for rawTag in tags {
                    let normalizedTag = TagCanonicalizer.key(rawTag)
                    guard !normalizedTag.isEmpty else { continue }
                    guard normalizedRowsByItem[itemID, default: []].insert(normalizedTag).inserted else {
                        continue
                    }
                    values.append((itemID, normalizedTag))
                }
            }

            try db.execute(sql: "DELETE FROM media_tags")
            for value in values {
                try db.execute(
                    sql: "INSERT INTO media_tags (item_id, tag) VALUES (?, ?)",
                    arguments: [value.itemID, value.tag]
                )
            }

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (37)")
            logInfo("Migration 37 complete: Normalized \(values.count) tag lookup rows")
        }

        // Migration 38: The default library page filters to active, displayable items
        // and orders by archivedDate. Separate deletedAt and archivedDate indexes make
        // SQLite gather the active rows and then build a temporary sort tree. This
        // partial index exactly matches the hot predicate, allowing an ordered bounded
        // index scan that can stop as soon as the requested page is filled.
        if currentVersion < 38 {
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_media_items_active_displayable_archivedDate
                ON media_items(archivedDate DESC)
                WHERE COALESCE(deletedAt, '') = ''
                  AND (
                    mediaFilesJSON != '[]'
                    OR (contextImageString IS NOT NULL AND contextImageString != '')
                  )
            """)

            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (38)")
            logInfo("Migration 38 complete: Added ordered active-library page index")
        }
        if currentVersion < 39 {
            try MetadataOutbox.install(in: db)
            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (39)")
            logInfo("Migration 39 complete: Durable per-field metadata projection")
        }
        if currentVersion < 40 {
            try db.execute(sql: """
                CREATE TABLE vision_pending_jobs (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    item_id TEXT NOT NULL UNIQUE REFERENCES media_items(id) ON DELETE CASCADE,
                    priority INTEGER NOT NULL DEFAULT 0,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    revision INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX idx_vision_pending_admission ON vision_pending_jobs(priority DESC, sequence)
                    WHERE retry_count < 3;
                INSERT INTO schema_migrations (version) VALUES (40);
                """)
        }
        if currentVersion < 41 {
            try ItemAssetStore.install(in: db)
            try db.execute(sql: "INSERT INTO schema_migrations (version) VALUES (41)")
            logInfo("Migration 41 complete: Stable assets and recoverable per-file associations")
        }
        if currentVersion < 42 {
            // Stable page ties must not reintroduce a temporary sort on the
            // default active-library path.
            try db.execute(sql: """
                DROP INDEX idx_media_items_active_displayable_archivedDate;
                CREATE INDEX idx_media_items_active_displayable_archivedDate
                ON media_items(archivedDate DESC, id ASC)
                WHERE COALESCE(deletedAt, '') = ''
                  AND (mediaFilesJSON != '[]' OR (contextImageString IS NOT NULL AND contextImageString != ''));
                INSERT INTO schema_migrations(version) VALUES (42);
                """)
        }
        if currentVersion < 43 {
            try DuplicateEvidencePersistence.migrate(db)
            try db.execute(sql: "INSERT INTO schema_migrations(version) VALUES (43)")
        }
        if currentVersion < 44 {
            try DuplicateReviewService.migrate(db)
            try db.execute(sql: "INSERT INTO schema_migrations(version) VALUES (44)")
        }
        if currentVersion < 45 {
            try SafetyAttributes.repairLegacyFlags(in: db)
            try db.execute(sql: "INSERT INTO schema_migrations(version) VALUES (45)")
        }
    }

    // MARK: - Database Access

    /// Execute a read-only database operation
    func read<T>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        guard let pool = pool else {
            throw DatabaseError.notInitialized
        }
        return try await pool.read(block)
    }

    /// Execute a write database operation
    func write<T>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        guard let pool = pool else {
            throw DatabaseError.notInitialized
        }
        return try await pool.write(block)
    }

    /// Get direct access to the pool for advanced operations (e.g., observation)
    func getPool() throws -> DatabasePool {
        guard let pool = pool else {
            throw DatabaseError.notInitialized
        }
        return pool
    }

    // MARK: - Utility

    /// Reset the database (for testing/debugging)
    func reset() async throws {
        pool = nil
        try FileManager.default.removeItem(at: databaseURL)
        try await initialize()
    }

    /// Database file path (for debugging)
    var databasePath: String {
        databaseURL.path
    }
}

// MARK: - Errors

enum DatabaseError: Error, LocalizedError {
    case notInitialized
    case migrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Database not initialized. Call DatabaseManager.shared.initialize() first."
        case .migrationFailed(let reason):
            return "Database migration failed: \(reason)"
        }
    }
}
