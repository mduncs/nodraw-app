import Foundation

/// SQLite-backed metadata cache for classification results.
///
/// Stores scene labels, object recognitions, and text observations
/// per asset ID for fast lookup without re-running ML models.
///
/// Uses flat JSON files as a portable alternative to CoreData,
/// avoiding the framework dependency and complexity.
public final class MetadataStore: @unchecked Sendable {

    private let storePath: URL
    private let lock = NSLock()

    public init(storePath: URL) throws {
        self.storePath = storePath
        try FileManager.default.createDirectory(at: storePath, withIntermediateDirectories: true)
    }

    // MARK: - Scene Classifications

    /// Store scene classification results for an asset.
    public func storeSceneResult(assetID: String, result: SceneResult) throws {
        var dict: [String: Any] = [
            "labels": result.labels.map { ["label": $0.label, "confidence": $0.confidence] },
            "aestheticsScore": result.aestheticsScore,
            "isJunk": result.isJunk,
            "isUtility": result.isUtility,
            "faceCount": result.faceCount,
        ]
        if let detail = result.aestheticsDetail {
            dict["aestheticsDetail"] = [
                "overallScore": detail.overallScore,
                "isUtility": detail.isUtility,
                "qualityScores": detail.qualityScores,
                "subscores": detail.subscores,
            ] as [String: Any]
        }
        if let box = result.saliencyBox {
            dict["saliencyBox"] = ["x": box.origin.x, "y": box.origin.y, "w": box.width, "h": box.height]
        }
        try store(assetID: assetID, category: "scene", data: dict)

        // Store embedding separately (large, binary-ish)
        if let embedding = result.embedding {
            try store(assetID: assetID, category: "embedding", data: ["vector": embedding])
        }
    }

    /// Retrieve stored scene classification for an asset.
    public func loadSceneResult(assetID: String) -> SceneResult? {
        guard let dict = load(assetID: assetID, category: "scene") else { return nil }
        guard let rawLabels = dict["labels"] as? [[String: Any]] else { return nil }

        let labels = rawLabels.compactMap { entry -> SceneClassification? in
            guard let label = entry["label"] as? String,
                  let conf = entry["confidence"] as? Float else { return nil }
            return SceneClassification(label: label, confidence: conf)
        }

        var aestheticsDetail: AestheticsDetail? = nil
        if let detailDict = dict["aestheticsDetail"] as? [String: Any] {
            let qualityScores = (detailDict["qualityScores"] as? [String: NSNumber])?.mapValues { $0.floatValue } ?? [:]
            let subscores = (detailDict["subscores"] as? [String: NSNumber])?.mapValues { $0.floatValue } ?? [:]
            aestheticsDetail = AestheticsDetail(
                overallScore: (detailDict["overallScore"] as? NSNumber)?.floatValue ?? 0,
                isUtility: (detailDict["isUtility"] as? Bool) ?? false,
                qualityScores: qualityScores,
                subscores: subscores
            )
        }

        var saliencyBox: CGRect? = nil
        if let boxDict = dict["saliencyBox"] as? [String: NSNumber] {
            saliencyBox = CGRect(
                x: boxDict["x"]?.doubleValue ?? 0,
                y: boxDict["y"]?.doubleValue ?? 0,
                width: boxDict["w"]?.doubleValue ?? 0,
                height: boxDict["h"]?.doubleValue ?? 0
            )
        }

        return SceneResult(
            labels: labels,
            aestheticsScore: (dict["aestheticsScore"] as? NSNumber)?.floatValue ?? 0,
            isJunk: (dict["isJunk"] as? Bool) ?? false,
            isUtility: (dict["isUtility"] as? Bool) ?? false,
            aestheticsDetail: aestheticsDetail,
            saliencyBox: saliencyBox,
            faceCount: (dict["faceCount"] as? Int) ?? 0
        )
    }

    // MARK: - Object Recognitions

    /// Store object recognition results for an asset.
    public func storeRecognitions(assetID: String, recognitions: [Recognition]) throws {
        let dicts: [[String: Any]] = recognitions.map { r in
            var dict: [String: Any] = [
                "domain": r.domain.rawValue,
                "name": r.name,
                "confidence": r.confidence,
            ]
            if let bbox = r.boundingBox {
                dict["boundingBox"] = [
                    "x": bbox.origin.x, "y": bbox.origin.y,
                    "width": bbox.size.width, "height": bbox.size.height,
                ]
            }
            return dict
        }
        try store(assetID: assetID, category: "object", data: ["recognitions": dicts])
    }

