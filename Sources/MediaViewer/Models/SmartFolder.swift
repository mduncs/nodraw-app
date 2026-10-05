import AppKit
import Foundation
import GRDB

// MARK: - SmartFolder

/// A saved search / rule-based folder that dynamically filters media items.
struct SmartFolder: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var icon: String            // SF Symbol name
    var rules: [FilterRule]
    var matchAll: Bool          // AND vs OR for multiple rules
    var sortOrder: SortOrder
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        icon: String = "folder.badge.gearshape",
        rules: [FilterRule],
        matchAll: Bool = true,
        sortOrder: SortOrder = .archivedDateDescending,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.rules = rules
        self.matchAll = matchAll
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Stored symbol names can predate the running OS. Earlier seeds used a symbol that
    /// does not exist, which rendered as a blank sidebar icon.
    var displayIcon: String {
        if icon == "rectangle.expand.horizontal" { return "pano" }
        return NSImage(systemSymbolName: icon, accessibilityDescription: nil) == nil ? "folder.badge.gearshape" : icon
    }
}

// MARK: - FilterRule

/// Individual filter condition for smart folders
enum FilterRule: Codable, Equatable, Hashable {
    case platform(PlatformFilter)
    case author(StringFilter)
    case dateRange(DateRangeFilter)
    case hasText(StringFilter)          // OCR text contains
    case colorBucket(ColorBucket)
    case starred(Bool)
    case hasTag(String)
    case tagsEmpty                      // No tags assigned
    case hasNotes(Bool)
    case hasVideo(Bool)
    case hasContextImage(Bool)
    case parseStatus(ParseStatusFilter) // Parse result status
    case isMetadataOnly(Bool)           // Has no media files (orphan .md)
    case isProcessed(Bool)              // Has indexed content
    case shape(ShapeFilter)             // Aspect ratio shape
    case fileExtension(Set<String>)     // File extension match

    /// Generate SQL WHERE clause fragment for this rule
    func sqlFragment() -> (sql: String, arguments: [DatabaseValueConvertible]) {
        switch self {
        case .platform(let filter):
            return filter.sqlFragment(column: "platform")

        case .author(let filter):
            return filter.sqlFragment(column: "author")

        case .dateRange(let filter):
            return filter.sqlFragment()

        case .hasText(let filter):
            // Uses FTS table
            // Note: FTS5 only supports suffix wildcard (term*), not prefix (*term).
            // For .contains, we fall back to LIKE which is slower but correct.
            switch filter {
            case .equals(let value):
                // Exact phrase match in FTS5
                // Use rowid for subquery because contentless FTS5 cannot retrieve column values
                let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
                return ("rowid IN (SELECT rowid FROM media_items_fts WHERE ocrText MATCH ?)", ["\"\(escaped)\""])
            case .contains(let value):
                // FTS5 doesn't support prefix wildcard, use LIKE fallback
                let escaped = MediaStore.escapeLikeValue(value)
                return ("ocrText LIKE ? ESCAPE '\\'", ["%\(escaped)%"])
            case .startsWith(let value):
                // FTS5 supports suffix wildcard for prefix matching
                // Use rowid for subquery because contentless FTS5 cannot retrieve column values
                let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
                return ("rowid IN (SELECT rowid FROM media_items_fts WHERE ocrText MATCH ?)", ["\"\(escaped)\"*"])
            case .isEmpty:
                return ("(ocrText IS NULL OR ocrText = '')", [])
            case .isNotEmpty:
                return ("ocrText IS NOT NULL AND ocrText != ''", [])
            }

        case .colorBucket(let bucket):
            let escaped = MediaStore.escapeLikeValue(bucket.rawValue)
            return ("dominantColorsJSON LIKE ? ESCAPE '\\'", ["%\"\(escaped)\"%"])

        case .starred(let value):
            return ("starred = ?", [value])

        case .hasTag(let tag):
            let escaped = MediaStore.escapeLikeValue(tag)
            return ("tagsJSON LIKE ? ESCAPE '\\'", ["%\"\(escaped)\"%"])

        case .tagsEmpty:
            // Tags stored as JSON array, empty = '[]' or NULL
            return ("(tagsJSON IS NULL OR tagsJSON = '[]')", [])

        case .hasNotes(let value):
            if value {
                return ("notes IS NOT NULL AND notes != ''", [])
            } else {
                return ("(notes IS NULL OR notes = '')", [])
            }

        case .hasVideo(let value):
            // Check if mediaFilesJSON contains video extensions
            if value {
                return ("(mediaFilesJSON LIKE '%.mp4%' OR mediaFilesJSON LIKE '%.mov%' OR mediaFilesJSON LIKE '%.webm%')", [])
            } else {
                return ("mediaFilesJSON NOT LIKE '%.mp4%' AND mediaFilesJSON NOT LIKE '%.mov%' AND mediaFilesJSON NOT LIKE '%.webm%'", [])
            }

        case .hasContextImage(let value):
            if value {
                return ("contextImageString IS NOT NULL", [])
            } else {
                return ("contextImageString IS NULL", [])
            }

        case .parseStatus(let filter):
            return filter.sqlFragment()

        case .isMetadataOnly(let value):
            // Check if mediaFilesJSON is empty array
            if value {
                return ("mediaFilesJSON = '[]'", [])
            } else {
                return ("mediaFilesJSON != '[]'", [])
            }

        case .isProcessed(let value):
            // Check if indexedContent fields are populated
            if value {
                return ("(ocrText IS NOT NULL OR dominantColorsJSON IS NOT NULL OR perceptualHash IS NOT NULL)", [])
            } else {
                return ("ocrText IS NULL AND dominantColorsJSON IS NULL AND perceptualHash IS NULL", [])
            }

        case .shape(let filter):
            return filter.sqlFragment()

        case .fileExtension(let extensions):
            let likes = extensions.map { _ in "basePathString LIKE ? ESCAPE '\\'" }
            let sql = "(" + likes.joined(separator: " OR ") + ")"
            let args: [DatabaseValueConvertible] = extensions.map { "%.\(MediaStore.escapeLikeValue($0.lowercased()))" }
            return (sql: sql, arguments: args)
        }
    }

