import XCTest
@testable import PhotoPipeline

final class OCRQualityFilterTests: XCTestCase {

    // MARK: - Confidence filtering

    func testDefaultFilterDropsLowConfidence() {
        let filter = OCRQualityFilter.default
        let obs = TextObservation(text: "Hello World", boundingBox: .zero, confidence: 0.1)
        XCTAssertFalse(filter.passes(obs))
    }

    func testDefaultFilterKeepsHighConfidence() {
        let filter = OCRQualityFilter.default
        let obs = TextObservation(text: "Hello World", boundingBox: .zero, confidence: 0.8)
        XCTAssertTrue(filter.passes(obs))
    }

    func testDefaultFilterKeepsBorderlineConfidence() {
        let filter = OCRQualityFilter.default
        let obs = TextObservation(text: "Maybe text", boundingBox: .zero, confidence: 0.25)
        XCTAssertTrue(filter.passes(obs))
    }

    func testDefaultFilterDropsJustBelowThreshold() {
        let filter = OCRQualityFilter.default
        let obs = TextObservation(text: "Probably noise", boundingBox: .zero, confidence: 0.24)
        XCTAssertFalse(filter.passes(obs))
    }

    // MARK: - Length filtering

    func testDropsSingleCharNoise() {
        let filter = OCRQualityFilter.default
        let obs = TextObservation(text: "l", boundingBox: .zero, confidence: 0.9)
        XCTAssertFalse(filter.passes(obs))
    }

    func testKeepsTwoCharText() {
        let filter = OCRQualityFilter.default
        let obs = TextObservation(text: "OK", boundingBox: .zero, confidence: 0.9)
        XCTAssertTrue(filter.passes(obs))
    }

    // MARK: - Symbol ratio filtering

    func testDropsAllSymbols() {
        let filter = OCRQualityFilter.default
        let obs = TextObservation(text: "|||///\\\\---", boundingBox: .zero, confidence: 0.9)
        XCTAssertFalse(filter.passes(obs))
    }

    func testKeepsMixedSymbolsAndText() {
        let filter = OCRQualityFilter.default
        // "$19.99" has 3 alnum + 1 space-equivalent out of 6 chars
        let obs = TextObservation(text: "$19.99", boundingBox: .zero, confidence: 0.9)
        XCTAssertTrue(filter.passes(obs))
    }

    func testKeepsCppProgramming() {
        let filter = OCRQualityFilter.default
        let obs = TextObservation(text: "C++ Programming", boundingBox: .zero, confidence: 0.9)
        XCTAssertTrue(filter.passes(obs))
    }

    // MARK: - Word ratio filtering

    func testStrictFilterDropsGarbledText() {
        let filter = OCRQualityFilter.strict
        // all single-char tokens — none are word-like (2+ letters)
        let obs = TextObservation(text: "x 3 q 7 z", boundingBox: .zero, confidence: 0.9)
        XCTAssertFalse(filter.passes(obs))
    }

    func testStrictFilterKeepsRealWords() {
        let filter = OCRQualityFilter.strict
        let obs = TextObservation(text: "Hello World 3", boundingBox: .zero, confidence: 0.9)
        XCTAssertTrue(filter.passes(obs))
    }

    func testStrictFilterConfidenceThreshold() {
        let filter = OCRQualityFilter.strict
        let obs = TextObservation(text: "Hello World", boundingBox: .zero, confidence: 0.4)
        XCTAssertFalse(filter.passes(obs))
    }

    // MARK: - Presets

    func testPermissiveKeepsAlmostEverything() {
        let filter = OCRQualityFilter.permissive
        let obs = TextObservation(text: "x", boundingBox: .zero, confidence: 0.15)
        XCTAssertTrue(filter.passes(obs))
    }

    func testNoneKeepsEverything() {
        let filter = OCRQualityFilter.none
        let obs = TextObservation(text: "l", boundingBox: .zero, confidence: 0.01)
        XCTAssertTrue(filter.passes(obs))
    }

    // MARK: - Batch filtering

    func testApplyFiltersArray() {
        let filter = OCRQualityFilter.default
        let observations = [
            TextObservation(text: "Good text", boundingBox: .zero, confidence: 0.9),
            TextObservation(text: "l", boundingBox: .zero, confidence: 0.9),
            TextObservation(text: "|||", boundingBox: .zero, confidence: 0.9),
            TextObservation(text: "Also good", boundingBox: .zero, confidence: 0.5),
            TextObservation(text: "Noise", boundingBox: .zero, confidence: 0.1),
        ]
        let filtered = filter.apply(observations)
        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(filtered[0].text, "Good text")
        XCTAssertEqual(filtered[1].text, "Also good")
    }

    func testPartitionSplitsCorrectly() {
        let filter = OCRQualityFilter.default
        let observations = [
            TextObservation(text: "Keep me", boundingBox: .zero, confidence: 0.9),
            TextObservation(text: "x", boundingBox: .zero, confidence: 0.9),
            TextObservation(text: "Drop me", boundingBox: .zero, confidence: 0.05),
        ]
        let (kept, rejected) = filter.partition(observations)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(rejected.count, 2)
        XCTAssertEqual(kept[0].text, "Keep me")
    }

    // MARK: - Real-world scenarios

    func testLicensePlatePassesDefault() {
        // License plates are real text — should pass default filter
        let filter = OCRQualityFilter.default
        let obs = TextObservation(text: "ABC 1234", boundingBox: .zero, confidence: 0.7)
        XCTAssertTrue(filter.passes(obs))
    }

    func testBokehNoiseDropped() {
        // Bokeh circles misread as "OOO" with low confidence
        let filter = OCRQualityFilter.default
        let obs = TextObservation(text: "OOO", boundingBox: .zero, confidence: 0.15)
        XCTAssertFalse(filter.passes(obs))
    }

    func testWoodGrainNoiseDropped() {
        // Wood grain misread as "lll" with low confidence
        let filter = OCRQualityFilter.default
        let obs = TextObservation(text: "lll", boundingBox: .zero, confidence: 0.12)
        XCTAssertFalse(filter.passes(obs))
    }

    func testEmptyArrayReturnsEmpty() {
        let filter = OCRQualityFilter.default
        XCTAssertTrue(filter.apply([]).isEmpty)
    }
}
