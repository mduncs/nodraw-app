import XCTest
@testable import MediaViewer

final class BackgroundQAConfigurationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/tmp/nodraw-qa-home")
    func testForegroundPreviewAndBackgroundQAAreDistinctExplicitModes() {
        XCTAssertEqual(BackgroundQAConfiguration.mode(for: ["NoDraw"]), .normal)
        XCTAssertEqual(BackgroundQAConfiguration.mode(for: ["NoDraw", "--editor-preview"]), .editorPreview)
        XCTAssertEqual(BackgroundQAConfiguration.mode(for: ["NoDraw", "--background-qa"]), .backgroundQA)
        XCTAssertEqual(BackgroundQAConfiguration.mode(for: ["NoDraw", "--editor-preview", "--background-qa"]), .backgroundQA,
                       "A preview package must still support a nonactivating smoke launch")
        XCTAssertEqual(BackgroundQAConfiguration.mode(for: ["NoDraw", "--editor-preview-other"]), .normal)
    }
    func testExplicitSeparateRootsAreRequired() throws {
        let valid = try BackgroundQAConfiguration.validate(environment: [
            "NODRAW_APP_SUPPORT_DIR": "/tmp/nodraw-qa-fixture/app",
            "NODRAW_ARCHIVE_PATH": "/tmp/nodraw-qa-fixture/archive"
        ], home: home)
        XCTAssertEqual(valid.appData.lastPathComponent, "app")
        XCTAssertEqual(valid.archive.lastPathComponent, "archive")
        XCTAssertThrowsError(try BackgroundQAConfiguration.validate(environment: [:], home: home))
        XCTAssertThrowsError(try BackgroundQAConfiguration.validate(environment: [
            "MEDIAVIEWER_APP_SUPPORT_DIR": "/tmp/app", "MEDIAVIEWER_ARCHIVE_PATH": "/tmp/archive"
        ], home: home), "Bare legacy overrides do not authorize the explicit QA mode")
    }

    func testRejectsLiveRootsHomeRootAndOverlap() {
        for unsafe in ["/", home.path, home.appendingPathComponent("MediaArchive").path,
                       home.appendingPathComponent("Library/Application Support/NoDraw").path,
                       home.appendingPathComponent("Library/Application Support/MediaViewer/child").path, "relative"] {
            XCTAssertThrowsError(try BackgroundQAConfiguration.validate(environment: [
                "NODRAW_APP_SUPPORT_DIR": unsafe, "NODRAW_ARCHIVE_PATH": "/tmp/nodraw-qa-fixture/archive"
            ], home: home), unsafe)
        }
        for archive in ["/tmp/nodraw-qa-fixture/app", "/tmp/nodraw-qa-fixture/app/archive"] {
            XCTAssertThrowsError(try BackgroundQAConfiguration.validate(environment: [
                "NODRAW_APP_SUPPORT_DIR": "/tmp/nodraw-qa-fixture/app", "NODRAW_ARCHIVE_PATH": archive
            ], home: home))
        }
    }
}
