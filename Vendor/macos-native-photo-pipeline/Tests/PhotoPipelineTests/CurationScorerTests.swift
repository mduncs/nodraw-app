import XCTest
@testable import PhotoPipeline

final class CurationScorerTests: XCTestCase {

    let scorer = CurationScorer()

    // MARK: - Quality Gate

    func testQualityGateRejectsLowQuality() {
        let result = scorer.score(junkConfidence: 0.3, aestheticsScore: 0.9)
        XCTAssertEqual(result.score, 0)
        XCTAssertTrue(result.gatedByQuality)
    }

    func testQualityGateRejectsAtBoundary() {
        let result = scorer.score(junkConfidence: 0.49, aestheticsScore: 0.9)
        XCTAssertEqual(result.score, 0)
        XCTAssertTrue(result.gatedByQuality)
    }

    func testQualityGatePassesAtThreshold() {
        let result = scorer.score(junkConfidence: 0.5, aestheticsScore: 0.5)
        XCTAssertGreaterThan(result.score, 0)
        XCTAssertFalse(result.gatedByQuality)
    }

    func testQualityGatePassesHighQuality() {
        let result = scorer.score(junkConfidence: 0.95, aestheticsScore: 0.8)
        XCTAssertGreaterThan(result.score, 0)
        XCTAssertFalse(result.gatedByQuality)
    }

    // MARK: - Formula Weights

    func testBaseScoreMinimum() {
        // Minimum score: 0.1 base + 0 aesthetics + 0 content = 0.1
        let result = scorer.score(junkConfidence: 0.9, aestheticsScore: 0)
        XCTAssertEqual(result.score, 0.1, accuracy: 0.01)
    }

    func testAestheticsContribution() {
        // With aesthetics = 1.0, no content: 0.1 + 1.0×0.25 + 0 = 0.35 base
        let low = scorer.score(junkConfidence: 0.9, aestheticsScore: 0.2)
        let high = scorer.score(junkConfidence: 0.9, aestheticsScore: 0.9)
        XCTAssertGreaterThan(high.score, low.score)
    }

    func testContentFromFaces() {
        let noFaces = scorer.score(junkConfidence: 0.9, aestheticsScore: 0.5, faceCount: 0)
        let oneFace = scorer.score(junkConfidence: 0.9, aestheticsScore: 0.5, faceCount: 1)
        let twoFaces = scorer.score(junkConfidence: 0.9, aestheticsScore: 0.5, faceCount: 2)
        XCTAssertGreaterThan(oneFace.score, noFaces.score)
        XCTAssertGreaterThan(twoFaces.score, oneFace.score)
    }

    func testContentFromObjects() {
        let noObj = scorer.score(junkConfidence: 0.9, aestheticsScore: 0.5)
        let withObj = scorer.score(junkConfidence: 0.9, aestheticsScore: 0.5, objectCount: 3)
        XCTAssertGreaterThan(withObj.score, noObj.score)
    }

    // MARK: - Penalty

    func testUtilityPenalty() {
        let normal = scorer.score(junkConfidence: 0.9, aestheticsScore: 0.8, faceCount: 1)
        let utility = scorer.score(junkConfidence: 0.9, aestheticsScore: 0.8, faceCount: 1, isUtility: true)
        XCTAssertGreaterThan(normal.score, utility.score)
        // Utility penalty is 0.3× multiplier
        XCTAssertEqual(utility.score, normal.score * 0.3, accuracy: 0.01)
    }

    func testBlurPenalty() {
        let sharp = scorer.score(junkConfidence: 0.9, aestheticsScore: 0.7, blurScore: 1.0)
        let blurry = scorer.score(junkConfidence: 0.9, aestheticsScore: 0.7, blurScore: 0.3)
        XCTAssertGreaterThan(sharp.score, blurry.score)
    }

    // MARK: - Clamping

    func testScoreClampedTo01() {
        // Even with extreme values, should stay in [0, 1]
        let result = scorer.score(
            junkConfidence: 1.0,
            aestheticsScore: 1.0,
            faceCount: 10,
            objectCount: 10,
            blurScore: 1.0
        )
        XCTAssertTrue(result.score <= 1.0)
        XCTAssertTrue(result.score >= 0.0)
    }

    // MARK: - Component Values

    func testComponentsPopulated() {
        let result = scorer.score(
            junkConfidence: 0.85,
            aestheticsScore: 0.7,
            faceCount: 2,
            objectCount: 1,
            isUtility: false
        )
        XCTAssertEqual(result.globalQuality, 0.85)
        XCTAssertEqual(result.visualPleasingScore, 0.7)
        XCTAssertGreaterThan(result.contentScore, 0)
        XCTAssertEqual(result.penaltyScore, 1.0) // no penalty
        XCTAssertFalse(result.gatedByQuality)
    }

    func testGatedComponentsZeroed() {
        let result = scorer.score(junkConfidence: 0.2, aestheticsScore: 0.9)
        XCTAssertEqual(result.score, 0)
        XCTAssertEqual(result.contentScore, 0)
        XCTAssertEqual(result.penaltyScore, 0)
        XCTAssertTrue(result.gatedByQuality)
    }

    // MARK: - Ranking

    func testHighQualityPortraitRanksHighest() {
        let portrait = scorer.score(junkConfidence: 0.95, aestheticsScore: 0.85, faceCount: 1)
        let landscape = scorer.score(junkConfidence: 0.95, aestheticsScore: 0.7)
        let junkPhoto = scorer.score(junkConfidence: 0.3, aestheticsScore: 0.9)
        XCTAssertGreaterThan(portrait.score, landscape.score)
        XCTAssertGreaterThan(landscape.score, junkPhoto.score)
    }
}
