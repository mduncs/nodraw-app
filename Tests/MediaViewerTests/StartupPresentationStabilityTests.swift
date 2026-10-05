import AppKit
import SwiftUI
import XCTest
@testable import MediaViewer

@MainActor
final class StartupPresentationStabilityTests: XCTestCase {
    func testLibrarySurvivesScanWatcherProcessingAndReadyWithoutRecreation() async throws {
        let state = PhaseState()
        let probe = LifetimeProbe()
        let host = NSHostingView(rootView: PhaseHarness(state: state, probe: probe))
        let window = makeWindow()
        window.contentView = host
        defer { window.contentView = nil }

        for phase in [InitializationPhase.scanningArchive(progress: 0),
                      .scanningArchive(progress: 0.6), .startingWatcher,
                      .processingItems(current: 1, total: 2), .ready] {
            state.phase = phase
            try await settle(host)
            XCTAssertEqual(probe.created, 1, "Library recreated at \(phase)")
            XCTAssertEqual(probe.dismantled, 0, "Library removed at \(phase)")
            XCTAssertFalse(window.isVisible)
        }
    }

    func testDatabasePreparationDoesNotMountLibraryAndFailureCanRetry() async throws {
        let state = PhaseState()
        state.phase = .initializingDatabase
        let probe = LifetimeProbe()
        let host = NSHostingView(rootView: PhaseHarness(state: state, probe: probe))
        let window = makeWindow()
        window.contentView = host
        defer { window.contentView = nil }

        try await settle(host)
        XCTAssertEqual(probe.created, 0, "No library queries before database preparation")
        state.phase = .scanningArchive(progress: 0)
        try await settle(host)
        XCTAssertEqual(probe.created, 1)
        state.phase = .failed("Isolated test failure")
        try await settle(host)
        XCTAssertEqual(probe.dismantled, 1)
        state.phase = .initializingDatabase
        try await settle(host)
        XCTAssertEqual(probe.created, 1)
        state.phase = .ready
        try await settle(host)
        XCTAssertEqual(probe.created, 2, "Retry should mount a fresh library")
        XCTAssertFalse(window.isVisible)
    }

    func testAutosaveAttachesBeforePresentationAndDoesNotResetUserResize() {
        let name = "NoDraw-startup-test-\(UUID().uuidString)"
        defer { NSWindow.removeFrame(usingName: name) }
        let window = makeWindow()
        let bridge = MainWindowFrameRestorationView()
        bridge.autosaveName = name
        window.contentView = bridge

        XCTAssertEqual(window.frameAutosaveName, name)
        XCTAssertFalse(window.isVisible)
        let resized = NSRect(x: 80, y: 90, width: 880, height: 620)
        window.setFrame(resized, display: false)
        // A SwiftUI reattachment must not reapply launch geometry.
        bridge.viewDidMoveToWindow()
        XCTAssertEqual(window.frame, resized)
        XCTAssertFalse(window.isVisible)
        window.contentView = nil
        window.setFrameAutosaveName("")
    }

    func testExistingSavedFrameWinsOverFirstLaunchDefaultBeforeWindowIsVisible() {
        let name = "NoDraw-startup-test-\(UUID().uuidString)"
        defer { NSWindow.removeFrame(usingName: name) }
        let savedWindow = makeWindow()
        savedWindow.setFrame(NSRect(x: 70, y: 80, width: 900, height: 650), display: false)
        savedWindow.saveFrame(usingName: name)

        // Use AppKit's own restoration as the expected result, including its
        // screen-bound adjustment. The production bridge must do this early.
        let expectedWindow = makeWindow()
        XCTAssertTrue(expectedWindow.setFrameUsingName(name))
        let window = makeWindow()
        let bridge = MainWindowFrameRestorationView()
        bridge.autosaveName = name
        window.contentView = bridge
        XCTAssertEqual(window.frame, expectedWindow.frame)
        XCTAssertFalse(window.isVisible)
        window.contentView = nil
        window.setFrameAutosaveName("")
    }

    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    }

    private func settle<V: View>(_ host: NSHostingView<V>) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class PhaseState: ObservableObject {
    @Published var phase: InitializationPhase = .scanningArchive(progress: 0)
}

private struct PhaseHarness: View {
    @ObservedObject var state: PhaseState
    let probe: LifetimeProbe

    var body: some View {
        StartupContentView(phase: state.phase, onRetry: {}) {
            LibraryProbe(probe: probe)
        }
    }
}

@MainActor
private final class LifetimeProbe {
    var created = 0
    var dismantled = 0
}

private struct LibraryProbe: NSViewRepresentable {
    let probe: LifetimeProbe

    func makeCoordinator() -> LifetimeProbe { probe }

    func makeNSView(context: Context) -> NSView {
        probe.created += 1
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: LifetimeProbe) {
        coordinator.dismantled += 1
    }
}
