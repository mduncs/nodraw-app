import AppKit
import SwiftUI
import XCTest
@testable import MediaViewer

/// Offscreen evidence captures of library-shell components (timeline, sidebar, cells, batch bar,
/// palette, empty states, smart-folder editor). Windows are never ordered on screen, so this
/// works while the session is locked and never takes focus. Skipped unless
/// `NODRAW_LIBRARY_CAPTURE_DIR` is set; refuses to run unless `NODRAW_APP_SUPPORT_DIR` points at a
/// disposable /tmp fixture. `NODRAW_LIBRARY_CAPTURE_ONLY` limits the run to comma-separated names.
@MainActor
final class LibraryShellEvidenceCaptureTests: XCTestCase {
    private var directory: URL!
    private var only: Set<String>?

    func testCaptureLibraryShellComponents() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outDir = env["NODRAW_LIBRARY_CAPTURE_DIR"] else {
            throw XCTSkip("Set NODRAW_LIBRARY_CAPTURE_DIR to write captures")
        }
        let support = try XCTUnwrap(env["NODRAW_APP_SUPPORT_DIR"], "an isolated fixture support dir is required")
        guard support.hasPrefix("/tmp/") || support.hasPrefix("/private/tmp/") else {
            return XCTFail("fixture must live under /tmp")
        }
        directory = URL(fileURLWithPath: outDir)
        only = env["NODRAW_LIBRARY_CAPTURE_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }

        _ = NSApplication.shared
        let savedDefinitions = TagSettings.shared.definitions
        defer { TagSettings.shared.definitions = savedDefinitions }
        if let tagFile = env["NODRAW_LIBRARY_CAPTURE_TAGDEFS"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: tagFile))
            TagSettings.shared.definitions = try JSONDecoder().decode([TagDefinition].self, from: data)
        }

        try await DatabaseManager.shared.initialize()
        let store = MediaStore(database: DatabaseManager.shared)
        var all = FilterState()
        all.limit = 200
        let items = try await store.fetchItems(filter: all)
        let smartFolders = try await store.fetchSmartFolders()

        try await captureTimelines()
        try captureSidebar(store: store)
        try captureCells(items)
        try captureBatchBar()
        try capturePalette(store: store, items: items)
        try captureEmptyStates(store: store, smartFolders: smartFolders)
        try captureSmartFolderEditor(store: store, smartFolders: smartFolders)
    }

    // MARK: - Surfaces

    private func captureTimelines() async throws {
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let spread = (0..<70).map { now.addingTimeInterval(-Double(($0 * 37) % 420) * day) }
        let cases: [(String, [Date], Bool, Bool)] = [
            ("timeline-single-day", (0..<14).map { now.addingTimeInterval(Double($0) * 60) }, true, false),
            ("timeline-two-months", (0..<14).map { now.addingTimeInterval(-Double($0 * 4) * day) }, true, false),
            ("timeline-spread", spread, true, false),
            ("timeline-spread-selected", spread, true, true),
            ("timeline-collapsed", spread, false, false),
        ]
        for (name, dates, expanded, selected) in cases where wants(name) {
            let model = TimelineViewModel(dateLoader: { dates })
            await model.loadTimelineData()
            model.autoSelectGranularity()
            model.isExpanded = expanded
            if selected, let bucket = model.buckets.dropFirst(model.buckets.count / 2).first(where: { $0.count > 0 }) {
                model.selectBucket(bucket)
            }
            for width in [1100.0, 640.0] {
                let view = TimelineFilterView(viewModel: model) { _ in }
                    .frame(width: width)
                try render(view, "\(name)-\(Int(width))", size: CGSize(width: width, height: expanded ? 92 : 36))
            }
        }
    }

    private func captureSidebar(store: MediaStore) throws {
        guard wants("sidebar-full") else { return }
        let state = AppState(mediaStore: store)
        let view = SidebarView()
            .environmentObject(state)
            .environment(SettingsStore.shared)
            .background(Color(nsColor: .windowBackgroundColor))
        try render(view, "sidebar-full", size: CGSize(width: 250, height: 1800), settle: 3)
    }

    private func captureCells(_ items: [MediaItem]) throws {
        guard wants("cells"), !items.isEmpty else { return }
        let starred = items.first { $0.metadata.starred } ?? items[0]
        let video = items.first { $0.hasVideo } ?? items[0]
        let multi = items.first { $0.mediaFiles.count > 1 } ?? items[1 % items.count]
        let plain = items.first { !$0.metadata.starred && !$0.hasVideo } ?? items[0]
        let cells: [(String, MediaItem, Bool, Bool, Bool)] = [
            ("plain", plain, false, false, false),
            ("starred", starred, false, false, false),
            ("video", video, false, false, false),
            ("multi", multi, false, false, false),
            ("selected", plain, true, false, false),
            ("multi-select off", starred, false, true, false),
            ("multi-select on", video, true, true, false),
            ("color bars", plain, false, false, true),
        ]
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.fixed(220), spacing: 12), count: 4), spacing: 12) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                VStack(spacing: 4) {
                    MasonryCell(item: cell.1, isSelected: cell.2, isMultiSelectMode: cell.3, showColorBar: cell.4,
                                selectedIDs: cell.2 ? [cell.1.id] : [], onSelect: {}, onToggleSelect: {},
                                onExtendSelect: {}, onDoubleClick: {}, onShowContextMenu: nil)
                        .frame(width: 220, height: 180)
                    Text(cell.0).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .environment(SettingsStore.shared)
        .background(Color(hex: 0x1c1c1e))
        try render(grid, "cells", size: CGSize(width: 960, height: 440), settle: 3)
    }

    private func captureBatchBar() throws {
        for width in [1100.0, 760.0] where wants("batch-bar-\(Int(width))") {
            let bar = BatchActionBar(selectedCount: 4, onStarAll: {}, onUnstarAll: {}, onAddTag: {},
                                     onRemoveTag: {}, onDelete: {}, onClearSelection: {})
                .padding(16)
                .frame(width: width)
                .background(Color(hex: 0x1c1c1e))
            try render(bar, "batch-bar-\(Int(width))", size: CGSize(width: width, height: 90))
        }
    }

    private func capturePalette(store: MediaStore, items: [MediaItem]) throws {
        guard wants("command-palette") else { return }
        let state = AppState(mediaStore: store)
        state.selectedItemIDs = Set(items.prefix(3).map(\.id))
        let registry = CommandRegistry.shared
        registry.registerDefaultCommands(appState: state)
        let palette = CommandPalette(registry: registry, isPresented: .constant(true))
            .environmentObject(state)
            .background(Color(hex: 0x1c1c1e))
        try render(palette, "command-palette", size: CGSize(width: 1100, height: 700))
    }

    private func captureEmptyStates(store: MediaStore, smartFolders: [SmartFolder]) throws {
        let cases: [(String, (AppState) -> Void)] = [
            ("empty-all-media", { _ in }),
            ("empty-no-results", { state in state.filterText = "zzqx"; state.starredFilter = true }),
            ("empty-smart-folder", { state in
                if let folder = smartFolders.first(where: { $0.name == "Parse Issues" }) ?? smartFolders.first {
                    state.activeSmartFolder = folder
                    state.sidebarSelection = .smartFolder(folder.id)
                }
            }),
        ]
        for (name, setup) in cases where wants(name) {
            let state = AppState(mediaStore: store)
            setup(state)
            let view = LibraryEmptyResultsView()
                .environmentObject(state)
                .background(Color(hex: 0x1c1c1e))
            try render(view, name, size: CGSize(width: 800, height: 420))
        }
    }

    private func captureSmartFolderEditor(store: MediaStore, smartFolders: [SmartFolder]) throws {
        let cases: [(String, SmartFolder?)] = [
            ("smart-folder-editor-new", nil),
            ("smart-folder-editor-edit", smartFolders.first { $0.name == "Twitter" } ?? smartFolders.first),
        ]
        for (name, existing) in cases where wants(name) {
            let editor = SmartFolderEditor(existingFolder: existing, onSave: { _ in }, getPreviewCount: { _ in 12 })
                .environmentObject(AppState(mediaStore: store))
                .environment(SettingsStore.shared)
                .background(Color(nsColor: .windowBackgroundColor))
            try render(editor, name, size: CGSize(width: 620, height: 660))
        }
    }

    // MARK: - Rendering

    private func wants(_ name: String) -> Bool { only?.contains(name) ?? true }

    private func render<V: View>(_ view: V, _ name: String, size: CGSize, settle: TimeInterval = 1) throws {
        guard wants(name) || name.hasPrefix("timeline") || name.hasPrefix("batch") else { return }
        let hosting = NSHostingView(rootView: view.preferredColorScheme(.dark))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting // never ordered front: no focus or screen change
        let end = Date().addingTimeInterval(settle)
        while Date() < end {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        window.contentView = nil
    }
}
