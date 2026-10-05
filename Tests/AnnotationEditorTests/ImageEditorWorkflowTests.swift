import XCTest
import AppKit
import ImageIO
import Combine
import GRDB
@testable import MediaViewer

@MainActor
final class ImageEditorWorkflowTests: XCTestCase {
    func testMenuActionsUseTheSameSessionHistorySelectionAndPrivateClipboard() throws {
        let pasteboard = NSPasteboard(name: .init("NoDraw.EditorMenuTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let session = AnnotationEditorSession(itemId: UUID(), pasteboard: pasteboard, autosaveInterval: nil)
        let first = AnnotationShape.rectangle(id: UUID(), rect: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4), style: .defaultRectangle)
        let second = AnnotationShape.text(id: UUID(), position: .init(x: 0.4, y: 0.5), content: "Menu fixture", style: .default)
        session.executeGroup([.addShape(shape: first, layerId: nil), .addShape(shape: second, layerId: nil)])
        let original = session.snapshot()
        var imagePasteCalls = 0
        func perform(_ action: ImageEditorMenuAction) {
            // This is the production handler called by the mounted host's menu
            // notification route, independently of the keyboard event monitor.
            action.perform(on: session, pasteImage: { imagePasteCalls += 1 })
        }

        perform(.selectAll)
        XCTAssertEqual(session.selectedShapeIds, Set([first.id, second.id]))
        perform(.copy)
        let copied = try XCTUnwrap(pasteboard.data(forType: AnnotationEditorSession.shapesPasteboardType))
        XCTAssertEqual(try JSONDecoder().decode([AnnotationShape].self, from: copied), [first, second])
        XCTAssertEqual(session.annotationSet, original, "Copy must not mutate the document")

        perform(.cut)
        let cutDocument = session.snapshot()
        XCTAssertEqual(session.annotationSet.shapeCount, 0)
        XCTAssertTrue(session.selectedShapeIds.isEmpty)
        perform(.undo)
        XCTAssertEqual(session.annotationSet, original)
        perform(.redo)
        XCTAssertEqual(session.annotationSet, cutDocument)

        perform(.paste)
        let pastedDocument = session.snapshot()
        XCTAssertEqual(session.annotationSet.shapeCount, 2)
        XCTAssertEqual(session.selectedShapeIds.count, 2)
        XCTAssertTrue(session.selectedShapeIds.isDisjoint(with: [first.id, second.id]))
        XCTAssertEqual(imagePasteCalls, 0, "Annotation JSON paste must not fall through to image import")
        perform(.undo)
        XCTAssertEqual(session.annotationSet, cutDocument)
        perform(.redo)
        XCTAssertEqual(session.annotationSet, pastedDocument)

        pasteboard.clearContents()
        perform(.paste)
        XCTAssertEqual(imagePasteCalls, 1, "The host handles image paste when annotation JSON is absent")
        XCTAssertEqual(session.annotationSet, pastedDocument)
    }

    func testCompletedEditCommitsOnceAndPersistsToPinnedAsset() async throws {
        try await withWorkflow { context in
            let finished = expectation(description: "Edit finished")
            let observation = completion(of: context.workflow, expectation: finished)
            defer { observation.cancel() }
            let layerID = UUID()
            let shape = AnnotationShape.text(id: UUID(), position: .init(x: 0.2, y: 0.3), content: "Async edit", style: .default)
            context.workflow.runEdit("Produced image edit") {
                .group([.addLayer(name: "Generated", id: layerID), .addShape(shape: shape, layerId: layerID)])
            }
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertNil(context.workflow.errorMessage)
            XCTAssertEqual(context.session.revision, 1)
            XCTAssertEqual(context.session.undoCount, 1)
            XCTAssertEqual(context.session.undoDescription, "Produced image edit")
            XCTAssertEqual(context.session.annotationSet.shapes, [shape])

            try await context.session.saveNow()
            let stored = try await context.store.fetchAnnotations(itemId: context.session.itemId, assetID: context.session.assetID)
            XCTAssertEqual(stored, context.session.annotationSet)
            XCTAssertFalse(context.session.isDirty)
        }
    }

    func testExportRejectsOriginalAndItsFileAliasesWithoutChangingBytes() async throws {
        let image = EditorPixels.image(width: 24, height: 16) { _, _ in [180, 30, 50, 255] }
        try await withWorkflow(sourceImage: image) { context in
            let original = try Data(contentsOf: context.source)
            context.session.execute(.setAdjustments(PhotoAdjustments(brightness: 0.3)))
            let directory = context.source.deletingLastPathComponent()
            let symlink = directory.appendingPathComponent("source-link.png")
            let hardlink = directory.appendingPathComponent("source-hardlink.png")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: context.source)
            try FileManager.default.linkItem(at: context.source, to: hardlink)
            for destination in [context.source, symlink, hardlink] {
                do {
                    try await context.workflow.export(to: destination)
                    XCTFail("Export must not overwrite its original, including file aliases")
                } catch ImageEditorWorkflow.ExportError.overwriteOriginal {
                } catch { XCTFail("Expected overwrite protection, got \(error)") }
                XCTAssertEqual(try Data(contentsOf: context.source), original)
                XCTAssertEqual(try Data(contentsOf: destination), original)
            }
            XCTAssertTrue(context.session.isDirty, "A refused export must not discard the document's edits")
        }
    }