    /// Retrieve stored object recognitions for an asset.
    public func loadRecognitions(assetID: String) -> [Recognition]? {
        guard let dict = load(assetID: assetID, category: "object"),
              let dicts = dict["recognitions"] as? [[String: Any]] else { return nil }

        return dicts.compactMap { entry -> Recognition? in
            guard let name = entry["name"] as? String,
                  let domainRaw = entry["domain"] as? Int,
                  let confidence = entry["confidence"] as? Float else { return nil }
            let domain = RecognitionDomain(rawValue: domainRaw) ?? .unknown
            return Recognition(domain: domain, name: name, confidence: confidence)
        }
    }

    // MARK: - Text Observations

    /// Store OCR results for an asset, with optional quality filter diagnostics.
    public func storeTextObservations(
        assetID: String,
        observations: [TextObservation],
        rawLineCount: Int? = nil
    ) throws {
        let dicts: [[String: Any]] = observations.map { obs in
            [
                "text": obs.text,
                "confidence": obs.confidence,
                "boundingBox": [
                    "x": obs.boundingBox.origin.x, "y": obs.boundingBox.origin.y,
                    "width": obs.boundingBox.size.width, "height": obs.boundingBox.size.height,
                ],
                "language": obs.language as Any,
            ]
        }
        var data: [String: Any] = ["observations": dicts]
        if let rawLineCount {
            data["rawLineCount"] = rawLineCount
            data["keptLineCount"] = observations.count
        }
        try store(assetID: assetID, category: "text", data: data)
    }

    /// Retrieve stored OCR results for an asset.
    public func loadTextObservations(assetID: String) -> [TextObservation]? {
        guard let dict = load(assetID: assetID, category: "text"),
              let dicts = dict["observations"] as? [[String: Any]] else { return nil }

        return dicts.compactMap { entry -> TextObservation? in
            guard let text = entry["text"] as? String,
                  let confidence = entry["confidence"] as? Float else { return nil }
            return TextObservation(
                text: text,
                boundingBox: .zero,
                confidence: confidence,
                language: entry["language"] as? String
            )
        }
    }

    /// Load OCR quality filter diagnostics for an asset.
    public func loadTextFilterDiagnostics(assetID: String) -> (rawLineCount: Int, keptLineCount: Int)? {
        guard let dict = load(assetID: assetID, category: "text"),
              let raw = dict["rawLineCount"] as? Int,
              let kept = dict["keptLineCount"] as? Int else { return nil }
        return (raw, kept)
    }

    // MARK: - Junk Classification

    /// Store junk classification result for an asset.
    public func storeJunkResult(assetID: String, result: JunkResult) throws {
        try store(assetID: assetID, category: "junk", data: [
            "confidence": result.confidence,
            "source": result.source.rawValue,
        ])
    }

    /// Retrieve stored junk classification for an asset.
    public func loadJunkResult(assetID: String) -> JunkResult? {
        guard let dict = load(assetID: assetID, category: "junk"),
              let confidence = dict["confidence"] as? Float,
              let sourceRaw = dict["source"] as? String,
              let source = JunkResult.Source(rawValue: sourceRaw) else { return nil }
        return JunkResult(confidence: confidence, source: source)
    }

    // MARK: - Curation Scores

    /// Store curation score for an asset.
    public func storeCurationResult(assetID: String, result: CurationResult) throws {
        try store(assetID: assetID, category: "curation", data: [
            "score": result.score,
            "globalQuality": result.globalQuality,
            "visualPleasingScore": result.visualPleasingScore,
            "contentScore": result.contentScore,
            "penaltyScore": result.penaltyScore,
            "gatedByQuality": result.gatedByQuality,
        ])
    }

    /// Retrieve stored curation score for an asset.
    public func loadCurationResult(assetID: String) -> CurationResult? {
        guard let dict = load(assetID: assetID, category: "curation"),
              let score = dict["score"] as? Float else { return nil }
        return CurationResult(
            score: score,
            globalQuality: (dict["globalQuality"] as? NSNumber)?.floatValue ?? 0,
            visualPleasingScore: (dict["visualPleasingScore"] as? NSNumber)?.floatValue ?? 0,
            contentScore: (dict["contentScore"] as? NSNumber)?.floatValue ?? 0,
            penaltyScore: (dict["penaltyScore"] as? NSNumber)?.floatValue ?? 0,
            gatedByQuality: (dict["gatedByQuality"] as? Bool) ?? false
        )
    }

