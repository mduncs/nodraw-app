import XCTest
import AppKit
@testable import MediaViewer

@MainActor
final class DuplicateTriageViewModelTests: XCTestCase {
    func testImmediateCaptureKeepsMultipleAndLocksNavigationBeforeAsyncCommit() async throws {
        let first = detail(count: 3)
        let second = detail(count: 2)
        let service = ReviewServiceStub(details: [first, second])
        let model = DuplicateTriageViewModel(detector: ReviewDetectorStub(), service: service, notificationCenter: NotificationCenter())
        await model.loadGroups()
        model.toggleItem(first.items[1].id)
        let request = try XCTUnwrap(model.beginDecision(.keepSelected))
        XCTAssertEqual(request.keptIDs, Set(first.items.prefix(2).map(\.id)))
        XCTAssertEqual(request.rejectedIDs, [first.items[2].id])
        model.skipToNext()
        model.selectItem(2)
        XCTAssertEqual(model.currentGroup?.id, first.snapshot.groupID)
        XCTAssertNil(model.beginDecision(.keepAll))
        await model.perform(request, undoStack: nil)
        let recorded = await service.requests
        XCTAssertEqual(recorded, [request])
        XCTAssertEqual(model.currentGroup?.id, second.snapshot.groupID)
    }

    func testOldFetchCannotPublishUnderNewGroupHeader() async throws {
        let first = detail(count: 2), second = detail(count: 2)
        let service = ReviewServiceStub(details: [first, second])
        await service.hold(first.snapshot.groupID)
        let model = DuplicateTriageViewModel(detector: ReviewDetectorStub(), service: service, notificationCenter: NotificationCenter())
        let loading = Task { await model.loadGroups() }
        await waitUntil { await service.isWaiting(first.snapshot.groupID) }
        model.skipToNext()
        await waitUntil { await MainActor.run { model.snapshot?.groupID == second.snapshot.groupID } }
        XCTAssertEqual(model.items.map(\.id), second.items.map(\.id))
        await service.release(first.snapshot.groupID)
        await loading.value
        XCTAssertEqual(model.currentGroup?.id, second.snapshot.groupID)
        XCTAssertEqual(model.items.map(\.id), second.items.map(\.id))
    }

