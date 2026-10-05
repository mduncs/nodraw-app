import XCTest
import GRDB
import Combine
@testable import MediaViewer

final class ExactColorHydrationTests: XCTestCase {
    private var fixture: ProductionAssetFixture!
    private var store: MediaStore!

    override func setUp() async throws {
        fixture = try await ProductionAssetFixture()
        store = MediaStore(database: fixture.database)
    }
    override func tearDown() async throws {
        store = nil
        fixture.cleanUp()
        fixture = nil
    }

    private func seed(_ colors: [(Int, Int, Int)], payloads: Bool = false) async throws -> [UUID] {
        let directory = fixture.directory
        let file = fixture.files[0]
        let entries = colors.enumerated().map { index, color in
            (UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!, color)
        }
        try await fixture.database.write { db in
            for (id, color) in entries {
                let item = MediaItem(id: id, basePath: directory, metadataFile: directory.appendingPathComponent("\(id).md"), mediaFiles: [file], metadata: MediaMetadata(source: URL(string: "https://example.com/\(id)")!, platform: "test", archivedDate: Date(timeIntervalSince1970: 0)))
                try MediaItemRecord(from: item).insert(db)
                try db.execute(sql: "INSERT INTO media_colors(item_id,color_bucket,rgb_r,rgb_g,rgb_b) VALUES (?,'green',?,?,?)", arguments: [id.uuidString, color.0, color.1, color.2])
                if payloads {
                    try MediaFileOCRRecord(itemId: id, fileURL: file.path, fileIndex: 0, ocrText: String(repeating: "OCR payload ", count: 100)).upsert(db: db)
                    try MediaAttribute(itemId: id, module: .quality, key: "aesthetics", value: 0.75).insert(db)
                    try VideoSegmentRecord(segment: VideoSegment(id: UUID(), itemId: id, mediaFileIndex: 0, sourcePath: file.path, startTime: 0, endTime: 1, summary: String(repeating: "video ", count: 100), labels: [], confidence: 1, analysisSource: "fixture", version: 1)).insert(db)
                    try TranscriptSegmentRecord(segment: TranscriptSegment(id: UUID(), itemId: id, mediaFileIndex: 0, sourcePath: file.path, startTime: 0, endTime: 1, text: String(repeating: "transcript ", count: 100), confidence: 1, language: "en", model: "fixture", version: 1)).insert(db)
                }
            }
        }
        return entries.map(\.0)
    }

    func testExactPagesCountsTiesAndMatchesBeyondEarlyCandidates() async throws {
        let colors = Array(repeating: (128, 128, 190), count: 540) + (0..<60).map { (128 + $0 % 5, 128, 128) }
        let ids = try await seed(colors)
        let target = (128, 128, 128)
        let expected = zip(ids, colors).filter { Self.referenceDeltaE(target, $0.1) <= 3 }.map(\.0)
        var filter = FilterState()
        filter.colorSearchRGB = Self.perceptualColor(r: 128, g: 128, b: 128, tolerance: 1, threshold: 3)
        filter.limit = 17
        let count = try await store.countItems(filter: filter)
        XCTAssertEqual(count, expected.count)
        var paged: [UUID] = []
        for offset in stride(from: 0, through: expected.count + 17, by: 17) {
            filter.offset = offset
            let page = try await store.fetchItems(filter: filter)
            XCTAssertEqual(page.map(\.id), Array(expected.dropFirst(offset).prefix(17)))
            paged += page.map(\.id)
        }
        XCTAssertEqual(paged, expected)
        filter.offset = 5
        filter.limit = -1
        let unlimitedOffset = try await store.fetchItems(filter: filter)
        XCTAssertEqual(unlimitedOffset.map(\.id), Array(expected.dropFirst(5)))
        filter.shuffleSeed = 42
        filter.offset = 0
        let shuffled = try await store.fetchItems(filter: filter)
        filter.limit = 9
        filter.offset = 9
        let shufflePage = try await store.fetchItems(filter: filter)
        XCTAssertEqual(shufflePage.map(\.id), Array(shuffled.dropFirst(9).prefix(9)).map(\.id))
    }