    /// Human-readable description
    var description: String {
        switch self {
        case .platform(let filter):
            return "Platform \(filter.description)"
        case .author(let filter):
            return "Author \(filter.description)"
        case .dateRange(let filter):
            return filter.description
        case .hasText(let filter):
            return "Text \(filter.description)"
        case .colorBucket(let bucket):
            return "Color is \(bucket.rawValue)"
        case .starred(let value):
            return value ? "Is starred" : "Not starred"
        case .hasTag(let tag):
            return "Has tag \"\(tag)\""
        case .tagsEmpty:
            return "No tags"
        case .hasNotes(let value):
            return value ? "Has notes" : "No notes"
        case .hasVideo(let value):
            return value ? "Contains video" : "No video"
        case .hasContextImage(let value):
            return value ? "Has context image" : "No context image"
        case .parseStatus(let filter):
            return "Parse status \(filter.description)"
        case .isMetadataOnly(let value):
            return value ? "Metadata only (no media)" : "Has media files"
        case .isProcessed(let value):
            return value ? "Has been processed" : "Not yet processed"
        case .shape(let filter):
            return "Shape is \(filter.description)"
        case .fileExtension(let extensions):
            return "Extension is \(extensions.sorted().joined(separator: ", "))"
        }
    }
}

/// Parse status filter
enum ParseStatusFilter: Codable, Equatable, Hashable {
    case equals(ParseStatus)
    case notEquals(ParseStatus)
    case hasIssues  // partial or failed

    func sqlFragment() -> (sql: String, arguments: [DatabaseValueConvertible]) {
        switch self {
        case .equals(let status):
            return ("parseStatus = ?", [status.rawValue])
        case .notEquals(let status):
            return ("parseStatus != ?", [status.rawValue])
        case .hasIssues:
            return ("parseStatus != 'success'", [])
        }
    }

    var description: String {
        switch self {
        case .equals(let status):
            return "is \(status.rawValue)"
        case .notEquals(let status):
            return "is not \(status.rawValue)"
        case .hasIssues:
            return "has issues"
        }
    }
}

// MARK: - Filter Types

/// Aspect ratio shape filter
enum ShapeFilter: String, Codable, Equatable, Hashable, CaseIterable {
    case landscape    // aspectRatio > 1.1
    case portrait     // aspectRatio < 0.9
    case square       // aspectRatio 0.9...1.1
    case panoramic    // aspectRatio > 2.5

    func sqlFragment() -> (sql: String, arguments: [DatabaseValueConvertible]) {
        switch self {
        case .landscape:
            return ("aspectRatio > 1.1", [])
        case .portrait:
            return ("aspectRatio < 0.9", [])
        case .square:
            return ("aspectRatio BETWEEN 0.9 AND 1.1", [])
        case .panoramic:
            return ("aspectRatio > 2.5", [])
        }
    }