    // MARK: - Embeddings

    /// Load the stored sceneprint embedding for an asset.
    public func loadEmbedding(assetID: String) -> [Float]? {
        guard let dict = load(assetID: assetID, category: "embedding"),
              let vector = dict["vector"] as? [NSNumber] else { return nil }
        return vector.map { $0.floatValue }
    }

    /// Load all stored embeddings as (assetID, vector) pairs for similarity search.
    public func allEmbeddings() -> [(String, [Float])] {
        let dir = storePath.appendingPathComponent("embedding")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var results: [(String, [Float])] = []
        for file in files where file.pathExtension == "json" {
            let assetID = file.deletingPathExtension().lastPathComponent
            if let vec = loadEmbedding(assetID: assetID) {
                results.append((assetID, vec))
            }
        }
        return results
    }

    // MARK: - Image Quality

    public func storeQualityResult(assetID: String, result: QualityResult) throws {
        try storeCodable(result, assetID: assetID, category: "quality")
    }

    public func loadQualityResult(assetID: String) -> QualityResult? {
        loadCodable(QualityResult.self, assetID: assetID, category: "quality")
    }

    // MARK: - Meme Detection

    public func storeMemeResult(assetID: String, result: MemeResult) throws {
        try storeCodable(result, assetID: assetID, category: "meme")
    }

    public func loadMemeResult(assetID: String) -> MemeResult? {
        loadCodable(MemeResult.self, assetID: assetID, category: "meme")
    }

    // MARK: - Safety Classification

    public func storeSafetyResult(assetID: String, result: SafetyResult) throws {
        try storeCodable(result, assetID: assetID, category: "safety")
    }

    public func loadSafetyResult(assetID: String) -> SafetyResult? {
        loadCodable(SafetyResult.self, assetID: assetID, category: "safety")
    }

    // MARK: - Duplicate Fingerprint

    public func storeFingerprint(assetID: String, fingerprint: ImageFingerprint) throws {
        try storeCodable(fingerprint, assetID: assetID, category: "fingerprint")
    }

    public func loadFingerprint(assetID: String) -> ImageFingerprint? {
        loadCodable(ImageFingerprint.self, assetID: assetID, category: "fingerprint")
    }

    // MARK: - Face Attributes

    public func storeFaceAttributes(assetID: String, results: [FaceAttributeResult]) throws {
        try storeCodable(results, assetID: assetID, category: "faceattr")
    }

    public func loadFaceAttributes(assetID: String) -> [FaceAttributeResult]? {
        loadCodable([FaceAttributeResult].self, assetID: assetID, category: "faceattr")
    }

    // MARK: - Body Poses

    public func storeBodyPoses(assetID: String, result: PoseResult) throws {
        try storeCodable(result, assetID: assetID, category: "bodypose")
    }

    public func loadBodyPoses(assetID: String) -> PoseResult? {
        loadCodable(PoseResult.self, assetID: assetID, category: "bodypose")
    }

    // MARK: - Animal Analysis

    public func storeAnimalAnalysis(assetID: String, result: AnimalAnalysis) throws {
        try storeCodable(result, assetID: assetID, category: "animal")
    }

    public func loadAnimalAnalysis(assetID: String) -> AnimalAnalysis? {
        loadCodable(AnimalAnalysis.self, assetID: assetID, category: "animal")
    }

    // MARK: - Person Segmentation Metadata

    public func storeSegmentationMetadata(assetID: String, metadata: SegmentationMetadata) throws {
        try storeCodable(metadata, assetID: assetID, category: "segmentation")
    }

    public func loadSegmentationMetadata(assetID: String) -> SegmentationMetadata? {
        loadCodable(SegmentationMetadata.self, assetID: assetID, category: "segmentation")
    }

    // MARK: - Document Analysis

    public func storeDocuments(assetID: String, documents: [DetectedDocument]) throws {
        try storeCodable(documents, assetID: assetID, category: "document")
    }

    public func loadDocuments(assetID: String) -> [DetectedDocument]? {
        loadCodable([DetectedDocument].self, assetID: assetID, category: "document")
    }

