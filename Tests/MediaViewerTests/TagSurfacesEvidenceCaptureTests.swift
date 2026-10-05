import AppKit
import SwiftUI
import XCTest
@testable import MediaViewer

/// Offscreen evidence captures of the tag surfaces around the hold-to-tag overlay
/// (tagging HUD, tag tree, rules, import presets, tag input) at ~300 tags. Views
/// render into a window that is never ordered on screen. Skipped unless
/// `NODRAW_TAG_OVERLAY_CAPTURE_DIR` is set, and refuses to run unless
/// `NODRAW_APP_SUPPORT_DIR` isolates the database under /tmp.
@MainActor
final class TagSurfacesEvidenceCaptureTests: XCTestCase {
    func testCaptureTagSurfaces() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["NODRAW_TAG_OVERLAY_CAPTURE_DIR"] else {
            throw XCTSkip("Set NODRAW_TAG_OVERLAY_CAPTURE_DIR to write captures")
        }
        guard let support = env["NODRAW_APP_SUPPORT_DIR"], support.hasPrefix("/tmp/") || support.hasPrefix("/private/tmp/") else {
            throw XCTSkip("Set NODRAW_APP_SUPPORT_DIR under /tmp so no live database is touched")
        }
        _ = NSApplication.shared
        let prefix = env["NODRAW_TAG_CAPTURE_PREFIX"] ?? "after"
        let out = URL(fileURLWithPath: directory)

        let database = DatabaseManager(databaseURL: URL(fileURLWithPath: support).appendingPathComponent("capture.sqlite"))
        try await database.initialize()
        DatabaseManager.shared = database
        let store = MediaStore(database: database)

        let tagSettings = TagSettings.shared
        let settings = SettingsStore.shared
        let saved = (tagSettings.definitions, tagSettings.recentTagIds)
        let savedPresets = settings.importTagPresets
        let savedExpanded = settings.tagTreeExpandedNodeIDs
        let savedWidth = settings.taggingHUDWidth
        defer {
            (tagSettings.definitions, tagSettings.recentTagIds) = saved
            settings.importTagPresets = savedPresets
            settings.tagTreeExpandedNodeIDs = savedExpanded
            settings.taggingHUDWidth = savedWidth
        }

        let fixture = TagOverlayEvidenceCaptureTests.fixture()
        tagSettings.definitions = fixture
        tagSettings.recentTagIds = [4, 60, 17, 133, 2, 88, 250].map { fixture[$0 % fixture.count].id }
        let roots = tagSettings.rootTags()
        let music = roots[1]
        let music80s = tagSettings.children(of: music.id)[1]
        let leaves = tagSettings.children(of: music80s.id)

        // Tag tree: two branches open, one filter-free view of the full vocabulary.
        settings.tagTreeExpandedNodeIDs = [music.id, music80s.id, roots[3].id]
        try Self.capture(
            ScrollView { TagTreeEditor(tagSettings: tagSettings, mediaStore: store).padding(16) },
            size: CGSize(width: 640, height: 620),
            to: out.appendingPathComponent("\(prefix)-tag-tree-editor.png")
        )
        try Self.capture(
            ScrollView { TagTreeEditor(tagSettings: tagSettings, mediaStore: nil).padding(16) },
            size: CGSize(width: 640, height: 300),
            to: out.appendingPathComponent("\(prefix)-tag-tree-editor-loading.png")
        )

        // Rules: a realistic mix, including long names and a disabled rule.
        let engine = TagRuleEngine.shared
        for rule in engine.rules { try await engine.deleteRule(rule) }
        let rules: [TagRule] = [
            TagRule(name: "r/outrun -> 1980s synthwave music", sourceField: .subreddit, pattern: "outrun", tagName: "1980s synthwave music", priority: 0),
            TagRule(name: "@moebius -> illustration 1970s", sourceField: .artistName, matchType: .contains, pattern: "moebius", tagName: "illustration 1970s", priority: 1),
            TagRule(name: "scene:concert -> music", sourceField: .sceneLabel, pattern: "concert", tagName: "music", priority: 2),
            TagRule(name: "/wg/ -> contemporary minimal architecture", sourceField: .boardName, pattern: "wg", tagName: "contemporary minimal architecture", priority: 3),
            TagRule(name: "tag:vaporwave -> y2k synthwave aesthetics", enabled: false, sourceField: .sourceTag, matchType: .prefix, pattern: "vaporwave", tagName: "y2k synthwave aesthetics", priority: 4),
        ]
        for rule in rules { try await engine.addRule(rule) }
        try Self.capture(
            TagRulesSettingsView(mediaStore: store).padding(16),
            size: CGSize(width: 640, height: 320),
            to: out.appendingPathComponent("\(prefix)-tag-rules.png")
        )
        for rule in engine.rules { try await engine.deleteRule(rule) }
        try Self.capture(
            TagRulesSettingsView(mediaStore: store).padding(16),
            size: CGSize(width: 640, height: 300),
            to: out.appendingPathComponent("\(prefix)-tag-rules-empty.png")
        )
        try Self.capture(
            TagRuleEditorSheet(engine: engine, tagSettings: tagSettings, editingRule: rules[0], mediaStore: store),
            size: CGSize(width: 420, height: 520),
            to: out.appendingPathComponent("\(prefix)-tag-rule-editor.png")
        )
        try Self.capture(
            TagRuleEditorSheet(engine: engine, tagSettings: tagSettings, prefilledSourceField: .curationScore, prefilledPattern: "0.8", mediaStore: store),
            size: CGSize(width: 420, height: 520),
            to: out.appendingPathComponent("\(prefix)-tag-rule-editor-new-ml.png")
        )

