import XCTest
@testable import MediaViewer

final class WebMLocalFileLoadPolicyTests: XCTestCase {
    func testLoadPlanUsesTheFileDirectlyAndRestrictsReadAccessToItsDirectory() {
        let source = URL(fileURLWithPath: "/archive/folder with spaces/[clip].webm")

        let plan = WebMLocalFileLoadPolicy.plan(for: source)

        XCTAssertEqual(plan.fileURL, source.standardizedFileURL)
        XCTAssertEqual(
            plan.readAccessURL,
            source.standardizedFileURL.deletingLastPathComponent()
        )
    }

    func testFinishedNavigationConfiguresTheMediaDocument() {
        XCTAssertTrue(WebMLocalFileLoadPolicy.shouldConfigure(after: .finished))
    }

    func testWebKitMediaDocumentHandledErrorConfiguresTheMediaDocument() {
        XCTAssertTrue(
            WebMLocalFileLoadPolicy.shouldConfigure(
                after: .failed(domain: "WebKitErrorDomain", code: 204)
            )
        )
    }

    func testUnrelatedNavigationFailuresAreNotTreatedAsMediaDocuments() {
        XCTAssertFalse(
            WebMLocalFileLoadPolicy.shouldConfigure(
                after: .failed(domain: "WebKitErrorDomain", code: 203)
            )
        )
        XCTAssertFalse(
            WebMLocalFileLoadPolicy.shouldConfigure(
                after: .failed(domain: NSURLErrorDomain, code: 204)
            )
        )
    }

    func testConfigurationRetryIsBounded() {
        XCTAssertTrue(
            WebMLocalFileLoadPolicy.shouldRetryConfiguration(
                afterAttempt: WebMLocalFileLoadPolicy.maximumConfigurationAttempts - 1
            )
        )
        XCTAssertFalse(
            WebMLocalFileLoadPolicy.shouldRetryConfiguration(
                afterAttempt: WebMLocalFileLoadPolicy.maximumConfigurationAttempts
            )
        )
    }
}
