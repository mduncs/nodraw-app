import Foundation
import ObjectiveC

// MARK: - Type-safe ObjC runtime wrappers

/// Wrapper for calling ObjC methods on dynamically loaded classes.
/// Provides type-safe(ish) wrappers around objc_msgSend for common patterns
/// found in Apple's private frameworks.
public enum ObjCBridge {

    // MARK: - Object creation

    /// Allocate and init an ObjC object: [[ClassName alloc] init]
    public static func create(_ cls: AnyClass) -> NSObject? {
        let sel = NSSelectorFromString("alloc")
        guard cls.responds(to: sel) else { return nil }
        let allocated = performSelector(cls, sel) as? NSObject
        return allocated?.perform(NSSelectorFromString("init"))?.takeUnretainedValue() as? NSObject
    }

    /// Allocate and call initWithURL: on an ObjC class.
    public static func create(_ cls: AnyClass, url: URL) -> NSObject? {
        let sel = NSSelectorFromString("alloc")
        guard cls.responds(to: sel) else { return nil }
        let allocated = performSelector(cls, sel) as? NSObject
        let initSel = NSSelectorFromString("initWithURL:")
        guard let allocated, allocated.responds(to: initSel) else { return nil }
        return allocated.perform(initSel, with: url)?.takeUnretainedValue() as? NSObject
    }

    // MARK: - Method invocation

    /// Call a no-argument selector on an object, returning the result.
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

    /// Call a selector with two arguments.
    @discardableResult
    public static func call(_ target: AnyObject, _ selectorName: String, with arg1: Any?, with arg2: Any?) -> Any? {
        let sel = NSSelectorFromString(selectorName)
        guard (target as? NSObject)?.responds(to: sel) ?? false else { return nil }
        return (target as? NSObject)?.perform(sel, with: arg1, with: arg2)?.takeUnretainedValue()
    }

    /// Call a class method (no args).
    @discardableResult
    public static func callClass(_ cls: AnyClass, _ selectorName: String) -> Any? {
        let sel = NSSelectorFromString(selectorName)
        guard cls.responds(to: sel) else { return nil }
        return performSelector(cls, sel)
    }

    /// Call a class method with one argument.
    @discardableResult
    public static func callClass(_ cls: AnyClass, _ selectorName: String, with arg: Any?) -> Any? {
        let sel = NSSelectorFromString(selectorName)
        guard cls.responds(to: sel) else { return nil }
        // Use NSObject bridge for class method dispatch
        let nsClass = cls as AnyObject
        return (nsClass as? NSObject)?.perform(sel, with: arg)?.takeUnretainedValue()
    }

    // MARK: - Property access

    /// Read a property value via KVC.
    public static func getValue(_ target: AnyObject, forKey key: String) -> Any? {
        (target as? NSObject)?.value(forKey: key)
    }

    /// Set a property value via KVC.
    public static func setValue(_ target: AnyObject, value: Any?, forKey key: String) {
        (target as? NSObject)?.setValue(value, forKey: key)
    }

    // MARK: - Selector checking

    /// Check if an object responds to a selector.
    public static func responds(_ target: AnyObject, to selectorName: String) -> Bool {
        (target as? NSObject)?.responds(to: NSSelectorFromString(selectorName)) ?? false
    }

    /// Check if a class responds to a selector.
    public static func classResponds(_ cls: AnyClass, to selectorName: String) -> Bool {
        cls.responds(to: NSSelectorFromString(selectorName))
    }

