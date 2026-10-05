import XCTest
import SwiftUI
import AppKit
@testable import MediaViewer

/// Background-only layout evidence. The actual host uses a nonactivating panel positioned far
/// outside every display; no window is keyed, ordered front, activated, or driven with input.
@MainActor
final class EditorWorkspaceSnapshotTests: XCTestCase {
    func testWorkspaceRendersOffscreenWithoutChangingFrontmostApplication() async throws {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let shapeID = UUID()
        let layer = AnnotationLayer(name: "Title & marks", shapes: [
            .rectangle(id: shapeID, rect: NormalizedRect(x: 0.18, y: 0.2, width: 0.44, height: 0.38), style: ShapeStyle(strokeColor: 0xFF6B35FF, strokeWidth: 3)),
            .text(id: UUID(), position: NormalizedPoint(x: 0.12, y: 0.8), content: "A quieter afternoon", style: TextStyle(fontSize: 25))
        ])
        let session = AnnotationEditorSession(itemId: UUID(), annotationSet: AnnotationSet(layers: [
            AnnotationLayer(name: "Highlights", opacity: 0.75), layer
        ], activeLayerId: layer.id))
        session.select(shapeID)
        let source = try syntheticImage()
        let workspace = ImageEditorWorkspace(session: session,
            selectedTool: .constant(.select), currentStyle: .constant(.defaultRectangle),
            currentTextStyle: .constant(.default), eraserMode: .constant(.removeFromMask),
            eraserBrushSize: .constant(30), featherRadius: .constant(2),
            onDone: {}, onExport: {}, onImportImage: {}, onRemoveBackground: {}, onIsolatePerson: {}, onLiftSubjects: {}) {
                ZStack {
                    Image(nsImage: source).resizable().aspectRatio(contentMode: .fit)
                    SelectionHandles(rect: NormalizedRect(x: 0.18, y: 0.2, width: 0.44, height: 0.38),
                        displaySize: CGSize(width: 780, height: 520), onBegin: {}, onResize: { _ in }, onEnd: {})
                }
                .frame(width: 780, height: 520)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
            }
        let host = NSHostingView(rootView: workspace)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
        host.layoutSubtreeIfNeeded()
        for _ in 0..<3 { await Task.yield(); host.layoutSubtreeIfNeeded() }
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/nodraw-editor-workspace.png"), options: .atomic)
        XCTAssertGreaterThan(png.count, 15_000, "The workspace snapshot should contain rendered UI, not an empty bitmap")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmostPID)
    }

    func testActualNativeEditorHostRendersAtRegularAndCompactSizesOffscreen() async throws {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nodraw-editor-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try syntheticImage()
        let cgImage = try XCTUnwrap(source.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let sourcePNG = try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        let sourceURL = directory.appendingPathComponent("source.png")
        try sourcePNG.write(to: sourceURL)
        let assets = AnnotationAssetStore(assetDirectory: directory.appendingPathComponent("assets", isDirectory: true))
        let shapeID = UUID()
        let layer = AnnotationLayer(name: "Title & marks", shapes: [
            .rectangle(id: shapeID, rect: NormalizedRect(x: 0.18, y: 0.2, width: 0.44, height: 0.38),
                       style: ShapeStyle(strokeColor: 0xFF6B35FF, strokeWidth: 3)),
            .text(id: UUID(), position: NormalizedPoint(x: 0.12, y: 0.8), content: "A quieter afternoon",
                  style: TextStyle(fontSize: 25, backgroundColor: nil, fontWeight: .semibold))
        ])
        let session = AnnotationEditorSession(itemId: UUID(), annotationSet: AnnotationSet(layers: [
            AnnotationLayer(name: "Highlights", opacity: 0.75), layer
        ], activeLayerId: layer.id))
        session.select(shapeID)
        let editor = NativeImageEditorView(session: session, sourceURL: sourceURL,
            isPresented: .constant(true), onDocumentChanged: { _ in }, assetStore: assets)
        let host = NSHostingView(rootView: editor)
        host.appearance = NSAppearance(named: .darkAqua)
        let panel = EditorSnapshotPanel(contentRect: CGRect(x: -30_000, y: -30_000, width: 1280, height: 800),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.tabbingMode = .disallowed
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.contentView = host
        // Attaching and ordering behind all windows triggers SwiftUI .task/.onAppear. The panel
        // cannot become key/main and constrainFrameRect deliberately retains its offscreen frame.
        panel.orderBack(nil)
        defer {
            panel.orderOut(nil)
            panel.contentView = nil
            host.removeFromSuperview()
            panel.close()
        }
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmostPID)
        let configurations: [(CGSize, String)] = [
            (CGSize(width: 1280, height: 800), "/tmp/nodraw-editor-host.png"),
            (CGSize(width: 900, height: 650), "/tmp/nodraw-editor-host-compact.png")
        ]
        for (size, path) in configurations {
            panel.setFrame(CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size), display: false)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            // Allow the real asynchronous source load, then the shared compositing task. Do not
            // replace this with an injected already-loaded image: this is host lifecycle coverage.
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                if sourcePixelCount(try snapshot(host)) > 1_000 { break }
            }
            try await Task.sleep(for: .milliseconds(200))
            let bitmap = try snapshot(host)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            XCTAssertGreaterThan(png.count, 15_000)
            // The synthetic blue/green source fills the central workspace. A loading spinner or
            // shell-only raster cannot satisfy this; small inspector swatches are insufficient.
            XCTAssertGreaterThan(sourcePixelCount(bitmap), 1_000, "Production source image did not render at \(size)")
            XCTAssertFalse(panel.isKeyWindow)
            XCTAssertFalse(panel.isMainWindow)
            XCTAssertLessThan(panel.frame.maxX, -20_000)
            XCTAssertFalse(session.isDirty)
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmostPID)
        }
        let assetFiles = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("assets").path)
        XCTAssertTrue(assetFiles.isEmpty, "Read-only snapshots must not create extracted assets")
    }

    func testEditorCanvasZoomsAtAnchorWithSourceScaledStrokesOffscreen() async throws {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nodraw-editor-canvas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cgImage = try XCTUnwrap(try syntheticImage().cgImage(forProposedRect: nil, context: nil, hints: nil))
        let sourceURL = directory.appendingPathComponent("source.png")
        try XCTUnwrap(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])).write(to: sourceURL)
        let layer = AnnotationLayer(name: "Marks", shapes: [
            .rectangle(id: UUID(), rect: NormalizedRect(x: 0.18, y: 0.2, width: 0.44, height: 0.38),
                       style: ShapeStyle(strokeColor: 0xFF6B35FF, strokeWidth: 3))
        ])
        let session = AnnotationEditorSession(itemId: UUID(), annotationSet: AnnotationSet(layers: [layer], activeLayerId: layer.id))
        let viewportModel = EditorViewportModel()
        let canvas = ImageEditorCanvas(sourceURL: sourceURL, session: session, viewportModel: viewportModel,
            selectedTool: .constant(.select), currentStyle: .constant(ShapeStyle()), currentTextStyle: .constant(TextStyle(fontSize: 24)),
            selectedShapeID: .constant(nil), eraserMode: .constant(.removeFromMask), eraserBrushSize: .constant(20),
            assetStore: AnnotationAssetStore(assetDirectory: directory.appendingPathComponent("assets", isDirectory: true)))
        let size = CGSize(width: 800, height: 600)
        let host = NSHostingView(rootView: canvas.background(Color.black))
        host.appearance = NSAppearance(named: .darkAqua)
        let panel = EditorSnapshotPanel(contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.contentView = host
        panel.orderBack(nil)
        defer {
            panel.orderOut(nil)
            panel.contentView = nil
            host.removeFromSuperview()
            panel.close()
        }
        host.frame = CGRect(origin: .zero, size: size)

        // Sun center in source pixels (top-left origin) of the synthetic image.
        let sun = CGPoint(x: 555, y: 145)
        func display(_ point: CGPoint, _ viewport: EditorViewport) -> CGPoint {
            CGPoint(x: viewport.origin.x + point.x * viewport.scale, y: viewport.origin.y + point.y * viewport.scale)
        }
        func color(_ bitmap: NSBitmapImageRep, at point: CGPoint) -> NSColor? {
            let factor = CGFloat(bitmap.pixelsWide) / size.width
            return bitmap.colorAt(x: Int(point.x * factor), y: Int(point.y * factor))?.usingColorSpace(.deviceRGB)
        }
        func isSun(_ color: NSColor?) -> Bool {
            guard let color else { return false }
            return color.redComponent > 0.75 && color.greenComponent > 0.55 && color.blueComponent < 0.6
        }
        /// Width, in view points, of the rectangle's orange right edge on one row.
        func strokeRun(_ bitmap: NSBitmapImageRep, row: CGFloat, around x: CGFloat) -> CGFloat {
            let factor = CGFloat(bitmap.pixelsWide) / size.width
            var run = 0
            for px in Int((x - 30) * factor)..<Int((x + 30) * factor) {
                guard let c = bitmap.colorAt(x: px, y: Int(row * factor))?.usingColorSpace(.deviceRGB) else { continue }
                if c.redComponent > 0.8 && c.greenComponent < 0.6 && c.blueComponent < 0.4 { run += 1 }
            }
            return CGFloat(run) / factor
        }

        var bitmap = try snapshot(host)
        for _ in 0..<30 {
            if let viewport = viewportModel.viewport, isSun(color(bitmap, at: display(sun, viewport))) { break }
            try await Task.sleep(for: .milliseconds(100))
            bitmap = try snapshot(host)
        }
        let fitted = try XCTUnwrap(viewportModel.viewport)
        XCTAssertTrue(fitted.isFitted)
        XCTAssertTrue(isSun(color(bitmap, at: display(sun, fitted))), "Fitted canvas did not render the source")

        let anchor = display(sun, fitted)
        viewportModel.update { $0.zoom(to: 3, anchor: anchor) }
        let zoomed = try XCTUnwrap(viewportModel.viewport)
        XCTAssertEqual(zoomed.zoomPercent, 300)
        XCTAssertEqual(display(sun, zoomed).x, anchor.x, accuracy: 0.5, "Zoom must keep the anchored pixel under the pointer")
        XCTAssertEqual(display(sun, zoomed).y, anchor.y, accuracy: 0.5)
        // Right edge of the rectangle (x = 0.62 of 780 px) on a sky row inside the shape.
        let edge = display(CGPoint(x: 0.62 * 780, y: 170), zoomed)
        var run: CGFloat = 0
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            bitmap = try snapshot(host)
            run = strokeRun(bitmap, row: edge.y, around: edge.x)
            if run > 6 { break }
        }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/nodraw-editor-canvas-zoom.png"), options: .atomic)
        XCTAssertTrue(isSun(color(bitmap, at: anchor)), "The anchored subject moved or the zoomed canvas did not render")
        // 3 source px at 300% is 9 pt; the composite is capped at 4096 px, so allow resampling slack.
        XCTAssertEqual(run, 9, accuracy: 2.5, "Committed stroke width should scale with zoom, not stay a fixed screen width")
        // The zoomed document covers the whole viewport, including the corners.
        for corner in [CGPoint(x: 4, y: 4), CGPoint(x: size.width - 4, y: size.height - 4)] {
            let c = try XCTUnwrap(color(bitmap, at: corner))
            XCTAssertGreaterThan(c.greenComponent + c.blueComponent, 0.2, "Viewport corner shows background at 300%")
        }
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmostPID)
    }

    private func snapshot<V: View>(_ host: NSHostingView<V>) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func sourcePixelCount(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.greenComponent > color.redComponent * 1.2,
                   color.blueComponent > color.redComponent * 1.2,
                   color.greenComponent > 0.15 { count += 1 }
            }
        }
        return count
    }

    private func syntheticImage() throws -> NSImage {
        let width = 780, height = 520
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.36, green: 0.52, blue: 0.56, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.89, green: 0.72, blue: 0.45, alpha: 1))
        context.fillEllipse(in: CGRect(x: 510, y: 330, width: 90, height: 90))
        context.setFillColor(CGColor(red: 0.18, green: 0.33, blue: 0.3, alpha: 1))
        context.move(to: CGPoint(x: 0, y: 100)); context.addLine(to: CGPoint(x: 210, y: 300))
        context.addLine(to: CGPoint(x: 470, y: 80)); context.addLine(to: CGPoint(x: 780, y: 280))
        context.addLine(to: CGPoint(x: 780, y: 0)); context.addLine(to: .zero); context.closePath(); context.fillPath()
        context.setFillColor(CGColor(red: 0.11, green: 0.22, blue: 0.23, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 100))
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: width, height: height))
    }
}

@MainActor
private final class EditorSnapshotPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
