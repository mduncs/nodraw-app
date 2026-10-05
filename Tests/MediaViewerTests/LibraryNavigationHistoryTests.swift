import XCTest
@testable import MediaViewer

final class LibraryNavigationHistoryTests: XCTestCase {
    private struct State: Equatable {
        var destination = "All Media"
        var search = ""
        var filter = ""
        var detailID: Int?
        var selection: Int?
        var scrollAnchor: Int?
        // Presentation is deliberately not part of navigation state.
    }

    func testFolderSearchFilterDetailUnwindsOneVisibleTransitionAtATime() {
        var history = LibraryNavigationHistory<State>()
        var state = State(selection: 1, scrollAnchor: 1)

        let allMedia = state
        state.destination = "Folder A"
        state.selection = 20
        state.scrollAnchor = 20
        history.recordTransition(from: allMedia, to: state, kind: .destination)
        let folder = state

        state.search = "cats"
        state.selection = 21
        state.scrollAnchor = 21
        history.stageCoalescedTransition(from: folder, to: state, kind: .search)
        history.commitCoalescedTransition()
        let searchedFolder = state

        state.filter = "starred"
        state.selection = 22
        state.scrollAnchor = 22
        history.recordTransition(from: searchedFolder, to: state, kind: .filter)
        let filteredFolder = state

        state.detailID = 22
        history.recordTransition(from: filteredFolder, to: state, kind: .detail)

        state = tryUnwrap(history.navigateBack()).state
        XCTAssertEqual(state, filteredFolder)
        state = tryUnwrap(history.navigateBack()).state
        XCTAssertEqual(state, searchedFolder)
        state = tryUnwrap(history.navigateBack()).state
        XCTAssertEqual(state, folder)
        state = tryUnwrap(history.navigateBack()).state
        XCTAssertEqual(state, allMedia)
        XCTAssertNil(history.navigateBack(), "Back at the library root is a no-op")
    }

    func testLiveSearchEditsCoalesceAndRevertingToBaselineAddsNoEntry() {
        var history = LibraryNavigationHistory<State>()
        let baseline = State()
        var state = baseline

        for text in ["c", "ca", "cat", "cats"] {
            let previous = state
            state.search = text
            history.stageCoalescedTransition(from: previous, to: state, kind: .search)
        }

        XCTAssertEqual(history.count, 1)
        XCTAssertTrue(history.commitCoalescedTransition())
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.navigateBack()?.state, baseline)

        let previous = state
        state.search = ""
        history.stageCoalescedTransition(from: previous, to: state, kind: .search)
        state.search = "cats"
        history.stageCoalescedTransition(from: State(search: ""), to: state, kind: .search)
        XCTAssertFalse(history.commitCoalescedTransition())
        XCTAssertFalse(history.canNavigateBack)
    }

    func testCommittedTransitionFlushesPendingSearchBeforeRecordingFilter() {
        var history = LibraryNavigationHistory<State>()
        let baseline = State()
        var searched = baseline
        searched.search = "birds"
        history.stageCoalescedTransition(from: baseline, to: searched, kind: .search)

        var filtered = searched
        filtered.filter = "has-text"
        history.recordTransition(from: searched, to: filtered, kind: .filter)

        XCTAssertEqual(history.entries.map(\.transition), [.search, .filter])
        XCTAssertEqual(history.navigateBack()?.state, searched)
        XCTAssertEqual(history.navigateBack()?.state, baseline)
    }

    func testExplicitDetailCloseConsumesOnlyDetailEntry() {
        var history = LibraryNavigationHistory<State>()
        let root = State()
        var folder = root
        folder.destination = "Folder A"
        history.recordTransition(from: root, to: folder, kind: .destination)

        var detail = folder
        detail.detailID = 7
        history.recordTransition(from: folder, to: detail, kind: .detail)

        XCTAssertTrue(history.discardLatestTransition(ifKind: .detail))
        XCTAssertEqual(history.navigateBack()?.state, root)
        XCTAssertFalse(history.canNavigateBack)
    }

    func testFilterStartedFromDetailConsumesDetailBeforeRecordingBrowseChange() {
        var history = LibraryNavigationHistory<State>()
        let browse = State(selection: 7, scrollAnchor: 7)
        var detail = browse
        detail.detailID = 7
        history.recordTransition(from: browse, to: detail, kind: .detail)

        // The eyedropper closes detail synchronously, then commits its color filter.
        XCTAssertTrue(history.discardLatestTransition(ifKind: .detail))
        var filteredBrowse = browse
        filteredBrowse.filter = "precise-color"
        filteredBrowse.selection = nil
        filteredBrowse.scrollAnchor = nil
        history.recordTransition(from: browse, to: filteredBrowse, kind: .filter)

        XCTAssertEqual(history.entries.map(\.transition), [.filter])
        XCTAssertEqual(history.navigateBack()?.state, browse)
        XCTAssertFalse(history.canNavigateBack)
    }

    func testPresentationOnlyChangesDoNotMutateOrReorderHistory() {
        var history = LibraryNavigationHistory<State>()
        let root = State()
        var folder = root
        folder.destination = "Folder A"
        history.recordTransition(from: root, to: folder, kind: .destination)

        // Grid/table switches and window resizing never call the history model.
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.navigateBack()?.state, root)
    }

    func testScrollRequestsAreGenerationStampedForRepeatedTopResets() {
        var request = LibraryScrollRequest()
        request.issue(.top)
        let firstGeneration = request.generation
        request.issue(.top)

        XCTAssertGreaterThan(request.generation, firstGeneration)
        XCTAssertEqual(request.target, .top)
    }

    private func tryUnwrap<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> T {
        guard let value else {
            XCTFail("Expected a value", file: file, line: line)
            fatalError("Unreachable after XCTFail")
        }
        return value
    }
}
