import AVFoundation
import CoreGraphics
import Darwin
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MediaViewer

final class DuplicateScanBenchmarkTests: XCTestCase {
    private struct Fixture: Encodable {
        let items: Int
        let assets: Int
        let mode: String
        let logicalBytes: Int64
        let imageCounts: [String: Int]
        let videoSizes: [Int64]
        let expectedExact: [[String]]
        let expectedVisual: [[String]]
        let methodology: String
    }

    private struct FoundGroup: Encodable, Equatable {
        let method: String
        let members: [String]
        let visualDistance: Int?
    }

    private struct Sample: Encodable {
        let elapsedSeconds: Double
        let footprintBytes: UInt64
        let progress: String
    }

    private struct Measurement: Encodable {
        let outcome: String
        let wallSeconds: Double
        let itemsPerSecond: Double?
        let baselineFootprintBytes: UInt64
        let peakFootprintBytes: UInt64
        let finalFootprintBytes: UInt64
        let footprintIncreaseBytes: UInt64
        let sampleCount: Int
        let ceilingBytes: UInt64
        let ceilingExceeded: Bool
        let groups: [FoundGroup]
        let cacheEntries: Int
        let modifiedArchiveFiles: [String]
        let error: String?
    }

    private struct Report: Encodable {
        let schemaVersion = 1
        let date = Date()
        let revision: String
        let build: [String: String]
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let configuration: String
        let fixture: Fixture
        let scan: Measurement
        let methodology = "Cold digest cache. Monotonic wall time surrounds detectDuplicates only; generation, DB migration/insertion, group reads and verification are excluded. TASK_VM_INFO phys_footprint sampled on a dedicated background Dispatch queue every 50 ms, including start/end samples. Peak is sampled, not kernel lifetime high-water. Whole XCTest process footprint includes fixture-generation residuals (baseline separately reported). Samples are streamed to samples.jsonl for interrupted-run evidence. A default 1536 MiB ceiling cancels cooperatively to protect the shared host; incomplete scans have no throughput or correctness claim."
    }

    private final class Sampler: @unchecked Sendable {
        private let queue = DispatchQueue(label: "nodraw.dedupe-benchmark.footprint", qos: .utility)
        private lazy var timer = DispatchSource.makeTimerSource(queue: queue)
        private let lock = NSLock()
        private var progress = "Reading archive"
        private var samples: [Sample] = []
        private var exceeded = false
        private var samplingError: String?
        private let stream: FileHandle
        private let start = ProcessInfo.processInfo.systemUptime
        let ceiling: UInt64
        let cancel: @Sendable () -> Void

        init(output: URL, ceiling: UInt64, cancel: @escaping @Sendable () -> Void) throws {
            self.ceiling = ceiling
            self.cancel = cancel
            guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
                throw NSError(domain: "DuplicateScanBenchmark", code: 1)
            }
            stream = try FileHandle(forWritingTo: output)
            timer.setEventHandler { [weak self] in self?.sample() }
            queue.sync { sample() }
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.resume()
        }

        func setProgress(_ value: String) {
            lock.lock(); progress = value; lock.unlock()
        }

