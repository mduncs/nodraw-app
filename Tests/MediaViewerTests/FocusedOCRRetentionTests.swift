import XCTest
@testable import MediaViewer

/// Adding a tag in detail triggers a grid reload whose records skip per-file OCR, ML
/// attributes and timelines. That shallow record must not strip the open detail item's
/// hydrated analysis, or the inspector falls back to "No text detected yet".
@MainActor
final class FocusedOCRRetentionTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusedOCRRetentionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        tempDirectory = nil
        try await super.tearDown()
    }

    func testShallowGridReloadAfterAddTagKeepsFocusedItemOCR() async throws {
        let database = DatabaseManager(databaseURL: tempDirectory.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        let store = MediaStore(database: database)
        let item = try makeItem(name: "notes", tags: ["screenshot"])
        try await store.insertItem(item)
        let block = SerializableTextBlock(
            id: "b0", text: "Release notes",
            lines: [SerializableTextObservation(text: "Release notes",
                boundingBox: SerializableCGRect(rect: CGRect(x: 0.1, y: 0.8, width: 0.4, height: 0.06)), confidence: 0.98)],
            boundingBox: SerializableCGRect(rect: CGRect(x: 0.1, y: 0.8, width: 0.4, height: 0.06)),
            confidence: 0.98, role: "body", columnIndex: 0)
        let ocr = MediaFileOCRRecord(itemId: item.id, fileURL: item.mediaFiles[0].path, fileIndex: 0,
                                     ocrText: "Release notes", ocrBlocks: [block])
        try await database.write { db in try ocr.insert(db) }

        // Detail opens on the hydrated record, as AppState.hydrateFocusedItem loads it.
        let hydrated = try XCTUnwrapAsync(try await store.fetchItem(id: item.id))
        XCTAssertEqual(hydrated.ocrText(forFileIndex: 0), "Release notes", "fixture: OCR is attached")
        let selection = MediaSelectionStore()
        selection.replaceItems(try await store.fetchItems(includeMLAttributes: false, includePerFileOCR: false,
                                                         includeVideoSegments: false, includeTranscriptSegments: false))
        selection.focusedItem = hydrated

        // Add a tag, then the grid's shallow reload replaces the corpus.
        try await store.addTag(id: item.id, tag: "release")
        let shallow = try await store.fetchItems(includeMLAttributes: false, includePerFileOCR: false,
                                                 includeVideoSegments: false, includeTranscriptSegments: false)
        XCTAssertTrue(try XCTUnwrap(shallow.first { $0.id == item.id }).perFileOCR.isEmpty, "fixture: grid records are shallow")
        selection.replaceItems(shallow)

        let focused = try XCTUnwrap(selection.focusedItem)
        XCTAssertTrue(focused.metadata.tags.contains("release"), "the new tag comes from the fresh record")
        XCTAssertEqual(focused.ocrText(forFileIndex: 0), "Release notes")
        XCTAssertEqual(focused.ocrBlocks(forFileIndex: 0)?.map(\.id), ["b0"])
        // The grid's own copy of a non-detail item stays shallow; only the open detail record is kept hydrated.
        XCTAssertEqual(selection.items.count, 1)
    }

    /// The grid reload after a tag keeps the same ID set, so AppState retains the shallow records
    /// in place instead of replacing the corpus. Every per-record path (retain, replaceRecord,
    /// optimistic star/tag snapshots) must keep the open item's analysis too.
    func testSameSetReloadAndRecordReplacementKeepFocusedItemOCR() async throws {
        let item = try makeItem(name: "same-set", tags: [])
        var hydrated = item
        hydrated.perFileOCR = [0: MediaFileOCR(fileIndex: 0, fileURL: item.mediaFiles[0].path, ocrText: "the leopard")]
        let other = try makeItem(name: "neighbor", tags: [])
        let app = AppState()
        app.setDisplayContext(surface: .grid, items: [item, other])
        app.mediaSelectionStore.focusedItem = hydrated
        var published: [MediaItem?] = []
        let subscription = app.focusedItemPublisher.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        var tagged = item
        tagged.metadata.tags = ["animals"]
        app.setDisplayContext(surface: .grid, items: [tagged, other])
        XCTAssertEqual(app.focusedItem?.metadata.tags, ["animals"], "the fresh record's metadata wins")
        XCTAssertEqual(app.focusedItem?.ocrText(forFileIndex: 0), "the leopard")

        var starred = tagged
        starred.metadata.starred = true
        app.replaceCachedItemIfPresent(starred)
        XCTAssertEqual(app.focusedItem?.metadata.starred, true)
        XCTAssertEqual(app.focusedItem?.ocrText(forFileIndex: 0), "the leopard")
        XCTAssertEqual(published.last??.ocrText(forFileIndex: 0), "the leopard", "detail's mirror gets the kept record")

        // A record whose media changed is a different item body: its OCR is not carried over.
        var reshaped = starred
        reshaped.mediaFiles = [tempDirectory.appendingPathComponent("replacement.png")]
        app.replaceCachedItemIfPresent(reshaped)
        XCTAssertNil(app.focusedItem?.ocrText(forFileIndex: 0))
    }

    func testFullRecordStillReplacesFocusedOCR() async throws {
        let item = try makeItem(name: "rescan", tags: [])
        var old = item
        old.perFileOCR = [0: MediaFileOCR(fileIndex: 0, fileURL: item.mediaFiles[0].path, ocrText: "old text")]
        var rescanned = item
        rescanned.perFileOCR = [0: MediaFileOCR(fileIndex: 0, fileURL: item.mediaFiles[0].path, ocrText: "new text")]
        let selection = MediaSelectionStore()
        selection.replaceItems([old])
        selection.focusedItem = old

        selection.replaceItems([rescanned])
        XCTAssertEqual(selection.focusedItem?.ocrText(forFileIndex: 0), "new text", "hydrated payloads in the new record win")
    }

    private func makeItem(name: String, tags: [String]) throws -> MediaItem {
        let metadataFile = tempDirectory.appendingPathComponent("\(name).md")
        let mediaFile = tempDirectory.appendingPathComponent("\(name).png")
        try "---\nsource: https://example.com/\(name)\n---\n".write(to: metadataFile, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: mediaFile.path, contents: Data([0x89, 0x50, 0x4E, 0x47]))
        return SampleData.createMediaItem(basePath: tempDirectory.appendingPathComponent(name), metadataFile: metadataFile,
                                          mediaFiles: [mediaFile], source: "https://example.com/\(name)", tags: tags)
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
