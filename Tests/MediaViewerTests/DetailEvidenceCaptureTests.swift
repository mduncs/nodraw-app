import AppKit
import GRDB
import SwiftUI
import XCTest
@testable import MediaViewer

/// Offscreen evidence captures of the detail view, its inspector, video transport and
/// the native image editor. Views render in a non-activating panel far off screen, so
/// nothing takes focus or appears on the display. Skipped unless
/// `NODRAW_DETAIL_CAPTURE_DIR`, a disposable `NODRAW_APP_SUPPORT_DIR` under /tmp and
/// `NODRAW_DETAIL_FIXTURE_DB` (an indexed QA fixture database, copied before use) are set.
@MainActor
final class DetailEvidenceCaptureTests: XCTestCase {
    func testCaptureDetailSurfaces() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["NODRAW_DETAIL_CAPTURE_DIR"], let fixtureDB = env["NODRAW_DETAIL_FIXTURE_DB"] else {
            throw XCTSkip("Set NODRAW_DETAIL_CAPTURE_DIR and NODRAW_DETAIL_FIXTURE_DB to write captures")
        }
        guard let support = env["NODRAW_APP_SUPPORT_DIR"], support.hasPrefix("/tmp/") || support.hasPrefix("/private/tmp/"),
              fixtureDB.hasPrefix("/tmp/") || fixtureDB.hasPrefix("/private/tmp/") else {
            throw XCTSkip("Captures need a disposable NODRAW_APP_SUPPORT_DIR and fixture under /tmp")
        }
        _ = NSApplication.shared
        let prefix = env["NODRAW_DETAIL_CAPTURE_PREFIX"] ?? "before"
        let out = URL(fileURLWithPath: directory)
        let root = URL(fileURLWithPath: support).appendingPathComponent("capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("capture.sqlite")
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: fixtureDB + suffix) {
            try FileManager.default.copyItem(atPath: fixtureDB + suffix, toPath: dbURL.path + suffix)
        }