    func testFailureRemainsVisibleAndDoesNotAdvanceOrRegisterUndo() async throws {
        let first = detail(count: 2)
        let service = ReviewServiceStub(details: [first])
        await service.failNextApply()
        let model = DuplicateTriageViewModel(detector: ReviewDetectorStub(), service: service, notificationCenter: NotificationCenter())
        let undo = UndoStack()
        await model.loadGroups()
        let request = try XCTUnwrap(model.beginDecision(.keepSelected))
        await model.perform(request, undoStack: undo)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.currentGroup?.id, first.snapshot.groupID)
        XCTAssertFalse(model.isApplying)
        XCTAssertFalse(undo.canUndo)
    }

    func testLaterAndKeepAllCaptureAllMembersWithoutRejectedItems() async throws {
        for decision in [TriageDecision.later, .keepAll, .notDuplicates] {
            let first = detail(count: 3)
            let model = DuplicateTriageViewModel(detector: ReviewDetectorStub(), service: ReviewServiceStub(details: [first]), notificationCenter: NotificationCenter())
            await model.loadGroups()
            let request = try XCTUnwrap(model.beginDecision(decision))
            XCTAssertEqual(request.keptIDs, Set(first.snapshot.itemIDs))
            XCTAssertTrue(request.rejectedIDs.isEmpty)
        }
    }

    func testModifiedAndRepeatedDecisionKeysDoNotInvokeTriage() {
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            XCTAssertFalse(DuplicateTriageKeyPolicy.accepts(keyCode: 36, modifiers: modifier, isRepeat: false))
        }
        for key: UInt16 in [36, 49, 2, 37] {
            XCTAssertFalse(DuplicateTriageKeyPolicy.accepts(keyCode: key, modifiers: [], isRepeat: true))
            XCTAssertTrue(DuplicateTriageKeyPolicy.accepts(keyCode: key, modifiers: [], isRepeat: false))
        }
        XCTAssertTrue(DuplicateTriageKeyPolicy.accepts(keyCode: 124, modifiers: [], isRepeat: true))
    }

    func testUndoActionActuallyReexecutesUsingInjectedService() async throws {
        let service = ReviewServiceStub(details: [])
        let id = UUID()
        let action = DuplicateTriageUndoAction(operationID: id, description: "fixture", service: service)
        try await action.undo()
        try await action.execute()
        let undoIDs = await service.undoneIDs, redoIDs = await service.redoneIDs
        XCTAssertEqual(undoIDs, [id]); XCTAssertEqual(redoIDs, [id])
    }

    func testEmptyStateCopyDistinguishesUnscannedSetAsideAndScannedQueues() async {
        let idle = DuplicateTriageViewModel(detector: ReviewDetectorStub(), service: ReviewServiceStub(details: []), notificationCenter: NotificationCenter())
        await idle.loadGroups()
        XCTAssertEqual(idle.emptyStateCopy.title, "No duplicates to review")
        idle.category = .exact
        XCTAssertEqual(idle.emptyStateCopy.title, "No exact copies to review")
        idle.showingLater = true
        XCTAssertEqual(idle.emptyStateCopy.title, "Nothing set aside")

        for (found, title) in [(0, "No duplicates found"),
                               (1, "No duplicates in this queue"),
                               (3, "No duplicates in this queue")] {
            let model = DuplicateTriageViewModel(detector: CompletedDetectorStub(found: found), service: ReviewServiceStub(details: []), notificationCenter: NotificationCenter())
            model.startScan()
            await waitUntil { await MainActor.run { !model.isScanning } }
            XCTAssertEqual(model.emptyStateCopy.title, title)
            let notice = DuplicateDetector.DetectionProgress.complete(groupsFound: found).displayText
                + (found > 0 ? " Earlier review decisions are kept." : "")
            XCTAssertEqual(model.notice, notice)
        }
    }

    func testCompletionKeepsPartialCoverageAndArrivalsInNoticeAndEmptyState() async {
        let completion = DuplicateDetector.DetectionProgress.complete(groupsFound: 0, unavailableItems: 2, changedItems: 3, arrivals: 4)
        let model = DuplicateTriageViewModel(detector: CompletedDetectorStub(found: 0, completion: completion), service: ReviewServiceStub(details: []), notificationCenter: NotificationCenter())
        model.startScan()
        await waitUntil { await MainActor.run { !model.isScanning } }
        XCTAssertEqual(model.scanProgress, completion)
        XCTAssertEqual(model.emptyStateCopy.title, "No duplicates found")
        let details = "2 files couldn't be read. 3 items changed during the scan; their groups were left out. 4 new items arrived; scan again to include them."
        XCTAssertEqual(completion.displayText, "Scan complete: 0 groups to review. " + details)
        XCTAssertEqual(model.notice, completion.displayText)
        XCTAssertEqual(model.emptyStateCopy.detail,
            "Every exact copy was checked; look-alike matching can miss a few. " + details)
        await model.loadGroups()
        XCTAssertEqual(model.scanProgress, completion, "Reloading an empty review queue must not erase scan coverage")
    }

    func testFullCoverageEmptyCopyStillExplainsBoundedVisualMatching() async {
        let model = DuplicateTriageViewModel(detector: CompletedDetectorStub(found: 0), service: ReviewServiceStub(details: []), notificationCenter: NotificationCenter())
        model.startScan()
        await waitUntil { await MainActor.run { !model.isScanning } }
        XCTAssertEqual(model.emptyStateCopy.title, "No duplicates found")
        XCTAssertEqual(model.emptyStateCopy.detail, "Every exact copy was checked; look-alike matching can miss a few.")
        XCTAssertEqual(model.notice, "Scan complete: 0 groups to review.")
        XCTAssertEqual(DuplicateDetector.DetectionProgress.complete(groupsFound: 7).displayText,
            "Scan complete: 7 groups to review.")
        XCTAssertEqual(DuplicateDetector.DetectionProgress.complete(groupsFound: 1, unavailableItems: 2).displayText,
            "Scan complete: 1 groups to review. 2 files couldn't be read.")
        XCTAssertEqual(DuplicateDetector.DetectionProgress.complete(groupsFound: 1, changedItems: 3).displayText,
            "Scan complete: 1 groups to review. 3 items changed during the scan; their groups were left out.")
        XCTAssertEqual(DuplicateDetector.DetectionProgress.complete(groupsFound: 1, arrivals: 4).displayText,
            "Scan complete: 1 groups to review. 4 new items arrived; scan again to include them.")
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<1000 { if await condition() { return }; await Task.yield() }
        XCTFail("Asynchronous fixture did not reach its checkpoint")
    }

    private func detail(count: Int) -> DuplicateReviewDetail {
        let items = (0..<count).map { _ -> MediaItem in
            let id = UUID(), base = URL(fileURLWithPath: "/tmp/review-fake")
            return MediaItem(id: id, basePath: base, metadataFile: base.appendingPathComponent("\(id).md"), mediaFiles: [base.appendingPathComponent("\(id).jpg")], metadata: MediaMetadata(source: URL(string: "https://example.com/\(id)")!, platform: "test"))
        }
        let group = DuplicateGroup(itemIds: items.map(\.id), detectionMethod: .exactDuplicate, similarity: 1)
        return DuplicateReviewDetail(snapshot: DuplicateReviewSnapshot(groupID: group.id, groupUpdatedAt: group.updatedAt, previousStatus: "pending", previousPrimaryID: nil, method: "exactDuplicate", similarity: 1, createdAt: group.createdAt,
            members: items.map { DuplicateReviewMember(id: $0.id, fingerprint: "fixture", annotationCount: 0, boardCount: 0, canvasCount: 0, fileBytes: 10) }, evidenceKey: nil, evidence: nil), items: items)
    }
}

