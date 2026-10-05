import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import MediaViewer

@MainActor
final class MediaTransferProductionTests: XCTestCase {
    private func item(files: [URL], context: URL? = nil) -> MediaItem {
        MediaItem(id: UUID(), basePath: URL(fileURLWithPath: "/tmp/transfer-fixture"),
                  metadataFile: URL(fileURLWithPath: "/tmp/transfer-fixture/item.md"),
                  mediaFiles: files, contextImage: context,
                  metadata: MediaMetadata(source: URL(string: "https://example.com/item")!,
                                          platform: "test", archivedDate: Date()))
    }

    func testDisplayedMeansActiveCarouselAssetAndRolesRemainDistinct() throws {
        let first = URL(fileURLWithPath: "/tmp/transfer-fixture/first.jpg")
        let second = URL(fileURLWithPath: "/tmp/transfer-fixture/second.jpg")
        let context = URL(fileURLWithPath: "/tmp/transfer-fixture/context.png")
        let record = item(files: [first, second], context: context)
        let shown = try MediaTransferResolver.resolve(items: [record], displayedURLs: [record.id: second], isReadable: { _ in true })
        let originals = try MediaTransferResolver.resolve(items: [record], source: .downloaded, isReadable: { _ in true })
        let screenshot = try MediaTransferResolver.resolve(items: [record], source: .context, isReadable: { _ in true })
        XCTAssertEqual(shown.files.map(\.url), [second])
        XCTAssertEqual(originals.files.map(\.url), [first, second])
        XCTAssertEqual(screenshot.files.map(\.url), [context])
    }

    func testOrderedSelectionAndRepeatedFileIdentityAreDeliberate() throws {
        let shared = URL(fileURLWithPath: "/tmp/transfer-fixture/shared.jpg")
        let first = item(files: [URL(fileURLWithPath: "/tmp/transfer-fixture/first.jpg")])
        let second = item(files: [shared])
        let third = item(files: [shared])
        let ordered = MediaTransferResolver.orderedTargets(items: [third, first, second], selected: [first.id, third.id], clicked: first)
        XCTAssertEqual(ordered.map(\.id), [third.id, first.id])
        let unrelated = MediaTransferResolver.orderedTargets(items: [third, first, second], selected: [first.id], clicked: second)
        XCTAssertEqual(unrelated.map(\.id), [second.id])
        let plan = try MediaTransferResolver.resolve(items: [third, second, third], isReadable: { _ in true })
        XCTAssertEqual(plan.itemIDs, [third.id, second.id])
        XCTAssertEqual(plan.files.map(\.url), [shared], "Internal identities survive physical-file deduplication")
    }

    func testMissingMemberAndUnavailableRoleFailEntirePlanWithoutMetadataFallback() {
        let good = URL(fileURLWithPath: "/tmp/transfer-fixture/good.jpg")
        let missing = URL(fileURLWithPath: "/tmp/transfer-fixture/missing.jpg")
        let record = item(files: [good, missing])
        XCTAssertThrowsError(try MediaTransferResolver.resolve(items: [record], source: .downloaded, isReadable: { $0 == good }))
        XCTAssertThrowsError(try MediaTransferResolver.resolve(items: [record], source: .context, isReadable: { _ in true }))
        XCTAssertThrowsError(try MediaTransferResolver.resolve(items: [item(files: [])], isReadable: { _ in true }))
        XCTAssertThrowsError(try MediaTransferResolver.resolve(items: [record], displayedURLs: [record.id: URL(fileURLWithPath: "/tmp/unrelated.jpg")], isReadable: { _ in true }))
    }

