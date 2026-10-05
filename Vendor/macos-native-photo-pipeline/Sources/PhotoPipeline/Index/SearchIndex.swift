import Foundation
import CoreGraphics

/// Unified multi-modal search index.
///
/// Orchestrates all analysis modules (embedding, scene, object, face, text)
/// and provides a single `search()` entry point that queries across all
/// enabled modules and returns ranked results.
///
/// ```swift
/// let index = try SearchIndex(
///     configuration: .full,
///     storePath: myAppSiloURL
/// )
///
/// // Index images
/// try await index.index(image: photo, assetID: "001")
///
/// // Multi-modal search
/// let results = try await index.search("dog at the beach")
/// ```
public final class SearchIndex: @unchecked Sendable {

    public let configuration: IndexConfiguration
    public let storePath: URL

    private let store: PipelineStore
    private let metadataStore: MetadataStore

    // Lazy-initialized modules
    private var _embeddingSearch: EmbeddingSearch?
    private var _sceneClassifier: SceneClassifier?
    private var _objectRecognizer: ObjectRecognizer?
    private var _faceGallery: FaceGallery?
    private var _textRecognizer: TextRecognizer?
    private let junkClassifier = JunkClassifier()
    private let curationScorer = CurationScorer()

    // New analysis modules (lazy-initialized, no-throw inits)
    private var _imageQuality: ImageQuality?
    private var _memeDetector: MemeDetector?
    private var _safetyClassifier: SafetyClassifier?
    private var _duplicateDetector: DuplicateDetector?
    private var _faceAttributeAnalyzer: FaceAttributeAnalyzer?
    private var _bodyPoseEstimator: BodyPoseEstimator?
    private var _animalAnalyzer: AnimalAnalyzer?
    private var _personSegmentation: PersonSegmentation?
    private var _documentAnalysis: DocumentAnalysis?
    private var _barcodeScanner: BarcodeScanner?
    private var _objectDetection: ObjectDetection?
    private var _imageCaptioner: ImageCaptioner?

    /// Create a search index with the given configuration and storage path.
    public init(configuration: IndexConfiguration, storePath: URL) throws {
        self.configuration = configuration
        self.storePath = storePath
        self.store = try PipelineStore(rootPath: storePath)
        self.metadataStore = try MetadataStore(storePath: store.classificationsPath)

        // Save config for recovery
        try store.saveConfig(configuration)
    }

