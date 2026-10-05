#!/usr/bin/env swift
/// Runtime probe for private framework classes related to aesthetics scoring.
/// Discovers available classes, methods, and properties to find the simplest
/// path to getting aesthetics data from Apple's scene classification backbone.

import Foundation
import ObjectiveC

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

func probe(_ className: String, framework: String? = nil) {
    guard let cls = NSClassFromString(className) else {
        print("  \(className): NOT FOUND")
        return
    }
    let methods = methodNames(of: cls)
    let props = propertyNames(of: cls)
    print("  \(className): FOUND (\(methods.count) methods, \(props.count) properties)")

    // Show aesthetics-related methods
    let aestheticsMethods = methods.filter {
        $0.lowercased().contains("aesthet") || $0.lowercased().contains("quality") ||
        $0.lowercased().contains("score") || $0.lowercased().contains("junk")
    }
    if !aestheticsMethods.isEmpty {
        print("    AESTHETICS METHODS:")
        for m in aestheticsMethods.sorted() { print("      - \(m)") }
    }

    let aestheticsProps = props.filter {
        $0.lowercased().contains("aesthet") || $0.lowercased().contains("quality") ||
        $0.lowercased().contains("score") || $0.lowercased().contains("junk")
    }
    if !aestheticsProps.isEmpty {
        print("    AESTHETICS PROPERTIES:")
        for p in aestheticsProps.sorted() { print("      - \(p)") }
    }
}

func probeAll(_ className: String) {
    guard let cls = NSClassFromString(className) else {
        print("  \(className): NOT FOUND")
        return
    }
    let methods = methodNames(of: cls)
    let props = propertyNames(of: cls)
    print("  \(className): \(methods.count) methods, \(props.count) properties")
    print("    METHODS:")
    for m in methods.sorted() { print("      \(m)") }
    print("    PROPERTIES:")
    for p in props.sorted() { print("      \(p)") }
}

// MARK: - Load frameworks

print("=== Loading Private Frameworks ===\n")

let frameworks = [
    "MediaAnalysis", "VisionCore", "Vision", "PhotoAnalysis"
]

for fw in frameworks {
    let path = "/System/Library/PrivateFrameworks/\(fw).framework/\(fw)"
    let publicPath = "/System/Library/Frameworks/\(fw).framework/\(fw)"
    if let _ = dlopen(path, RTLD_LAZY) {
        print("  \(fw): loaded (private)")
    } else if let _ = dlopen(publicPath, RTLD_LAZY) {
        print("  \(fw): loaded (public)")
    } else {
        print("  \(fw): FAILED - \(String(cString: dlerror()))")
    }
}

// MARK: - Probe scene/aesthetics classes

print("\n=== Scene Classification Classes ===\n")

// MediaAnalysis scene task
probe("VCPMADVISceneClassificationTask")
probe("VCPMADVISceneClassificationResource")
probe("VCPPreAnalyzer")
probe("VCPSharedImageBackboneAnalyzer")
probe("VCPImageBackboneAnalyzer")
probe("VCPPhotoAnalyzer")

print("\n=== VisionCore SceneNet ===\n")

probe("VisionCoreSceneNetInferenceNetworkDescriptor")
probe("VisionCoreInferenceNetworkDescriptor")
probe("VisionCoreClassificationMetrics")
probe("VisionCoreValueConfidenceCurve")

print("\n=== Vision Private Requests ===\n")

// Check for private VN request classes related to aesthetics
let vnClassNames = [
    "VNClassifyImageAestheticsRequest",
    "VNClassifyJunkImageRequest",
    "VNSceneClassificationRequest",
    "VNGenerateImageScoreRequest",
    "VNGenerateImageQualityScoreRequest",
    "VNCalculateImageAestheticsScoresRequest",
    "VNGenerateImageAestheticsScoreRequest",
    "VNClassifyImageQualityRequest",
    "VNGenerateAttentionBasedSaliencyImageRequest",
    "VNGenerateObjectnessBasedSaliencyImageRequest",
]

for name in vnClassNames {
    probe(name)
}

// MARK: - Deep dive on SceneNet descriptor

print("\n=== FULL DUMP: VisionCoreSceneNetInferenceNetworkDescriptor ===\n")
probeAll("VisionCoreSceneNetInferenceNetworkDescriptor")

print("\n=== FULL DUMP: VCPPreAnalyzer ===\n")
probeAll("VCPPreAnalyzer")

// Also check for custom classifier descriptors
print("\n=== Custom Classifiers ===\n")
probe("VisionCoreCustomClassifierDescriptor")
probe("VisionCoreClassificationMetrics")

// Check if there are VN observation types for aesthetics
print("\n=== VN Observation Types ===\n")
probe("VNClassificationObservation")
probe("VNFeaturePrintObservation")
probe("VNRecognizedObjectObservation")
