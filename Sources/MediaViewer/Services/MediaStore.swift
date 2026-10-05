import Foundation
import GRDB
import Combine
import os.signpost
import SwiftUI
import AppKit
import Yams

// MARK: - Notifications

extension Notification.Name {
    /// Posted when MediaStore data changes (insert, update, delete)
    /// Used to trigger UI refresh when file watcher detects changes
    static let mediaStoreDidChange = Notification.Name("mediaStoreDidChange")

    /// Posted when duplicate groups change (cleared, added, resolved)
    /// GAP #7 fix: UI needs to refresh duplicate counts
    static let duplicateGroupsDidChange = Notification.Name("duplicateGroupsDidChange")

    /// Posted when a canvas is deleted
    /// GAP #6 fix: CanvasLayoutManager needs to clear in-memory state
    static let canvasDidDelete = Notification.Name("canvasDidDelete")
}

// MARK: - Search Scope

/// Scope for FTS search - allows searching specific fields
enum SearchScope: String, CaseIterable, Codable, Sendable {
    case all        // search all fields
    case ocrOnly    // OCR text only
    case notesOnly  // notes only
    case authorOnly // author only
    case visual     // CLIP text-to-image search

    var displayName: String {
        switch self {
        case .all: return "All"
        case .ocrOnly: return "OCR"
        case .notesOnly: return "Notes"
        case .authorOnly: return "Author"
        case .visual: return "Image Match"
        }
    }

    var icon: String {
        switch self {
        case .all: return "magnifyingglass"
        case .ocrOnly: return "text.viewfinder"
        case .notesOnly: return "note.text"
        case .authorOnly: return "person"
        case .visual: return "eye"
        }
    }
}

// MARK: - Precision Color Search

/// RGB color with tolerance for precision color search
/// Finds images containing colors within ±tolerance of the target RGB
struct ColorSearchRGB: Equatable, Sendable {
    let r: Int  // 0-255
    let g: Int  // 0-255
    let b: Int  // 0-255
    let tolerance: Int  // Per-channel tolerance (0-50 typical)

    /// Whether to use perceptual (CIE76 DeltaE) color matching instead of RGB tolerance
    var usePerceptual: Bool = false
    /// DeltaE threshold for perceptual mode (default 20)
    var deltaEThreshold: Double = 20

    /// Hex representation of the target color
    var hex: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }

    /// SwiftUI Color representation
    var color: Color {
        Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
    }

    /// Create from hex string (e.g., "#FF4488" or "FF4488")
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if hexSanitized.hasPrefix("#") {
            hexSanitized.removeFirst()
        }
        guard hexSanitized.count == 6,
              let hexValue = UInt32(hexSanitized, radix: 16) else {
            return nil
        }
        self.r = Int((hexValue >> 16) & 0xFF)
        self.g = Int((hexValue >> 8) & 0xFF)
        self.b = Int(hexValue & 0xFF)
        self.tolerance = 25  // Default tolerance
    }

    init(r: Int, g: Int, b: Int, tolerance: Int = 25) {
        self.r = max(0, min(255, r))
        self.g = max(0, min(255, g))
        self.b = max(0, min(255, b))
        self.tolerance = max(0, min(100, tolerance))
    }
}

// MARK: - Filter State

struct AspectRatioFilter: Equatable, Sendable {
    var min: Double
    var max: Double
}

enum DeletionScope: String, Codable, Sendable {
    case active
    case deletedOnly
    case all
}

enum TagFilterPolarity: String, Codable, Sendable {
    case include
    case exclude
}

enum TagFilterScope: String, Codable, Sendable {
    case subtree
    case exact
}

/// An explicit tag predicate. Legacy `FilterState.tags` remains the concise
/// include-subtree API; this model adds exclusion and exact-parent behavior.
struct TagFilter: Equatable, Hashable, Codable, Sendable {
    var name: String
    var polarity: TagFilterPolarity = .include
    var scope: TagFilterScope = .subtree

    init(name: String, polarity: TagFilterPolarity = .include, scope: TagFilterScope = .subtree) {
        self.name = TagCanonicalizer.key(name)
        self.polarity = polarity
        self.scope = scope
    }
}

enum DeletedItemRecoveryError: LocalizedError {
    case combinedItemsCannotBeRestored
    case noDisplayableFiles([UUID])

    var errorDescription: String? {
        switch self {
        case .combinedItemsCannotBeRestored:
            return "Combined items cannot be restored independently. Their content is part of the surviving item."
        case .noDisplayableFiles(let ids):
            let noun = ids.count == 1 ? "item has" : "items have"
            return "\(ids.count) \(noun) no media or context file on disk. Put the files back before restoring."
        }
    }
}

enum DeletedItemPurgeError: LocalizedError {
    case activeItemsIncluded
    case combinedItemsIncluded

    var errorDescription: String? {
        switch self {
        case .activeItemsIncluded:
            return "Only items already in Recently Deleted can be permanently removed."
        case .combinedItemsIncluded:
            return "Combined items cannot be permanently removed independently. Their files may belong to the surviving item."
        }
    }
}

/// Current filter/query state for fetching media items
struct FilterState: Equatable, Sendable {
    var searchText: String = ""
    var searchScope: SearchScope = .all
    var platform: String? = nil
    /// Additional scopes are intersected, never silently replaced by another control.
    var platformConstraints: [String] = []
    var folderConstraints: [String] = []
    var dateConstraints: [DateRangeFilter] = []
    var author: String? = nil
    var authorQuery: String? = nil
    var authorConstraints: [String] = []
    var sourceQuery: String? = nil
    var sourceConstraints: [String] = []
    var ocrQuery: String? = nil
    var notesQuery: String? = nil
    var starred: Bool? = nil
    var tags: [String] = []
    var tagFilters: [TagFilter] = []
    var deletionScope: DeletionScope = .active
    var dateRange: DateRangeFilter? = nil
    var smartFolder: SmartFolder? = nil
    var sortOrder: SortOrder = .archivedDateDescending
    var shuffleSeed: UInt64? = nil

    /// Filter by folder path (e.g., "2025-12")
    var folderPath: String? = nil

    /// Filter by color buckets (OR logic - any matching bucket)
    var colorFilters: Set<ColorBucket> = []

    /// Precision color search: find images with colors within RGB tolerance
    var colorSearchRGB: ColorSearchRGB? = nil

    /// Filter to items that have OCR text extracted
    var hasOCR: Bool? = nil

    /// Filter by whether an item has video media files
    var hasVideo: Bool? = nil

    /// Filter by whether an item has no tags
    var tagsEmpty: Bool? = nil

    /// Filter by media/context file extensions such as jpg, gif, mp4
    var fileExtensions: [String] = []

    /// Filter by stored width/height aspect ratio.
    var aspectRatio: AspectRatioFilter? = nil
    var aspectRatioConstraints: [AspectRatioFilter] = []

    /// Limit results:
    /// - `0`: use `defaultQueryLimit`
    /// - `-1`: no limit (explicitly unbounded)
    /// - `>0`: exact SQL LIMIT
    var limit: Int = 0

    /// Offset for pagination
    var offset: Int = 0

    /// Filter to a specific collection board
    var boardId: UUID? = nil

    /// Enable FSRS rediscover mode (fetch items due for review)
    var rediscoverMode: Bool = false

    /// ML attribute filters (AND logic - all must match)
    var attributeFilters: [AttributeFilter] = []

    /// Hide junk items (pipeline junk classification)
    var hideJunk: Bool = true

    /// Minimum curation score (0.0–1.0, nil = no filter)
    var minCurationScore: Double? = nil

    /// Safety filter: hide unsafe content
    var hideSafetyFlagged: Bool = true

    /// Pipeline status filter
    var pipelineStatus: PipelineStatus? = nil

    /// CLIP semantic search results (itemIds with scores, merged with FTS)
    var clipResultIds: [UUID]? = nil

    /// Defensive default for queries that do not request pagination.
    static let defaultQueryLimit: Int = 500

    /// Returns a copy configured for an explicitly unbounded query.
    func withUnlimitedLimit() -> FilterState {
        var copy = self
        copy.limit = -1
        return copy
    }

    static let all = FilterState()
}

// MARK: - Media Store

enum MediaStoreChange: Equatable, Sendable {
    case items(Set<UUID>)
    case deleted(Set<UUID>)
    case reload
}

/// Central data access layer for MediaItems.
/// Provides CRUD operations and GRDB observation for live UI updates.
final class MediaStore: @unchecked Sendable {
    private static let searchableVideoExtensions = ["mp4", "mov", "webm", "m4v", "avi", "mkv"]
    private static let fileExtensionAliases: [String: [String]] = [
        "htm": ["htm", "html"],
        "html": ["htm", "html"],
        "heic": ["heic", "heif"],
        "heif": ["heic", "heif"],
        "jpeg": ["jpg", "jpeg"],
        "jpg": ["jpg", "jpeg"],
        "mpg": ["mpg", "mpeg"],
        "mpeg": ["mpg", "mpeg"],
        "aif": ["aif", "aiff"],
        "aiff": ["aif", "aiff"],
        "tif": ["tif", "tiff"],
        "tiff": ["tif", "tiff"]
    ]
    let database: DatabaseManager

    /// Debounced queue for writing user data back to .md frontmatter
    let writeBackQueue: WriteBackQueue

    /// Tracks paths recently written by the app (shared with AppCoordinator)
    let selfWriteTracker: SelfWriteTracker

    /// Tag rule engine for auto-tagging on insert
    @MainActor
    var tagRuleEngine: TagRuleEngine?

    /// Publisher for database changes - views can observe this
    @MainActor
    private let changesSubject = PassthroughSubject<Void, Never>()

    @MainActor
    private let detailedChangesSubject = PassthroughSubject<MediaStoreChange, Never>()

    @MainActor
    var changes: AnyPublisher<Void, Never> {
        changesSubject.eraseToAnyPublisher()
    }

