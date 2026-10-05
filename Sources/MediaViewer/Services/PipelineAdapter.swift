import AVFoundation
import Foundation
import GRDB
import ImageIO
import PhotoPipeline
import Vision

// MARK: - Pipeline Adapter

/// Bridges the photo pipeline library's SearchIndex API to our GRDB storage.
/// Converts pipeline results (AssetAnalysis) into media_attributes rows and clip_vectors.
actor PipelineAdapter {

    private let database: DatabaseManager
    private var searchIndex: SearchIndex?
    private var cachedAnalysis: [UUID: AssetAnalysis] = [:]
    private let idleUnloadDelay: Duration
    private let indexFactory: (@Sendable (URL) throws -> SearchIndex)?
    private var idleUnloadTask: Task<Void, Never>?
    private var activeOperations = 0
    private var idleGeneration: UInt64 = 0
    private var releaseWhenIdle = false
    private var indexLoadCount = 0

    struct ResourceDiagnostics: Sendable {
        let indexLoaded: Bool
        let activeOperations: Int
        let cachedAnalysisCount: Int
        let indexLoadCount: Int
    }

    func resourceDiagnostics() -> ResourceDiagnostics {
        ResourceDiagnostics(indexLoaded: searchIndex != nil, activeOperations: activeOperations,
                            cachedAnalysisCount: cachedAnalysis.count, indexLoadCount: indexLoadCount)
    }

    private struct ClipBackfillCandidate: Sendable {
        let id: UUID
        let mediaPaths: [String]
        let contextPath: String?
    }

    private static let clipBackfillBatchLimit = 24
    private static let stillImageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jp2", "jpeg", "jpg",
        "png", "tif", "tiff", "webp"
    ]

    /// Pipeline config persisted as JSON in app support
    private static var configURL: URL {
        AppPaths.appDataDirectory.appendingPathComponent("pipeline-config.json")
    }

    /// Free-text search reloads the index and its text model, so the delay is long enough
    /// that a pause while searching doesn't pay for a reload; memory pressure still releases at once.
    init(database: DatabaseManager = .shared, idleUnloadDelay: Duration = .seconds(300),
         indexFactory: (@Sendable (URL) throws -> SearchIndex)? = nil) {
        self.database = database
        self.idleUnloadDelay = idleUnloadDelay
        self.indexFactory = indexFactory
    }

    deinit { idleUnloadTask?.cancel() }

    private func beginOperation() {
        activeOperations += 1
        idleGeneration &+= 1
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private func endOperation() {
        activeOperations -= 1
        guard activeOperations == 0 else { return }
        if releaseWhenIdle {
            releaseIdleResources()
            return
        }
        scheduleIdleUnload()
    }

    private func scheduleIdleUnload() {
        let generation = idleGeneration
        let delay = idleUnloadDelay
        idleUnloadTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.unloadIfStillIdle(generation: generation)
        }
    }

    private func unloadIfStillIdle(generation: UInt64) {
        guard generation == idleGeneration else { return }
        releaseIdleResources()
    }

    /// Phase results are already persisted and can be read again after unloading.
    func releaseIdleResources() {
        idleGeneration &+= 1
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        guard activeOperations == 0 else {
            releaseWhenIdle = true
            return
        }
        releaseWhenIdle = false
        do {
            try searchIndex?.flushEmbeddings()
        } catch {
            // VectorStore only persists at flush; keep the index if that write fails.
            logWarning("PipelineAdapter: retaining index after embedding flush failed: \(error)")
            scheduleIdleUnload()
            return
        }
        searchIndex = nil
        cachedAnalysis.removeAll()
    }

    func discardAnalysis(itemId: UUID) {
        cachedAnalysis[itemId] = nil
    }

    // MARK: - Lazy Initialization

    /// Get or create the SearchIndex; reload its persisted store on demand.
    private func getIndex() throws -> SearchIndex {
        guard !BackgroundQAConfiguration.isEnabled else { throw BackgroundQAConfiguration.ConfigurationError.maintenanceSuppressed }
        if let existing = searchIndex { return existing }

        let storePath = AppPaths.appDataDirectory.appendingPathComponent("pipeline-store", isDirectory: true)
        try FileManager.default.createDirectory(at: storePath, withIntermediateDirectories: true)

        let config = loadConfig()
        let index = try indexFactory?(storePath) ?? SearchIndex(configuration: config, storePath: storePath)
        self.searchIndex = index
        indexLoadCount += 1
        logInfo("PipelineAdapter: SearchIndex initialized")
        return index
    }

    // MARK: - Configuration

    private func loadConfig() -> IndexConfiguration {
        if let data = try? Data(contentsOf: Self.configURL),
           let config = try? JSONDecoder().decode(IndexConfiguration.self, from: data) {
            return config
        }
        // Face gallery uses private VisualUnderstanding APIs that crash on some macOS versions.
        // Disable until VUWGallery compatibility is resolved.
        var config = IndexConfiguration.full
        config.enableFaceGallery = false
        config.enableFaceAttributes = false
        return config
    }

    func saveConfig(_ config: IndexConfiguration) throws {
        let data = try JSONEncoder().encode(config)
        try data.write(to: Self.configURL)
    }

    // MARK: - Phase 1: Embeddings + Scene

    /// Run full pipeline: index image, extract analysis once, store in two phases.
    /// SearchIndex.index() runs all ML modules atomically — the phase split is
    /// purely for storage (phase 1 = embeddings+scene, phase 2+3 = everything else).
    func runPhase1(itemId: UUID) async throws {
        beginOperation()
        defer { endOperation() }
        let imageURL = try await getImageURL(itemId: itemId)
        guard let cgImage = loadCGImage(from: imageURL) else {
            throw PipelineError.imageLoadFailed(imageURL.path)
        }

        let index = try getIndex()
        let result = try await index.index(image: cgImage, assetID: itemId.uuidString)

        if !result.failures.isEmpty {
            logWarning("PipelineAdapter: index failures for \(itemId): \(result.failures)")
        }

        // Load only the item just indexed. allAnalysis() walks every historical asset and every
        // per-module JSON file, which made one new item scale with the entire library.
        guard let analysis = index.analysis(for: itemId.uuidString) else {
            throw PipelineError.noResults
        }

        try await storePhase1Results(itemId: itemId, analysis: analysis, image: cgImage)
        cachedAnalysis[itemId] = analysis
    }

    // MARK: - Phase 2+3: Full Analysis

    func runPhase2And3(itemId: UUID) async throws {
        beginOperation()
        defer { endOperation() }
        // Use cached analysis from phase 1 — avoids O(N) allAnalysis() re-scan
        guard let analysis = cachedAnalysis.removeValue(forKey: itemId) else {
            // Fallback: re-extract if cache miss (e.g., resumed from phase1 status)
            let index = try getIndex()
            guard let a = index.analysis(for: itemId.uuidString) else {
                throw PipelineError.noResults
            }
            try await storeFullResults(itemId: itemId, analysis: a)
            return
        }

        try await storeFullResults(itemId: itemId, analysis: analysis)
    }

    // MARK: - CLIP Vector Backfill

    /// Backfill CLIP vectors for completed pipeline items that are missing them.
    /// Extracts sceneprint directly via Vision — no SearchIndex needed.
    @discardableResult
    func backfillClipVectors(limit: Int = clipBackfillBatchLimit) async -> Int {
        let missing: [ClipBackfillCandidate]
        do {
            missing = try await database.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT mi.id, mi.mediaFilesJSON, mi.contextImageString
                    FROM media_items mi
                    WHERE mi.pipeline_status = 'complete'
                      AND mi.id NOT IN (SELECT itemId FROM clip_vectors)
                    ORDER BY mi.originalDate DESC
                """)
                return rows.compactMap { row -> ClipBackfillCandidate? in
                    guard let idStr: String = row["id"],
                          let id = UUID(uuidString: idStr) else { return nil }
                    let json: String = row["mediaFilesJSON"]
                    let ctx: String? = row["contextImageString"]
                    let paths = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
                    return ClipBackfillCandidate(id: id, mediaPaths: paths, contextPath: ctx)
                }
            }
        } catch {
            logError("PipelineAdapter: backfill query failed: \(error)")
            return 0
        }

        guard !missing.isEmpty else { return 0 }

        // Select after checking source viability so a stale prefix cannot pin every launch to the
        // same failed page. Automatic maintenance intentionally avoids video decoding; video-only
        // recovery belongs in an explicit batch operation, not the interactive startup path.
        let eligible = missing.compactMap { candidate -> (UUID, URL)? in
            guard let source = Self.preferredExistingStillURL(
                mediaPaths: candidate.mediaPaths,
                contextPath: candidate.contextPath
            ) else { return nil }
            return (candidate.id, source)
        }
        let batch = Array(eligible.prefix(max(0, limit)))
        guard !batch.isEmpty else {
            logInfo("PipelineAdapter: CLIP backfill skipped — no existing still sources among \(missing.count) missing vectors")
            return 0
        }

        logInfo(
            "PipelineAdapter: backfilling CLIP vectors for \(batch.count) existing stills " +
            "(\(missing.count) missing, \(eligible.count) eligible)"
        )

        var filled = 0
        for (itemId, url) in batch {
            guard !Task.isCancelled else { break }

            // Keep maintenance dormant during direct manipulation and scrolling. The queue also
            // cancels this task when foreground work arrives; this check covers interactions that
            // begin between individual candidates.
            while AppInteractionMonitor.shared.shouldSuspendBackgroundProcessing() {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return filled
                }
            }

            guard let cgImage = loadCGImage(from: url, maxPixelDimension: 1_024) else {
                logWarning("PipelineAdapter: CLIP backfill could not decode still source \(url.lastPathComponent)")
                continue
            }
            guard let vector = extractSceneprint(from: cgImage) else { continue }
            guard vector.count == CLIPVectorRecord.dimension else { continue }

            do {
                try await database.write { db in
                    let record = CLIPVectorRecord.create(from: vector, itemId: itemId)
                    try record.save(db)
                }
                filled += 1
            } catch {
                logWarning("PipelineAdapter: backfill save failed for \(itemId): \(error)")
            }
        }

        logInfo("PipelineAdapter: backfilled \(filled)/\(batch.count) CLIP vectors")
        return filled
    }

    // MARK: - Text Search

    /// Search using CLIP text-to-image similarity.
    /// Returns (itemId, score) pairs sorted by relevance.
    func clipSearch(query: String, limit: Int = 20) async throws -> [(itemId: UUID, score: Float)] {
        beginOperation()
        defer { endOperation() }
        let index = try getIndex()
        let results = try await index.search(query, limit: limit)

        return results.compactMap { result in
            guard let id = UUID(uuidString: result.assetID) else { return nil }
            return (itemId: id, score: result.score)
        }
    }

    // MARK: - Result Storage

    private func storePhase1Results(itemId: UUID, analysis: AssetAnalysis, image: CGImage) async throws {
        // Extract embedding before entering DB closure (actor-isolated)
        var embeddingVector: [Float]?

        // Try SearchIndex cache first
        do {
            embeddingVector = try searchIndex?.getEmbedding(assetID: itemId.uuidString)
        } catch {
            logWarning("PipelineAdapter: getEmbedding threw for \(itemId): \(error)")
        }

        // Fallback: extract sceneprint directly via Vision
        if embeddingVector == nil {
            logInfo("PipelineAdapter: SearchIndex cache miss for \(itemId), extracting sceneprint directly")
            embeddingVector = extractSceneprint(from: image)
        }

        if embeddingVector == nil {
            logWarning("PipelineAdapter: no embedding available for \(itemId)")
        }

        try await database.write { db in
            var attrs: [MediaAttribute] = []

            // Scene labels
            for scene in analysis.sceneLabels {
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .scene,
                    key: scene.label,
                    value: Double(scene.confidence)
                ))
            }

            // Aesthetics / curation
            attrs.append(MediaAttribute(
                itemId: itemId,
                module: .quality,
                key: "aesthetics",
                value: Double(analysis.aestheticsScore)
            ))

            // Junk flag
            attrs.append(MediaAttribute(
                itemId: itemId,
                module: .junk,
                key: "is_junk",
                value: analysis.isJunk ? 1.0 : 0.0
            ))

            if let junkConf = analysis.junkConfidence {
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .junk,
                    key: "confidence",
                    value: Double(junkConf)
                ))
            }

            try MediaAttribute.upsertBatch(attrs, db: db)

            // Store sceneprint embedding to clip_vectors (captured before closure)
            if let embedding = embeddingVector, embedding.count == CLIPVectorRecord.dimension {
                let record = CLIPVectorRecord.create(from: embedding, itemId: itemId)
                try record.save(db)
            }
        }
    }

    private func storeFullResults(itemId: UUID, analysis: AssetAnalysis) async throws {
        try await database.write { db in
            var attrs: [MediaAttribute] = []

            // Objects
            for obj in analysis.objectRecognitions {
                var metadataJSON: String?
                if let box = obj.boundingBox {
                    metadataJSON = String(format: "{\"x\":%.4f,\"y\":%.4f,\"w\":%.4f,\"h\":%.4f}",
                                          box.origin.x, box.origin.y, box.size.width, box.size.height)
                }

                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .object,
                    key: obj.name,
                    value: Double(obj.confidence),
                    metadata: metadataJSON
                ))
            }

            // Faces
            if analysis.faceCount > 0 {
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .face,
                    key: "count",
                    value: Double(analysis.faceCount)
                ))
            }

            // Face attributes
            for faceAttr in analysis.faceAttributes {
                let encoder = JSONEncoder()
                let metadataJSON = (try? encoder.encode(faceAttr))
                    .flatMap { String(data: $0, encoding: .utf8) }
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .face,
                    key: "attributes",
                    value: 1.0,
                    metadata: metadataJSON
                ))
            }

            // Safety
            if let safety = analysis.safetyResult {
                let categories = safety.categories.map { cat in
                    MediaAttribute(
                        itemId: itemId,
                        module: .safety,
                        key: cat.label,
                        value: Double(cat.confidence)
                    )
                }
                try Self.storeSafetyAttributes(categories, itemId: itemId, db: db)
            }

            // Quality
            if let quality = analysis.qualityResult {
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .quality,
                    key: "is_sharp",
                    value: quality.isSharp ? 1.0 : 0.0
                ))
                if let blur = quality.blurScore {
                    attrs.append(MediaAttribute(
                        itemId: itemId,
                        module: .quality,
                        key: "blur_score",
                        value: Double(blur)
                    ))
                }
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .quality,
                    key: "is_well_exposed",
                    value: quality.isWellExposed ? 1.0 : 0.0
                ))
            }

            // Meme
            if let meme = analysis.memeResult {
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .meme,
                    key: "is_meme",
                    value: meme.isMeme ? 1.0 : 0.0
                ))
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .meme,
                    key: "confidence",
                    value: Double(meme.memeConfidence)
                ))
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .meme,
                    key: "environment",
                    value: 1.0,
                    metadata: "\"\(meme.environment.rawValue)\""
                ))
            }

            // Curation score
            if let curation = analysis.curationScore {
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .curation,
                    key: "score",
                    value: Double(curation)
                ))
            }

            // Caption
            if let caption = analysis.caption {
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .caption,
                    key: "text",
                    value: 1.0,
                    metadata: caption.caption
                ))

                // Also write caption to FTS for search
                try self.addCaptionToFTS(db: db, itemId: itemId, caption: caption.caption)
            }

            // Body pose
            if let pose = analysis.bodyPoses, !pose.bodies.isEmpty {
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .bodyPose,
                    key: "person_count",
                    value: Double(pose.bodies.count)
                ))
            }

            // Animal
            if let animal = analysis.animalAnalysis {
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .animal,
                    key: "detected",
                    value: 1.0,
                    metadata: (try? JSONEncoder().encode(animal))
                        .flatMap { String(data: $0, encoding: .utf8) }
                ))
            }

            // Documents
            for doc in analysis.documents {
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .document,
                    key: "detected",
                    value: 1.0,
                    metadata: (try? JSONEncoder().encode(doc))
                        .flatMap { String(data: $0, encoding: .utf8) }
                ))
            }

            // Barcodes
            for barcode in analysis.barcodes {
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .barcode,
                    key: barcode.symbology,
                    value: Double(barcode.confidence),
                    metadata: barcode.payload
                ))
            }

            // Fingerprint
            if analysis.fingerprint != nil {
                attrs.append(MediaAttribute(
                    itemId: itemId,
                    module: .fingerprint,
                    key: "has_fingerprint",
                    value: 1.0
                ))
            }

            try MediaAttribute.upsertBatch(attrs, db: db)
        }
    }

    // MARK: - Caption → FTS

    private nonisolated func addCaptionToFTS(db: Database, itemId: UUID, caption: String) throws {
        // UPDATE triggers automatic FTS sync via content-synced triggers (migration 24)
        try db.execute(
            sql: "UPDATE media_items SET generatedCaption = ? WHERE id = ?",
            arguments: [caption, itemId.uuidString]
        )
    }

    // MARK: - Helpers

    nonisolated static func storeSafetyAttributes(_ categories: [MediaAttribute], itemId: UUID, db: Database) throws {
        // Replace the module so a later result cannot leave stale category flags behind.
        try MediaAttribute.deleteModule(db: db, itemId: itemId, module: .safety)
        try MediaAttribute.upsertBatch(SafetyAttributes.canonicalize(categories, itemId: itemId), db: db)
    }

    private func getImageURL(itemId: UUID) async throws -> URL {
        let url: URL? = try await database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT mediaFilesJSON, contextImageString FROM media_items WHERE id = ?",
                arguments: [itemId.uuidString]
            ) else { return nil }

            let json: String = row["mediaFilesJSON"]
            let paths = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
            if let first = paths.first {
                return URL(fileURLWithPath: first)
            }
            if let ctx: String = row["contextImageString"] {
                return URL(fileURLWithPath: ctx)
            }
            return nil
        }

        guard let url = url else {
            throw PipelineError.noMediaFiles(itemId)
        }
        return url
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "avi", "mkv"]

    nonisolated static func preferredExistingStillURL(
        mediaPaths: [String],
        contextPath: String?
    ) -> URL? {
        var candidates = mediaPaths
        if let contextPath, !contextPath.isEmpty {
            candidates.append(contextPath)
        }

        let fm = FileManager.default
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            guard stillImageExtensions.contains(url.pathExtension.lowercased()) else { continue }

            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            return url
        }
        return nil
    }

    private nonisolated func loadCGImage(from url: URL, maxPixelDimension: Int? = nil) -> CGImage? {
        let ext = url.pathExtension.lowercased()
        if Self.videoExtensions.contains(ext) {
            return extractVideoFrame(from: url)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        if let maxPixelDimension {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
                kCGImageSourceShouldCacheImmediately: true
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }

        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Extract a representative frame from a video file.
    /// Grabs at 1 second or 10% of duration, whichever is smaller — avoids black first frames.
    private nonisolated func extractVideoFrame(from url: URL) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let durationSeconds = CMTimeGetSeconds(asset.duration)
        let targetSeconds: Double
        if durationSeconds > 0 {
            targetSeconds = min(1.0, durationSeconds * 0.1)
        } else {
            targetSeconds = 0.0
        }
        let requestTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)

        do {
            let cgImage = try generator.copyCGImage(at: requestTime, actualTime: nil)
            return cgImage
        } catch {
            logWarning("PipelineAdapter: video frame extraction failed for \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Extract 768-float sceneprint directly via Vision framework.
    /// Used as fallback when SearchIndex's VectorStore cache misses.
    private nonisolated func extractSceneprint(from image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logError("PipelineAdapter: sceneprint extraction failed: \(error)")
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        guard observation.elementType == .float else { return nil }
        return observation.data.withUnsafeBytes { ptr -> [Float] in
            let buffer = ptr.bindMemory(to: Float.self)
            return Array(buffer.prefix(observation.elementCount))
        }
    }
}

// MARK: - Pipeline Errors

enum PipelineError: Error, LocalizedError {
    case imageLoadFailed(String)
    case noResults
    case noMediaFiles(UUID)
    case notInitialized

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let path): return "Failed to load image: \(path)"
        case .noResults: return "Pipeline returned no results"
        case .noMediaFiles(let id): return "No media files for item \(id)"
        case .notInitialized: return "Pipeline not initialized"
        }
    }
}
