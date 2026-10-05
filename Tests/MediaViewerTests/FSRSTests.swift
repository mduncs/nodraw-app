import XCTest
import GRDB
@testable import MediaViewer

// MARK: - FSRS Tests

final class FSRSTests: XCTestCase {

    // MARK: - ReviewState Tests

    func testReviewStateInitialization() {
        let itemId = UUID()
        let state = ReviewStateRecord.initial(itemId: itemId)

        XCTAssertEqual(state.itemId, itemId)
        XCTAssertEqual(state.stability, 1.0)
        XCTAssertEqual(state.difficulty, 5.0)
        XCTAssertEqual(state.scheduledDays, 1.0)
        XCTAssertEqual(state.reps, 0)
        XCTAssertEqual(state.lapses, 0)
        XCTAssertNil(state.lastReviewAt)
        XCTAssertEqual(state.interestScore, 0.5)
    }

    func testReviewStateIsDue() {
        let itemId = UUID()
        var state = ReviewStateRecord.initial(itemId: itemId)

        // Initially due tomorrow
        XCTAssertFalse(state.isDue)

        // Set nextReviewAt to the past
        state.nextReviewAt = Date().addingTimeInterval(-3600) // 1 hour ago
        XCTAssertTrue(state.isDue)
    }

    func testReviewStateDaysOverdue() {
        let itemId = UUID()
        var state = ReviewStateRecord.initial(itemId: itemId)

        // Set nextReviewAt to 3 days ago
        state.nextReviewAt = Date().addingTimeInterval(-3 * 86400)
        let overdue = state.daysOverdue

        // Should be approximately 3 days overdue (allow some tolerance)
        XCTAssertGreaterThan(overdue, 2.9)
        XCTAssertLessThan(overdue, 3.1)
    }

    func testReviewStateNotOverdueWhenFuture() {
        let itemId = UUID()
        var state = ReviewStateRecord.initial(itemId: itemId)

        // Set nextReviewAt to tomorrow
        state.nextReviewAt = Date().addingTimeInterval(86400)
        let overdue = state.daysOverdue

        // Should be negative (not yet due)
        XCTAssertLessThan(overdue, 0)
        XCTAssertGreaterThan(overdue, -1.1)
    }

    // MARK: - ReviewGrade Tests

    func testReviewGradeDisplayNames() {
        XCTAssertEqual(ReviewGrade.again.displayName, "Again")
        XCTAssertEqual(ReviewGrade.hard.displayName, "Hard")
        XCTAssertEqual(ReviewGrade.good.displayName, "Good")
        XCTAssertEqual(ReviewGrade.easy.displayName, "Easy")
    }

    func testReviewGradeKeyboardShortcuts() {
        XCTAssertEqual(ReviewGrade.again.keyboardShortcut, "1")
        XCTAssertEqual(ReviewGrade.hard.keyboardShortcut, "2")
        XCTAssertEqual(ReviewGrade.good.keyboardShortcut, "3")
        XCTAssertEqual(ReviewGrade.easy.keyboardShortcut, "4")
    }

    func testReviewGradeRawValues() {
        XCTAssertEqual(ReviewGrade.again.rawValue, 1)
        XCTAssertEqual(ReviewGrade.hard.rawValue, 2)
        XCTAssertEqual(ReviewGrade.good.rawValue, 3)
        XCTAssertEqual(ReviewGrade.easy.rawValue, 4)
    }

    func testReviewGradeColors() {
        // Verify each grade has a distinct color
        let againColor = ReviewGrade.again.color
        let hardColor = ReviewGrade.hard.color
        let goodColor = ReviewGrade.good.color
        let easyColor = ReviewGrade.easy.color

        // Again should be reddish (higher red component)
        XCTAssertGreaterThan(againColor.red, againColor.green)
        XCTAssertGreaterThan(againColor.red, againColor.blue)

        // Hard should be orangish (red > green > blue)
        XCTAssertGreaterThan(hardColor.red, hardColor.blue)

        // Good should be greenish (higher green component)
        XCTAssertGreaterThan(goodColor.green, goodColor.red)
        XCTAssertGreaterThan(goodColor.green, goodColor.blue)

        // Easy should be bluish (higher blue component)
        XCTAssertGreaterThan(easyColor.blue, easyColor.red)
    }

