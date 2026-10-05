import XCTest
@testable import MediaViewer

final class HeadlessHarnessConfigurationTests: XCTestCase {
    func testDisposableFixtureContractIsAccepted() {
        let configuration = HeadlessHarnessConfiguration.resolve(
            environment: fixtureEnvironment(),
            arguments: ["NoDraw", "--headless-tests", "--test-fixtures"]
        )

        XCTAssertTrue(configuration.usesFixtures)
        XCTAssertNil(configuration.safetyFailure)
    }

    func testFixtureArchiveMustBeInsideDisposableRoot() {
        var environment = fixtureEnvironment()
        environment["NODRAW_ARCHIVE_PATH"] = "/Users/example/MediaArchive"
        environment["MEDIAVIEWER_ARCHIVE_PATH"] = "/Users/example/MediaArchive"

        let configuration = HeadlessHarnessConfiguration.resolve(
            environment: environment,
            arguments: ["NoDraw", "--headless-tests", "--test-fixtures"]
        )

        XCTAssertEqual(
            configuration.safetyFailure,
            "Fixture archive must be a disposable copy inside the harness root"
        )
    }

    func testArchiveAliasesMustBePresentAndAligned() {
        var missingLegacy = fixtureEnvironment()
        missingLegacy.removeValue(forKey: "MEDIAVIEWER_ARCHIVE_PATH")
        XCTAssertEqual(
            HeadlessHarnessConfiguration.resolve(
                environment: missingLegacy,
                arguments: ["NoDraw", "--test-fixtures"]
            ).safetyFailure,
            "MEDIAVIEWER_ARCHIVE_PATH is required and must match NODRAW_ARCHIVE_PATH"
        )

        var mismatched = fixtureEnvironment()
        mismatched["MEDIAVIEWER_ARCHIVE_PATH"] = "/tmp/other/archive"
        XCTAssertEqual(
            HeadlessHarnessConfiguration.resolve(
                environment: mismatched,
                arguments: ["NoDraw", "--test-fixtures"]
            ).safetyFailure,
            "NODRAW_ARCHIVE_PATH and MEDIAVIEWER_ARCHIVE_PATH do not match"
        )
    }

    func testAppSupportAndResultsMustBeDisposable() {
        var environment = fixtureEnvironment()
        environment["NODRAW_APP_SUPPORT_DIR"] = "/Users/example/Library/Application Support/NoDraw"
        environment["MEDIAVIEWER_APP_SUPPORT_DIR"] = environment["NODRAW_APP_SUPPORT_DIR"]

        XCTAssertEqual(
            HeadlessHarnessConfiguration.resolve(
                environment: environment,
                arguments: ["NoDraw", "--test-fixtures"]
            ).safetyFailure,
            "Headless app support must be inside the disposable root"
        )
    }

    func testLiveArchiveRequiresArgumentAndEnvironmentOptIn() {
        var environment = fixtureEnvironment()
        environment.removeValue(forKey: "MEDIAVIEWER_TEST_FIXTURES")

        let withoutOptIn = HeadlessHarnessConfiguration.resolve(
            environment: environment,
            arguments: ["NoDraw", "--headless-tests"]
        )
        XCTAssertEqual(
            withoutOptIn.safetyFailure,
            "Non-fixture tests require explicit --headless-live-archive opt-in"
        )

        environment["NODRAW_HEADLESS_ALLOW_LIVE_ARCHIVE"] = "1"
        let explicitLive = HeadlessHarnessConfiguration.resolve(
            environment: environment,
            arguments: ["NoDraw", "--headless-tests", "--headless-live-archive"]
        )
        XCTAssertTrue(explicitLive.permitsLiveArchive)
        XCTAssertNil(explicitLive.safetyFailure)
    }

    func testLiveArchiveOptInStillRejectsSourcePathOutsideSandbox() {
        var environment = fixtureEnvironment()
        environment.removeValue(forKey: "MEDIAVIEWER_TEST_FIXTURES")
        environment["NODRAW_ARCHIVE_PATH"] = "/Users/example/MediaArchive"
        environment["MEDIAVIEWER_ARCHIVE_PATH"] = "/Users/example/MediaArchive"
        environment["NODRAW_HEADLESS_ALLOW_LIVE_ARCHIVE"] = "1"

        let configuration = HeadlessHarnessConfiguration.resolve(
            environment: environment,
            arguments: ["NoDraw", "--headless-tests", "--headless-live-archive"]
        )

        XCTAssertEqual(
            configuration.safetyFailure,
            "Real-archive tests must use a disposable snapshot inside the harness root"
        )
    }

    private func fixtureEnvironment() -> [String: String] {
        [
            "NODRAW_ARCHIVE_PATH": "/tmp/nodraw-headless.ABC123/archive",
            "MEDIAVIEWER_ARCHIVE_PATH": "/tmp/nodraw-headless.ABC123/archive",
            "NODRAW_APP_SUPPORT_DIR": "/tmp/nodraw-headless.ABC123/app-support",
            "MEDIAVIEWER_APP_SUPPORT_DIR": "/tmp/nodraw-headless.ABC123/app-support",
            "NODRAW_HEADLESS_RESULTS_DIR": "/tmp/nodraw-headless.ABC123/results",
            "NODRAW_HEADLESS_DISPOSABLE_ROOT": "/tmp/nodraw-headless.ABC123",
            "MEDIAVIEWER_TEST_FIXTURES": "1"
        ]
    }
}