        private func sample() {
            // Keep measurement's own Foundation temporaries out of the peak.
            autoreleasepool {
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
                let result = withUnsafeMutablePointer(to: &info) { pointer in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                    }
                }
                guard result == KERN_SUCCESS else {
                    samplingError = "TASK_VM_INFO failed: \(result)"
                    cancel()
                    return
                }
                lock.lock(); let phase = progress; lock.unlock()
                let value = Sample(elapsedSeconds: ProcessInfo.processInfo.systemUptime - start,
                    footprintBytes: info.phys_footprint, progress: phase)
                samples.append(value)
                do {
                    var data = try JSONEncoder().encode(value)
                    data.append(10)
                    try stream.write(contentsOf: data)
                } catch {
                    samplingError = error.localizedDescription
                    cancel()
                }
                if value.footprintBytes > ceiling {
                    if !exceeded {
                        print("DEDUPE_BENCH cancelling at \(value.footprintBytes) bytes (ceiling \(ceiling))")
                    }
                    exceeded = true
                    cancel()
                }
            }
        }

        func stop() throws -> ([Sample], Bool) {
            timer.cancel()
            return try queue.sync {
                sample()
                try stream.close()
                if let samplingError {
                    throw NSError(domain: "DuplicateScanBenchmark", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: samplingError])
                }
                return (samples, exceeded)
            }
        }
    }

    func testDuplicateScanBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["NODRAW_DEDUPE_BENCH"] == "1" else {
            throw XCTSkip("Set NODRAW_DEDUPE_BENCH=1 to run the synthetic duplicate scan benchmark")
        }
        if let count = env["NODRAW_DEDUPE_BENCH_SCALE_ITEMS"].flatMap(Int.init) {
            try await runScaleBenchmark(count: count, environment: env)
            return
        }
        let root = try XCTUnwrap(env["NODRAW_DEDUPE_BENCH_ROOT"]).resolvedDirectory
        let support = try XCTUnwrap(env["NODRAW_APP_SUPPORT_DIR"]).resolvedDirectory
        let archive = try XCTUnwrap(env["NODRAW_ARCHIVE_PATH"]).resolvedDirectory
        let worktree = try XCTUnwrap(env["NODRAW_DEDUPE_BENCH_WORKTREE"]).resolvedDirectory
        // Resolve symlinks before checking isolation; never follow a fixture path to live data.
        for path in [root, support, archive] {
            XCTAssertTrue(path.path.hasPrefix(worktree.path + "/.scratch/"))
            guard path.path.hasPrefix(worktree.path + "/.scratch/") else {
                throw NSError(domain: "DuplicateScanBenchmarkIsolation", code: 1)
            }
        }
        XCTAssertEqual(AppPaths.appDataDirectory.resolvingSymlinksInPath(), support)
        let database = DatabaseManager(databaseURL: support.appendingPathComponent("benchmark.sqlite"))
        try await database.initialize()
        let fixture = try await makeFixture(archive: archive, database: database,
            controlsOnly: env["NODRAW_DEDUPE_BENCH_CONTROLS_ONLY"] == "1")
        let archiveFiles = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        let versionsBefore = try Dictionary(uniqueKeysWithValues: archiveFiles.map { ($0, try DuplicateFileVersion.read($0)) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(fixture).write(to: root.appendingPathComponent("fixture.json"), options: .atomic)
        let beforeCount = try await database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM duplicate_digest_cache")!
        }
        XCTAssertEqual(beforeCount, 0)
        let defaults = UserDefaults.standard
        let oldArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = oldArguments
        arguments["duplicateHashThreshold"] = 6
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain) }
        let detector = DuplicateDetector(db: database)
        let ceiling = UInt64(env["NODRAW_DEDUPE_BENCH_MAX_MIB"] ?? "1536") ?? 1536
        let sampler = try Sampler(output: root.appendingPathComponent("samples.jsonl"), ceiling: ceiling * 1_048_576) {
            Task { await detector.cancelDetection() }
        }
        let monitor = Task {
            while !Task.isCancelled {
                sampler.setProgress(await detector.getProgress().displayText)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        var scanError: Error?
        do { _ = try await detector.detectDuplicates() } catch { scanError = error }
        let seconds = ProcessInfo.processInfo.systemUptime - started
        monitor.cancel()
        sampler.setProgress(await detector.getProgress().displayText)
        let (samples, exceeded) = try sampler.stop()
        let groups = try await detector.fetchAllGroups()
        let named = groups.map { group in
            FoundGroup(method: group.detectionMethod.rawValue, members: group.itemIds.map(Self.name).sorted(),
                visualDistance: group.evidence?.visualDistance)
        }.sorted { "\($0.method):\($0.members)" < "\($1.method):\($1.members)" }
        let cacheCount = try await database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM duplicate_digest_cache")!
        }
        let baseline = try XCTUnwrap(samples.first).footprintBytes
        let peak = samples.map(\.footprintBytes).max() ?? baseline
        let outcome = exceeded ? "memory-ceiling" : scanError == nil ? "completed" : "failed"
        let filesAfter = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        let changedVersions = archiveFiles.filter { (try? DuplicateFileVersion.read($0)) != versionsBefore[$0] }
        let changedEntries = Set(archiveFiles).symmetricDifference(Set(filesAfter))
        let modifiedFiles = Set(changedVersions).union(changedEntries).map(\.lastPathComponent).sorted()
        let measurement = Measurement(outcome: outcome, wallSeconds: seconds,
            itemsPerSecond: outcome == "completed" ? Double(fixture.items) / seconds : nil,
            baselineFootprintBytes: baseline, peakFootprintBytes: peak,
            finalFootprintBytes: try XCTUnwrap(samples.last).footprintBytes,
            footprintIncreaseBytes: peak - baseline, sampleCount: samples.count,
            ceilingBytes: sampler.ceiling, ceilingExceeded: exceeded, groups: named,
            cacheEntries: cacheCount, modifiedArchiveFiles: modifiedFiles, error: scanError.map { String(describing: $0) })
        let buildPath = try XCTUnwrap(env["NODRAW_DEDUPE_BENCH_BUILD_INFO"])
        let build = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: buildPath)))
        try encoder.encode(Report(revision: env["NODRAW_DEDUPE_BENCH_REVISION"] ?? "unknown", build: build,
            configuration: env["NODRAW_DEDUPE_BENCH_CONFIGURATION"] ?? "debug", fixture: fixture, scan: measurement))
            .write(to: root.appendingPathComponent("results.json"), options: .atomic)
        print(String(format: "DEDUPE_BENCH %@ items=%d assets=%d baseline=%.1fMiB peak=%.1fMiB delta=%.1fMiB wall=%.3fs items/s=%@ groups=%d samples=%d",
            outcome, fixture.items, fixture.assets, Double(baseline) / 1_048_576, Double(peak) / 1_048_576,
            Double(peak - baseline) / 1_048_576, seconds,
            measurement.itemsPerSecond.map { String(format: "%.2f", $0) } ?? "unavailable", named.count, samples.count))
        XCTAssertTrue(modifiedFiles.isEmpty, "The scan changed synthetic media or sidecars")
        if exceeded { throw XCTSkip("Scan cancelled at benchmark memory ceiling; measurements saved, results not verified") }
        if let scanError { throw scanError }
        XCTAssertEqual(cacheCount, fixture.assets, "Every declared asset must have been hashed")
        for members in fixture.expectedExact {
            XCTAssertTrue(named.contains { $0.method == "exactDuplicate" && $0.members == members.sorted() }, "Missing exact control \(members)")
        }
        for members in fixture.expectedVisual {
            XCTAssertTrue(named.contains { $0.method == "perceptualHash" && Set(members).isSubset(of: Set($0.members)) }, "Missing visual control \(members)")
        }
    }

    private static func id(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
    }

    private static func name(_ id: UUID) -> String {
        "item-\(Int(id.uuidString.suffix(12))! - 1)"
    }

    private func makeFixture(archive: URL, database: DatabaseManager, controlsOnly: Bool) async throws -> Fixture {
        var records: [MediaItemRecord] = []
        var files: [URL] = []
        var primaryFiles: [Int: URL] = [:]
        var types: [String: Int] = [:]
        func insert(_ index: Int, _ file: URL) throws {
            let sidecar = archive.appendingPathComponent("item-\(index).md")
            try "---\nsource: https://example.com/dedupe/\(index)\nplatform: benchmark\n---\n".write(to: sidecar, atomically: false, encoding: .utf8)
            var media = [file]
            if (60..<240).contains(index), index.isMultiple(of: 2) {
                let original = try XCTUnwrap(primaryFiles[index - 1])
                let second = archive.appendingPathComponent("item-\(index)-secondary.\(original.pathExtension)")
                try FileManager.default.copyItem(at: original, to: second)
                media.append(second)
            }
            let item = MediaItem(id: Self.id(index), basePath: archive, metadataFile: sidecar, mediaFiles: media,
                metadata: MediaMetadata(source: URL(string: "https://example.com/dedupe/\(index)")!, platform: "benchmark",
                    archivedDate: Date(timeIntervalSince1970: 0)))
            records.append(MediaItemRecord(from: item))
            primaryFiles[index] = file
            files.append(contentsOf: media)
            for asset in media { types[asset.pathExtension, default: 0] += 1 }
        }
        let imageIndices = controlsOnly ? [0, 1, 2, 10, 13] : Array(0..<240)
        for index in imageIndices {
            try autoreleasepool {
                let type: UTType = [.jpeg, .png, .heic][index % 3]
                let file = archive.appendingPathComponent("item-\(index).\(type.preferredFilenameExtension!)")
                try makeImage(index: index, type: type, file: file)
                try insert(index, file)
            }
            if index.isMultiple(of: 30) { print("DEDUPE_BENCH fixture images \(index)/240") }
        }
        let gifIndices = controlsOnly ? [] : Array(240..<248)
        for index in gifIndices {
            try autoreleasepool {
                let file = archive.appendingPathComponent("item-\(index).gif")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.gif.identifier as CFString, 4, nil))
                for frame in 0..<4 {
                    let context = try makeContext(width: 640, height: 480, seed: index * 4 + frame)
                    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
                }
                try require(CGImageDestinationFinalize(destination), "GIF generation failed")
                try insert(index, file)
            }
        }
        // Controls precede large videos, so an interrupted baseline still measures image work.
        let copies = [(248, 0), (249, 1), (250, 2)]
        for (index, original) in copies {
            let source = try XCTUnwrap(primaryFiles[original])
            let file = archive.appendingPathComponent("item-\(index).\(source.pathExtension)")
            try FileManager.default.copyItem(at: source, to: file)
            try insert(index, file)
        }
        for (index, original) in [(251, 10), (252, 13)] {
            try autoreleasepool {
                let file = archive.appendingPathComponent("item-\(index).jpg")
                try makeImage(index: original, type: .jpeg, file: file, quality: 0.72)
                try insert(index, file)
            }
        }
        let videoMiB: [Int64] = controlsOnly ? [] : [256, 288, 320, 352, 1152, 1280]
        let sizes = videoMiB.map { $0 * 1_048_576 }
        for (offset, size) in sizes.enumerated() {
            let index = 253 + offset
            let file = archive.appendingPathComponent("item-\(index).mov")
            try await makeVideo(file: file, seed: index, size: size)
            try insert(index, file)
        }
        let inserted = records
        try await database.write { db in
            for record in inserted { try record.insertWithFTSSync(db: db) }
        }
        return Fixture(items: records.count, assets: files.count, mode: controlsOnly ? "controls-only" : "full",
            logicalBytes: try files.reduce(0) { try $0 + DuplicateFileVersion.read($1).size },
            imageCounts: types.filter { $0.key != "mov" }, videoSizes: sizes,
            expectedExact: copies.map { ["item-\($0.0)", "item-\($0.1)"] },
            expectedVisual: [["item-10", "item-251"], ["item-13", "item-252"]],
            methodology: controlsOnly
                ? "Ten single-image items: original indexes 0,1,2,10,13; exact copies 248,249,250; reencoded near-copies 251,252. Same 6000x4000 images, IDs and threshold 6 as full mode. This separate small fixture establishes control groups when the full scan cannot publish within the memory ceiling."
                : "240 distinct 6000x4000 block-textured images (80 each JPEG/PNG/HEIC), 90 secondary image assets in multiasset items, 8 four-frame GIFs, 6 silent valid MOVs padded with sparse free atoms, 3 exact copies and 2 reencoded near-copies. Deterministic UUIDs order images before videos. Direct MediaItemRecord insertion; no import/background indexing. Block textures compress more than photographs. Sparse video padding exercises full-byte hashing, not large-video decoding. Hash threshold 6 is set in a volatile defaults domain; no preferences are written.")
    }

    private func makeContext(width: Int, height: Int, seed: Int) throws -> CGContext {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        var state = UInt64(seed + 1)
        func random() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 32) & 65535) / 65535
        }
        for y in 0..<48 { for x in 0..<64 {
            context.setFillColor(CGColor(red: random(), green: random(), blue: random(), alpha: 1))
            context.fill(CGRect(x: x * width / 64, y: y * height / 48,
                width: width / 64 + 1, height: height / 48 + 1))
        } }
        return context
    }

    private func makeImage(index: Int, type: UTType, file: URL, quality: Double = 0.9) throws {
        let context = try makeContext(width: 6000, height: 4000, seed: index)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "DuplicateScanBenchmarkImage", code: 1)
        }
    }

    private func makeVideo(file: URL, seed: Int, size: Int64) async throws {
        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw try XCTUnwrap(writer.error) }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try autoreleasepool {
                var buffer: CVPixelBuffer?
                try require(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB,
                    nil, &buffer) == kCVReturnSuccess, "Video pixel buffer creation failed")
                let pixels = try XCTUnwrap(buffer)
                CVPixelBufferLockBaseAddress(pixels, [])
                defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
                let row = CVPixelBufferGetBytesPerRow(pixels)
                for y in 0..<180 { for x in 0..<320 {
                    let i = y * row + x * 4
                    base[i] = 255; base[i + 1] = UInt8((x + seed) % 256)
                    base[i + 2] = UInt8((y + frame * 40) % 256); base[i + 3] = UInt8(seed % 256)
                } }
                try require(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 3)), "Video frame append failed")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, "Video writer failed: \(String(describing: writer.error))")
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let start = try handle.seekToEnd()
        var length = UInt32(size - Int64(start)).bigEndian
        var header = withUnsafeBytes(of: &length) { Data($0) }
        header.append(Data("free".utf8))
        try handle.write(contentsOf: header)
        try handle.truncate(atOffset: UInt64(size))
        try handle.seek(toOffset: UInt64(size - 1))
        try handle.write(contentsOf: Data([UInt8(seed % 256)]))
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        try require(tracks.count == 1, "Sparse free atom must preserve a valid video track")
        let duration = try await asset.load(.duration)
        try require(duration.seconds > 0, "Sparse video must have positive duration")
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw NSError(domain: "DuplicateScanBenchmarkFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

private extension String {
    var resolvedDirectory: URL { URL(fileURLWithPath: self).standardizedFileURL.resolvingSymlinksInPath() }
}

extension DuplicateScanBenchmarkTests {
    private struct ScalePlant: Encodable {
        let family: Int
        let original: UUID
        let copy: UUID
        let variants: [UUID]
        let kinds: [String]
        let distances: [Int?]
        let eligible: [Bool]
    }

    private struct ScaleRun: Encodable {
        let name: String
        let wallSeconds: Double
        let baselineMiB: Double
        let peakMiB: Double
        let increaseMiB: Double
        let progress: String
        let error: String?
        let cacheEntries: Int
        let exactFound: Int
        let nearFound: Int
        let nearByKind: [String: Int]
        let falseGroups: Int
        let groups: Int
        let groupSignature: [String]
        let actionAtItem: Int?
    }

    private struct ScaleReport: Encodable {
        let schemaVersion = 2
        let mode = "scale"
        let date = Date()
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let items: Int
        let logicalBytes: Int64
        let configuration: String
        let revision: String
        let plants: [ScalePlant]
        let runs: [ScaleRun]
        let archiveChanged: Bool
        let methodology: String
    }

    private func runScaleBenchmark(count: Int, environment env: [String: String]) async throws {
        guard count >= 1000 && count <= 41000 else {
            throw NSError(domain: "ScaleFixture", code: 1)
        }
        let root = try XCTUnwrap(env["NODRAW_DEDUPE_BENCH_ROOT"]).resolvedDirectory
        let support = try XCTUnwrap(env["NODRAW_APP_SUPPORT_DIR"]).resolvedDirectory
        let archive = try XCTUnwrap(env["NODRAW_ARCHIVE_PATH"]).resolvedDirectory
        let worktree = try XCTUnwrap(env["NODRAW_DEDUPE_BENCH_WORKTREE"]).resolvedDirectory
        for directory in [root, support, archive] {
            guard directory.path.hasPrefix(worktree.path + "/.scratch/") else {
                throw NSError(domain: "ScaleIsolation", code: 1)
            }
        }
        XCTAssertEqual(AppPaths.appDataDirectory.resolvingSymlinksInPath(), support)
        let database = DatabaseManager(databaseURL: support.appendingPathComponent("scale.sqlite"))
        try await database.initialize()
        if env["NODRAW_DEDUPE_BENCH_SCALE_BLANKS"] == "1" {
            try await runBlankScaleBenchmark(count: count, database: database, root: root, archive: archive)
            return
        }
        var state: UInt64 = 0x8123456789abcdef
        func random() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 16
        }
        var positions = Array(0..<count)
        for index in stride(from: count - 1, through: 1, by: -1) {
            positions.swapAt(index, Int(random() % UInt64(index + 1)))
        }
        // The same 80 image families at both sizes. Each family occupies five shuffled UUID ranks.
        let families = 80
        var plants: [ScalePlant] = []
        var plantedFiles: [Int: URL] = [:]
        for family in 0..<families {
            let ranks = Array(positions[(family * 5)..<(family * 5 + 5)])
            let original = archive.appendingPathComponent("item-\(ranks[0]).png")
            try autoreleasepool { try makeScaleImage(seed: 100000 + family, file: original) }
            let copy = archive.appendingPathComponent("item-\(ranks[1]).png")
            try FileManager.default.copyItem(at: original, to: copy)
            let variants = [archive.appendingPathComponent("item-\(ranks[2]).jpg"),
                archive.appendingPathComponent("item-\(ranks[3]).jpg"),
                archive.appendingPathComponent("item-\(ranks[4]).png")]
            try autoreleasepool {
                try makeScaleImage(seed: 100000 + family, file: variants[0], quality: 0.65)
                try makeScaleImage(seed: 100000 + family, file: variants[1], width: 96, height: 72)
                try makeScaleImage(seed: 100000 + family, file: variants[2], brightness: 0.03)
            }
            let base = try XCTUnwrap(DuplicateEvidenceService.visualFingerprint(original))
            let fingerprints = variants.map { DuplicateEvidenceService.visualFingerprint($0) }
            let distances = fingerprints.map { $0.map { (base.hash ^ $0.hash).nonzeroBitCount } }
            let eligible = fingerprints.map { other in
                guard let other else { return false }
                return (base.hash ^ other.hash).nonzeroBitCount <= 6
                    && abs(log(base.aspectRatio / other.aspectRatio)) <= 0.04
                    && abs(base.meanLuminance - other.meanLuminance) <= 0.12
            }
            plants.append(ScalePlant(family: family, original: Self.id(ranks[0]), copy: Self.id(ranks[1]),
                variants: ranks.dropFirst(2).map(Self.id), kinds: ["reencode", "resize", "brightness"],
                distances: distances, eligible: eligible))
            for (rank, file) in zip(ranks, [original, copy] + variants) { plantedFiles[rank] = file }
        }
        var versions: [URL: DuplicateFileVersion] = [:]
        var logicalBytes: Int64 = 0
        // Insert in batches to keep fixture-generation memory independent of collection size.
        for start in stride(from: 0, to: count, by: 500) {
            var records: [MediaItemRecord] = []
            for rank in start..<min(start + 500, count) {
                try autoreleasepool {
                    let file = plantedFiles[rank] ?? archive.appendingPathComponent("item-\(rank).jpg")
                    if plantedFiles[rank] == nil { try makeScaleImage(seed: rank, file: file) }
                    let version = try DuplicateFileVersion.read(file)
                    versions[file] = version
                    logicalBytes += version.size
                    records.append(scaleRecord(rank: rank, file: file, archive: archive))
                }
            }
            let batch = records
            try await database.write { db in
                for record in batch { try record.insertWithFTSSync(db: db) }
            }
            if start.isMultiple(of: 5000) { print("DEDUPE_SCALE fixture \(start)/\(count)") }
        }
        let defaults = UserDefaults.standard
        let oldArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = oldArguments
        arguments["duplicateHashThreshold"] = 6
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain) }
        let detector = DuplicateDetector(db: database)
        let ceiling = (UInt64(env["NODRAW_DEDUPE_BENCH_MAX_MIB"] ?? "400") ?? 400) * 1_048_576
        let addedFile = archive.appendingPathComponent("late-arrival.png")
        try autoreleasepool { try makeScaleImage(seed: 999999, file: addedFile) }
        let lateRecord = scaleRecord(rank: count + 1, file: addedFile, archive: archive)
        let labelByID = Dictionary(uniqueKeysWithValues: plants.flatMap { plant in
            ([plant.original, plant.copy] + plant.variants).map { ($0, plant.family) }
        })

        func measure(_ name: String, action: String? = nil) async throws -> ScaleRun {
            let sampler = try Sampler(output: root.appendingPathComponent("\(name)-samples.jsonl"), ceiling: ceiling) {
                Task { await detector.cancelDetection() }
            }
            let monitor = Task<Int?, Error> {
                var actedAt: Int?
                while !Task.isCancelled {
                    let progress = await detector.getProgress()
                    sampler.setProgress(progress.displayText)
                    if actedAt == nil, action != nil,
                       case .scanning(let phase, let current, let total) = progress,
                       phase == "Verifying media bytes", total > 0, current >= total / 2 {
                        actedAt = current
                        if action == "add" {
                            try await database.write { try lateRecord.insertWithFTSSync(db: $0) }
                        } else { await detector.cancelDetection() }
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                return actedAt
            }
            let started = ProcessInfo.processInfo.systemUptime
            var failure: String?
            do { _ = try await detector.detectDuplicates() }
            catch { failure = error is CancellationError ? "CancellationError" : error.localizedDescription }
            let seconds = ProcessInfo.processInfo.systemUptime - started
            monitor.cancel()
            let actionAt = try await monitor.value
            let progress = await detector.getProgress().displayText
            sampler.setProgress(progress)
            let (samples, exceeded) = try sampler.stop()
            if exceeded { throw NSError(domain: "ScaleMemoryCeiling", code: 1) }
            let groups = try await detector.fetchAllGroups()
            let exact = groups.filter { $0.detectionMethod == .exactDuplicate }
            let visual = groups.filter { $0.detectionMethod == .perceptualHash }
            var nearByKind: [String: Int] = [:]
            var exactFound = 0
            for plant in plants {
                if exact.contains(where: { Set([plant.original, plant.copy]).isSubset(of: Set($0.itemIds)) }) {
                    exactFound += 1
                }
                for (index, variant) in plant.variants.enumerated() {
                    if visual.contains(where: { $0.itemIds.contains(variant)
                        && ($0.itemIds.contains(plant.original) || $0.itemIds.contains(plant.copy)) }) {
                        nearByKind[plant.kinds[index], default: 0] += 1
                    }
                }
            }
            let falseGroups = groups.filter { group in
                let labels = group.itemIds.compactMap { labelByID[$0] }
                return labels.count != group.itemIds.count || Set(labels).count != 1
            }.count
            let cacheCount = try await database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM duplicate_digest_cache")! }
            let baseline = try XCTUnwrap(samples.first).footprintBytes
            let peak = samples.map(\.footprintBytes).max() ?? baseline
            let result = ScaleRun(name: name, wallSeconds: seconds,
                baselineMiB: Double(baseline) / 1_048_576, peakMiB: Double(peak) / 1_048_576,
                increaseMiB: Double(peak - baseline) / 1_048_576,
                progress: progress, error: failure, cacheEntries: cacheCount,
                exactFound: exactFound, nearFound: nearByKind.values.reduce(0, +), nearByKind: nearByKind,
                falseGroups: falseGroups, groups: groups.count,
                groupSignature: groups.map { "\($0.detectionMethod.rawValue):\($0.itemIds.map(\.uuidString).sorted().joined(separator: ","))" }.sorted(),
                actionAtItem: actionAt)
            print(String(format: "DEDUPE_SCALE %@ n=%d wall=%.3fs baseline=%.1fMiB peak=%.1fMiB exact=%d/80 near=%d/240 false=%d cache=%d error=%@",
                name, count, seconds, result.baselineMiB, result.peakMiB, result.exactFound,
                result.nearFound, result.falseGroups, cacheCount, failure ?? "none"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: root.appendingPathComponent("\(name).json"), options: .atomic)
            return result
        }
        var runs = [try await measure("cold"), try await measure("warm")]
        for run in runs {
            XCTAssertNil(run.error)
            XCTAssertEqual(run.exactFound, 80)
            XCTAssertEqual(run.cacheEntries, count)
            XCTAssertGreaterThanOrEqual(run.nearFound, count == 8000 ? 230 : 216)
            XCTAssertEqual(run.falseGroups, 0)
            XCTAssertLessThan(run.peakMiB, 400)
            XCTAssertLessThan(run.wallSeconds, 56)
        }
        XCTAssertEqual(runs[0].groupSignature, runs[1].groupSignature)
        let priorSignature = try XCTUnwrap(runs.last).groupSignature
        // Prior completed groups remain, but force a cold cache to represent interruption of a first scan.
        try await database.write { try $0.execute(sql: "DELETE FROM duplicate_digest_cache") }
        let cancelled = try await measure("cancelled", action: "cancel")
        XCTAssertEqual(cancelled.error, "CancellationError")
        XCTAssertNotNil(cancelled.actionAtItem)
        XCTAssertGreaterThan(cancelled.cacheEntries, 0)
        XCTAssertLessThan(cancelled.cacheEntries, count)
        XCTAssertEqual(cancelled.groupSignature, priorSignature)
        runs.append(cancelled)
        runs.append(try await measure("cancel-rerun"))
        XCTAssertNil(runs.last?.error)
        try await database.write { try $0.execute(sql: "DELETE FROM duplicate_digest_cache") }
        let beforeAddition = try XCTUnwrap(runs.last).groupSignature
        let added = try await measure("added-during-scan", action: "add")
        XCTAssertNotNil(added.actionAtItem)
        XCTAssertNil(added.error)
        XCTAssertEqual(added.cacheEntries, count)
        XCTAssertTrue(added.progress.contains("1 new items arrived; scan again to include them."))
        XCTAssertEqual(added.groupSignature, beforeAddition)
        runs.append(added)
        runs.append(try await measure("addition-rerun"))
        XCTAssertNil(runs.last?.error)
        XCTAssertEqual(runs.last?.cacheEntries, count + 1)
        let changed = versions.contains { (try? DuplicateFileVersion.read($0.key)) != $0.value }
        XCTAssertFalse(changed)
        let report = ScaleReport(items: count, logicalBytes: logicalBytes,
            configuration: env["NODRAW_DEDUPE_BENCH_CONFIGURATION"] ?? "unknown",
            revision: env["NODRAW_DEDUPE_BENCH_REVISION"] ?? "unknown", plants: plants, runs: runs,
            archiveChanged: changed,
            methodology: "80 deterministic random-block 128x96 PNG originals, byte copies, JPEG quality-0.65 reencodes, 96x72 JPEG resizes and +0.03 RGB-brightness PNGs. All 400 planted members occupy deterministic shuffled UUID ranks among independent JPEG distractors. Same pixels/families at both sizes; shuffled positions depend on size. Threshold 6. Near recall requires variant and original or exact copy in the same visual group, accepting either byte-identical representative. False groups contain unrelated families or distractors. Scan wall time excludes fixture generation and result reading. Whole XCTest phys_footprint sampled every 50ms, with fixture residuals included in baseline; ceiling 400MiB by default. Cold refers to digest cache, not OS disk cache. Midpoint actions use 1ms progress polling. Warm/reruns use the same deterministic candidate order. All archive files are deleted after measurement; support DB, ground truth, JSON and streamed samples retained.")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: root.appendingPathComponent("results.json"), options: .atomic)
        for file in try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private func scaleRecord(rank: Int, file: URL, archive: URL) -> MediaItemRecord {
        let item = MediaItem(id: Self.id(rank), basePath: archive,
            metadataFile: archive.appendingPathComponent("item-\(rank).md"), mediaFiles: [file],
            metadata: MediaMetadata(source: URL(string: "https://example.com/scale/\(rank)")!,
                platform: "benchmark", archivedDate: Date(timeIntervalSince1970: 0)))
        return MediaItemRecord(from: item)
    }

    private func makeScaleImage(seed: Int, file: URL, width: Int = 128, height: Int = 96,
                                quality: Double = 0.9, brightness: Double = 0) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        var state = UInt64(seed + 1)
        func color() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(0.15 + 0.7 * Double((state >> 32) & 65535) / 65535 + brightness)
        }
        for y in 0..<6 { for x in 0..<8 {
            context.setFillColor(CGColor(red: color(), green: color(), blue: color(), alpha: 1))
            context.fill(CGRect(x: x * width / 8, y: y * height / 6, width: width / 8, height: height / 6))
        } }
        let type: UTType = file.pathExtension == "png" ? .png : .jpeg
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        try require(CGImageDestinationFinalize(destination), "Scale image generation failed")
    }
}

