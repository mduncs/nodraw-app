import XCTest
@testable import PhotoPipeline

final class SceneTests: XCTestCase {

    func testSceneClassificationModel() {
        let sc = SceneClassification(label: "Beach", confidence: 0.95)
        XCTAssertEqual(sc.label, "Beach")
        XCTAssertEqual(sc.confidence, 0.95, accuracy: 0.001)
    }

    func testSceneResultConstruction() {
        let labels = [
            SceneClassification(label: "Beach", confidence: 0.9),
            SceneClassification(label: "Ocean", confidence: 0.8),
        ]
        let result = SceneResult(labels: labels, aestheticsScore: 0.75, isJunk: false)
        XCTAssertEqual(result.labels.count, 2)
        XCTAssertEqual(result.aestheticsScore, 0.75, accuracy: 0.001)
        XCTAssertFalse(result.isJunk)
    }

    func testSceneClassifierInit() {
        // Should init even without private frameworks (falls back to public Vision API)
        do {
            let classifier = try SceneClassifier()
            _ = classifier
        } catch {
            XCTFail("SceneClassifier init should not throw (has public API fallback): \(error)")
        }
    }

    func testRecognitionDomainRawValues() {
        XCTAssertEqual(RecognitionDomain.unknown.rawValue, 0)
        XCTAssertEqual(RecognitionDomain.dogs.rawValue, 5)
        XCTAssertEqual(RecognitionDomain.cats.rawValue, 4)
        XCTAssertEqual(RecognitionDomain.food.rawValue, 16)
        XCTAssertEqual(RecognitionDomain.birds.rawValue, 8)
    }
}