    /// Index an image through all enabled analysis modules.
    ///
    /// Uses Apple's VCPPreAnalyzer pattern: scene classification runs first (phase 1),
    /// then gates downstream modules based on scene content (phase 2):
    /// - Face gallery: skipped if no faces detected in scene
    /// - Object recognition: skipped for utility images (screenshots, documents)
    /// - OCR: always runs (Apple's 0.11 threshold almost never triggers)
    ///
    /// Disable gating with `IndexConfiguration.enableSceneGating = false` to
    /// brute-force all enabled modules on every image.
    ///
    /// Fault-tolerant: individual module failures don't prevent other modules
    /// from completing.
    @discardableResult
    public func index(image: CGImage, assetID: String, metadata: AssetMetadata? = nil) async throws -> IndexResult {
        var succeeded = 0
        var failures: [String] = []
        var skipped: [String] = []

        // ── Phase 1: Foundation (always runs) ──
        // Scene classification is the "gate keeper" — its results determine phase 2.
        // Embedding extraction is independent and runs concurrently.
        var sceneResult: SceneResult?

        await withTaskGroup(of: (String, Bool, String?, SceneResult?).self) { group in

            if configuration.enableEmbeddingSearch {
                group.addTask {
                    do {
                        let search = try self.embeddingSearch()
                        try await search.index(image: image, assetID: assetID)
                        return ("embedding", true, nil, nil)
                    } catch {
                        return ("embedding", false, error.localizedDescription, nil)
                    }
                }
            }

            if configuration.enableSceneClassification {
                group.addTask {
                    do {
                        let classifier = try self.sceneClassifier()
                        let result = try await classifier.classify(image: image)
                        try self.metadataStore.storeSceneResult(assetID: assetID, result: result)
                        return ("scene", true, nil, result)
                    } catch {
                        return ("scene", false, error.localizedDescription, nil)
                    }
                }
            }

            for await (module, ok, err, scene) in group {
                if ok { succeeded += 1 }
                else if let err { failures.append("\(module): \(err)") }
                if let scene { sceneResult = scene }
            }
        }

        // ── Phase 2: Gated analysis ──
        // Scene results gate downstream modules, matching Apple's VCPPreAnalyzer pattern.
        // When gating is disabled or scene classification failed, everything runs.
        let gating = configuration.enableSceneGating && sceneResult != nil

        let shouldRunFaces: Bool
        let shouldRunObjects: Bool
        if gating {
            let scene = sceneResult!
            shouldRunFaces = scene.faceCount > 0
            shouldRunObjects = !scene.isUtility
        } else {
            shouldRunFaces = true
            shouldRunObjects = true
        }

        await withTaskGroup(of: (String, Bool, String?).self) { group in

            if configuration.enableObjectRecognition {
                if shouldRunObjects {
                    group.addTask {
                        do {
                            let recognizer = try self.objectRecognizer()
                            let recognitions = try await recognizer.recognize(image: image)
                            try self.metadataStore.storeRecognitions(assetID: assetID, recognitions: recognitions)
                            return ("object", true, nil)
                        } catch {
                            return ("object", false, error.localizedDescription)
                        }
                    }
                } else {
                    skipped.append("object: utility image (screenshot/document)")
                }
            }

            if configuration.enableFaceGallery {
                if shouldRunFaces {
                    group.addTask {
                        do {
                            let gallery = try self.faceGallery()
                            _ = try await gallery.identify(image: image)
                            return ("face", true, nil)
                        } catch {
                            return ("face", false, error.localizedDescription)
                        }
                    }
                } else {
                    skipped.append("face: no faces in scene")
                }
            }

            if configuration.enableTextRecognition {
                group.addTask {
                    do {
                        let recognizer = try self.textRecognizer()
                        let rawObservations = try await recognizer.recognize(image: image)
                        // Apply quality filter with diagnostics
                        let filter = self.configuration.ocrQualityFilter
                        let kept: [TextObservation]
                        let rawCount: Int?
                        if let filter {
                            let (k, _) = filter.partition(rawObservations)
                            kept = k
                            rawCount = rawObservations.count
                        } else {
                            kept = rawObservations
                            rawCount = nil
                        }
                        try self.metadataStore.storeTextObservations(
                            assetID: assetID,
                            observations: kept,
                            rawLineCount: rawCount
                        )
                        return ("text", true, nil)
                    } catch {
                        return ("text", false, error.localizedDescription)
                    }
                }
            }

            // ── New Phase 2 modules ──

            if configuration.enableFaceAttributes {
                if shouldRunFaces {
                    group.addTask {
                        do {
                            let analyzer = self.faceAttributeAnalyzer()
                            let results = try await analyzer.analyze(image: image)
                            try self.metadataStore.storeFaceAttributes(assetID: assetID, results: results)
                            return ("faceattr", true, nil)
                        } catch {
                            return ("faceattr", false, error.localizedDescription)
                        }
                    }
                } else {
                    skipped.append("faceattr: no faces in scene")
                }
            }

            if configuration.enableBodyPoseEstimation {
                group.addTask {
                    do {
                        let estimator = self.bodyPoseEstimator()
                        let result = try await estimator.detectAll(image: image)
                        try self.metadataStore.storeBodyPoses(assetID: assetID, result: result)
                        return ("bodypose", true, nil)
                    } catch {
                        return ("bodypose", false, error.localizedDescription)
                    }
                }
            }

            if configuration.enableAnimalAnalysis {
                group.addTask {
                    do {
                        let analyzer = self.animalAnalyzer()
                        let result = try await analyzer.analyze(image: image)
                        try self.metadataStore.storeAnimalAnalysis(assetID: assetID, result: result)
                        return ("animal", true, nil)
                    } catch {
                        return ("animal", false, error.localizedDescription)
                    }
                }
            }

            if configuration.enablePersonSegmentation {
                group.addTask {
                    do {
                        let segmenter = self.personSegmentation()
                        let result = try await segmenter.generateMask(image: image, quality: .fast)
                        let metadata = SegmentationMetadata(
                            personDetected: result.mask != nil,
                            qualityLevel: result.quality.rawValue
                        )
                        try self.metadataStore.storeSegmentationMetadata(assetID: assetID, metadata: metadata)
                        return ("segmentation", true, nil)
                    } catch {
                        return ("segmentation", false, error.localizedDescription)
                    }
                }
            }

            if configuration.enableDocumentAnalysis {
                let shouldRunDocs = !gating || (sceneResult?.isUtility ?? false)
                if shouldRunDocs {
                    group.addTask {
                        do {
                            let analyzer = self.documentAnalysis()
                            let docs = try await analyzer.detectDocuments(image: image)
                            try self.metadataStore.storeDocuments(assetID: assetID, documents: docs)
                            return ("document", true, nil)
                        } catch {
                            return ("document", false, error.localizedDescription)
                        }
                    }
                } else {
                    skipped.append("document: not a utility image")
                }
            }

            if configuration.enableBarcodeScanning {
                group.addTask {
                    do {
                        let scanner = self.barcodeScanner()
                        let results = try await scanner.scan(image: image)
                        try self.metadataStore.storeBarcodes(assetID: assetID, results: results)
                        return ("barcode", true, nil)
                    } catch {
                        return ("barcode", false, error.localizedDescription)
                    }
                }
            }

            if configuration.enableHorizonContourDetection {
                group.addTask {
                    do {
                        let detector = self.objectDetection()
                        let horizon = try await detector.detectHorizon(image: image)
                        let contours = try await detector.detectContours(image: image)
                        try self.metadataStore.storeHorizonAndContours(assetID: assetID, horizon: horizon, contours: contours)
                        return ("geometry", true, nil)
                    } catch {
                        return ("geometry", false, error.localizedDescription)
                    }
                }
            }

            if configuration.enableImageQuality {
                group.addTask {
                    do {
                        let quality = self.imageQuality()
                        let result = try await quality.assess(image: image)
                        try self.metadataStore.storeQualityResult(assetID: assetID, result: result)
                        return ("quality", true, nil)
                    } catch {
                        return ("quality", false, error.localizedDescription)
                    }
                }
            }

            if configuration.enableMemeDetection {
                group.addTask {
                    do {
                        let detector = self.memeDetector()
                        let result = try await detector.detect(image: image)
                        try self.metadataStore.storeMemeResult(assetID: assetID, result: result)
                        return ("meme", true, nil)
                    } catch {
                        return ("meme", false, error.localizedDescription)
                    }
                }
            }

            if configuration.enableSafetyClassification {
                group.addTask {
                    do {
                        let classifier = self.safetyClassifier()
                        let result = try await classifier.classify(image: image)
                        try self.metadataStore.storeSafetyResult(assetID: assetID, result: result)
                        return ("safety", true, nil)
                    } catch {
                        return ("safety", false, error.localizedDescription)
                    }
                }
            }

            if configuration.enableDuplicateDetection {
                group.addTask {
                    do {
                        let detector = self.duplicateDetector()
                        let fp = try await detector.fingerprint(image: image)
                        try self.metadataStore.storeFingerprint(assetID: assetID, fingerprint: fp)
                        return ("fingerprint", true, nil)
                    } catch {
                        return ("fingerprint", false, error.localizedDescription)
                    }
                }
            }

            if configuration.enableImageCaptioning {
                group.addTask {
                    do {
                        let captioner = self.imageCaptioner()
                        let result = try await captioner.caption(image: image)
                        try self.metadataStore.storeCaption(assetID: assetID, result: result)
                        return ("caption", true, nil)
                    } catch {
                        return ("caption", false, error.localizedDescription)
                    }
                }
            }

            for await (module, ok, err) in group {
                if ok { succeeded += 1 }
                else if let err { failures.append("\(module): \(err)") }
            }
        }

        // ── Phase 3: Junk + Curation (sequential, depends on phase 1+2 results) ──
        if junkClassifier.isAvailable {
            do {
                let junkResult = try await junkClassifier.classify(image: image)
                try metadataStore.storeJunkResult(assetID: assetID, result: junkResult)
                succeeded += 1

                // Compute curation score using scene + object results
                let objects = metadataStore.loadRecognitions(assetID: assetID)
                let curationResult = curationScorer.score(
                    junkConfidence: junkResult.confidence,
                    aestheticsScore: sceneResult?.aestheticsScore ?? 0,
                    faceCount: sceneResult?.faceCount ?? 0,
                    objectCount: objects?.count ?? 0,
                    isUtility: sceneResult?.isUtility ?? false
                )
                try metadataStore.storeCurationResult(assetID: assetID, result: curationResult)
            } catch {
                failures.append("junk: \(error.localizedDescription)")
            }
        }

        return IndexResult(modulesSucceeded: succeeded, failures: failures, skipped: skipped)
    }

