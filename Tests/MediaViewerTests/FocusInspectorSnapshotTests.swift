import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import MediaViewer

@MainActor
final class FocusInspectorSnapshotTests: XCTestCase {
    private struct PreviewProbe: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    func testSinglePagePreviewDoesNotReserveCarouselSpace() async throws {
        let image = URL(fileURLWithPath: "/fixture/item.png")
        let context = URL(fileURLWithPath: "/fixture/item.context.png")
        for (files, screenshot, expectedHeight) in [([image], nil, CGFloat(500)),
                                                   ([], context, CGFloat(500)),
                                                   ([image], context, CGFloat(428))] {
            let probe = NSView()
            let preview = FocusPagePreview(mediaFiles: files, contextImage: screenshot,
                selectedIndex: .constant(0)) { PreviewProbe(view: probe) }
            let (window, host) = mount(preview, size: CGSize(width: 800, height: 500))
            await settle(host)
            XCTAssertEqual(probe.bounds.height, expectedHeight, accuracy: 0.01)
            XCTAssertFalse(window.isVisible)
            close(window, host: host)
        }
    }

    func testRelatedOccupiesTheRightHandSingleFocusColumn() async throws {
        let prior = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var preferences = prior
        preferences["showFocusMetadataPanel"] = false
        preferences["showFocusSidebar"] = true
        preferences["tagDefinitions"] = Data("[]".utf8)
        preferences["tagSortOrderMigrated"] = true
        UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }

        let archive = try fixtureArchive()
        let item = makeItem(name: "empty", archive: archive, media: [], context: nil)
        let view = SingleFocusView(item: item, onClose: {}, onItemUpdated: { _ in })
            .environmentObject(AppState())
            .environment(SettingsStore.shared)
        let (window, host) = mount(view, size: CGSize(width: 1_200, height: 800))
        defer { close(window, host: host) }
        await settle(host)
        let split = try XCTUnwrap(descendants(host).compactMap { $0 as? NSSplitView }.first)
        // SwiftUI also installs a narrow divider view inside the AppKit split view.
        let panes = split.subviews.filter { $0.bounds.width > 100 && $0.bounds.height > 100 }
        XCTAssertEqual(panes.count, 2)
        let left = try XCTUnwrap(panes.first)
        let right = try XCTUnwrap(panes.last)
        XCTAssertGreaterThan(left.bounds.width, 400)
        XCTAssertLessThanOrEqual(right.bounds.width, 360)
        XCTAssertGreaterThan(right.convert(right.bounds, to: host).minX,
            left.convert(left.bounds, to: host).midX)
        XCTAssertFalse(window.isVisible)
    }

    func testFiveCarouselCasesRenderOffscreen() async throws {
        let archive = try fixtureArchive()
        let output = try evidenceDirectory()
        let cases: [(String, Int, Bool, Bool, Bool)] = [
            ("one-image", 1, false, false, false),
            ("image-context", 1, false, true, false),
            ("video-context", 1, true, true, true),
            ("gallery-context", 3, false, true, false),
            ("context-only", 0, false, true, true)
        ]
        for (name, count, video, hasContext, prefersContext) in cases {
            let directory = archive.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var files: [URL] = []
            for index in 0..<count {
                let url = directory.appendingPathComponent(count > 1 ? "item_\(index + 1).png" : "item.\(video ? "mp4" : "png")")
                if video { try await writeSilentVideo(to: url) }
                else { try fixtureImage(context: false, variant: index).write(to: url) }
                files.append(url)
            }
            let screenshot = hasContext ? directory.appendingPathComponent("item.context.png") : nil
            if let screenshot { try fixtureImage(context: true).write(to: screenshot) }
            let sidecar = "---\nsource: https://example.com/item\n---\n" +
                (files + (screenshot.map { [$0] } ?? [])).map { "![[\($0.lastPathComponent)]]" }.joined(separator: "\n")
            try sidecar.write(to: directory.appendingPathComponent("item.md"), atomically: true, encoding: .utf8)
            let pages = SingleFocusPagePolicy.pages(mediaFiles: files, contextImage: screenshot)
            let index = SingleFocusPagePolicy.initialPageIndex(mediaCount: files.count,
                hasContextPage: screenshot != nil, prefersContext: prefersContext,
                navigationDirection: .forward)
            let displayedImage = try XCTUnwrap(NSImage(contentsOf: pages[index]))
            // The video fixture initially selects its context page, so no player or audio
            // device is created. The real carousel still decodes its silent video thumbnail.
            let preview = FocusPagePreview(mediaFiles: files, contextImage: screenshot,
                selectedIndex: .constant(index)) {
                Image(nsImage: displayedImage).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(hex: 0x1a1a1a))
            }
            try await capture(preview, size: CGSize(width: 900, height: 600),
                to: output.appendingPathComponent("carousel-\(name).png"))
        }
    }

    func testRelatedInspectorRendersWithAndWithoutAuthor() async throws {
        let archive = try fixtureArchive()
        let output = try evidenceDirectory()
        let urls = try (0..<12).map { index in
            let url = archive.appendingPathComponent("author-\(index).png")
            try fixtureImage(context: false, variant: index).write(to: url)
            return url
        }
        let related = urls.enumerated().map { index, url in
            makeItem(name: "author-\(index)", archive: archive, media: [url], context: nil, author: "Alex")
        }
        for author in ["Alex", nil] as [String?] {
            let item = makeItem(name: "focused", archive: archive, media: [urls[0]], context: nil, author: author)
            let sections = FocusRelatedSections(author: author == nil ? [] : related,
                authorTotal: author == nil ? 0 : 17, folder: [related[0]], tags: [related[1]])
            let inspector = FocusInspectorColumn(showInfo: true, showRelated: true,
                selection: .constant(.related)) {
                Text("Info")
            } related: {
                ScrollView {
                    FocusRelatedContent(item: item, sections: sections, thumbnail: { related in
                        AnyView(Image(nsImage: NSImage(contentsOf: related.mediaFiles[0])!)
                            .resizable().scaledToFill().frame(height: 56).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 4)))
                    })
                }
            }
            try await capture(inspector, size: CGSize(width: 320, height: 600), containsMedia: author != nil,
                to: output.appendingPathComponent(author == nil ? "related-no-author.png" : "related-author.png"))
        }
    }

    private func fixtureArchive() throws -> URL {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["NODRAW_ARCHIVE_PATH"])
        let url = URL(fileURLWithPath: path).appendingPathComponent("focus-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func evidenceDirectory() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let support = try XCTUnwrap(env["NODRAW_APP_SUPPORT_DIR"])
        XCTAssertEqual(AppPaths.appDataDirectory.resolvingSymlinksInPath(),
            URL(fileURLWithPath: support).resolvingSymlinksInPath())
        let url = URL(fileURLWithPath: env["NODRAW_FOCUS_SNAPSHOT_OUT"] ?? support + "/evidence")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeItem(name: String, archive: URL, media: [URL], context: URL?, author: String? = nil) -> MediaItem {
        MediaItem(id: UUID(), basePath: archive.appendingPathComponent(name),
            metadataFile: archive.appendingPathComponent(name + ".md"), mediaFiles: media, contextImage: context,
            metadata: MediaMetadata(source: URL(string: "https://example.com/" + name)!,
                platform: "test", author: author, archivedDate: Date(timeIntervalSince1970: 0)))
    }

    private func mount<V: View>(_ view: V, size: CGSize) -> (NSWindow, NSHostingView<AnyView>) {
        let root = AnyView(view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark))
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        return (window, host)
    }

    private func close(_ window: NSWindow, host: NSHostingView<AnyView>) {
        host.rootView = AnyView(EmptyView())
        window.contentView = nil
        window.close()
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            CATransaction.flush()
        }
    }

    private func capture<V: View>(_ view: V, size: CGSize, containsMedia: Bool = true, to url: URL) async throws {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let (window, host) = mount(view, size: size)
        defer { close(window, host: host) }
        await settle(host)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if containsMedia {
            XCTAssertGreaterThan(coloredPixels(bitmap), 50, "Fixture media must render")
        } else {
            XCTAssertGreaterThan(brightPixels(bitmap), 50, "Inspector text and controls must render")
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
    }

    private func coloredPixels(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if max(color.redComponent, color.greenComponent, color.blueComponent)
                    - min(color.redComponent, color.greenComponent, color.blueComponent) > 0.15 { count += 1 }
            }
        }
        return count
    }

    private func brightPixels(_ bitmap: NSBitmapImageRep) -> Int {
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.4 { count += 1 }
            }
        }
        return count
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func fixtureImage(context: Bool, variant: Int = 0) throws -> Data {
        let canvas = try XCTUnwrap(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8,
            bytesPerRow: 600 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(context ? CGColor(red: 0.13, green: 0.17, blue: 0.22, alpha: 1)
            : CGColor(red: 0.1 + Double(variant % 4) * 0.08, green: 0.62, blue: 0.78, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        canvas.setFillColor(CGColor(red: 0.97, green: 0.6, blue: 0.2, alpha: 1))
        canvas.fill(CGRect(x: 40, y: context ? 310 : 40, width: context ? 520 : 160, height: context ? 45 : 180))
        canvas.setFillColor(CGColor(red: 0.85, green: 0.9, blue: 0.95, alpha: 1))
        for row in 0..<4 {
            canvas.fill(CGRect(x: context ? 40 : 250, y: 230 - row * 40,
                width: context ? 380 : 270, height: 12))
        }
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(canvas.makeImage()))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func writeSilentVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<12 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw try XCTUnwrap(writer.error) }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240,
                kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let canvas = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 320, height: 240,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue))
            canvas.setFillColor(CGColor(red: 0.12, green: 0.65, blue: 0.8, alpha: 1))
            canvas.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            canvas.setFillColor(CGColor(red: 0.97, green: 0.6, blue: 0.2, alpha: 1))
            canvas.fill(CGRect(x: 20 + frame * 5, y: 35, width: 100, height: 150))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }
}