    // MARK: - Barcode Scanning

    public func storeBarcodes(assetID: String, results: [BarcodeResult]) throws {
        try storeCodable(results, assetID: assetID, category: "barcode")
    }

    public func loadBarcodes(assetID: String) -> [BarcodeResult]? {
        loadCodable([BarcodeResult].self, assetID: assetID, category: "barcode")
    }

    // MARK: - Horizon & Contours

    public func storeHorizonAndContours(assetID: String, horizon: HorizonResult?, contours: ContourResult) throws {
        let wrapper = HorizonContourData(horizon: horizon, contours: contours)
        try storeCodable(wrapper, assetID: assetID, category: "geometry")
    }

    public func loadHorizonAndContours(assetID: String) -> HorizonContourData? {
        loadCodable(HorizonContourData.self, assetID: assetID, category: "geometry")
    }

    // MARK: - Image Caption

    public func storeCaption(assetID: String, result: CaptionResult) throws {
        try storeCodable(result, assetID: assetID, category: "caption")
    }

    public func loadCaption(assetID: String) -> CaptionResult? {
        loadCodable(CaptionResult.self, assetID: assetID, category: "caption")
    }

    /// Combined horizon + contour data for storage.
    public struct HorizonContourData: Codable, Sendable {
        public let horizon: HorizonResult?
        public let contours: ContourResult
    }

    // MARK: - Bulk operations

    /// Whether any persisted analysis category exists for one asset.
    ///
    /// This is intentionally a bounded set of direct path checks. Callers that need one asset
    /// should not enumerate every category directory via `allAssetIDs()` first.
    public func containsMetadata(assetID: String) -> Bool {
        let fm = FileManager.default
        for category in ["scene", "object", "text", "junk", "curation",
                         "quality", "meme", "safety", "fingerprint", "faceattr",
                         "bodypose", "animal", "segmentation", "document", "barcode",
                         "geometry", "caption"] {
            if fm.fileExists(atPath: filePath(assetID: assetID, category: category).path) {
                return true
            }
        }
        return false
    }

    /// Remove all metadata for an asset.
    public func removeAll(assetID: String) throws {
        let fm = FileManager.default
        for category in ["scene", "object", "text", "junk", "curation", "embedding",
                          "quality", "meme", "safety", "fingerprint", "faceattr",
                          "bodypose", "animal", "segmentation", "document", "barcode",
                          "geometry", "caption"] {
            let path = filePath(assetID: assetID, category: category)
            if fm.fileExists(atPath: path.path) {
                try fm.removeItem(at: path)
            }
        }
    }

    /// Count of assets with stored metadata.
    public func assetCount() -> Int {
        let scenePath = storePath.appendingPathComponent("scene")
        guard FileManager.default.fileExists(atPath: scenePath.path) else { return 0 }
        let files = (try? FileManager.default.contentsOfDirectory(at: scenePath, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.count
    }

    /// All asset IDs that have stored metadata (union across all categories).
    public func allAssetIDs() -> Set<String> {
        var ids = Set<String>()
        for category in ["scene", "object", "text", "junk", "curation",
                          "quality", "meme", "safety", "fingerprint", "faceattr",
                          "bodypose", "animal", "segmentation", "document", "barcode",
                          "geometry", "caption"] {
            let dir = storePath.appendingPathComponent(category)
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension == "json" {
                ids.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        return ids
    }

    // MARK: - Private

    private func store(assetID: String, category: String, data: [String: Any]) throws {
        let dir = storePath.appendingPathComponent(category)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let jsonData = try JSONSerialization.data(withJSONObject: data, options: [])
        try jsonData.write(to: filePath(assetID: assetID, category: category))
    }

    private func load(assetID: String, category: String) -> [String: Any]? {
        let path = filePath(assetID: assetID, category: category)
        guard let data = try? Data(contentsOf: path),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict
    }

    private func filePath(assetID: String, category: String) -> URL {
        storePath.appendingPathComponent(category).appendingPathComponent("\(assetID).json")
    }

    private func storeCodable<T: Encodable>(_ value: T, assetID: String, category: String) throws {
        let dir = storePath.appendingPathComponent(category)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: filePath(assetID: assetID, category: category))
    }

    private func loadCodable<T: Decodable>(_ type: T.Type, assetID: String, category: String) -> T? {
        let path = filePath(assetID: assetID, category: category)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