    func testPerceptualMatchesOutsideOldRGBBoxAndRGBModeStaysExact() async throws {
        let ids = try await seed([(0, 255, 0), (100, 255, 0), (255, 0, 255)])
        XCTAssertLessThan(Self.referenceDeltaE((0, 255, 0), (100, 255, 0)), 20)
        var filter = FilterState()
        filter.colorSearchRGB = Self.perceptualColor(r: 0, g: 255, b: 0, tolerance: 5, threshold: 20)
        let exact = try await store.fetchItems(filter: filter)
        XCTAssertEqual(exact.map(\.id), Array(ids.prefix(2)))
        filter.colorSearchRGB?.usePerceptual = false
        let rgb = try await store.fetchItems(filter: filter)
        XCTAssertEqual(rgb.map(\.id), [ids[0]])
    }

    @MainActor
    func testObservedPageAndCountUseExactPredicateOnEveryReader() async throws {
        let ids = try await seed([(128, 128, 190), (128, 128, 128)])
        var filter = FilterState()
        filter.colorSearchRGB = Self.perceptualColor(r: 128, g: 128, b: 128, tolerance: 1, threshold: 1)
        filter.limit = 1
        let pageInitial = expectation(description: "Exact observed first page")
        let pageChanged = expectation(description: "Exact observed changed page")
        let countInitial = expectation(description: "Exact observed count")
        let countChanged = expectation(description: "Exact observed changed count")
        let pagePublisher = try await store.observeWindow(offset: 0, limit: 1, filter: filter)
        let countPublisher = try await store.observeCount(filter: filter)
        let pageSubscription = pagePublisher.sink(receiveCompletion: { completion in
            if case .failure(let error) = completion { XCTFail("\(error)") }
        }, receiveValue: { items in
            if items.map(\.id) == [ids[1]] { pageInitial.fulfill() }
            if items.map(\.id) == [ids[0]] { pageChanged.fulfill() }
        })
        let countSubscription = countPublisher.sink(receiveCompletion: { completion in
            if case .failure(let error) = completion { XCTFail("\(error)") }
        }, receiveValue: { count in
            if count == 1 { countInitial.fulfill() }
            if count == 2 { countChanged.fulfill() }
        })
        await fulfillment(of: [pageInitial, countInitial], timeout: 3)
        let id = ids[0].uuidString
        try await fixture.database.write { db in try db.execute(sql: "UPDATE media_colors SET rgb_b = 128 WHERE item_id = ?", arguments: [id]) }
        await fulfillment(of: [pageChanged, countChanged], timeout: 3)
        pageSubscription.cancel()
        countSubscription.cancel()
    }

    func testShallowTableAndMemberFetchAvoidEnrichmentAndChunkLargeIDs() async throws {
        let ids = try await seed(Array(repeating: (0, 255, 0), count: 605), payloads: true)
        let started = Date()
        let full = try await store.fetchItems(filter: .all.withUnlimitedLimit())
        let fullTime = Date().timeIntervalSince(started)
        let shallowStarted = Date()
        let shallow = try await store.fetchItems(filter: .all.withUnlimitedLimit(), includeMLAttributes: false, includePerFileOCR: false, includeVideoSegments: false, includeTranscriptSegments: false)
        let shallowTime = Date().timeIntervalSince(shallowStarted)
        let fullWarmStarted = Date()
        _ = try await store.fetchItems(filter: .all.withUnlimitedLimit())
        let fullWarmTime = Date().timeIntervalSince(fullWarmStarted)
        let shallowWarmStarted = Date()
        _ = try await store.fetchItems(filter: .all.withUnlimitedLimit(), includeMLAttributes: false, includePerFileOCR: false, includeVideoSegments: false, includeTranscriptSegments: false)
        let shallowWarmTime = Date().timeIntervalSince(shallowWarmStarted)
        XCTAssertEqual(shallow.map(\.id), full.map(\.id))
        XCTAssertTrue(shallow.allSatisfy { $0.perFileOCR.isEmpty && $0.mlAttributes.isEmpty && $0.videoSegments.isEmpty && $0.transcriptSegments.isEmpty && $0.assets.count == 1 })
        XCTAssertTrue(full.allSatisfy { $0.perFileOCR.count == 1 && $0.videoSegments.count == 1 && $0.transcriptSegments.count == 1 })
        await MainActor.run {
            let model = TableBrowserViewModel()
            model.setItems(shallow)
            let replacements = model.collectionReplacementCount
            model.setItems(shallow)
            XCTAssertEqual(model.collectionReplacementCount, replacements, "An unchanged shallow refresh must not replace the table corpus")
        }
        let members = [ids[604], ids[4], ids[400]]
        let canvas = try await store.fetchItems(ids: members, includeMLAttributes: false, includePerFileOCR: false, includeVideoSegments: false, includeTranscriptSegments: false)
        XCTAssertEqual(canvas.map(\.id), members)
        let large = try await store.fetchItems(ids: Array(ids.reversed()), includeMLAttributes: false, includePerFileOCR: false, includeVideoSegments: false, includeTranscriptSegments: false)
        XCTAssertEqual(large.map(\.id), Array(ids.reversed()))
        var payloadBytes = 0
        var relatedRows = 0
        for item in full {
            relatedRows += item.perFileOCR.count + item.mlAttributes.count + item.videoSegments.count + item.transcriptSegments.count
            payloadBytes += item.perFileOCR.values.reduce(0) { $0 + ($1.ocrText?.utf8.count ?? 0) }
            payloadBytes += item.videoSegments.reduce(0) { $0 + $1.summary.utf8.count }
            payloadBytes += item.transcriptSegments.reduce(0) { $0 + $1.text.utf8.count }
        }
        print("HYDRATION_PROBE fullRows=\(full.count) shallowRows=\(shallow.count) canvasRows=\(canvas.count) fullRelatedRows=\(relatedRows) shallowRelatedRows=0 omittedTextBytes=\(payloadBytes) fullFirstSeconds=\(fullTime) shallowFirstSeconds=\(shallowTime) fullWarmSeconds=\(fullWarmTime) shallowWarmSeconds=\(shallowWarmTime)")
    }