    /// Multi-modal search across all enabled modules.
    ///
    /// Queries text against:
    /// - CLIP embedding similarity (semantic)
    /// - Scene label keyword matching
    /// - Object name matching
    /// - OCR text content matching
    ///
    /// Results are ranked by combined score across all matching modules.
    public func search(_ query: String, limit: Int = 20) async throws -> [SearchResult] {
        var allResults: [SearchResult] = []

        // Fault-tolerant: each module catches its own errors
        await withTaskGroup(of: [SearchResult].self) { group in

            // Embedding search (semantic)
            if configuration.enableEmbeddingSearch {
                group.addTask {
                    do {
                        let search = try self.embeddingSearch()
                        return try await search.search(text: query, limit: limit)
                    } catch {
                        return []
                    }
                }
            }

            // Scene label matching
            if configuration.enableSceneClassification {
                group.addTask {
                    return self.searchSceneLabels(query: query, limit: limit)
                }
            }

            // Object name matching
            if configuration.enableObjectRecognition {
                group.addTask {
                    return self.searchObjectNames(query: query, limit: limit)
                }
            }

            // Text content matching (OCR)
            if configuration.enableTextRecognition {
                group.addTask {
                    return self.searchTextContent(query: query, limit: limit)
                }
            }

            for await results in group {
                allResults.append(contentsOf: results)
            }
        }

        // Merge and rank results — combine scores for assets matched by multiple modules
        return mergeResults(allResults, limit: limit)
    }

