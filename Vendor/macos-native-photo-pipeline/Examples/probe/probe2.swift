#!/usr/bin/env swift
/// Deep probe of aesthetics VN request classes + a real image test.

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
    let methods = methodNames(of: cls).sorted()
    let props = propertyNames(of: cls).sorted()
    print("\n=== \(name) ===")
    print("  Methods (\(methods.count)):")
    for m in methods { print("    \(m)") }
    print("  Properties (\(props.count)):")
    for p in props { print("    \(p)") }

    // Also check superclass
    if let superCls = class_getSuperclass(cls) {
        let superName = NSStringFromClass(superCls)
        print("  Superclass: \(superName)")
    }
}

// Load frameworks
dlopen("/System/Library/PrivateFrameworks/VisionCore.framework/VisionCore", RTLD_LAZY)
dlopen("/System/Library/PrivateFrameworks/MediaAnalysis.framework/MediaAnalysis", RTLD_LAZY)
dlopen("/System/Library/Frameworks/Vision.framework/Vision", RTLD_LAZY)

print("=== Deep Probe: Aesthetics Classes ===")

dumpClass("VNClassifyImageAestheticsRequest")
dumpClass("VNCalculateImageAestheticsScoresRequest")
dumpClass("VNClassifyJunkImageRequest")

// Also check VNSceneClassificationRequest — it might return aesthetics too
dumpClass("VNSceneClassificationRequest")

// Check the observation type
dumpClass("VNClassificationObservation")

// Now try actually running these requests on a real image
print("\n\n=== LIVE TEST ===\n")

// Find a test image
let testDir = ProcessInfo.processInfo.environment["PHOTO_PIPELINE_TEST_DIR"] ?? NSString(string: "~/Pictures").expandingTildeInPath
let fm = FileManager.default
guard let files = try? fm.contentsOfDirectory(atPath: testDir) else {
    print("No files in test dir")
    exit(1)
}

let imageFile = files.first { f in
    let ext = (f as NSString).pathExtension.lowercased()
    return ["jpg", "jpeg", "png", "heic"].contains(ext)
}

guard let imageFile else {
    print("No images found")
    exit(1)
}

let imageURL = URL(fileURLWithPath: testDir).appendingPathComponent(imageFile)
print("Test image: \(imageFile)")

guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("Failed to load image")
    exit(1)
}

print("Image size: \(cgImage.width)x\(cgImage.height)")

// Import Vision dynamically
let visionPath = "/System/Library/Frameworks/Vision.framework/Vision"
guard let _ = dlopen(visionPath, RTLD_LAZY) else {
    print("Failed to load Vision")
    exit(1)
}

// Helper to create and run a VN request by class name
func tryRequest(_ className: String, image: CGImage) {
    print("\n--- Testing \(className) ---")
    guard let cls = NSClassFromString(className) else {
        print("  Class not found")
        return
    }

    // Create via alloc/init
    let allocSel = NSSelectorFromString("alloc")
    let initSel = NSSelectorFromString("init")
    guard cls.responds(to: allocSel) else {
        print("  Can't alloc")
        return
    }

    guard let allocated = (cls as AnyObject).perform(allocSel)?.takeUnretainedValue() as? NSObject else {
        print("  Alloc failed")
        return
    }

    guard let request = allocated.perform(initSel)?.takeUnretainedValue() as? NSObject else {
        print("  Init failed")
        return
    }

    print("  Created request: \(type(of: request))")

    // List methods on instance
    let methods = methodNames(of: type(of: request))
    let resultMethods = methods.filter {
        $0.contains("result") || $0.contains("Result") ||
        $0.contains("observation") || $0.contains("Observation")
    }
    print("  Result-related methods: \(resultMethods)")

    // Try to use it as a VNRequest via VNImageRequestHandler
    let handlerCls = NSClassFromString("VNImageRequestHandler")!
    let handlerAllocSel = NSSelectorFromString("alloc")
    let handlerInitSel = NSSelectorFromString("initWithCGImage:options:")

    guard let handlerAllocated = (handlerCls as AnyObject).perform(handlerAllocSel)?.takeUnretainedValue() as? NSObject else {
        print("  Handler alloc failed")
        return
    }

    guard let handler = handlerAllocated.perform(handlerInitSel, with: image, with: [:] as NSDictionary)?.takeUnretainedValue() as? NSObject else {
        print("  Handler init failed")
        return
    }

    // performRequests:error:
    let performSel = NSSelectorFromString("performRequests:error:")
    if handler.responds(to: performSel) {
        let requestArray = [request] as NSArray
        var error: NSError?
        let errorPtr = withUnsafeMutablePointer(to: &error) { $0 }

        // Use perform to call performRequests:error:
        handler.perform(performSel, with: requestArray, with: errorPtr)

        if let err = error {
            print("  Perform error: \(err)")
        }

        // Try to get results
        let resultsSel = NSSelectorFromString("results")
        if request.responds(to: resultsSel),
           let results = request.perform(resultsSel)?.takeUnretainedValue() {
            print("  Results type: \(type(of: results))")
            if let arr = results as? NSArray {
                print("  Results count: \(arr.count)")
                for (i, obj) in arr.enumerated() {
                    let nsObj = obj as! NSObject
                    print("  [\(i)] type: \(type(of: nsObj))")

                    // Try to read properties
                    for key in ["identifier", "confidence", "score",
                                "aestheticsScore", "overallScore",
                                "qualityScore", "isJunk", "label"] {
                        if nsObj.responds(to: NSSelectorFromString(key)) {
                            if let val = nsObj.value(forKey: key) {
                                print("       \(key) = \(val)")
                            }
                        }
                    }
                }
            } else {
                print("  Results: \(results)")
            }
        } else {
            print("  No results accessor")
        }
    }
}

tryRequest("VNClassifyImageAestheticsRequest", image: cgImage)
tryRequest("VNCalculateImageAestheticsScoresRequest", image: cgImage)
tryRequest("VNClassifyJunkImageRequest", image: cgImage)
