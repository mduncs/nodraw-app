import AppKit
import Darwin
import ImageIO
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import MediaViewer

#if DEBUG
@MainActor
final class GridScrollBenchmarkTests: XCTestCase {
    private struct Run: Codable {
        let name: String
        let hz: Int
        let stepsMS: [Double]
        let mainCPUMS: [Double]
        let frameIntervalsMS: [Double]
        let mountedTiles: [Int]
        let tileBodies: Int
        let gridBodies: Int
        let prefetchRequests: Int
        let distancePT: Double
        let trackedOffsetPT: Double
        let expectedBottomPT: Double
        let endpointErrorPT: Double
        let emptyViewportSamples: Int
        var metrics: [String: Double] {
            func percentile(_ values: [Double], _ p: Double) -> Double {
                let sorted = values.sorted()
                return sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)]
            }
            let threshold = 1_500 / Double(hz)
            return ["p50MS": percentile(stepsMS, 0.5), "p95MS": percentile(stepsMS, 0.95),
                "p99MS": percentile(stepsMS, 0.99), "maxMS": stepsMS.max() ?? 0,
                "mainCPUP50MS": percentile(mainCPUMS, 0.5), "mainCPUP95MS": percentile(mainCPUMS, 0.95),
                "mainCPUP99MS": percentile(mainCPUMS, 0.99),
                "intervalP95MS": percentile(frameIntervalsMS, 0.95),
                "intervalP99MS": percentile(frameIntervalsMS, 0.99),
                "workHitches": Double(stepsMS.filter { $0 > threshold }.count),
                "cpuHitches": Double(mainCPUMS.filter { $0 > threshold }.count),
                "intervalHitches": Double(frameIntervalsMS.filter { $0 > threshold }.count),
                "mountedMax": Double(mountedTiles.max() ?? 0)]
        }
    }

    private struct Report: Encodable {
        let schemaVersion = 2
        let date = Date()
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let revision = ProcessInfo.processInfo.environment["NODRAW_GRID_BENCH_REVISION"] ?? "unknown"
        let configuration = "debug; hidden 1440x900 pt window; 7600 items; 8 columns; mixed 0.4...2.5 aspects; JPEG files, carousels, video poster tiles"
        let methodology = "Paced at 120/144 Hz with a controlled animation-clock replay; late frames retain the same input/physics sequence. End stops recording when its animation settles. stepsMS is main-thread wall time for input, run-loop turn, layout, display, transaction flush; mainCPUMS is Mach main-thread user+system CPU across the entire paced interval, including async thumbnail completions. frameIntervalsMS includes scheduling lateness and is not compositor FPS. Hitches exceed 1.5 refresh budgets. Cold clears memory, retains OS disk cache and generated JPEG disk thumbnails, settles first viewport; warm repeats the same forward path with bounded production caches retained. Wheel uses real smooth-scroll accumulation/advancement; Page Down/End use real animation; autoscroll injects a local middle-click and fixed pointer displacement into production physics, never moves the mouse. Mount scans are outside work timing but included in CPU/interval measurements. Hidden windows never become key or visible. Video source stubs are never played; bright disk posters decode."
        let runs: [Run]
        let metrics: [[String: Double]]
    }
    @MainActor
    private final class Fixture {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let viewModel: MasonryGridViewModel
        let scroll: NSScrollView
        var parkedOffset: CGFloat?

        init(items: [MediaItem], density: CGFloat = 0, columns: Int = 8) throws {
            viewModel = MasonryGridViewModel()
            viewModel.density = density
            viewModel.setColumnCount(columns)
            viewModel.setContainerWidth(1_424)
            viewModel.setItems(items)
            let grid = MasonryGrid(viewModel: viewModel, useHybridLayout: false,
                showColorBars: true, isBackgrounded: false, onItemSelected: { _ in },
                onItemDoubleClicked: { _ in }, onShowContextMenu: nil, onLoadMore: nil)
            host = NSHostingView(rootView: AnyView(grid.environment(SettingsStore.shared)))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_440, height: 900),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host.frame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
            window.contentView = host
            for _ in 0..<10 { GridScrollBenchmarkTests.process(host) }
            scroll = try XCTUnwrap(GridScrollBenchmarkTests.descendants(host).compactMap { $0 as? NSScrollView }.first,
                "SwiftUI did not create its scroll view in the hidden window")
            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(viewModel.columns.count, columns)
        }

        var bottom: CGFloat {
            max(0, (viewModel.columnHeights.max() ?? 0) + 2 * viewModel.spacing - scroll.contentView.bounds.height)
        }
        func move(to y: CGFloat) {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func park(_ fraction: CGFloat) {
            parkedOffset = bottom * fraction
            move(to: parkedOffset!)
            for _ in 0..<10 { GridScrollBenchmarkTests.process(host) }
        }
        func close() {
            host.rootView = AnyView(EmptyView())
            GridScrollBenchmarkTests.process(host)
            window.contentView = nil
            window.close()
        }
    }


    func testGridScrollBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["NODRAW_GRID_BENCH"] == "1" else {
            throw XCTSkip("Set NODRAW_GRID_BENCH=1 to run the hidden-window grid benchmark")
        }
        // Foundation on this host returns the system temporary directory even with TMPDIR
        // supplied. Keep the large media fixture in the runner's explicit synthetic archive.
        guard let output = env["NODRAW_GRID_BENCH_OUT"], !output.isEmpty else {
            throw XCTSkip("Run scripts/grid-benchmark.sh with its isolated output directory")
        }
        let outputRoot = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(URL(fileURLWithPath: output)))
            .deletingLastPathComponent()
        guard let support = env["NODRAW_APP_SUPPORT_DIR"], !support.isEmpty,
              let home = env["CFFIXED_USER_HOME"], !home.isEmpty,
              let archivePath = env["NODRAW_ARCHIVE_PATH"], !archivePath.isEmpty,
              URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(URL(fileURLWithPath: support)))
                .deletingLastPathComponent().path == outputRoot.path,
              URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(URL(fileURLWithPath: home)))
                .deletingLastPathComponent().path == outputRoot.path,
              URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(URL(fileURLWithPath: archivePath)))
                .deletingLastPathComponent().path == outputRoot.path else {
            throw XCTSkip("Run scripts/grid-benchmark.sh with its isolated data, home and archive directories")
        }
        let dataRoot = AppPaths.appDataDirectory.resolvingSymlinksInPath().deletingLastPathComponent()
        guard dataRoot.path == outputRoot.path else {
            throw XCTSkip("Run scripts/grid-benchmark.sh with its isolated data and temporary directories")
        }
        let archive = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(URL(fileURLWithPath: archivePath)))
            .appendingPathComponent("grid-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: archive) }
        let items = try makeItems(count: 7_600, archive: archive)
        var runs: [Run] = []
        let rates = (env["NODRAW_GRID_BENCH_HZ"] ?? "120,144").split(separator: ",").compactMap { Int($0) }
        let modes = (env["NODRAW_GRID_BENCH_MODES"] ?? "wheel,pageDown,end,autoscroll").split(separator: ",").map(String.init)
        guard !rates.isEmpty, rates.allSatisfy({ [120, 144].contains($0) }),
              !modes.isEmpty, modes.allSatisfy({ ["wheel", "pageDown", "end", "autoscroll"].contains($0) }) else {
            throw failure("Choose 120/144 Hz and wheel/pageDown/end/autoscroll modes")
        }
        for hz in rates {
            for mode in modes {
                await ImageCache.shared.clearMemoryCache()
                let fixture = try Fixture(items: items)
                defer { fixture.close() }
                try await settle(fixture)
                for temperature in ["cold", "warm"] {
                    fixture.park(0)
                    try await settle(fixture)
                    let run = try await scroll(fixture, mode: mode, temperature: temperature, hz: hz)
                    runs.append(run)
                    print("GRID_BENCH \(run.name) hz=\(hz) frames=\(run.stepsMS.count) metrics=\(run.metrics) bodies=\(run.tileBodies)/\(run.gridBodies) distance=\(run.distancePT) empty=\(run.emptyViewportSamples)")
                    XCTAssertGreaterThan(run.distancePT, 900)
                    XCTAssertGreaterThan(run.mountedTiles.max() ?? 0, 0)
                    XCTAssertLessThan(run.mountedTiles.max() ?? 7_600, 7_600)
                    XCTAssertFalse(fixture.window.isVisible)
                }
            }
        }
        if let output = env["NODRAW_GRID_BENCH_OUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(Report(runs: runs, metrics: runs.map(\.metrics)))
                .write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }

    private static func process(_ host: NSView) {
        _ = RunLoop.main.run(mode: .default, before: Date())
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func settle(_ fixture: Fixture) async throws {
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(10))
            Self.process(fixture.host)
        }
        XCTAssertGreaterThan(GridContextClickRouter.shared.registeredViewCount, 0)
        let cache = await ImageCache.shared.retentionSnapshot()
        XCTAssertGreaterThan(cache.liveTrackedItemKeyCount, 0)
    }

    private func mainCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS)
        return Double(info.user_time.seconds + info.system_time.seconds) * 1_000 +
            Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000
    }

    private func middle(_ type: NSEvent.EventType, fixture: Fixture, point: CGPoint) throws -> NSEvent {
        let local = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 0))
        let cg = try XCTUnwrap(local.cgEvent)
        cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(fixture.window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(fixture.window.windowNumber))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    private func scroll(_ fixture: Fixture, mode: String, temperature: String, hz: Int) async throws -> Run {
        let bridge = try XCTUnwrap(Self.descendants(fixture.host).compactMap { $0 as? MiddleMouseAutoScrollView }.first)
        let scroller = bridge.smoothScroller
        scroller.reduceMotion = { false }
        var tileBodies = 0
        var gridBodies = 0
        var prefetchRequests = 0
        MasonryCellDiagnostics.onBody = { _ in tileBodies += 1 }
        MasonryGrid.bodyEvaluationObserver = { gridBodies += 1 }
        MasonryGridScrollRuntime.prefetchRequestObserver = { prefetchRequests += 1 }
        defer {
            MasonryCellDiagnostics.onBody = nil
            MasonryGrid.bodyEvaluationObserver = nil
            MasonryGridScrollRuntime.prefetchRequestObserver = nil
            scroller.cancel()
            scroller.benchmarkTime = nil
            bridge.prepareForViewportCommand()
        }
        let anchor = CGPoint(x: 300, y: 450)
        if mode == "autoscroll" {
            XCTAssertNil(bridge.handleMonitoredEvent(try middle(.otherMouseDown, fixture: fixture, point: anchor)))
            XCTAssertNil(bridge.handleMonitoredEvent(try middle(.otherMouseUp, fixture: fixture, point: anchor)))
            bridge.pauseAutoScrollTickerForBenchmark()
        }
        if let phase = ProcessInfo.processInfo.environment["NODRAW_GRID_BENCH_PHASE"] {
            try "\(getpid()) \(temperature)-\(mode)".write(toFile: phase, atomically: true, encoding: .utf8)
        }
        let seconds = mode == "wheel" ? 12 : 6
        let frameCount = hz * seconds
        let budget = 1 / Double(hz)
        var times: [Double] = [], cpu: [Double] = [], intervals: [Double] = []
        var mounted: [Int] = []
        var empty = 0
        let initialOffset = fixture.scroll.contentView.bounds.minY
        var lastFrame = CACurrentMediaTime()
        var lastCPU = mainCPU()
        var animationTime = ProcessInfo.processInfo.systemUptime
        for frame in 0..<frameCount {
            let start = CACurrentMediaTime()
            animationTime += budget
            scroller.benchmarkTime = animationTime
            autoreleasepool {
                switch mode {
                case "wheel":
                    if frame % max(1, hz / 30) == 0 {
                        scroller.scroll(by: 40, in: fixture.scroll)
                        scroller.pauseFrameTickerForBenchmark()
                    }
                    scroller.advance(at: animationTime)
                case "pageDown":
                    if frame % max(1, hz / 3) == 0 {
                        scroller.scroll(.pageDown, in: fixture.scroll)
                        scroller.pauseFrameTickerForBenchmark()
                    }
                    scroller.advance(at: animationTime)
                case "end":
                    if frame == 0 {
                        scroller.scroll(.last, in: fixture.scroll)
                        scroller.pauseFrameTickerForBenchmark()
                    }
                    scroller.advance(at: animationTime)
                case "autoscroll":
                    bridge.autoScrollTick(at: animationTime, pointer: CGPoint(x: anchor.x, y: anchor.y - 100))
                default: preconditionFailure("Unknown benchmark mode")
                }
                Self.process(fixture.host)
            }
            times.append((CACurrentMediaTime() - start) * 1_000)
            let remaining = budget - (CACurrentMediaTime() - start)
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            mounted.append(GridContextClickRouter.shared.registeredViewCount)
            if frame % hz == hz - 1 || frame == frameCount - 1 || (mode == "end" && !scroller.isAnimating) {
                let anchors = Self.descendants(fixture.host).compactMap { $0 as? RightClickView }
                if anchors.allSatisfy({ $0.visibleRect.isEmpty }) { empty += 1 }
            }
            let now = CACurrentMediaTime()
            let currentCPU = mainCPU()
            intervals.append((now - lastFrame) * 1_000)
            cpu.append(currentCPU - lastCPU)
            lastFrame = now
            lastCPU = currentCPU
            if mode == "end", !scroller.isAnimating { break }
        }
        return Run(name: "\(temperature)-\(mode)", hz: hz, stepsMS: times, mainCPUMS: cpu,
            frameIntervalsMS: intervals, mountedTiles: mounted, tileBodies: tileBodies, gridBodies: gridBodies,
            prefetchRequests: prefetchRequests,
            distancePT: Double(fixture.scroll.contentView.bounds.minY - initialOffset),
            trackedOffsetPT: Double(fixture.viewModel.currentScrollOffset),
            expectedBottomPT: Double(fixture.bottom),
            endpointErrorPT: mode == "end" ? Double(abs(fixture.scroll.contentView.bounds.minY - fixture.bottom)) : 0,
            emptyViewportSamples: empty)
    }
    private func makeItems(count: Int, archive: URL) throws -> [MediaItem] {
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        return try (0..<count).map { index in
            try autoreleasepool {
                let ratio = 0.4 + CGFloat(index % 43) / 42 * 2.1
                let files = (0..<(index % 7 == 0 ? 3 : 1)).map {
                    archive.appendingPathComponent("grid-\(index)-\($0).\(index % 9 == 0 ? "mp4" : "jpg")")
                }
                let item = MediaItem(id: UUID(), basePath: archive,
                    metadataFile: archive.appendingPathComponent("grid-\(index).md"), mediaFiles: files,
                    metadata: MediaMetadata(source: URL(string: "https://example.com/grid/\(index)")!,
                        platform: "test", archivedDate: Date(timeIntervalSince1970: 0), starred: index % 5 == 0),
                    indexedContent: IndexedContent(dominantColors: [.orange, .blue, .green]), aspectRatio: ratio)
                let width = Int(ratio >= 1 ? 400 : 400 * ratio)
                let height = Int(ratio >= 1 ? 400 / ratio : 400)
                let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                for band in 0..<16 {
                    context.setFillColor(CGColor(red: CGFloat((index + band) % 13) / 12,
                        green: CGFloat((index * 3 + band) % 11) / 10, blue: 0.6, alpha: 1))
                    context.fill(CGRect(x: 0, y: band * height / 16, width: width, height: height / 16 + 1))
                }
                let data = NSMutableData()
                let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                    [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw failure("JPEG generation failed") }
                let path = ThumbnailGenerator.thumbnailPath(for: item.id, size: .small,
                    variant: ImageCache.diskCacheVariant(for: item))
                guard path.resolvingSymlinksInPath().path.hasPrefix(AppPaths.appDataDirectory.resolvingSymlinksInPath().path + "/") else {
                    throw failure("Thumbnail path escaped isolated app data")
                }
                try (data as Data).write(to: path)
                for file in files { try (data as Data).write(to: file) }
                return item
            }
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "GridScrollBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
