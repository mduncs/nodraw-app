#!/usr/bin/env swift
/// Comprehensive probe: CLIP embeddings, object recognition, face gallery,
/// sceneprint, saliency, fingerprint — everything we haven't wired up yet.

import Foundation
import ObjectiveC
import CoreGraphics
import ImageIO

// MARK: - Helpers

func methodNames(of cls: AnyClass) -> [String] {
    var count: UInt32 = 0
    guard let methods = class_copyMethodList(cls, &count) else { return [] }
    defer { free(methods) }
    return (0..<Int(count)).compactMap { i in
        NSStringFromSelector(method_getName(methods[i]))
    }
}

func propertyNames(of cls: AnyClass) -> [String] {
    var count: UInt32 = 0
    guard let properties = class_copyPropertyList(cls, &count) else { return [] }
    defer { free(properties) }
    return (0..<Int(count)).compactMap { i in
        String(cString: property_getName(properties[i]))
    }
}

func dumpClass(_ name: String) {
    guard let cls = NSClassFromString(name) else {
        print("  \(name): NOT FOUND")
        return
    }
    let methods = methodNames(of: cls).sorted()
    let props = propertyNames(of: cls).sorted()
    print("\n=== \(name) ===")
    print("  Methods (\(methods.count)):")
    for m in methods { print("    \(m)") }
    print("  Properties (\(props.count)):")
    for p in props { print("    \(p)") }
    if let sup = class_getSuperclass(cls) {
        print("  Super: \(NSStringFromClass(sup))")
    }
}

func probeClass(_ name: String) -> Bool {
    guard let cls = NSClassFromString(name) else {
        print("  \(name): NOT FOUND")
        return false
    }
    let mc = methodNames(of: cls).count
    let pc = propertyNames(of: cls).count
    if let sup = class_getSuperclass(cls) {
        print("  \(name): FOUND (\(mc) methods, \(pc) props, super: \(NSStringFromClass(sup)))")
    } else {
        print("  \(name): FOUND (\(mc) methods, \(pc) props)")
    }
    return true
}

// MARK: - Load all frameworks

print("=== LOADING FRAMEWORKS ===\n")

let frameworks = [
    ("/System/Library/Frameworks/Vision.framework/Vision", "Vision"),
    ("/System/Library/PrivateFrameworks/VisionCore.framework/VisionCore", "VisionCore"),
    ("/System/Library/PrivateFrameworks/MediaAnalysis.framework/MediaAnalysis", "MediaAnalysis"),
    ("/System/Library/PrivateFrameworks/VisualUnderstanding.framework/VisualUnderstanding", "VisualUnderstanding"),
    ("/System/Library/PrivateFrameworks/VisualLookup.framework/VisualLookup", "VisualLookup"),
    ("/System/Library/PrivateFrameworks/PhotoAnalysis.framework/PhotoAnalysis", "PhotoAnalysis"),
    ("/System/Library/PrivateFrameworks/SemanticPerception.framework/SemanticPerception", "SemanticPerception"),
    ("/System/Library/PrivateFrameworks/Espresso.framework/Espresso", "Espresso"),
    ("/System/Library/PrivateFrameworks/E5RT.framework/E5RT", "E5RT"),
]

for (path, name) in frameworks {
    if dlopen(path, RTLD_LAZY) != nil {
        print("  \(name): loaded")
    } else {
        print("  \(name): FAILED - \(String(cString: dlerror()))")
    }
}

// MARK: - 1. CLIP Embedding Search

print("\n\n========== CLIP EMBEDDING SEARCH ==========\n")

let clipClasses = [
    "MADEmbeddingStore",
    "MADVectorDatabase",
    "MADSharedTextEncoder",
    "MADImageEmbedding",
    "MADTextEmbedding",
    "MADEmbeddingSearchResult",
    "MADEmbeddingVersion",
    "MADSearchConfiguration",
    "MADEmbeddingStoreConfiguration",
    "VCPMADVIEmbeddingTask",
    "VCPImageEmbeddingTask",
    "VCPSharedImageBackboneAnalyzer",
]

for name in clipClasses {
    if probeClass(name) {
        // Full dump for found classes
        dumpClass(name)
    }
}

