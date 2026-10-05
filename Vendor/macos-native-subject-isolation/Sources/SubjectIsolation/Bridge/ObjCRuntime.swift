import Foundation
import ObjectiveC

/// Errors from private API access.
public enum IsolationError: Error, CustomStringConvertible {
    case classNotFound(String)
    case invocationFailed(String)
    case noSubjectsDetected
    case maskGenerationFailed(String)
    case unsupportedOS

    public var description: String {
        switch self {
        case .classNotFound(let cls):
            return "Class '\(cls)' not found"
        case .invocationFailed(let msg):
            return "Invocation failed: \(msg)"
        case .noSubjectsDetected:
            return "No subjects detected in image"
        case .maskGenerationFailed(let msg):
            return "Mask generation failed: \(msg)"
        case .unsupportedOS:
            return "macOS 14+ required for subject isolation"
        }
    }
}

/// Minimal ObjC bridge for private Vision API access.
/// Provides create/call/KVC wrappers around NSObject.perform/setValue.
public enum ObjCBridge {

    // MARK: - Object creation

    /// [[cls alloc] init]
    public static func create(_ cls: AnyClass) -> NSObject? {
        let allocSel = NSSelectorFromString("alloc")
        guard cls.responds(to: allocSel) else { return nil }
        let allocated = performSelector(cls, allocSel) as? NSObject
        return allocated?.perform(NSSelectorFromString("init"))?.takeRetainedValue() as? NSObject
    }

    // MARK: - Method invocation

    /// Call a no-argument selector, returning the result.
    @discardableResult
    public static func call(_ target: AnyObject, _ selectorName: String) -> Any? {
        let sel = NSSelectorFromString(selectorName)
        guard (target as? NSObject)?.responds(to: sel) ?? false else { return nil }
        return (target as? NSObject)?.perform(sel)?.takeUnretainedValue()
    }

    /// Call a selector with one argument.
    @discardableResult
    public static func call(_ target: AnyObject, _ selectorName: String, with arg: Any?) -> Any? {
        let sel = NSSelectorFromString(selectorName)
        guard (target as? NSObject)?.responds(to: sel) ?? false else { return nil }
        return (target as? NSObject)?.perform(sel, with: arg)?.takeUnretainedValue()
    }

    /// Call a class method with one argument.
    @discardableResult
    public static func callClass(_ cls: AnyClass, _ selectorName: String, with arg: Any?) -> Any? {
        let sel = NSSelectorFromString(selectorName)
        guard cls.responds(to: sel) else { return nil }
        let nsClass = cls as AnyObject
        return (nsClass as? NSObject)?.perform(sel, with: arg)?.takeUnretainedValue()
    }

    // MARK: - Property access (KVC)

    public static func getValue(_ target: AnyObject, forKey key: String) -> Any? {
        (target as? NSObject)?.value(forKey: key)
    }

    public static func setValue(_ target: AnyObject, value: Any?, forKey key: String) {
        (target as? NSObject)?.setValue(value, forKey: key)
    }

    // MARK: - Selector checking

    public static func responds(_ target: AnyObject, to selectorName: String) -> Bool {
        (target as? NSObject)?.responds(to: NSSelectorFromString(selectorName)) ?? false
    }

    // MARK: - Private

    private static func performSelector(_ target: AnyObject, _ sel: Selector) -> Any? {
        (target as? NSObject)?.perform(sel)?.takeUnretainedValue()
    }
}