    var description: String { rawValue.capitalized }
}

/// Platform filter with common presets
enum PlatformFilter: Codable, Equatable, Hashable {
    case equals(String)
    case oneOf([String])

    static let twitter = PlatformFilter.equals("twitter")
    static let instagram = PlatformFilter.equals("instagram")
    static let reddit = PlatformFilter.equals("reddit")
    static let youtube = PlatformFilter.equals("youtube")

    func sqlFragment(column: String) -> (sql: String, arguments: [DatabaseValueConvertible]) {
        switch self {
        case .equals(let value):
            return ("\(column) = ?", [value])
        case .oneOf(let values):
            let placeholders = values.map { _ in "?" }.joined(separator: ", ")
            return ("\(column) IN (\(placeholders))", values)
        }
    }

    var description: String {
        switch self {
        // Display names ("X", "Google Arts"); the stored values stay raw.
        case .equals(let value):
            return "is \(LibraryFilterPresentation.platformName(value))"
        case .oneOf(let values):
            return "is one of: \(values.map(LibraryFilterPresentation.platformName).joined(separator: ", "))"
        }
    }
}

/// String matching filter
enum StringFilter: Codable, Equatable, Hashable {
    case equals(String)
    case contains(String)
    case startsWith(String)
    case isEmpty
    case isNotEmpty

    func sqlFragment(column: String) -> (sql: String, arguments: [DatabaseValueConvertible]) {
        switch self {
        case .equals(let value):
            return ("\(column) = ?", [value])
        case .contains(let value):
            let escaped = MediaStore.escapeLikeValue(value)
            return ("\(column) LIKE ? ESCAPE '\\'", ["%\(escaped)%"])
        case .startsWith(let value):
            let escaped = MediaStore.escapeLikeValue(value)
            return ("\(column) LIKE ? ESCAPE '\\'", ["\(escaped)%"])
        case .isEmpty:
            return ("(\(column) IS NULL OR \(column) = '')", [])
        case .isNotEmpty:
            return ("\(column) IS NOT NULL AND \(column) != ''", [])
        }
    }

    var description: String {
        switch self {
        case .equals(let value):
            return "is \"\(value)\""
        case .contains(let value):
            return "contains \"\(value)\""
        case .startsWith(let value):
            return "starts with \"\(value)\""
        case .isEmpty:
            return "is empty"
        case .isNotEmpty:
            return "is not empty"
        }
    }
}

/// Date range filter
struct DateRangeFilter: Codable, Equatable, Hashable {
    enum DateField: String, Codable {
        case original = "originalDate"
        case archived = "archivedDate"
    }

    enum RangeType: Codable, Equatable, Hashable {
        case after(Date)
        case before(Date)
        case between(Date, Date)
        case lastNDays(Int)
        case thisMonth
        case thisYear
    }

    let field: DateField
    let range: RangeType

    func sqlFragment() -> (sql: String, arguments: [DatabaseValueConvertible]) {
        let column = field.rawValue

        switch range {
        case .after(let date):
            return ("\(column) > ?", [date])
        case .before(let date):
            return ("\(column) < ?", [date])
        case .between(let start, let end):
            return ("\(column) BETWEEN ? AND ?", [start, end])
        case .lastNDays(let n):
            let date = Calendar.current.date(byAdding: .day, value: -n, to: Date()) ?? Date()
            return ("\(column) > ?", [date])
        case .thisMonth:
            let now = Date()
            let calendar = Calendar.current
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
            return ("\(column) >= ?", [startOfMonth])
        case .thisYear:
            let now = Date()
            let calendar = Calendar.current
            let startOfYear = calendar.date(from: calendar.dateComponents([.year], from: now))!
            return ("\(column) >= ?", [startOfYear])
        }
    }