    /// Remove an asset from all indices.
    public func remove(assetID: String) async throws {
        if configuration.enableEmbeddingSearch {
            let search = try embeddingSearch()
            try search.remove(assetID: assetID)
        }
        try metadataStore.removeAll(assetID: assetID)
    }

    /// Rebuild all indices. Call after bulk insertions.
    public func rebuild() async throws {
        if configuration.enableEmbeddingSearch {
            let search = try embeddingSearch()
            try await search.rebuild()
        }
    }

    /// Flush embedding vectors to disk. Call periodically during batch processing.
    public func flushEmbeddings() throws {
        if configuration.enableEmbeddingSearch {
            let search = try embeddingSearch()
            try search.flush()
        }
    }

    /// Get the embedding vector for an asset (from in-memory cache or disk).
    /// Returns nil if embeddings are disabled or the asset hasn't been indexed.
    public func getEmbedding(assetID: String) throws -> [Float]? {
        guard configuration.enableEmbeddingSearch else { return nil }
        let search = try embeddingSearch()
        return search.getVector(assetID: assetID)
    }

    /// Analysis data for one indexed asset.
    ///
    /// Unlike `allAnalysis()`, this performs only a bounded set of direct file lookups. It is the
    /// appropriate API after indexing one asset or resuming one asset's processing pipeline.
    public func analysis(for assetID: String) -> AssetAnalysis? {
        guard metadataStore.containsMetadata(assetID: assetID) else { return nil }
        return makeAnalysis(assetID: assetID)
    }