    func testPrivateAppKitPasteboardAdvertisesOneRealURLAndInternalPayloadPerItem() throws {
        let ids = [UUID(), UUID()]
        let urls = [URL(fileURLWithPath: "/tmp/first.jpg"), URL(fileURLWithPath: "/tmp/second.jpg")]
        let plan = MediaTransferPlan(itemIDs: ids, source: .displayed,
                                     files: zip(ids, urls).map { MediaTransferPlan.File(itemID: $0.0, url: $0.1) })
        let writers = try MediaFilePasteboardWriter.writers(for: plan)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects(writers))
        let values = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values.map { $0.string(forType: .fileURL) }, urls.map(\.absoluteString))
        for value in values {
            for identifier in kSupportedMediaItemTypeIdentifiers {
                let data = try XCTUnwrap(value.data(forType: NSPasteboard.PasteboardType(identifier)))
                XCTAssertEqual(try JSONDecoder().decode(MediaItemDragData.self, from: data).itemIds, ids)
            }
        }
    }

    func testAggregateProvidersPreservesOrderDeduplicatesAndSkipsFileCompanions() async throws {
        let ids = [UUID(), UUID(), UUID()]
        let first = NSItemProvider(object: MediaItemDragProvider(dragData: MediaItemDragData(itemIds: [ids[1], ids[0]])))
        let second = NSItemProvider(object: MediaItemDragProvider(dragData: MediaItemDragData(itemIds: [ids[0], ids[2]])))
        let companion = NSItemProvider(object: URL(fileURLWithPath: "/tmp/file.jpg") as NSURL)
        let completed = expectation(description: "aggregate")
        var result: MediaItemDragData?
        loadMediaItemDragData(from: [first, companion, second]) { result = $0; completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(result?.itemIds, [ids[1], ids[0], ids[2]])
    }

    func testMalformedLaterProviderDoesNotApplyEarlierPartialDrop() async {
        let first = NSItemProvider(object: MediaItemDragProvider(dragData: MediaItemDragData(itemId: UUID())))
        let malformed = NSItemProvider()
        malformed.registerDataRepresentation(forTypeIdentifier: kNoDrawItemTypeIdentifier, visibility: .all) { completion in
            completion(Data("not JSON".utf8), nil)
            return nil
        }
        let completed = expectation(description: "malformed")
        var result: MediaItemDragData?
        loadMediaItemDragData(from: [first, malformed]) { result = $0; completed.fulfill() }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertNil(result)
    }

    func testPersistentAssetIdentityWinsOverOrderAndStaleIdentityFailsClosed() throws {
        let first = URL(fileURLWithPath: "/tmp/transfer-fixture/a.jpg")
        let second = URL(fileURLWithPath: "/tmp/transfer-fixture/b.jpg")
        var record = item(files: [first, second])
        let a = UUID(), b = UUID()
        record.assets = [
            ItemAsset(assetID: a, itemID: record.id, url: first, role: .media, order: 1, availability: "available"),
            ItemAsset(assetID: b, itemID: record.id, url: second, role: .media, order: 0, availability: "available")
        ]
        let active = try MediaTransferResolver.resolve(items: [record], displayedAssetIDs: [record.id: a], isReadable: { _ in true })
        XCTAssertEqual(active.files.map(\.url), [first])
        XCTAssertEqual(active.files.first?.assetID, a)
        let originals = try MediaTransferResolver.resolve(items: [record], source: .downloaded, isReadable: { _ in true })
        XCTAssertEqual(originals.files.map(\.url), [second, first])
        XCTAssertThrowsError(try MediaTransferResolver.resolve(items: [record], displayedAssetIDs: [record.id: UUID()], isReadable: { _ in true }))
    }

    func testMouseDownSnapshotSurvivesSelectionMutationAndCancellationClearsIt() throws {
        let first = item(files: [URL(fileURLWithPath: "/tmp/a.jpg")])
        let second = item(files: [URL(fileURLWithPath: "/tmp/b.jpg")])
        var selected: [MediaItem] = [first, second]
        var capture = MediaDragGestureCapture()
        capture.mouseDown(at: .zero) { try MediaTransferResolver.resolve(items: selected, isReadable: { _ in true }) }
        selected = [second]
        XCTAssertNil(capture.takePlan(at: NSPoint(x: 2, y: 0)))
        let plan = try XCTUnwrap(capture.takePlan(at: NSPoint(x: 6, y: 0))).get()
        XCTAssertEqual(plan.itemIDs, [first.id, second.id])
        XCTAssertNil(capture.takePlan(at: NSPoint(x: 12, y: 0)), "A native drag consumes its snapshot once")
        capture.mouseDown(at: .zero) { try MediaTransferResolver.resolve(items: selected, isReadable: { _ in true }) }
        capture.cancel()
        XCTAssertNil(capture.takePlan(at: NSPoint(x: 6, y: 0)))
    }

    func testCancelledProviderDoesNotHangOrApplyPartialIDs() async {
        let first = NSItemProvider(object: MediaItemDragProvider(dragData: MediaItemDragData(itemId: UUID())))
        let stalled = NSItemProvider()
        let started = expectation(description: "provider started")
        var lateCompletion: ((Data?, Error?) -> Void)?
        stalled.registerDataRepresentation(forTypeIdentifier: kNoDrawItemTypeIdentifier, visibility: .all) { completion in
            lateCompletion = completion
            started.fulfill()
            return Progress(totalUnitCount: 1)
        }
        let completed = expectation(description: "cancel resumes")
        var callbacks = 0
        let task = loadMediaItemDragData(from: [first, stalled]) { value in
            callbacks += 1
            XCTAssertNil(value)
            completed.fulfill()
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        await fulfillment(of: [completed], timeout: 3)
        lateCompletion?(try? JSONEncoder().encode(MediaItemDragData(itemId: UUID())), nil)
        await task.value
        XCTAssertEqual(callbacks, 1)
    }

    func testInternalFileCompanionsNeverBecomeFinderImportsIncludingLegacyType() {
        let internalProvider = NSItemProvider()
        internalProvider.registerDataRepresentation(forTypeIdentifier: kLegacyMediaViewerItemTypeIdentifier, visibility: .all) { completion in
            completion(Data(), nil)
            return nil
        }
        let one = NSItemProvider(object: URL(fileURLWithPath: "/tmp/a.jpg") as NSURL)
        let two = NSItemProvider(object: URL(fileURLWithPath: "/tmp/b.jpg") as NSURL)
        XCTAssertTrue(MediaDropClassification.externalFileProviders(in: [one, internalProvider, two]).isEmpty)
        let external = MediaDropClassification.externalFileProviders(in: [two, one])
        XCTAssertTrue(external[0] === two)
        XCTAssertTrue(external[1] === one)
    }

    func testActionContextFocusOverridesBackgroundSelectionAndExportRetainsMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nodraw-transfer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.jpg")
        let contextURL = directory.appendingPathComponent("context.png")
        try Data([1]).write(to: original)
        try Data([2]).write(to: contextURL)
        var focused = item(files: [original], context: contextURL)
        focused.metadata.notes = "metadata stays attached"
        let background = item(files: [original])
        let app = AppState()
        app.setDisplayContext(surface: .table, items: [background, focused], selectedIDs: [background.id])
        app.openSingleFocus(focused)
        app.selectedItemIDs = [background.id]
        app.selectedItemID = background.id
        app.mediaSelectionStore.setActiveDetailAsset(itemID: focused.id, url: contextURL)
        let context = app.mediaActionContext
        XCTAssertEqual(context.items.map(\.id), [focused.id])
        XCTAssertEqual(try context.resolve().files.map(\.url), [contextURL])
        XCTAssertEqual(try context.exportItems(source: .context).first?.mediaFiles, [contextURL])
        XCTAssertEqual(try context.exportItems(source: .context).first?.metadata.notes, focused.metadata.notes)
        XCTAssertEqual(try context.exportItems(source: .downloaded).first?.mediaFiles, [original])
        XCTAssertTrue(context.canCopyImage)
        try FileManager.default.removeItem(at: contextURL)
        XCTAssertFalse(context.isEnabled(.copyFiles, source: .displayed))
        XCTAssertTrue(context.isEnabled(.copyFiles, source: .downloaded))
    }

    func testKeyboardMenuSkipsDisabledRowsAndWrapsInVisualOrder() {
        var executions = 0
        let entries = [KeyboardMenuEntry(id: "first", enabled: true, action: { executions += 1 }),
                       KeyboardMenuEntry(id: "disabled", enabled: false, action: { XCTFail("Disabled action") }),
                       KeyboardMenuEntry(id: "last", enabled: true, action: { executions += 1 })]
        var selection = KeyboardMenuSelection()
        selection.move(1, entries: entries)
        XCTAssertEqual(selection.selectedID, "first")
        selection.move(1, entries: entries)
        XCTAssertEqual(selection.selectedID, "last")
        selection.selected(in: entries)?.action()
        selection.move(1, entries: entries)
        XCTAssertEqual(selection.selectedID, "first")
        selection.move(-1, entries: entries)
        XCTAssertEqual(selection.selectedID, "last")
        selection.selectedID = "disabled"
        XCTAssertNil(selection.selected(in: entries))
        XCTAssertEqual(executions, 1)
    }

    func testExportEligibilityMatchesExistingEngineAndDeduplicatesItems() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nodraw-transfer-export-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = directory.appendingPathComponent("image.bmp")
        let jpeg = directory.appendingPathComponent("image.jpg")
        try Data([1]).write(to: bitmap)
        try Data([2]).write(to: jpeg)
        let unsupported = MediaActionContext(items: [item(files: [bitmap])])
        XCTAssertTrue(unsupported.canCopyImage)
        XCTAssertFalse(unsupported.isEnabled(.exportMetadata, source: .downloaded))
        let record = item(files: [jpeg])
        let duplicate = MediaActionContext(items: [record, record])
        XCTAssertEqual(try duplicate.exportItems(source: .downloaded).map(\.id), [record.id])
    }

    func testKeyboardMenuOwnsResponderAndReturnsItWithoutOrderingWindowFront() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let previous = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(previous)
        window.makeFirstResponder(previous)
        let view = KeyboardMenuKeyView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var executions = 0, dismissals = 0
        view.entries = [.init(id: "run", enabled: true, action: { executions += 1 })]
        view.selection.selectedID = "run"
        view.onDismiss = { dismissals += 1 }
        window.contentView?.addSubview(view)
        await Task.yield()
        let ready = expectation(description: "responder installation")
        DispatchQueue.main.async { ready.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertFalse(window.isVisible)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(view.handle(enter))
        XCTAssertEqual(executions, 1)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        XCTAssertTrue(view.handle(escape))
        XCTAssertEqual(dismissals, 1)
        view.removeFromSuperview()
        XCTAssertTrue(window.firstResponder === previous)
        XCTAssertNil(KeyboardMenuFocus.active)
    }
}
