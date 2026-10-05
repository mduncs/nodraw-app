import Foundation

/// Errors from framework loading.
public enum FrameworkError: Error, CustomStringConvertible {
    case frameworkNotFound(String, path: String)
    case classNotFound(String, framework: String)
    case methodNotFound(String, className: String)
    case invocationFailed(String)
    case unsupportedOS(current: String, minimum: String)

    public var description: String {
        switch self {
        case .frameworkNotFound(let name, let path):
            return "Framework '\(name)' not found at \(path)"
        case .classNotFound(let cls, let framework):
            return "Class '\(cls)' not found in \(framework)"
        case .methodNotFound(let sel, let className):
            return "Method '\(sel)' not found on \(className)"
        case .invocationFailed(let msg):
            return "Invocation failed: \(msg)"
        case .unsupportedOS(let current, let minimum):
            return "macOS \(current) < required \(minimum)"
        }
    }
}

/// Status of a framework on the current system.
public enum FrameworkStatus: Sendable, CustomStringConvertible {
    case available
    case missing
    case loadError(String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .available: return "available"
        case .missing: return "missing"
        case .loadError(let msg): return "error: \(msg)"
        }
    }
}

/// Handle to a loaded framework — provides class lookup.
public final class FrameworkHandle: @unchecked Sendable {
    public let name: String
    let handle: UnsafeMutableRawPointer

    init(name: String, handle: UnsafeMutableRawPointer) {
        self.name = name
        self.handle = handle
    }

    /// Look up an ObjC class by name.
    public func classNamed(_ name: String) -> AnyClass? {
        NSClassFromString(name)
    }

    /// Look up an ObjC class, throwing if not found.
    public func requireClass(_ name: String) throws -> AnyClass {
        guard let cls = NSClassFromString(name) else {
            throw FrameworkError.classNotFound(name, framework: self.name)
        }
        return cls
    }
}

/// Loads Apple's private frameworks via dlopen.
///
/// These frameworks ship on every Mac in the dyld shared cache but aren't
/// part of the public SDK. Loading them requires non-sandboxed execution
/// (no App Store distribution).
///
/// Usage:
/// ```swift
/// let loader = FrameworkLoader.shared
/// let handle = try loader.load(.mediaAnalysis)
/// let cls = try handle.requireClass("MADEmbeddingStore")
/// ```
public final class FrameworkLoader: @unchecked Sendable {

    public static let shared = FrameworkLoader()

    /// Private frameworks relevant to the photo analysis pipeline.
    public enum Framework: String, CaseIterable, Sendable {
        case mediaAnalysis = "MediaAnalysis"
        case visualUnderstanding = "VisualUnderstanding"
        case visualLookup = "VisualLookUp"
        case visionCore = "VisionCore"
        case textRecognition = "TextRecognition"
        case espresso = "Espresso"
        case photoAnalysis = "PhotoAnalysis"
        case photosIntelligence = "PhotosIntelligence"

        /// Filesystem path to the framework binary.
        public var path: String {
            "/System/Library/PrivateFrameworks/\(rawValue).framework/\(rawValue)"
        }

        /// Path to the framework's Resources directory (ML models live here).
        public var resourcesPath: String {
            "/System/Library/PrivateFrameworks/\(rawValue).framework/Versions/A/Resources"
        }
    }

    private let lock = NSLock()
    private var loaded: [Framework: FrameworkHandle] = [:]

    private init() {}

    /// Load a private framework. Returns a handle for class lookups.
    /// Thread-safe — subsequent calls return the cached handle.
    @discardableResult
    public func load(_ framework: Framework) throws -> FrameworkHandle {
        lock.lock()
        defer { lock.unlock() }

        if let existing = loaded[framework] {
            return existing
        }

        let path = framework.path
        guard let handle = dlopen(path, RTLD_LAZY) else {
            let err = String(cString: dlerror())
            throw FrameworkError.frameworkNotFound(framework.rawValue, path: err)
        }

        let fwHandle = FrameworkHandle(name: framework.rawValue, handle: handle)
        loaded[framework] = fwHandle
        return fwHandle
    }

    /// Look up an ObjC class by name. Searches all loaded frameworks.
    public func classNamed(_ name: String) -> AnyClass? {
        NSClassFromString(name)
    }

    /// Look up a class, loading its framework first if needed.
    public func requireClass(_ name: String, from framework: Framework) throws -> AnyClass {
        let handle = try load(framework)
        return try handle.requireClass(name)
    }

    /// Check availability of all frameworks without loading them.
    public static func availability() -> [Framework: FrameworkStatus] {
        var results: [Framework: FrameworkStatus] = [:]
        for fw in Framework.allCases {
            let path = fw.path
            if FileManager.default.fileExists(atPath: "/System/Library/PrivateFrameworks/\(fw.rawValue).framework") {
                // Try loading to verify it's actually loadable
                if let handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD) {
                    // Already loaded
                    dlclose(handle)
                    results[fw] = .available
                } else if let handle = dlopen(path, RTLD_LAZY) {
                    dlclose(handle)
                    results[fw] = .available
                } else {
                    results[fw] = .loadError(String(cString: dlerror()))
                }
            } else {
                results[fw] = .missing
            }
        }
        return results
    }

    /// Unload all cached frameworks. Generally not needed.
    public func unloadAll() {
        lock.lock()
        defer { lock.unlock() }
        for (_, handle) in loaded {
            dlclose(handle.handle)
        }
        loaded.removeAll()
    }
}