    @MainActor
    var detailedChanges: AnyPublisher<MediaStoreChange, Never> {
        detailedChangesSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    init(database: DatabaseManager = .shared, selfWriteTracker: SelfWriteTracker = SelfWriteTracker()) {
        self.database = database
        self.selfWriteTracker = selfWriteTracker
        self.writeBackQueue = WriteBackQueue(database: database, selfWriteTracker: selfWriteTracker)
    }

    // MARK: - Helpers

    func existingMetadataFileStrings(for paths: [String]) async throws -> Set<String> {
        let uniquePaths = Array(Set(paths))
        guard !uniquePaths.isEmpty else { return [] }

        return try await database.read { db in
            var found = Set<String>()
            let chunkSize = 500  // Keep SQL placeholders safely below SQLite limits.

            for start in stride(from: 0, to: uniquePaths.count, by: chunkSize) {
                let end = min(start + chunkSize, uniquePaths.count)
                let chunk = Array(uniquePaths[start..<end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let sql = "SELECT metadataFileString FROM media_items WHERE metadataFileString IN (\(placeholders))"
                let rows = try String.fetchAll(db, sql: sql, arguments: StatementArguments(chunk))
                found.formUnion(rows)
            }

            return found
        }
    }

    // MARK: - Fetch Operations

    /// Fetch items matching the filter state.
    /// For large grids, callers can skip expensive payloads (ML attributes, per-file OCR)
    /// and hydrate a single item lazily when opening detail view.
    func fetchItems(
        filter: FilterState = .all,
        includeMLAttributes: Bool = true,
        includePerFileOCR: Bool = true,
        includeVideoSegments: Bool = true,
        includeTranscriptSegments: Bool = true
    ) async throws -> [MediaItem] {
        // Build filter description for PerfLog
        try Task.checkCancellation()
        var filterParts: [String] = []
        if !filter.searchText.isEmpty { filterParts.append("search:\(filter.searchText.prefix(15))") }
        if let platform = filter.platform { filterParts.append("platform:\(platform)") }
        if filter.starred == true { filterParts.append("starred") }
        if !filter.tags.isEmpty { filterParts.append("tags:\(filter.tags.count)") }
        if !filter.tagFilters.isEmpty { filterParts.append("tagFilters:\(filter.tagFilters.count)") }
        if filter.deletionScope != .active { filterParts.append("deletion:\(filter.deletionScope.rawValue)") }
        if filter.smartFolder != nil { filterParts.append("smartFolder") }
        if filter.limit > 0 {
            filterParts.append("limit:\(filter.limit)")
        } else if filter.limit == 0 {
            filterParts.append("limit:\(FilterState.defaultQueryLimit)")
        }
        if filter.offset > 0 { filterParts.append("offset:\(filter.offset)") }
        let filterContext = filterParts.isEmpty ? "all" : filterParts.joined(separator: ", ")

        let token = PerfLog.begin("fetchItems", category: .data, context: filterContext)
        defer { PerfLog.end(token) }

        // Pre-compute hierarchical tag expansion on MainActor before entering database closure
        let tagExpansion = await expandTagsForFilter(filter)

        return try await database.read { db in
            try Task.checkCancellation()
            let query = self.buildFilterQueryParts(
                filter: filter,
                tagExpansion: tagExpansion,
                searchMode: .joinedFTSMatch
            )

            var sql = query.selectSQL
            sql = self.applyingWhereClause(to: sql, conditions: query.conditions)
            self.appendSortAndPagination(to: &sql, filter: filter, isSearching: query.isSearching)

            var records = try MediaItemRecord.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(query.arguments)
            )
            records = self.applyShuffleAndPaginationIfNeeded(records, filter: filter)

            return try self.materializeMediaItems(
                db: db,
                records: records,
                includeMLAttributes: includeMLAttributes,
                includePerFileOCR: includePerFileOCR,
                includeVideoSegments: includeVideoSegments,
                includeTranscriptSegments: includeTranscriptSegments
            )
        }
    }

    /// Load per-file OCR data for multiple items in one query
    private func loadPerFileOCRBatch(db: Database, itemIds: [UUID]) throws -> [UUID: [Int: MediaFileOCR]] {
        guard !itemIds.isEmpty else { return [:] }

        let placeholders = itemIds.map { _ in "?" }.joined(separator: ", ")
        let sql = "SELECT * FROM media_file_ocr WHERE item_id IN (\(placeholders)) AND association_state = 'attached' ORDER BY item_id, file_index"
        let arguments = itemIds.map { $0.uuidString }

        let records = try MediaFileOCRRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

        var result: [UUID: [Int: MediaFileOCR]] = [:]
        for record in records {
            if result[record.itemId] == nil {
                result[record.itemId] = [:]
            }
            result[record.itemId]?[record.fileIndex] = record.toMediaFileOCR()
        }

        return result
    }

    /// Load ML attributes for multiple items in one query.
    /// Returns flattened "module.key" -> value map per item.
    private func loadMLAttributesBatch(db: Database, itemIds: [UUID]) throws -> [UUID: [String: Double]] {
        guard !itemIds.isEmpty else { return [:] }

        let placeholders = itemIds.map { _ in "?" }.joined(separator: ", ")
        let sql = "SELECT item_id, module, key, value, metadata FROM media_attributes WHERE item_id IN (\(placeholders)) ORDER BY item_id"
        let arguments = itemIds.map { $0.uuidString }

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

        var result: [UUID: [String: Double]] = [:]
        for row in rows {
            let itemIdStr: String = row["item_id"]
            guard let itemId = UUID(uuidString: itemIdStr) else { continue }
            let module: String = row["module"]
            let key: String = row["key"]
            let value: Double = row["value"]

            if result[itemId] == nil {
                result[itemId] = [:]
            }
            result[itemId]?["\(module).\(key)"] = value
        }

        return result
    }

    /// Load native video timeline segments for multiple items in one query.
    private func loadVideoSegmentsBatch(db: Database, itemIds: [UUID]) throws -> [UUID: [VideoSegment]] {
        guard !itemIds.isEmpty else { return [:] }
        guard try db.tableExists(VideoSegmentRecord.databaseTableName) else { return [:] }

        let placeholders = itemIds.map { _ in "?" }.joined(separator: ", ")
        let records = try VideoSegmentRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM video_segments
                WHERE item_id IN (\(placeholders))
                  AND association_state = 'attached'
                ORDER BY item_id, media_file_index, start_time
            """,
            arguments: StatementArguments(itemIds.map { $0.uuidString })
        )

        var result: [UUID: [VideoSegment]] = [:]
        for record in records {
            result[record.itemId, default: []].append(record.toVideoSegment())
        }
        return result
    }

    /// Load speech transcript segments for multiple items in one query.
    private func loadTranscriptSegmentsBatch(db: Database, itemIds: [UUID]) throws -> [UUID: [TranscriptSegment]] {
        guard !itemIds.isEmpty else { return [:] }
        guard try db.tableExists(TranscriptSegmentRecord.databaseTableName) else { return [:] }

        let placeholders = itemIds.map { _ in "?" }.joined(separator: ", ")
        let records = try TranscriptSegmentRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM transcript_segments
                WHERE item_id IN (\(placeholders))
                  AND association_state = 'attached'
                ORDER BY item_id, media_file_index, start_time
            """,
            arguments: StatementArguments(itemIds.map { $0.uuidString })
        )

        var result: [UUID: [TranscriptSegment]] = [:]
        for record in records {
            result[record.itemId, default: []].append(record.toTranscriptSegment())
        }
        return result
    }

    /// Fetch a single item by ID
    func fetchItem(id: UUID) async throws -> MediaItem? {
        try await database.read { db in
            guard let record = try MediaItemRecord.fetchOne(
                db,
                sql: "SELECT * FROM media_items WHERE id = ?",
                arguments: [id.uuidString]
            ) else {
                return nil
            }

            // Load per-file OCR data, ML attributes, and timeline segments
            let ocrRecords = try MediaFileOCRRecord.fetchAll(db: db, itemId: id)
            var perFileOCR: [Int: MediaFileOCR] = [:]
            for ocrRecord in ocrRecords {
                perFileOCR[ocrRecord.fileIndex] = ocrRecord.toMediaFileOCR()
            }
            let mlAttrs = try self.loadMLAttributesBatch(db: db, itemIds: [id])[id] ?? [:]
            let videoSegments = try self.loadVideoSegmentsBatch(db: db, itemIds: [id])[id] ?? []
            let transcriptSegments = try self.loadTranscriptSegmentsBatch(db: db, itemIds: [id])[id] ?? []

            return record.toMediaItem(
                withPerFileOCR: perFileOCR,
                mlAttributes: mlAttrs,
                videoSegments: videoSegments,
                transcriptSegments: transcriptSegments,
                assets: try ItemAssetStore.fetchBatch(in: db, itemIDs: [id])[id] ?? []
            )
        }
    }

    /// Fetch item by metadata file path.
    /// NOTE: Intentionally does NOT filter by deletedAt. This is used by the file watcher
    /// when a .md file changes, and needs to find the item even if soft-deleted so it can update it.
    func fetchItem(byMetadataPath path: String) async throws -> MediaItem? {
        try await database.read { db in
            guard let record = try MediaItemRecord.fetchOne(
                db,
                sql: "SELECT * FROM media_items WHERE metadataFileString = ?",
                arguments: [path]
            ) else {
                return nil
            }

            // Load per-file OCR data, ML attributes, and timeline segments
            let ocrRecords = try MediaFileOCRRecord.fetchAll(db: db, itemId: record.id)
            var perFileOCR: [Int: MediaFileOCR] = [:]
            for ocrRecord in ocrRecords {
                perFileOCR[ocrRecord.fileIndex] = ocrRecord.toMediaFileOCR()
            }
            let mlAttrs = try self.loadMLAttributesBatch(db: db, itemIds: [record.id])[record.id] ?? [:]
            let videoSegments = try self.loadVideoSegmentsBatch(db: db, itemIds: [record.id])[record.id] ?? []
            let transcriptSegments = try self.loadTranscriptSegmentsBatch(db: db, itemIds: [record.id])[record.id] ?? []

            return record.toMediaItem(
                withPerFileOCR: perFileOCR,
                mlAttributes: mlAttrs,
                videoSegments: videoSegments,
                transcriptSegments: transcriptSegments,
                assets: try ItemAssetStore.fetchBatch(in: db, itemIDs: [record.id])[record.id] ?? []
            )
        }
    }

    /// Fetch multiple items by IDs (batch query to avoid N+1)
    func fetchItems(ids: [UUID]) async throws -> [MediaItem] {
        try await fetchItems(ids: ids, includeMLAttributes: true, includePerFileOCR: true, includeVideoSegments: true, includeTranscriptSegments: true)
    }

    func fetchItems(
        ids: [UUID],
        includeMLAttributes: Bool,
        includePerFileOCR: Bool,
        includeVideoSegments: Bool,
        includeTranscriptSegments: Bool
    ) async throws -> [MediaItem] {
        try Task.checkCancellation()
        guard !ids.isEmpty else { return [] }

        return try await database.read { db in
            var fetchedItems: [MediaItem] = []
            let uniqueIDs = Array(Set(ids))
            for start in stride(from: 0, to: uniqueIDs.count, by: 400) {
                try Task.checkCancellation()
                let chunk = Array(uniqueIDs[start..<min(start + 400, uniqueIDs.count)])
                let placeholders = chunk.map { _ in "?" }.joined(separator: ", ")
                let sql = "SELECT * FROM media_items WHERE id IN (\(placeholders)) AND (deletedAt IS NULL OR deletedAt = '')"
                let records = try MediaItemRecord.fetchAll(db, sql: sql, arguments: StatementArguments(chunk.map(\.uuidString)))
                fetchedItems += try self.materializeMediaItems(db: db, records: records,
                    includeMLAttributes: includeMLAttributes, includePerFileOCR: includePerFileOCR,
                    includeVideoSegments: includeVideoSegments, includeTranscriptSegments: includeTranscriptSegments)
            }

            // Preserve caller order (e.g. review deck ordering) after IN-clause fetch.
            let byId = Dictionary(uniqueKeysWithValues: fetchedItems.map { ($0.id, $0) })
            return ids.compactMap { byId[$0] }
        }
    }

    /// Fetch all ML pipeline attributes for an item.
    func fetchAttributes(itemId: UUID) async throws -> [MediaAttribute] {
        try await database.read { db in
            try MediaAttribute.fetchAll(db: db, itemId: itemId)
        }
    }

    /// Fetch attributes for a page of items in bounded IN-clause batches.
    /// Tag-rule evaluation used to issue one database read per item (up to 500
    /// reads per page); callers that process a collection should use this map.
    func fetchAttributes(itemIds: [UUID]) async throws -> [UUID: [MediaAttribute]] {
        let uniqueItemIds = Array(Set(itemIds))
        guard !uniqueItemIds.isEmpty else { return [:] }

        return try await database.read { db in
            var attributesByItem: [UUID: [MediaAttribute]] = [:]
            attributesByItem.reserveCapacity(uniqueItemIds.count)

            // Stay comfortably below SQLite's host-parameter limit, including
            // older/system SQLite builds used by tests and packaged releases.
            let chunkSize = 500
            for start in stride(from: 0, to: uniqueItemIds.count, by: chunkSize) {
                let end = min(start + chunkSize, uniqueItemIds.count)
                let chunk = Array(uniqueItemIds[start..<end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let records = try MediaAttribute.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM media_attributes
                        WHERE item_id IN (\(placeholders))
                        ORDER BY item_id, module, key
                    """,
                    arguments: StatementArguments(chunk.map(\.uuidString))
                )

                for record in records {
                    guard let itemId = UUID(uuidString: record.itemId) else { continue }
                    attributesByItem[itemId, default: []].append(record)
                }
            }

            return attributesByItem
        }
    }

    /// Archive-wide totals for option labels, in one grouped query rather than N counts.
    func fetchPlatformCounts() async throws -> [String: Int] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT CASE WHEN LOWER(platform) IN ('bsky', 'bluesky') THEN 'bluesky'
                       ELSE LOWER(platform) END AS name, COUNT(*) AS total
                FROM media_items
                WHERE (deletedAt IS NULL OR deletedAt = '') AND platform IS NOT NULL AND platform != ''
                GROUP BY name
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { (String($0["name"] as String), $0["total"] as Int) })
        }
    }

    /// Fetch all unique platforms
    func fetchPlatforms() async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT
                        CASE
                            WHEN LOWER(platform) IN ('bsky', 'bluesky') THEN 'bluesky'
                            ELSE platform
                        END AS platform
                    FROM media_items
                    WHERE (deletedAt IS NULL OR deletedAt = '')
                      AND platform IS NOT NULL
                      AND platform != ''
                    ORDER BY platform
                """
            )
        }
    }

    /// Fetch all unique authors
    func fetchAuthors() async throws -> [String] {
        try await database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT author FROM media_items WHERE author IS NOT NULL AND (deletedAt IS NULL OR deletedAt = '') ORDER BY author"
            )
        }
    }

    /// Fetch all unique tags (excludes tags belonging to soft-deleted items)
    func fetchAllTags() async throws -> [String] {
        try await database.read { db in
            // Keep this proportional to the number of lookup rows/tags, not to the
            // whole library's JSON payload. One deterministic live item supplies the
            // user-facing spelling for each canonical junction key.
            let rows = try Row.fetchAll(db, sql: """
                WITH first_live_item AS (
                    SELECT mt.tag, MIN(mt.item_id) AS item_id
                    FROM media_tags mt
                    JOIN media_items mi ON mi.id = mt.item_id
                    WHERE mi.deletedAt IS NULL OR mi.deletedAt = ''
                    GROUP BY mt.tag
                )
                SELECT first_live_item.tag, media_items.tagsJSON
                FROM first_live_item
                JOIN media_items ON media_items.id = first_live_item.item_id
                ORDER BY first_live_item.tag
            """)

            let decoder = JSONDecoder()
            return rows.compactMap { row -> String? in
                let key: String = row["tag"]
                let encoded: String = row["tagsJSON"]
                let tags = (try? decoder.decode([String].self, from: Data(encoded.utf8))) ?? []
                return tags
                    .map(TagCanonicalizer.displayName)
                    .first(where: { TagCanonicalizer.key($0) == key }) ?? key
            }.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        }
    }

    private func ensureTagDefinitionsExist(for tagNames: [String]) async {
        guard !tagNames.isEmpty else { return }
        let _ = await MainActor.run {
            TagSettings.shared.ensureDefinitionsExist(for: tagNames)
        }
    }

    private static func decodePathList(_ json: String, decoder: JSONDecoder) -> [String] {
        let paths = (try? decoder.decode([String].self, from: Data(json.utf8))) ?? []
        return sortPathList(paths)
    }

    private static func sortPathList(_ paths: [String]) -> [String] {
        return paths.sorted {
            URL(fileURLWithPath: $0).lastPathComponent.localizedStandardCompare(
                URL(fileURLWithPath: $1).lastPathComponent
            ) == .orderedAscending
        }
    }

    // MARK: - FTS Index Health

    /// Check FTS index health - returns (indexed count, expected count)
    func checkFTSHealth() async throws -> (indexed: Int, expected: Int) {
        try await database.read { db in
            try MediaItemRecord.checkFTSHealth(db: db)
        }
    }

    /// Rebuild the FTS index from scratch
    func rebuildFTSIndex() async throws {
        try await database.write { db in
            try MediaItemRecord.rebuildFTSIndex(db: db)
        }
    }

    /// Count items matching filter
    func countItems(filter: FilterState = .all) async throws -> Int {
        // Pre-compute hierarchical tag expansion on MainActor before entering database closure
        let tagExpansion = await expandTagsForFilter(filter)

        return try await database.read { db in
            let query = self.buildFilterQueryParts(
                filter: filter,
                tagExpansion: tagExpansion,
                searchMode: .rowIDSubquery
            )
            let sql = self.applyingWhereClause(to: "SELECT COUNT(*) FROM media_items", conditions: query.conditions)

            return try Int.fetchOne(
                db,
                sql: sql,
                arguments: StatementArguments(query.arguments)
            ) ?? 0
        }
    }

    // MARK: - Write Operations

    /// Insert a new item, applying tag rules if engine is available
    func insertItem(_ item: MediaItem) async throws {
        var itemToInsert = item
        let autoTags = await applyTagRules(to: item.metadata)
        if !autoTags.isEmpty {
            let existingTags = Set(itemToInsert.metadata.tags.map(TagCanonicalizer.key))
            let newTags = autoTags.filter { !existingTags.contains(TagCanonicalizer.key($0)) }
            if !newTags.isEmpty {
                itemToInsert.metadata.tags.append(contentsOf: newTags)
                logInfo("Auto-tagged item with: \(newTags.joined(separator: ", "))")
            }
        }
        await ensureTagDefinitionsExist(for: itemToInsert.metadata.tags)
        let record = MediaItemRecord(from: itemToInsert)
        try await database.write { db in
            try record.insertWithFTSSync(db: db)
        }
        await notifyChange()
    }

    /// Batch insert multiple items, skipping duplicates (for initial scan).
    /// Applies tag rules to new items.
    func insertItemsBatch(_ items: [MediaItem]) async throws {
        // Apply tag rules to all items before inserting
        var processedItems: [MediaItem] = []
        for item in items {
            var itemToInsert = item
            let autoTags = await applyTagRules(to: item.metadata)
            if !autoTags.isEmpty {
                let existingTags = Set(itemToInsert.metadata.tags.map(TagCanonicalizer.key))
                let newTags = autoTags.filter { !existingTags.contains(TagCanonicalizer.key($0)) }
                if !newTags.isEmpty {
                    itemToInsert.metadata.tags.append(contentsOf: newTags)
                }
            }
            processedItems.append(itemToInsert)
        }

        await ensureTagDefinitionsExist(for: processedItems.flatMap { $0.metadata.tags })

        let records = processedItems.map { MediaItemRecord(from: $0) }

        // Fetch existing paths in bulk to avoid O(n) per-record lookups.
        let existingPaths = try await existingMetadataFileStrings(for: records.map(\.metadataFileString))

        var skipped = 0
        var seenNewPaths = Set<String>()
        var dedupedRecordsToInsert: [MediaItemRecord] = []
        dedupedRecordsToInsert.reserveCapacity(records.count)

        for record in records {
            let path = record.metadataFileString
            if existingPaths.contains(path) {
                skipped += 1
                continue
            }
            if !seenNewPaths.insert(path).inserted {
                skipped += 1
                continue
            }
            dedupedRecordsToInsert.append(record)
        }
        let recordsToInsert = dedupedRecordsToInsert

        let writeCounts: (inserted: Int, skippedRaces: Int) = try await database.write { db in
            var inserted = 0
            var skippedRaces = 0
            for record in recordsToInsert {
                do {
                    try record.insertWithFTSSync(db: db)
                    inserted += 1
                } catch let error as GRDB.DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
                    // Race with watcher/import inserting same item in parallel.
                    skippedRaces += 1
                }
            }
            return (inserted, skippedRaces)
        }
        let inserted = writeCounts.inserted
        skipped += writeCounts.skippedRaces

        logInfo("Batch insert: \(inserted) new, \(skipped) existing")
        await notifyChange()
    }

    struct StartupScanState: Sendable {
        let itemId: UUID
        let metadataFileString: String
        let mediaFiles: [String]
        let contextImageString: String?
        let cachedFingerprint: MetadataFileFingerprint?
        let cachedMediaFiles: [String]
        let cachedContextImageString: String?

        func matchesDiscoveredFiles(mediaFiles discoveredMediaFiles: [URL], contextImage: URL?) -> Bool {
            let discoveredPaths = MediaStore.sortPathList(discoveredMediaFiles.map(\.path))
            return mediaFiles == discoveredPaths && contextImageString == contextImage?.path
        }

        func matchesCache(fingerprint: MetadataFileFingerprint, mediaFiles discoveredMediaFiles: [URL], contextImage: URL?) -> Bool {
            guard cachedFingerprint == fingerprint else { return false }
            let discoveredPaths = MediaStore.sortPathList(discoveredMediaFiles.map(\.path))
            return cachedMediaFiles == discoveredPaths && cachedContextImageString == contextImage?.path
        }

        /// Fast follow-up after `matchesDiscoveredFiles` has already established
        /// that the discovered paths equal the stored paths. This avoids sorting
        /// the same filesystem result a second time for every startup row.
        func matchesCacheAfterStoredFilesMatch(fingerprint: MetadataFileFingerprint) -> Bool {
            cachedFingerprint == fingerprint
                && cachedMediaFiles == mediaFiles
                && cachedContextImageString == contextImageString
        }
    }