extension DuplicateScanBenchmarkTests {
    private func runBlankScaleBenchmark(count: Int, database: DatabaseManager, root: URL, archive: URL) async throws {
        let file = archive.appendingPathComponent("blank.png")
        try autoreleasepool {
            let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 96,
                bitsPerComponent: 8, bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 96))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            try require(CGImageDestinationFinalize(destination), "Blank generation failed")
        }
        XCTAssertNil(DuplicateEvidenceService.visualFingerprint(file))
        for start in stride(from: 0, to: count, by: 500) {
            let records = (start..<min(start + 500, count)).map { scaleRecord(rank: $0, file: file, archive: archive) }
            try await database.write { db in
                for record in records { try record.insertWithFTSSync(db: db) }
            }
        }
        let unreadable = archive.appendingPathComponent("unreadable.png")
        try Data("unreadable".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        XCTAssertThrowsError(try FileHandle(forReadingFrom: unreadable))
        let controls = [scaleRecord(rank: count, file: archive.appendingPathComponent("missing.png"), archive: archive),
            scaleRecord(rank: count + 1, file: unreadable, archive: archive)]
        try await database.write { db in
            for record in controls { try record.insertWithFTSSync(db: db) }
        }
        let detector = DuplicateDetector(db: database)
        let sampler = try Sampler(output: root.appendingPathComponent("blank-samples.jsonl"), ceiling: 768 * 1_048_576) {
            Task { await detector.cancelDetection() }
        }
        let monitor = Task {
            while !Task.isCancelled {
                sampler.setProgress(await detector.getProgress().displayText)
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        let found: Int
        do { found = try await detector.detectDuplicates() }
        catch {
            monitor.cancel()
            _ = await monitor.value
            _ = try sampler.stop()
            throw error
        }
        let seconds = ProcessInfo.processInfo.systemUptime - start
        monitor.cancel()
        _ = await monitor.value
        let progress = await detector.getProgress().displayText
        sampler.setProgress(progress)
        let (samples, exceeded) = try sampler.stop()
        XCTAssertFalse(exceeded)
        XCTAssertEqual(found, 1)
        let groups = try await detector.fetchAllGroups()
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.itemIds.count, count)
        XCTAssertEqual(group.detectionMethod, .exactDuplicate)
        let scanOnly: [String: Any] = ["scanSeconds": seconds, "identicalMembers": count,
            "baselineMiB": Double(samples.first!.footprintBytes) / 1_048_576,
            "scanPeakMiB": Double(samples.map(\.footprintBytes).max()!) / 1_048_576,
            "finalProgress": progress]
        try JSONSerialization.data(withJSONObject: scanOnly, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("blank-scan.json"), options: .atomic)
        let store = MediaStore(database: database)
        let service = DuplicateReviewService(database: database, mediaStore: store)
        let reviewSampler = try Sampler(output: root.appendingPathComponent("blank-review-samples.jsonl"), ceiling: 768 * 1_048_576) {
            // Review loading has no cancellation checks. Stop only this isolated test process.
            try? Data("{\"outcome\":\"review-memory-ceiling\",\"ceilingMiB\":768}\n".utf8)
                .write(to: root.appendingPathComponent("review-memory-ceiling.json"), options: .atomic)
            print("DEDUPE_BLANK review memory ceiling; terminating synthetic test process")
            fflush(stdout)
            _exit(77)
        }
        let reviewStart = ProcessInfo.processInfo.systemUptime
        var reviewError: String?
        var reviewItems = 0
        do { reviewItems = try await service.load(groupID: group.id).items.count }
        catch { reviewError = error.localizedDescription }
        let reviewSeconds = ProcessInfo.processInfo.systemUptime - reviewStart
        let (reviewSamples, reviewExceeded) = try reviewSampler.stop()
        XCTAssertFalse(reviewExceeded)
        let report: [String: Any] = [
            "schemaVersion": 2, "mode": "blank-group", "items": count + 2, "identicalMembers": count,
            "scanSeconds": seconds, "scanPeakMiB": Double(samples.map(\.footprintBytes).max()!) / 1_048_576,
            "baselineMiB": Double(samples.first!.footprintBytes) / 1_048_576, "finalProgress": progress,
            "groups": groups.count, "reviewSeconds": reviewSeconds, "reviewItems": reviewItems,
            "reviewError": reviewError.map { $0 as Any } ?? NSNull(),
            "reviewPeakMiB": Double(reviewSamples.map(\.footprintBytes).max()!) / 1_048_576,
            "methodology": "41k independent DB items reference one byte-identical flat PNG to isolate giant exact-group overhead; this does not measure 41k filesystem paths. Additional missing and chmod-000 files must be skipped. No GUI or review decisions. Sampled phys_footprint every 50ms. Review detail materialization is measured separately."
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("results.json"), options: .atomic)
        print("DEDUPE_BLANK \(report)")
        try FileManager.default.removeItem(at: file)
    }
}
