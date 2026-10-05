import Foundation
import CoreGraphics
import Vision

/// Face gallery wrapping VisualUnderstanding's VUWGallery / VUWStreamingGallery.
///
/// VUWGallery is the ObjC bridge to Apple's face identity system with CoreData-backed
/// storage and IVF vector search over face embeddings. VUWStreamingGallery provides
/// a simpler add/recognize API for incremental use.
///
/// ```swift
/// let gallery = try FaceGallery(galleryPath: myGalleryURL)
/// let matches = try await gallery.identify(image: cgImage)
/// for match in matches {
///     print("\(match.identityName ?? "Unknown") [\(match.confidence)]")
/// }
/// ```
public final class FaceGallery: @unchecked Sendable {

    private let galleryPath: URL
    private let loader = FrameworkLoader.shared
    private var _gallery: AnyObject?
    private var _streamingGallery: AnyObject?
    private var _galleryInitialized = false
    private let queue = DispatchQueue(label: "com.photopipeline.face", qos: .userInitiated)

    /// Initialize with your own gallery database path.
    ///
    /// Creates a face identity store at the given path.
    /// Completely isolated from Photos.app's face data.
    public init(galleryPath: URL) throws {
        self.galleryPath = galleryPath
        try FileManager.default.createDirectory(at: galleryPath, withIntermediateDirectories: true)

        do {
            try loader.load(.visualUnderstanding)
        } catch {
            // Will fall back to Vision-only face detection
        }
    }

    /// Detect and identify faces in an image.
    ///
    /// Uses VNDetectFaceRectanglesRequest for detection, then VUWGallery's
    /// recognize:context:recognitionPreset:error: for identity matching.
    public func identify(image: CGImage) async throws -> [FaceMatch] {
        let faceObservations = try await detectFaces(image: image)

        var matches: [FaceMatch] = []
        for obs in faceObservations {
            if let match = try matchFace(observation: obs, in: image) {
                matches.append(match)
            }
        }
        return matches
    }