    func testImportedPNGSurvivesDocumentReopenAndExportsAtSourceDimensions() async throws {
        let source = EditorPixels.image(width: 96, height: 64) { _, _ in [255, 0, 0, 255] }
        try await withWorkflow(sourceImage: source) { context in
            let originalBytes = try Data(contentsOf: context.source)
            let directory = context.source.deletingLastPathComponent()
            let importURL = directory.appendingPathComponent("blue-portrait.png")
            let importedImage = EditorPixels.image(width: 12, height: 24) { _, _ in [0, 0, 255, 255] }
            let importBytes = ImageMasking.cgImageToPNGData(importedImage)
            XCTAssertFalse(importBytes.isEmpty)
            try importBytes.write(to: importURL)
            let finished = expectation(description: "Real PNG import finished")
            let observation = completion(of: context.workflow, expectation: finished)
            defer { observation.cancel() }
            context.workflow.importImages([importURL])
            await fulfillment(of: [finished], timeout: 5)
            XCTAssertNil(context.workflow.errorMessage)
            XCTAssertEqual(context.session.annotationSet.layers.count, 1)
            XCTAssertEqual(context.session.annotationSet.layers.first?.name, "blue-portrait")
            XCTAssertEqual(context.session.undoCount, 1)
            let shape = try XCTUnwrap(context.session.annotationSet.shapes.first)
            guard case .extractedSubject(_, let key, let bounds, _, _, _) = shape else {
                return XCTFail("Imported image must be a persisted raster asset reference")
            }
            XCTAssertEqual(bounds.width * 96 / (bounds.height * 64), 0.5, accuracy: 0.0001,
                "Placement must preserve the imported image's pixel aspect ratio")
            let importedAssetExists = await context.assetStore.exists(key)
            XCTAssertTrue(importedAssetExists)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("assets/\(key).png").path))
            let document = context.session.snapshot()
            XCTAssertTrue(context.session.undo())
            XCTAssertEqual(context.session.annotationSet, .empty)
            XCTAssertTrue(context.session.redo())
            XCTAssertEqual(context.session.annotationSet, document)
            try await context.session.saveNow()

            let firstExportURL = directory.appendingPathComponent("edited-before-reopen.png")
            try await context.workflow.export(to: firstExportURL)
            let firstExport = try decodePNG(firstExportURL)
            XCTAssertEqual(firstExport.width, 96)
            XCTAssertEqual(firstExport.height, 64)
            EditorPixels.assertPixel(firstExport, x: 2, y: 2, equals: [255, 0, 0, 255], tolerance: 4)
            EditorPixels.assertPixel(firstExport, x: 48, y: 32, equals: [0, 0, 255, 255], tolerance: 4)

