import XCTest
import AppKit
@testable import SubjectIsolation

final class SubjectHighlightViewTests: XCTestCase {
    func testHitTestingIgnoresAspectFitLetterboxArea() {
        let view = makeHighlightView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertNil(view.subjectIndex(at: CGPoint(x: 25, y: 50)))
        XCTAssertEqual(view.subjectIndex(at: CGPoint(x: 100, y: 50)), 1)
        XCTAssertEqual(view.imageContentRect, CGRect(x: 50, y: 0, width: 100, height: 100))
    }

    func testBottomLeftCoordinatesStayAlignedInPortraitLetterboxingAndOffsetBounds() {
        let view = makeHighlightView(frame: NSRect(x: 0, y: 0, width: 100, height: 200),
                                     rectangles: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)])
        view.bounds.origin = CGPoint(x: 10, y: 20)
        view.layout()
        XCTAssertEqual(view.imageContentRect, CGRect(x: 10, y: 70, width: 100, height: 100))
        XCTAssertEqual(view.subjectIndex(at: CGPoint(x: 30, y: 90)), 1)
        XCTAssertNil(view.subjectIndex(at: CGPoint(x: 30, y: 150)))
        XCTAssertNil(view.subjectIndex(at: CGPoint(x: 30, y: 30)))
        view.beginGlow(for: [1], animated: false)
        let highlight = view.layer!.sublayers![2].sublayers![0]
        let mask = highlight.mask as! CAShapeLayer
        XCTAssertEqual(mask.path?.boundingBoxOfPath, CGRect(x: 20, y: 80, width: 20, height: 20))
        XCTAssertEqual(mask.bounds, view.bounds)
    }

    func testContourHolesAreBackgroundEvenWhenOuterContourContainsThem() {
        let view = makeHighlightView()
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: 1, height: 1))
        path.addRect(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        view.isolationResult = makeResult(paths: [path])
        XCTAssertNil(view.subjectIndex(at: CGPoint(x: 50, y: 50)))
        XCTAssertEqual(view.subjectIndex(at: CGPoint(x: 20, y: 20)), 1)
    }

    func testInvalidHighlightIndexDoesNotActivateGlowOrLift() {
        let view = makeHighlightView()
        view.beginGlow(for: [0, 9], animated: false)
        XCTAssertFalse(view.isGlowActive)
        XCTAssertFalse(view.requestLift(animated: false))
        XCTAssertNil(view.copyHighlightedSubjects())
    }

    func testHighlightWithoutContourPathsUsesRealMaskHitsWithoutInventingAnOutline() {
        let view = makeHighlightView(includePaths: false)
        view.beginGlow(for: [1], animated: false)
        XCTAssertFalse(view.isGlowActive)
        XCTAssertEqual(view.subjectIndex(at: CGPoint(x: 50, y: 50)), 1)
    }

    func testMissingContourFallsBackToForegroundPixelsWithBottomLeftCoordinates() {
        let view = makeHighlightView()
        let mask = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 2,
                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                           provider: CGDataProvider(data: Data([0, 255, 0, 0]) as CFData)!, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)!
        view.isolationResult = IsolationResult(subjects: [SubjectInstance(index: 1, mask: mask,
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), contourPath: nil, outerContourPath: nil)],
            foregroundMask: nil, semanticMasks: [:], imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(view.subjectIndex(at: CGPoint(x: 75, y: 75)), 1)
        XCTAssertNil(view.subjectIndex(at: CGPoint(x: 25, y: 75)))
        XCTAssertNil(view.subjectIndex(at: CGPoint(x: 75, y: 25)))
    }

    func testHidingSourceLeavesMaskedSubjectAvailableForOverlay() {
        let view = makeHighlightView()
        view.showsSourceImage = false
        XCTAssertTrue(view.layer!.sublayers![0].isHidden)
        XCTAssertFalse(view.layer!.sublayers![2].isHidden)
        XCTAssertNotNil(view.layer!.sublayers![2].sublayers![0].contents)
    }

    func testHoverIsTransientAndNeverCommitsOrExportsSelection() {
        let view = makeHighlightView()
        var callbackCount = 0
        view.onSelectionChanged = { _ in callbackCount += 1 }
        view.previewSubject(at: CGPoint(x: 50, y: 50))
        XCTAssertEqual(view.hoveredSubjectIndex, 1)
        XCTAssertTrue(view.isGlowActive)
        XCTAssertTrue(view.selectedSubjects.isEmpty)
        XCTAssertNil(view.copyHighlightedSubjects())
        XCTAssertFalse(view.requestLift(animated: false))
        view.previewSubject(at: nil)
        XCTAssertNil(view.hoveredSubjectIndex)
        XCTAssertFalse(view.isGlowActive)
        XCTAssertEqual(callbackCount, 0)
    }

    func testMultiSelectionTogglesAndBackgroundClearsWithoutInventingSubject() {
        let view = makeTwoSubjectView()
        var changes: [IndexSet] = []
        view.onSelectionChanged = { changes.append($0) }
        view.selectSubject(at: CGPoint(x: 20, y: 50))
        view.selectSubject(at: CGPoint(x: 80, y: 50), extendingSelection: true)
        XCTAssertEqual(view.selectedSubjects, [1, 2])
        view.selectSubject(at: CGPoint(x: 20, y: 50), extendingSelection: true)
        XCTAssertEqual(view.selectedSubjects, [2])
        view.selectSubject(at: CGPoint(x: 50, y: 50), extendingSelection: true)
        XCTAssertEqual(view.selectedSubjects, [2])
        view.selectSubject(at: CGPoint(x: 50, y: 50))
        XCTAssertTrue(view.selectedSubjects.isEmpty)
        XCTAssertFalse(view.isGlowActive)
        XCTAssertEqual(changes, [[1], [1, 2], [2], []])
    }

    func testDisablingMultiSelectionMakesExtendedClickReplaceSelection() {
        let view = makeTwoSubjectView()
        view.allowsMultipleSelection = false
        view.selectSubject(at: CGPoint(x: 20, y: 50))
        view.selectSubject(at: CGPoint(x: 80, y: 50), extendingSelection: true)
        XCTAssertEqual(view.selectedSubjects, [2])
    }

    func testHoverAddsPreviewWithoutRemovingCommittedGlow() {
        let view = makeTwoSubjectView()
        view.selectedSubjects = [1]
        view.previewSubject(at: CGPoint(x: 80, y: 50))
        let glow = view.layer!.sublayers!.last as! GlowLayer
        XCTAssertEqual(glow.activeSubjectIndexes, [1, 2])
        XCTAssertEqual(view.selectedSubjects, [1])
        view.previewSubject(at: nil)
        XCTAssertEqual(glow.activeSubjectIndexes, [1])
    }

    func testSameResultAssignmentPreservesSelectionHoverAndGlowLayers() {
        let view = makeTwoSubjectView()
        view.selectedSubjects = [1]
        view.previewSubject(at: CGPoint(x: 80, y: 50))
        let glow = view.layer!.sublayers!.last as! GlowLayer
        let previous = glow.sublayers!.first!.sublayers!.map(ObjectIdentifier.init)
        var changes = 0
        view.onSelectionChanged = { _ in changes += 1 }
        let result = view.isolationResult
        view.isolationResult = result
        XCTAssertEqual(view.selectedSubjects, [1])
        XCTAssertEqual(view.hoveredSubjectIndex, 2)
        XCTAssertEqual(glow.sublayers!.first!.sublayers!.map(ObjectIdentifier.init), previous)
        XCTAssertEqual(changes, 0)
    }

    func testDifferentResultClearsResultLocalIDsAndPreview() {
        let view = makeTwoSubjectView()
        view.selectedSubjects = [1, 2]
        view.previewSubject(at: CGPoint(x: 20, y: 50))
        var changes: [IndexSet] = []
        view.onSelectionChanged = { changes.append($0) }
        view.isolationResult = makeResult(paths: [])
        XCTAssertTrue(view.selectedSubjects.isEmpty)
        XCTAssertNil(view.hoveredSubjectIndex)
        XCTAssertFalse(view.isGlowActive)
        XCTAssertNil(view.subjectIndex(at: CGPoint(x: 20, y: 50)))
        XCTAssertEqual(changes, [[]])
    }

    func testExplicitLiftUsesCommittedValidIDsOnly() {
        let view = makeTwoSubjectView()
        view.selectedSubjects = [1, 99]
        view.previewSubject(at: CGPoint(x: 80, y: 50))
        var lifts: [IndexSet] = []
        view.onSubjectLiftRequested = { lifts.append($0) }
        XCTAssertTrue(lifts.isEmpty)
        XCTAssertTrue(view.requestLift(animated: false))
        XCTAssertEqual(lifts, [[1]])
    }

    func testReduceMotionUsesStaticOutlineAndNeverAddsSpatialLift() {
        let view = makeHighlightView()
        view.reduceMotionOverride = false
        view.previewSubject(at: CGPoint(x: 50, y: 50))
        view.selectedSubjects = [1]
        XCTAssertTrue(view.requestLift())
        let glow = view.layer!.sublayers!.last as! GlowLayer
        XCTAssertNotNil(glow.animation(forKey: "subjectLift"))
        // Enabling the preference must cancel already-running spatial/chase animations too.
        view.reduceMotionOverride = true
        XCTAssertTrue(view.requestLift())
        let strokes = glow.sublayers!.first!.sublayers!.flatMap { $0.sublayers ?? [] }.compactMap { $0 as? CAShapeLayer }
        XCTAssertFalse(strokes.isEmpty)
        XCTAssertTrue(strokes.allSatisfy { $0.strokeEnd == 1 && ($0.animationKeys() ?? []).isEmpty })
        XCTAssertNil(glow.animation(forKey: "subjectLift"))
        XCTAssertTrue(CATransform3DIsIdentity(glow.transform))
    }

    func testDefaultInteractionAndDraggingAreOptIn() {
        let view = makeHighlightView()
        XCTAssertFalse(view.isSubjectInteractionEnabled)
        XCTAssertFalse(view.allowsSubjectDragging)
        XCTAssertTrue(view.trackingAreas.isEmpty)
        view.isSubjectInteractionEnabled = true
        XCTAssertEqual(view.trackingAreas.count, 1)
        view.previewSubject(at: CGPoint(x: 50, y: 50))
        view.isSubjectInteractionEnabled = false
        XCTAssertNil(view.hoveredSubjectIndex)
        XCTAssertTrue(view.trackingAreas.isEmpty)
    }

    func testNativeDragPayloadContainsDecodableImageBytesWithoutClipboardMutation() throws {
        let view = makeHighlightView()
        view.selectedSubjects = [1]
        let clipboardChangeCount = NSPasteboard.general.changeCount
        let cutout = try XCTUnwrap(view.copyHighlightedSubjects())
        let item = try XCTUnwrap(view.makeDragPasteboardItem(for: cutout))
        let png = try XCTUnwrap(item.data(forType: .png))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(decoded.pixelsWide, 100)
        XCTAssertEqual(decoded.pixelsHigh, 100)
        XCTAssertTrue(decoded.hasAlpha)
        XCTAssertNotNil(item.data(forType: .tiff))
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboardChangeCount)
    }

    private func makeTwoSubjectView() -> SubjectHighlightView {
        makeHighlightView(rectangles: [CGRect(x: 0, y: 0, width: 0.4, height: 1),
                                       CGRect(x: 0.6, y: 0, width: 0.4, height: 1)])
    }
    private func makeHighlightView(frame: NSRect = NSRect(x: 0, y: 0, width: 100, height: 100),
                                   includePaths: Bool = true,
                                   rectangles: [CGRect] = [CGRect(x: 0, y: 0, width: 1, height: 1)]) -> SubjectHighlightView {
        let view = SubjectHighlightView(frame: frame)
        let image = createMask(width: 100, height: 100)
        view.image = NSImage(cgImage: image, size: NSSize(width: 100, height: 100))
        view.isolationResult = makeResult(paths: rectangles.map { rect in
            guard includePaths else { return nil }
            return CGPath(rect: rect, transform: nil)
        })
        view.layout()
        return view
    }
    private func makeResult(paths: [CGPath?]) -> IsolationResult {
        IsolationResult(subjects: paths.enumerated().map { offset, path in
            SubjectInstance(index: offset + 1, mask: createMask(width: 100, height: 100),
                            boundingBox: path?.boundingBoxOfPath ?? .zero,
                            contourPath: path, outerContourPath: path)
        }, foregroundMask: nil, semanticMasks: [:], imageSize: CGSize(width: 100, height: 100))
    }
    private func createMask(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
