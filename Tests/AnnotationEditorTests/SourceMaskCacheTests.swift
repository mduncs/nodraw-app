import XCTest
import AppKit
@testable import MediaViewer

final class SourceMaskCacheTests: XCTestCase {
    func testUnchangedRealSourceReturnsCachedMasksIncludingEmptyAnalysis() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeSource(in: directory)
        let cache = SubjectMaskCache()
        let masks = [makeMask()]
        await cache.set(masks, for: url)
        let cached = await cache.get(for: url)
        let contains = await cache.contains(url)
        XCTAssertEqual(cached, masks)
        XCTAssertTrue(contains)
        await cache.set([], for: url)
        let emptyResult = await cache.get(for: url)
        let emptyIsCached = await cache.contains(url)
        XCTAssertEqual(emptyResult, [])
        XCTAssertTrue(emptyIsCached, "A valid no-subject result should avoid repeated analysis")
    }

    func testMissingSourcesAreNeverCachedAndDeletionEvictsBytes() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SubjectMaskCache()
        let missing = directory.appendingPathComponent("missing.png")
        await cache.set([makeMask()], for: missing)
        let missingCount = await cache.count
        XCTAssertEqual(missingCount, 0)
        let url = try makeSource(in: directory)
        await cache.set([makeMask()], for: url)
        try FileManager.default.removeItem(at: url)
        let contains = await cache.contains(url)
        let count = await cache.count
        let bytes = await cache.estimatedBytes
        XCTAssertFalse(contains)
        XCTAssertEqual(count, 0)
        XCTAssertEqual(bytes, 0)
    }

    func testSameURLObjectDoesNotReuseCachedFoundationMetadata() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeSource(in: directory)
        // Deliberately populate URL's resource-value cache before changing the file.
        _ = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        let cache = SubjectMaskCache()
        await cache.set([makeMask()], for: url)
        try Data("different-size".utf8).write(to: url)
        let cached = await cache.get(for: url)
        let count = await cache.count
        XCTAssertNil(cached)
        XCTAssertEqual(count, 0)
    }

    func testSameSizeReplacementWithPreservedTimestampIsInvalidatedByInode() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeSource(in: directory)
        let before = try XCTUnwrap(SubjectMaskCache.sourceVersion(for: url))
        let cache = SubjectMaskCache()
        await cache.set([makeMask()], for: url)
        try replaceSource(url)
        let after = try XCTUnwrap(SubjectMaskCache.sourceVersion(for: url))
        XCTAssertEqual(before.byteSize, after.byteSize)
        XCTAssertEqual(before.modifiedSeconds, after.modifiedSeconds)
        XCTAssertEqual(before.modifiedNanoseconds, after.modifiedNanoseconds)
        XCTAssertNotEqual(before.inode, after.inode)
        let contains = await cache.contains(url)
        let cached = await cache.get(for: url)
        XCTAssertFalse(contains)
        XCTAssertNil(cached)
    }

    func testLateOldAnalysisCannotOverwriteOrEvictNewerValidEntry() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeSource(in: directory)
        let oldVersion = try XCTUnwrap(SubjectMaskCache.sourceVersion(for: url))
        let cache = SubjectMaskCache()
        let oldMasks = [makeMask()]
        try replaceSource(url)
        await cache.set(oldMasks, for: url, expectedVersion: oldVersion)
        let rejected = await cache.get(for: url)
        XCTAssertNil(rejected, "Completion must be bound to the source present when analysis started")
        let freshMasks = [makeMask()]
        await cache.set(freshMasks, for: url)
        await cache.set(oldMasks, for: url, expectedVersion: oldVersion)
        let preserved = await cache.get(for: url)
        XCTAssertEqual(preserved, freshMasks)
    }

    func testEntryByteAndSubjectCountBudgetsRemainBounded() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SubjectMaskCache(maxEntries: 2)
        let urls = try (0..<3).map { try makeSource(in: directory, name: "source-\($0)") }
        for url in urls { await cache.set([makeMask()], for: url) }
        let oldest = await cache.get(for: urls[0])
        let count = await cache.count
        XCTAssertNil(oldest)
        XCTAssertEqual(count, 2)
        let tinyBudget = SubjectMaskCache(maxBytes: 1)
        await tinyBudget.set([makeMask()], for: urls[0])
        let tooLarge = await tinyBudget.get(for: urls[0])
        let bytes = await tinyBudget.estimatedBytes
        XCTAssertNil(tooLarge, "One oversized entry must not bypass the byte budget")
        XCTAssertEqual(bytes, 0)
        await cache.set((0..<12).map { _ in makeMask() }, for: urls[2])
        let bounded = await cache.get(for: urls[2])
        XCTAssertEqual(bounded?.count, SubjectMaskCache.maxSubjectsPerEntry)
    }

    @MainActor
    func testProductionAnalysisRejectsSourceReplacementDuringSuspendedProvider() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try makeSource(in: directory)
        let gate = SubjectAnalysisGate()
        let service = AnnotationAIService(assetStore: AnnotationAssetStore(assetDirectory: directory.appendingPathComponent("assets")))
        let task = Task {
            try await service.analyzeSubjects(from: url, subjectProvider: { _ in await gate.value() })
        }
        await gate.waitUntilStarted()
        try replaceSource(url)
        await gate.resolve([makeMask()])
        do {
            _ = try await task.value
            XCTFail("A replaced source must not receive a stale analysis result")
        } catch {
            guard case .failed = service.currentJob?.status else { return XCTFail("Changed-source failure must remain observable") }
        }
        let cached = await SubjectMaskCache.shared.contains(url)
        XCTAssertFalse(cached)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nodraw-mask-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func makeSource(in directory: URL, name: String = "source.png") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("AAAA".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
        return url
    }
    private func replaceSource(_ url: URL) throws {
        // Create the replacement before unlinking so its inode must be distinct.
        let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement-\(UUID().uuidString)")
        try Data("BBBB".utf8).write(to: replacement)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
    }
    private func makeMask() -> SubjectMask {
        let mask = EditorPixels.mask(width: 2, height: 2) { _, _ in 255 }
        let pixels = SubjectMask.extractPixelData(from: mask)!
        return SubjectMask(mask: mask, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), instanceIndex: 1,
                           maskPixelData: pixels.data, bytesPerRow: pixels.bytesPerRow)
    }
}

private actor SubjectAnalysisGate {
    private var result: CheckedContinuation<[SubjectMask], Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var started = false
    func value() async -> [SubjectMask] {
        await withCheckedContinuation { continuation in
            result = continuation
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func resolve(_ masks: [SubjectMask]) {
        result?.resume(returning: masks)
        result = nil
    }
}
