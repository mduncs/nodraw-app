import Foundation
import GRDB

// MARK: - TagRule

struct TagRule: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var enabled: Bool
    var sourceField: SourceField
    var matchType: MatchType
    var pattern: String
    var tagName: String
    var priority: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        sourceField: SourceField,
        matchType: MatchType = .exact,
        pattern: String,
        tagName: String,
        priority: Int = 100,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.sourceField = sourceField
        self.matchType = matchType
        self.pattern = pattern
        self.tagName = tagName
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - SourceField

enum SourceField: String, Codable, CaseIterable, Sendable {
    case subreddit
    case boardName = "board_name"
    case blogName = "blog_name"
    case channelName = "channel_name"
    case artistName = "artist_name"
    case galleryName = "gallery_name"
    case platform
    case sourceTag = "source_tag"
    // ML pipeline source fields (match against media_attributes)
    case sceneLabel = "scene_label"
    case detectedObject = "detected_object"
    case safetyFlag = "safety_flag"
    case curationScore = "curation_score"
    case junkFlag = "junk_flag"

    /// Whether this source field requires ML pipeline attributes (vs sidecar metadata).
    var isMLField: Bool {
        switch self {
        case .sceneLabel, .detectedObject, .safetyFlag, .curationScore, .junkFlag:
            return true
        default:
            return false
        }
    }
}

// MARK: - MatchType

enum MatchType: String, Codable, CaseIterable, Sendable {
    case exact
    case contains
    case prefix
}

// MARK: - TagRuleRecord (GRDB)

struct TagRuleRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tag_rules"

    let id: UUID
    var name: String
    var enabled: Bool
    var sourceField: String
    var matchType: String
    var pattern: String
    var tagName: String
    var priority: Int
    var createdAt: Date
    var updatedAt: Date

    init(from rule: TagRule) {
        self.id = rule.id
        self.name = rule.name
        self.enabled = rule.enabled
        self.sourceField = rule.sourceField.rawValue
        self.matchType = rule.matchType.rawValue
        self.pattern = rule.pattern
        self.tagName = rule.tagName
        self.priority = rule.priority
        self.createdAt = rule.createdAt
        self.updatedAt = rule.updatedAt
    }

    // MARK: - GRDB PersistableRecord

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["name"] = name
        container["enabled"] = enabled
        container["source_field"] = sourceField
        container["match_type"] = matchType
        container["pattern"] = pattern
        container["tag_name"] = tagName
        container["priority"] = priority
        container["created_at"] = createdAt
        container["updated_at"] = updatedAt
    }

    // MARK: - GRDB FetchableRecord

    init(row: Row) throws {
        guard let idString: String = row["id"],
              let id = UUID(uuidString: idString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid or missing UUID in tag_rules id column"
                )
            )
        }
        self.id = id
        self.name = row["name"]
        self.enabled = row["enabled"]
        self.sourceField = row["source_field"]
        self.matchType = row["match_type"]
        self.pattern = row["pattern"]
        self.tagName = row["tag_name"]
        self.priority = row["priority"]
        self.createdAt = row["created_at"]
        self.updatedAt = row["updated_at"]
    }

    // MARK: - Conversion

    func toTagRule() -> TagRule? {
        guard let field = SourceField(rawValue: sourceField),
              let match = MatchType(rawValue: matchType) else {
            return nil
        }
        return TagRule(
            id: id,
            name: name,
            enabled: enabled,
            sourceField: field,
            matchType: match,
            pattern: pattern,
            tagName: tagName,
            priority: priority,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - Schema

    static func createTable(in db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("name", .text).notNull()
            t.column("enabled", .boolean).notNull().defaults(to: true)
            t.column("source_field", .text).notNull()
            t.column("match_type", .text).notNull().defaults(to: "exact")
            t.column("pattern", .text).notNull()
            t.column("tag_name", .text).notNull()
            t.column("priority", .integer).notNull().defaults(to: 100)
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }

        try db.create(
            index: "idx_tag_rules_enabled",
            on: databaseTableName,
            columns: ["enabled"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_tag_rules_priority",
            on: databaseTableName,
            columns: ["priority"],
            ifNotExists: true
        )
    }
}
