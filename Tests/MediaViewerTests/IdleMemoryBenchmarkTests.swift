import AppKit
import AVFoundation
import CoreML
import Darwin
import FluidAudio
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MediaViewer

/// Opt-in service benchmark. No application, windows, watcher, or download server.
final class IdleMemoryBenchmarkTests: XCTestCase {
    func testSyntheticLibraryIdleMemory() async throws {
        guard ProcessInfo.processInfo.environment["NODRAW_MEMORY_BENCHMARK"] == "1" else {
            throw XCTSkip("Run scripts/benchmark-idle-memory.sh to profile isolated services")
        }
        let temporaryDirectory = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(FileManager.default.temporaryDirectory))
        let fixtureDirectory = ProcessInfo.processInfo.environment["NODRAW_MEMORY_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0) } ?? temporaryDirectory
        let root = fixtureDirectory
            .appendingPathComponent("IdleMemoryBenchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = ProcessInfo.processInfo.environment["NODRAW_MEMORY_OUTPUT"].map { URL(fileURLWithPath: $0) } ?? root
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = root.appendingPathComponent("fixture.jpg")
        try Self.writeFixture(to: fixture)
        let database = DatabaseManager(databaseURL: root.appendingPathComponent("memory.sqlite"))
        try await database.initialize()
        let count = 7_500
        let pendingCount = Int(ProcessInfo.processInfo.environment["NODRAW_MEMORY_PENDING"] ?? "16") ?? 16
        let ids = (0..<count).map { _ in UUID() }
        let sources = (0..<count).map { root.appendingPathComponent("image-\($0).jpg") }
        let audioID = ProcessInfo.processInfo.environment["NODRAW_MEMORY_ASR_FIXTURE"] == nil ? nil : UUID()
        let audioURL = root.appendingPathComponent("silence.wav")
        var transcriber: ParakeetTranscriptionService?
        if audioID != nil {
            guard let modelPath = ProcessInfo.processInfo.environment["NODRAW_MEMORY_ASR_CACHE"] else {
                throw XCTSkip("ASR requires compatible models in an isolated cache")
            }
            transcriber = try Self.makeTranscriber(modelsURL: URL(fileURLWithPath: modelPath))
            try Self.writeSilentAudio(to: audioURL)
        }
        for source in sources { try FileManager.default.linkItem(at: fixture, to: source) }
        try await database.write { db in
            for index in 0..<count {
                let pending = index < pendingCount
                let media = String(data: try JSONEncoder().encode([sources[index].path]), encoding: .utf8)!
                try db.execute(sql: """
                    INSERT INTO media_items (id, basePathString, metadataFileString, mediaFilesJSON,
                        sourceURL, platform, archivedDate, starred, tagsJSON, parseStatus,
                        ocrText, dominantColorsJSON, perceptualHash, pipeline_status)
                    VALUES (?, ?, ?, ?, 'https://example.invalid', 'synthetic', ?, 0, '[]', 'success', ?, ?, ?, ?)
                    """, arguments: [ids[index].uuidString, root.path, root.appendingPathComponent("item-\(index).md").path,
                                       media, Date(), pending ? nil : "", pending ? nil : "[]",
                                       pending ? nil : "0000000000000000", pending ? "none" : "complete"])
                if !pending {
                    try CLIPVectorRecord(itemId: ids[index], vectorData: Data(repeating: 0, count: 1_536),
                                         version: 1, extractedAt: Date()).save(db)
                }
            }
            if let audioID {
                let media = String(data: try JSONEncoder().encode([audioURL.path]), encoding: .utf8)!
                try db.execute(sql: """
                    INSERT INTO media_items (id, basePathString, metadataFileString, mediaFilesJSON,
                        sourceURL, platform, archivedDate, starred, tagsJSON, parseStatus,
                        ocrText, dominantColorsJSON, perceptualHash, pipeline_status, transcription_status)
                    VALUES (?, ?, ?, ?, 'https://example.invalid', 'synthetic', ?, 0, '[]', 'success',
                        '', '[]', '0000000000000000', 'complete', 'none')
                    """, arguments: [audioID.uuidString, root.path, root.appendingPathComponent("audio.md").path, media, Date()])
            }
        }
        // Same queue construction/shared registration as AppCoordinator; startup scans and
        // watchers are excluded so the benchmark only measures service retention.
        let coordinator = AppCoordinator(database: database, archivePath: root, transcriber: transcriber)
        let vision = await coordinator.getVisionQueue()
        let pipeline = await coordinator.getPipelineQueue()
        let video = await coordinator.getVideoUnderstandingQueue()
        let transcription = await coordinator.getTranscriptionQueue()
        let cache = ImageCache.shared
        var samples: [[String: Any]] = []
        let monitor = Task.detached(priority: .background) { () -> UInt64 in
            var peak: UInt64 = 0
            while !Task.isCancelled {
                let memory = Self.memoryInfo()
                let bytes = memory.phys_footprint
                peak = max(peak, UInt64(max(0, memory.ledger_phys_footprint_peak)))
                if bytes > 2_500_000_000 {
                    fputs("Memory guard: benchmark exceeded 2.5 GB footprint\n", stderr)
                    Darwin.exit(99)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            return peak
        }
        defer { monitor.cancel() }
        samples.append(try await Self.snapshot("services-started", output: output, heap: false))
        await vision.requeueIncomplete()
        await pipeline.requeueIncomplete()
        await video.requeueIncomplete()
        await transcription.requeueIncomplete()
        let started = ContinuousClock.now
        for index in 0..<count {
            _ = await cache.loadThumbnail(itemId: ids[index], from: sources[index], size: .medium)
            if index % 500 == 0 {
                print("MEMORY thumbnails=\(index) footprint_mb=\(Double(Self.footprint()) / 1_048_576)")
            }
        }
        try await Self.waitForJobs(database: database, vision: vision, pipeline: pipeline)
        samples.append(try await Self.snapshot("jobs-finished", output: output, heap: true))
        try await Task.sleep(for: .seconds(35))
        samples.append(try await Self.snapshot("idle", output: output, heap: true))
        let reloadStart = ContinuousClock.now
        let firstID = ids[0]
        try await database.write { db in
            try db.execute(sql: "UPDATE media_items SET pipeline_status = 'none' WHERE id = ?", arguments: [firstID.uuidString])
        }
        if let audioID { await transcription.enqueue(itemId: audioID, force: true) }
        await pipeline.enqueue(itemId: firstID)
        _ = try await VisionProcessor.extractOCR(from: fixture)
        try await Self.waitForJobs(database: database, vision: vision, pipeline: pipeline)
        let reloadSeconds = Self.seconds(reloadStart.duration(to: .now))
        samples.append(try await Self.snapshot("first-use-after-idle", output: output, heap: false))
        try await Task.sleep(for: .seconds(35))
        samples.append(try await Self.snapshot("idle-after-reload", output: output, heap: false))
        monitor.cancel()
        let peak = await monitor.value
        let completedAudioJobs = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE transcription_status = 'complete'") ?? 0
        }
        let result: [String: Any] = ["pid": getpid(), "items": count, "pendingMLItems": pendingCount,
                                     "media": "synthetic 800x800 JPEG; optional 2-second silent WAV; no video", "samples": samples,
                                     "completedAudioItems": completedAudioJobs,
                                     "peakFootprintMB": Double(peak) / 1_048_576, "reloadJobSeconds": reloadSeconds,
                                     "elapsedSeconds": Self.seconds(started.duration(to: .now)), "fixtureRoot": root.path]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("results.json"))
        print("MEMORY results=\(output.path) peak_mb=\(Double(peak) / 1_048_576) reload_job_s=\(reloadSeconds)")
        await vision.pause()
        await pipeline.pause()
        await video.pause()
        await transcription.pause()
        withExtendedLifetime(coordinator) {}
    }

    private static func waitForJobs(database: DatabaseManager, vision: VisionJobQueue, pipeline: PipelineQueue) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(600))
        var quiet = 0
        while ContinuousClock.now < deadline {
            let remaining = try await database.read { db in
                let failed = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM media_items WHERE pipeline_status = 'failed' OR transcription_status = 'failed'
                    """) ?? 0
                if failed > 0 { throw NSError(domain: "IdleMemoryBenchmark.failedJobs", code: failed) }
                return try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM media_items WHERE pipeline_status != 'complete'
                        OR transcription_status IN ('none', 'processing') AND mediaFilesJSON LIKE '%.wav%'
                    """) ?? 0
            }
            let status = await vision.diagnostics
            let pipelineStatus = await pipeline.currentStatus
            if remaining == 0 && status.processing == 0 && status.residentPending == 0 && !status.loading && !status.refillNeeded && pipelineStatus.isIdle {
                quiet += 1
                if quiet >= 3 { return }
            } else { quiet = 0 }
            try await Task.sleep(for: .seconds(1))
        }
        XCTFail("Synthetic ML jobs did not complete; inspect isolated logs")
        throw NSError(domain: "IdleMemoryBenchmark", code: 1)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func footprint() -> UInt64 { memoryInfo().phys_footprint }

    private static func memoryInfo() -> task_vm_info_data_t {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : task_vm_info_data_t()
    }

    private static func snapshot(_ phase: String, output: URL, heap: Bool) async throws -> [String: Any] {
        let memory = memoryInfo()
        let bytes = memory.phys_footprint
        print("MEMORY phase=\(phase) pid=\(getpid()) footprint_mb=\(Double(bytes) / 1_048_576)")
        let tools: [(String, [String])] = [("footprint", ["-v", "\(getpid())"]), ("vmmap", ["--summary", "\(getpid())"])]
            + (heap ? [("heap", ["-s", "\(getpid())"])] : [])
        var exits: [String: Int32] = [:]
        for (name, arguments) in tools {
            let file = output.appendingPathComponent("\(phase)-\(name).txt")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/\(name)")
            process.arguments = arguments
            process.standardOutput = handle
            process.standardError = handle
            try await Task.detached(priority: .background) {
                try process.run()
                process.waitUntilExit()
            }.value
            try handle.close()
            exits[name] = process.terminationStatus
        }
        return ["phase": phase, "footprintMB": Double(bytes) / 1_048_576,
                "peakFootprintMB": Double(memory.ledger_phys_footprint_peak) / 1_048_576,
                "neuralNoFootprintMB": Double(memory.ledger_tag_neural_nofootprint + memory.ledger_tag_neural_nofootprint_compressed) / 1_048_576,
                "compressedMB": Double(memory.compressed) / 1_048_576, "toolExitStatus": exits]
    }

    private static func writeFixture(to url: URL) throws {
        try autoreleasepool {
            let side = 800
            var pixels = [UInt8](repeating: 255, count: side * side * 4)
            for y in 0..<side {
                for x in 0..<side {
                    let offset = (y * side + x) * 4
                    pixels[offset] = UInt8((x + y) % 256)
                    pixels[offset + 1] = UInt8((x / 4) % 256)
                    pixels[offset + 2] = UInt8((y / 4) % 256)
                }
            }
            let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let image = context.makeImage()!
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "JPEG", code: 1) }
        }
    }

    private static func writeSilentAudio(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func makeTranscriber(modelsURL: URL) throws -> ParakeetTranscriptionService {
        let models = try loadModels(from: modelsURL)
        if ProcessInfo.processInfo.environment["NODRAW_MEMORY_LEGACY_ASR"] == "1" {
            // A preloaded service without a reload factory preserves the original lifetime.
            return ParakeetTranscriptionService(preloadedModels: models)
        }
        return ParakeetTranscriptionService(preloadedModels: models, reloadManager: {
            AsrManager(config: ASRConfig(parallelChunkConcurrency: 1, streamingEnabled: true, streamingThreshold: 480_000),
                       models: try loadModels(from: modelsURL))
        })
    }

    private static func loadModels(from directory: URL) throws -> AsrModels {
        let started = ContinuousClock.now
        defer { print("MEMORY asr_model_load_seconds=\(seconds(started.duration(to: .now)))") }
        let configuration = AsrModels.defaultConfiguration()
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)))
        let vocabulary: [Int: String]
        if let array = json as? [String] {
            vocabulary = Dictionary(uniqueKeysWithValues: array.enumerated().map { ($0.offset, $0.element) })
        } else if let dictionary = json as? [String: String] {
            vocabulary = Dictionary(uniqueKeysWithValues: dictionary.compactMap { key, value in Int(key).map { ($0, value) } })
        } else { throw NSError(domain: "IdleMemoryBenchmark.vocabulary", code: 1) }
        return try AsrModels(
            encoder: MLModel(contentsOf: directory.appendingPathComponent(ModelNames.ASR.encoderFile), configuration: configuration),
            preprocessor: MLModel(contentsOf: directory.appendingPathComponent(ModelNames.ASR.preprocessorFile), configuration: cpu),
            decoder: MLModel(contentsOf: directory.appendingPathComponent(ModelNames.ASR.decoderFile), configuration: configuration),
            joint: MLModel(contentsOf: directory.appendingPathComponent(ModelNames.ASR.jointV3File), configuration: configuration),
            configuration: configuration, vocabulary: vocabulary, version: .v3)
    }
}
