import Foundation
import CoreGraphics
import Vision

/// Image similarity search using VNGenerateImageFeaturePrintRequest sceneprints,
/// with optional CLIP text→image search via Apple's private MADSharedTextEncoder.
///
/// **Image→image**: Uses public Vision framework (768-float sceneprint vectors).
/// **Text→image**: Uses private MediaAnalysis CLIP text tower via VCPTextEncoder
/// (discovered via Ghidra RE of MediaAnalysis binary). Falls back gracefully
/// if the private framework isn't available.
///
/// ```swift
/// let search = try EmbeddingSearch(storePath: myAppSiloURL)
/// try await search.index(image: cgImage, assetID: "photo-001")
/// let similar = try await search.search(image: anotherImage, limit: 10)
/// let textResults = try await search.search(text: "sunset at beach", limit: 10)
/// ```
public final class EmbeddingSearch: @unchecked Sendable {

    private let storePath: URL
    private let version: EmbeddingVersion
    private let vectorStore: VectorStore
    private let loader = FrameworkLoader.shared
    private let queue = DispatchQueue(label: "com.photopipeline.embedding", qos: .userInitiated)

    /// Cached text encoder (created once, reused for all queries)
    private var _textEncoder: NSObject?
    private var _vcpEncoder: AnyObject?
    private var _textEncoderInitialized = false

    /// Initialize with your own silo path (NOT Photos.app's library).
    ///
    /// - Parameters:
    ///   - storePath: Directory for vector database files. Created if needed.
    ///   - version: Embedding version tag (metadata only for this implementation).
    public init(storePath: URL, version: EmbeddingVersion = .md7v2) throws {
        self.storePath = storePath
        self.version = version
        self.vectorStore = try VectorStore(storePath: storePath)

        // Attempt to load MediaAnalysis for MADSharedTextEncoder (optional)
        try? loader.load(.mediaAnalysis)
    }

    /// Index an image — extract sceneprint embedding and store it.
    ///
    /// Uses VNGenerateImageFeaturePrintRequest to produce a 768-float vector,
    /// then inserts into the VectorStore for similarity search.
    /// Call `rebuild()` after batch inserts to flush to disk.
    public func index(image: CGImage, assetID: String) async throws {
        let vector = try extractFeaturePrint(image: image)
        try vectorStore.upsert(assetID: assetID, vector: vector)
    }

    /// Search by image similarity — find visually similar images.
    ///
    /// Extracts the query image's sceneprint, then does brute-force cosine
    /// similarity over all stored vectors.
    public func search(image: CGImage, limit: Int = 20) async throws -> [SearchResult] {
        let queryVector = try extractFeaturePrint(image: image)
        let matches = vectorStore.search(query: queryVector, limit: limit)
        return matches.map { (assetID, score) in
            SearchResult(
                assetID: assetID,
                score: score,
                matchType: .embedding,
                detail: "image similarity"
            )
        }
    }

    /// Search by text query — semantic text→image search.
    ///
    /// Uses MADSharedTextEncoder → VCPTextEncoder.textEmbeddingForQuery:useFP16:
    /// to produce a CLIP text embedding, then searches against stored sceneprints.
    ///
    /// Note: sceneprint and CLIP are different embedding spaces, so text→sceneprint
    /// matching is approximate. For production CLIP search, images should also be
    /// indexed with CLIP image embeddings via MADEmbeddingStore.
    public func search(text: String, limit: Int = 20) async throws -> [SearchResult] {
        if let textVector = try? encodeText(text) {
            let matches = vectorStore.search(query: textVector, limit: limit)
            return matches.map { (assetID, score) in
                SearchResult(
                    assetID: assetID,
                    score: score,
                    matchType: .embedding,
                    detail: text
                )
            }
        }

        // Text encoding unavailable — return empty (other modules handle keyword search)
        return []
    }

    /// Remove an asset from the index.
    public func remove(assetID: String) throws {
        vectorStore.remove(assetID: assetID)
        try vectorStore.flush()
    }

    /// Flush cached vectors to disk.
    public func flush() throws {
        try vectorStore.flush()
    }

    /// Get the cached vector for an asset.
    public func getVector(assetID: String) -> [Float]? {
        vectorStore.get(assetID: assetID)
    }

    /// Rebuild the index. For VectorStore this just flushes to disk.
    public func rebuild() async throws {
        try vectorStore.flush()
    }

    /// Number of indexed vectors.
    public var indexedCount: Int { vectorStore.count }

    // MARK: - Feature Print Extraction

    /// Extract 768-float sceneprint via VNGenerateImageFeaturePrintRequest.
    private func extractFeaturePrint(image: CGImage) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first else {
            throw FrameworkError.invocationFailed("VNGenerateImageFeaturePrintRequest returned no results")
        }

        let count = observation.elementCount
        guard observation.elementType == .float else {
            throw FrameworkError.invocationFailed("Feature print element type is not float")
        }