    var description: String {
        let fieldName = field == .original ? "Created" : "Archived"
        switch range {
        case .after(let date):
            return "\(fieldName) after \(Self.formatDate(date))"
        case .before(let date):
            return "\(fieldName) before \(Self.formatDate(date))"
        case .between(let start, let end):
            return "\(fieldName) between \(Self.formatDate(start)) and \(Self.formatDate(end))"
        case .lastNDays(let n):
            return "\(fieldName) in last \(n) days"
        case .thisMonth:
            return "\(fieldName) this month"
        case .thisYear:
            return "\(fieldName) this year"
        }
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Sort Order

enum SortOrder: String, Codable, CaseIterable {
    case archivedDateDescending = "archived_desc"
    case archivedDateAscending = "archived_asc"
    case originalDateDescending = "original_desc"
    case originalDateAscending = "original_asc"
    case authorAscending = "author_asc"
    case platformAscending = "platform_asc"
    case starredDescending = "starred_desc"
    case authorDescending = "author_desc"
    case platformDescending = "platform_desc"

    var sqlFragment: String {
        switch self {
        case .archivedDateDescending:
            return "archivedDate DESC"
        case .archivedDateAscending:
            return "archivedDate ASC"
        case .originalDateDescending:
            return "originalDate DESC NULLS LAST"
        case .originalDateAscending:
            return "originalDate ASC NULLS LAST"
        case .authorAscending:
            return "author ASC NULLS LAST"
        case .authorDescending:
            return "author DESC NULLS LAST"
        case .platformAscending:
            return "platform ASC"
        case .platformDescending:
            return "platform DESC"
        case .starredDescending:
            return "starred DESC"
        }
    }

    var displayName: String {
        switch self {
        case .archivedDateDescending:
            return "Newest archived"
        case .archivedDateAscending:
            return "Oldest archived"
        case .originalDateDescending:
            return "Newest created"
        case .originalDateAscending:
            return "Oldest created"
        case .authorAscending:
            return "Author A-Z"
        case .authorDescending:
            return "Author Z-A"
        case .platformAscending:
            return "Platform A-Z"
        case .platformDescending:
            return "Platform Z-A"
        case .starredDescending:
            return "Starred first"
        }
    }
}

// MARK: - GRDB Record

extension SmartFolder: FetchableRecord, PersistableRecord {
    static let databaseTableName = "smart_folders"

    static func createTable(in db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("icon", .text).notNull()
            t.column("rulesJSON", .text).notNull()
            t.column("matchAll", .boolean).notNull().defaults(to: true)
            t.column("sortOrder", .text).notNull()
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }
    }

    // Custom encoding because rules need JSON serialization
    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["name"] = name
        container["icon"] = icon
        container["rulesJSON"] = (try? JSONEncoder().encode(rules))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        container["matchAll"] = matchAll
        container["sortOrder"] = sortOrder.rawValue
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
    }

    init(row: Row) throws {
        self.id = UUID(uuidString: row["id"]) ?? UUID()
        self.name = row["name"]
        self.icon = row["icon"]

        let rulesJSON: String = row["rulesJSON"]
        self.rules = (try? JSONDecoder().decode([FilterRule].self, from: Data(rulesJSON.utf8))) ?? []

        self.matchAll = row["matchAll"]
        self.sortOrder = SortOrder(rawValue: row["sortOrder"]) ?? .archivedDateDescending
        self.createdAt = row["createdAt"]
        self.updatedAt = row["updatedAt"]
    }
}

// MARK: - Default Smart Folders

extension SmartFolder {
    static let defaultFolders: [SmartFolder] = [
        SmartFolder(
            name: "Twitter",
            icon: "bird",
            rules: [.platform(.twitter)]
        ),
        SmartFolder(
            name: "Starred",
            icon: "star.fill",
            rules: [.starred(true)]
        ),
        SmartFolder(
            name: "Recent",
            icon: "clock",
            rules: [.dateRange(DateRangeFilter(field: .archived, range: .lastNDays(7)))]
        ),
        SmartFolder(
            name: "Has Text",
            icon: "text.quote",
            rules: [.hasText(.isNotEmpty)]
        ),
        SmartFolder(
            name: "Videos",
            icon: "video",
            rules: [.hasVideo(true)]
        ),
        SmartFolder(
            name: "Untagged",
            icon: "tag.slash",
            rules: [.tagsEmpty]
        ),
        // QA edge case folders
        SmartFolder(
            name: "Parse Issues",
            icon: "exclamationmark.triangle",
            rules: [.parseStatus(.hasIssues)]
        ),
        SmartFolder(
            name: "Metadata Only",
            icon: "doc.text",
            rules: [.isMetadataOnly(true)]
        ),
        SmartFolder(
            name: "Processing",
            icon: "gearshape.2",
            rules: [.isProcessed(false)]
        ),
        SmartFolder(
            name: "Panoramic",
            icon: "pano",
            rules: [.shape(.panoramic)]
        ),
        SmartFolder(
            name: "Portraits",
            icon: "rectangle.portrait",
            rules: [.shape(.portrait)]
        )
    ]
}
