import Foundation
import AppKit
import Combine
import XCTest
@testable import MediaViewer

@MainActor
private final class DelayedGridObservationProvider {
    private typealias Continuation = CheckedContinuation<AnyPublisher<[MediaItem], Error>, Error>

    private var continuations: [Int: Continuation] = [:]
    private(set) var requestedOffsets: [Int] = []

    func publisher(offset: Int) async throws -> AnyPublisher<[MediaItem], Error> {
        requestedOffsets.append(offset)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[offset] = continuation
        }
    }

    func resolve(offset: Int, items: [MediaItem]) {
        guard let continuation = continuations.removeValue(forKey: offset) else {
            preconditionFailure("No pending observation for offset \(offset)")
        }
        continuation.resume(
            returning: Just(items)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        )
    }

    func hasRequest(for offset: Int) -> Bool {
        continuations[offset] != nil
    }
}

@MainActor
final class MasonryGridRefreshTests: XCTestCase {
    func testMiddleScrollTargetBindsToItsEnclosingLibraryScrollView() {
        let library = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 2_000))
        library.documentView = document
        let binder = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        document.addSubview(binder)

        let nestedMediaScroller = NSScrollView(frame: NSRect(x: 10, y: 10, width: 100, height: 100))
        document.addSubview(nestedMediaScroller)

        XCTAssertTrue(
            MiddleMouseScrollTargetPolicy.nearestEnclosingScrollView(from: binder) === library
        )
        XCTAssertFalse(
            MiddleMouseScrollTargetPolicy.nearestEnclosingScrollView(from: binder) === nestedMediaScroller
        )
    }

    func testMiddleClickEntersAutoScrollAndSecondClickStopsIt() {
        let anchor = CGPoint(x: 120, y: 240)
        var machine = MiddleMouseScrollStateMachine(dragThreshold: 6)

        XCTAssertEqual(machine.middleButtonDown(at: anchor), .none)
        XCTAssertEqual(
            machine.middleButtonUp(at: CGPoint(x: 123, y: 242)),
            .startAutoScroll(anchor: anchor)
        )
        XCTAssertEqual(machine.autoScrollAnchor, anchor)

        XCTAssertEqual(machine.middleButtonDown(at: CGPoint(x: 300, y: 300)), .stopAutoScroll)
        XCTAssertTrue(machine.isIdle)
    }

    func testMiddleDragPastThresholdPansAndNeverEntersAutoScroll() {
        let anchor = CGPoint(x: 50, y: 50)
        var machine = MiddleMouseScrollStateMachine(dragThreshold: 6)

        _ = machine.middleButtonDown(at: anchor)
        XCTAssertEqual(
            machine.middleButtonDragged(
                to: CGPoint(x: 53, y: 52),
                eventDeltaX: 3,
                eventDeltaY: 2
            ),
            .none
        )
        XCTAssertEqual(
            machine.middleButtonDragged(
                to: CGPoint(x: 60, y: 58),
                eventDeltaX: 7,
                eventDeltaY: 6
            ),
            .pan(deltaX: -7, deltaY: -6)
        )
        XCTAssertEqual(machine.middleButtonUp(at: CGPoint(x: 60, y: 58)), .endDrag)
        XCTAssertTrue(machine.isIdle)
    }

    func testAutoScrollVelocityHasDeadZoneDirectionAndCap() {
        XCTAssertEqual(MiddleMouseAutoScrollPhysics.verticalVelocity(for: 0), 0)
        XCTAssertEqual(
            MiddleMouseAutoScrollPhysics.verticalVelocity(
                for: MiddleMouseAutoScrollPhysics.deadZone
            ),
            0
        )
        XCTAssertLessThan(MiddleMouseAutoScrollPhysics.verticalVelocity(for: 40), 0)
        XCTAssertGreaterThan(MiddleMouseAutoScrollPhysics.verticalVelocity(for: -40), 0)
        XCTAssertEqual(
            abs(MiddleMouseAutoScrollPhysics.verticalVelocity(for: 10_000)),
            MiddleMouseAutoScrollPhysics.maximumPointsPerSecond
        )

        // A delayed timer tick is capped at 50ms so wake/focus stalls cannot fling the grid.
        XCTAssertEqual(
            MiddleMouseAutoScrollPhysics.contentDelta(
                verticalDisplacement: -10_000,
                elapsed: 1
            ),
            MiddleMouseAutoScrollPhysics.maximumPointsPerSecond * 0.05,
            accuracy: 0.001
        )
    }

    func testDeepScrollPrefetchWindowAccountsForAllColumnsAndStaysBounded() throws {
        let window = try XCTUnwrap(
            MasonryGridPrefetchPolicy.window(
                itemCount: 1_000,
                scrollOffset: -2_000,
                previousScrollOffset: -1_800,
                estimatedRowHeight: 200,
                estimatedVisibleRows: 10,
                columnCount: 5
            )
        )

        // Row 10 in a five-column grid starts around item 50, not item 10.
        XCTAssertEqual(window.prefetchRange, 45..<125)
        XCTAssertEqual(window.activeRange, 30..<120)
        XCTAssertLessThanOrEqual(window.prefetchRange.count, 80)
    }

    func testPrefetchPolicyRejectsEmptyOrInvalidGeometry() {
        XCTAssertNil(
            MasonryGridPrefetchPolicy.window(
                itemCount: 0,
                scrollOffset: 0,
                previousScrollOffset: 0,
                estimatedRowHeight: 200,
                estimatedVisibleRows: 10,
                columnCount: 5
            )
        )
        XCTAssertNil(
            MasonryGridPrefetchPolicy.window(
                itemCount: 100,
                scrollOffset: .nan,
                previousScrollOffset: 0,
                estimatedRowHeight: 200,
                estimatedVisibleRows: 10,
                columnCount: 5
            )
        )
    }

    func testCancellingPressedMiddleGestureDoesNotStartAutoScrollOnMouseUp() {
        var machine = MiddleMouseScrollStateMachine()
        _ = machine.middleButtonDown(at: CGPoint(x: 10, y: 10))

        XCTAssertEqual(machine.cancel(), .endDrag)
        XCTAssertEqual(machine.middleButtonUp(at: CGPoint(x: 10, y: 10)), .none)
        XCTAssertTrue(machine.isIdle)
    }

    func testLocalStarMutationUpdatesOneItemAndPreservesGridState() {
        let vm = MasonryGridViewModel()
        let items = [makeItem(starred: false), makeItem(starred: false), makeItem(starred: true)]
        vm.setItems(items)
        vm.setColumnCount(2)
        vm.select(items[1].id)

        let originalIDs = vm.items.map(\.id)
        let originalOffset = vm.currentOffset
        let originalSelection = vm.selectedIDs

        let outcome = vm.applyLocalStarMutation(
            id: items[0].id,
            starred: true,
            activeStarredFilter: nil
        )

        guard case .updated(let updatedItem) = outcome else {
            return XCTFail("Expected an in-place update")
        }
        XCTAssertTrue(updatedItem.metadata.starred)
        XCTAssertEqual(vm.items.map(\.id), originalIDs)
        XCTAssertEqual(vm.items.first(where: { $0.id == items[0].id })?.metadata.starred, true)
        XCTAssertEqual(vm.currentOffset, originalOffset)
        XCTAssertEqual(vm.selectedIDs, originalSelection)
    }

    func testLocalStarMutationRemovesOnlyItemThatLeavesStarredFilter() {
        let vm = MasonryGridViewModel()
        let target = makeItem(starred: true)
        let survivor = makeItem(starred: true)
        vm.setItems([target, survivor])
        vm.select(survivor.id)
        vm.toggleSelection(target.id)

        let outcome = vm.applyLocalStarMutation(
            id: target.id,
            starred: false,
            activeStarredFilter: true
        )

        guard case .removed = outcome else {
            return XCTFail("Expected the filtered item to be removed locally")
        }
        XCTAssertEqual(vm.items.map(\.id), [survivor.id])
        XCTAssertEqual(vm.selectedIDs, Set([survivor.id]))
        XCTAssertNil(vm.items.first(where: { $0.id == target.id }))
    }

    func testLocalStoreChangeSuppressionConsumesOnlyExpectedEvent() {
        let vm = MasonryGridViewModel()
        let item = makeItem()
        vm.setItems([item])

        XCTAssertTrue(vm.beginLocalStarMutation(for: item.id))
        XCTAssertTrue(vm.consumePendingLocalStoreChange())
        XCTAssertFalse(vm.consumePendingLocalStoreChange())

        // A later event is external and must remain reload-authoritative.
        XCTAssertFalse(vm.consumePendingLocalStoreChange())
    }

    func testCancelledReloadCallerCannotCancelCoalescedTrailingOperation() async {
        let vm = MasonryGridViewModel()
        var invocationCount = 0
        var completedCount = 0
        var firstOperationContinuation: CheckedContinuation<Void, Never>?

        let operation: @MainActor () async -> Void = {
            invocationCount += 1
            if invocationCount == 1 {
                await withCheckedContinuation { continuation in
                    firstOperationContinuation = continuation
                }
            }
            XCTAssertFalse(Task.isCancelled, "Admitted reload work must not inherit scheduler cancellation")
            completedCount += 1
        }

        let firstRequest = Task { @MainActor in
            await vm.performCoalescedReload(operation)
        }
        let startedFirstOperation = await waitUntil { invocationCount == 1 }
        XCTAssertTrue(startedFirstOperation)

        // A filter change supersedes its scheduler task while the database load
        // is suspended, then enqueues one trailing refresh on the same model.
        firstRequest.cancel()
        let trailingRequest = Task { @MainActor in
            await vm.performCoalescedReload(operation)
        }
        await trailingRequest.value
        firstOperationContinuation?.resume()
        await firstRequest.value

        XCTAssertEqual(invocationCount, 2)
        XCTAssertEqual(completedCount, 2)
    }

    func testLocalStarMutationDoesNotRegisterForMissingItem() {
        let vm = MasonryGridViewModel()

        XCTAssertFalse(vm.beginLocalStarMutation(for: UUID()))
        XCTAssertFalse(vm.consumePendingLocalStoreChange())
    }

    func testBatchDeleteSelectsNextSurvivingLoadedItem() {
        let vm = MasonryGridViewModel()
        let items = (0..<5).map { _ in makeItem() }
        vm.setItems(items)
        vm.select(items[1].id)
        vm.toggleSelection(items[2].id)

        let survivor = vm.removeItems(
            Set([items[1].id, items[2].id]),
            selectingSurvivor: true
        )

        XCTAssertEqual(survivor, items[3].id)
        XCTAssertEqual(vm.selectedIDs, Set([items[3].id]))
        XCTAssertEqual(vm.selectionAnchor, items[3].id)
        XCTAssertEqual(vm.items.map(\.id), [items[0].id, items[3].id, items[4].id])
    }

    func testBatchDeleteAtEndFallsBackToPreviousSurvivorWithoutWrapping() {
        let vm = MasonryGridViewModel()
        let items = (0..<5).map { _ in makeItem() }
        vm.setItems(items)
        vm.select(items[3].id)
        vm.toggleSelection(items[4].id)

        let survivor = vm.removeItems(
            Set([items[3].id, items[4].id]),
            selectingSurvivor: true
        )

        XCTAssertEqual(survivor, items[2].id)
        XCTAssertEqual(vm.selectedIDs, Set([items[2].id]))
    }

    func testBatchDeleteAllLoadedItemsClearsSelection() {
        let vm = MasonryGridViewModel()
        let items = (0..<3).map { _ in makeItem() }
        vm.setItems(items)
        vm.select(items[0].id)
        vm.toggleSelection(items[1].id)
        vm.toggleSelection(items[2].id)

        let survivor = vm.removeItems(Set(items.map(\.id)), selectingSurvivor: true)

        XCTAssertNil(survivor)
        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertTrue(vm.selectedIDs.isEmpty)
        XCTAssertNil(vm.selectionAnchor)
    }

    func testNewerObservationWinsWhenOlderPublisherConstructionFinishesLast() async {
        let provider = DelayedGridObservationProvider()
        let vm = MasonryGridViewModel { offset, _, _ in
            try await provider.publisher(offset: offset)
        }
        let loaded = (0..<80).map { _ in makeItem() }
        vm.setItems(loaded)

        vm.updateObservation(newOffset: 0, force: true)
        let requestedFirstWindow = await waitUntil { provider.hasRequest(for: 0) }
        XCTAssertTrue(requestedFirstWindow)

        vm.updateObservation(newOffset: 30, force: true)
        let requestedSecondWindow = await waitUntil { provider.hasRequest(for: 30) }
        XCTAssertTrue(requestedSecondWindow)

        var current = loaded[30]
        current.metadata.starred = true
        provider.resolve(offset: 30, items: [current])
        let acceptedSecondWindow = await waitUntil { vm.windowedItems.first?.id == current.id }
        XCTAssertTrue(acceptedSecondWindow)
        XCTAssertTrue(vm.items[30].metadata.starred)

        var stale = loaded[0]
        stale.metadata.starred = true
        provider.resolve(offset: 0, items: [stale])
        await yieldMainActor()

        XCTAssertEqual(vm.windowedItems.map(\.id), [current.id])
        XCTAssertFalse(vm.items[0].metadata.starred)
        XCTAssertTrue(vm.items[30].metadata.starred)
    }

    func testCancelObservationRejectsLaterPublisherValues() async {
        let loaded = (0..<12).map { _ in makeItem() }
        var firstUpdate = loaded[3]
        firstUpdate.metadata.starred = true
        let subject = CurrentValueSubject<[MediaItem], Error>([firstUpdate])
        let vm = MasonryGridViewModel { _, _, _ in subject.eraseToAnyPublisher() }
        vm.setItems(loaded)

        vm.updateObservation(newOffset: 3, force: true)
        let acceptedFirstUpdate = await waitUntil { vm.windowedItems.first?.id == firstUpdate.id }
        XCTAssertTrue(acceptedFirstUpdate)
        vm.cancelObservation()

        var rejectedUpdate = loaded[4]
        rejectedUpdate.metadata.starred = true
        subject.send([rejectedUpdate])
        await yieldMainActor()

        XCTAssertFalse(vm.isObservationActive)
        XCTAssertEqual(vm.windowedItems.map(\.id), [firstUpdate.id])
        XCTAssertFalse(vm.items[4].metadata.starred)
    }

    func testObservedOffsetWindowPreservesLoadedPrefixSuffixSelectionAndLayout() async {
        let loaded = (0..<12).map { _ in makeItem() }
        var updates = Array(loaded[4...6])
        for index in updates.indices {
            updates[index].metadata.starred = true
        }
        let vm = MasonryGridViewModel { _, _, _ in
            Just(updates)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        vm.setItems(loaded)
        vm.setColumnCount(3)
        vm.select(loaded[10].id)

        vm.updateObservation(newOffset: 4, force: true)
        let acceptedWindow = await waitUntil { vm.windowedItems.map(\.id) == updates.map(\.id) }
        XCTAssertTrue(acceptedWindow)

        XCTAssertEqual(vm.items.count, loaded.count)
        XCTAssertEqual(vm.items[0..<4].map(\.id), loaded[0..<4].map(\.id))
        XCTAssertEqual(vm.items[4...6].map(\.id), updates.map(\.id))
        XCTAssertTrue(vm.items[4...6].allSatisfy(\.metadata.starred))
        XCTAssertEqual(vm.items[7...].map(\.id), loaded[7...].map(\.id))
        XCTAssertEqual(vm.selectedIDs, Set([loaded[10].id]))
        XCTAssertEqual(Set(vm.columns.flatMap { $0.map(\.id) }), Set(loaded.map(\.id)))
        XCTAssertEqual(vm.currentOffset, loaded.count)
    }

    func testPartialObservedWindowDoesNotDeleteUnobservedSuffix() {
        let loaded = (0..<10).map { _ in makeItem() }
        var updates = Array(loaded[4...5])
        updates[0].metadata.starred = true
        updates[1].metadata.starred = true

        let merged = MasonryGridViewModel.mergingObservedWindow(updates, at: 4, into: loaded)

        XCTAssertEqual(merged.count, loaded.count)
        XCTAssertEqual(merged[0..<4].map(\.id), loaded[0..<4].map(\.id))
        XCTAssertTrue(merged[4...5].allSatisfy(\.metadata.starred))
        XCTAssertEqual(merged[6...].map(\.id), loaded[6...].map(\.id))
    }

    func testOutOfRangeObservedWindowOnlyUpdatesAlreadyLoadedIdentity() {
        let loaded = (0..<5).map { _ in makeItem() }
        var knownUpdate = loaded[2]
        knownUpdate.metadata.starred = true
        let unknown = makeItem(starred: true)

        let merged = MasonryGridViewModel.mergingObservedWindow(
            [knownUpdate, unknown],
            at: 20,
            into: loaded
        )

        XCTAssertEqual(merged.map(\.id), loaded.map(\.id))
        XCTAssertTrue(merged[2].metadata.starred)
        XCTAssertFalse(merged.contains { $0.id == unknown.id })
    }

    func testNonzeroObservationCannotInventMissingPrefixForEmptyLibrary() async {
        let observed = [makeItem()]
        let vm = MasonryGridViewModel { _, _, _ in
            Just(observed)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }

        vm.updateObservation(newOffset: 40, force: true)
        let acceptedWindow = await waitUntil { vm.windowedItems == observed }
        XCTAssertTrue(acceptedWindow)

        XCTAssertTrue(vm.items.isEmpty)
        XCTAssertTrue(vm.visibleItems.isEmpty)
    }

    func testStoreReloadKeepsDeepLoadedRangeAndVisibleItem() {
        let vm = MasonryGridViewModel()
        let loaded = (0..<1_200).map { _ in makeItem() }
        XCTAssertEqual(vm.reloadLimit, MasonryGridViewModel.pageSize)
        vm.applyReload(loaded, resetToTop: true)
        vm.shouldScrollToTop = false
        vm.updateScrollPosition(offset: -32_328, viewportHeight: 600)
        vm.select(loaded[1_000].id)
        XCTAssertTrue(vm.visibleItemIDs.contains(loaded[1_000].id))
        XCTAssertEqual(vm.reloadLimit, 1_200)
        vm.applyReload(Array(loaded.prefix(vm.reloadLimit)))
        XCTAssertEqual(vm.currentOffset, 1_200)
        XCTAssertTrue(vm.containsItem(loaded[1_000].id))
        XCTAssertTrue(vm.visibleItemIDs.contains(loaded[1_000].id))
        XCTAssertEqual(vm.currentScrollOffset, -32_328)
        XCTAssertFalse(vm.shouldScrollToTop)
    }

    func testIdenticalItemRefreshPublishesNoColumns() {
        let vm = MasonryGridViewModel()
        let item = makeItem()
        vm.setItems([item])
        var publishes = 0
        let subscription = vm.$columns.dropFirst().sink { _ in publishes += 1 }
        vm.replaceItemIfPresent(item)
        XCTAssertEqual(publishes, 0)
        withExtendedLifetime(subscription) {}
    }

    func testAnalysisOnlyRefreshKeepsCanonicalRecordWithoutPublishingColumns() {
        let vm = MasonryGridViewModel()
        let item = makeItem()
        vm.setItems([item])
        var publishes = 0
        let subscription = vm.$columns.dropFirst().sink { _ in publishes += 1 }
        var updated = item
        updated.pipelineStatus = "complete"
        updated.generatedCaption = "A completed background description"
        vm.replaceItemIfPresent(updated)
        XCTAssertEqual(vm.item(for: item.id)?.pipelineStatus, "complete")
        XCTAssertEqual(publishes, 0)
        withExtendedLifetime(subscription) {}
    }

    func testReplacementOnlyReloadPreservesColumnsPaginationAndObservation() async {
        let loaded = (0..<1_200).map { _ in makeItem() }
        let subject = PassthroughSubject<[MediaItem], Error>()
        let vm = MasonryGridViewModel { _, _, _ in subject.eraseToAnyPublisher() }
        vm.applyReload(loaded, resetToTop: true)
        vm.updateObservation(newOffset: 900, force: true)
        await yieldMainActor()
        let layout = vm.columns.map { $0.map(\.id) }
        var updated = loaded
        updated[1_000].metadata.starred = true
        vm.applyReload(updated)
        XCTAssertEqual(vm.currentOffset, 1_200)
        XCTAssertTrue(vm.isObservationActive)
        XCTAssertEqual(vm.columns.map { $0.map(\.id) }, layout)
        XCTAssertEqual(vm.lastColumnLayoutItemVisitCount, 0)
    }

    func testFrontInsertionIsHeldWhileDeepAndAppliedAtTopOnRequest() {
        let vm = MasonryGridViewModel()
        let loaded = (0..<1_200).map { _ in makeItem() }
        vm.applyReload(loaded, resetToTop: true)
        vm.shouldScrollToTop = false
        vm.updateScrollPosition(offset: -32_328, viewportHeight: 600)
        let visible = vm.topVisibleItemID
        XCTAssertNotNil(visible)
        let inserted = makeItem()
        vm.applyReload([inserted] + loaded.dropLast())
        XCTAssertEqual(vm.pendingNewItemCount, 1)
        XCTAssertEqual(vm.items.map(\.id), loaded.map(\.id))
        XCTAssertEqual(vm.topVisibleItemID, visible)
        XCTAssertEqual(vm.paginationOffset, 1_201)
        vm.applyPendingInsertions()
        XCTAssertEqual(vm.items.first?.id, inserted.id)
        XCTAssertEqual(vm.items.count, 1_201)
        XCTAssertEqual(vm.pendingNewItemCount, 0)
        XCTAssertTrue(vm.shouldScrollToTop)
    }

    func testInsertionAfterLastVisibleTileAppliesImmediately() {
        let vm = MasonryGridViewModel()
        let loaded = (0..<1_200).map { _ in makeItem() }
        vm.applyReload(loaded, resetToTop: true)
        vm.updateScrollPosition(offset: -10_000, viewportHeight: 600)
        let visible = vm.topVisibleItemID
        let inserted = makeItem()
        vm.applyReload(Array(loaded.prefix(1_100)) + [inserted] + loaded[1_100...])
        XCTAssertEqual(vm.pendingNewItemCount, 0)
        XCTAssertTrue(vm.containsItem(inserted.id))
        XCTAssertEqual(vm.topVisibleItemID, visible)
        XCTAssertNil(vm.scrollAnchorToRestore)
    }

    func testInsertionAtTopAppliesImmediatelyAndQueryResetUsesFirstPage() {
        let vm = MasonryGridViewModel()
        let loaded = (0..<1_200).map { _ in makeItem() }
        vm.applyReload(loaded, resetToTop: true)
        let inserted = makeItem()
        vm.applyReload([inserted] + loaded)
        XCTAssertEqual(vm.items.first?.id, inserted.id)
        XCTAssertEqual(vm.pendingNewItemCount, 0)
        for _ in ["filter", "sort", "search"] {
            vm.prepareReload(resetToTop: true)
            XCTAssertEqual(vm.reloadLimit, MasonryGridViewModel.pageSize)
            vm.applyReload(Array(loaded.prefix(vm.reloadLimit)), resetToTop: vm.reloadStartsAtTop)
            XCTAssertEqual(vm.items.count, MasonryGridViewModel.pageSize)
            XCTAssertTrue(vm.shouldScrollToTop)
        }
    }

    func testCoalescedItemRefreshFetchesAndPublishesOnce() async throws {
        let vm = MasonryGridViewModel()
        let loaded = (0..<2_000).map { _ in makeItem() }
        vm.applyReload(loaded, resetToTop: true)
        var fetches = 0
        var publishes = 0
        let subscription = vm.$columns.dropFirst().sink { _ in publishes += 1 }
        for item in loaded.prefix(50) {
            vm.enqueueItemRefresh([item.id], fetch: { ids in
                fetches += 1
                XCTAssertEqual(ids.count, 50)
                return loaded.filter { ids.contains($0.id) }.map { item in
                    var updated = item
                    updated.metadata.starred = true
                    return updated
                }
            }, apply: { records, missing in
                XCTAssertTrue(missing.isEmpty)
                vm.replaceItemsIfPresent(records)
            }, onFailure: { XCTFail("Unexpected fetch failure") })
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(vm.items.count, 2_000)
        XCTAssertEqual(vm.items.prefix(50).filter { $0.metadata.starred }.count, 50)
        withExtendedLifetime(subscription) {}
    }

    func testQueryResetCancelsPendingJobRefresh() async throws {
        let vm = MasonryGridViewModel()
        let item = makeItem()
        vm.applyReload([item], resetToTop: true)
        var fetches = 0
        vm.enqueueItemRefresh([item.id], fetch: { _ in fetches += 1; return [] },
                              apply: { _, _ in XCTFail("Stale refresh applied") },
                              onFailure: { XCTFail("Cancelled refresh failed") })
        vm.prepareReload(resetToTop: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fetches, 0)
    }

    func testDeletingHeldInsertionDoesNotResurrectIt() {
        let vm = MasonryGridViewModel()
        let loaded = (0..<1_200).map { _ in makeItem() }
        vm.applyReload(loaded, resetToTop: true)
        vm.updateScrollPosition(offset: -32_328, viewportHeight: 600)
        let inserted = makeItem()
        vm.applyReload([inserted] + loaded.dropLast())
        vm.removeItems([inserted.id])
        XCTAssertEqual(vm.pendingNewItemCount, 0)
        vm.applyPendingInsertions()
        XCTAssertFalse(vm.containsItem(inserted.id))
        XCTAssertEqual(vm.items.count, 1_200)
    }

    func testReturningToTopAppliesHeldInsertions() {
        let vm = MasonryGridViewModel()
        let loaded = (0..<1_200).map { _ in makeItem() }
        vm.applyReload(loaded, resetToTop: true)
        vm.updateScrollPosition(offset: -32_328, viewportHeight: 600)
        let inserted = makeItem()
        vm.applyReload([inserted] + loaded.dropLast())
        vm.updateScrollPosition(offset: 0, viewportHeight: 600)
        XCTAssertEqual(vm.items.first?.id, inserted.id)
        XCTAssertEqual(vm.pendingNewItemCount, 0)
    }

    func testRefreshingHeldInsertionAppliesLatestTileWhenAccepted() {
        let vm = MasonryGridViewModel()
        let loaded = (0..<1_200).map { _ in makeItem() }
        vm.applyReload(loaded, resetToTop: true)
        vm.updateScrollPosition(offset: -32_328, viewportHeight: 600)
        var inserted = makeItem()
        vm.applyReload([inserted] + loaded.dropLast())
        inserted.metadata.starred = true
        vm.replacePendingItems([inserted])
        vm.applyPendingInsertions()
        XCTAssertEqual(vm.items.first?.metadata.starred, true)
    }

    func testGroupedRowsHoldInsertionsWhileScrolled() {
        let vm = MasonryGridViewModel()
        let loaded = (0..<1_200).map { _ in makeItem() }
        vm.applyReload(loaded, resetToTop: true)
        vm.groupsSimilarAspectRatios = true
        vm.updateScrollPosition(offset: -10_000, viewportHeight: 600)
        let inserted = makeItem()
        vm.applyReload(loaded + [inserted])
        XCTAssertEqual(vm.pendingNewItemCount, 1)
        XCTAssertFalse(vm.containsItem(inserted.id))
        vm.applyPendingInsertions()
        XCTAssertTrue(vm.containsItem(inserted.id))
    }

    func testSharedStoreAnalysisRefreshDoesNotPublishGridChanges() {
        let store = MediaSelectionStore()
        let vm = MasonryGridViewModel()
        vm.setSelectionStore(store)
        let item = makeItem()
        vm.setItems([item])
        var changes = 0
        let subscription = vm.objectWillChange.sink { changes += 1 }
        var updated = item
        updated.generatedCaption = "Analysis finished"
        updated.pipelineStatus = "complete"
        store.replaceRecords([updated])
        XCTAssertEqual(vm.item(for: item.id)?.generatedCaption, "Analysis finished")
        XCTAssertEqual(changes, 0)
        withExtendedLifetime(subscription) {}
    }

    func testDeletingAboveViewportRestoresSurvivingVisibleAnchor() {
        let vm = MasonryGridViewModel()
        let loaded = (0..<1_200).map { _ in makeItem() }
        vm.applyReload(loaded, resetToTop: true)
        vm.updateScrollPosition(offset: -32_328, viewportHeight: 600)
        let anchor = vm.topVisibleItemID
        XCTAssertNotNil(anchor)
        vm.removeItems(Set(loaded.prefix(100).map(\.id)))
        XCTAssertEqual(vm.items.count, 1_100)
        XCTAssertTrue(anchor.map(vm.containsItem) ?? false)
        XCTAssertEqual(vm.scrollAnchorToRestore, anchor)
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    private func yieldMainActor() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }

    private func makeItem(starred: Bool = false) -> MediaItem {
        let id = UUID()
        let basePath = URL(fileURLWithPath: "/archive/2025-01")
        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("\(id.uuidString).md"),
            mediaFiles: [basePath.appendingPathComponent("\(id.uuidString).jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/\(id)")!,
                platform: "test",
                starred: starred
            ),
            aspectRatio: 1.0
        )
    }
}