        // Import presets.
        settings.importTagPresets = [
            ImportTagPreset(name: "Film scans", tags: ["film 1970s", "photography 1970s", "1970s minimal photography"], isDefault: true),
            ImportTagPreset(name: "Synth flyers", tags: ["music 1980s", "1980s synthwave music", "1980s punk typography", "y2k synthwave aesthetics", "contemporary hair metal music"]),
            ImportTagPreset(name: "Reference", tags: ["architecture"]),
        ]
        try Self.capture(
            ImportTagPresetSheet(fileCount: 48, onImport: { _, _ in }, onCancel: {}),
            size: CGSize(width: 400, height: 500),
            to: out.appendingPathComponent("\(prefix)-import-presets.png")
        )

        // Tag input popover (library 't'), empty state with recents.
        let names = fixture.map(\.name)
        let recents = tagSettings.recentTags.map(\.name)
        try Self.capture(
            TagInputPopover(isPresented: .constant(true), existingTags: names, recentlyUsedTags: recents, onAddTag: { _ in }),
            size: CGSize(width: 420, height: 380),
            to: out.appendingPathComponent("\(prefix)-tag-input-popover.png")
        )

        // Tagging HUD: root level and a drilled leaf level with staged changes.
        let viewModel = TaggingQueueViewModel(mediaStore: store, tagSettings: tagSettings)
        viewModel.isActive = true
        viewModel.totalCount = 214
        viewModel.currentIndex = 36
        var item = Self.makeItem()
        item.metadata.tags = ["music", "music 1980s", leaves[0].name, "1990s minimal photography", "an old free-form tag"]
        viewModel.currentItem = item
        var level = TagTreeNode.buildTree(from: tagSettings)
        TagTreeNode.assignKeyBindings(to: &level)
        viewModel.currentLevel = level
        settings.taggingHUDWidth = 520
        let appState = AppState()
        try Self.capture(
            TaggingHUD(viewModel: viewModel).environmentObject(appState).environment(settings),
            size: CGSize(width: 560, height: 560),
            to: out.appendingPathComponent("\(prefix)-tagging-hud-root.png")
        )
        guard let musicNode = viewModel.currentLevel.first(where: { $0.id == music.id }) else { return XCTFail("music") }
        viewModel.selectNode(musicNode)
        guard let eraNode = viewModel.currentLevel.first(where: { $0.id == music80s.id }) else { return XCTFail("era") }
        viewModel.selectNode(eraNode)
        viewModel.toggleLeafTag(named: leaves[1].name)
        viewModel.toggleLeafTag(named: leaves[2].name)
        viewModel.toggleLeafTag(named: leaves[0].name)
        try Self.capture(
            TaggingHUD(viewModel: viewModel).environmentObject(appState).environment(settings),
            size: CGSize(width: 560, height: 560),
            to: out.appendingPathComponent("\(prefix)-tagging-hud-drilled.png")
        )
    }

    private static func makeItem() -> MediaItem {
        let id = UUID()
        let basePath = URL(fileURLWithPath: "/tmp/nodraw-cleanup-tags/archive/2025-01")
        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("\(id.uuidString).md"),
            mediaFiles: [basePath.appendingPathComponent("\(id.uuidString).jpg")],
            metadata: MediaMetadata(source: URL(string: "https://example.com/\(id)")!, platform: "test"),
            aspectRatio: 1.0
        )
    }

    static func capture<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let root = ZStack(alignment: .topLeading) {
            Color(hex: 0x1e1e1e)
            view
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting // never ordered front: no focus or screen change
        for _ in 0..<6 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        window.contentView = nil
    }
}