    /// All analysis data for every indexed asset.
    ///
    /// Returns one `AssetAnalysis` per asset with scene labels, OCR text,
    /// object recognitions, aesthetics score, etc.
    public func allAnalysis() -> [AssetAnalysis] {
        metadataStore.allAssetIDs()
            .map(makeAnalysis(assetID:))
            .sorted { $0.assetID < $1.assetID }
    }

    private func makeAnalysis(assetID: String) -> AssetAnalysis {
        let scene = metadataStore.loadSceneResult(assetID: assetID)
        let text = metadataStore.loadTextObservations(assetID: assetID) ?? []
        let objects = metadataStore.loadRecognitions(assetID: assetID) ?? []
        let filterDiag = metadataStore.loadTextFilterDiagnostics(assetID: assetID)
        let junk = metadataStore.loadJunkResult(assetID: assetID)
        let curation = metadataStore.loadCurationResult(assetID: assetID)
        // New module results
        let quality = metadataStore.loadQualityResult(assetID: assetID)
        let meme = metadataStore.loadMemeResult(assetID: assetID)
        let safety = metadataStore.loadSafetyResult(assetID: assetID)
        let fp = metadataStore.loadFingerprint(assetID: assetID)
        let faceAttrs = metadataStore.loadFaceAttributes(assetID: assetID) ?? []
        let poses = metadataStore.loadBodyPoses(assetID: assetID)
        let animals = metadataStore.loadAnimalAnalysis(assetID: assetID)
        let segMeta = metadataStore.loadSegmentationMetadata(assetID: assetID)
        let docs = metadataStore.loadDocuments(assetID: assetID) ?? []
        let barcodes = metadataStore.loadBarcodes(assetID: assetID) ?? []
        let geometry = metadataStore.loadHorizonAndContours(assetID: assetID)
        let caption = metadataStore.loadCaption(assetID: assetID)

        return AssetAnalysis(
            assetID: assetID,
            sceneLabels: scene?.labels ?? [],
            aestheticsScore: scene?.aestheticsScore ?? 0,
            isJunk: scene?.isJunk ?? false,
            isUtility: scene?.isUtility ?? false,
            faceCount: scene?.faceCount ?? 0,
            textObservations: text,
            objectRecognitions: objects,
            ocrRawLineCount: filterDiag?.rawLineCount,
            ocrKeptLineCount: filterDiag?.keptLineCount,
            junkConfidence: junk?.confidence,
            junkSource: junk?.source,
            curationScore: curation?.score,
            curationGated: curation?.gatedByQuality ?? false,
            qualityResult: quality,
            memeResult: meme,
            safetyResult: safety,
            fingerprint: fp,
            faceAttributes: faceAttrs,
            bodyPoses: poses,
            animalAnalysis: animals,
            personDetected: segMeta?.personDetected ?? false,
            documents: docs,
            barcodes: barcodes,
            horizonAngle: geometry?.horizon?.angle,
            contourCount: geometry?.contours.contourCount ?? 0,
            caption: caption
        )
    }