        let database = DatabaseManager(databaseURL: dbURL)
        try await database.initialize()
        let previousShared = DatabaseManager.shared
        DatabaseManager.shared = database
        defer { DatabaseManager.shared = previousShared }
        let store = MediaStore(database: database)
        let ids = try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, basePathString FROM media_items").reduce(into: [String: UUID]()) { result, row in
                let path: String = row["basePathString"]
                if let id = UUID(uuidString: row["id"]) { result[(path as NSString).lastPathComponent] = id }
            }
        }
        func item(_ name: String) async throws -> MediaItem {
            let id = try XCTUnwrap(ids[name], "fixture item \(name)")
            return try await XCTUnwrapAsync(try await store.fetchItem(id: id))
        }
        try await Self.seedAnalysis(database: database, video: try await item("13-loop-teal"),
                                    ocr: try await item("19-release-notes"), annotated: try await item("16-still"))

        let appState = AppState(mediaStore: store)
        let settings = SettingsStore.shared

        func detail(_ name: String, width: CGFloat, suffix: String = "") async throws {
            let loaded = try await item(name)
            try await Self.capture(
                SingleFocusView(item: loaded, onClose: {}, onItemUpdated: { _ in }, onPrevItem: {}, onNextItem: {})
                    .environmentObject(appState).environment(settings),
                size: CGSize(width: width, height: 900), settle: 2.5,
                to: out.appendingPathComponent("\(prefix)-detail-\(Int(width))-\(name)\(suffix).png"))
        }
        for width: CGFloat in [1440, 1100] {
            for name in ["16-still", "15-gallery", "13-loop-teal", "19-release-notes"] {
                try await detail(name, width: width)
            }
        }
        for name in ["17-voice-memo", "18-zine", "20-moved-away"] {
            try await detail(name, width: 1440)
        }

        let still = try await item("16-still")
        let annotations = try await AnnotationStore(database: database).fetchAnnotations(itemId: still.id, mediaFileIndex: 0)
        for width: CGFloat in [1440, 1100] {
            let session = AnnotationEditorSession(itemId: still.id, mediaFileIndex: 0, annotationSet: annotations,
                                                  store: AnnotationStore(database: database))
            try await Self.capture(
                NativeImageEditorView(session: session, sourceURL: still.mediaFiles[0],
                                      isPresented: .constant(true), onDocumentChanged: { _ in })
                    .environmentObject(appState).environment(settings),
                size: CGSize(width: width, height: 900), settle: 2,
                to: out.appendingPathComponent("\(prefix)-editor-\(Int(width)).png"))
        }

        let video = try await item("13-loop-teal")
        try await Self.capture(
            MetadataPanel(item: video, onTagsChanged: { _ in }, onNotesChanged: { _, _ in }, onStarChanged: { _ in },
                          videoPlaybackTime: 3, onSeekToVideoTime: { _ in })
                .environmentObject(appState).environment(settings),
            size: CGSize(width: 320, height: 1000), settle: 2,
            to: out.appendingPathComponent("\(prefix)-inspector-video.png"))
        for name in ["13-loop-teal", "19-release-notes", "16-still"] {
            let loaded = try await item(name)
            try await Self.capture(
                MetadataPanel(item: loaded, onTagsChanged: { _ in }, onNotesChanged: { _, _ in }, onStarChanged: { _ in },
                              hoveredOCRBlock: .constant(nil), showOCROverlay: .constant(false),
                              videoPlaybackTime: 5, onSeekToVideoTime: { _ in }, expandsDetailSections: true)
                    .environmentObject(appState).environment(settings),
                size: CGSize(width: 320, height: 1500), settle: 2,
                to: out.appendingPathComponent("\(prefix)-inspector-expanded-\(name).png"))
        }
        try await Self.capture(Self.transport, size: CGSize(width: 900, height: 200),
                               to: out.appendingPathComponent("\(prefix)-video-transport.png"))
    }

    private static var transport: some View {
        VStack(spacing: 12) {
            VideoTransportControls(isPlaying: .constant(false), isMuted: .constant(true), volume: .constant(0.6),
                rate: .constant(1), currentTime: 7, duration: 24, onSeek: { _ in }, onToggleMute: {},
                canGoToPreviousResult: true, canGoToNextResult: true, onPreviousItem: {}, onNextItem: {})
            VideoTransportControls(isPlaying: .constant(true), isMuted: .constant(false), volume: .constant(0.8),
                rate: .constant(1.5), currentTime: 3725, duration: 5400, onSeek: { _ in }, onToggleMute: {},
                canGoToPreviousResult: false, canGoToNextResult: true, onPreviousItem: {}, onNextItem: {})
        }
        .padding(12)
    }

    /// Seeds transcript and visual segments for the video, OCR regions for the text image,
    /// and a small annotation document for the still, all in the disposable copy.
    private static func seedAnalysis(database: DatabaseManager, video: MediaItem, ocr: MediaItem, annotated: MediaItem) async throws {
        let lines = [
            "Okay, this is the teal loop test clip for the archive.",
            "The gradient drifts left to right over about four seconds.",
            "Watch the edge where the colour bands meet, that is the part I care about.",
            "Second pass, same loop, slightly faster.",
            "Notice the banding in the dark corner.",
            "That is it, the end of the loop.",
        ]
        let summaries = ["Teal gradient, wide shot", "Colour band edge, close", "Dark corner banding", "Loop restart"]
        let videoPath = video.mediaFiles[0].path
        var transcript: [TranscriptSegmentRecord] = []
        for (index, text) in lines.enumerated() {
            transcript.append(TranscriptSegmentRecord(segment: TranscriptSegment(
                id: UUID(), itemId: video.id, mediaFileIndex: 0, sourcePath: videoPath,
                startTime: Double(index) * 4, endTime: Double(index) * 4 + 3.8, text: text,
                confidence: 0.92, language: "en", model: "parakeet", version: 1)))
        }
        var visual: [VideoSegmentRecord] = []
        for (index, summary) in summaries.enumerated() {
            visual.append(VideoSegmentRecord(segment: VideoSegment(
                id: UUID(), itemId: video.id, mediaFileIndex: 0, sourcePath: videoPath,
                startTime: Double(index) * 6, endTime: Double(index) * 6 + 6, summary: summary,
                labels: [VideoSegmentLabel(label: "gradient", confidence: 0.8)], confidence: 0.8,
                analysisSource: "native_vision", version: 1)))
        }
        let ocrURL = ocr.mediaFiles[0]
        // Vision is unavailable in some headless sessions; fall back to the fixture's known layout.
        let blocks: [SerializableTextBlock]
        if let result = try? await VisionProcessor.extractOCRWithRegions(from: ocrURL), !result.blocks.isEmpty {
            blocks = result.blocks.map { SerializableTextBlock(from: $0) }
        } else {
            let fixtureLines: [(String, CGFloat, CGFloat)] = [
                ("Release notes: archive 2.4", 160, 58), ("Faster thumbnails for large folders", 260, 34),
                ("Context screenshots browse like pages", 320, 34), ("Related items by author, folder and tag", 380, 34),
                ("posted by @changelog.demo \u{00B7} 12 replies", 800, 26),
            ]
            blocks = fixtureLines.enumerated().map { index, line in
                let (text, baseline, points) = line
                let box = SerializableCGRect(rect: CGRect(x: 90.0 / 1400, y: 1 - (baseline + points * 0.25) / 900,
                    width: min(0.9, CGFloat(text.count) * points * 0.52 / 1400), height: points * 1.05 / 900))
                return SerializableTextBlock(id: "fixture-\(index)", text: text,
                    lines: [SerializableTextObservation(text: text, boundingBox: box, confidence: 0.98)],
                    boundingBox: box, confidence: 0.98, role: "body", columnIndex: 0)
            }
        }
        let ocrRecord = MediaFileOCRRecord(itemId: ocr.id, fileURL: ocrURL.path, fileIndex: 0,
                                           ocrText: blocks.map(\.text).joined(separator: "\n"), ocrBlocks: blocks)
        let transcriptRecords = transcript, visualRecords = visual
        try await database.write { db in
            for record in transcriptRecords { try record.insert(db) }
            for record in visualRecords { try record.insert(db) }
            try db.execute(sql: "DELETE FROM media_file_ocr WHERE item_id = ?", arguments: [ocr.id.uuidString])
            try ocrRecord.insert(db)
        }

        let accent = ShapeStyle(strokeColor: 0xFF5A36FF, strokeWidth: 4)
        let layer = AnnotationLayer(name: "Notes", shapes: [
            .rectangle(id: UUID(), rect: NormalizedRect(x: 0.18, y: 0.22, width: 0.34, height: 0.3), style: accent),
            .arrow(id: UUID(), from: NormalizedPoint(x: 0.75, y: 0.72), to: NormalizedPoint(x: 0.5, y: 0.5), style: accent),
            .text(id: UUID(), position: NormalizedPoint(x: 0.6, y: 0.78), content: "fix this edge", style: .default),
        ])
        try await AnnotationStore(database: database).saveAnnotations(
            itemId: annotated.id, annotationSet: AnnotationSet(layers: [layer]), recordUndo: false)
    }

    static func capture<V: View>(_ view: V, size: CGSize, settle: Double = 1, to url: URL) async throws {
        let root = view
            .frame(width: size.width, height: size.height)
            .background(Color(hex: 0x1a1a1a))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .darkAqua)
        let panel = NSPanel(contentRect: CGRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = host
        panel.orderBack(nil)
        defer { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        host.frame = CGRect(origin: .zero, size: size)
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(panel.isKeyWindow)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