    /// Existing DB state plus the lightweight file fingerprint cache used to avoid
    /// reparsing unchanged sidecars during startup archive discovery.
    func fetchStartupScanStates() async throws -> [String: StartupScanState] {
        let decoder = JSONDecoder()

        return try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    mi.id,
                    mi.metadataFileString,
                    mi.mediaFilesJSON,
                    mi.contextImageString,
                    cache.metadataFileModifiedAt,
                    cache.metadataFileSize,
                    cache.mediaFilesJSON AS cachedMediaFilesJSON,
                    cache.contextImageString AS cachedContextImageString
                FROM media_items mi
                LEFT JOIN archive_scan_cache cache
                    ON cache.metadataFileString = mi.metadataFileString
            """)

            var states: [String: StartupScanState] = [:]
            states.reserveCapacity(rows.count)

            for row in rows {
                guard let idString: String = row["id"],
                      let itemId = UUID(uuidString: idString),
                      let metadataFileString: String = row["metadataFileString"],
                      let mediaFilesJSON: String = row["mediaFilesJSON"] else {
                    continue
                }

                let cachedFingerprint: MetadataFileFingerprint?
                if let modifiedAt: Double = row["metadataFileModifiedAt"],
                   let fileSize: Int64 = row["metadataFileSize"] {
                    cachedFingerprint = MetadataFileFingerprint(modifiedAt: modifiedAt, fileSize: fileSize)
                } else {
                    cachedFingerprint = nil
                }

                let decodedMediaFiles = Self.decodePathList(mediaFilesJSON, decoder: decoder)
                let cachedMediaJSON: String? = row["cachedMediaFilesJSON"]
                let decodedCachedMediaFiles: [String]
                if cachedMediaJSON == mediaFilesJSON {
                    // Normal steady-state rows store the same canonical JSON in
                    // both tables. Reuse the decoded/sorted array instead of
                    // decoding and sorting it twice for every startup item.
                    decodedCachedMediaFiles = decodedMediaFiles
                } else {
                    decodedCachedMediaFiles = cachedMediaJSON
                        .map { Self.decodePathList($0, decoder: decoder) } ?? []
                }
                let state = StartupScanState(
                    itemId: itemId,
                    metadataFileString: metadataFileString,
                    mediaFiles: decodedMediaFiles,
                    contextImageString: row["contextImageString"],
                    cachedFingerprint: cachedFingerprint,
                    cachedMediaFiles: decodedCachedMediaFiles,
                    cachedContextImageString: row["cachedContextImageString"]
                )
                states[metadataFileString] = state
            }

            return states
        }
    }

    func backfillStartupScanCache(_ updates: [(state: StartupScanState, fingerprint: MetadataFileFingerprint)]) async throws {
        guard !updates.isEmpty else { return }

        try await database.write { db in
            let encoder = JSONEncoder()
            for update in updates {
                let state = update.state
                let fingerprint = update.fingerprint
                let mediaFilesJSON = (try? encoder.encode(state.mediaFiles))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                try db.execute(
                    sql: """
                        INSERT INTO archive_scan_cache (
                            metadataFileString, itemId, metadataFileModifiedAt,
                            metadataFileSize, mediaFilesJSON, contextImageString
                        )
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(metadataFileString) DO UPDATE SET
                            itemId = excluded.itemId,
                            metadataFileModifiedAt = excluded.metadataFileModifiedAt,
                            metadataFileSize = excluded.metadataFileSize,
                            mediaFilesJSON = excluded.mediaFilesJSON,
                            contextImageString = excluded.contextImageString
                    """,
                    arguments: [
                        state.metadataFileString,
                        state.itemId.uuidString,
                        fingerprint.modifiedAt,
                        fingerprint.fileSize,
                        mediaFilesJSON,
                        state.contextImageString
                    ]
                )
            }
        }
    }

    /// Update an existing item
    func updateItem(_ item: MediaItem, source: MetadataOutbox.Source = .user) async throws {
        let result = try await database.write { db in
            try self.updateItem(item, source: source, in: db)
        }
        if result.presentationSourcesChanged {
            await ImageCache.shared.clearAll(itemId: item.id)
        }
        await notifyChange(result.becameDeleted ? .deleted([item.id]) : .items([item.id]))
        if source == .user { await writeBackQueue.enqueue(item.id) }
    }

    /// A bounded startup batch shares one transaction and groups UI notifications.
    /// Read stored state at acceptance so derived results and pending edits survive.
    func updateChangedScannedItemsBatch(_ changes: [(parsed: MediaItem, itemID: UUID)]) async throws {
        guard !changes.isEmpty else { return }
        let result = try await database.write { db -> (updated: Set<UUID>, deleted: Set<UUID>, invalidated: Set<UUID>) in
            var updated = Set<UUID>()
            var deleted = Set<UUID>()
            var invalidated = Set<UUID>()
            for change in changes {
                guard let row = try Row.fetchOne(db, sql: "SELECT * FROM media_items WHERE id = ?", arguments: [change.itemID.uuidString]),
                      let existing = try MediaItemRecord(row: row).toMediaItem() else {
                    continue
                }
                let item = AppCoordinator.changedScannedItem(change.parsed, preserving: existing)
                let result = try self.updateItem(item, source: .sidecar, in: db, existingRow: row)
                if result.presentationSourcesChanged {
                    invalidated.insert(item.id)
                }
                if result.becameDeleted {
                    deleted.insert(item.id)
                } else {
                    updated.insert(item.id)
                }
            }
            return (updated, deleted, invalidated)
        }
        for id in result.invalidated {
            await ImageCache.shared.clearAll(itemId: id)
        }
        if !result.updated.isEmpty { await notifyChange(.items(result.updated)) }
        if !result.deleted.isEmpty { await notifyChange(.deleted(result.deleted)) }
    }

    private func updateItem(
        _ item: MediaItem,
        source: MetadataOutbox.Source,
        in db: Database,
        existingRow: Row? = nil
    ) throws -> (presentationSourcesChanged: Bool, becameDeleted: Bool) {
        var currentItem = item
        if source == .sidecar {
            // An async scan can arrive after a newer projection was already
            // acknowledged. Re-read its atomic sidecar at the acceptance
            // boundary rather than trusting that earlier parsed snapshot.
            currentItem.metadata = try MetadataParser.parse(fileAt: item.metadataFile)
        }
        var record = MediaItemRecord(from: currentItem)
        if source == .sidecar, record.deletedAt != nil, record.deletionReason == nil {
            record.deletionReason = MediaItemDeletionReason.user.rawValue
        }
        var presentationSourcesChanged = false
        var wasDeleted = false
        if let existing = try existingRow ?? Row.fetchOne(
            db,
            sql: "SELECT deletedAt, deletionReason, mediaFilesJSON, contextImageString FROM media_items WHERE id = ?",
            arguments: [item.id.uuidString]
        ) {
            let existingDeletedAt: Date? = existing["deletedAt"]
            wasDeleted = existingDeletedAt != nil
            let existingReason: String? = existing["deletionReason"]
            let existingMediaFilesJSON: String = existing["mediaFilesJSON"]
            let existingContextImageString: String? = existing["contextImageString"]
            presentationSourcesChanged = existingMediaFilesJSON != record.mediaFilesJSON
                || existingContextImageString != record.contextImageString

            // A stale view model or sidecar refresh must never resurrect or
            // reclassify a tombstone. Restoring is an explicit operation; an
            // old sidecar or full-item snapshot is not restoration authority.
            if existingReason == MediaItemDeletionReason.combined.rawValue {
                if source == .sidecar {
                    // Keep the merge's ownership evidence even when discovery
                    // assigns these files to the surviving item's sidecar.
                    currentItem.mediaFiles = Self.decodePathList(existingMediaFilesJSON, decoder: JSONDecoder())
                        .map { URL(fileURLWithPath: $0) }
                    currentItem.contextImage = existingContextImageString.map { URL(fileURLWithPath: $0) }
                    record = MediaItemRecord(from: currentItem)
                    presentationSourcesChanged = false
                }
                record.deletedAt = existingDeletedAt ?? Date()
                record.deletionReason = MediaItemDeletionReason.combined.rawValue
            } else if existingReason == MediaItemDeletionReason.contextReattached.rawValue {
                record.deletedAt = existingDeletedAt
                record.deletionReason = existingReason
            } else if let existingDeletedAt {
                record.deletedAt = existingDeletedAt
                record.deletionReason = existingReason
            }
        }
        if source == .sidecar {
            // Read pending fields inside the import transaction, not from a
            // stale watcher snapshot. Unrelated external fields still merge.
            let pending = Set(try String.fetchAll(db, sql: "SELECT field FROM metadata_outbox WHERE itemID = ? AND state != 'synced'", arguments: [item.id.uuidString]))
            let current: MediaItemRecord?
            if let existingRow {
                current = try MediaItemRecord(row: existingRow)
            } else {
                current = try MediaItemRecord.fetchOne(db, key: item.id.uuidString)
            }
            if let current {
                if pending.contains("tags") { record.tagsJSON = current.tagsJSON }
                if pending.contains("notes") { record.notes = current.notes }
                if pending.contains("starred") { record.starred = current.starred }
                if pending.contains("deleted") {
                    record.deletedAt = current.deletedAt
                    record.deletionReason = current.deletionReason
                }
            }
            try MetadataOutbox.importing(in: db) { try record.updateWithFTSSync(db: db) }
        } else {
            try record.updateWithFTSSync(db: db)
        }
        // Publish the accepted state after pending local recovery has been merged.
        return (presentationSourcesChanged, !wasDeleted && record.deletedAt != nil)
    }

    /// Persist the UI-only choice of which existing file role leads presentation.
    /// This deliberately avoids rewriting sidecars or swapping any stored file paths.
    func setPreferredDisplayRole(itemId: UUID, prefersContextImage: Bool) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE media_items SET prefersContextImage = ? WHERE id = ?",
                arguments: [prefersContextImage, itemId.uuidString]
            )
        }
        await notifyChange(.items([itemId]))
    }

    /// Legacy ordinal adapter. Reconcile persistent identities without deleting
    /// removed-file data or applying a second positional shift.
    func reindexPerFileData(itemID: UUID, removedIndex: Int) async throws {
        try await database.write { db in
            // Compatibility adapter: the media mutation already remaps by asset
            // identity transactionally. Repeating an ordinal shift would corrupt it.
            try ItemAssetStore.reconcile(in: db, itemID: itemID.uuidString)
        }
    }

    func fetchAssets(itemID: UUID) async throws -> [ItemAsset] {
        try await database.read { db in try ItemAssetStore.fetchBatch(in: db, itemIDs: [itemID])[itemID] ?? [] }
    }

    func refreshAssets(itemID: UUID) async throws {
        try await database.write { db in try ItemAssetStore.reconcile(in: db, itemID: itemID.uuidString) }
        await notifyChange(.items([itemID]))
    }

    func assetAssociationIssues(itemID: UUID? = nil) async throws -> [ItemAssetStore.AssociationIssue] {
        try await database.read { db in try ItemAssetStore.issues(in: db, itemID: itemID) }
    }

    func retainedAnnotationContent(recordID: String) async throws -> String? {
        try await database.read { db in
            try String.fetchOne(db, sql: "SELECT annotationsJSON FROM annotations WHERE id = ? AND association_state != 'attached'", arguments: [recordID])
        }
    }

    func reattachAnnotation(recordID: String, itemID: UUID, to assetID: UUID) async throws {
        try await database.write { db in
            guard let record = try Row.fetchOne(db, sql: "SELECT * FROM annotations WHERE id = ? AND itemId = ? AND association_state != 'attached'", arguments: [recordID, itemID.uuidString]) else { throw ItemAssetStore.AssociationError.staleAsset }
            let asset = try ItemAssetStore.prepareWrite(in: db, itemID: itemID, assetID: assetID, index: 0)
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM annotations WHERE itemId = ? AND asset_id = ? AND association_state = 'attached')", arguments: [itemID.uuidString, asset.id.uuidString]) == true { throw ItemAssetStore.AssociationError.occupiedAsset }
            try db.execute(sql: "INSERT INTO asset_association_resolutions(record_id, previous_asset_id, selected_asset_id, previous_state) VALUES (?, ?, ?, ?)", arguments: [recordID, record["asset_id"] as String?, asset.id.uuidString, record["association_state"] as String])
            try db.execute(sql: "UPDATE annotations SET asset_id = ?, mediaFileIndex = ?, association_state = 'attached' WHERE id = ?", arguments: [asset.id.uuidString, asset.index, recordID])
        }
        await writeBackQueue.enqueue(itemID)
        await notifyChange(.items([itemID]))
    }

    func removeAsset(itemID: UUID, assetID: UUID) async throws -> MediaItem {
        try await database.write { db in
            let assets = try ItemAssetStore.fetchBatch(in: db, itemIDs: [itemID])[itemID] ?? []
            guard let selected = assets.first(where: { $0.assetID == assetID && $0.role == .media }) else {
                throw ItemAssetStore.AssociationError.staleAsset
            }
            let paths = assets.filter { $0.role == .media && $0.assetID != selected.assetID }.sorted { $0.order < $1.order }.map(\.url.path)
            let json = String(decoding: try JSONEncoder().encode(paths), as: UTF8.self)
            try db.execute(sql: "UPDATE media_items SET mediaFilesJSON = ? WHERE id = ?", arguments: [json, itemID.uuidString])
            try ItemAssetStore.reconcile(in: db, itemID: itemID.uuidString)
        }
        await notifyChange(.items([itemID]))
        guard let item = try await fetchItem(id: itemID) else { throw ItemAssetStore.AssociationError.staleAsset }
        return item
    }

    func reorderAssets(itemID: UUID, orderedAssetIDs: [UUID]) async throws {
        try await database.write { db in
            let assets = try ItemAssetStore.fetchBatch(in: db, itemIDs: [itemID])[itemID]?.filter { $0.role == .media } ?? []
            guard orderedAssetIDs.count == assets.count, Set(orderedAssetIDs) == Set(assets.map(\.assetID)) else { throw ItemAssetStore.AssociationError.staleAsset }
            let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.assetID, $0.url.path) })
            let paths = orderedAssetIDs.compactMap { byID[$0] }
            let json = String(decoding: try JSONEncoder().encode(paths), as: UTF8.self)
            try db.execute(sql: "UPDATE media_items SET mediaFilesJSON = ? WHERE id = ?", arguments: [json, itemID.uuidString])
            try ItemAssetStore.reconcile(in: db, itemID: itemID.uuidString)
        }
        await notifyChange(.items([itemID]))
    }

    /// Delete an item by ID
    /// Moves files to system Trash (recoverable) before removing from DB
    func deleteItem(id: UUID, preservePendingMetadata: Bool = false) async throws {
        var filesToTrash: [URL] = []

        // Fetch file paths before deleting from DB
        try await database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT metadataFileString, mediaFilesJSON FROM media_items WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return }

            // Add sidecar .md file
            if let mdPath: String = row["metadataFileString"], !mdPath.isEmpty {
                filesToTrash.append(URL(fileURLWithPath: mdPath))
            }

            // Add media files
            if let mediaJSON: String = row["mediaFilesJSON"],
               let paths = try? JSONDecoder().decode([String].self, from: Data(mediaJSON.utf8)) {
                filesToTrash.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
            }
        }

        // Delete from DB
        let didDelete = try await database.write { db -> Bool in
            if preservePendingMetadata,
               try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM metadata_outbox WHERE itemID = ? AND state != 'synced')", arguments: [id.uuidString]) == true {
                return false
            }
            try MediaItemRecord.deleteFromFTS(db: db, id: id)
            try db.execute(
                sql: "DELETE FROM media_items WHERE id = ?",
                arguments: [id.uuidString]
            )
            return true
        }
        guard didDelete else { return }

        // Move files to system Trash (recoverable)
        await MainActor.run {
            for url in filesToTrash where FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.recycle([url]) { trashedURLs, error in
                    if let error = error {
                        Log.warning("Failed to trash \(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        }

        // GAP #9 fix: Clear cached thumbnails for deleted item
        await ImageCache.shared.clearAll(itemId: id)

        await notifyChange(.deleted([id]))
    }

    /// Remove a tag from ALL items globally (used when deleting a tag definition)
    /// GAP #1 fix: Cascade tag deletion to items
    @discardableResult
    func removeTagGlobally(tag: String) async throws -> [UUID] {
        let lowered = TagCanonicalizer.key(tag)
        guard !lowered.isEmpty else { return [] }
        let affectedIds = try await database.write { db -> [UUID] in
            // The junction is the canonical lookup source. Fetch affected JSON rows before
            // deleting it so mixed-case presentation tags are updated too.
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT media_items.id, media_items.tagsJSON
                FROM media_items
                JOIN media_tags ON media_tags.item_id = media_items.id
                WHERE media_tags.tag = ?
            """, arguments: [lowered])

            try db.execute(
                sql: "DELETE FROM media_tags WHERE tag = ?",
                arguments: [lowered]
            )

