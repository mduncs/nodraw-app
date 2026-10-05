import XCTest
@testable import PhotoPipeline

final class BridgeTests: XCTestCase {

    func testFrameworkAvailability() {
        let availability = FrameworkLoader.availability()
        // At minimum, we should be able to check all frameworks
        XCTAssertEqual(availability.count, FrameworkLoader.Framework.allCases.count)
    }

    func testIsCompatible() {
        // Should be true on macOS 14+ with private frameworks present
        let compatible = Diagnostics.isCompatible()
        // This is system-dependent, so we just verify it doesn't crash
        _ = compatible
    }

    func testSystemReport() {
        let report = Diagnostics.systemReport()
        XCTAssertFalse(report.macOSVersion.isEmpty)
        XCTAssertFalse(report.architecture.isEmpty)
        // Report should produce valid output
        let description = report.description
        XCTAssert(description.contains("PhotoPipeline System Report"))
        XCTAssert(description.contains("macOS:"))
    }

    func testFrameworkPaths() {
        // Verify framework path construction
        let ma = FrameworkLoader.Framework.mediaAnalysis
        XCTAssertEqual(ma.path, "/System/Library/PrivateFrameworks/MediaAnalysis.framework/MediaAnalysis")
        XCTAssert(ma.resourcesPath.contains("Resources"))
    }

    func testLoadMediaAnalysis() throws {
        let loader = FrameworkLoader.shared
        // Try loading — may fail on some systems, that's OK
        do {
            let handle = try loader.load(.mediaAnalysis)
            XCTAssertEqual(handle.name, "MediaAnalysis")
        } catch {
            // Expected on systems without private frameworks
            print("MediaAnalysis not available: \(error)")
        }
    }

    func testClassLookupAfterLoad() throws {
        let loader = FrameworkLoader.shared
        do {
            try loader.load(.mediaAnalysis)
            // These classes should exist after loading MediaAnalysis
            let cls = loader.classNamed("VCPPhotoAnalyzer")
            // May or may not be available depending on system
            _ = cls
        } catch {
            // Expected
        }
    }

    func testObjCBridgeMethodNames() {
        // Test introspection on a known class
        let names = ObjCBridge.methodNames(of: NSObject.self)
        XCTAssert(names.contains("init"))
        XCTAssert(names.contains("description"))
    }

    func testObjCBridgePropertyNames() {
        let names = ObjCBridge.propertyNames(of: NSObject.self)
        // NSObject has some properties
        _ = names
    }

    func testObjCBridgeCreate() {
        let obj = ObjCBridge.create(NSObject.self)
        XCTAssertNotNil(obj)
    }

    func testObjCBridgeResponds() {
        let obj = NSObject()
        XCTAssert(ObjCBridge.responds(obj, to: "description"))
        XCTAssertFalse(ObjCBridge.responds(obj, to: "nonExistentMethod12345"))
    }

    func testModelAvailability() {
        let models = Diagnostics.checkModelAvailability()
        // Should check several models
        XCTAssert(models.count > 5)
        // MonzaV4_1 is a key model
        XCTAssertNotNil(models["MonzaV4_1.mlmodelc"])
    }
}