// Also check for VN-based embedding requests
print("\n--- VN Embedding Requests ---")
for name in [
    "VNGenerateImageFeaturePrintRequest",
    "VNFeaturePrintObservation",
    "VNGenerateImageEmbeddingRequest",
] {
    probeClass(name)
}

// MARK: - 2. Object Recognition / VisualLookup

print("\n\n========== OBJECT RECOGNITION ==========\n")

let objectClasses = [
    "VLLookupService",
    "VLLookupServiceProvider",
    "VLLookupResult",
    "VLIdentifier",
    "VLRecognizedObject",
    "VLDomainClassifier",
    "VLGNNClassifier",
    "VLRichLabelKV",
    "VLLookupServiceConfiguration",
    "VLQueryImageContext",
    "VCPMADVIVisualSearchGatingTask",
    "VCPMADVIVisualSearchTask",
    "MADVisualSearchResultGroup",
]

for name in objectClasses {
    if probeClass(name) {
        dumpClass(name)
    }
}

// VN-based object detection
print("\n--- VN Object/Detection Requests ---")
for name in [
    "VNRecognizeAnimalsRequest",
    "VNDetectFaceRectanglesRequest",
    "VNDetectFaceLandmarksRequest",
    "VNClassifyImageRequest",
    "VNDetectBarcodesRequest",
    "VNDetectHumanBodyPoseRequest",
    "VNRecognizeTextRequest",
] {
    probeClass(name)
}

// MARK: - 3. Face Gallery

print("\n\n========== FACE GALLERY ==========\n")

let faceClasses = [
    "VUGallery",
    "VUWGallery",
    "VUWFace",
    "VUWPerson",
    "VUWPersonPromoter",
    "VUIndexClusterer",
    "VUFaceObservation",
    "VUFaceEmbedding",
    "VUIdentity",
    "VUGalleryConfiguration",
    "VUWGroupFace",
    "VUWFaceGroup",
]

for name in faceClasses {
    if probeClass(name) {
        dumpClass(name)
    }
}

// MARK: - 4. Sceneprint / Saliency / Fingerprint

print("\n\n========== SCENEPRINT / SALIENCY / FINGERPRINT ==========\n")

let backboneClasses = [
    "VCPMADVISceneClassificationTask",
    "VCPPreAnalyzer",
    "VCPPhotoAnalyzer",
    "VCPImageBackboneAnalyzer",
    "VisionCoreSceneNetInferenceNetworkDescriptor",
]

for name in backboneClasses {
    if probeClass(name) {
        dumpClass(name)
    }
}

// VN Saliency requests
print("\n--- VN Saliency Requests ---")
for name in [
    "VNGenerateAttentionBasedSaliencyImageRequest",
    "VNGenerateObjectnessBasedSaliencyImageRequest",
    "VNSaliencyImageObservation",
] {
    if probeClass(name) {
        dumpClass(name)
    }
}

// MARK: - 5. LIVE TESTS on real image

print("\n\n========== LIVE TESTS ==========\n")

let testDir = ProcessInfo.processInfo.environment["PHOTO_PIPELINE_TEST_DIR"] ?? NSString(string: "~/Pictures").expandingTildeInPath
let fm = FileManager.default
guard let files = try? fm.contentsOfDirectory(atPath: testDir) else {
    print("No test dir")
    exit(1)
}

let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic"]
let imageFile = files.first { imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
guard let imageFile else { print("No images"); exit(1) }

let imageURL = URL(fileURLWithPath: testDir).appendingPathComponent(imageFile)
guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("Failed to load image")
    exit(1)
}

print("Test image: \(imageFile) (\(cgImage.width)x\(cgImage.height))")

