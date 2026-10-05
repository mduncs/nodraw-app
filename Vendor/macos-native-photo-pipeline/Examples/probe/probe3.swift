#!/usr/bin/env swift
/// Probe the aesthetics observation types for all available scores.

import Foundation
import ObjectiveC
import CoreGraphics
import ImageIO

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
    print("\n=== \(name) ===")
    for m in methodNames(of: cls).sorted() { print("  method: \(m)") }
    for p in propertyNames(of: cls).sorted() { print("  prop: \(p)") }
    if let sup = class_getSuperclass(cls) { print("  super: \(NSStringFromClass(sup))") }
}

// Load frameworks
dlopen("/System/Library/Frameworks/Vision.framework/Vision", RTLD_LAZY)
dlopen("/System/Library/PrivateFrameworks/VisionCore.framework/VisionCore", RTLD_LAZY)
dlopen("/System/Library/PrivateFrameworks/MediaAnalysis.framework/MediaAnalysis", RTLD_LAZY)

// Dump the observation types
dumpClass("VNImageAestheticsObservation")
dumpClass("VNImageAestheticsScoresObservation")

// Now run on a few different images to calibrate the score range
print("\n\n=== MULTI-IMAGE AESTHETICS TEST ===\n")

let testDir = ProcessInfo.processInfo.environment["PHOTO_PIPELINE_TEST_DIR"] ?? NSString(string: "~/Pictures").expandingTildeInPath
let fm = FileManager.default
guard let files = try? fm.contentsOfDirectory(atPath: testDir) else {
    print("No test dir")
    exit(1)
}

let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic"]
let images = files.filter { imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
    .prefix(10)

for file in images {
    let url = URL(fileURLWithPath: testDir).appendingPathComponent(file)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        continue
    }

    // Run VNCalculateImageAestheticsScoresRequest
    let cls: AnyClass = NSClassFromString("VNCalculateImageAestheticsScoresRequest")!
    let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    let request = allocated.perform(NSSelectorFromString("init"))!.takeUnretainedValue() as! NSObject

    let handlerCls: AnyClass = NSClassFromString("VNImageRequestHandler")!
    let handlerAlloc = (handlerCls as AnyObject).perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    let handler = handlerAlloc.perform(NSSelectorFromString("initWithCGImage:options:"), with: cgImage, with: [:] as NSDictionary)!.takeUnretainedValue() as! NSObject

    handler.perform(NSSelectorFromString("performRequests:error:"), with: [request] as NSArray, with: nil)

    if let results = request.perform(NSSelectorFromString("results"))?.takeUnretainedValue() as? NSArray,
       let obs = results.firstObject as? NSObject {
        // Read ALL properties via KVC
        let obsType = type(of: obs)
        let props = propertyNames(of: obsType)
        var scores: [String] = []
        for p in props {
            if obs.responds(to: NSSelectorFromString(p)) {
                if let val = obs.value(forKey: p) {
                    scores.append("\(p)=\(val)")
                }
            }
        }
        // Also try known score names
        for key in ["overallScore", "pleasantnessScore", "harmonyScore",
                     "immersiveScore", "interestingContentScore",
                     "interactionScore", "balancedElementsScore",
                     "goodLightingScore", "naturalLightingScore",
                     "sharpFocusScore", "vividColorScore",
                     "backgroundScore", "depthOfFieldScore",
                     "symmetryScore", "ruleOfThirdsScore",
                     "score", "utility", "failure"] {
            if obs.responds(to: NSSelectorFromString(key)) {
                if let val = obs.value(forKey: key) {
                    if !scores.contains(where: { $0.hasPrefix("\(key)=") }) {
                        scores.append("\(key)=\(val)")
                    }
                }
            }
        }
        print("  \(file): \(scores.joined(separator: ", "))")
    }

    // Also run VNClassifyImageAestheticsRequest
    let cls2: AnyClass = NSClassFromString("VNClassifyImageAestheticsRequest")!
    let allocated2 = (cls2 as AnyObject).perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    let request2 = allocated2.perform(NSSelectorFromString("init"))!.takeUnretainedValue() as! NSObject

    let handler2Alloc = (handlerCls as AnyObject).perform(NSSelectorFromString("alloc"))!.takeUnretainedValue() as! NSObject
    let handler2 = handler2Alloc.perform(NSSelectorFromString("initWithCGImage:options:"), with: cgImage, with: [:] as NSDictionary)!.takeUnretainedValue() as! NSObject

    handler2.perform(NSSelectorFromString("performRequests:error:"), with: [request2] as NSArray, with: nil)

    if let results2 = request2.perform(NSSelectorFromString("results"))?.takeUnretainedValue() as? NSArray,
       let obs2 = results2.firstObject as? NSObject {
        let obsType2 = type(of: obs2)
        let props2 = propertyNames(of: obsType2)
        var scores2: [String] = []
        for p in props2 {
            if obs2.responds(to: NSSelectorFromString(p)) {
                if let val = obs2.value(forKey: p) {
                    scores2.append("\(p)=\(val)")
                }
            }
        }
        // check common keys
        for key in ["isUtility", "isJunk", "overallScore", "label", "identifier",
                     "confidence", "pleasantness", "utility",
                     "aestheticScore", "failure"] {
            if obs2.responds(to: NSSelectorFromString(key)) {
                if let val = obs2.value(forKey: key) {
                    if !scores2.contains(where: { $0.hasPrefix("\(key)=") }) {
                        scores2.append("\(key)=\(val)")
                    }
                }
            }
        }
        print("    Aesthetics: \(scores2.joined(separator: ", "))")
    }
}