    /// Current index statistics.
    public func stats() throws -> IndexStats {
        let assetCount = metadataStore.assetCount()
        let sizeBytes = (try? store.totalSizeBytes()) ?? 0

        return IndexStats(
            totalAssets: assetCount,
            embeddingCount: (try? store.indexedAssetCount()) ?? 0,
            sceneClassificationCount: assetCount,
            storeSizeBytes: sizeBytes
        )
    }

    // MARK: - Module accessors (lazy init)

    private func embeddingSearch() throws -> EmbeddingSearch {
        if let existing = _embeddingSearch { return existing }
        let search = try EmbeddingSearch(storePath: store.embeddingsPath, version: configuration.embeddingVersion)
        _embeddingSearch = search
        return search
    }

    private func sceneClassifier() throws -> SceneClassifier {
        if let existing = _sceneClassifier { return existing }
        let classifier = try SceneClassifier()
        _sceneClassifier = classifier
        return classifier
    }

    private func objectRecognizer() throws -> ObjectRecognizer {
        if let existing = _objectRecognizer { return existing }
        let recognizer = try ObjectRecognizer()
        _objectRecognizer = recognizer
        return recognizer
    }

    private func faceGallery() throws -> FaceGallery {
        if let existing = _faceGallery { return existing }
        let gallery = try FaceGallery(galleryPath: store.galleryPath)
        _faceGallery = gallery
        return gallery
    }

    private func textRecognizer() throws -> TextRecognizer {
        if let existing = _textRecognizer { return existing }
        // Filter is applied manually in index() for diagnostics, so disable it here
        let recognizer = try TextRecognizer(
            languages: configuration.ocrLanguages,
            qualityFilter: nil
        )
        _textRecognizer = recognizer
        return recognizer
    }

    private func imageQuality() -> ImageQuality {
        if let existing = _imageQuality { return existing }
        let m = ImageQuality(); _imageQuality = m; return m
    }
    private func memeDetector() -> MemeDetector {
        if let existing = _memeDetector { return existing }
        let m = MemeDetector(); _memeDetector = m; return m
    }
    private func safetyClassifier() -> SafetyClassifier {
        if let existing = _safetyClassifier { return existing }
        let m = SafetyClassifier(); _safetyClassifier = m; return m
    }
    private func duplicateDetector() -> DuplicateDetector {
        if let existing = _duplicateDetector { return existing }
        let m = DuplicateDetector(); _duplicateDetector = m; return m
    }
    private func faceAttributeAnalyzer() -> FaceAttributeAnalyzer {
        if let existing = _faceAttributeAnalyzer { return existing }
        let m = FaceAttributeAnalyzer(); _faceAttributeAnalyzer = m; return m
    }
    private func bodyPoseEstimator() -> BodyPoseEstimator {
        if let existing = _bodyPoseEstimator { return existing }
        let m = BodyPoseEstimator(); _bodyPoseEstimator = m; return m
    }
    private func animalAnalyzer() -> AnimalAnalyzer {
        if let existing = _animalAnalyzer { return existing }
        let m = AnimalAnalyzer(); _animalAnalyzer = m; return m
    }
    private func personSegmentation() -> PersonSegmentation {
        if let existing = _personSegmentation { return existing }
        let m = PersonSegmentation(); _personSegmentation = m; return m
    }
    private func documentAnalysis() -> DocumentAnalysis {
        if let existing = _documentAnalysis { return existing }
        let m = DocumentAnalysis(); _documentAnalysis = m; return m
    }
    private func barcodeScanner() -> BarcodeScanner {
        if let existing = _barcodeScanner { return existing }
        let m = BarcodeScanner(); _barcodeScanner = m; return m
    }
    private func objectDetection() -> ObjectDetection {
        if let existing = _objectDetection { return existing }
        let m = ObjectDetection(); _objectDetection = m; return m
    }
    private func imageCaptioner() -> ImageCaptioner {
        if let existing = _imageCaptioner { return existing }
        let m = ImageCaptioner(); _imageCaptioner = m; return m
    }

    // MARK: - Keyword search across stored metadata

