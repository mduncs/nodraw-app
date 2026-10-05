import XCTest
import GRDB
import PhotoPipeline
@testable import MediaViewer

final class PipelineAdapterSafetyTests: XCTestCase {
    func testLegacyResultIsCanonicalizedAndStaleCategoriesAreRemoved() throws {
        let queue = try makeQueue()
        let itemId = UUID()
        try queue.write { db in
            try MediaAttribute(itemId: itemId, module: .safety, key: "sword", value: 0.9).upsert(db: db)
            let legacy = ["adult", "adult_cat", "swordfish", "knife", "axe", "is_safe"].map {
                MediaAttribute(itemId: itemId, module: .safety, key: $0, value: $0 == "is_safe" ? 0 : 1)
            }
            try PipelineAdapter.storeSafetyAttributes(legacy, itemId: itemId, db: db)
            let attributes = try MediaAttribute.fetchModule(db: db, itemId: itemId, module: .safety)
            XCTAssertEqual(attributes.map(\.key), ["is_safe"])
            XCTAssertEqual(attributes.first?.value, 1)
        }
    }

    func testCachedLegacySafetyJSONCannotRestoreUnsafeFlag() throws {
        let support = try XCTUnwrap(ProcessInfo.processInfo.environment["NODRAW_APP_SUPPORT_DIR"])
        let directory = URL(fileURLWithPath: support).appendingPathComponent("safety-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MetadataStore(storePath: directory)
        let itemId = UUID()
        let legacy = try JSONDecoder().decode(SafetyResult.self, from: Data("""
            {"isSafe":false,"categories":[{"label":"adult","confidence":0.99},{"label":"adult_cat","confidence":0.9}]}
            """.utf8))
        try store.storeSafetyResult(assetID: itemId.uuidString, result: legacy)
        let cached = try XCTUnwrap(store.loadSafetyResult(assetID: itemId.uuidString))
        XCTAssertFalse(cached.isSafe)
        let categories = cached.categories.map {
            MediaAttribute(itemId: itemId, module: .safety, key: $0.label, value: Double($0.confidence))
        }
        let queue = try makeQueue()
        try queue.write { db in
            try PipelineAdapter.storeSafetyAttributes(categories, itemId: itemId, db: db)
            let attributes = try MediaAttribute.fetchModule(db: db, itemId: itemId, module: .safety)
            XCTAssertEqual(attributes.map(\.key), ["is_safe"])
            XCTAssertEqual(attributes.first?.value, 1)
        }
    }

    func testExactIdentifierAndConfidenceBoundaries() {
        let itemId = UUID()
        for confidence in [0.1, 0.1001, 0.4999, 0.5, 1.0] {
            let attributes = SafetyAttributes.canonicalize([
                MediaAttribute(itemId: itemId, module: .safety, key: "sword", value: confidence),
                MediaAttribute(itemId: itemId, module: .scene, key: "sword", value: 1),
                MediaAttribute(itemId: itemId, module: .safety, key: "Sword", value: 1)
            ], itemId: itemId)
            XCTAssertEqual(attributes.first { $0.key == "is_safe" }?.value, confidence >= 0.5 ? 0 : 1)
            XCTAssertEqual(attributes.filter { $0.key == "sword" }.count, confidence > 0.1 ? 1 : 0)
        }
    }

    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE media_attributes (
                    item_id TEXT NOT NULL, module TEXT NOT NULL, key TEXT NOT NULL,
                    value REAL NOT NULL, metadata TEXT, version INTEGER NOT NULL DEFAULT 1,
                    PRIMARY KEY (item_id, module, key)
                )
                """)
        }
        return queue
    }
}