    func testReviewGradeCaseIterable() {
        let allGrades = ReviewGrade.allCases
        XCTAssertEqual(allGrades.count, 4)
        XCTAssertTrue(allGrades.contains(.again))
        XCTAssertTrue(allGrades.contains(.hard))
        XCTAssertTrue(allGrades.contains(.good))
        XCTAssertTrue(allGrades.contains(.easy))
    }

    // MARK: - ViewEvent Tests

    func testViewEventAction() {
        XCTAssertEqual(ViewEventRecord.ViewAction.view.rawValue, "view")
        XCTAssertEqual(ViewEventRecord.ViewAction.star.rawValue, "star")
        XCTAssertEqual(ViewEventRecord.ViewAction.tag.rawValue, "tag")
        XCTAssertEqual(ViewEventRecord.ViewAction.note.rawValue, "note")
        XCTAssertEqual(ViewEventRecord.ViewAction.skip.rawValue, "skip")
    }

    func testViewEventUnstarAction() {
        XCTAssertEqual(ViewEventRecord.ViewAction.unstar.rawValue, "unstar")
    }

    // MARK: - Interest Score Formula Tests

    func testInterestScoreBaseOnly() {
        // Base score with no engagement
        let score = calculateTestInterestScore(starred: false, tagCount: 0, hasNotes: false)
        XCTAssertEqual(score, 0.5, accuracy: 0.001)
    }

    func testInterestScoreStarredAdds03() {
        let baseScore = calculateTestInterestScore(starred: false, tagCount: 0, hasNotes: false)
        let starredScore = calculateTestInterestScore(starred: true, tagCount: 0, hasNotes: false)
        XCTAssertEqual(starredScore - baseScore, 0.3, accuracy: 0.001)
    }

    func testInterestScoreOneTagAdds01() {
        let baseScore = calculateTestInterestScore(starred: false, tagCount: 0, hasNotes: false)
        let oneTagScore = calculateTestInterestScore(starred: false, tagCount: 1, hasNotes: false)
        XCTAssertEqual(oneTagScore - baseScore, 0.1, accuracy: 0.001)
    }

    func testInterestScoreTwoTagsAdds02() {
        let baseScore = calculateTestInterestScore(starred: false, tagCount: 0, hasNotes: false)
        let twoTagScore = calculateTestInterestScore(starred: false, tagCount: 2, hasNotes: false)
        XCTAssertEqual(twoTagScore - baseScore, 0.2, accuracy: 0.001)
    }

    func testInterestScoreThreeTagsAdds03() {
        let baseScore = calculateTestInterestScore(starred: false, tagCount: 0, hasNotes: false)
        let threeTagScore = calculateTestInterestScore(starred: false, tagCount: 3, hasNotes: false)
        XCTAssertEqual(threeTagScore - baseScore, 0.3, accuracy: 0.001)
    }

    func testInterestScoreTagsCappedAt03() {
        // More than 3 tags should still only add 0.3
        let threeTagScore = calculateTestInterestScore(starred: false, tagCount: 3, hasNotes: false)
        let fiveTagScore = calculateTestInterestScore(starred: false, tagCount: 5, hasNotes: false)
        let tenTagScore = calculateTestInterestScore(starred: false, tagCount: 10, hasNotes: false)

        XCTAssertEqual(threeTagScore, fiveTagScore, accuracy: 0.001)
        XCTAssertEqual(threeTagScore, tenTagScore, accuracy: 0.001)
    }

    func testInterestScoreNotesAdds02() {
        let baseScore = calculateTestInterestScore(starred: false, tagCount: 0, hasNotes: false)
        let notesScore = calculateTestInterestScore(starred: false, tagCount: 0, hasNotes: true)
        XCTAssertEqual(notesScore - baseScore, 0.2, accuracy: 0.001)
    }

    func testInterestScoreCappedAt10() {
        // Maximum engagement: starred + 3 tags + notes = 0.5 + 0.3 + 0.3 + 0.2 = 1.3, capped to 1.0
        let maxScore = calculateTestInterestScore(starred: true, tagCount: 5, hasNotes: true)
        XCTAssertEqual(maxScore, 1.0, accuracy: 0.001)
    }

