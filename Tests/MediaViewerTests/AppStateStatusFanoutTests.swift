import AppKit
import Combine
import SwiftUI
import XCTest
@testable import MediaViewer

@MainActor
final class AppStateStatusFanoutTests: XCTestCase {
    func testQueueBurstDoesNotPublishAppState() async throws {
        let app = AppState()
        var sends = 0
        let subscription = app.objectWillChange.sink { sends += 1 }
        var statusSends = 0
        let statusSubscription = app.backgroundStatus.objectWillChange.sink { statusSends += 1 }
        for value in 1...100 {
            for queue in AppState.BackgroundQueue.allCases {
                app.updateQueueStatus(queue, processing: 1, queued: value)
            }
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        print("STATUS_BURST events=400 appStateSends=\(sends)")
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(statusSends, 1, "The whole burst must display one consistent snapshot")
        let status = app.backgroundStatus
        XCTAssertEqual(status.processingCount, 1)
        XCTAssertEqual(status.queuedCount, 100)
        XCTAssertEqual(status.pipelineProcessingCount, 1)
        XCTAssertEqual(status.pipelineQueuedCount, 100)
        XCTAssertEqual(status.videoUnderstandingProcessingCount, 1)
        XCTAssertEqual(status.videoUnderstandingQueuedCount, 100)
        XCTAssertEqual(status.transcriptionProcessingCount, 1)
        XCTAssertEqual(status.transcriptionQueuedCount, 100)
        XCTAssertEqual(status.overallProcessingCount, 4)
        XCTAssertEqual(status.overallQueuedCount, 400)
        for queue in AppState.BackgroundQueue.allCases {
            app.updateQueueStatus(queue, processing: 1, queued: 100)
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(statusSends, 1, "Repeated counts must not republish the display")
        for queue in AppState.BackgroundQueue.allCases {
            app.updateQueueStatus(queue, processing: 0, queued: 0)
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(statusSends, 2)
        XCTAssertEqual(status.overallProcessingCount, 0)
        XCTAssertEqual(status.overallQueuedCount, 0)
        XCTAssertEqual(status.processingRate, 0)
        XCTAssertEqual(sends, 0)
        withExtendedLifetime((subscription, statusSubscription)) {}
    }

    func testIdenticalQueueEventsDoNotPublishAppState() async throws {
        let app = AppState()
        var sends = 0
        let subscription = app.objectWillChange.sink { sends += 1 }
        for _ in 0..<100 {
            for queue in AppState.BackgroundQueue.allCases {
                app.updateQueueStatus(queue, processing: 0, queued: 0)
            }
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        print("IDENTICAL_STATUS_BURST events=400 appStateSends=\(sends)")
        XCTAssertEqual(sends, 0)
        withExtendedLifetime(subscription) {}
    }

    func testThumbnailProgressBurstDoesNotPublishAppState() async throws {
        let app = AppState()
        var sends = 0
        let subscription = app.objectWillChange.sink { sends += 1 }
        for value in 0...100 {
            app.thumbnailRegenerationProgress = (value, 100)
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        print("THUMBNAIL_BURST events=101 appStateSends=\(sends)")
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(app.backgroundStatus.thumbnailRegenerationProgress?.completed, 100)
        XCTAssertEqual(app.backgroundStatus.thumbnailRegenerationProgress?.total, 100)
        app.thumbnailRegenerationProgress = nil
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertNil(app.backgroundStatus.thumbnailRegenerationProgress)
        XCTAssertEqual(sends, 0)
        withExtendedLifetime(subscription) {}
    }

    func testDisplayUpdatesAreLimitedToFourPerSecond() async throws {
        let app = AppState()
        var updates: [Date] = []
        let subscription = app.backgroundStatus.objectWillChange.sink { updates.append(Date()) }
        for value in 1...24 {
            app.updateQueueStatus(.vision, processing: 1, queued: value)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertGreaterThanOrEqual(updates.count, 2)
        let intervals = zip(updates, updates.dropFirst()).map { $1.timeIntervalSince($0) }
        for interval in intervals {
            XCTAssertGreaterThanOrEqual(interval, 0.24)
        }
        XCTAssertEqual(app.backgroundStatus.queuedCount, 24, "The trailing value must be displayed")
        print("DISPLAY_CADENCE events=24 displaySends=\(updates.count) minimumGap=\(intervals.min() ?? 0)")
        withExtendedLifetime(subscription) {}
    }

    func testGridEqualityIncludesEveryRenderingInput() {
        let model = MasonryGridViewModel()
        func grid(
            model: MasonryGridViewModel,
            hybrid: Bool = false,
            colors: Bool = false,
            backgrounded: Bool = false,
            interaction: Bool = true,
            scroll: LibraryScrollRequest = LibraryScrollRequest()
        ) -> MasonryGrid {
            MasonryGrid(
                viewModel: model,
                useHybridLayout: hybrid,
                showColorBars: colors,
                isBackgrounded: backgrounded,
                allowsViewportInteraction: interaction,
                onItemSelected: { _ in },
                onItemDoubleClicked: { _ in },
                onShowContextMenu: nil,
                onLoadMore: nil,
                libraryScrollRequest: scroll
            )
        }
        let original = grid(model: model)
        XCTAssertEqual(original, grid(model: model))
        XCTAssertNotEqual(original, grid(model: MasonryGridViewModel()))
        XCTAssertNotEqual(original, grid(model: model, hybrid: true))
        XCTAssertNotEqual(original, grid(model: model, colors: true))
        XCTAssertNotEqual(original, grid(model: model, backgrounded: true))
        XCTAssertNotEqual(original, grid(model: model, interaction: false))
        var request = LibraryScrollRequest()
        request.issue(.top)
        XCTAssertNotEqual(original, grid(model: model, scroll: request))
        var callbacksChanged = original
        callbacksChanged.onColorClicked = { _ in }
        XCTAssertEqual(original, callbacksChanged)
    }

    #if DEBUG
    func testUnrelatedAppPublishesDoNotEvaluateGridBody() async throws {
        let app = AppState()
        let viewModel = MasonryGridViewModel()
        viewModel.setItems([])
        var evaluations = 0
        MasonryGrid.bodyEvaluationObserver = { evaluations += 1 }
        defer { MasonryGrid.bodyEvaluationObserver = nil }
        let host = NSHostingView(rootView: FanoutGridHost(app: app, viewModel: viewModel))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        // Pump offscreen layout and let width/pagination setup settle before measuring fan-out.
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(evaluations, 0, "The offscreen host must evaluate the grid")
        // Prime SwiftUI's first @self replacement after the initial model/layout invalidations.
        let beforeReplacement = evaluations
        app.showKeyboardShortcutsHelp = true
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        print("GRID_INITIAL_REPLACEMENT bodyEvaluations=\(evaluations - beforeReplacement)")
        let initial = evaluations
        for index in 0..<10 {
            app.showKeyboardShortcutsHelp = !index.isMultiple(of: 2)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        print("GRID_FANOUT publishes=10 bodyEvaluations=\(evaluations - initial)")
        XCTAssertEqual(evaluations, initial)
        app.showCommandPalette = true
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(evaluations, initial, "Viewport interaction must still update")
        let beforeModelChange = evaluations
        viewModel.density = 0.8
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(evaluations, beforeModelChange, "Direct model observation must bypass equality")
        withExtendedLifetime(host) {}
    }
    #endif
}

private struct FanoutGridHost: View {
    @ObservedObject var app: AppState
    let viewModel: MasonryGridViewModel

    var body: some View {
        MasonryGrid(
            viewModel: viewModel,
            useHybridLayout: app.useHybridLayout,
            showColorBars: app.showColorBars,
            isBackgrounded: app.isShowingSingleFocus,
            allowsViewportInteraction: !app.showCommandPalette,
            onItemSelected: { app.selectedItemID = $0.id },
            onItemDoubleClicked: { app.openSingleFocus($0) },
            onShowContextMenu: nil,
            onLoadMore: nil,
            libraryScrollRequest: app.libraryScrollRequest
        )
        .equatable()
    }
}
