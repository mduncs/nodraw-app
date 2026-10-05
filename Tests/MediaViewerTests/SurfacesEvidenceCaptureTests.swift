import AppKit
import SwiftUI
import XCTest
@testable import MediaViewer

/// Offscreen evidence captures of Settings, import, onboarding, About, delete and
/// duplicate-review surfaces. Views render in a non-activating panel far off screen,
/// so nothing takes focus or appears on the display. Skipped unless
/// `NODRAW_SURFACES_CAPTURE_DIR` and a disposable `NODRAW_APP_SUPPORT_DIR` are set;
/// the Downloads tab is not rendered because its status task contacts the local server.
@MainActor
final class SurfacesEvidenceCaptureTests: XCTestCase {
    func testCaptureSurfaces() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["NODRAW_SURFACES_CAPTURE_DIR"] else {
            throw XCTSkip("Set NODRAW_SURFACES_CAPTURE_DIR to write captures")
        }
        guard let support = env["NODRAW_APP_SUPPORT_DIR"], support.hasPrefix("/tmp/") || support.hasPrefix("/private/tmp/") else {
            throw XCTSkip("Captures need a disposable NODRAW_APP_SUPPORT_DIR under /tmp")
        }
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: directory)
        let root = URL(fileURLWithPath: support).appendingPathComponent("capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let database = DatabaseManager(databaseURL: root.appendingPathComponent("capture.sqlite"))
        try await database.initialize()
        let previousShared = DatabaseManager.shared
        DatabaseManager.shared = database
        defer { DatabaseManager.shared = previousShared }
        let store = MediaStore(database: database)
        try await Self.seedDuplicates(in: root, store: store)
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()

        let appState = AppState(mediaStore: store)
        let settings = SettingsStore.shared
        // Presets make the shared tag chips visible in Library settings and the import sheet.
        let previousPresets = settings.importTagPresets
        settings.importTagPresets = [
            ImportTagPreset(name: "Golden hour", tags: ["sunset", "photography", "reference"], isDefault: true),
            ImportTagPreset(name: "Mood board", tags: ["aesthetics", "film"]),
        ]
        defer { settings.importTagPresets = previousPresets }

        let tabs: [(String, SettingsRootView.SettingsTab)] = [
            ("settings-general", .general), ("settings-library", .library), ("settings-playback", .playback),
            ("settings-organization", .organization), ("settings-processing", .processing), ("settings-advanced", .advanced),
        ]
        for (name, tab) in tabs {
            try await Self.capture(
                SettingsRootView(initialTab: tab).environmentObject(appState).environment(settings),
                size: CGSize(width: 1020, height: 1500), to: out.appendingPathComponent("\(name).png"))
        }

        try await Self.capture(
            ImportTagPresetSheet(fileCount: 1, onImport: { _, _ in }, onCancel: {}),
            size: CGSize(width: 400, height: 500), to: out.appendingPathComponent("import-sheet-1-file.png"))
        try await Self.capture(
            ImportTagPresetSheet(fileCount: 12, onImport: { _, _ in }, onCancel: {}),
            size: CGSize(width: 400, height: 500), to: out.appendingPathComponent("import-sheet-12-files.png"))
        try await Self.capture(
            Self.banners, size: CGSize(width: 640, height: 720), to: out.appendingPathComponent("import-banners.png"))
        try await Self.capture(
            DropTargetOverlay(), size: CGSize(width: 900, height: 600), to: out.appendingPathComponent("import-drop-zone.png"))
        try await Self.capture(
            OnboardingView(onComplete: {}), size: CGSize(width: 720, height: 500), to: out.appendingPathComponent("onboarding.png"))
        try await Self.capture(
            AboutView(), size: CGSize(width: 520, height: 540), to: out.appendingPathComponent("about.png"))
        try await Self.capture(
            Self.deleteDialogs, size: CGSize(width: 900, height: 420), to: out.appendingPathComponent("delete-dialogs.png"))

        try await Self.capture(
            DuplicateTriageView(detector: detector, reviewService: DuplicateReviewService(database: database, mediaStore: store))
                .environmentObject(appState),
            size: CGSize(width: 1280, height: 820), to: out.appendingPathComponent("duplicates-comparison.png"), settle: 3)

        let emptyDatabase = DatabaseManager(databaseURL: root.appendingPathComponent("empty.sqlite"))
        try await emptyDatabase.initialize()
        let emptyStore = MediaStore(database: emptyDatabase)
        try await Self.capture(
            DuplicateTriageView(detector: DuplicateDetector(db: emptyDatabase),
                                reviewService: DuplicateReviewService(database: emptyDatabase, mediaStore: emptyStore))
                .environmentObject(AppState(mediaStore: emptyStore)),
            size: CGSize(width: 1100, height: 640), to: out.appendingPathComponent("duplicates-empty.png"), settle: 2)

        await store.writeBackQueue.flushNow()
        await emptyStore.writeBackQueue.flushNow()
    }

    private static var banners: some View {
        VStack(spacing: -40) {
            ImportProgressBanner(count: 1, progress: nil)
            ImportProgressBanner(count: 24, progress: ImportProgress(completed: 7, total: 24,
                filename: "2026-09-28 reference sheet with a very long exported filename (final) copy 3.png"))
            ImportCompleteBanner(result: ImportResult(importedCount: 5, skippedCount: 0, failedCount: 0, createdItemIds: [], errors: []))
            ImportCompleteBanner(result: ImportResult(importedCount: 0, skippedCount: 3, failedCount: 0, createdItemIds: [], errors: []))
            ImportCompleteBanner(result: ImportResult(importedCount: 2, skippedCount: 1, failedCount: 1, createdItemIds: [], errors: [
                ImportError(filename: "broken-export.heic", reason: "The file couldn't be read.",
                            sourceURL: URL(fileURLWithPath: "/tmp/broken-export.heic")),
            ]))
        }
        .padding(.top, 20)
    }

    private static var deleteDialogs: some View {
        HStack(alignment: .top, spacing: 20) {
            DeleteConfirmDialog(itemCount: 1, fileCount: 1, hasContext: false, deleteFromDisk: false,
                                onConfirm: {}, onCancel: {}, skipFutureConfirmations: .constant(false))
            DeleteConfirmDialog(itemCount: 1, fileCount: 3, hasContext: true, deleteFromDisk: true,
                                onConfirm: {}, onCancel: {}, skipFutureConfirmations: .constant(false))
        }
        .padding(20)
    }

    /// Three byte-identical images under separate items: one exact-duplicate group.
    private static func seedDuplicates(in root: URL, store: MediaStore) async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 480, height: 320, bitsPerComponent: 8,
            bytesPerRow: 480 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors: [CGColor] = [CGColor(red: 0.09, green: 0.12, blue: 0.2, alpha: 1), CGColor(red: 0.98, green: 0.45, blue: 0.2, alpha: 1)]
        context.setFillColor(colors[0]); context.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
        context.setFillColor(colors[1]); context.fillEllipse(in: CGRect(x: 150, y: 70, width: 180, height: 180))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let notes = [
            "Original save from the artist's post.",
            "Re-saved from a repost; the thread context differs.",
            nil,
        ]
        for index in 1...3 {
            let url = root.appendingPathComponent("sunset-\(index).png")
            try data.write(to: url)
            var item = SampleData.createMediaItem(basePath: root,
                metadataFile: root.appendingPathComponent("sunset-\(index).md"), mediaFiles: [url],
                source: "https://example.com/post/\(1000 + index)", tags: index == 1 ? ["sunset", "reference"] : ["sunset"],
                notes: notes[index - 1])
            item.metadata.starred = index == 1
            try await store.insertItem(item)
        }
        await store.writeBackQueue.flushNow()
    }

    static func capture<V: View>(_ view: V, size: CGSize, to url: URL, settle: Double = 1) async throws {
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