private actor ReviewDetectorStub: DuplicateTriageDetecting {
    func detectDuplicates() async throws -> Int { 0 }
    func cancelDetection() async {}
    func getProgress() async -> DuplicateDetector.DetectionProgress { .idle }
}

private actor CompletedDetectorStub: DuplicateTriageDetecting {
    let found: Int
    let completion: DuplicateDetector.DetectionProgress
    init(found: Int, completion: DuplicateDetector.DetectionProgress? = nil) {
        self.found = found
        self.completion = completion ?? .complete(groupsFound: found)
    }
    func detectDuplicates() async throws -> Int { found }
    func cancelDetection() async {}
    func getProgress() async -> DuplicateDetector.DetectionProgress { completion }
}

private actor ReviewServiceStub: DuplicateReviewServicing {
    var details: [DuplicateReviewDetail]
    var requests: [DuplicateReviewRequest] = []
    var undoneIDs: [UUID] = []
    var redoneIDs: [UUID] = []
    var held = Set<UUID>()
    var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    var shouldFail = false
    init(details: [DuplicateReviewDetail]) { self.details = details }
    func hold(_ id: UUID) { held.insert(id) }
    func isWaiting(_ id: UUID) -> Bool { waiters[id] != nil }
    func release(_ id: UUID) { held.remove(id); waiters.removeValue(forKey: id)?.resume() }
    func failNextApply() { shouldFail = true }
    func fetchGroups(includeLater: Bool, exactOnly: Bool?) async throws -> [DuplicateGroup] { details.map { $0.snapshot.group } }
    func load(groupID: UUID) async throws -> DuplicateReviewDetail {
        let detail = details.first { $0.snapshot.groupID == groupID }!
        if held.contains(groupID) { await withCheckedContinuation { waiters[groupID] = $0 } }
        return detail
    }
    func apply(_ request: DuplicateReviewRequest) async throws {
        if shouldFail { throw DuplicateReviewService.ReviewError.changed }
        requests.append(request)
        details.removeAll { $0.snapshot.groupID == request.snapshot.groupID }
    }
    func undo(_ operationID: UUID) async throws { undoneIDs.append(operationID) }
    func redo(_ operationID: UUID) async throws { redoneIDs.append(operationID) }
    func history() async throws -> [DuplicateReviewHistoryEntry] { [] }
}