    /// List all method names on a class (for debugging/discovery).
    public static func methodNames(of cls: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return [] }
        defer { free(methods) }
        return (0..<Int(count)).compactMap { i in
            let sel = method_getName(methods[i])
            return NSStringFromSelector(sel)
        }
    }

    /// List all property names on a class.
    public static func propertyNames(of cls: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let properties = class_copyPropertyList(cls, &count) else { return [] }
        defer { free(properties) }
        return (0..<Int(count)).compactMap { i in
            let name = property_getName(properties[i])
            return String(cString: name)
        }
    }

    // MARK: - Ivar access

    /// List ivar names and offsets on a class.
    public static func ivarNames(of cls: AnyClass) -> [(name: String, offset: Int)] {
        var count: UInt32 = 0
        guard let ivars = class_copyIvarList(cls, &count) else { return [] }
        defer { free(ivars) }
        return (0..<Int(count)).compactMap { i in
            guard let name = ivar_getName(ivars[i]) else { return nil }
            return (String(cString: name), ivar_getOffset(ivars[i]))
        }
    }

    /// Get an object ivar value by name.
    public static func getIvar(_ obj: AnyObject, named name: String) -> AnyObject? {
        let cls: AnyClass = type(of: obj)
        guard let ivar = class_getInstanceVariable(cls, name) else { return nil }
        return object_getIvar(obj, ivar) as AnyObject?
    }

    // MARK: - Typed objc_msgSend

    /// Raw pointer to objc_msgSend for typed calls.
    /// Required when method parameters include non-object types (int, bool, etc.)
    /// that can't be passed via NSObject.perform(_:with:).
    private static let _msgSend: UnsafeMutableRawPointer = {
        dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend")!
    }()

    /// Call method taking (UInt64, UInt8) → id. For init patterns with integer args.
    public static func msgSendInitUInt64UInt8(
        _ target: AnyObject, _ selectorName: String,
        _ arg1: UInt64, _ arg2: UInt8
    ) -> AnyObject? {
        typealias F = @convention(c) (AnyObject, Selector, UInt64, UInt8) -> AnyObject?
        let fn = unsafeBitCast(_msgSend, to: F.self)
        return fn(target, NSSelectorFromString(selectorName), arg1, arg2)
    }

    /// Call method taking (id, UInt32) → id. For textEmbeddingForQuery:useFP16:.
    public static func msgSendIdUInt32(
        _ target: AnyObject, _ selectorName: String,
        _ obj: AnyObject, _ val: UInt32
    ) -> AnyObject? {
        typealias F = @convention(c) (AnyObject, Selector, AnyObject, UInt32) -> AnyObject?
        let fn = unsafeBitCast(_msgSend, to: F.self)
        return fn(target, NSSelectorFromString(selectorName), obj, val)
    }

    /// Call method taking (OpaquePointer?) → Bool. For loadResources: with NSError** out-param.
    public static func msgSendWithErrorPtr(
        _ target: AnyObject, _ selectorName: String,
        _ errorPtr: OpaquePointer? = nil
    ) -> Bool {
        typealias F = @convention(c) (AnyObject, Selector, OpaquePointer?) -> UInt8
        let fn = unsafeBitCast(_msgSend, to: F.self)
        return fn(target, NSSelectorFromString(selectorName), errorPtr) != 0
    }

    /// Call method taking (id, NSError**) → id. For initWithPath:error:, initWithOptions:error:.
    public static func msgSendObjError(
        _ target: AnyObject, _ selectorName: String,
        _ arg: AnyObject
    ) -> (result: AnyObject?, error: NSError?) {
        var error: NSError?
        typealias F = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>) -> AnyObject?
        let fn = unsafeBitCast(_msgSend, to: F.self)
        let result = fn(target, NSSelectorFromString(selectorName), arg, &error)
        return (result, error)
    }

    /// Call method taking (id, id, Int, NSError**) → id. For recognize:context:recognitionPreset:error:.
    public static func msgSendObjObjIntError(
        _ target: AnyObject, _ selectorName: String,
        _ arg1: AnyObject, _ arg2: AnyObject, _ arg3: Int
    ) -> (result: AnyObject?, error: NSError?) {
        var error: NSError?
        typealias F = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, Int, UnsafeMutablePointer<NSError?>) -> AnyObject?
        let fn = unsafeBitCast(_msgSend, to: F.self)
        let result = fn(target, NSSelectorFromString(selectorName), arg1, arg2, arg3, &error)
        return (result, error)
    }

    /// Call method taking (id, Int, Bool, NSError**) → id. For recognizeWithObservation:k:confirmedOnly:error:.
    public static func msgSendObjIntBoolError(
        _ target: AnyObject, _ selectorName: String,
        _ arg1: AnyObject, _ arg2: Int, _ arg3: Bool
    ) -> (result: AnyObject?, error: NSError?) {
        var error: NSError?
        typealias F = @convention(c) (AnyObject, Selector, AnyObject, Int, UInt8, UnsafeMutablePointer<NSError?>) -> AnyObject?
        let fn = unsafeBitCast(_msgSend, to: F.self)
        let result = fn(target, NSSelectorFromString(selectorName), arg1, arg2, arg3 ? 1 : 0, &error)
        return (result, error)
    }

    /// Call method taking (NSError**, @convention(block) (AnyObject) → Void) → Bool.
    /// For mutateAndReturnError:handler:.
    public static func msgSendErrorBlock(
        _ target: AnyObject, _ selectorName: String,
        handler: @escaping @convention(block) (AnyObject) -> Void
    ) -> (success: Bool, error: NSError?) {
        var error: NSError?
        typealias F = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>, @convention(block) (AnyObject) -> Void) -> UInt8
        let fn = unsafeBitCast(_msgSend, to: F.self)
        let result = fn(target, NSSelectorFromString(selectorName), &error, handler)
        return (result != 0, error)
    }

    /// Call method taking (id, id, NSError**) → id. For initWithPath:configuration:error:.
    public static func msgSendObjObjError(
        _ target: AnyObject, _ selectorName: String,
        _ arg1: AnyObject, _ arg2: AnyObject
    ) -> (result: AnyObject?, error: NSError?) {
        var error: NSError?
        typealias F = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, UnsafeMutablePointer<NSError?>) -> AnyObject?
        let fn = unsafeBitCast(_msgSend, to: F.self)
        let result = fn(target, NSSelectorFromString(selectorName), arg1, arg2, &error)
        return (result, error)
    }

    /// Call method taking (id, id, Int, NSDate*, NSError**) → id.
    /// For addWithObservation:context:priority:at:error:.
    public static func msgSendObjObjIntObjError(
        _ target: AnyObject, _ selectorName: String,
        _ arg1: AnyObject, _ arg2: AnyObject, _ arg3: Int, _ arg4: AnyObject
    ) -> (result: AnyObject?, error: NSError?) {
        var error: NSError?
        typealias F = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, Int, AnyObject, UnsafeMutablePointer<NSError?>) -> AnyObject?
        let fn = unsafeBitCast(_msgSend, to: F.self)
        let result = fn(target, NSSelectorFromString(selectorName), arg1, arg2, arg3, arg4, &error)
        return (result, error)
    }

    /// Call method taking (NSError**) → Bool. For prewarmAndReturnError:, updateAndReturnError:.
    public static func msgSendErrorOnly(
        _ target: AnyObject, _ selectorName: String
    ) -> (success: Bool, error: NSError?) {
        var error: NSError?
        typealias F = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> UInt8
        let fn = unsafeBitCast(_msgSend, to: F.self)
        let result = fn(target, NSSelectorFromString(selectorName), &error)
        return (result != 0, error)
    }

    // MARK: - Private helpers

    private static func performSelector(_ target: AnyObject, _ sel: Selector) -> Any? {
        let nsObj = target as? NSObject
        return nsObj?.perform(sel)?.takeUnretainedValue()
    }
}

// MARK: - Result type for ObjC calls with NSError out-params

/// Wraps an ObjC method call that uses NSError** out-parameter pattern.
public func objcTry<T>(_ body: (UnsafeMutablePointer<NSError?>) -> T?) -> Result<T, Error> {
    var error: NSError?
    let result = body(&error)
    if let error {
        return .failure(error)
    }
    guard let result else {
        return .failure(FrameworkError.invocationFailed("Method returned nil without error"))
    }
    return .success(result)
}
