import Foundation
import GRDB

// MARK: - Review Scheduler

/// Actor handling FSRS-4 spaced repetition scheduling.
/// Manages review state, calculates next review dates, and tracks interest scores.
actor ReviewScheduler {
    private let database: DatabaseManager

    // FSRS-4 parameters (optimized defaults)
    private let w: [Double] = [
        0.4,    // w0: initial stability
        0.6,    // w1: initial difficulty
        2.4,    // w2: stability increase base
        0.14,   // w3: difficulty adjustment
        1.0,    // w4: stability after lapse
        0.3,    // w5: difficulty decay
        1.2,    // w6: hard penalty
        0.02,   // w7: easy bonus
        1.5,    // w8: stability increase exponent
        0.1,    // w9: minimum stability
        0.9,    // w10: forgetting curve factor
        2.0,    // w11: memory strength factor
        0.2,    // w12: difficulty weight
        0.45    // w13: retrievability target (45% = optimal retention)
    ]

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    // MARK: - Review Operations

    /// Update review state after user rates an item.
    /// Implements FSRS-4 algorithm for scheduling.
    func updateAfterReview(itemId: UUID, grade: ReviewGrade) async throws {
        try await database.write { db in
            // Fetch or create review state
            var state = try ReviewStateRecord
                .fetchOne(db, sql: "SELECT * FROM review_state WHERE itemId = ?", arguments: [itemId.uuidString])
                ?? ReviewStateRecord.initial(itemId: itemId)

            let now = Date()
            let elapsedDays = state.lastReviewAt.map { now.timeIntervalSince($0) / 86400 } ?? 0

            // Calculate retrievability (probability of recall)
            let retrievability = self.calculateRetrievability(
                stability: state.stability,
                elapsedDays: elapsedDays
            )

            // Update based on grade
            switch grade {
            case .again:
                // Lapse - memory decayed, need to relearn
                state.lapses += 1
                state.stability = max(self.w[9], state.stability * self.w[4])
                state.difficulty = min(10, state.difficulty + self.w[3] * 2)
                state.scheduledDays = 1.0

            case .hard:
                // Recalled but with effort
                state.reps += 1
                state.stability = self.newStability(
                    current: state.stability,
                    difficulty: state.difficulty,
                    retrievability: retrievability,
                    grade: grade
                )
                state.difficulty = min(10, state.difficulty + self.w[3])
                state.scheduledDays = max(1, state.stability * self.w[6])

            case .good:
                // Normal recall
                state.reps += 1
                state.stability = self.newStability(
                    current: state.stability,
                    difficulty: state.difficulty,
                    retrievability: retrievability,
                    grade: grade
                )
                state.difficulty = max(1, state.difficulty - self.w[5] * 0.5)
                state.scheduledDays = state.stability

            case .easy:
                // Easy recall - boost stability
                state.reps += 1
                state.stability = self.newStability(
                    current: state.stability,
                    difficulty: state.difficulty,
                    retrievability: retrievability,
                    grade: grade
                ) * (1 + self.w[7])
                state.difficulty = max(1, state.difficulty - self.w[5])
                state.scheduledDays = state.stability * (1 + self.w[7])
            }

            // Update timestamps
            state.lastReviewAt = now
            state.nextReviewAt = now.addingTimeInterval(state.scheduledDays * 86400)

            // Save state
            try state.save(db)

            // Note: We do NOT log a view event here to avoid duplicates.
            // View events should be logged when the user actually views an item
            // (e.g., in SingleFocusView), not during the review process.
            // The review grade itself is the relevant data, stored in the state.
        }
    }

    /// Calculate new stability based on FSRS-4 formula.
    /// Nonisolated since it only uses constant parameters.
    private nonisolated func newStability(
        current: Double,
        difficulty: Double,
        retrievability: Double,
        grade: ReviewGrade
    ) -> Double {
        // FSRS-4 stability formula
        let difficultyFactor = exp(-w[12] * (difficulty - 5) / 5)
        let retrievabilityBonus = 1 + (1 - retrievability) * w[11]

        var gradeMultiplier: Double
        switch grade {
        case .again: gradeMultiplier = 0.5
        case .hard: gradeMultiplier = 0.9
        case .good: gradeMultiplier = 1.0
        case .easy: gradeMultiplier = 1.2
        }

        let newS = current * pow(w[2], 1 / pow(current, w[8])) * difficultyFactor * retrievabilityBonus * gradeMultiplier

        return max(w[9], newS) // Minimum stability
    }

    /// Calculate probability of recall (retrievability).
    /// Nonisolated since it only uses constant parameters.
    private nonisolated func calculateRetrievability(stability: Double, elapsedDays: Double) -> Double {
        // FSRS forgetting curve: R = (1 + t/s)^(-w[10])
        guard stability > 0 else { return 0 }
        return pow(1 + elapsedDays / stability, -w[10])
    }

    // MARK: - Overdue Handling

    /// Recalculate overdue items on app launch.
    /// Decays stability for items overdue > 7 days.
    func recalculateOverdueReviews() async throws {
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)

        try await database.write { db in
            let overdueItems = try ReviewStateRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM review_state
                    WHERE nextReviewAt < ?
                    AND lastReviewAt IS NOT NULL
                """,
                arguments: [sevenDaysAgo]
            )

            for var item in overdueItems {
                let daysOverdue = Date().timeIntervalSince(item.nextReviewAt) / 86400

                // Stability decays 10% per week overdue
                item.stability *= pow(0.9, daysOverdue / 7)

                // Due now
                item.nextReviewAt = Date()

                try item.update(db)
            }

            if !overdueItems.isEmpty {
                logInfo("Recalculated \(overdueItems.count) overdue review items")
            }
        }
    }

    // MARK: - Interest Scoring

    /// Update interest score based on user engagement.
    /// Called when user stars, tags, or adds notes to an item.
    func updateInterestScore(itemId: UUID) async throws {
        try await database.write { db in
            // Fetch the media item to check engagement
            guard let itemRow = try Row.fetchOne(
                db,
                sql: "SELECT starred, tagsJSON, notes FROM media_items WHERE id = ?",
                arguments: [itemId.uuidString]
            ) else { return }

            let starred: Bool = itemRow["starred"] ?? false
            let tagsJSON: String = itemRow["tagsJSON"] ?? "[]"
            let notes: String? = itemRow["notes"]

            // Calculate interest score
            var score: Double = 0.5 // Base score

            // Starred: +0.3
            if starred {
                score += 0.3
            }

            // Tags: +0.1 per tag (max +0.3)
            if let tags = try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8)) {
                score += min(0.3, Double(tags.count) * 0.1)
            }

            // Notes: +0.2
            if let n = notes, !n.isEmpty {
                score += 0.2
            }

            // Cap at 1.0
            score = min(1.0, score)

            // Fetch or create review state
            if var state = try ReviewStateRecord.fetchOne(
                db,
                sql: "SELECT * FROM review_state WHERE itemId = ?",
                arguments: [itemId.uuidString]
            ) {
                state.interestScore = score
                try state.update(db)
            } else {
                var newState = ReviewStateRecord.initial(itemId: itemId)
                newState.interestScore = score
                try newState.insert(db)
            }
        }
    }

    /// Record a view event (e.g., when SingleFocusView opens).
    func recordViewEvent(itemId: UUID, duration: TimeInterval? = nil) async throws {
        try await database.write { db in
            let event = ViewEventRecord(
                id: nil,
                itemId: itemId,
                viewedAt: Date(),
                durationSeconds: duration,
                action: .view
            )
            try event.insert(db)

            // Update interest score if view was long enough
            if let dur = duration, dur > 5 {
                if var state = try ReviewStateRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM review_state WHERE itemId = ?",
                    arguments: [itemId.uuidString]
                ) {
                    state.interestScore = min(1.0, state.interestScore + 0.1)
                    try state.update(db)
                }
            }
        }
    }

    // MARK: - Fetch Operations

    /// Fetch items due for review, sorted by most overdue first.
    func fetchDueItems(limit: Int = 50) async throws -> [UUID] {
        try await database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT itemId FROM review_state
                    WHERE nextReviewAt <= datetime('now')
                    ORDER BY nextReviewAt ASC
                    LIMIT ?
                """,
                arguments: [limit]
            )

            return rows.compactMap { row -> UUID? in
                guard let idString: String = row["itemId"] else { return nil }
                return UUID(uuidString: idString)
            }
        }
    }

    /// Count items due for review.
    func countDueItems() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM review_state WHERE nextReviewAt <= datetime('now')"
            ) ?? 0
        }
    }

    /// Fetch review state for a specific item.
    func fetchState(for itemId: UUID) async throws -> ReviewStateRecord? {
        try await database.read { db in
            try ReviewStateRecord.fetchOne(
                db,
                sql: "SELECT * FROM review_state WHERE itemId = ?",
                arguments: [itemId.uuidString]
            )
        }
    }

    /// Initialize review state for items that don't have one.
    /// Called during initial scan or when Rediscover is first enabled.
    func initializeForItems(_ itemIds: [UUID]) async throws {
        try await database.write { db in
            let now = Date()
            let baseInterval: TimeInterval = 24 * 3600 // 1 day

            for (index, itemId) in itemIds.enumerated() {
                // Check if already exists
                let exists = try Int.fetchOne(
                    db,
                    sql: "SELECT 1 FROM review_state WHERE itemId = ?",
                    arguments: [itemId.uuidString]
                ) ?? 0 > 0

                if !exists {
                    // Stagger initial reviews across time to avoid all items being due at once
                    let staggerDays = Double(index) / 10.0 // 0.1 days between each
                    var state = ReviewStateRecord.initial(itemId: itemId)
                    state.nextReviewAt = now.addingTimeInterval(baseInterval + staggerDays * 86400)
                    try state.insert(db)
                }
            }
        }
    }

    /// Snooze an item by pushing its next review date forward.
    /// Used when user skips an item during review.
    func snoozeItem(_ itemId: UUID, days: Int) async throws {
        try await database.write { db in
            guard var state = try ReviewStateRecord.fetchOne(
                db,
                sql: "SELECT * FROM review_state WHERE itemId = ?",
                arguments: [itemId.uuidString]
            ) else { return }

            // Push next review date forward by specified days
            state.nextReviewAt = Date().addingTimeInterval(Double(days) * 86400)
            try state.update(db)
        }
    }

    /// Get predicted next review date for each grade.
    func predictNextReview(for itemId: UUID) async throws -> [ReviewGrade: Date] {
        guard let state = try await fetchState(for: itemId) else {
            return [:]
        }

        let now = Date()
        var predictions: [ReviewGrade: Date] = [:]

        for grade in ReviewGrade.allCases {
            let elapsedDays = state.lastReviewAt.map { now.timeIntervalSince($0) / 86400 } ?? 0
            let retrievability = calculateRetrievability(stability: state.stability, elapsedDays: elapsedDays)

            var scheduledDays: Double

            switch grade {
            case .again:
                scheduledDays = 1.0
            case .hard:
                let newS = newStability(current: state.stability, difficulty: state.difficulty, retrievability: retrievability, grade: grade)
                scheduledDays = max(1, newS * w[6])
            case .good:
                let newS = newStability(current: state.stability, difficulty: state.difficulty, retrievability: retrievability, grade: grade)
                scheduledDays = newS
            case .easy:
                let newS = newStability(current: state.stability, difficulty: state.difficulty, retrievability: retrievability, grade: grade) * (1 + w[7])
                scheduledDays = newS * (1 + w[7])
            }

            predictions[grade] = now.addingTimeInterval(scheduledDays * 86400)
        }

        return predictions
    }

    // MARK: - Undo Support (Issue #5)

    /// Restore a previous review state (for undo).
    func restoreState(_ state: ReviewStateRecord) async throws {
        try await database.write { db in
            try state.save(db)
        }
    }

    /// Remove review state for an item (for undo when item was newly added).
    /// Also cleans up orphan view_events for this item.
    func removeState(for itemId: UUID) async throws {
        try await database.write { db in
            // Delete review state
            try db.execute(
                sql: "DELETE FROM review_state WHERE itemId = ?",
                arguments: [itemId.uuidString]
            )
            // Delete orphan view_events (no FK cascade exists for this table)
            try db.execute(
                sql: "DELETE FROM view_events WHERE itemId = ?",
                arguments: [itemId.uuidString]
            )
        }
    }
}