            // Fresh database/store/asset-cache instances prove the JSON reference
            // and its PNG survive outside the original session's memory caches.
            let reopenedDatabase = DatabaseManager(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
            try await reopenedDatabase.initialize()
            let reopenedStore = AnnotationStore(database: reopenedDatabase)
            let reopenedSession = AnnotationEditorSession(itemId: context.session.itemId, store: reopenedStore,
                assetID: context.session.assetID, autosaveInterval: nil)
            try await reopenedSession.load()
            XCTAssertEqual(reopenedSession.annotationSet, document)
            XCTAssertFalse(reopenedSession.isDirty)
            let reopenedAssets = AnnotationAssetStore(assetDirectory: directory.appendingPathComponent("assets"))
            let reopenedWorkflow = ImageEditorWorkflow(session: reopenedSession, sourceURL: context.source, assetStore: reopenedAssets)
            let reopenedExportURL = directory.appendingPathComponent("edited-after-reopen.png")
            try await reopenedWorkflow.export(to: reopenedExportURL)
            let reopenedExport = try decodePNG(reopenedExportURL)
            XCTAssertEqual(reopenedExport.width, 96)
            XCTAssertEqual(reopenedExport.height, 64)
            for (x, y) in [(2, 2), (48, 32), (93, 61)] {
                EditorPixels.assertPixel(reopenedExport, x: x, y: y,
                    equals: try EditorPixels.pixel(firstExport, x: x, y: y), tolerance: 1)
            }
            XCTAssertEqual(try Data(contentsOf: context.source), originalBytes)
            XCTAssertEqual(try Data(contentsOf: importURL), importBytes)
        }
    }

    func testExportPreservesOriginalDimensionsAboveDisplayCacheDownsamplingThreshold() async throws {
        let width = 5_001
        let height = 4_001
        // Encode and release the large source bitmap before entering the async
        // workflow. Keep only its compact PNG bytes in the test's live scope.
        let sourcePNG: Data = try autoreleasepool {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = try XCTUnwrap(context.makeImage())
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        try await withWorkflow(sourcePNG: sourcePNG) { context in
            let destination = context.source.deletingLastPathComponent().appendingPathComponent("full-resolution-export.png")
            try await context.workflow.export(to: destination)
            // Inspect metadata instead of creating another 80 MB decoded image.
            let exported = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(exported, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, width)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, height)
            XCTAssertEqual(try Data(contentsOf: context.source), sourcePNG)
            XCTAssertEqual(context.session.annotationSet, .empty)
        }
    }

    func testHumanEditDuringSuspendedOperationRejectsStaleResult() async throws {
        try await withWorkflow { context in
            let gate = suspendedEdit()
            let finished = expectation(description: "Stale operation finished")
            let observation = completion(of: context.workflow, expectation: finished)
            defer { observation.cancel() }
            context.workflow.runEdit("Stale AI edit") { try await gate.produce() }
            await fulfillment(of: [gate.started], timeout: 2)
            context.session.execute(.addLayer(name: "Keep human edit"))
            let humanDocument = context.session.snapshot()
            let humanRevision = context.session.revision
            gate.resume(.success(.addLayer(name: "Do not apply")))
            await fulfillment(of: [finished, gate.returned], timeout: 2)

            XCTAssertEqual(context.session.annotationSet, humanDocument)
            XCTAssertEqual(context.session.revision, humanRevision)
            XCTAssertEqual(context.session.undoCount, 1)
            XCTAssertTrue(context.session.isDirty)
            XCTAssertNotNil(context.workflow.errorMessage)
            XCTAssertFalse(context.workflow.isWorking)
        }
    }

    func testCancelledProducerCannotCommitOrStopItsReplacement() async throws {
        try await withWorkflow { context in
            let old = suspendedEdit()
            context.workflow.runEdit("Cancelled edit") { try await old.produce() }
            await fulfillment(of: [old.started], timeout: 2)
            context.workflow.cancel()
            XCTAssertFalse(context.workflow.isWorking)

            let replacement = suspendedEdit()
            context.workflow.runEdit("Replacement edit") { try await replacement.produce() }
            await fulfillment(of: [replacement.started], timeout: 2)
            let unwantedEdit = expectation(description: "Cancelled operation must not mutate document")
            unwantedEdit.isInverted = true
            let revisionObserver = context.session.$revision.dropFirst().sink { _ in unwantedEdit.fulfill() }
            old.resume(.success(.addLayer(name: "Cancelled content")))
            await fulfillment(of: [old.returned], timeout: 2)
            await fulfillment(of: [unwantedEdit], timeout: 0.1)
            revisionObserver.cancel()
            XCTAssertTrue(context.workflow.isWorking, "Old task cleanup must not stop the replacement")
            XCTAssertNil(context.workflow.errorMessage)
            XCTAssertEqual(context.session.annotationSet, .empty)

            let finished = expectation(description: "Replacement finished")
            let observation = completion(of: context.workflow, expectation: finished)
            defer { observation.cancel() }
            replacement.resume(.success(.addLayer(name: "Replacement content")))
            await fulfillment(of: [finished, replacement.returned], timeout: 2)
            XCTAssertEqual(context.session.annotationSet.layers.map(\.name), ["Replacement content"])
            XCTAssertEqual(context.session.revision, 1)
        }
    }

    func testReplacedOperationFailureCannotReplaceNewOperationState() async throws {
        try await withWorkflow { context in
            let old = suspendedEdit()
            context.workflow.runEdit("Superseded edit") { try await old.produce() }
            await fulfillment(of: [old.started], timeout: 2)
            let replacement = suspendedEdit()
            context.workflow.runEdit("New edit") { try await replacement.produce() }
            await fulfillment(of: [replacement.started], timeout: 2)
            let unwantedError = expectation(description: "Old error must stay discarded")
            unwantedError.isInverted = true
            let errors = context.workflow.$errorMessage.compactMap { $0 }.sink { _ in unwantedError.fulfill() }
            old.resume(.failure(CocoaError(.fileReadCorruptFile)))
            await fulfillment(of: [old.returned], timeout: 2)
            await fulfillment(of: [unwantedError], timeout: 0.1)
            errors.cancel()
            XCTAssertTrue(context.workflow.isWorking)
            XCTAssertNil(context.workflow.errorMessage)

            let finished = expectation(description: "New edit finished")
            let observation = completion(of: context.workflow, expectation: finished)
            defer { observation.cancel() }
            replacement.resume(.success(.addLayer(name: "New content")))
            await fulfillment(of: [finished, replacement.returned], timeout: 2)
            XCTAssertEqual(context.session.annotationSet.layers.map(\.name), ["New content"])
        }
    }

    func testDeactivatedWorkflowRejectsLateImportStartAndCanReactivate() async throws {
        try await withWorkflow { context in
            context.workflow.deactivate()
            let unexpectedStart = expectation(description: "Inactive producer must not start")
            unexpectedStart.isInverted = true
            context.workflow.runEdit("Late dropped image") {
                unexpectedStart.fulfill()
                return .addLayer(name: "Hidden edit")
            }
            await fulfillment(of: [unexpectedStart], timeout: 0.1)
            XCTAssertEqual(context.session.annotationSet, .empty)
            XCTAssertEqual(context.session.revision, 0)
            XCTAssertFalse(context.workflow.isWorking)
            XCTAssertFalse(context.session.isDirty)

            context.workflow.activate()
            let finished = expectation(description: "Reactivated editor completed its edit")
            let observation = completion(of: context.workflow, expectation: finished)
            defer { observation.cancel() }
            context.workflow.runEdit("Active edit") { .addLayer(name: "Visible edit") }
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(context.session.annotationSet.layers.map(\.name), ["Visible edit"])
            XCTAssertEqual(context.session.revision, 1)
            XCTAssertNil(context.workflow.errorMessage)
        }
    }

    func testIdleSourceReplacementInvalidatesCachedSubjectsNewEditsAndExport() async throws {
        try await withWorkflow { context in
            let maskImage = EditorPixels.mask(width: 8, height: 8) { _, _ in 255 }
            let pixels = try XCTUnwrap(SubjectMask.extractPixelData(from: maskImage))
            let mask = SubjectMask(mask: maskImage, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                instanceIndex: 1, maskPixelData: pixels.data, bytesPerRow: pixels.bytesPerRow)
            await SubjectMaskCache.shared.set([mask], for: context.source)
            let analyzed = expectation(description: "Cached subjects loaded for original source")
            let observation = completion(of: context.workflow, expectation: analyzed)
            defer { observation.cancel() }
            context.workflow.analyzeSubjects()
            await fulfillment(of: [analyzed], timeout: 2)
            XCTAssertEqual(context.workflow.subjectMasks, [mask])
            context.workflow.selectedSubject = mask

            let replacement = EditorPixels.image(width: 8, height: 8) { _, _ in [0, 255, 0, 255] }
            try ImageMasking.cgImageToPNGData(replacement).write(to: context.source, options: .atomic)
            // A nonempty subject cache must not bypass the pinned-source check.
            context.workflow.errorMessage = nil
            context.workflow.analyzeSubjects()
            XCTAssertNotNil(context.workflow.errorMessage)
            XCTAssertFalse(context.workflow.isWorking)

            let unwantedProducer = expectation(description: "Replaced source must not start another edit")
            unwantedProducer.isInverted = true
            context.workflow.errorMessage = nil
            context.workflow.runEdit("Wrong-source edit") {
                unwantedProducer.fulfill()
                return .addLayer(name: "Must not apply")
            }
            await fulfillment(of: [unwantedProducer], timeout: 0.1)
            XCTAssertNotNil(context.workflow.errorMessage)
            XCTAssertEqual(context.session.annotationSet, .empty)
            XCTAssertEqual(context.session.revision, 0)

            let destination = context.source.deletingLastPathComponent().appendingPathComponent("wrong-source-export.png")
            do {
                try await context.workflow.export(to: destination)
                XCTFail("Export must not mix the replacement's pixels with the original session")
            } catch ImageEditorWorkflow.ExportError.sourceChanged {
            } catch { XCTFail("Expected source replacement rejection, got \(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            await SubjectMaskCache.shared.evict(context.source)
        }
    }

    func testChangedSourceRejectsSuspendedEdit() async throws {
        try await assertSourceChangeRejectsEdit { source in
            try Data("Different replacement bytes with a different size".utf8).write(to: source, options: .atomic)
        }
    }

    func testSameSizeReplacementWithPreservedModificationDateRejectsSuspendedEdit() async throws {
        try await assertSourceChangeRejectsEdit { source in
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
            let size = try Data(contentsOf: source).count
            try Data(repeating: 0x7F, count: size).write(to: source, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
            XCTAssertEqual(try Data(contentsOf: source).count, size)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date, modified)
        }
    }

    func testDeletedSourceRejectsSuspendedEdit() async throws {
        try await assertSourceChangeRejectsEdit { source in
            try FileManager.default.removeItem(at: source)
        }
    }

    private func assertSourceChangeRejectsEdit(_ replace: (URL) throws -> Void) async throws {
        try await withWorkflow { context in
            let gate = suspendedEdit()
            let finished = expectation(description: "Invalidated operation finished")
            let observation = completion(of: context.workflow, expectation: finished)
            defer { observation.cancel() }
            context.workflow.runEdit("Original source result") { try await gate.produce() }
            await fulfillment(of: [gate.started], timeout: 2)
            try replace(context.source)
            gate.resume(.success(.addLayer(name: "Old source content")))
            await fulfillment(of: [finished, gate.returned], timeout: 2)
            XCTAssertEqual(context.session.annotationSet, .empty)
            XCTAssertEqual(context.session.revision, 0)
            XCTAssertFalse(context.session.canUndo)
            XCTAssertFalse(context.session.isDirty)
            XCTAssertNotNil(context.workflow.errorMessage)
            XCTAssertFalse(context.workflow.isWorking)
        }
    }

    private func completion(of workflow: ImageEditorWorkflow, expectation: XCTestExpectation) -> AnyCancellable {
        workflow.$isWorking.drop(while: { !$0 }).filter { !$0 }.prefix(1).sink { _ in expectation.fulfill() }
    }

    private func suspendedEdit() -> SuspendedEdit {
        SuspendedEdit(started: expectation(description: "Producer suspended"), returned: expectation(description: "Producer returned"))
    }

    @MainActor
    private final class SuspendedEdit {
        let started: XCTestExpectation
        let returned: XCTestExpectation
        private var continuation: CheckedContinuation<AnnotationCommand, Error>?

        init(started: XCTestExpectation, returned: XCTestExpectation) {
            self.started = started
            self.returned = returned
        }

        func produce() async throws -> AnnotationCommand {
            defer { returned.fulfill() }
            // Deliberately ignores cancellation like an already-running native
            // provider. The production workflow must reject its late result.
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }

        func resume(_ result: Result<AnnotationCommand, Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private struct Context {
        let workflow: ImageEditorWorkflow
        let session: AnnotationEditorSession
        let store: AnnotationStore
        let source: URL
        let assetStore: AnnotationAssetStore
    }

    private func decodePNG(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func withWorkflow(sourceImage: CGImage? = nil, sourcePNG: Data? = nil, _ body: (Context) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("image-editor-workflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let sourceData = sourcePNG ?? sourceImage.map(ImageMasking.cgImageToPNGData)
            ?? ImageMasking.cgImageToPNGData(EditorPixels.image(width: 8, height: 8) { _, _ in [255, 0, 0, 255] })
        try sourceData.write(to: source)
        // Integral seconds round-trip exactly through filesystem timestamps. This
        // keeps the preserved-mtime replacement test sensitive to inode checks,
        // not floating-point timestamp precision differences.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: source.path)
        let database = DatabaseManager(databaseURL: directory.appendingPathComponent("fixture.sqlite"))
        try await database.initialize()
        let itemID = UUID()
        let assetID: UUID = try await database.write { db in
            let item = MediaItem(id: itemID, basePath: directory, metadataFile: directory.appendingPathComponent("item.md"), mediaFiles: [source], metadata: MediaMetadata(source: URL(string: "https://example.com/editor")!, platform: "test"))
            try MediaItemRecord(from: item).insert(db)
            return try ItemAssetStore.prepareWrite(in: db, itemID: itemID, assetID: nil, index: 0).id
        }
        let store = AnnotationStore(database: database)
        let assetStore = AnnotationAssetStore(assetDirectory: directory.appendingPathComponent("assets"))
        let session = AnnotationEditorSession(itemId: itemID, store: store, assetID: assetID, autosaveInterval: nil)
        let workflow = ImageEditorWorkflow(session: session, sourceURL: source, assetStore: assetStore)
        defer { workflow.cancel() }
        try await body(Context(workflow: workflow, session: session, store: store, source: source, assetStore: assetStore))
    }
}