            var ids: [UUID] = []
            for row in rows {
                guard let idStr = row["id"] as? String,
                      let tagsJSON = row["tagsJSON"] as? String else { continue }

                if let id = UUID(uuidString: idStr) {
                    ids.append(id)
                }

                // Parse, filter, re-encode
                if var tags = try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8)) {
                    tags.removeAll {
                        TagCanonicalizer.key($0) == lowered
                    }
                    if let newJSON = try? JSONEncoder().encode(tags),
                       let newStr = String(data: newJSON, encoding: .utf8) {
                        try db.execute(
                            sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                            arguments: [newStr, idStr]
                        )
                    }
                }
            }
            return ids
        }
        if !affectedIds.isEmpty {
            await writeBackQueue.enqueue(affectedIds)
        }
        await notifyChange()
        return affectedIds
    }

    /// Remove a hierarchy's exact tag references in one transaction. A failed member
    /// must not leave earlier members removed without an undoable action.
    /// Returned keys are canonical tag names; values capture only affected items.
    func removeTagsGlobally(tags: [String]) async throws -> [String: [UUID]] {
        let keys = Set(tags.map(TagCanonicalizer.key).filter { !$0.isEmpty }).sorted()
        guard !keys.isEmpty else { return [:] }
        let affected = try await database.write { db -> [String: [UUID]] in
            var result: [String: [UUID]] = [:]
            for key in keys {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT media_items.id, media_items.tagsJSON
                    FROM media_items JOIN media_tags ON media_tags.item_id = media_items.id
                    WHERE media_tags.tag = ?
                    """, arguments: [key])
                var ids: [UUID] = []
                for row in rows {
                    let rawID: String = row["id"]
                    let json: String = row["tagsJSON"]
                    var itemTags = try JSONDecoder().decode([String].self, from: Data(json.utf8))
                    itemTags.removeAll { TagCanonicalizer.key($0) == key }
                    let encoded = String(decoding: try JSONEncoder().encode(itemTags), as: UTF8.self)
                    try db.execute(sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?", arguments: [encoded, rawID])
                    if let id = UUID(uuidString: rawID) { ids.append(id) }
                }
                try db.execute(sql: "DELETE FROM media_tags WHERE tag = ?", arguments: [key])
                result[key] = ids
            }
            return result
        }
        let ids = Array(Set(affected.values.flatMap { $0 }))
        if !ids.isEmpty { await writeBackQueue.enqueue(ids) }
        await notifyChange()
        return affected
    }

    /// Atomically restore captured hierarchy assignments. Definition snapshots are
    /// restored by the undo action only after this succeeds, not by this method.
    func restoreTagAssignments(_ assignments: [String: [UUID]]) async throws {
        let updatedIDs = try await database.write { db -> [UUID] in
            var updated = Set<UUID>()
            for name in assignments.keys.sorted() {
                let display = TagCanonicalizer.displayName(name)
                let key = TagCanonicalizer.key(display)
                guard !key.isEmpty else { continue }
                for id in Set(assignments[name] ?? []) {
                    guard let row = try Row.fetchOne(db, sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                                                    arguments: [id.uuidString]) else { continue }
                    let json: String = row["tagsJSON"]
                    var itemTags = try JSONDecoder().decode([String].self, from: Data(json.utf8))
                    try db.execute(sql: "INSERT OR IGNORE INTO media_tags (item_id, tag) VALUES (?, ?)",
                                   arguments: [id.uuidString, key])
                    if !itemTags.contains(where: { TagCanonicalizer.key($0) == key }) {
                        itemTags.append(display)
                        let encoded = String(decoding: try JSONEncoder().encode(itemTags), as: UTF8.self)
                        try db.execute(sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?", arguments: [encoded, id.uuidString])
                        updated.insert(id)
                    }
                }
            }
            return Array(updated)
        }
        if !updatedIDs.isEmpty { await writeBackQueue.enqueue(updatedIDs) }
        await notifyChange()
    }

    /// Count exact tag references using the same canonical key as global tag removal.
    /// Unlike sidebar filter counts, this deliberately does not include descendant tags.
    func countItemsTaggedExactly(tag: String) async throws -> Int {
        let key = TagCanonicalizer.key(tag)
        guard !key.isEmpty else { return 0 }
        return try await database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT media_items.id)
                FROM media_items
                JOIN media_tags ON media_tags.item_id = media_items.id
                WHERE media_tags.tag = ?
            """, arguments: [key]) ?? 0
        }
    }

    /// Rename a tag across ALL items globally (used when renaming a tag definition)
    /// Updates the junction table and tagsJSON on affected items.
    func renameTagGlobally(oldName: String, newName: String) async throws {
        let oldLower = TagCanonicalizer.key(oldName)
        let newDisplayName = TagCanonicalizer.displayName(newName)
        let newLower = TagCanonicalizer.key(newDisplayName)
        guard !oldLower.isEmpty, !newLower.isEmpty else { return }

        let affectedIds = try await database.write { db -> [UUID] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT media_items.id, media_items.tagsJSON
                FROM media_items
                JOIN media_tags ON media_tags.item_id = media_items.id
                WHERE media_tags.tag = ?
            """, arguments: [oldLower])

            if oldLower != newLower {
                // Delete + INSERT OR IGNORE safely handles an item that already carries the
                // destination tag; a direct UPDATE would violate the junction primary key.
                try db.execute(
                    sql: "DELETE FROM media_tags WHERE tag = ?",
                    arguments: [oldLower]
                )
            }

            var ids: [UUID] = []
            for row in rows {
                guard let idStr = row["id"] as? String,
                      let tagsJSON = row["tagsJSON"] as? String else { continue }

                if let id = UUID(uuidString: idStr) {
                    ids.append(id)
                }

                if oldLower != newLower {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO media_tags (item_id, tag) VALUES (?, ?)",
                        arguments: [idStr, newLower]
                    )
                }

                if let decoded = try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8)) {
                    var seen = Set<String>()
                    let tags = decoded.compactMap { existing -> String? in
                        let normalized = TagCanonicalizer.key(existing)
                        let replacement = normalized == oldLower ? newDisplayName : existing
                        let replacementKey = TagCanonicalizer.key(replacement)
                        guard !replacementKey.isEmpty, seen.insert(replacementKey).inserted else {
                            return nil
                        }
                        return replacement
                    }
                    if let newJSON = try? JSONEncoder().encode(tags),
                       let newStr = String(data: newJSON, encoding: .utf8) {
                        try db.execute(
                            sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                            arguments: [newStr, idStr]
                        )
                    }
                }
            }
            return ids
        }
        if !affectedIds.isEmpty {
            await writeBackQueue.enqueue(affectedIds)
        }
        await notifyChange()
    }

    /// Rename tag references in tag_rules table (cascade from TagSettings rename)
    func renameTagInRules(oldName: String, newName: String) async throws {
        guard let engine = await tagRuleEngine else { return }
        try await engine.renameTagInRules(oldName: oldName, newName: newName)
    }

    /// Apply tag rules to metadata, returning tags to add.
    /// Runs on MainActor because TagRuleEngine is MainActor-isolated.
    @MainActor
    private func applyTagRules(to metadata: MediaMetadata) -> [String] {
        guard let engine = tagRuleEngine else { return [] }
        return engine.evaluateRules(for: metadata)
    }

    /// Backfill source context columns from re-parsed sidecar metadata.
    /// Used by applyRulesToAll to fix items that had NULL source context after migration 23.
    func updateSourceContext(id: UUID, metadata: MediaMetadata) async throws {
        let sourceTagsJSON: String? = metadata.sourceTags.flatMap { tags in
            (try? JSONEncoder().encode(tags)).flatMap { String(data: $0, encoding: .utf8) }
        }
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE media_items SET
                        subreddit = ?, boardName = ?, blogName = ?,
                        channelName = ?, artistName = ?, galleryName = ?,
                        sourceTagsJSON = ?, uploadDate = ?,
                        viewCount = ?, likeCount = ?
                    WHERE id = ?
                    """,
                arguments: [
                    metadata.subreddit, metadata.boardName, metadata.blogName,
                    metadata.channelName, metadata.artistName, metadata.galleryName,
                    sourceTagsJSON, metadata.uploadDate,
                    metadata.viewCount, metadata.likeCount,
                    id.uuidString
                ]
            )
        }
    }

    /// Toggle starred state for an item
    func toggleStar(id: UUID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE media_items SET starred = NOT starred WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
        await writeBackQueue.enqueue(id)
        await notifyChange(.items([id]))
    }

    /// Set starred state for an item (explicit value for batch operations)
    func setStar(id: UUID, starred: Bool) async throws {
        try await database.write { db in
            try db.execute(
                sql: "UPDATE media_items SET starred = ? WHERE id = ?",
                arguments: [starred, id.uuidString]
            )
        }
        await writeBackQueue.enqueue(id)
        await notifyChange(.items([id]))
    }

    /// Get starred state for multiple items (GAP #12 fix: for batch undo pre-state capture)
    func getStarredStates(ids: [UUID]) async throws -> [UUID: Bool] {
        try await database.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, starred FROM media_items WHERE id IN (\(placeholders))
            """, arguments: StatementArguments(ids.map(\.uuidString)))

            var result: [UUID: Bool] = [:]
            for row in rows {
                if let idStr = row["id"] as? String,
                   let id = UUID(uuidString: idStr),
                   let starred = row["starred"] as? Bool {
                    result[id] = starred
                }
            }
            return result
        }
    }

    /// Get which items have a specific tag (GAP #12 fix: for batch undo pre-state capture)
    func getItemsWithTag(ids: [UUID], tag: String) async throws -> Set<UUID> {
        try await database.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            var arguments: [DatabaseValueConvertible] = [TagCanonicalizer.key(tag)]
            arguments.append(contentsOf: ids.map(\.uuidString))

            let rows = try Row.fetchAll(db, sql: """
                SELECT item_id FROM media_tags
                WHERE tag = ? AND item_id IN (\(placeholders))
            """, arguments: StatementArguments(arguments))

            var result = Set<UUID>()
            for row in rows {
                if let idStr = row["item_id"] as? String,
                   let id = UUID(uuidString: idStr) {
                    result.insert(id)
                }
            }
            return result
        }
    }

    /// Soft delete items while preserving all derived analysis for recovery.
    func softDelete(ids: [UUID]) async throws {
        try await softDelete(ids: ids, reason: .user)
    }

    func softDelete(ids: [UUID], reason: MediaItemDeletionReason) async throws {
        guard !ids.isEmpty else { return }
        try await softDeleteInternal(ids: ids, reason: reason)
        await writeBackQueue.enqueue(ids)
        await notifyChange(.deleted(Set(ids)))
    }

    /// A vanished sidecar is not permission to discard its item or media: it is usually a
    /// rename/move whose old path can no longer be stat'ed for inode pairing. Hide the item as
    /// missing-files (restorable) without sidecar write-back, which would resurrect the old path.
    func markSidecarMissing(id: UUID) async throws {
        if try await fetchItem(id: id)?.deletionReason == .contextReattached { return }
        try await softDeleteInternal(ids: [id], reason: .missingFiles)
        await notifyChange(.deleted([id]))
    }

    /// Re-attach a moved sidecar to its unique owner, including an offline rename of an active item.
    func adoptMovedSidecar(at url: URL, mediaFiles: [URL]) async throws -> UUID? {
        try await adoptMovedSidecars([(url: url, mediaFiles: mediaFiles)])[url.path]
    }

    /// Match a batch once by exact media sets, rather than scanning the DB for each new sidecar.
    /// Both the missing owner and the incoming sidecar must be unambiguous. User/combined
    /// deletions are never restoration candidates, and an empty media set proves no identity.
    func adoptMovedSidecars(_ sidecars: [(url: URL, mediaFiles: [URL])]) async throws -> [String: UUID] {
        let incoming = Dictionary(grouping: sidecars.filter { !$0.mediaFiles.isEmpty }) {
            Set($0.mediaFiles.map(\.path))
        }
        guard !incoming.isEmpty else { return [:] }
        let adopted: [String: UUID] = try await database.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, metadataFileString, mediaFilesJSON, deletedAt, deletionReason FROM media_items
                """)
            let knownPaths = Set(rows.map { $0["metadataFileString"] as String })
            let decoder = JSONDecoder()
            var candidates: [Set<String>: [(id: UUID, path: String)]] = [:]
            for row in rows {
                let deletedAt: String? = row["deletedAt"]
                let reason: String? = row["deletionReason"]
                guard deletedAt == nil || deletedAt == "" || reason == MediaItemDeletionReason.missingFiles.rawValue else { continue }
                let oldPath: String = row["metadataFileString"]
                let json: String = row["mediaFilesJSON"]
                guard let paths = try? decoder.decode([String].self, from: Data(json.utf8)),
                      let idString: String = row["id"],
                      let id = UUID(uuidString: idString) else { continue }
                let mediaPaths = Set(paths)
                // Only stat owners whose media set appears in this batch.
                guard incoming[mediaPaths] != nil,
                      !FileManager.default.fileExists(atPath: oldPath) else { continue }
                candidates[mediaPaths, default: []].append((id, oldPath))
            }

            var result: [String: UUID] = [:]
            for (mediaPaths, sidecars) in incoming {
                guard sidecars.count == 1,
                      let matches = candidates[mediaPaths], matches.count == 1 else { continue }
                let url = sidecars[0].url
                let match = matches[0]
                guard !knownPaths.contains(url.path),
                      FileManager.default.fileExists(atPath: url.path),
                      !FileManager.default.fileExists(atPath: match.path) else { continue }
                // Startup rows use a sidecar stem; imported/runtime rows use the folder.
                // Sidecars aren't item assets: update only the owner/cache, avoiding
                // updateFilePath's asset-table scan and any unchanged media rewrites.
                try db.execute(
                    sql: """
                        UPDATE media_items SET metadataFileString = ?, deletedAt = NULL, deletionReason = NULL,
                            basePathString = CASE WHEN basePathString = ? THEN ? ELSE basePathString END
                        WHERE id = ?
                        """,
                    arguments: [url.path, URL(fileURLWithPath: match.path).deletingPathExtension().path,
                                url.deletingPathExtension().path, match.id.uuidString]
                )
                try db.execute(
                    sql: "UPDATE archive_scan_cache SET metadataFileString = ? WHERE metadataFileString = ?",
                    arguments: [url.path, match.path]
                )
                result[url.path] = match.id
            }
            return result
        }
        if !adopted.isEmpty { await notifyChange() }
        return adopted
    }

    /// Publish a duplicate-review transaction through this shared store without
    /// repeating its already-committed item mutations.
    func didCommitDuplicateReview(itemIDs: [UUID]) async {
        await writeBackQueue.enqueue(itemIDs)
        await notifyChange()
    }

    /// Internal soft-delete without notification (for batch callers that notify once at the end)
    private func softDeleteInternal(
        ids: [UUID],
        reason: MediaItemDeletionReason = .missingFiles
    ) async throws {
        guard !ids.isEmpty else { return }
        try await database.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            var arguments: [DatabaseValueConvertible] = [Date(), reason.rawValue]
            arguments.append(contentsOf: ids.map(\.uuidString))

            try db.execute(
                sql: """
                    UPDATE media_items
                    SET deletedAt = ?,
                        deletionReason = CASE
                            WHEN deletionReason IN ('combined', 'contextReattached') THEN deletionReason
                            ELSE ?
                        END
                    WHERE id IN (\(placeholders))
                    """,
                arguments: StatementArguments(arguments)
            )
        }
    }

    /// Result of filesystem reconciliation at startup
    struct ReconciliationResult {
        let regeneratedCount: Int   // .md sidecars regenerated from DB data
        let softDeletedCount: Int   // items with no files at all, soft-deleted
        let skipped: Bool           // true when cached signature indicates no work needed
    }

    /// Reconcile DB against filesystem: regenerate missing sidecars when media exists, soft-delete when nothing remains.
    func reconcileOrphans() async throws -> ReconciliationResult {
        let startupTime = Date()
        let signature = try? await fetchReconciliationSignature()

        if let signature, await shouldSkipReconciliation(for: signature, now: startupTime) {
            return ReconciliationResult(regeneratedCount: 0, softDeletedCount: 0, skipped: true)
        }

        // Fetch all non-deleted items with metadata needed for sidecar regeneration
        struct OrphanCandidate: Sendable {
            let id: UUID
            let metadataPath: String
            let mediaFilesJSON: String
            let contextImageString: String?
            let tagsJSON: String
            let sourceURL: String
            let platform: String
            let author: String?
            let originalDate: Date?
            let archivedDate: Date
            let downloadDate: Date?
            let importDate: Date?
            let uploadDate: Date?
            let starred: Bool
            let notes: String?
        }

        let candidates: [OrphanCandidate] = try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, metadataFileString, mediaFilesJSON, contextImageString, tagsJSON,
                       sourceURL, platform, author, originalDate, archivedDate,
                       downloadDate, importDate, uploadDate, starred, notes
                FROM media_items
                WHERE (deletedAt IS NULL OR deletedAt = '')
            """)
            return rows.compactMap { row in
                guard let idStr: String = row["id"],
                      let id = UUID(uuidString: idStr),
                      let path: String = row["metadataFileString"],
                      let mediaJSON: String = row["mediaFilesJSON"],
                      let sourceURL: String = row["sourceURL"],
                      let platform: String = row["platform"],
                      let archivedDate: Date = row["archivedDate"] else { return nil }
                return OrphanCandidate(
                    id: id,
                    metadataPath: path,
                    mediaFilesJSON: mediaJSON,
                    contextImageString: row["contextImageString"],
                    tagsJSON: row["tagsJSON"],
                    sourceURL: sourceURL,
                    platform: platform,
                    author: row["author"],
                    originalDate: row["originalDate"],
                    archivedDate: archivedDate,
                    downloadDate: row["downloadDate"],
                    importDate: row["importDate"],
                    uploadDate: row["uploadDate"],
                    starred: row["starred"] ?? false,
                    notes: row["notes"]
                )
            }
        }

        // Filter to items whose .md is missing
        let fm = FileManager.default
        let orphans = candidates.filter { !fm.fileExists(atPath: $0.metadataPath) }

        guard !orphans.isEmpty else {
            if let signature = signature {
                await recordReconciliationSnapshot(signature: signature, now: startupTime)
            }
            return ReconciliationResult(regeneratedCount: 0, softDeletedCount: 0, skipped: false)
        }

        var toRegenerate: [OrphanCandidate] = []
        var toSoftDelete: [UUID] = []

        for item in orphans {
            // Check if any media files still exist on disk
            let mediaFiles = (try? JSONDecoder().decode([String].self, from: Data(item.mediaFilesJSON.utf8))) ?? []
            let contextImage = item.contextImageString

            let anyMediaExists = mediaFiles.contains { fm.fileExists(atPath: $0) }
            let contextExists = contextImage.map { fm.fileExists(atPath: $0) } ?? false

            if anyMediaExists || contextExists {
                toRegenerate.append(item)
            } else {
                toSoftDelete.append(item.id)
            }
        }

        // Regenerate sidecars from DB data
        var regeneratedCount = 0
        if !toRegenerate.isEmpty {
            let dateFormatter = ISO8601DateFormatter()

            for item in toRegenerate {
                let tags = (try? JSONDecoder().decode([String].self, from: Data(item.tagsJSON.utf8))) ?? []
                let mdURL = URL(fileURLWithPath: item.metadataPath)

                // Ensure parent directory exists
                let parentDir = mdURL.deletingLastPathComponent()
                if !fm.fileExists(atPath: parentDir.path) {
                    try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }

                // Build frontmatter using Yams.dump for proper escaping
                var yaml: [String: Any] = [
                    "source": item.sourceURL,
                    "platform": item.platform,
                    "archived": dateFormatter.string(from: item.archivedDate),
                    "tags": tags,
                ]
                if let originalDate = item.originalDate {
                    yaml["date"] = dateFormatter.string(from: originalDate)
                }
                if let downloadDate = item.downloadDate {
                    yaml["download_date"] = dateFormatter.string(from: downloadDate)
                }
                if let importDate = item.importDate {
                    yaml["import_date"] = dateFormatter.string(from: importDate)
                }
                if let uploadDate = item.uploadDate {
                    yaml["upload_date"] = dateFormatter.string(from: uploadDate)
                }
                if let author = item.author, !author.isEmpty {
                    yaml["author"] = author
                }
                if item.starred {
                    yaml["starred"] = true
                }
                if let notes = item.notes, !notes.isEmpty {
                    yaml["notes"] = notes
                }
                let serialized = try Yams.dump(object: yaml, allowUnicode: true, sortKeys: true)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let frontmatter = "---\n\(serialized)\n---\n"

                do {
                    try frontmatter.write(to: mdURL, atomically: true, encoding: .utf8)
                    regeneratedCount += 1
                    logInfo("Reconciliation: regenerated sidecar at \(item.metadataPath)")
                } catch {
                    logError("Reconciliation: failed to regenerate sidecar at \(item.metadataPath): \(error)")
                    // Fall back to soft-delete if we can't write the sidecar
                    toSoftDelete.append(item.id)
                }
            }
        }

        // Soft-delete items with no files at all, in batches of 500 (no notification per batch)
        if !toSoftDelete.isEmpty {
            for batch in stride(from: 0, to: toSoftDelete.count, by: 500) {
                let end = min(batch + 500, toSoftDelete.count)
                let batchIds = Array(toSoftDelete[batch..<end])
                try await softDeleteInternal(ids: batchIds)
            }
            // Enqueue all for write-back once, single notification
            await writeBackQueue.enqueue(toSoftDelete)
            await notifyChange()
        }

        if let postRunSignature = try? await fetchReconciliationSignature() {
            await recordReconciliationSnapshot(signature: postRunSignature, now: startupTime)
        } else if let signature = signature {
            await recordReconciliationSnapshot(signature: signature, now: startupTime)
        }

        return ReconciliationResult(
            regeneratedCount: regeneratedCount,
            softDeletedCount: toSoftDelete.count,
            skipped: false
        )
    }

    private struct ReconciliationSignature: Sendable {
        let activeItemCount: Int
        let latestArchivedEpoch: Int64
        let maxMetadataPath: String
        let totalMediaJSONLength: Int

        var value: String {
            "\(activeItemCount)|\(latestArchivedEpoch)|\(maxMetadataPath)|\(totalMediaJSONLength)"
        }
    }

    private struct ReconciliationSnapshot: Codable {
        let dbPath: String
        let signature: String
        let timestamp: Date
    }

    private static let reconciliationSnapshotKey = "mediaStore.reconcileOrphans.snapshot.v1"
    /// Avoid full filesystem reconciliation if nothing relevant changed very recently.
    private static let reconciliationCacheWindow: TimeInterval = 60 * 60

    private func fetchReconciliationSignature() async throws -> ReconciliationSignature {
        try await database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        COUNT(*) AS active_count,
                        CAST(COALESCE(MAX(strftime('%s', archivedDate)), '0') AS INTEGER) AS latest_archived_epoch,
                        COALESCE(MAX(metadataFileString), '') AS max_metadata_path,
                        COALESCE(SUM(LENGTH(mediaFilesJSON)), 0) AS total_media_json_length
                    FROM media_items
                    WHERE (deletedAt IS NULL OR deletedAt = '')
                """
            )

            return ReconciliationSignature(
                activeItemCount: row?["active_count"] ?? 0,
                latestArchivedEpoch: row?["latest_archived_epoch"] ?? 0,
                maxMetadataPath: row?["max_metadata_path"] ?? "",
                totalMediaJSONLength: row?["total_media_json_length"] ?? 0
            )
        }
    }

    private func shouldSkipReconciliation(for signature: ReconciliationSignature, now: Date) async -> Bool {
        let dbPath = await database.databasePath
        guard let data = UserDefaults.standard.data(forKey: Self.reconciliationSnapshotKey),
              let snapshot = try? JSONDecoder().decode(ReconciliationSnapshot.self, from: data),
              snapshot.dbPath == dbPath,
              snapshot.signature == signature.value else {
            return false
        }

        return now.timeIntervalSince(snapshot.timestamp) < Self.reconciliationCacheWindow
    }

    private func recordReconciliationSnapshot(signature: ReconciliationSignature, now: Date) async {
        let dbPath = await database.databasePath
        let snapshot = ReconciliationSnapshot(
            dbPath: dbPath,
            signature: signature.value,
            timestamp: now
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.reconciliationSnapshotKey)
    }

    /// Result of filesystem sync operation
    struct FilesystemSyncResult: Sendable {
        let scannedCount: Int           // total items checked
        let softDeletedCount: Int       // items soft-deleted (media files missing)
        let cleanedUpCount: Int         // items with dead media refs cleaned (context image kept)
        let duplicateGroupsPruned: Int  // duplicate groups cleaned up
    }

    /// Sync database with filesystem: soft-delete items whose media files no longer exist.
    /// Use after manually deleting files in Finder to clean up stale DB entries.
    /// Also prunes duplicate groups that reference deleted items.
    ///
    /// Memory-optimized: processes items in batches to avoid loading entire library at once.
    func syncWithFilesystem() async throws -> FilesystemSyncResult {
        let batchSize = 1000
        var totalScanned = 0
        var toSoftDelete: [UUID] = []
        var toCleanup: [UUID] = []  // Items where primary media gone but context survives

        let fm = FileManager.default
        // Reuse decoder to avoid allocation per item
        let decoder = JSONDecoder()

        // Process in batches to limit memory usage for large libraries
        var offset = 0
        while true {
            let batch: [(id: UUID, mediaFilesJSON: String, contextImageString: String?)] = try await database.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id, mediaFilesJSON, contextImageString
                        FROM media_items
                        WHERE (deletedAt IS NULL OR deletedAt = '')
                        ORDER BY id
                        LIMIT ? OFFSET ?
                    """,
                    arguments: [batchSize, offset]
                )
                return rows.compactMap { row -> (UUID, String, String?)? in
                    guard let idString: String = row["id"],
                          let id = UUID(uuidString: idString),
                          let mediaJSON: String = row["mediaFilesJSON"] else { return nil }
                    return (id, mediaJSON, row["contextImageString"])
                }
            }

            if batch.isEmpty { break }
            totalScanned += batch.count
            offset += batchSize

            for item in batch {
                // Parse media files from JSON (reuse decoder)
                let mediaFiles = (try? decoder.decode([String].self, from: Data(item.mediaFilesJSON.utf8))) ?? []

                // Check if any media file exists
                let anyMediaExists = mediaFiles.contains { fm.fileExists(atPath: $0) }
                let contextExists = item.contextImageString.map { fm.fileExists(atPath: $0) } ?? false

                if !anyMediaExists && !mediaFiles.isEmpty {
                    if contextExists {
                        // Primary media gone but context image survives
                        // Keep the item, just clear the dead media references
                        toCleanup.append(item.id)
                    } else {
                        // Nothing exists, soft-delete
                        toSoftDelete.append(item.id)
                    }
                } else if mediaFiles.isEmpty,
                          let contextPath = item.contextImageString,
                          !contextPath.isEmpty,
                          !contextExists {
                    // Context-only captures have no primary media to trip the
                    // branch above. If their sole display file disappears they
                    // must leave the active library just like media-only items.
                    toSoftDelete.append(item.id)
                }
            }

            // Yield to avoid blocking too long
            await Task.yield()
        }

        // Soft-delete items in batches (no notification per batch)
        if !toSoftDelete.isEmpty {
            for batch in stride(from: 0, to: toSoftDelete.count, by: 500) {
                let end = min(batch + 500, toSoftDelete.count)
                let batchIds = Array(toSoftDelete[batch..<end])
                try await softDeleteInternal(ids: batchIds)
            }
            // Enqueue all for write-back once
            await writeBackQueue.enqueue(toSoftDelete)
        }

        // Clean up items where primary media is gone but context survives
        // Clear mediaFilesJSON so context image becomes the display image
        if !toCleanup.isEmpty {
            for batch in stride(from: 0, to: toCleanup.count, by: 500) {
                let end = min(batch + 500, toCleanup.count)
                let batchIds = Array(toCleanup[batch..<end])
                try await database.write { db in
                    let placeholders = batchIds.map { _ in "?" }.joined(separator: ", ")
                    let arguments = batchIds.map(\.uuidString)
                    try db.execute(
                        sql: "UPDATE media_items SET mediaFilesJSON = '[]' WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(arguments)
                    )
                }
            }
        }

        // Prune duplicate groups that reference soft-deleted items
        let prunedGroups = try await pruneStaleDuplicateGroups()

        // Single notification after all changes
        await notifyChange()

        return FilesystemSyncResult(
            scannedCount: totalScanned,
            softDeletedCount: toSoftDelete.count,
            cleanedUpCount: toCleanup.count,
            duplicateGroupsPruned: prunedGroups
        )
    }

    /// Prune duplicate groups that have members referencing soft-deleted items.
    /// Removes stale members and deletes groups that become too small.
    private func pruneStaleDuplicateGroups() async throws -> Int {
        let deletedGroups: Int = try await database.write { db in
            let staleRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT dgm.groupId, dgm.itemId
                    FROM duplicate_group_members dgm
                    JOIN media_items mi ON mi.id = dgm.itemId
                    WHERE mi.deletedAt IS NOT NULL AND mi.deletedAt != ''
                """
            )

            let staleMembers = staleRows.compactMap { row -> (groupId: UUID, itemId: UUID)? in
                guard let groupIdStr: String = row["groupId"],
                      let itemIdStr: String = row["itemId"],
                      let groupId = UUID(uuidString: groupIdStr),
                      let itemId = UUID(uuidString: itemIdStr) else { return nil }
                return (groupId, itemId)
            }

            guard !staleMembers.isEmpty else { return 0 }

            // Delete all stale members inside this single transaction.
            var groupsToCheck: Set<UUID> = []
            for stale in staleMembers {
                groupsToCheck.insert(stale.groupId)
                try db.execute(
                    sql: "DELETE FROM duplicate_group_members WHERE groupId = ? AND itemId = ?",
                    arguments: [stale.groupId.uuidString, stale.itemId.uuidString]
                )
            }

            let affectedGroupIds = Array(groupsToCheck)
            let placeholders = affectedGroupIds.map { _ in "?" }.joined(separator: ", ")
            let affectedArgs = StatementArguments(affectedGroupIds.map(\.uuidString))

            let remainingRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT groupId, COUNT(*) AS member_count
                    FROM duplicate_group_members
                    WHERE groupId IN (\(placeholders))
                    GROUP BY groupId
                """,
                arguments: affectedArgs
            )

            var remainingByGroup = Dictionary(uniqueKeysWithValues: affectedGroupIds.map { ($0, 0) })
            for row in remainingRows {
                guard let groupIdStr: String = row["groupId"],
                      let groupId = UUID(uuidString: groupIdStr) else { continue }
                let count: Int = row["member_count"] ?? 0
                remainingByGroup[groupId] = count
            }

            let groupsToDelete = affectedGroupIds.filter { (remainingByGroup[$0] ?? 0) < 2 }
            guard !groupsToDelete.isEmpty else { return 0 }

            let deletePlaceholders = groupsToDelete.map { _ in "?" }.joined(separator: ", ")
            let deleteArguments = StatementArguments(groupsToDelete.map(\.uuidString))
            try db.execute(
                sql: "DELETE FROM duplicate_group_members WHERE groupId IN (\(deletePlaceholders))",
                arguments: deleteArguments
            )
            try db.execute(
                sql: "DELETE FROM duplicate_groups WHERE id IN (\(deletePlaceholders))",
                arguments: StatementArguments(groupsToDelete.map(\.uuidString))
            )

            return groupsToDelete.count
        }

        if deletedGroups > 0 {
            await MainActor.run {
                NotificationCenter.default.post(name: .duplicateGroupsDidChange, object: nil)
            }
        }

        return deletedGroups
    }

    /// Result of database cleanup operation
    struct DatabaseCleanupResult: Sendable {
        let duplicateFileUrlsDeleted: Int   // file:// entries that duplicated real URLs
        let basePathsFixed: Int             // items with month-only basePath fixed
    }

    /// Clean up database issues:
    /// 1. Delete file:// URL entries that share media files with real URL entries
    /// 2. Fix items with month-only basePath (derive correct path from mediaFilesJSON)
    func cleanupDatabaseIssues() async throws -> DatabaseCleanupResult {
        // Step 1: Find and delete file:// entries that duplicate real URL entries
        let duplicatesToDelete: [UUID] = try await database.read { db in
            // Find file:// items that share media files with real URL items
            let sql = """
                WITH file_refs AS (
                    SELECT m.id, m.sourceURL,
                           json_each.value as filepath
                    FROM media_items m, json_each(m.mediaFilesJSON)
                    WHERE m.mediaFilesJSON != '[]'
                )
                SELECT DISTINCT f1.id
                FROM file_refs f1
                JOIN file_refs f2 ON f1.filepath = f2.filepath AND f1.id != f2.id
                WHERE f1.sourceURL LIKE 'file://%'
                AND f2.sourceURL NOT LIKE 'file://%'
            """
            let rows = try Row.fetchAll(db, sql: sql)
            return rows.compactMap { row -> UUID? in
                guard let idStr: String = row["id"] else { return nil }
                return UUID(uuidString: idStr)
            }
        }

        // Delete the duplicate file:// entries
        if !duplicatesToDelete.isEmpty {
            try await database.write { db in
                let placeholders = duplicatesToDelete.map { _ in "?" }.joined(separator: ", ")
                let args = duplicatesToDelete.map(\.uuidString)

                // Delete from FTS first
                try db.execute(
                    sql: "DELETE FROM media_items_fts WHERE rowid IN (SELECT rowid FROM media_items WHERE id IN (\(placeholders)))",
                    arguments: StatementArguments(args)
                )

                // Delete from main table
                try db.execute(
                    sql: "DELETE FROM media_items WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(args)
                )
            }
        }

        // Step 2: Fix items with month-only basePath
        // These have basePath like ~/MediaArchive/2026-02 instead of item-specific folder
        let itemsToFix: [(id: UUID, mediaFilesJSON: String)] = try await database.read { db in
            let sql = """
                SELECT id, mediaFilesJSON
                FROM media_items
                WHERE basePathString LIKE '%/____-__'
                AND basePathString NOT LIKE '%/____-__-%'
                AND mediaFilesJSON != '[]'
                AND (deletedAt IS NULL OR deletedAt = '')
            """
            let rows = try Row.fetchAll(db, sql: sql)
            return rows.compactMap { row -> (UUID, String)? in
                guard let idStr: String = row["id"],
                      let id = UUID(uuidString: idStr),
                      let json: String = row["mediaFilesJSON"] else { return nil }
                return (id, json)
            }
        }

        var basePathUpdates: [(id: UUID, newBasePath: String)] = []
        for item in itemsToFix {
            // Parse media files and derive basePath from first file
            guard let mediaFiles = try? JSONDecoder().decode([String].self, from: Data(item.mediaFilesJSON.utf8)),
                  let firstFile = mediaFiles.first else { continue }

            // Derive basePath: remove filename, keep directory
            // e.g., ~/MediaArchive/2026-02/2026-02-18-twitter-user-123-1.jpg
            //    -> ~/MediaArchive/2026-02/2026-02-18-twitter-user-123
            let fileURL = URL(fileURLWithPath: firstFile)
            let filename = fileURL.deletingPathExtension().lastPathComponent

            // Remove the -N suffix (e.g., -1, -2) to get base folder name
            var baseName = filename
            if let dashRange = baseName.range(of: #"-\d+$"#, options: .regularExpression) {
                baseName = String(baseName[..<dashRange.lowerBound])
            }

            let newBasePath = fileURL.deletingLastPathComponent().appendingPathComponent(baseName).path

            basePathUpdates.append((id: item.id, newBasePath: newBasePath))
        }

        if !basePathUpdates.isEmpty {
            try await database.write { db in
                for update in basePathUpdates {
                    try db.execute(
                        sql: "UPDATE media_items SET basePathString = ? WHERE id = ?",
                        arguments: [update.newBasePath, update.id.uuidString]
                    )
                }
            }
        }
        let fixedCount = basePathUpdates.count

        await notifyChange()

        return DatabaseCleanupResult(
            duplicateFileUrlsDeleted: duplicatesToDelete.count,
            basePathsFixed: fixedCount
        )
    }

    /// Restore soft-deleted items by clearing deletion state. Combine tombstones
    /// are deliberately ineligible because their content now belongs to the
    /// surviving primary item.
    /// File events may recover only missing-file tombstones. Recheck the reason
    /// inside the transaction so a newer manual/duplicate decision always wins.
    @discardableResult
    func restoreMissingFiles(ids: [UUID]) async throws -> [UUID] {
        guard !ids.isEmpty else { return [] }
        let restored: [UUID] = try await database.write { db in
            var restored: [UUID] = []
            for id in Set(ids) {
                try db.execute(
                    sql: "UPDATE media_items SET deletedAt = NULL, deletionReason = NULL WHERE id = ? AND deletionReason = 'missingFiles' AND deletedAt IS NOT NULL AND deletedAt != ''",
                    arguments: [id.uuidString]
                )
                if db.changesCount > 0 { restored.append(id) }
            }
            return restored
        }
        if !restored.isEmpty {
            await writeBackQueue.enqueue(restored)
            await notifyChange()
        }
        return restored
    }

    func restoreDeleted(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await database.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            let arguments = ids.map(\.uuidString)

            let combinedCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_items WHERE id IN (\(placeholders)) AND deletionReason = 'combined'",
                arguments: StatementArguments(arguments)
            ) ?? 0
            guard combinedCount == 0 else {
                throw DeletedItemRecoveryError.combinedItemsCannotBeRestored
            }

            try db.execute(
                sql: """
                    UPDATE media_items SET deletedAt = NULL,
                        deletionReason = CASE WHEN deletionReason = 'contextReattached' THEN deletionReason ELSE NULL END
                    WHERE id IN (\(placeholders))
                    """,
                arguments: StatementArguments(arguments)
            )
        }
        await writeBackQueue.enqueue(ids)
        await notifyChange()
    }

    /// Restore from the user-facing recovery surface only when the item can
    /// become visible again. Internal undo and file-watcher recovery retain the
    /// lower-level `restoreDeleted(ids:)` behavior.
    func restoreDeletedWithFileValidation(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        let missingIDs = try await database.read { db -> [UUID] in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, mediaFilesJSON, contextImageString FROM media_items WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids.map(\.uuidString))
            )
            let fileManager = FileManager.default
            return rows.compactMap { row in
                guard let idString: String = row["id"], let id = UUID(uuidString: idString) else { return nil }
                let mediaJSON: String = row["mediaFilesJSON"]
                let paths = (try? JSONDecoder().decode([String].self, from: Data(mediaJSON.utf8))) ?? []
                let contextPath: String? = row["contextImageString"]
                let hasFile = paths.contains(where: fileManager.fileExists(atPath:))
                    || contextPath.map(fileManager.fileExists(atPath:)) == true
                return hasFile ? nil : id
            }
        }
        guard missingIDs.isEmpty else {
            throw DeletedItemRecoveryError.noDisplayableFiles(missingIDs)
        }
        try await restoreDeleted(ids: ids)
    }

    struct DeletedItemPurgePlan: Sendable {
        struct Entry: Sendable {
            let id: UUID
            let fileURLs: [URL]
            let metadataFileURL: URL
        }

        let entries: [Entry]
    }

    /// Build an authoritative filesystem plan for a permanent purge. Cached UI
    /// models are intentionally ignored: the selected rows are re-read, active
    /// and combined rows are rejected, and any path referenced by a non-target
    /// row (active or deleted) is protected from Trash.
    func makeDeletedItemPurgePlan(ids: [UUID]) async throws -> DeletedItemPurgePlan {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return DeletedItemPurgePlan(entries: []) }

        return try await database.read { db in
            let placeholders = uniqueIDs.map { _ in "?" }.joined(separator: ", ")
            let arguments = StatementArguments(uniqueIDs.map(\.uuidString))
            let records = try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items WHERE id IN (\(placeholders))",
                arguments: arguments
            )
            guard records.count == uniqueIDs.count,
                  records.allSatisfy({ $0.deletedAt != nil }) else {
                throw DeletedItemPurgeError.activeItemsIncluded
            }
            guard records.allSatisfy({ $0.deletionReason != MediaItemDeletionReason.combined.rawValue }) else {
                throw DeletedItemPurgeError.combinedItemsIncluded
            }

            let protectedRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT metadataFileString, mediaFilesJSON, contextImageString
                    FROM media_items
                    WHERE id NOT IN (\(placeholders))
                    """,
                arguments: arguments
            )
            var protectedPaths = Set<String>()
            for row in protectedRows {
                let metadataPath: String = row["metadataFileString"]
                protectedPaths.insert(Self.normalizedFileIdentity(metadataPath))
                let mediaFilesJSON: String = row["mediaFilesJSON"]
                for path in Self.decodeStoredPaths(mediaFilesJSON) {
                    protectedPaths.insert(Self.normalizedFileIdentity(path))
                }
                if let contextPath: String = row["contextImageString"], !contextPath.isEmpty {
                    protectedPaths.insert(Self.normalizedFileIdentity(contextPath))
                }
            }

            let entries = records.map { record in
                let metadataURL = URL(fileURLWithPath: record.metadataFileString)
                let candidatePaths = Self.decodeStoredPaths(record.mediaFilesJSON)
                    + [record.contextImageString, record.metadataFileString].compactMap { $0 }
                var seen = Set<String>()
                let fileURLs = candidatePaths.compactMap { path -> URL? in
                    guard !path.isEmpty else { return nil }
                    let identity = Self.normalizedFileIdentity(path)
                    guard !protectedPaths.contains(identity), seen.insert(identity).inserted else {
                        return nil
                    }
                    return URL(fileURLWithPath: path)
                }
                return DeletedItemPurgePlan.Entry(
                    id: record.id,
                    fileURLs: fileURLs,
                    metadataFileURL: metadataURL
                )
            }
            return DeletedItemPurgePlan(entries: entries)
        }
    }

    /// Protect original paths referenced by any non-target item, including
    /// recoverable deleted items. Call immediately before an explicit Trash
    /// attempt; cached UI payloads are not authority for cross-item ownership.
    func protectedFilePaths(candidates: [URL], excludingItemIDs: [UUID]) async throws -> Set<String> {
        let candidates = Set(candidates.map { Self.normalizedFileIdentity($0.path) })
        let excluded = Set(excludingItemIDs.map(\.uuidString))
        return try await database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, metadataFileString, mediaFilesJSON, contextImageString FROM media_items")
            var protected = Set<String>()
            for row in rows {
                let id: String = row["id"]
                guard !excluded.contains(id) else { continue }
                let mediaJSON: String = row["mediaFilesJSON"]
                let metadataPath: String = row["metadataFileString"]
                let contextPath: String? = row["contextImageString"]
                let paths = Self.decodeStoredPaths(mediaJSON) + [metadataPath] + [contextPath].compactMap { $0 }
                for path in paths {
                    let identity = Self.normalizedFileIdentity(path)
                    if candidates.contains(identity) { protected.insert(identity) }
                }
            }
            return protected
        }
    }

    private static func decodeStoredPaths(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func normalizedFileIdentity(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    /// Permanently remove soft-deleted database records. Filesystem handling is
    /// intentionally owned by `DeleteService`, which moves surviving files to
    /// the system Trash before calling this method.
    @discardableResult
    func purgeDeletedRecords(ids: [UUID]) async throws -> Int {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return 0 }

        let deletedRecords = try await database.write { db -> [MediaItemRecord] in
            let placeholders = uniqueIDs.map { _ in "?" }.joined(separator: ", ")
            let records = try MediaItemRecord.fetchAll(
                db,
                sql: "SELECT * FROM media_items WHERE id IN (\(placeholders)) AND deletedAt IS NOT NULL AND deletedAt != ''",
                arguments: StatementArguments(uniqueIDs.map(\.uuidString))
            )
            guard records.count == uniqueIDs.count else {
                throw DeletedItemPurgeError.activeItemsIncluded
            }
            guard records.allSatisfy({ $0.deletionReason != MediaItemDeletionReason.combined.rawValue }) else {
                throw DeletedItemPurgeError.combinedItemsIncluded
            }
            for record in records {
                _ = try record.deleteWithFTSSync(db: db)
            }
            return records
        }

        for record in deletedRecords {
            await ImageCache.shared.clearAll(itemId: record.id)
        }
        await notifyChange(.deleted(Set(uniqueIDs)))
        return deletedRecords.count
    }

    /// Check if an item is currently soft-deleted
    func isSoftDeleted(id: UUID) async throws -> Bool {
        try await database.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_items WHERE id = ? AND deletedAt IS NOT NULL AND deletedAt != ''",
                arguments: [id.uuidString]
            ) ?? 0
            return count > 0
        }
    }

    /// Get current starred state for an item
    func isStarred(id: UUID) async throws -> Bool {
        try await database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT starred FROM media_items WHERE id = ?",
                arguments: [id.uuidString]
            )
            return row?["starred"] ?? false
        }
    }

    /// Add a tag to an item
    func addTag(id: UUID, tag: String) async throws {
        let displayTag = TagCanonicalizer.displayName(tag)
        let normalizedTag = TagCanonicalizer.key(displayTag)
        guard !normalizedTag.isEmpty else { return }

        let didUpdate = try await database.write { db -> Bool in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                arguments: [id.uuidString]
            ) else {
                return false
            }

            let json: String = row["tagsJSON"]
            var tags = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []

            // Heal a missing derived junction row even when the presentation JSON
            // already contains this tag.
            try db.execute(
                sql: "INSERT OR IGNORE INTO media_tags (item_id, tag) VALUES (?, ?)",
                arguments: [id.uuidString, normalizedTag]
            )

            if !tags.contains(where: {
                TagCanonicalizer.key($0) == normalizedTag
            }) {
                tags.append(displayTag)
                let newJSON = (try? JSONEncoder().encode(tags))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                try db.execute(
                    sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                    arguments: [newJSON, id.uuidString]
                )
                return true
            }
            return false
        }

        if didUpdate {
            await ensureTagDefinitionsExist(for: [displayTag])
            await writeBackQueue.enqueue(id)
        }
        await notifyChange(.items([id]))
    }

    /// Remove a tag from an item
    func removeTag(id: UUID, tag: String) async throws {
        let normalizedTag = TagCanonicalizer.key(tag)
        guard !normalizedTag.isEmpty else { return }

        let didUpdate = try await database.write { db -> Bool in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                arguments: [id.uuidString]
            ) else {
                return false
            }

            let json: String = row["tagsJSON"]
            var tags = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []

            let priorCount = tags.count
            tags.removeAll {
                TagCanonicalizer.key($0) == normalizedTag
            }
            // Also heal the opposite drift state: a stale junction row with no JSON tag.
            try db.execute(
                sql: "DELETE FROM media_tags WHERE item_id = ? AND tag = ?",
                arguments: [id.uuidString, normalizedTag]
            )
            if tags.count != priorCount {
                let newJSON = (try? JSONEncoder().encode(tags))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                try db.execute(
                    sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                    arguments: [newJSON, id.uuidString]
                )
                return true
            }
            return false
        }

        if didUpdate {
            await writeBackQueue.enqueue(id)
        }
        await notifyChange(.items([id]))
    }

    // MARK: - Batch Operations (for drag-drop)

    /// Add a tag to multiple items at once (batch operation for drag-drop).
    /// More efficient than calling addTag repeatedly.
    /// - Parameters:
    ///   - ids: Item IDs to add the tag to
    ///   - tag: The tag to add
    func addTagToItems(ids: [UUID], tag: String) async throws {
        guard !ids.isEmpty else { return }
        let displayTag = TagCanonicalizer.displayName(tag)
        let normalizedTag = TagCanonicalizer.key(displayTag)
        guard !normalizedTag.isEmpty else { return }

        let updatedIds = try await database.write { db -> [UUID] in
            var updatedIds: [UUID] = []
            for id in ids {
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                    arguments: [id.uuidString]
                ) else {
                    continue
                }

                let json: String = row["tagsJSON"]
                var tags = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []

                // Keep the derived lookup table complete even if an older database
                // drifted before migration 37 rebuilt it.
                try db.execute(
                    sql: "INSERT OR IGNORE INTO media_tags (item_id, tag) VALUES (?, ?)",
                    arguments: [id.uuidString, normalizedTag]
                )

                guard !tags.contains(where: {
                    TagCanonicalizer.key($0) == normalizedTag
                }) else { continue }

                tags.append(displayTag)
                let newJSON = (try? JSONEncoder().encode(tags))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

                try db.execute(
                    sql: "UPDATE media_items SET tagsJSON = ? WHERE id = ?",
                    arguments: [newJSON, id.uuidString]
                )

                updatedIds.append(id)
            }
            return updatedIds
        }

        if !updatedIds.isEmpty {
            await ensureTagDefinitionsExist(for: [displayTag])
            await writeBackQueue.enqueue(updatedIds)
        }
        await notifyChange(.items(Set(ids)))
    }

    /// Move items to a different folder (year-month directory).
    /// Moves files on disk and updates database records.
    /// - Parameters:
    ///   - ids: Item IDs to move
    ///   - targetFolder: Target folder name (e.g., "2025-01")
    ///   - archivePath: Base archive path
    enum FolderMoveError: LocalizedError {
        case sharedFolder(count: Int)

        var errorDescription: String? {
            switch self {
            case .sharedFolder(let count):
                let items = count == 1 ? "1 item wasn't" : "\(count) items weren't"
                return "\(items) moved: an item that shares its folder with other items can't be moved on its own yet."
            }
        }
    }

    /// Whether every visible file in the item's base folder is one of the item's own files.
    /// Only then does moving the folder move just this item. Captures and imports share
    /// their month folder, and a startup-scanned item's base path is its sidecar's stem.
    nonisolated static func ownsWholeFolder(_ record: MediaItemRecord, fileManager: FileManager = .default) -> Bool {
        let folder = URL(fileURLWithPath: record.basePathString).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let entries = try? fileManager.contentsOfDirectory(atPath: folder.path) else {
            return false
        }
        let mediaPaths = (try? JSONDecoder().decode([String].self, from: Data(record.mediaFilesJSON.utf8))) ?? []
        let owned = Set(([record.metadataFileString, record.contextImageString].compactMap { $0 } + mediaPaths)
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        return entries
            .filter { !$0.hasPrefix(".") }
            .allSatisfy { owned.contains(folder.appendingPathComponent($0).path) }
    }

    func moveItemsToFolder(ids: [UUID], targetFolder: String, archivePath: URL) async throws {
        guard !ids.isEmpty else { return }

        let fileManager = FileManager.default
        let targetPath = archivePath.appendingPathComponent(targetFolder)

        // Ensure target folder exists
        if !fileManager.fileExists(atPath: targetPath.path) {
            try fileManager.createDirectory(at: targetPath, withIntermediateDirectories: true)
        }

        let (movedItems, sharedFolderCount) = try await database.write { db in
            var movedItems: [(id: UUID, oldBasePath: String, newBasePath: String)] = []
            var sharedFolderCount = 0
            for id in ids {
                guard let record = try MediaItemRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM media_items WHERE id = ?",
                    arguments: [id.uuidString]
                ) else {
                    continue
                }

                let oldBasePath = URL(fileURLWithPath: record.basePathString)
                let itemFolderName = oldBasePath.lastPathComponent

                // Skip if already in target folder
                guard itemFolderName != targetFolder else { continue }

                // Moving a shared month folder moved every item in it.
                guard Self.ownsWholeFolder(record) else {
                    sharedFolderCount += 1
                    continue
                }

                // The item's subdirectory (timestamp folder like "2025-12_01-15-30")
                // We need to move this entire directory
                let itemSubdirName = oldBasePath.lastPathComponent
                let newBasePath = targetPath.appendingPathComponent(itemSubdirName)

                movedItems.append((id, oldBasePath.path, newBasePath.path))
            }
            return (movedItems, sharedFolderCount)
        }

        // Move files on disk outside the transaction
        for item in movedItems {
            let oldURL = URL(fileURLWithPath: item.oldBasePath)
            let newURL = URL(fileURLWithPath: item.newBasePath)

            do {
                // Handle name collision
                var finalNewURL = newURL
                var counter = 1
                while fileManager.fileExists(atPath: finalNewURL.path) {
                    let name = newURL.deletingPathExtension().lastPathComponent
                    let ext = newURL.pathExtension
                    let newName = ext.isEmpty ? "\(name)_\(counter)" : "\(name)_\(counter).\(ext)"
                    finalNewURL = newURL.deletingLastPathComponent().appendingPathComponent(newName)
                    counter += 1
                }

                try fileManager.moveItem(at: oldURL, to: finalNewURL)

                // Update database paths
                try await database.write { db in
                    try MediaItemRecord.updatePaths(
                        db: db,
                        oldBasePath: item.oldBasePath,
                        newBasePath: finalNewURL.path
                    )
                }
            } catch {
                logWarning("Failed to move item \(item.id): \(error.localizedDescription)")
            }
        }

        await notifyChange(.items(Set(ids)))
        if sharedFolderCount > 0 {
            throw FolderMoveError.sharedFolder(count: sharedFolderCount)
        }
    }

    /// Update notes for an item
    func updateNotes(id: UUID, notes: String?) async throws {
        try await database.write { db in
            // FTS triggers handle index sync automatically
            try db.execute(
                sql: "UPDATE media_items SET notes = ? WHERE id = ?",
                arguments: [notes, id.uuidString]
            )
        }

        await writeBackQueue.enqueue(id)
        await notifyChange(.items([id]))
        await MainActor.run {
            NotificationCenter.default.post(
                name: .mediaStoreDidChange,
                object: nil,
                userInfo: ["itemId": id]
            )
        }
    }

    /// Update media files for an item (Issue #9: for trim undo)
    func updateMediaFiles(id: UUID, files: [URL]) async throws {
        let jsonData = try JSONEncoder().encode(files.map { $0.path })
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"

        try await database.write { db in
            try db.execute(
                sql: "UPDATE media_items SET mediaFilesJSON = ? WHERE id = ?",
                arguments: [jsonString, id.uuidString]
            )
            try ItemAssetStore.reconcile(in: db, itemID: id.uuidString)
        }
        await notifyChange(.items([id]))
    }

    struct CombineItemsResult: Sendable {
        let primaryID: UUID
        let secondaryIDs: [UUID]
        /// Files that belonged to the absorbed secondaries and are NOT referenced by the
        /// merged primary (i.e. genuinely orphaned by the combine) — safe to trash if the
        /// user has disk-delete enabled. The primary's carousel unions in every secondary
        /// *media* file, so this is effectively unadopted secondary context images; media
        /// paths are excluded here by construction so a combine can never delete a file the
        /// merged primary still points at. Trashing is the caller's call via DeleteService.
        let orphanedFileURLs: [URL]
    }

    enum CombineItemsError: LocalizedError {
        case requiresAtLeastTwoItems
        case primaryItemMissing
        case secondaryItemMissing

        var errorDescription: String? {
            switch self {
            case .requiresAtLeastTwoItems:
                return "Select at least two items to combine"
            case .primaryItemMissing:
                return "The primary item could not be loaded"
            case .secondaryItemMissing:
                return "One or more secondary items could not be loaded"
            }
        }
    }

    /// Merge multiple items into a single canonical item.
    /// The primary item keeps its identity and most source metadata; user enrichment
    /// and cross-item relationships are merged, and the secondary items are soft-deleted.
    /// File paths are preserved as-is; this is a logical merge, not a folder consolidation.
    func combineItems(primaryID: UUID, secondaryIDs: [UUID]) async throws -> CombineItemsResult {
        let uniqueSecondaryIDs = Array(Set(secondaryIDs)).filter { $0 != primaryID }
        guard !uniqueSecondaryIDs.isEmpty else {
            throw CombineItemsError.requiresAtLeastTwoItems
        }

        let allIDs = [primaryID] + uniqueSecondaryIDs
        let fetchedItems = try await fetchItems(ids: allIDs)
        let fetchedByID = Dictionary(uniqueKeysWithValues: fetchedItems.map { ($0.id, $0) })

        guard let primaryItem = fetchedByID[primaryID] else {
            throw CombineItemsError.primaryItemMissing
        }

        let secondaryItems = uniqueSecondaryIDs.compactMap { fetchedByID[$0] }
        guard secondaryItems.count == uniqueSecondaryIDs.count else {
            throw CombineItemsError.secondaryItemMissing
        }

        let mergedPrimary = mergedItem(primary: primaryItem, secondaries: secondaryItems)

        try await database.write { db in
            let mergedRecord = MediaItemRecord(from: mergedPrimary)
            try mergedRecord.updateWithFTSSync(db: db)
            try ItemAssetStore.transfer(in: db, primaryID: primaryID, secondaryIDs: uniqueSecondaryIDs, preservingAssetIDs: Set(primaryItem.assets.map(\.assetID)))

            try self.transferBoardMembershipsForCombine(
                db: db,
                primaryID: primaryID,
                secondaryIDs: uniqueSecondaryIDs
            )
            try self.transferCanvasPlacementsForCombine(
                db: db,
                primaryID: primaryID,
                secondaryIDs: uniqueSecondaryIDs
            )
            try self.transferViewHistoryForCombine(
                db: db,
                primaryID: primaryID,
                secondaryIDs: uniqueSecondaryIDs
            )
            try self.mergeReviewStateForCombine(
                db: db,
                primaryID: primaryID,
                secondaryIDs: uniqueSecondaryIDs
            )
            try self.clearDuplicateGroupsForCombine(db: db, itemIDs: allIDs)
            try self.invalidateDerivedDataForCombine(db: db, itemIDs: allIDs, primaryID: primaryID)

            let placeholders = uniqueSecondaryIDs.map { _ in "?" }.joined(separator: ", ")
            var arguments: [DatabaseValueConvertible] = [Date()]
            arguments.append(contentsOf: uniqueSecondaryIDs.map(\.uuidString))
            try db.execute(
                sql: "UPDATE media_items SET deletedAt = ?, deletionReason = 'combined' WHERE id IN (\(placeholders))",
                arguments: StatementArguments(arguments)
            )
        }

        await writeBackQueue.enqueue(allIDs)
        await notifyChange()

        // Re-run vision over the merged item so the appended secondary files get
        // OCR/colors/etc. Vision processing is idempotent per file; the chained
        // PipelineQueue pass then refreshes CLIP/scene/aesthetics. The primary's own
        // pre-merge derived data was preserved above (mergedItem), so requeueIncomplete
        // alone would not have picked this item back up — its ocrText etc. are non-nil.
        if let visionQueue = VisionJobQueue.sharedIfConfigured {
            await visionQueue.enqueue(itemId: primaryID, priority: .normal)
        }

        let orphanedFileURLs = orphanedSecondaryFiles(mergedPrimary: mergedPrimary, secondaries: secondaryItems)

        return CombineItemsResult(
            primaryID: primaryID,
            secondaryIDs: uniqueSecondaryIDs,
            orphanedFileURLs: orphanedFileURLs
        )
    }

    /// Files owned by the absorbed secondaries that the merged primary does NOT reference —
    /// the only things a combine genuinely orphans. Every secondary *media* file is unioned
    /// into the primary's carousel (`mergedItem`), so those paths are in `keepPaths` and are
    /// excluded here; in practice this yields the secondary context images the primary didn't
    /// adopt. The keep-set exclusion is the safety guarantee: a combine can never surface a
    /// path the merged primary still points at, so trashing these can't corrupt the primary.
    private func orphanedSecondaryFiles(mergedPrimary: MediaItem, secondaries: [MediaItem]) -> [URL] {
        var keepPaths = Set(mergedPrimary.mediaFiles.map(\.path))
        if let ctx = mergedPrimary.contextImage {
            keepPaths.insert(ctx.path)
        }

        var orphans: [URL] = []
        var seen = Set<String>()
        for secondary in secondaries {
            let candidates = secondary.mediaFiles + [secondary.contextImage].compactMap { $0 }
            for url in candidates where !keepPaths.contains(url.path) {
                if seen.insert(url.path).inserted {
                    orphans.append(url)
                }
            }
        }
        return orphans
    }

    // MARK: - Backfill

    /// Cached sidecars still need URL-derived authors after upgrading the parser.
    /// Author is imported metadata, so this never creates a sidecar write intent.
    @discardableResult
    func backfillStatusURLAuthors() async throws -> Int {
        let updated = try await database.write { db -> Set<UUID> in
            let rows = try Row.fetchAll(db, sql: "SELECT id, sourceURL FROM media_items WHERE author IS NULL OR TRIM(author) = ''")
            var updated = Set<UUID>()
            for row in rows {
                let source: String = row["sourceURL"]
                guard let url = URL(string: source), let author = MetadataParser.authorFromStatusURL(url),
                      let id = UUID(uuidString: row["id"]) else { continue }
                try db.execute(sql: "UPDATE media_items SET author = ? WHERE id = ?", arguments: [author, id.uuidString])
                updated.insert(id)
            }
            return updated
        }
        if !updated.isEmpty { await notifyChange(.items(updated)) }
        return updated.count
    }

    func didRepairContextAssociations(enrichedOwnerIDs: [UUID]) async {
        await writeBackQueue.enqueue(enrichedOwnerIDs)
        await notifyChange()
    }

    func didRepairCombinedAssociations(restoredIDs: [UUID], updatedIDs: Set<UUID>) async {
        if !restoredIDs.isEmpty { await writeBackQueue.enqueue(restoredIDs) }
        for id in updatedIDs { await ImageCache.shared.clearAll(itemId: id) }
        let changed = updatedIDs.union(restoredIDs)
        if !changed.isEmpty { await notifyChange(.items(changed)) }
    }

    /// Find all items with user enrichment data (starred, tags, notes, deleted)
    /// that need their frontmatter written/verified. Used for one-time migration.
    func itemIdsWithEnrichment() async throws -> [UUID] {
        try await database.read { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT id FROM media_items
                WHERE COALESCE(deletionReason, '') != 'contextReattached'
                  AND (starred = 1
                   OR (tagsJSON IS NOT NULL AND tagsJSON != '[]')
                   OR (notes IS NOT NULL AND notes != '')
                   OR (deletedAt IS NOT NULL AND deletedAt != ''))
                """)
            return rows.compactMap { UUID(uuidString: $0) }
        }
    }

    // MARK: - Smart Folder Operations

    /// Fetch all smart folders
    func fetchSmartFolders() async throws -> [SmartFolder] {
        try await database.read { db in
            try SmartFolder.fetchAll(db)
        }
    }

    /// Save a smart folder (insert or update)
    func saveSmartFolder(_ folder: SmartFolder) async throws {
        try await database.write { db in
            var updated = folder
            updated.updatedAt = Date()
            try updated.save(db)
        }
    }

    /// Delete a smart folder
    func deleteSmartFolder(id: UUID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM smart_folders WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    /// GAP #2 Fix: Update tag references in all smart folder rules when a tag is renamed.
    /// This cascades tag renames to smart folders that have hasTag rules.
    func renameTagInSmartFolders(oldName: String, newName: String) async throws {
        let folders = try await fetchSmartFolders()
        let oldLower = TagCanonicalizer.key(oldName)
        let newDisplayName = TagCanonicalizer.displayName(newName)

        for folder in folders {
            var needsUpdate = false
            var updatedRules: [FilterRule] = []

            for rule in folder.rules {
                if case .hasTag(let tagName) = rule, TagCanonicalizer.key(tagName) == oldLower {
                    updatedRules.append(.hasTag(newDisplayName))
                    needsUpdate = true
                } else {
                    updatedRules.append(rule)
                }
            }

            if needsUpdate {
                var updatedFolder = folder
                updatedFolder.rules = updatedRules
                updatedFolder.updatedAt = Date()
                try await saveSmartFolder(updatedFolder)
            }
        }
    }

    // MARK: - GRDB Observation

    /// Observe only the count for a filter.
    /// This is significantly cheaper than observing full item payloads.
    func observeCount(filter: FilterState = .all) async throws -> AnyPublisher<Int, Error> {
        let pool = try await database.getPool()
        let tagExpansion = await expandTagsForFilter(filter)

        let observation = ValueObservation.tracking { db -> Int in
            let query = self.buildFilterQueryParts(
                filter: filter,
                tagExpansion: tagExpansion,
                searchMode: .rowIDSubquery
            )
            let sql = self.applyingWhereClause(to: "SELECT COUNT(*) FROM media_items", conditions: query.conditions)

            return try Int.fetchOne(
                db,
                sql: sql,
                arguments: StatementArguments(query.arguments)
            ) ?? 0
        }

        return observation
            // Deliver asynchronously on the main queue; the fetch runs on a pool
            // reader rather than blocking the main thread (was `.immediate`).
            .publisher(in: pool, scheduling: .async(onQueue: .main))
            .eraseToAnyPublisher()
    }

    // MARK: - Windowed Observation

    /// Observe a windowed subset of items with automatic change detection.
    /// Uses GRDB's ValueObservation with removeDuplicates() to prevent spurious updates.
    ///
    /// - Parameters:
    ///   - offset: Starting offset for the window
    ///   - limit: Number of items to observe
    ///   - filter: Optional filter to apply
    /// - Returns: Publisher that emits whenever the observed window changes
    func observeWindow(
        offset: Int,
        limit: Int,
        filter: FilterState = .all
    ) async throws -> AnyPublisher<[MediaItem], Error> {
        let pool = try await database.getPool()

        // Pre-compute hierarchical tag expansion on MainActor before entering observation closure
        let tagExpansion = await expandTagsForFilter(filter)

        let observation = ValueObservation.tracking { [weak self] db -> [MediaItem] in
            guard let self = self else { return [] }

            let query = self.buildFilterQueryParts(
                filter: filter,
                tagExpansion: tagExpansion,
                searchMode: .joinedFTSMatch
            )

            var sql = query.selectSQL
            sql = self.applyingWhereClause(to: sql, conditions: query.conditions)
            self.appendSortAndPagination(
                to: &sql,
                filter: filter,
                isSearching: query.isSearching,
                limitOverride: limit,
                offsetOverride: offset
            )

            var records = try MediaItemRecord.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(query.arguments)
            )
            records = self.applyShuffleAndPaginationIfNeeded(
                records,
                filter: filter,
                limitOverride: limit,
                offsetOverride: offset
            )

            return try self.materializeMediaItems(
                db: db,
                records: records,
                includeMLAttributes: false,
                includePerFileOCR: true,
                includeVideoSegments: false,
                includeTranscriptSegments: false
            )
        }

        return observation
            .removeDuplicates()
            // Deliver asynchronously on the main queue; the fetch runs on a pool
            // reader rather than blocking the main thread (was `.immediate`).
            .publisher(in: pool, scheduling: .async(onQueue: .main))
            .eraseToAnyPublisher()
    }

    // MARK: - Private Helpers

    enum SearchQueryMode {
        case joinedFTSMatch
        case rowIDSubquery
        case disabled
    }

    struct FilterQueryParts {
        var selectSQL: String
        var isSearching: Bool
        var conditions: [String]
        var arguments: [DatabaseValueConvertible]
    }

    func applyingWhereClause(to sql: String, conditions: [String]) -> String {
        guard !conditions.isEmpty else { return sql }
        return sql + " WHERE " + conditions.joined(separator: " AND ")
    }

    private func appendSortAndPagination(
        to sql: inout String,
        filter: FilterState,
        isSearching: Bool,
        limitOverride: Int? = nil,
        offsetOverride: Int? = nil
    ) {
        let sortOrder = filter.smartFolder?.sortOrder ?? filter.sortOrder
        if isSearching {
            // bm25() returns negative values, lower (more negative) = better match
            sql += " ORDER BY _rank, \(sortOrder.sqlFragment)"
        } else {
            sql += " ORDER BY \(sortOrder.sqlFragment)"
        }
        sql += ", media_items.id ASC"

        if filter.shuffleSeed != nil {
            return
        }

        let requestedLimit = limitOverride ?? filter.limit
        let limit: Int
        if requestedLimit == 0 {
            limit = FilterState.defaultQueryLimit
        } else {
            limit = requestedLimit
        }
        let offset = offsetOverride ?? filter.offset
        if limit > 0 {
            sql += " LIMIT \(limit)"
            if offset > 0 {
                sql += " OFFSET \(offset)"
            }
        } else if offset > 0 {
            sql += " LIMIT -1 OFFSET \(offset)"
        }
    }

    private func applyShuffleAndPaginationIfNeeded(
        _ records: [MediaItemRecord],
        filter: FilterState,
        limitOverride: Int? = nil,
        offsetOverride: Int? = nil
    ) -> [MediaItemRecord] {
        guard let seed = filter.shuffleSeed else { return records }

        let shuffled = records.sorted { lhs, rhs in
            let lhsRank = Self.seededShuffleRank(id: lhs.id, seed: seed)
            let rhsRank = Self.seededShuffleRank(id: rhs.id, seed: seed)
            if lhsRank == rhsRank {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhsRank < rhsRank
        }

        let requestedLimit = limitOverride ?? filter.limit
        let limit = requestedLimit == 0 ? FilterState.defaultQueryLimit : requestedLimit
        let offset = max(0, offsetOverride ?? filter.offset)
        guard offset < shuffled.count else { return [] }
        guard limit > 0 else {
            return Array(shuffled.dropFirst(offset))
        }
        return Array(shuffled.dropFirst(offset).prefix(limit))
    }

    private static func seededShuffleRank(id: UUID, seed: UInt64) -> UInt64 {
        let uuid = id.uuid
        let bytes: [UInt8] = [
            uuid.0, uuid.1, uuid.2, uuid.3,
            uuid.4, uuid.5, uuid.6, uuid.7,
            uuid.8, uuid.9, uuid.10, uuid.11,
            uuid.12, uuid.13, uuid.14, uuid.15
        ]

        var hash = seed ^ 0xCBF29CE484222325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x100000001B3
        }
        return splitMix64(hash)
    }

    private static func splitMix64(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    func buildFilterQueryParts(
        filter: FilterState,
        tagExpansion: [String: Set<String>],
        searchMode: SearchQueryMode
    ) -> FilterQueryParts {
        var selectSQL = "SELECT * FROM media_items"
        var conditions: [String] = []
        var arguments: [DatabaseValueConvertible] = []

        let isSearching = !filter.searchText.isEmpty
            && filter.searchScope != .visual
            && searchMode != .disabled
        if isSearching {
            let ftsQuery = buildFTSQuery(filter.searchText, scope: filter.searchScope)
            switch searchMode {
            case .joinedFTSMatch:
                selectSQL = """
                    SELECT media_items.*, search_match._rank
                    FROM media_items
                    JOIN (
                        SELECT rowid, bm25(media_items_fts) AS _rank
                        FROM media_items_fts
                        WHERE media_items_fts MATCH ?
                    ) AS search_match ON media_items.rowid = search_match.rowid
                    """
                arguments.append(ftsQuery)
            case .rowIDSubquery:
                conditions.append("rowid IN (SELECT rowid FROM media_items_fts WHERE media_items_fts MATCH ?)")
                arguments.append(ftsQuery)
            case .disabled:
                break
            }
        }

        if let folder = filter.smartFolder {
            let (folderSQL, folderArgs) = buildSmartFolderQuery(folder, tagExpansion: tagExpansion)
            if !folderSQL.isEmpty {
                conditions.append(folderSQL)
                arguments.append(contentsOf: folderArgs)
            }
        }

        for platform in [filter.platform].compactMap({ $0 }) + filter.platformConstraints {
            let platformValues = Self.platformFilterValues(for: platform)
            if platformValues.count == 1, let onlyValue = platformValues.first {
                conditions.append("platform = ?")
                arguments.append(onlyValue)
            } else if !platformValues.isEmpty {
                let placeholders = platformValues.map { _ in "?" }.joined(separator: ", ")
                conditions.append("LOWER(platform) IN (\(placeholders))")
                arguments.append(contentsOf: platformValues)
            }
        }

        if let author = filter.author {
            conditions.append("author = ?")
            arguments.append(author)
        }

        for authorConstraint in [filter.authorQuery].compactMap({ $0 }) + filter.authorConstraints {
            let authorQuery = authorConstraint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !authorQuery.isEmpty else { continue }
            let escaped = MediaStore.escapeLikeValue(authorQuery.lowercased())
            conditions.append("author IS NOT NULL AND LOWER(author) LIKE ? ESCAPE '\\'")
            arguments.append("%\(escaped)%")
        }

        for sourceConstraint in [filter.sourceQuery].compactMap({ $0 }) + filter.sourceConstraints {
            let sourceQuery = sourceConstraint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sourceQuery.isEmpty else { continue }
            let escaped = MediaStore.escapeLikeValue(sourceQuery.lowercased())
            conditions.append("LOWER(sourceURL) LIKE ? ESCAPE '\\'")
            arguments.append("%\(escaped)%")
        }

        if let ocrQuery = filter.ocrQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ocrQuery.isEmpty {
            let ftsQuery = buildFTSQuery(ocrQuery, scope: .ocrOnly)
            if !ftsQuery.isEmpty {
                conditions.append("media_items.rowid IN (SELECT rowid FROM media_items_fts WHERE media_items_fts MATCH ?)")
                arguments.append(ftsQuery)
            }
        }

        if let notesQuery = filter.notesQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
           !notesQuery.isEmpty {
            let ftsQuery = buildFTSQuery(notesQuery, scope: .notesOnly)
            if !ftsQuery.isEmpty {
                conditions.append("media_items.rowid IN (SELECT rowid FROM media_items_fts WHERE media_items_fts MATCH ?)")
                arguments.append(ftsQuery)
            }
        }

        if let starred = filter.starred {
            conditions.append("starred = ?")
            arguments.append(starred)
        }

        if !filter.tags.isEmpty {
            appendTagConditions(
                tags: filter.tags,
                expansion: tagExpansion,
                conditions: &conditions,
                arguments: &arguments
            )
        }
        if !filter.tagFilters.isEmpty {
            appendTagFilterConditions(
                filters: filter.tagFilters,
                expansion: tagExpansion,
                conditions: &conditions,
                arguments: &arguments
            )
        }

        for dateRange in [filter.dateRange].compactMap({ $0 }) + filter.dateConstraints {
            let (dateSQL, dateArgs) = dateRange.sqlFragment()
            conditions.append(dateSQL)
            arguments.append(contentsOf: dateArgs)
        }

        if !filter.colorFilters.isEmpty {
            let colorConditions = filter.colorFilters.map { bucket in
                arguments.append(bucket.rawValue)
                return "EXISTS (SELECT 1 FROM media_colors WHERE media_colors.item_id = media_items.id AND media_colors.color_bucket = ?)"
            }
            conditions.append("(" + colorConditions.joined(separator: " OR ") + ")")
        }

        // An RGB box is not a proven superset of a CIE76 sphere. Evaluate the
        // exact predicate inside SQLite before counting or paginating.
        if let colorSearch = filter.colorSearchRGB, colorSearch.usePerceptual {
            let target = PerceptualColorMetric.rgbToLab(r: colorSearch.r, g: colorSearch.g, b: colorSearch.b)
            conditions.append("""
                EXISTS (SELECT 1 FROM media_colors
                    WHERE media_colors.item_id = media_items.id
                      AND nodraw_delta_e76(rgb_r, rgb_g, rgb_b, ?, ?, ?) <= ?)
                """)
            arguments.append(contentsOf: [target.L, target.a, target.b, colorSearch.deltaEThreshold])
        } else if let colorSearch = filter.colorSearchRGB {
            let margin = colorSearch.tolerance
            let rMin = max(0, colorSearch.r - margin)
            let rMax = min(255, colorSearch.r + margin)
            let gMin = max(0, colorSearch.g - margin)
            let gMax = min(255, colorSearch.g + margin)
            let bMin = max(0, colorSearch.b - margin)
            let bMax = min(255, colorSearch.b + margin)

            conditions.append("""
                EXISTS (
                    SELECT 1 FROM media_colors
                    WHERE media_colors.item_id = media_items.id
                    AND rgb_r BETWEEN ? AND ?
                    AND rgb_g BETWEEN ? AND ?
                    AND rgb_b BETWEEN ? AND ?
                )
            """)
            arguments.append(contentsOf: [rMin, rMax, gMin, gMax, bMin, bMax])
        }

        for folderPath in [filter.folderPath].compactMap({ $0 }) + filter.folderConstraints {
            let escaped = MediaStore.escapeLikeValue(folderPath)
            conditions.append("basePathString LIKE ? ESCAPE '\\'")
            arguments.append("%/\(escaped)%")
        }

        if let hasOCR = filter.hasOCR {
            if hasOCR {
                conditions.append("ocrText IS NOT NULL AND ocrText != ''")
            } else {
                conditions.append("(ocrText IS NULL OR ocrText = '')")
            }
        }

        if let hasVideo = filter.hasVideo {
            let videoFragment = fileExtensionCondition(Self.searchableVideoExtensions)
            conditions.append(hasVideo ? videoFragment.0 : "NOT \(videoFragment.0)")
            arguments.append(contentsOf: videoFragment.1)
        }

        if let tagsEmpty = filter.tagsEmpty {
            if tagsEmpty {
                conditions.append("NOT EXISTS (SELECT 1 FROM media_tags WHERE media_tags.item_id = media_items.id)")
            } else {
                conditions.append("EXISTS (SELECT 1 FROM media_tags WHERE media_tags.item_id = media_items.id)")
            }
        }

        if !filter.fileExtensions.isEmpty {
            let fileExtensionFragment = fileExtensionCondition(filter.fileExtensions)
            conditions.append(fileExtensionFragment.0)
            arguments.append(contentsOf: fileExtensionFragment.1)
        }

        for aspectRatio in [filter.aspectRatio].compactMap({ $0 }) + filter.aspectRatioConstraints {
            conditions.append("aspectRatio BETWEEN ? AND ?")
            arguments.append(aspectRatio.min)
            arguments.append(aspectRatio.max)
        }

        switch filter.deletionScope {
        case .active:
            // Equivalent to the legacy NULL-or-empty check, expressed as one
            // predicate so SQLite can use the ordered partial active-page index.
            conditions.append("COALESCE(deletedAt, '') = ''")
            conditions.append("(mediaFilesJSON != '[]' OR (contextImageString IS NOT NULL AND contextImageString != ''))")
        case .deletedOnly:
            conditions.append("(deletedAt IS NOT NULL AND deletedAt != '')")
            // Combine tombstones are implementation details, not independently
            // restorable media. Legacy nil provenance remains visible/recoverable.
            conditions.append("COALESCE(deletionReason, '') != 'combined'")
        case .all:
            break
        }

        for attrFilter in filter.attributeFilters {
            let (attrSQL, attrArgs) = attrFilter.sqlCondition()
            conditions.append(attrSQL)
            for arg in attrArgs {
                if let value = arg as? DatabaseValueConvertible {
                    arguments.append(value)
                }
            }
        }

        if filter.hideJunk {
            conditions.append("""
                NOT EXISTS (
                    SELECT 1 FROM media_attributes
                    WHERE media_attributes.item_id = media_items.id
                      AND media_attributes.module = 'junk'
                      AND media_attributes.key = 'is_junk'
                      AND media_attributes.value >= 0.5
                )
            """)
        }

        if filter.hideSafetyFlagged {
            conditions.append("""
                NOT EXISTS (
                    SELECT 1 FROM media_attributes
                    WHERE media_attributes.item_id = media_items.id
                      AND media_attributes.module = 'safety'
                      AND media_attributes.key = 'is_safe'
                      AND media_attributes.value < 0.5
                )
            """)
        }

        if let minScore = filter.minCurationScore {
            conditions.append("""
                EXISTS (
                    SELECT 1 FROM media_attributes
                    WHERE media_attributes.item_id = media_items.id
                      AND media_attributes.module = 'curation'
                      AND media_attributes.key = 'score'
                      AND media_attributes.value >= ?
                )
            """)
            arguments.append(minScore)
        }

        if let pipelineStatus = filter.pipelineStatus {
            conditions.append("pipeline_status = ?")
            arguments.append(pipelineStatus.rawValue)
        }

        if let clipIds = filter.clipResultIds, !clipIds.isEmpty {
            let placeholders = clipIds.map { _ in "?" }.joined(separator: ", ")
            conditions.append("media_items.id IN (\(placeholders))")
            for id in clipIds {
                arguments.append(id.uuidString)
            }
        }

        return FilterQueryParts(
            selectSQL: selectSQL,
            isSearching: isSearching,
            conditions: conditions,
            arguments: arguments
        )
    }

    private func materializeMediaItems(
        db: Database,
        records: [MediaItemRecord],
        includeMLAttributes: Bool,
        includePerFileOCR: Bool,
        includeVideoSegments: Bool = true,
        includeTranscriptSegments: Bool = true
    ) throws -> [MediaItem] {
        let itemIds = records.map(\.id)
        let assetMap = try ItemAssetStore.fetchBatch(in: db, itemIDs: itemIds)
        let perFileOCRMap: [UUID: [Int: MediaFileOCR]]
        if includePerFileOCR {
            perFileOCRMap = try loadPerFileOCRBatch(db: db, itemIds: itemIds)
        } else {
            perFileOCRMap = [:]
        }
        let mlAttributeMap: [UUID: [String: Double]]
        if includeMLAttributes {
            mlAttributeMap = try loadMLAttributesBatch(db: db, itemIds: itemIds)
        } else {
            mlAttributeMap = [:]
        }
        let videoSegmentMap: [UUID: [VideoSegment]]
        if includeVideoSegments {
            videoSegmentMap = try loadVideoSegmentsBatch(db: db, itemIds: itemIds)
        } else {
            videoSegmentMap = [:]
        }
        let transcriptSegmentMap: [UUID: [TranscriptSegment]]
        if includeTranscriptSegments {
            transcriptSegmentMap = try loadTranscriptSegmentsBatch(db: db, itemIds: itemIds)
        } else {
            transcriptSegmentMap = [:]
        }

        return records.compactMap { record in
            record.toMediaItem(
                withPerFileOCR: perFileOCRMap[record.id] ?? [:],
                mlAttributes: mlAttributeMap[record.id] ?? [:],
                videoSegments: videoSegmentMap[record.id] ?? [],
                transcriptSegments: transcriptSegmentMap[record.id] ?? [],
                assets: assetMap[record.id] ?? []
            )
        }
    }

    /// Escape LIKE metacharacters (%, _) in a value to be embedded in a LIKE pattern.
    static func escapeLikeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func platformFilterValues(for platform: String) -> [String] {
        let canonical = canonicalPlatformName(platform)
        switch canonical {
        case "bluesky":
            return ["bluesky", "bsky"]
        default:
            return [canonical]
        }
    }

    static func canonicalPlatformName(_ platform: String) -> String {
        let trimmed = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "bsky", "bluesky":
            return "bluesky"
        default:
            return trimmed.lowercased()
        }
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func normalizedFileExtensions(_ extensions: [String]) -> [String] {
        let normalized = extensions.compactMap { rawValue -> String? in
            let trimmed = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return trimmed.isEmpty ? nil : trimmed
        }

        let expanded = normalized.flatMap { fileExtensionAliases[$0] ?? [$0] }
        return uniquePreservingOrder(expanded)
    }

    private func fileExtensionCondition(_ extensions: [String]) -> (String, [DatabaseValueConvertible]) {
        let normalizedExtensions = Self.normalizedFileExtensions(extensions)
        guard !normalizedExtensions.isEmpty else { return ("1 = 0", []) }

        var arguments: [DatabaseValueConvertible] = []
        let clauses = normalizedExtensions.map { fileExtension -> String in
            let pattern = "%.\(MediaStore.escapeLikeValue(fileExtension))"
            arguments.append(pattern)
            arguments.append(pattern)
            return """
                (
                    EXISTS (
                        SELECT 1
                        FROM json_each(media_items.mediaFilesJSON)
                        WHERE LOWER(json_each.value) LIKE ? ESCAPE '\\'
                    )
                    OR (
                        contextImageString IS NOT NULL
                        AND LOWER(contextImageString) LIKE ? ESCAPE '\\'
                    )
                )
                """
        }

        return ("(" + clauses.joined(separator: " OR ") + ")", arguments)
    }

    private func platformRuleFragment(_ filter: PlatformFilter) -> (String, [DatabaseValueConvertible]) {
        switch filter {
        case .equals(let value):
            let platformValues = Self.platformFilterValues(for: value)
            if platformValues.count == 1, let onlyValue = platformValues.first {
                return ("platform = ?", [onlyValue])
            }
            let placeholders = platformValues.map { _ in "?" }.joined(separator: ", ")
            return ("LOWER(platform) IN (\(placeholders))", platformValues)

        case .oneOf(let values):
            var expandedValues: [String] = []
            var requiresAliasExpansion = false

            for value in values {
                let aliases = Self.platformFilterValues(for: value)
                if aliases.count > 1 {
                    requiresAliasExpansion = true
                }
                expandedValues.append(contentsOf: aliases)
            }

            let dedupedValues = Self.uniquePreservingOrder(expandedValues)
            guard !dedupedValues.isEmpty else { return ("1 = 0", []) }

            let placeholders = dedupedValues.map { _ in "?" }.joined(separator: ", ")
            if requiresAliasExpansion {
                return ("LOWER(platform) IN (\(placeholders))", dedupedValues)
            } else {
                return ("platform IN (\(placeholders))", dedupedValues)
            }
        }
    }

    private func buildSmartFolderQuery(_ folder: SmartFolder, tagExpansion: [String: Set<String>] = [:]) -> (String, [DatabaseValueConvertible]) {
        guard !folder.rules.isEmpty else { return ("", []) }

        var fragments: [(String, [DatabaseValueConvertible])] = []

        for rule in folder.rules {
            if case .platform(let platformFilter) = rule {
                fragments.append(platformRuleFragment(platformFilter))
                continue
            }

            if case .hasVideo(let value) = rule {
                let fragment = fileExtensionCondition(Self.searchableVideoExtensions)
                fragments.append((value ? fragment.0 : "NOT \(fragment.0)", fragment.1))
                continue
            }

            if case .fileExtension(let extensions) = rule {
                fragments.append(fileExtensionCondition(Array(extensions)))
                continue
            }

            // Expand hasTag rules using hierarchical tag descendants
            if case .hasTag(let tag) = rule,
               let allNames = tagExpansion[TagCanonicalizer.key(tag)],
               allNames.count > 1 {
                // Non-leaf tag: match any descendant OR the tag itself using junction table
                let placeholders = allNames.map { _ in "?" }.joined(separator: ", ")
                let sql = "EXISTS (SELECT 1 FROM media_tags WHERE media_tags.item_id = media_items.id AND media_tags.tag IN (\(placeholders)))"
                let args: [DatabaseValueConvertible] = allNames.sorted()
                fragments.append((sql, args))
            } else if case .hasTag(let tag) = rule {
                let sql = "EXISTS (SELECT 1 FROM media_tags WHERE media_tags.item_id = media_items.id AND media_tags.tag = ?)"
                fragments.append((sql, [TagCanonicalizer.key(tag)]))
            } else {
                let fragment = rule.sqlFragment()
                fragments.append((fragment.sql, fragment.arguments))
            }
        }

        let joiner = folder.matchAll ? " AND " : " OR "
        let sql = "(" + fragments.map(\.0).joined(separator: joiner) + ")"
        let args = fragments.flatMap(\.1)

        return (sql, args)
    }

    /// Pre-compute hierarchical tag expansion on MainActor before entering database closures.
    /// Returns a map of tag name -> all names to match (the tag itself + all descendants).
    /// For leaf tags (no descendants), the set contains just the tag itself (single element).
    @MainActor
    private func expandTagsForFilter(_ filter: FilterState) -> [String: Set<String>] {
        var expansion: [String: Set<String>] = [:]

        // Expand filter.tags
        for tag in filter.tags {
            let descendants = TagSettings.shared.allDescendantNames(ofTagNamed: tag)
            let key = TagCanonicalizer.key(tag)
            expansion[key] = Set(descendants.map(TagCanonicalizer.key)).union([key])
        }

        for tagFilter in filter.tagFilters where tagFilter.scope == .subtree {
            let tag = tagFilter.name
            let descendants = TagSettings.shared.allDescendantNames(ofTagNamed: tag)
            let key = TagCanonicalizer.key(tag)
            expansion[key] = Set(descendants.map(TagCanonicalizer.key)).union([key])
        }

        // Expand hasTag rules in smart folder
        if let folder = filter.smartFolder {
            for rule in folder.rules {
                if case .hasTag(let tag) = rule {
                    let key = TagCanonicalizer.key(tag)
                    guard expansion[key] == nil else { continue }
                    let descendants = TagSettings.shared.allDescendantNames(ofTagNamed: tag)
                    expansion[key] = Set(descendants.map(TagCanonicalizer.key)).union([key])
                }
            }
        }

        return expansion
    }

    /// Append tag filter conditions using pre-computed hierarchical expansion.
    /// Each tag in filter.tags must match (AND logic). Parent tags expand to match any descendant.
    private func appendTagConditions(
        tags: [String],
        expansion: [String: Set<String>],
        conditions: inout [String],
        arguments: inout [DatabaseValueConvertible]
    ) {
        for tag in tags {
            let tagKey = TagCanonicalizer.key(tag)
            let allNames = expansion[tagKey] ?? [tagKey]
            if allNames.count == 1 {
                // Leaf tag or unknown — exact match (same as before)
                conditions.append("EXISTS (SELECT 1 FROM media_tags WHERE media_tags.item_id = media_items.id AND media_tags.tag = ?)")
                arguments.append(tagKey)
            } else {
                // Non-leaf — match any descendant OR the tag itself
                let placeholders = allNames.map { _ in "?" }.joined(separator: ", ")
                conditions.append("EXISTS (SELECT 1 FROM media_tags WHERE media_tags.item_id = media_items.id AND media_tags.tag IN (\(placeholders)))")
                for name in allNames.sorted() {
                    arguments.append(name)
                }
            }
        }
    }

    private func appendTagFilterConditions(
        filters: [TagFilter],
        expansion: [String: Set<String>],
        conditions: inout [String],
        arguments: inout [DatabaseValueConvertible]
    ) {
        for filter in filters {
            let allNames: Set<String>
            switch filter.scope {
            case .exact:
                allNames = [TagCanonicalizer.key(filter.name)]
            case .subtree:
                let key = TagCanonicalizer.key(filter.name)
                allNames = expansion[key] ?? [key]
            }

            let predicate: String
            if allNames.count == 1 {
                predicate = "EXISTS (SELECT 1 FROM media_tags WHERE media_tags.item_id = media_items.id AND media_tags.tag = ?)"
                arguments.append(TagCanonicalizer.key(filter.name))
            } else {
                let placeholders = allNames.map { _ in "?" }.joined(separator: ", ")
                predicate = "EXISTS (SELECT 1 FROM media_tags WHERE media_tags.item_id = media_items.id AND media_tags.tag IN (\(placeholders)))"
                arguments.append(contentsOf: allNames.sorted())
            }

            conditions.append(filter.polarity == .include ? predicate : "NOT \(predicate)")
        }
    }

    /// Build FTS5 query from user search text.
    /// - Escapes special characters for FTS5 safety
    /// - Appends * for prefix matching on partial words
    /// - Handles multi-word queries as AND (all terms must match)
    /// - Preserves quoted phrases as exact phrase matches
    /// - Supports scoped search using FTS5 column prefix syntax
    private func buildFTSQuery(_ searchText: String, scope: SearchScope = .all) -> String {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Determine column prefix for scoped searches
        let columnPrefix: String? = {
            switch scope {
            case .all: return nil
            case .ocrOnly: return "ocrText"
            case .notesOnly: return "notes"
            case .authorOnly: return "author"
            case .visual: return nil  // Visual scope uses CLIP, not FTS
            }
        }()

        let terms = parseFTSTerms(from: trimmed).compactMap { term -> String? in
            switch term {
            case .phrase(let phrase):
                let cleaned = sanitizeFTSPhrase(phrase)
                guard !cleaned.isEmpty else { return nil }
                if let prefix = columnPrefix {
                    return "\(prefix):\"\(cleaned)\""
                } else {
                    return "\"\(cleaned)\""
                }

            case .token(let token):
                let cleaned = sanitizeFTSToken(token)
                guard !cleaned.isEmpty else { return nil }
                if let prefix = columnPrefix {
                    return "\(prefix):\"\(cleaned)\"*"
                } else {
                    return "\"\(cleaned)\"*"
                }
            }
        }

        // Join with space - FTS5 treats this as implicit AND
        return terms.joined(separator: " ")
    }

    private enum FTSTerm {
        case token(String)
        case phrase(String)
    }

    private func parseFTSTerms(from searchText: String) -> [FTSTerm] {
        let ftsOperators: Set<String> = ["AND", "OR", "NOT", "NEAR"]
        var terms: [FTSTerm] = []
        var current = ""
        var isInsideQuotes = false

        for character in searchText {
            if character == "\"" {
                if isInsideQuotes {
                    if !current.isEmpty {
                        terms.append(.phrase(current))
                        current = ""
                    }
                    isInsideQuotes = false
                } else {
                    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        appendToken(current, to: &terms, skipping: ftsOperators)
                    }
                    current = ""
                    isInsideQuotes = true
                }
                continue
            }

            if character.isWhitespace && !isInsideQuotes {
                appendToken(current, to: &terms, skipping: ftsOperators)
                current = ""
                continue
            }

            current.append(character)
        }

        if isInsideQuotes {
            appendPhraseOrToken(current, to: &terms, skipping: ftsOperators)
        } else {
            appendToken(current, to: &terms, skipping: ftsOperators)
        }

        return terms
    }

    private func appendToken(_ rawValue: String, to terms: inout [FTSTerm], skipping operators: Set<String>) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !operators.contains(trimmed.uppercased()) else { return }
        terms.append(.token(trimmed))
    }

    private func appendPhraseOrToken(_ rawValue: String, to terms: inout [FTSTerm], skipping operators: Set<String>) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.contains(where: \.isWhitespace) {
            terms.append(.phrase(trimmed))
        } else {
            appendToken(trimmed, to: &terms, skipping: operators)
        }
    }

    private func sanitizeFTSToken(_ token: String) -> String {
        token
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "^", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: ":", with: "")
    }

    private func sanitizeFTSPhrase(_ phrase: String) -> String {
        phrase
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "^", with: "")
            .replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func notifyChange(_ change: MediaStoreChange = .reload) {
        changesSubject.send()
        detailedChangesSubject.send(change)
    }

    private func mergedItem(primary: MediaItem, secondaries: [MediaItem]) -> MediaItem {
        var merged = primary

        var seenPaths = Set<String>()
        var combinedMediaFiles: [URL] = []
        for url in ([primary] + secondaries).flatMap(\.mediaFiles) {
            if seenPaths.insert(url.path).inserted {
                combinedMediaFiles.append(url)
            }
        }

        let mergedTags = mergeTags(primary.metadata.tags, with: secondaries.flatMap { $0.metadata.tags })
        let mergedNotes = mergeNotes(primary: primary, secondaries: secondaries)

        merged.mediaFiles = combinedMediaFiles
        merged.contextImage = primary.contextImage ?? secondaries.compactMap(\.contextImage).first
        merged.metadata = MediaMetadata(
            source: primary.metadata.source,
            platform: primary.metadata.platform,
            author: primary.metadata.author,
            originalDate: primary.metadata.originalDate,
            archivedDate: primary.metadata.archivedDate,
            downloadDate: primary.metadata.downloadDate,
            importDate: primary.metadata.importDate,
            starred: primary.metadata.starred || secondaries.contains(where: { $0.metadata.starred }),
            tags: mergedTags,
            notes: mergedNotes,
            originalDateString: primary.metadata.originalDateString,
            deleted: false,
            subreddit: primary.metadata.subreddit,
            boardName: primary.metadata.boardName,
            blogName: primary.metadata.blogName,
            channelName: primary.metadata.channelName,
            artistName: primary.metadata.artistName,
            galleryName: primary.metadata.galleryName,
            sourceTags: primary.metadata.sourceTags,
            uploadDate: primary.metadata.uploadDate,
            viewCount: primary.metadata.viewCount,
            likeCount: primary.metadata.likeCount
        )
        merged.indexedContent = nil
        // Primary's files keep their indices (they're first in combinedMediaFiles),
        // so its caption / ML attributes / per-file OCR all remain valid. Keep them;
        // only the appended secondary files need fresh analysis.
        merged.generatedCaption = primary.generatedCaption
        merged.mlAttributes = primary.mlAttributes
        merged.perFileOCR = primary.perFileOCR
        merged.pipelineStatus = "none"
        merged.pipelineLastError = nil
        merged.pipelineFailedAt = nil
        merged.pipelineRetryCount = nil

        return merged
    }

    private func mergeTags(_ primaryTags: [String], with secondaryTags: [String]) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []

        for tag in primaryTags + secondaryTags {
            let normalized = TagCanonicalizer.key(tag)
            if seen.insert(normalized).inserted {
                merged.append(tag)
            }
        }

        return merged
    }

    private func mergeNotes(primary: MediaItem, secondaries: [MediaItem]) -> String? {
        var sections: [String] = []

        if let notes = normalizedNotes(primary.metadata.notes) {
            sections.append(notes)
        }

        for item in secondaries {
            guard let notes = normalizedNotes(item.metadata.notes) else { continue }
            if sections.contains(notes) { continue }
            sections.append("[Combined from \(item.metadataFile.deletingPathExtension().lastPathComponent)]\n\(notes)")
        }

        return sections.isEmpty ? nil : sections.joined(separator: "\n\n---\n\n")
    }

    private func normalizedNotes(_ notes: String?) -> String? {
        guard let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func transferBoardMembershipsForCombine(
        db: Database,
        primaryID: UUID,
        secondaryIDs: [UUID]
    ) throws {
        guard !secondaryIDs.isEmpty else { return }

        for secondaryID in secondaryIDs {
            let memberships = try BoardMembership
                .filter(Column("itemId") == secondaryID.uuidString)
                .fetchAll(db)

            for membership in memberships {
                let existing = try BoardMembership
                    .filter(Column("boardId") == membership.boardId.uuidString && Column("itemId") == primaryID.uuidString)
                    .fetchOne(db)

                if existing == nil {
                    try db.execute(
                        sql: """
                            UPDATE board_memberships
                            SET itemId = ?
                            WHERE boardId = ? AND itemId = ?
                        """,
                        arguments: [primaryID.uuidString, membership.boardId.uuidString, secondaryID.uuidString]
                    )
                } else {
                    try BoardMembership.removeAndCompact(db: db, boardId: membership.boardId, itemId: secondaryID)
                }
            }
        }

        let placeholders = secondaryIDs.map { _ in "?" }.joined(separator: ", ")
        let arguments = [primaryID.uuidString] + secondaryIDs.map(\.uuidString)
        try db.execute(
            sql: "UPDATE collection_boards SET coverItemId = ? WHERE coverItemId IN (\(placeholders))",
            arguments: StatementArguments(arguments)
        )
    }

    private func transferCanvasPlacementsForCombine(
        db: Database,
        primaryID: UUID,
        secondaryIDs: [UUID]
    ) throws {
        guard !secondaryIDs.isEmpty else { return }

        for secondaryID in secondaryIDs {
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, canvasId FROM canvas_placements WHERE mediaItemId = ?",
                arguments: [secondaryID.uuidString]
            )

            for row in rows {
                guard let placementID: String = row["id"],
                      let canvasId: String = row["canvasId"] else { continue }

                let hasPrimaryPlacement = (try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM canvas_placements
                        WHERE canvasId = ? AND mediaItemId = ?
                    """,
                    arguments: [canvasId, primaryID.uuidString]
                ) ?? 0) > 0

                if hasPrimaryPlacement {
                    try db.execute(
                        sql: "DELETE FROM canvas_placements WHERE id = ?",
                        arguments: [placementID]
                    )
                } else {
                    try db.execute(
                        sql: "UPDATE canvas_placements SET mediaItemId = ? WHERE id = ?",
                        arguments: [primaryID.uuidString, placementID]
                    )
                }
            }
        }
    }

    private func transferViewHistoryForCombine(
        db: Database,
        primaryID: UUID,
        secondaryIDs: [UUID]
    ) throws {
        guard !secondaryIDs.isEmpty else { return }

        let placeholders = secondaryIDs.map { _ in "?" }.joined(separator: ", ")
        let arguments = [primaryID.uuidString] + secondaryIDs.map(\.uuidString)
        try db.execute(
            sql: "UPDATE view_events SET itemId = ? WHERE itemId IN (\(placeholders))",
            arguments: StatementArguments(arguments)
        )
    }

    private func mergeReviewStateForCombine(
        db: Database,
        primaryID: UUID,
        secondaryIDs: [UUID]
    ) throws {
        guard !secondaryIDs.isEmpty else { return }

        let primaryState = try ReviewStateRecord
            .filter(Column("itemId") == primaryID.uuidString)
            .fetchOne(db)

        let secondaryStates = try secondaryIDs.compactMap { id in
            try ReviewStateRecord
                .filter(Column("itemId") == id.uuidString)
                .fetchOne(db)
        }

        if let baseState = ([primaryState] + secondaryStates).compactMap({ $0 }).first {
            let mergedState = ([primaryState] + secondaryStates).compactMap({ $0 }).dropFirst().reduce(baseState) { partial, next in
                ReviewStateRecord(
                    itemId: primaryID,
                    stability: max(partial.stability, next.stability),
                    difficulty: partial.difficulty,
                    scheduledDays: max(partial.scheduledDays, next.scheduledDays),
                    reps: max(partial.reps, next.reps),
                    lapses: max(partial.lapses, next.lapses),
                    lastReviewAt: max(partial.lastReviewAt ?? .distantPast, next.lastReviewAt ?? .distantPast) == .distantPast
                        ? nil
                        : max(partial.lastReviewAt ?? .distantPast, next.lastReviewAt ?? .distantPast),
                    nextReviewAt: min(partial.nextReviewAt, next.nextReviewAt),
                    interestScore: max(partial.interestScore, next.interestScore)
                )
            }
            try mergedState.save(db)
        }

        let placeholders = secondaryIDs.map { _ in "?" }.joined(separator: ", ")
        try db.execute(
            sql: "DELETE FROM review_state WHERE itemId IN (\(placeholders))",
            arguments: StatementArguments(secondaryIDs.map(\.uuidString))
        )
    }

    private func clearDuplicateGroupsForCombine(db: Database, itemIDs: [UUID]) throws {
        guard !itemIDs.isEmpty else { return }

        let placeholders = itemIDs.map { _ in "?" }.joined(separator: ", ")
        let arguments = StatementArguments(itemIDs.map(\.uuidString))

        try db.execute(
            sql: "UPDATE duplicate_groups SET primaryItemId = NULL WHERE primaryItemId IN (\(placeholders))",
            arguments: arguments
        )
        try db.execute(
            sql: "DELETE FROM duplicate_group_members WHERE itemId IN (\(placeholders))",
            arguments: arguments
        )

        let invalidGroupIDs = try String.fetchAll(db, sql: """
            SELECT g.id
            FROM duplicate_groups g
            LEFT JOIN duplicate_group_members m ON m.groupId = g.id
            GROUP BY g.id
            HAVING COUNT(m.itemId) < 2
        """)

        guard !invalidGroupIDs.isEmpty else { return }

        let deletePlaceholders = invalidGroupIDs.map { _ in "?" }.joined(separator: ", ")
        try db.execute(
            sql: "DELETE FROM duplicate_group_members WHERE groupId IN (\(deletePlaceholders))",
            arguments: StatementArguments(invalidGroupIDs)
        )
        try db.execute(
            sql: "DELETE FROM duplicate_groups WHERE id IN (\(deletePlaceholders))",
            arguments: StatementArguments(invalidGroupIDs)
        )
    }

    /// Invalidates derived ML/OCR/color data for the items being absorbed into a combine
    /// (the SECONDARIES only). The primary keeps its derived data — its files retain their
    /// indices (they're first in the merged mediaFiles array), so its caption/attributes/
    /// per-file OCR all remain valid; mergedItem() already carries those forward into the
    /// merged record write, so no primary UPDATE is needed here.
    private func invalidateDerivedDataForCombine(
        db: Database,
        itemIDs: [UUID],
        primaryID: UUID
    ) throws {
        let secondaryIDs = itemIDs.filter { $0 != primaryID }
        guard !secondaryIDs.isEmpty else { return }

        let placeholders = secondaryIDs.map { _ in "?" }.joined(separator: ", ")
        let idArgs = StatementArguments(secondaryIDs.map(\.uuidString))

        try db.execute(
            sql: "DELETE FROM media_attributes WHERE item_id IN (\(placeholders))",
            arguments: idArgs
        )
        try db.execute(
            sql: "DELETE FROM clip_vectors WHERE itemId IN (\(placeholders))",
            arguments: idArgs
        )
        // Per-file OCR/annotations/segments are transferred by stable asset ID;
        // unadopted or ambiguous source associations remain recoverable.
        try db.execute(
            sql: "DELETE FROM media_colors WHERE item_id IN (\(placeholders))",
            arguments: idArgs
        )
    }
}