        return observation.data.withUnsafeBytes { ptr -> [Float] in
            let buffer = ptr.bindMemory(to: Float.self)
            return Array(buffer.prefix(count))
        }
    }

    // MARK: - Text Encoding (CLIP via MADSharedTextEncoder → VCPTextEncoder)

    /// Encode text via the CLIP text tower discovered in MediaAnalysis.
    ///
    /// Pipeline (from Ghidra RE):
    ///   MADSharedTextEncoder.initWithTextEncoderWithVersion:extendedContextLength:
    ///     → creates VCPTextEncoder internally (ivar at self+0x10)
    ///   loadResources: → loads BPE tokenizer + Espresso CLIP model
    ///   VCPTextEncoder.textEmbeddingForQuery:useFP16:
    ///     → tokenize → Espresso forward → extract tensor → L2 normalize
    ///     → returns NSData of L2-normalized float32 embedding
    private func encodeText(_ text: String) throws -> [Float]? {
        guard let vcpEncoder = getOrCreateVCPEncoder() else {
            return nil
        }

        // Call textEmbeddingForQuery:useFP16: on VCPTextEncoder
        // Signature: -(NSData*)textEmbeddingForQuery:(NSString*)query useFP16:(uint)fp16
        // Returns L2-normalized NSData of float32 (when useFP16=0)
        let sel = "textEmbeddingForQuery:useFP16:"
        guard ObjCBridge.responds(vcpEncoder, to: sel) else {
            return nil
        }

        guard let result = ObjCBridge.msgSendIdUInt32(
            vcpEncoder, sel, text as NSString, 0  // useFP16=0 → float32 output
        ) else {
            return nil
        }

        // Result is NSData containing L2-normalized float32 embedding
        guard let data = result as? Data else {
            // Try extracting via KVC if it's a wrapper object
            if let embData = ObjCBridge.getValue(result, forKey: "data") as? Data {
                return dataToFloats(embData)
            }
            if let embData = ObjCBridge.getValue(result, forKey: "embeddingBlob") as? Data {
                return dataToFloats(embData)
            }
            return nil
        }

        return dataToFloats(data)
    }

    /// Get or create the cached VCPTextEncoder for text embedding.
    private func getOrCreateVCPEncoder() -> AnyObject? {
        if _textEncoderInitialized { return _vcpEncoder }
        _textEncoderInitialized = true

        guard let encoderCls = loader.classNamed("MADSharedTextEncoder") else {
            return nil
        }

        // Create MADSharedTextEncoder via typed msgSend
        // Signature: -(id)initWithTextEncoderWithVersion:(ulong)version
        //                  extendedContextLength:(BOOL)extended
        let allocSel = NSSelectorFromString("alloc")
        guard encoderCls.responds(to: allocSel) else { return nil }
        guard let allocated = (encoderCls as AnyObject).perform(allocSel)?
            .takeUnretainedValue() as? NSObject else { return nil }

        // version=0 (md7v2), extendedContextLength=0 (standard)
        guard let encoder = ObjCBridge.msgSendInitUInt64UInt8(
            allocated, "initWithTextEncoderWithVersion:extendedContextLength:", 0, 0
        ) as? NSObject else {
            return nil
        }
        _textEncoder = encoder

        // Load resources (BPE tokenizer, Espresso model)
        let loaded = ObjCBridge.msgSendWithErrorPtr(encoder, "loadResources:")
        if !loaded {
            return nil
        }

        // Extract VCPTextEncoder from MADSharedTextEncoder ivar
        // From Ghidra: VCPTextEncoder is at self+0x10, dispatch_queue at self+0x18
        let vcpEncoder = resolveVCPEncoder(from: encoder)
        _vcpEncoder = vcpEncoder
        return vcpEncoder
    }

    /// Extract VCPTextEncoder from MADSharedTextEncoder's internal ivar.
    /// Tries KVC first, falls back to direct ivar enumeration.
    private func resolveVCPEncoder(from encoder: NSObject) -> AnyObject? {
        // Try KVC with likely property names
        for key in ["textEncoder", "encoder"] {
            if let obj = (encoder as NSObject).value(forKey: key) as AnyObject?,
               ObjCBridge.responds(obj, to: "textEmbeddingForQuery:useFP16:") {
                return obj
            }
        }

        // Fall back: enumerate ivars and find the one at offset 0x10
        let cls: AnyClass = type(of: encoder)
        let ivars = ObjCBridge.ivarNames(of: cls)
        for (name, offset) in ivars {
            if offset == 0x10 {
                if let obj = ObjCBridge.getIvar(encoder, named: name) {
                    return obj
                }
            }
        }

        // Last resort: try the encoder itself (maybe it responds to the selector)
        if ObjCBridge.responds(encoder, to: "textEmbeddingForQuery:useFP16:") {
            return encoder
        }

        return nil
    }

    /// Convert NSData of float32 values to [Float].
    private func dataToFloats(_ data: Data) -> [Float]? {
        guard data.count >= MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { buf in
            Array(buf.bindMemory(to: Float.self))
        }
    }
}