    func testTableReuseHydratesMLAttributesFromShallowGridItems() async throws {
        let ids = try await seed([(0, 255, 0), (25, 225, 25)], payloads: true)
        let shallowGridItems = try await store.fetchItems(
            filter: .all.withUnlimitedLimit(),
            includeMLAttributes: false,
            includePerFileOCR: false,
            includeVideoSegments: false,
            includeTranscriptSegments: false
        )
        XCTAssertEqual(Set(shallowGridItems.map(\.id)), Set(ids))
        XCTAssertTrue(shallowGridItems.allSatisfy(\.mlAttributes.isEmpty))

        let tableItems = try await TableBrowserHydration.hydrateMLAttributes(shallowGridItems, using: store)
        XCTAssertEqual(tableItems.map(\.id), shallowGridItems.map(\.id), "Hydration must retain the shared grid corpus order")
        XCTAssertEqual(tableItems.map { $0.mlAttributes["quality.aesthetics"] }, [0.75, 0.75])
        XCTAssertTrue(tableItems.allSatisfy { $0.perFileOCR.isEmpty && $0.videoSegments.isEmpty && $0.transcriptSegments.isEmpty })
    }

    func testCancelledQueryDoesNotPublishResults() async throws {
        _ = try await seed([(0, 255, 0)])
        let store = try XCTUnwrap(store)
        let task = Task { try await store.fetchItems(filter: .all.withUnlimitedLimit()) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled query must not return a stale corpus") }
        catch is CancellationError {}
    }

    private static func perceptualColor(r: Int, g: Int, b: Int, tolerance: Int, threshold: Double) -> ColorSearchRGB {
        var color = ColorSearchRGB(r: r, g: g, b: b, tolerance: tolerance)
        color.usePerceptual = true
        color.deltaEThreshold = threshold
        return color
    }

    /// Independent full-corpus CIE76 reference (sRGB/D65), without SQL/prefilter.
    private static func referenceDeltaE(_ lhs: (Int, Int, Int), _ rhs: (Int, Int, Int)) -> Double {
        func lab(_ rgb: (Int, Int, Int)) -> [Double] {
            let linear = [rgb.0, rgb.1, rgb.2].map { value -> Double in
                let s = Double(value) / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            let x = (0.4124564 * linear[0] + 0.3575761 * linear[1] + 0.1804375 * linear[2]) / 0.95047
            let y = 0.2126729 * linear[0] + 0.7151522 * linear[1] + 0.0721750 * linear[2]
            let z = (0.0193339 * linear[0] + 0.1191920 * linear[1] + 0.9503041 * linear[2]) / 1.08883
            let f = [x, y, z].map { $0 > 0.008856 ? pow($0, 1.0 / 3.0) : 7.787 * $0 + 16.0 / 116.0 }
            return [116 * f[1] - 16, 500 * (f[0] - f[1]), 200 * (f[1] - f[2])]
        }
        return sqrt(zip(lab(lhs), lab(rhs)).reduce(0) { $0 + pow($1.0 - $1.1, 2) })
    }
}