// --- 5a. VNGenerateImageFeaturePrintRequest ---
print("\n--- Feature Print (public VN) ---")
if let fpCls = NSClassFromString("VNGenerateImageFeaturePrintRequest"),
   let fpReq = (fpCls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject {
    let req = fpReq.perform(NSSelectorFromString("init"))?.takeUnretainedValue() as! NSObject

    let handler = (NSClassFromString("VNImageRequestHandler")! as AnyObject)
        .perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    let h = handler.perform(NSSelectorFromString("initWithCGImage:options:"),
                           with: cgImage, with: [:] as NSDictionary)!.takeUnretainedValue() as! NSObject

    h.perform(NSSelectorFromString("performRequests:error:"), with: [req] as NSArray, with: nil)

    if let results = req.perform(NSSelectorFromString("results"))?.takeUnretainedValue() as? NSArray,
       let obs = results.firstObject as? NSObject {
        print("  Result type: \(type(of: obs))")
        let props = propertyNames(of: type(of: obs))
        for p in props.sorted() {
            if obs.responds(to: NSSelectorFromString(p)) {
                if let val = obs.value(forKey: p) {
                    let desc = "\(val)"
                    print("  \(p) = \(desc.prefix(200))")
                }
            }
        }
    }
}

// --- 5b. Saliency ---
print("\n--- Attention Saliency ---")
if let salCls = NSClassFromString("VNGenerateAttentionBasedSaliencyImageRequest"),
   let salReq = (salCls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject {
    let req = salReq.perform(NSSelectorFromString("init"))?.takeUnretainedValue() as! NSObject

    let handler = (NSClassFromString("VNImageRequestHandler")! as AnyObject)
        .perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    let h = handler.perform(NSSelectorFromString("initWithCGImage:options:"),
                           with: cgImage, with: [:] as NSDictionary)!.takeUnretainedValue() as! NSObject

    h.perform(NSSelectorFromString("performRequests:error:"), with: [req] as NSArray, with: nil)

    if let results = req.perform(NSSelectorFromString("results"))?.takeUnretainedValue() as? NSArray,
       let obs = results.firstObject as? NSObject {
        print("  Result type: \(type(of: obs))")
        let props = propertyNames(of: type(of: obs))
        for p in props.sorted() {
            if obs.responds(to: NSSelectorFromString(p)) {
                if let val = obs.value(forKey: p) {
                    let desc = "\(val)"
                    print("  \(p) = \(desc.prefix(200))")
                }
            }
        }
    }
}

// --- 5c. Objectness Saliency ---
print("\n--- Objectness Saliency ---")
if let objSalCls = NSClassFromString("VNGenerateObjectnessBasedSaliencyImageRequest"),
   let objSalReq = (objSalCls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject {
    let req = objSalReq.perform(NSSelectorFromString("init"))?.takeUnretainedValue() as! NSObject

    let handler = (NSClassFromString("VNImageRequestHandler")! as AnyObject)
        .perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    let h = handler.perform(NSSelectorFromString("initWithCGImage:options:"),
                           with: cgImage, with: [:] as NSDictionary)!.takeUnretainedValue() as! NSObject

    h.perform(NSSelectorFromString("performRequests:error:"), with: [req] as NSArray, with: nil)

    if let results = req.perform(NSSelectorFromString("results"))?.takeUnretainedValue() as? NSArray,
       let obs = results.firstObject as? NSObject {
        print("  Result type: \(type(of: obs))")
        let props = propertyNames(of: type(of: obs))
        for p in props.sorted() {
            if obs.responds(to: NSSelectorFromString(p)) {
                if let val = obs.value(forKey: p) {
                    let desc = "\(val)"
                    print("  \(p) = \(desc.prefix(200))")
                }
            }
        }
    }
}

// --- 5d. RecognizeAnimals ---
print("\n--- Recognize Animals ---")
if let aniCls = NSClassFromString("VNRecognizeAnimalsRequest"),
   let aniReq = (aniCls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject {
    let req = aniReq.perform(NSSelectorFromString("init"))?.takeUnretainedValue() as! NSObject

    let handler = (NSClassFromString("VNImageRequestHandler")! as AnyObject)
        .perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    let h = handler.perform(NSSelectorFromString("initWithCGImage:options:"),
                           with: cgImage, with: [:] as NSDictionary)!.takeUnretainedValue() as! NSObject

    h.perform(NSSelectorFromString("performRequests:error:"), with: [req] as NSArray, with: nil)

    if let results = req.perform(NSSelectorFromString("results"))?.takeUnretainedValue() as? NSArray {
        print("  Results count: \(results.count)")
        for (i, obj) in results.enumerated() {
            let obs = obj as! NSObject
            print("  [\(i)] type: \(type(of: obs))")
            let props = propertyNames(of: type(of: obs))
            for p in props.sorted() {
                if obs.responds(to: NSSelectorFromString(p)) {
                    if let val = obs.value(forKey: p) {
                        let desc = "\(val)"
                        print("    \(p) = \(desc.prefix(200))")
                    }
                }
            }
        }
    }
}

// --- 5e. Face Detection ---
print("\n--- Face Detection ---")
if let faceCls = NSClassFromString("VNDetectFaceRectanglesRequest"),
   let faceReq = (faceCls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject {
    let req = faceReq.perform(NSSelectorFromString("init"))?.takeUnretainedValue() as! NSObject

    let handler = (NSClassFromString("VNImageRequestHandler")! as AnyObject)
        .perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    let h = handler.perform(NSSelectorFromString("initWithCGImage:options:"),
                           with: cgImage, with: [:] as NSDictionary)!.takeUnretainedValue() as! NSObject

    h.perform(NSSelectorFromString("performRequests:error:"), with: [req] as NSArray, with: nil)

    if let results = req.perform(NSSelectorFromString("results"))?.takeUnretainedValue() as? NSArray {
        print("  Faces found: \(results.count)")
        for (i, obj) in results.enumerated().prefix(3) {
            let obs = obj as! NSObject
            print("  [\(i)] type: \(type(of: obs))")
            for key in ["boundingBox", "confidence", "roll", "yaw", "pitch"] {
                if obs.responds(to: NSSelectorFromString(key)),
                   let val = obs.value(forKey: key) {
                    print("    \(key) = \(val)")
                }
            }
        }
    }
}

// --- 5f. Try MADEmbeddingStore ---
print("\n--- MADEmbeddingStore init ---")
if let storeCls = NSClassFromString("MADEmbeddingStore") {
    print("  Class found. Methods:")
    for m in methodNames(of: storeCls).sorted() {
        if m.contains("init") || m.contains("search") || m.contains("embed") || m.contains("add") || m.contains("create") || m.contains("query") {
            print("    \(m)")
        }
    }
}

// --- 5g. Try MADSharedTextEncoder ---
print("\n--- MADSharedTextEncoder init ---")
if let encCls = NSClassFromString("MADSharedTextEncoder") {
    print("  Class found. Methods:")
    for m in methodNames(of: encCls).sorted() {
        print("    \(m)")
    }
    // Try to create
    let allocSel = NSSelectorFromString("alloc")
    if let allocated = (encCls as AnyObject).perform(allocSel)?.takeUnretainedValue() as? NSObject {
        let initSel = NSSelectorFromString("init")
        if allocated.responds(to: initSel),
           let encoder = allocated.perform(initSel)?.takeUnretainedValue() as? NSObject {
            print("  Created encoder: \(type(of: encoder))")
            // Try encoding a string
            for m in methodNames(of: type(of: encoder)).sorted() {
                if m.contains("encode") || m.contains("embed") || m.contains("text") || m.contains("query") {
                    print("    encode-related: \(m)")
                }
            }
        } else {
            print("  Init failed, trying other init methods...")
            for m in methodNames(of: encCls).sorted() {
                if m.hasPrefix("init") { print("    \(m)") }
            }
        }
    }
}

// --- 5h. Try VisualLookup service ---
print("\n--- VLLookupService ---")
if let vlCls = NSClassFromString("VLLookupService") {
    print("  Class found. All methods:")
    for m in methodNames(of: vlCls).sorted() {
        print("    \(m)")
    }
}

// --- 5i. Try VUGallery ---
print("\n--- VUGallery ---")
if let vuCls = NSClassFromString("VUGallery") {
    print("  Class found. Methods with init/add/identify/cluster:")
    for m in methodNames(of: vuCls).sorted() {
        if m.contains("init") || m.contains("add") || m.contains("identify") ||
           m.contains("cluster") || m.contains("gallery") || m.contains("face") ||
           m.contains("person") || m.contains("merge") {
            print("    \(m)")
        }
    }
}

print("\n\n========== PROBE COMPLETE ==========")