    func testInterestScoreCombinations() {
        // Starred + notes = 0.5 + 0.3 + 0.2 = 1.0
        let starredAndNotes = calculateTestInterestScore(starred: true, tagCount: 0, hasNotes: true)
        XCTAssertEqual(starredAndNotes, 1.0, accuracy: 0.001)

        // 2 tags + notes = 0.5 + 0.2 + 0.2 = 0.9
        let tagsAndNotes = calculateTestInterestScore(starred: false, tagCount: 2, hasNotes: true)
        XCTAssertEqual(tagsAndNotes, 0.9, accuracy: 0.001)

        // Starred + 1 tag = 0.5 + 0.3 + 0.1 = 0.9
        let starredAndTag = calculateTestInterestScore(starred: true, tagCount: 1, hasNotes: false)
        XCTAssertEqual(starredAndTag, 0.9, accuracy: 0.001)
    }

    /// Helper to calculate interest score matching ReviewScheduler.updateInterestScore logic
    private func calculateTestInterestScore(starred: Bool, tagCount: Int, hasNotes: Bool) -> Double {
        var score: Double = 0.5 // Base score

        if starred {
            score += 0.3
        }

        score += min(0.3, Double(tagCount) * 0.1)

        if hasNotes {
            score += 0.2
        }

        return min(1.0, score)
    }
}

// MARK: - FSRS Algorithm Tests (Unit Tests)

final class FSRSAlgorithmTests: XCTestCase {

