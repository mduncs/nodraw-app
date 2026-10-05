import XCTest
import SwiftUI
import AppKit
@testable import MediaViewer

/// Real view + real service, rendered offscreen with an isolated fixture database.
@MainActor
final class DuplicateReviewSnapshotTests: XCTestCase {
    func testReviewRendersRegularAndCompactWithoutTakingFocus() async throws {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duplicate-view-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager(databaseURL: root.appendingPathComponent("test.sqlite"))
        try await database.initialize()
        let store = MediaStore(database: database)
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8,
            bytesPerRow: 320 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.04, green: 0.1, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        context.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 35, y: 35, width: 250, height: 170))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        for index in 1...3 {
            let url = root.appendingPathComponent("copy-\(index).png")
            try data.write(to: url)
            var item = SampleData.createMediaItem(basePath: root,
                metadataFile: root.appendingPathComponent("copy-\(index).md"), mediaFiles: [url],
                source: "https://example.com/capture-\(index)")
            item.metadata.notes = "Independent capture \(index): the media bytes match, but these notes belong to this copy."
            try await store.insertItem(item)
        }
        await store.writeBackQueue.flushNow()
        let detector = DuplicateDetector(db: database)
        _ = try await detector.detectDuplicates()
        let view = DuplicateTriageView(detector: detector, reviewService: DuplicateReviewService(database: database, mediaStore: store))
            .environmentObject(AppState(mediaStore: store))
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        let panel = DuplicateSnapshotPanel(contentRect: CGRect(x: -30_000, y: -30_000, width: 1280, height: 820),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.tabbingMode = .disallowed
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.contentView = host
        panel.orderBack(nil)
        defer { panel.orderOut(nil); panel.contentView = nil; host.removeFromSuperview(); panel.close() }
        for (width, height, suffix) in [(1280, 820, "regular"), (900, 650, "compact")] {
            let size = CGSize(width: width, height: height)
            panel.setFrame(CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size), display: false)
            host.frame = CGRect(origin: .zero, size: size)
            var rendered: NSBitmapImageRep?
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let result = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: result)
                rendered = result
                if cyanPixels(result) > 500 { break }
            }
            let result = try XCTUnwrap(rendered)
            XCTAssertGreaterThan(cyanPixels(result), 500, "Real duplicate media should render, not just the empty shell")
            let png = try XCTUnwrap(result.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent("review-\(suffix).png"))
            XCTAssertFalse(panel.isKeyWindow)
            XCTAssertFalse(panel.isMainWindow)
            XCTAssertLessThan(panel.frame.maxX, -20_000)
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
        }
        await store.writeBackQueue.flushNow()
    }

    private func cyanPixels(_ image: NSBitmapImageRep) -> Int {
        var count = 0
        for y in stride(from: 0, to: image.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: image.pixelsWide, by: 4) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.greenComponent > color.redComponent * 1.8 && color.blueComponent > color.redComponent * 1.8 && color.greenComponent > 0.1 { count += 1 }
            }
        }
        return count
    }
}

private final class DuplicateSnapshotPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
