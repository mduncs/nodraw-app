import XCTest
import UniformTypeIdentifiers
@testable import MediaViewer

final class ImportDropFailureTests: XCTestCase {
    private var root: URL!
    private var source: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ImportDropFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("valid.png")
        try Data([1, 2, 3]).write(to: source)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testMixedProviderLoadRetainsFailurePositionNameAndAccurateSummary() async throws {
        let good = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let bad = NSItemProvider()
        bad.suggestedName = "unavailable.png"
        bad.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadNoPermission))
            return nil
        }
        let batch = await withCheckedContinuation { continuation in
            ImportDropDecoder.load([good, bad]) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(batch.entries.map(\.position), [0, 1])
        XCTAssertEqual(batch.scopes.map(\.url), [source])
        let error = try XCTUnwrap(batch.errors.first)
        XCTAssertTrue(error.filename.contains("Drop item 2"))
        XCTAssertTrue(error.filename.contains("unavailable.png"))
        XCTAssertNil(error.sourceURL)
        XCTAssertTrue(error.reason.contains("Drop the file again"))
        let merged = batch.merging(ImportResult(importedCount: 1, skippedCount: 0, failedCount: 0, createdItemIds: [UUID()], errors: []))
        XCTAssertEqual(merged.summary, "1 imported, 1 failed")
        XCTAssertEqual(merged.errors.count, 1)
    }

    func testAllFailedProvidersRemainVisibleWithoutInventedRetryURLs() {
        let entries = (0..<2).map { position in
            ImportDropDecoder.decode(item: nil, error: CocoaError(.fileReadUnknown), position: position, suggestedName: "file\(position).png")
        }
        let batch = ImportDropBatch(entries: entries)
        XCTAssertTrue(batch.scopes.isEmpty)
        XCTAssertEqual(batch.errors.count, 2)
        XCTAssertTrue(batch.errors.allSatisfy { $0.sourceURL == nil && $0.operationID == nil })
        XCTAssertEqual(batch.merging(ImportResult(importedCount: 0, skippedCount: 0, failedCount: 0, createdItemIds: [], errors: [])).summary, "2 failed")
    }

    func testUndecodableAndNonFilePayloadsRequireRedrop() throws {
        for payload: NSSecureCoding in [NSNumber(value: 42), "https://example.com/image.png" as NSString] {
            let entry = ImportDropDecoder.decode(item: payload, error: nil, position: 3, suggestedName: nil)
            XCTAssertNil(entry.scope)
            let error = try XCTUnwrap(entry.error)
            XCTAssertEqual(error.filename, "Drop item 4")
            XCTAssertNil(error.sourceURL)
            XCTAssertTrue(error.reason.contains("Drop the file again from Finder"))
        }
    }

    func testMissingSourceRetainsActualURLAndPositionInsteadOfSilentlyFiltering() throws {
        let missing = root.appendingPathComponent("missing.png")
        let entry = ImportDropDecoder.decode(item: missing as NSURL, error: nil, position: 1, suggestedName: nil)
        XCTAssertNil(entry.scope)
        let error = try XCTUnwrap(entry.error)
        XCTAssertEqual(error.sourceURL, missing)
        XCTAssertEqual(error.filename, "Drop item 2 · missing.png")
        XCTAssertTrue(error.reason.contains("Restore it at this location and retry"))
    }

    func testDuplicateValidURLsDoNotDiscardOtherProviderFailures() {
        let good = ImportDropDecoder.decode(item: source as NSURL, error: nil, position: 0, suggestedName: nil)
        let duplicate = ImportDropDecoder.decode(item: source as NSURL, error: nil, position: 1, suggestedName: nil)
        let bad = ImportDropDecoder.decode(item: nil, error: nil, position: 2, suggestedName: "bad")
        let batch = ImportDropBatch(entries: [good, duplicate, bad])
        XCTAssertEqual(batch.scopes.count, 1)
        XCTAssertEqual(batch.errors.count, 1)
        XCTAssertEqual(batch.entries.map(\.position), [0, 1, 2])
    }

    func testArchiveFolderProvidersReachSkipPolicyAlongsideNewFiles() async throws {
        let archive = root.appendingPathComponent("archive")
        let folder = archive.appendingPathComponent("existing-post")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = NSItemProvider(item: folder as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let newFile = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let batch = await withCheckedContinuation { continuation in
            ImportDropDecoder.load([existing, newFile], archivePath: archive) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(batch.scopes.map(\.url), [folder, source])
        XCTAssertTrue(batch.errors.isEmpty)
        let rejected = ImportDropDecoder.decode(item: root as NSURL, error: nil, position: 0,
            suggestedName: nil, archivePath: archive)
        XCTAssertNil(rejected.scope)
        XCTAssertTrue(rejected.error?.reason.contains("Folders cannot be imported") == true)
    }

    func testProviderErrorsPreserveExistingItemNotices() {
        let notice = ImportSkippedItem(sourceURL: source, existingItemID: UUID(),
            existingURL: source, existingName: "Existing post")
        let original = ImportResult(importedCount: 0, skippedCount: 1, failedCount: 0,
            createdItemIds: [], errors: [], skippedItems: [notice])
        let merged = ImportDropBatch.adding(errors: [ImportError(filename: "Unavailable", reason: "Missing")], to: original)
        XCTAssertEqual(merged.skippedItems.first?.existingItemID, notice.existingItemID)
        XCTAssertEqual(merged.skippedCount, 1)
        XCTAssertEqual(merged.failedCount, 1)
    }

}