// MARK: - Contextual Queries (Focus Sidebar)

extension MediaStore {
    /// The author's thumbnail page and full count use one database snapshot.
    func fetchAuthorRelated(_ author: String, excluding itemId: UUID,
                            limit: Int = 12) async throws -> (items: [MediaItem], total: Int) {
        try await database.read { db in
            let predicate = "author = ? AND id != ? AND (deletedAt IS NULL OR deletedAt = '')"
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE \(predicate)",
                arguments: [author, itemId.uuidString]) ?? 0
            let records = try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items WHERE \(predicate)
                ORDER BY archivedDate DESC, id DESC LIMIT ?
                """, arguments: [author, itemId.uuidString, max(0, limit)])
            let assets = try ItemAssetStore.fetchBatch(in: db, itemIDs: records.map(\.id))
            let items = records.compactMap { record in
                record.toMediaItem(withPerFileOCR: [:], assets: assets[record.id] ?? [])
            }
            return (items, total)
        }
    }

    /// Fetch items by the same author, excluding the given item. Limited to 12.
    func fetchByAuthor(_ author: String, excluding itemId: UUID) async throws -> [MediaItem] {
        try await database.read { db in
            let sql = """
                SELECT * FROM media_items
                WHERE author = ? AND id != ? AND (deletedAt IS NULL OR deletedAt = '')
                ORDER BY archivedDate DESC
                LIMIT 36  -- over-fetch; FocusContextSidebar dedupes and caps each section at 12
                """
            let records = try MediaItemRecord.fetchAll(db, sql: sql, arguments: [author, itemId.uuidString])
            let itemIds = records.map { $0.id }
            let assets = try ItemAssetStore.fetchBatch(in: db, itemIDs: itemIds)
            let perFileOCRMap = try self.loadPerFileOCRBatch(db: db, itemIds: itemIds)
            let mlAttributeMap = try self.loadMLAttributesBatch(db: db, itemIds: itemIds)
            return records.compactMap { record in
                record.toMediaItem(withPerFileOCR: perFileOCRMap[record.id] ?? [:], mlAttributes: mlAttributeMap[record.id] ?? [:], assets: assets[record.id] ?? [])
            }
        }
    }

    /// Fetch sibling items directly inside `parentPath` (the item's containing folder),
    /// excluding the given item. Limited to 12.
    func fetchInFolder(_ parentPath: String, excluding itemId: UUID) async throws -> [MediaItem] {
        try await database.read { db in
            let sql = """
                SELECT * FROM media_items
                WHERE basePathString LIKE ? AND basePathString NOT LIKE ? AND id != ? AND (deletedAt IS NULL OR deletedAt = '')
                ORDER BY archivedDate DESC
                LIMIT 36  -- over-fetch; FocusContextSidebar dedupes and caps each section at 12
                """
            let records = try MediaItemRecord.fetchAll(
                db, sql: sql, arguments: [parentPath + "/%", parentPath + "/%/%", itemId.uuidString]
            )
            let itemIds = records.map { $0.id }
            let assets = try ItemAssetStore.fetchBatch(in: db, itemIDs: itemIds)
            let perFileOCRMap = try self.loadPerFileOCRBatch(db: db, itemIds: itemIds)
            let mlAttributeMap = try self.loadMLAttributesBatch(db: db, itemIds: itemIds)
            return records.compactMap { record in
                record.toMediaItem(withPerFileOCR: perFileOCRMap[record.id] ?? [:], mlAttributes: mlAttributeMap[record.id] ?? [:], assets: assets[record.id] ?? [])
            }
        }
    }

    /// Fetch items sharing any of the given tags, excluding the given item. Limited to 12.
    func fetchBySharedTags(_ tags: [String], excluding itemId: UUID) async throws -> [MediaItem] {
        guard !tags.isEmpty else { return [] }
        return try await database.read { db in
            // tags are stored as a JSON array in tagsJSON
            let tagConditions = tags.map { _ in "tagsJSON LIKE ?" }.joined(separator: " OR ")
            let sql = """
                SELECT * FROM media_items
                WHERE (\(tagConditions)) AND id != ? AND (deletedAt IS NULL OR deletedAt = '')
                ORDER BY archivedDate DESC
                LIMIT 36  -- over-fetch; FocusContextSidebar dedupes and caps each section at 12
                """
            var arguments: [DatabaseValueConvertible] = tags.map { "%\"\($0)\"%" as DatabaseValueConvertible }
            arguments.append(itemId.uuidString)
            let records = try MediaItemRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            let itemIds = records.map { $0.id }
            let assets = try ItemAssetStore.fetchBatch(in: db, itemIDs: itemIds)
            let perFileOCRMap = try self.loadPerFileOCRBatch(db: db, itemIds: itemIds)
            let mlAttributeMap = try self.loadMLAttributesBatch(db: db, itemIds: itemIds)
            return records.compactMap { record in
                record.toMediaItem(withPerFileOCR: perFileOCRMap[record.id] ?? [:], mlAttributes: mlAttributeMap[record.id] ?? [:], assets: assets[record.id] ?? [])
            }
        }
    }
}

// MARK: - CIE76 Color Distance

enum PerceptualColorMetric {
    /// Install on every pooled connection, including observation/count readers.
    /// SQLite streams candidates without hydrating their analysis payloads.
    static func install(in db: Database) {
        db.add(function: DatabaseFunction("nodraw_delta_e76", argumentCount: 6, pure: true) { values in
            guard let r = Int.fromDatabaseValue(values[0]),
                  let g = Int.fromDatabaseValue(values[1]),
                  let b = Int.fromDatabaseValue(values[2]),
                  let l = Double.fromDatabaseValue(values[3]),
                  let a = Double.fromDatabaseValue(values[4]),
                  let targetB = Double.fromDatabaseValue(values[5]) else { return nil }
            return deltaE76(lab1: rgbToLab(r: r, g: g, b: b), lab2: (l, a, targetB))
        })
    }
    /// Convert sRGB (0-255) to CIE LAB
    static func rgbToLab(r: Int, g: Int, b: Int) -> (L: Double, a: Double, b: Double) {
        // sRGB to linear
        func linearize(_ c: Double) -> Double {
            c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92
        }
        let rl = linearize(Double(r) / 255.0)
        let gl = linearize(Double(g) / 255.0)
        let bl = linearize(Double(b) / 255.0)

        // Linear RGB to XYZ (D65)
        var x = rl * 0.4124564 + gl * 0.3575761 + bl * 0.1804375
        var y = rl * 0.2126729 + gl * 0.7151522 + bl * 0.0721750
        var z = rl * 0.0193339 + gl * 0.1191920 + bl * 0.9503041

        // Normalize to D65 white point
        x /= 0.95047
        y /= 1.00000
        z /= 1.08883

        // XYZ to LAB
        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t) + (16.0 / 116.0)
        }
        let L = 116.0 * f(y) - 16.0
        let a = 500.0 * (f(x) - f(y))
        let bLab = 200.0 * (f(y) - f(z))

        return (L, a, bLab)
    }

    /// CIE76 DeltaE distance between two LAB colors
    static func deltaE76(lab1: (L: Double, a: Double, b: Double), lab2: (L: Double, a: Double, b: Double)) -> Double {
        let dL = lab1.L - lab2.L
        let da = lab1.a - lab2.a
        let db = lab1.b - lab2.b
        return sqrt(dL * dL + da * da + db * db)
    }
}