    private func searchSceneLabels(query: String, limit: Int) -> [SearchResult] {
        let queryLower = query.lowercased()
        let queryWords = Set(queryLower.split(separator: " ").map(String.init))

        // Scan stored scene classifications
        let scenePath = store.classificationsPath.appendingPathComponent("scene")
        guard let files = try? FileManager.default.contentsOfDirectory(at: scenePath, includingPropertiesForKeys: nil) else {
            return []
        }

        var results: [SearchResult] = []
        for file in files where file.pathExtension == "json" {
            let assetID = file.deletingPathExtension().lastPathComponent
            guard let sceneResult = metadataStore.loadSceneResult(assetID: assetID) else { continue }

            for label in sceneResult.labels {
                let labelWords = Set(label.label.lowercased().split(separator: " ").map(String.init))
                let overlap = queryWords.intersection(labelWords)
                if !overlap.isEmpty || label.label.lowercased().contains(queryLower) {
                    let score = label.confidence * Float(overlap.count) / Float(max(queryWords.count, 1))
                    results.append(SearchResult(
                        assetID: assetID,
                        score: score,
                        matchType: .scene,
                        detail: label.label
                    ))
                    break // One match per asset
                }
            }
        }

        return results.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    private func searchObjectNames(query: String, limit: Int) -> [SearchResult] {
        let queryLower = query.lowercased()
        let objectPath = store.classificationsPath.appendingPathComponent("object")
        guard let files = try? FileManager.default.contentsOfDirectory(at: objectPath, includingPropertiesForKeys: nil) else {
            return []
        }

        var results: [SearchResult] = []
        for file in files where file.pathExtension == "json" {
            let assetID = file.deletingPathExtension().lastPathComponent
            guard let recognitions = metadataStore.loadRecognitions(assetID: assetID) else { continue }

            for rec in recognitions {
                if rec.name.lowercased().contains(queryLower) {
                    results.append(SearchResult(
                        assetID: assetID,
                        score: rec.confidence,
                        matchType: .object,
                        detail: rec.name
                    ))
                    break
                }
            }
        }

        return results.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    private func searchTextContent(query: String, limit: Int) -> [SearchResult] {
        let queryLower = query.lowercased()
        let textPath = store.classificationsPath.appendingPathComponent("text")
        guard let files = try? FileManager.default.contentsOfDirectory(at: textPath, includingPropertiesForKeys: nil) else {
            return []
        }

        var results: [SearchResult] = []
        for file in files where file.pathExtension == "json" {
            let assetID = file.deletingPathExtension().lastPathComponent
            guard let observations = metadataStore.loadTextObservations(assetID: assetID) else { continue }

            for obs in observations {
                if obs.text.lowercased().contains(queryLower) {
                    results.append(SearchResult(
                        assetID: assetID,
                        score: obs.confidence,
                        matchType: .text,
                        detail: obs.text
                    ))
                    break
                }
            }
        }

        return results.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    // MARK: - Result merging

    private func mergeResults(_ results: [SearchResult], limit: Int) -> [SearchResult] {
        // Group by assetID and combine scores
        var grouped: [String: (maxScore: Float, results: [SearchResult])] = [:]

        for result in results {
            var entry = grouped[result.assetID] ?? (maxScore: 0, results: [])
            entry.results.append(result)
            entry.maxScore = max(entry.maxScore, result.score)
            grouped[result.assetID] = entry
        }

        // Multi-modal boost: assets matched by multiple modules get a score boost
        return grouped.values
            .sorted { lhs, rhs in
                let lhsBoost = Float(lhs.results.count) * 0.1
                let rhsBoost = Float(rhs.results.count) * 0.1
                return (lhs.maxScore + lhsBoost) > (rhs.maxScore + rhsBoost)
            }
            .prefix(limit)
            .map { entry in
                // Return the highest-scoring result for each asset
                entry.results.max(by: { $0.score < $1.score })!
            }
    }
}
