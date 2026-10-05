import AppKit
import ImageIO
import PhotoPipeline
import UniformTypeIdentifiers
import XCTest
@testable import MediaViewer

final class IdleServiceResourceTests: XCTestCase {
    func testPipelineReleasesIndexAndReloadsSameStoreAfterIdle() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = makeAdapter(root: root, delay: .milliseconds(30))
        let first = try await adapter.clipSearch(query: "synthetic")
        XCTAssertTrue(first.isEmpty)
        let loaded = await adapter.resourceDiagnostics()
        XCTAssertTrue(loaded.indexLoaded)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await adapter.resourceDiagnostics().indexLoaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let idle = await adapter.resourceDiagnostics()
        XCTAssertFalse(idle.indexLoaded)
        let second = try await adapter.clipSearch(query: "synthetic")
        XCTAssertEqual(second.count, first.count)
        let reloaded = await adapter.resourceDiagnostics()
        XCTAssertEqual(reloaded.indexLoadCount, 2)
        await adapter.releaseIdleResources()
    }

    func testPressureReleasesPipelineIndexImmediatelyAndKeepsItReloadable() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = makeAdapter(root: root, delay: .seconds(30))
        _ = try await adapter.clipSearch(query: "synthetic")
        await adapter.releaseIdleResources()
        let pressure = await adapter.resourceDiagnostics()
        XCTAssertFalse(pressure.indexLoaded)
        _ = try await adapter.clipSearch(query: "synthetic")
        let reloaded = await adapter.resourceDiagnostics()
        XCTAssertEqual(reloaded.indexLoadCount, 2)
        await adapter.releaseIdleResources()
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(FileManager.default.temporaryDirectory))
            .appendingPathComponent("IdleServiceResourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeAdapter(root: URL, delay: Duration) -> PipelineAdapter {
        PipelineAdapter(database: DatabaseManager(databaseURL: root.appendingPathComponent("unused.sqlite")),
                        idleUnloadDelay: delay, indexFactory: { _ in
            var config = IndexConfiguration.minimal
            config.enableEmbeddingSearch = false
            config.enableSceneClassification = false
            return try SearchIndex(configuration: config, storePath: root.appendingPathComponent("index"))
        })
    }

    private func writeImage(to url: URL) throws {
        let context = CGContext(data: nil, width: 800, height: 800, bitsPerComponent: 8, bytesPerRow: 3_200,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.7, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 800))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