    /// Add a face observation to the gallery via VUWStreamingGallery.
    ///
    /// Detects a face in the image, wraps it as VUWObservation, and adds it
    /// to the streaming gallery for identity clustering.
    public func addObservation(
        faceImage: CGImage,
        assetID: String,
        identityHint: String? = nil
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.addObservationSync(
                        faceImage: faceImage,
                        assetID: assetID,
                        identityHint: identityHint
                    )
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// List all known identities in the gallery.
    public func identities() throws -> [Identity] {
        guard let gallery = getOrCreateGallery() else {
            return try loadIdentitiesFromDisk()
        }

        // Try entities: callback
        var identities: [Identity] = []
        let sel = "entities:error:body:"
        if ObjCBridge.responds(gallery, to: sel) {
            // entities uses a callback pattern — try KVC for simpler access
            if let entityList = ObjCBridge.call(gallery, "unassignedObservations") as? [AnyObject] {
                for (i, _) in entityList.enumerated() {
                    identities.append(Identity(id: "\(i)", observationCount: 1))
                }
            }
        }

        if identities.isEmpty {
            return try loadIdentitiesFromDisk()
        }
        return identities
    }

    /// Prewarm the gallery (load models into memory).
    public func prewarm() throws {
        guard let gallery = getOrCreateGallery() else { return }
        let (_, error) = ObjCBridge.msgSendErrorOnly(gallery, "prewarmAndReturnError:")
        if let error { throw error }
    }

    /// Update gallery clustering.
    public func update() throws {
        guard let gallery = getOrCreateGallery() else { return }
        // updateAndReturnError:progressHandler: — pass nil for progress handler
        let sel = "updateAndReturnError:progressHandler:"
        if ObjCBridge.responds(gallery, to: sel) {
            let (_, error) = ObjCBridge.msgSendErrorBlock(gallery, sel) { _ in }
            if let error { throw error }
        }
    }

    /// Get the face gallery version.
    public var version: Int? {
        guard let gallery = getOrCreateGallery() else { return nil }
        return ObjCBridge.call(gallery, "version") as? Int
    }

    /// Get current faceprint revision.
    public var faceprintRevision: Int? {
        guard let gallery = getOrCreateGallery() else { return nil }
        return ObjCBridge.call(gallery, "faceprintRevision") as? Int
    }

    // MARK: - Private

    private func getOrCreateGallery() -> AnyObject? {
        if _galleryInitialized { return _gallery }
        _galleryInitialized = true

        // VUWGallery initWithPath:error:
        guard let galleryCls = loader.classNamed("VUWGallery") else { return nil }
        let allocSel = NSSelectorFromString("alloc")
        guard galleryCls.responds(to: allocSel),
              let allocated = (galleryCls as AnyObject).perform(allocSel)?.takeUnretainedValue() else {
            return nil
        }

        // Verify the init selector exists before calling — avoids ObjC exceptions
        let initSel = NSSelectorFromString("initWithPath:error:")
        guard (allocated as AnyObject).responds(to: initSel) else {
            print("[FaceGallery] VUWGallery does not respond to initWithPath:error:")
            return nil
        }

        let dbPath = galleryPath.path as NSString
        let (result, error) = ObjCBridge.msgSendObjError(
            allocated, "initWithPath:error:", dbPath
        )
        if let error {
            print("[FaceGallery] VUWGallery init error: \(error)")
            return nil
        }
        _gallery = result
        return result
    }

    private func getOrCreateStreamingGallery() -> AnyObject? {
        if let existing = _streamingGallery { return existing }

        guard let sgCls = loader.classNamed("VUWStreamingGallery") else { return nil }
        let allocSel = NSSelectorFromString("alloc")
        guard sgCls.responds(to: allocSel),
              let allocated = (sgCls as AnyObject).perform(allocSel)?.takeUnretainedValue() else {
            return nil
        }

        let dbPath = galleryPath.path as NSString

        // Try initWithPath:configuration:error: first
        if ObjCBridge.responds(allocated as AnyObject, to: "initWithPath:configuration:error:") {
            // Try with nil configuration
            let (result, _) = ObjCBridge.msgSendObjObjError(
                allocated as AnyObject, "initWithPath:configuration:error:",
                dbPath, NSNull()
            )
            if let result {
                _streamingGallery = result
                return result
            }
        }

        // Try initWithConfiguration:error:
        if ObjCBridge.responds(allocated as AnyObject, to: "initWithConfiguration:error:") {
            // Create a VUWStreamingGalleryConfiguration if available
            if let configCls = loader.classNamed("VUWStreamingGalleryConfiguration"),
               let config = ObjCBridge.create(configCls) {
                ObjCBridge.setValue(config, value: galleryPath.path as NSString, forKey: "path")
                let (result, _) = ObjCBridge.msgSendObjError(
                    allocated as AnyObject, "initWithConfiguration:error:", config
                )
                if let result {
                    _streamingGallery = result
                    return result
                }
            }
        }

        return nil
    }

    private func addObservationSync(
        faceImage: CGImage,
        assetID: String,
        identityHint: String?
    ) throws -> String {
        // Step 1: Detect face via Vision
        let handler = VNImageRequestHandler(cgImage: faceImage, options: [:])
        let faceRequest = VNDetectFaceRectanglesRequest()
        try handler.perform([faceRequest])

        guard let face = faceRequest.results?.first else {
            throw FrameworkError.invocationFailed("No face detected in image")
        }

        // Step 2: Try VUWStreamingGallery path (simpler)
        if let sg = getOrCreateStreamingGallery() {
            if let vuObs = createVUWObservation(from: face) {
                let tag = createVUWTag(assetID: assetID)
                let (_, error) = ObjCBridge.msgSendObjObjError(
                    sg, "addObservation:tag:error:", vuObs, tag ?? NSNull() as AnyObject
                )
                if let error { throw error }
                return assetID
            }
        }

        // Step 3: Try VUWGallery mutation path
        if let gallery = getOrCreateGallery() {
            if let vuObs = createVUWObservation(from: face) {
                let context = createVUWGalleryContext(assetID: assetID)
                let (success, error) = ObjCBridge.msgSendErrorBlock(
                    gallery, "mutateAndReturnError:handler:"
                ) { transaction in
                    // Inside the transaction block
                    let _ = ObjCBridge.msgSendObjObjIntObjError(
                        transaction,
                        "addWithObservation:context:priority:at:error:",
                        vuObs, context ?? NSNull() as AnyObject, 0, NSDate() as AnyObject
                    )
                }
                if let error { throw error }
                if success { return assetID }
            }
        }

        // Fallback: store to disk
        try storeFaceObservation(face: face, assetID: assetID, identityID: identityHint ?? UUID().uuidString, image: faceImage)
        return identityHint ?? assetID
    }

    private func createVUWObservation(from face: VNFaceObservation) -> AnyObject? {
        guard let obsCls = loader.classNamed("VUWObservation") else { return nil }
        let allocSel = NSSelectorFromString("alloc")
        guard obsCls.responds(to: allocSel),
              let allocated = (obsCls as AnyObject).perform(allocSel)?.takeUnretainedValue() else {
            return nil
        }

        // initWithPersonObservation:embeddingExpiration:contextualEmbeddingExpiration:error:
        let sel = "initWithPersonObservation:embeddingExpiration:contextualEmbeddingExpiration:error:"
        if ObjCBridge.responds(allocated as AnyObject, to: sel) {
            let (result, _) = ObjCBridge.msgSendObjObjIntError(
                allocated as AnyObject, sel,
                face as AnyObject, NSNull() as AnyObject, 0
            )
            if let result { return result }
        }

        // Try simpler init
        let result = ObjCBridge.call(allocated as AnyObject, "initWithObservation:error:", with: face)
        return result as AnyObject?
    }

    private func createVUWGalleryContext(assetID: String) -> AnyObject? {
        guard let ctxCls = loader.classNamed("VUWGalleryContext") else { return nil }
        guard let ctx = ObjCBridge.create(ctxCls) else { return nil }
        // initWithMoment:asset:source:
        let uuid = UUID(uuidString: assetID) ?? UUID()
        ObjCBridge.setValue(ctx, value: uuid as NSUUID, forKey: "asset")
        return ctx
    }

    private func createVUWTag(assetID: String) -> AnyObject? {
        guard let tagCls = loader.classNamed("VUWTag") else { return nil }
        return ObjCBridge.create(tagCls)
    }

    private func matchFace(observation: VNFaceObservation, in image: CGImage) throws -> FaceMatch? {
        guard let gallery = getOrCreateGallery() else { return nil }

        // Create VUWObservation from VNFaceObservation
        guard let vuObs = createVUWObservation(from: observation) else { return nil }

        // recognize:context:recognitionPreset:error:
        let ctx = createVUWGalleryContext(assetID: UUID().uuidString) ?? NSNull() as AnyObject
        let (result, _) = ObjCBridge.msgSendObjObjIntError(
            gallery, "recognize:context:recognitionPreset:error:",
            vuObs, ctx, 0  // preset 0 = default
        )

        // Result should be an array of VUWRecognition objects
        if let recognitions = result as? [AnyObject], let first = recognitions.first {
            let score = ObjCBridge.getValue(first, forKey: "score")
            let tag = ObjCBridge.getValue(first, forKey: "tag")

            let confidence = (score as? NSNumber)?.floatValue ?? 0
            let tagStr = tag as? String

            return FaceMatch(
                identityID: tagStr ?? "unknown",
                identityName: tagStr,
                confidence: confidence,
                boundingBox: observation.boundingBox
            )
        }

        // Try VUWStreamingGallery recognize path
        if let sg = getOrCreateStreamingGallery() {
            let (sgResult, _) = ObjCBridge.msgSendObjIntBoolError(
                sg, "recognizeWithObservation:k:confirmedOnly:error:",
                vuObs, 5, false  // top-5 matches, include unconfirmed
            )
            if let matches = sgResult as? [AnyObject], let first = matches.first {
                let score = ObjCBridge.getValue(first, forKey: "score")
                let tag = ObjCBridge.getValue(first, forKey: "tag")
                return FaceMatch(
                    identityID: (tag as? String) ?? "unknown",
                    identityName: tag as? String,
                    confidence: (score as? NSNumber)?.floatValue ?? 0,
                    boundingBox: observation.boundingBox
                )
            }
        }

        return nil
    }

    private func detectFaces(image: CGImage) async throws -> [VNFaceObservation] {
        try await withCheckedThrowingContinuation { cont in
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            let request = VNDetectFaceRectanglesRequest { request, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                cont.resume(returning: request.results as? [VNFaceObservation] ?? [])
            }
            do {
                try handler.perform([request])
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    private func storeFaceObservation(
        face: VNFaceObservation,
        assetID: String,
        identityID: String,
        image: CGImage
    ) throws {
        let facesDir = galleryPath.appendingPathComponent("faces")
        try FileManager.default.createDirectory(at: facesDir, withIntermediateDirectories: true)

        let faceData: [String: Any] = [
            "assetID": assetID,
            "identityID": identityID,
            "boundingBox": [
                "x": face.boundingBox.origin.x,
                "y": face.boundingBox.origin.y,
                "width": face.boundingBox.width,
                "height": face.boundingBox.height,
            ],
        ]

        let data = try JSONSerialization.data(withJSONObject: faceData, options: .prettyPrinted)
        let filePath = facesDir.appendingPathComponent("\(assetID)_\(identityID).json")
        try data.write(to: filePath)
    }

    private func loadIdentitiesFromDisk() throws -> [Identity] {
        let facesDir = galleryPath.appendingPathComponent("faces")
        guard FileManager.default.fileExists(atPath: facesDir.path) else { return [] }

        let files = try FileManager.default.contentsOfDirectory(at: facesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        var identityMap: [String: Int] = [:]
        for file in files {
            let data = try Data(contentsOf: file)
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let identityID = dict["identityID"] as? String {
                identityMap[identityID, default: 0] += 1
            }
        }

        return identityMap.map { Identity(id: $0.key, observationCount: $0.value) }
    }
}
