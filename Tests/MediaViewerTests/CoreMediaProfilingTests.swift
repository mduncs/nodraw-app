import AppKit
import CoreML
import Darwin
import FluidAudio
import GRDB
import PhotoPipeline
import XCTest
@testable import MediaViewer

/// Opt-in processor contention evidence, not a synthetic scheduling benchmark or
/// GUI/startup measurement. No shared thumbnail disk cache is read or cleared.
final class CoreMediaProfilingTests: XCTestCase {
    private static let fixtureDirectory = URL(fileURLWithPath:
        ProcessInfo.processInfo.environment["NODRAW_CORE_PROFILE_FIXTURES"] ?? "performance-fixtures")

    func testPopulatedMediaWorkloadsAgainstShallowBrowsing() async throws {
        guard ProcessInfo.processInfo.environment["NODRAW_CORE_PROFILE"] == "1" else {
            throw XCTSkip("Set NODRAW_CORE_PROFILE=1 for isolated populated media profiling")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nodraw-core-profile-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("ocr.png")
        try await MainActor.run { try Self.renderOCRImage(to: image) }
        let video = root.appendingPathComponent("clip.mp4")
        let speech = root.appendingPathComponent("speech.aiff")
        try FileManager.default.copyItem(at: Self.fixtureDirectory.appendingPathComponent("clip.mp4"), to: video)
        try FileManager.default.copyItem(at: Self.fixtureDirectory.appendingPathComponent("speech.aiff"), to: speech)

        let database = DatabaseManager(databaseURL: root.appendingPathComponent("fixture.sqlite"))
        var start = Self.now()
        try await database.initialize()
        Self.emit(["phase": "isolated_migrations", "elapsed_ms": Self.elapsed(start)])
        let store = MediaStore(database: database)
        var images: [URL] = []
        for index in 0..<48 {
            let copy = root.appendingPathComponent("image-\(index).png")
            try FileManager.default.copyItem(at: image, to: copy)
            images.append(copy)
        }
        let records = (0..<1_024).map { index in
            MediaItemRecord(from: MediaItem(id: UUID(), basePath: root,
                metadataFile: root.appendingPathComponent("item-\(index).md"),
                mediaFiles: [images[index % images.count]],
                metadata: MediaMetadata(source: URL(string: "https://example.invalid/profile/\(index)")!,
                    platform: "profile", notes: "Synthetic profiling item \(index)")))
        }
        start = Self.now()
        // Use real record persistence without tag settings or notification side effects.
        try await database.write { db in
            for record in records { try record.insertWithFTSSync(db: db) }
        }
        Self.emit(["phase": "fixture_seed", "items": records.count, "elapsed_ms": Self.elapsed(start)])

        let cache = ImageCache()
        try await measure("baseline_memory_cold", store: store, cache: cache, images: images, cold: true)
        try await measure("baseline_memory_warm", store: store, cache: cache, images: images, cold: false)

        // Direct CoreML loading has no DownloadUtils recovery/deletion/download
        // branch. Only an isolated copy is loaded; the service gets complete
        // models with their own version, so injection cannot fall back to cache.
        let transcriber = try await prepareCachedTranscriber(root: root)
        for cold in [true, false] {
            let ledger = ProfileWorkLedger()
            let loadedStart = Self.now()
            let workers = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await Self.repeatWork("ocr", limit: 40, ledger: ledger) {
                            let result = try await VisionProcessor.extractOCRWithRegions(from: image)
                            guard result.text?.contains("NoDraw") == true else { throw ProfileError.emptyOCR }
                            return result.blocks.count
                        }
                    }
                    group.addTask {
                        let analyzer = VideoAnalyzer()
                        await Self.repeatWork("video", limit: 8, ledger: ledger) {
                            let result = try await analyzer.analyze(videoURL: video, framesPerSecond: 1)
                            guard result.frameCount > 0 else { throw ProfileError.emptyVideo }
                            return result.frameCount
                        }
                    }
                    if let transcriber {
                        group.addTask {
                            await Self.repeatWork("asr", limit: 3, ledger: ledger) {
                                let result = try await transcriber.transcribe(sourceURL: speech)
                                guard !result.text.isEmpty else { throw ProfileError.emptyASR }
                                return result.tokens.count
                            }
                        }
                    }
                }
            }
            // Explicit admission barrier, not a guessed startup sleep.
            while await ledger.startedCount < (transcriber == nil ? 2 : 3) { await Task.yield() }
            do {
                try await measure(cold ? "loaded_memory_cold" : "loaded_memory_warm",
                    store: store, cache: cache, images: images, cold: cold, ledger: ledger)
            } catch {
                await ledger.stop()
                await workers.value
                throw error
            }
            await ledger.stop()
            await workers.value
            let workload = await ledger.report()
            Self.emit(["phase": cold ? "loaded_cold_work" : "loaded_warm_work",
                "elapsed_ms": Self.elapsed(loadedStart), "work": workload,
                "asr_included": transcriber != nil])
            let errors = await ledger.errors()
            XCTAssertTrue(errors.isEmpty, "Real processor failures are not performance successes: \(errors)")
        }
        await cache.clearMemoryCache()
    }

    private func measure(_ name: String, store: MediaStore, cache: ImageCache, images: [URL], cold: Bool,
                         ledger: ProfileWorkLedger? = nil) async throws {
        await cache.clearMemoryCache()
        if !cold {
            for url in images { _ = await cache.loadThumbnail(from: url) }
        }
        let started = Self.now()
        let cpuStart = Self.cpuSeconds()
        let rssStart = Self.residentBytes()
        var rssMax = rssStart
        var queries: [Double] = []
        var thumbnails: [Double] = []
        var combined: [Double] = []
        var overlapped = 0
        for index in 0..<48 {
            if cold { await cache.clearMemoryCache() }
            if let ledger, await ledger.activeCount > 0 { overlapped += 1 }
            let sample = Self.now()
            var filter = FilterState()
            filter.limit = 64
            filter.offset = (index % 8) * 64
            let items = try await store.fetchItems(filter: filter, includeMLAttributes: false,
                includePerFileOCR: false, includeVideoSegments: false, includeTranscriptSegments: false)
            guard !items.isEmpty else { throw ProfileError.emptyQuery }
            queries.append(Self.elapsed(sample))
            let thumbnailStart = Self.now()
            guard await cache.loadThumbnail(from: images[index % images.count]) != nil else { throw ProfileError.emptyThumbnail }
            thumbnails.append(Self.elapsed(thumbnailStart))
            combined.append(Self.elapsed(sample))
            rssMax = max(rssMax, Self.residentBytes())
        }
        Self.emit(["phase": name, "samples": queries.count,
            "query_ms": Self.percentiles(queries), "thumbnail_ms": Self.percentiles(thumbnails),
            "combined_ms": Self.percentiles(combined), "elapsed_ms": Self.elapsed(started),
            "process_cpu_seconds": Self.cpuSeconds() - cpuStart,
            "rss_start_bytes": rssStart, "rss_end_bytes": Self.residentBytes(), "rss_sampled_max_bytes": rssMax,
            "overlapped_samples": overlapped,
            "cold_definition": "ImageCache memory cleared; URL-only path bypasses shared disk cache; OS file cache not purged"])
    }

    @MainActor
    private static func renderOCRImage(to url: URL) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1000,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1600, height: 1000).fill()
        for line in 0..<12 {
            ("NoDraw archive profiling line \(line): recoverable files and readable notes." as NSString)
                .draw(at: NSPoint(x: 36, y: 45 + line * 74), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func prepareCachedTranscriber(root: URL) async throws -> ParakeetTranscriptionService? {
        let valid = (try? await AsrModels.isModelValid(version: .v3)) == true
        guard valid else {
            Self.emit(["phase": "asr_unavailable", "reason": "Cached AsrModels.v3 absent or invalid; no download attempted"])
            return nil
        }
        let cached = AsrModels.defaultCacheDirectory(for: .v3)
        let clone = root.appendingPathComponent("asr-models")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        let names = [ModelNames.ASR.preprocessorFile, ModelNames.ASR.encoderFile,
                     ModelNames.ASR.decoderFile, ModelNames.ASR.jointV3File, ModelNames.ASR.vocabularyFile]
        var start = Self.now()
        for name in names {
            let source = cached.appendingPathComponent(name)
            let destination = clone.appendingPathComponent(name)
            guard copyfile(source.path, destination.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        Self.emit(["phase": "asr_isolated_clone", "elapsed_ms": Self.elapsed(start)])
        start = Self.now()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        let vocabularyData = try Data(contentsOf: clone.appendingPathComponent(ModelNames.ASR.vocabularyFile))
        let json = try JSONSerialization.jsonObject(with: vocabularyData)
        let vocabulary: [Int: String]
        if let array = json as? [String] { vocabulary = Dictionary(uniqueKeysWithValues: array.enumerated().map { ($0.offset, $0.element) }) }
        else if let dictionary = json as? [String: String] {
            vocabulary = Dictionary(uniqueKeysWithValues: dictionary.compactMap { key, value in Int(key).map { ($0, value) } })
        } else { throw ProfileError.invalidVocabulary }
        let models = try AsrModels(
            encoder: MLModel(contentsOf: clone.appendingPathComponent(ModelNames.ASR.encoderFile), configuration: configuration),
            preprocessor: MLModel(contentsOf: clone.appendingPathComponent(ModelNames.ASR.preprocessorFile), configuration: cpu),
            decoder: MLModel(contentsOf: clone.appendingPathComponent(ModelNames.ASR.decoderFile), configuration: configuration),
            joint: MLModel(contentsOf: clone.appendingPathComponent(ModelNames.ASR.jointV3File), configuration: configuration),
            configuration: configuration, vocabulary: vocabulary, version: .v3)
        Self.emit(["phase": "asr_coreml_load", "elapsed_ms": Self.elapsed(start), "rss_bytes": Self.residentBytes()])
        return ParakeetTranscriptionService(preloadedModels: models)
    }

    private static func repeatWork(_ name: String, limit: Int, ledger: ProfileWorkLedger,
                                  work: @Sendable () async throws -> Int) async {
        await ledger.started()
        for _ in 0..<limit {
            guard !(await ledger.shouldStop) else { break }
            await ledger.begin()
            let start = now()
            do {
                let units = try await work()
                await ledger.finish(name, milliseconds: elapsed(start), units: units, error: nil)
            }
            catch { await ledger.finish(name, milliseconds: elapsed(start), units: 0, error: String(describing: error)); break }
        }
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func elapsed(_ start: UInt64) -> Double { Double(now() - start) / 1_000_000 }
    private static func percentiles(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        return ["p50": sorted[Int(ceil(Double(sorted.count) * 0.50)) - 1],
                "p95": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]]
    }
    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
    private static func emit(_ values: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print("NODRAW_CORE_PROFILE \(line)") }
    }
}

private enum ProfileError: Error { case emptyOCR, emptyVideo, emptyASR, emptyQuery, emptyThumbnail, invalidVocabulary }

private actor ProfileWorkLedger {
    private(set) var activeCount = 0
    private(set) var startedCount = 0
    private(set) var shouldStop = false
    private var results: [[String: String]] = []
    func started() { startedCount += 1 }
    func begin() { activeCount += 1 }
    func stop() { shouldStop = true }
    func finish(_ name: String, milliseconds: Double, units: Int, error: String?) {
        activeCount -= 1
        results.append(["kind": name, "elapsed_ms": String(milliseconds), "units": String(units), "error": error ?? ""])
    }
    func report() -> [[String: String]] { results }
    func errors() -> [String] { results.compactMap { ($0["error"] ?? "").isEmpty ? nil : $0["error"] } }
}