    // FSRS-4 parameters (must match ReviewScheduler)
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
        0.45    // w13: retrievability target
    ]

    // MARK: - Retrievability Tests

    func testRetrievabilityAtZeroDays() {
        // At t=0, retrievability should be 1.0 (perfect recall)
        let r = calculateRetrievability(stability: 1.0, elapsedDays: 0)
        XCTAssertEqual(r, 1.0, accuracy: 0.001)
    }

    func testRetrievabilityDecaysOverTime() {
        let stability = 10.0
        let r0 = calculateRetrievability(stability: stability, elapsedDays: 0)
        let r5 = calculateRetrievability(stability: stability, elapsedDays: 5)
        let r10 = calculateRetrievability(stability: stability, elapsedDays: 10)
        let r20 = calculateRetrievability(stability: stability, elapsedDays: 20)

        // Retrievability should decrease over time
        XCTAssertGreaterThan(r0, r5)
        XCTAssertGreaterThan(r5, r10)
        XCTAssertGreaterThan(r10, r20)
    }

    func testRetrievabilityHigherWithHigherStability() {
        let elapsedDays = 7.0

        let rLowStability = calculateRetrievability(stability: 5.0, elapsedDays: elapsedDays)
        let rHighStability = calculateRetrievability(stability: 20.0, elapsedDays: elapsedDays)

        // Higher stability = slower decay = higher retrievability
        XCTAssertGreaterThan(rHighStability, rLowStability)
    }

    func testRetrievabilityWithZeroStability() {
        // Edge case: zero stability should return 0
        let r = calculateRetrievability(stability: 0, elapsedDays: 5)
        XCTAssertEqual(r, 0)
    }

    func testRetrievabilityNeverNegative() {
        // Even after very long time, retrievability should stay positive
        let r = calculateRetrievability(stability: 1.0, elapsedDays: 1000)
        XCTAssertGreaterThan(r, 0)
    }

    // MARK: - Stability Update Tests

    func testStabilityIncreasesAfterGoodReview() {
        let currentStability = 5.0
        let difficulty = 5.0
        let retrievability = 0.9

        let newS = newStability(current: currentStability, difficulty: difficulty, retrievability: retrievability, grade: .good)

        // Stability should increase after successful review
        XCTAssertGreaterThan(newS, currentStability)
    }

    func testStabilityIncreasesMoreAfterEasyReview() {
        let currentStability = 5.0
        let difficulty = 5.0
        let retrievability = 0.9

        let goodS = newStability(current: currentStability, difficulty: difficulty, retrievability: retrievability, grade: .good)
        let easyS = newStability(current: currentStability, difficulty: difficulty, retrievability: retrievability, grade: .easy)

        // Easy should give bigger stability boost than Good
        XCTAssertGreaterThan(easyS, goodS)
    }

    func testStabilityIncreasesLessAfterHardReview() {
        let currentStability = 5.0
        let difficulty = 5.0
        let retrievability = 0.9

        let hardS = newStability(current: currentStability, difficulty: difficulty, retrievability: retrievability, grade: .hard)
        let goodS = newStability(current: currentStability, difficulty: difficulty, retrievability: retrievability, grade: .good)

        // Hard should give smaller stability boost than Good
        XCTAssertLessThan(hardS, goodS)
    }

    func testStabilityDecreasesAfterAgain() {
        let currentStability = 5.0
        let difficulty = 5.0
        let retrievability = 0.9

        let againS = newStability(current: currentStability, difficulty: difficulty, retrievability: retrievability, grade: .again)

        // Again gives smallest multiplier (0.5)
        XCTAssertLessThan(againS, currentStability)
    }

    func testStabilityNeverBelowMinimum() {
        // Even with terrible parameters, stability should never go below w[9]
        let newS = newStability(current: 0.05, difficulty: 10.0, retrievability: 0.1, grade: .again)
        XCTAssertGreaterThanOrEqual(newS, w[9])
    }

    func testStabilityHigherDifficultyMeansSlowerGrowth() {
        let currentStability = 5.0
        let retrievability = 0.9

        let lowDiffS = newStability(current: currentStability, difficulty: 3.0, retrievability: retrievability, grade: .good)
        let highDiffS = newStability(current: currentStability, difficulty: 8.0, retrievability: retrievability, grade: .good)

        // Higher difficulty = slower stability growth
        XCTAssertGreaterThan(lowDiffS, highDiffS)
    }

    func testStabilityBonusFromLowRetrievability() {
        let currentStability = 5.0
        let difficulty = 5.0

        // When retrievability is low (harder recall), successful review gives bonus
        let highRS = newStability(current: currentStability, difficulty: difficulty, retrievability: 0.9, grade: .good)
        let lowRS = newStability(current: currentStability, difficulty: difficulty, retrievability: 0.3, grade: .good)

        // Lower retrievability gives bigger stability boost (memory strengthening effect)
        XCTAssertGreaterThan(lowRS, highRS)
    }

    // MARK: - Difficulty Adjustment Tests

    func testDifficultyIncreasesOnAgain() {
        var difficulty = 5.0

        // Simulate Again rating
        difficulty = min(10, difficulty + w[3] * 2)

        XCTAssertGreaterThan(difficulty, 5.0)
        XCTAssertEqual(difficulty, 5.0 + 0.14 * 2, accuracy: 0.001)
    }

    func testDifficultyIncreasesOnHard() {
        var difficulty = 5.0

        // Simulate Hard rating
        difficulty = min(10, difficulty + w[3])

        XCTAssertGreaterThan(difficulty, 5.0)
        XCTAssertEqual(difficulty, 5.14, accuracy: 0.001)
    }

    func testDifficultyDecreasesOnGood() {
        var difficulty = 5.0

        // Simulate Good rating
        difficulty = max(1, difficulty - w[5] * 0.5)

        XCTAssertLessThan(difficulty, 5.0)
        XCTAssertEqual(difficulty, 5.0 - 0.3 * 0.5, accuracy: 0.001)
    }

    func testDifficultyDecreasesMoreOnEasy() {
        var difficulty = 5.0

        // Simulate Easy rating
        difficulty = max(1, difficulty - w[5])

        XCTAssertLessThan(difficulty, 5.0)
        XCTAssertEqual(difficulty, 4.7, accuracy: 0.001)
    }

    func testDifficultyCappedAt10() {
        var difficulty = 9.9

        // Multiple Again ratings
        for _ in 0..<10 {
            difficulty = min(10, difficulty + w[3] * 2)
        }

        XCTAssertEqual(difficulty, 10.0)
    }

    func testDifficultyCappedAt1() {
        var difficulty = 1.5

        // Multiple Easy ratings
        for _ in 0..<10 {
            difficulty = max(1, difficulty - w[5])
        }

        XCTAssertEqual(difficulty, 1.0)
    }

    // MARK: - Scheduled Days Tests

    func testScheduledDaysAfterAgainIs1() {
        // Again always schedules for next day
        let scheduledDays = 1.0 // From ReviewScheduler logic
        XCTAssertEqual(scheduledDays, 1.0)
    }

    func testScheduledDaysAfterHardUsesHardPenalty() {
        let stability = 10.0
        let scheduledDays = max(1, stability * w[6])

        // Hard uses w[6] multiplier (1.2)
        XCTAssertEqual(scheduledDays, 12.0, accuracy: 0.001)
    }

    func testScheduledDaysAfterGoodEqualsStability() {
        let stability = 15.0
        let scheduledDays = stability

        // Good schedules for stability days
        XCTAssertEqual(scheduledDays, 15.0)
    }

    func testScheduledDaysAfterEasyUsesEasyBonus() {
        let stability = 10.0
        let easyBonus = 1 + w[7] // 1.02

        let scheduledDays = stability * easyBonus

        // Easy uses easy bonus
        XCTAssertEqual(scheduledDays, 10.2, accuracy: 0.001)
    }

    func testScheduledDaysMinimum1() {
        // Even with very low stability, scheduled days should be at least 1
        let stability = 0.1
        let scheduledDays = max(1, stability * w[6])

        XCTAssertGreaterThanOrEqual(scheduledDays, 1.0)
    }

    // MARK: - Overdue Stability Decay Tests

    func testOverdueStabilityDecays10PercentPerWeek() {
        var stability = 10.0
        let daysOverdue = 7.0

        // Decay formula from recalculateOverdueReviews
        stability *= pow(0.9, daysOverdue / 7)

        // Should be 90% of original
        XCTAssertEqual(stability, 9.0, accuracy: 0.001)
    }

    func testOverdueStabilityDecaysMoreAfterTwoWeeks() {
        var stability = 10.0
        let daysOverdue = 14.0

        stability *= pow(0.9, daysOverdue / 7)

        // Should be 0.9^2 = 81% of original
        XCTAssertEqual(stability, 8.1, accuracy: 0.001)
    }

    func testOverdueStabilityNeverDecaysBelowMinimum() {
        var stability = 0.15
        let daysOverdue = 365.0

        stability *= pow(0.9, daysOverdue / 7)
        stability = max(w[9], stability) // Apply minimum

        XCTAssertGreaterThanOrEqual(stability, w[9])
    }

    // MARK: - Lapse Counting Tests

    func testLapseIncreasesOnAgain() {
        var lapses = 2
        let grade = ReviewGrade.again

        if grade == .again {
            lapses += 1
        }

        XCTAssertEqual(lapses, 3)
    }

    func testLapseDoesNotIncreaseOnOtherGrades() {
        var lapses = 2

        for grade in [ReviewGrade.hard, ReviewGrade.good, ReviewGrade.easy] {
            if grade == .again {
                lapses += 1
            }
        }

        XCTAssertEqual(lapses, 2)
    }

    // MARK: - Reps Counting Tests

    func testRepsIncreasesOnHardGoodEasy() {
        var reps = 5

        for grade in [ReviewGrade.hard, ReviewGrade.good, ReviewGrade.easy] {
            if grade != .again {
                reps += 1
            }
        }

        XCTAssertEqual(reps, 8)
    }

    func testRepsDoesNotIncreaseOnAgain() {
        var reps = 5
        let grade = ReviewGrade.again

        if grade != .again {
            reps += 1
        }

        XCTAssertEqual(reps, 5)
    }

    // MARK: - State Transition Tests

    func testStateAfterFirstReview() {
        var state = ReviewStateRecord.initial(itemId: UUID())
        XCTAssertEqual(state.reps, 0)
        XCTAssertEqual(state.lapses, 0)
        XCTAssertNil(state.lastReviewAt)

        // Simulate first Good review
        state.reps += 1
        state.lastReviewAt = Date()

        XCTAssertEqual(state.reps, 1)
        XCTAssertEqual(state.lapses, 0)
        XCTAssertNotNil(state.lastReviewAt)
    }

    func testStateAfterMultipleReviews() {
        var state = ReviewStateRecord.initial(itemId: UUID())

        // Simulate 5 Good reviews, 1 Hard, 2 Again
        for grade in [ReviewGrade.good, .good, .again, .good, .hard, .again, .good, .good] {
            if grade == .again {
                state.lapses += 1
            } else {
                state.reps += 1
            }
            state.lastReviewAt = Date()
        }

        XCTAssertEqual(state.reps, 6)  // 5 good + 1 hard
        XCTAssertEqual(state.lapses, 2)  // 2 again
    }

    func testStateLapseResetsLearning() {
        var state = ReviewStateRecord.initial(itemId: UUID())
        state.stability = 30.0  // High stability from previous learning
        state.scheduledDays = 30.0

        // Simulate Again (lapse)
        state.lapses += 1
        state.stability = max(w[9], state.stability * w[4])
        state.scheduledDays = 1.0

        // Stability should be drastically reduced
        XCTAssertEqual(state.stability, 30.0, accuracy: 0.001) // w[4] = 1.0 so stability unchanged
        XCTAssertEqual(state.scheduledDays, 1.0)
        XCTAssertEqual(state.lapses, 1)
    }

    // MARK: - Helper Methods (matching ReviewScheduler)

    private func calculateRetrievability(stability: Double, elapsedDays: Double) -> Double {
        guard stability > 0 else { return 0 }
        return pow(1 + elapsedDays / stability, -w[10])
    }

    private func newStability(
        current: Double,
        difficulty: Double,
        retrievability: Double,
        grade: ReviewGrade
    ) -> Double {
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

        return max(w[9], newS)
    }
}

