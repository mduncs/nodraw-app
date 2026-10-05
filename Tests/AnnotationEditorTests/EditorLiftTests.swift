import XCTest
import AppKit
@testable import MediaViewer

@MainActor
final class EditorLiftTests: XCTestCase {
    func testProductionLiftCropsAndPlacesSubjectWithoutShrinkingOrFlipping() async throws {
        let directory = EditorPixels.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnnotationAssetStore(assetDirectory: directory)
        let service = AnnotationAIService(assetStore: store)
        // Top-left pixel rect (8,4,12,8) is Vision bottom-left rect (0.2,0.625,0.3,0.25).
        let source = EditorPixels.image(width: 40, height: 32) { x, y in
            (8..<20).contains(x) && (4..<12).contains(y) ? [255, 40, 0, 255] : [0, 40, 255, 255]
        }
        let mask = EditorPixels.mask(width: 40, height: 32) { x, y in
            (8..<20).contains(x) && (4..<12).contains(y) ? 255 : 0
        }
        let subject = makeSubject(mask: mask, bounds: CGRect(x: 0.2, y: 0.625, width: 0.3, height: 0.25))
        let lifted = try await service.liftSubject(source: source, subjectMask: subject, existingAnnotations: .empty)
        XCTAssertEqual(service.currentJob?.status, .completed)
        var document = AnnotationSet.empty
        document.apply(lifted.command)
        guard case .extractedSubject(_, let key, let bounds, _, _, _) = document.shape(id: lifted.extractedSubjectId) else {
            return XCTFail("Lift must return an extracted asset shape")
        }
        XCTAssertEqual(bounds, NormalizedRect(x: 0.2, y: 0.125, width: 0.3, height: 0.25))
        let saved = await store.loadImage(key)
        let asset = try XCTUnwrap(saved?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(asset.width, 12)
        XCTAssertEqual(asset.height, 8)
        EditorPixels.assertPixel(asset, x: 6, y: 4, equals: [255, 40, 0, 255], tolerance: 2)
        let stationary = try await EditorPixels.render(document, source: source, store: store)
        EditorPixels.assertPixel(stationary, x: 10, y: 6, equals: [255, 40, 0, 255], tolerance: 2)
        EditorPixels.assertPixel(stationary, x: 10, y: 26, equals: [0, 40, 255, 255], tolerance: 2)
        document.apply(.translateShape(shapeId: lifted.extractedSubjectId, delta: NormalizedPoint(x: 0.25, y: 0.25)))
        let moved = try await EditorPixels.render(document, source: source, store: store)
        XCTAssertEqual(try EditorPixels.pixel(moved, x: 10, y: 6)[3], 0, "The old subject position becomes a cutout")
        EditorPixels.assertPixel(moved, x: 20, y: 14, equals: [255, 40, 0, 255], tolerance: 2)
        EditorPixels.assertPixel(moved, x: 10, y: 26, equals: [0, 40, 255, 255], tolerance: 2)
    }

    func testRemoveBackgroundProducesKeepForegroundCommandWithoutPrematureFeathering() async throws {
        let directory = EditorPixels.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mask = EditorPixels.mask(width: 20, height: 20) { x, _ in x < 10 ? 255 : 0 }
        let service = AnnotationAIService(assetStore: AnnotationAssetStore(assetDirectory: directory),
                                          backgroundMaskProvider: { _ in mask })
        let command = try await service.removeBackground(from: directory.appendingPathComponent("unused"), featherRadius: 0)
        var document = AnnotationSet.empty
        document.apply(command)
        guard case .mask(_, _, _, let mode, _, _) = document.shapes.first else { return XCTFail("Expected mask") }
        XCTAssertEqual(mode, .maskKeep)
        let source = EditorPixels.image(width: 20, height: 20) { _, _ in [255, 50, 0, 255] }
        let output = try await EditorPixels.render(document, source: source)
        EditorPixels.assertPixel(output, x: 3, y: 10, equals: [255, 50, 0, 255], tolerance: 2)
        XCTAssertEqual(try EditorPixels.pixel(output, x: 16, y: 10)[3], 0)
    }

    func testFailedOperationStaysFailedInsteadOfBeingCompletedByDefer() async throws {
        let directory = EditorPixels.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = AnnotationAIService(assetStore: AnnotationAssetStore(assetDirectory: directory),
                                          backgroundMaskProvider: { _ in nil })
        do {
            _ = try await service.removeBackground(from: directory, featherRadius: 0)
            XCTFail("A missing mask cannot produce an edit")
        } catch {
            guard case .failed = service.currentJob?.status else { return XCTFail("Failure must remain observable") }
            XCTAssertFalse(service.isProcessing)
        }
    }

    func testInvalidLiftBoundsFailBeforeCreatingAssetOrCommand() async throws {
        let directory = EditorPixels.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = AnnotationAIService(assetStore: AnnotationAssetStore(assetDirectory: directory))
        let source = EditorPixels.image(width: 8, height: 8) { _, _ in [255, 0, 0, 255] }
        let mask = EditorPixels.mask(width: 8, height: 8) { _, _ in 255 }
        do {
            _ = try await service.liftSubject(source: source, subjectMask: makeSubject(mask: mask, bounds: .zero), existingAnnotations: .empty)
            XCTFail("Zero-area subjects cannot produce a lifted layer")
        } catch {
            guard case .failed = service.currentJob?.status else { return XCTFail("Expected failed job") }
            XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
        }
    }

    func testCancelRejectsLateNonCooperativeProviderResult() async throws {
        let directory = EditorPixels.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = MaskProviderGate()
        let service = AnnotationAIService(assetStore: AnnotationAssetStore(assetDirectory: directory),
                                          backgroundMaskProvider: { _ in await gate.value() })
        let task = Task { try await service.removeBackground(from: directory, featherRadius: 0) }
        await gate.waitUntilStarted()
        XCTAssertTrue(service.isProcessing)
        service.cancel()
        await gate.resolve(EditorPixels.mask(width: 2, height: 2) { _, _ in 255 })
        do { _ = try await task.value; XCTFail("Cancelled work must not return a command") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(service.currentJob?.status, .cancelled)
        XCTAssertFalse(service.isProcessing)
    }

    func testOlderOperationCannotOverwriteNewerCompletionOrReturnStaleEdit() async throws {
        let directory = EditorPixels.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = MaskProviderGate()
        let mask = EditorPixels.mask(width: 2, height: 2) { _, _ in 255 }
        let service = AnnotationAIService(assetStore: AnnotationAssetStore(assetDirectory: directory),
            backgroundMaskProvider: { _ in await gate.value() }, personMaskProvider: { _ in mask })
        let older = Task { try await service.removeBackground(from: directory, featherRadius: 0) }
        await gate.waitUntilStarted()
        let oldID = service.currentJob?.id
        _ = try await service.isolatePerson(from: directory, featherRadius: 0)
        let newID = service.currentJob?.id
        XCTAssertNotEqual(newID, oldID)
        XCTAssertEqual(service.currentJob?.status, .completed)
        await gate.resolve(mask)
        do { _ = try await older.value; XCTFail("Superseded work must not return a command") }
        catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertEqual(service.currentJob?.id, newID)
        XCTAssertEqual(service.currentJob?.status, .completed)
    }

    private func makeSubject(mask: CGImage, bounds: CGRect) -> SubjectMask {
        let pixels = SubjectMask.extractPixelData(from: mask)!
        return SubjectMask(mask: mask, bounds: bounds, instanceIndex: 1,
                           maskPixelData: pixels.data, bytesPerRow: pixels.bytesPerRow)
    }
}

/// Intentionally ignores cancellation so tests exercise the service's generation gate.
private actor MaskProviderGate {
    private var result: CheckedContinuation<CGImage?, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var started = false
    func value() async -> CGImage? {
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
    func resolve(_ mask: CGImage?) {
        result?.resume(returning: mask)
        result = nil
    }
}
