import Foundation
import GRDB

// MARK: - Review State

/// FSRS-4 spaced repetition state for a media item.
/// Tracks scheduling parameters for the "Rediscover" feature.
struct ReviewStateRecord: Codable, Equatable, Hashable {
    let itemId: UUID
    var stability: Double        // FSRS S parameter - memory stability in days
    var difficulty: Double       // FSRS D parameter (1-10 scale)
    var scheduledDays: Double    // Days until next review
    var reps: Int                // Total review count
    var lapses: Int              // Times the item was "forgotten" (rated Again)
    var lastReviewAt: Date?      // Last review timestamp
    var nextReviewAt: Date       // Scheduled next review
    var interestScore: Double    // 0-1 based on user engagement

    /// Default initial state for new items
    static func initial(itemId: UUID) -> ReviewStateRecord {
        ReviewStateRecord(
            itemId: itemId,
            stability: 1.0,
            difficulty: 5.0,
            scheduledDays: 1.0,
            reps: 0,
            lapses: 0,
            lastReviewAt: nil,
            nextReviewAt: Date().addingTimeInterval(24 * 3600), // Due tomorrow
            interestScore: 0.5
        )
    }

    /// Check if item is due for review
    var isDue: Bool {
        nextReviewAt <= Date()
    }

    /// Days overdue (negative if not yet due)
    var daysOverdue: Double {
        Date().timeIntervalSince(nextReviewAt) / 86400
    }
}

// MARK: - GRDB Record

extension ReviewStateRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "review_state"

    static func createTable(in db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) { t in
            t.column("itemId", .text).primaryKey()
            t.column("stability", .double).notNull().defaults(to: 1.0)
            t.column("difficulty", .double).notNull().defaults(to: 5.0)
            t.column("scheduledDays", .double).notNull().defaults(to: 1.0)
            t.column("reps", .integer).notNull().defaults(to: 0)
            t.column("lapses", .integer).notNull().defaults(to: 0)
            t.column("lastReviewAt", .datetime)
            t.column("nextReviewAt", .datetime).notNull()
            t.column("interestScore", .double).notNull().defaults(to: 0.5)
        }

        // Index for finding due items
        try db.create(
            index: "idx_review_state_next",
            on: databaseTableName,
            columns: ["nextReviewAt"],
            ifNotExists: true
        )

        // Index for interest-based ordering
        try db.create(
            index: "idx_review_state_interest",
            on: databaseTableName,
            columns: ["interestScore"],
            ifNotExists: true
        )
    }

    // MARK: - Custom Encoding/Decoding for UUID

    func encode(to container: inout PersistenceContainer) {
        container["itemId"] = itemId.uuidString
        container["stability"] = stability
        container["difficulty"] = difficulty
        container["scheduledDays"] = scheduledDays
        container["reps"] = reps
        container["lapses"] = lapses
        container["lastReviewAt"] = lastReviewAt
        container["nextReviewAt"] = nextReviewAt
        container["interestScore"] = interestScore
    }

    init(row: Row) throws {
        guard let idString: String = row["itemId"],
              let id = UUID(uuidString: idString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid or missing UUID in itemId column"
                )
            )
        }
        self.itemId = id
        self.stability = row["stability"]
        self.difficulty = row["difficulty"]
        self.scheduledDays = row["scheduledDays"]
        self.reps = row["reps"]
        self.lapses = row["lapses"]
        self.lastReviewAt = row["lastReviewAt"]
        self.nextReviewAt = row["nextReviewAt"]
        self.interestScore = row["interestScore"]
    }
}

// MARK: - View Event

/// Records a view/interaction event for interest scoring.
struct ViewEventRecord: Codable, Equatable {
    let id: Int64?
    let itemId: UUID
    let viewedAt: Date
    let durationSeconds: Double?
    let action: ViewAction

    enum ViewAction: String, Codable {
        case view       // Item was viewed
        case star       // Item was starred
        case unstar     // Item was unstarred
        case tag        // Tag was added
        case note       // Note was added/edited
        case skip       // Skipped during review
    }
}

extension ViewEventRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "view_events"

    static func createTable(in db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("itemId", .text).notNull()
            t.column("viewedAt", .datetime).notNull()
            t.column("durationSeconds", .double)
            t.column("action", .text).notNull()
        }

        // Index for item lookups
        try db.create(
            index: "idx_view_events_item",
            on: databaseTableName,
            columns: ["itemId"],
            ifNotExists: true
        )

        // Index for time-based queries
        try db.create(
            index: "idx_view_events_time",
            on: databaseTableName,
            columns: ["viewedAt"],
            ifNotExists: true
        )
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["itemId"] = itemId.uuidString
        container["viewedAt"] = viewedAt
        container["durationSeconds"] = durationSeconds
        container["action"] = action.rawValue
    }

    init(row: Row) throws {
        self.id = row["id"]
        guard let idString: String = row["itemId"],
              let itemId = UUID(uuidString: idString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid or missing UUID in itemId column"
                )
            )
        }
        self.itemId = itemId
        self.viewedAt = row["viewedAt"]
        self.durationSeconds = row["durationSeconds"]
        guard let actionStr: String = row["action"],
              let action = ViewAction(rawValue: actionStr) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid action value"
                )
            )
        }
        self.action = action
    }
}

// MARK: - Review Grade

/// FSRS rating scale for review outcomes.
enum ReviewGrade: Int, CaseIterable {
    case again = 1   // Complete failure - forgot
    case hard = 2    // Recalled with difficulty
    case good = 3    // Recalled correctly
    case easy = 4    // Recalled easily

    var displayName: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }

    var keyboardShortcut: String {
        "\(rawValue)"
    }

    /// Color for UI display
    var color: (red: Double, green: Double, blue: Double) {
        switch self {
        case .again: return (0.85, 0.35, 0.35) // red
        case .hard: return (0.85, 0.65, 0.35)  // orange
        case .good: return (0.45, 0.75, 0.45)  // green
        case .easy: return (0.45, 0.65, 0.85)  // blue
        }
    }
}