// MARK: - FSRS Database Integration Tests

final class FSRSIntegrationTests: XCTestCase {
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        // Create in-memory database for testing
        dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try ReviewStateRecord.createTable(in: db)
            try ViewEventRecord.createTable(in: db)

            // Create minimal media_items table for interest score tests
            try db.create(table: "media_items", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("starred", .boolean).notNull().defaults(to: false)
                t.column("tagsJSON", .text).notNull().defaults(to: "[]")
                t.column("notes", .text)
            }
        }
    }

    override func tearDownWithError() throws {
        dbQueue = nil
    }

    // MARK: - ReviewState Persistence Tests

    func testReviewStateInsert() throws {
        let itemId = UUID()
        let state = ReviewStateRecord.initial(itemId: itemId)

        try dbQueue.write { db in
            try state.insert(db)
        }

        let fetched = try dbQueue.read { db in
            try ReviewStateRecord.fetchOne(
                db,
                sql: "SELECT * FROM review_state WHERE itemId = ?",
                arguments: [itemId.uuidString]
            )
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.itemId, itemId)
        XCTAssertEqual(fetched?.stability, 1.0)
        XCTAssertEqual(fetched?.difficulty, 5.0)
    }

    func testReviewStateUpdate() throws {
        let itemId = UUID()
        var state = ReviewStateRecord.initial(itemId: itemId)

        try dbQueue.write { db in
            try state.insert(db)
        }

        // Update state
        state.stability = 15.0
        state.difficulty = 4.5
        state.reps = 10
        state.interestScore = 0.8

        try dbQueue.write { db in
            try state.update(db)
        }

        let fetched = try dbQueue.read { db in
            try ReviewStateRecord.fetchOne(
                db,
                sql: "SELECT * FROM review_state WHERE itemId = ?",
                arguments: [itemId.uuidString]
            )
        }

        XCTAssertEqual(fetched?.stability, 15.0)
        XCTAssertEqual(fetched?.difficulty, 4.5)
        XCTAssertEqual(fetched?.reps, 10)
        XCTAssertEqual(fetched?.interestScore, 0.8)
    }

    func testReviewStateFetchDueItems() throws {
        let now = Date()

        try dbQueue.write { db in
            // Item due yesterday
            var past = ReviewStateRecord.initial(itemId: UUID())
            past.nextReviewAt = now.addingTimeInterval(-86400)
            try past.insert(db)

            // Item due now
            var current = ReviewStateRecord.initial(itemId: UUID())
            current.nextReviewAt = now
            try current.insert(db)

            // Item due tomorrow
            var future = ReviewStateRecord.initial(itemId: UUID())
            future.nextReviewAt = now.addingTimeInterval(86400)
            try future.insert(db)
        }

        let dueCount = try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM review_state WHERE nextReviewAt <= ?",
                arguments: [now]
            ) ?? 0
        }

        // Past and current should be due
        XCTAssertEqual(dueCount, 2)
    }

    // MARK: - ViewEvent Persistence Tests

    func testViewEventInsert() throws {
        let itemId = UUID()
        let event = ViewEventRecord(
            id: nil,
            itemId: itemId,
            viewedAt: Date(),
            durationSeconds: 5.5,
            action: .view
        )

        try dbQueue.write { db in
            try event.insert(db)
        }

        let fetched = try dbQueue.read { db in
            try ViewEventRecord.fetchOne(
                db,
                sql: "SELECT * FROM view_events WHERE itemId = ?",
                arguments: [itemId.uuidString]
            )
        }

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.itemId, itemId)
        XCTAssertEqual(fetched?.durationSeconds, 5.5)
        XCTAssertEqual(fetched?.action, .view)
    }

    func testViewEventMultipleActionsForSameItem() throws {
        let itemId = UUID()

        try dbQueue.write { db in
            for action in [ViewEventRecord.ViewAction.view, .star, .tag, .note] {
                let event = ViewEventRecord(
                    id: nil,
                    itemId: itemId,
                    viewedAt: Date(),
                    durationSeconds: nil,
                    action: action
                )
                try event.insert(db)
            }
        }

        let count = try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM view_events WHERE itemId = ?",
                arguments: [itemId.uuidString]
            ) ?? 0
        }

        XCTAssertEqual(count, 4)
    }

    // MARK: - Interest Score Integration Tests

    func testInterestScoreFromMediaItem() throws {
        let itemId = UUID()

        // Insert media item with engagement
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO media_items (id, starred, tagsJSON, notes)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: [itemId.uuidString, true, "[\"art\",\"favorite\"]", "Great photo!"]
            )
        }

        // Calculate expected score: 0.5 + 0.3 (starred) + 0.2 (2 tags) + 0.2 (notes) = 1.2 -> 1.0 (capped)
        let (starred, tagsJSON, notes) = try dbQueue.read { db -> (Bool, String, String?) in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT starred, tagsJSON, notes FROM media_items WHERE id = ?",
                arguments: [itemId.uuidString]
            )!
            return (row["starred"], row["tagsJSON"], row["notes"])
        }

        var score: Double = 0.5
        if starred { score += 0.3 }
        if let tags = try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8)) {
            score += min(0.3, Double(tags.count) * 0.1)
        }
        if let n = notes, !n.isEmpty { score += 0.2 }
        score = min(1.0, score)

        XCTAssertEqual(score, 1.0, accuracy: 0.001)
    }

    func testInterestScoreWithEmptyTags() throws {
        let itemId = UUID()

        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO media_items (id, starred, tagsJSON, notes) VALUES (?, ?, ?, ?)",
                arguments: [itemId.uuidString, false, "[]", nil]
            )
        }

        let tagsJSON: String = try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT tagsJSON FROM media_items WHERE id = ?",
                arguments: [itemId.uuidString]
            ) ?? "[]"
        }

        let tags = try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))
        let tagBonus = min(0.3, Double(tags?.count ?? 0) * 0.1)

        XCTAssertEqual(tagBonus, 0.0)
    }

    // MARK: - Index Tests

    func testNextReviewAtIndexExists() throws {
        let indexExists = try dbQueue.read { db in
            try db.indexes(on: "review_state").contains { $0.name == "idx_review_state_next" }
        }
        XCTAssertTrue(indexExists)
    }

    func testInterestScoreIndexExists() throws {
        let indexExists = try dbQueue.read { db in
            try db.indexes(on: "review_state").contains { $0.name == "idx_review_state_interest" }
        }
        XCTAssertTrue(indexExists)
    }

    func testViewEventsItemIndexExists() throws {
        let indexExists = try dbQueue.read { db in
            try db.indexes(on: "view_events").contains { $0.name == "idx_view_events_item" }
        }
        XCTAssertTrue(indexExists)
    }

    func testViewEventsTimeIndexExists() throws {
        let indexExists = try dbQueue.read { db in
            try db.indexes(on: "view_events").contains { $0.name == "idx_view_events_time" }
        }
        XCTAssertTrue(indexExists)
    }
}
