import AppKit
import SwiftUI
import XCTest
@testable import MediaViewer

/// Offscreen evidence captures of the hold-to-tag overlay at scale. A held modifier
/// cannot be simulated without touching global input state, so this renders the
/// overlay in a window that is never ordered on screen. Skipped unless
/// `NODRAW_TAG_OVERLAY_CAPTURE_DIR` is set.
@MainActor
final class TagOverlayEvidenceCaptureTests: XCTestCase {
    func testCaptureOverlayAtScale() throws {
        guard let directory = ProcessInfo.processInfo.environment["NODRAW_TAG_OVERLAY_CAPTURE_DIR"] else {
            throw XCTSkip("Set NODRAW_TAG_OVERLAY_CAPTURE_DIR to write captures")
        }
        _ = NSApplication.shared
        let settings = TagSettings.shared
        let saved = (settings.definitions, settings.recentTagIds, settings.layout, settings.gridScale)
        defer {
            (settings.definitions, settings.recentTagIds, settings.layout, settings.gridScale) = saved
        }

        let fixture = Self.fixture()
        settings.definitions = fixture
        settings.recentTagIds = [4, 60, 17, 133, 2, 88, 250].map { fixture[$0 % fixture.count].id }
        let selected = [fixture[3].name, fixture[20].name, fixture[140].name, fixture[141].name]
        let rootWithChildren = settings.rootTags()[2]
        let branch = settings.children(of: rootWithChildren.id)[1]

        let shots: [(String, TagOverlayLayout, Double, TagOverlay)] = [
            ("after-sunburst-310-tags", .sunburst, 1.0, TagOverlay(previewTags: selected)),
            ("after-sunburst-drilled", .sunburst, 1.0,
             TagOverlay(previewTags: selected, drillPath: [.init(parentID: rootWithChildren.id), .init(parentID: branch.id)])),
            ("after-sunburst-filter", .sunburst, 1.0, TagOverlay(previewTags: selected, query: "punk")),
            ("after-sunburst-wide", .sunburst, 1.45, TagOverlay(previewTags: selected)),
            ("after-grid-310-tags", .grid, 1.0, TagOverlay(previewTags: selected)),
            ("after-grid-filter", .grid, 1.0, TagOverlay(previewTags: selected, query: "synth")),
            ("after-radial-310-tags", .radial, 1.0, TagOverlay(previewTags: selected)),
        ]

        for (name, layout, scale, overlay) in shots {
            settings.layout = layout
            settings.gridScale = scale
            try Self.capture(overlay, size: CGSize(width: 1000, height: scale > 1.2 ? 860 : 700),
                             to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    /// 12 genres × 5 eras × 4 styles (+ roots and eras) = 312 hierarchical tags.
    static func fixture() -> [TagDefinition] {
        let genres = ["aesthetics", "music", "film", "illustration", "photography", "fashion",
                      "architecture", "games", "memes", "typography", "nature", "people"]
        let eras = ["1970s", "1980s", "1990s", "y2k", "contemporary"]
        let styles = ["punk", "synthwave", "hair metal", "minimal"]
        var result: [TagDefinition] = []
        for (g, genre) in genres.enumerated() {
            var root = TagDefinition(name: genre)
            root.sortOrder = g
            result.append(root)
            for (e, era) in eras.enumerated() {
                var child = TagDefinition(name: "\(genre) \(era)")
                child.parentId = root.id
                child.sortOrder = e
                result.append(child)
                for (s, style) in styles.enumerated() {
                    var leaf = TagDefinition(name: "\(era) \(style) \(genre)")
                    leaf.parentId = child.id
                    leaf.sortOrder = s
                    result.append(leaf)
                }
            }
        }
        return result
    }

    static func capture<V: View>(_ view: V, size: CGSize, to url: URL) throws {
        let root = ZStack {
            Color(hex: 0x2b2b2b)
            Color.black.opacity(0.5)
            view
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting // never ordered front: no focus or screen change
        for _ in 0..<4 {
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
