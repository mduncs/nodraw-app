import XCTest
import UniformTypeIdentifiers
@testable import MediaViewer

final class MediaDropClassificationTests: XCTestCase {
    func testAppMarkerOnAnyProviderRejectsAllFileCompanionsWithoutLoadingPayload() {
        for identifier in kSupportedMediaItemTypeIdentifiers {
            for position in 0..<3 {
                var providers = (0..<3).map { fileProvider("file-\($0).jpg") }
                providers[position].registerDataRepresentation(forTypeIdentifier: identifier, visibility: .all) { _ in
                    XCTFail("An app marker must reject import without decoding its payload")
                    return nil
                }
                XCTAssertTrue(MediaDropClassification.externalFileProviders(in: providers).isEmpty,
                              "\(identifier) at position \(position) must reject the complete drop")
            }
        }
    }

    func testMarkerOnlyProviderRejectsWholeDropEvenWhenFilesAreSeparateProviders() {
        for identifier in kSupportedMediaItemTypeIdentifiers {
            let marker = NSItemProvider()
            marker.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .all) { completion in
                completion(Data("malformed internal payload".utf8), nil)
                return nil
            }
            let files = [fileProvider("first.jpg"), fileProvider("second.mp4")]
            for providers in [[marker] + files, [files[0], marker, files[1]], files + [marker]] {
                XCTAssertTrue(MediaDropClassification.externalFileProviders(in: providers).isEmpty)
            }
        }
    }

    func testExplicitRegisteredAppMarkerRejectsImportWhenTypeConformanceFails() {
        for identifier in kSupportedMediaItemTypeIdentifiers {
            let marker = UnresolvedAppMarkerProvider()
            marker.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .all) { _ in
                XCTFail("Unresolved app marker must not be loaded for import")
                return nil
            }
            XCTAssertTrue(marker.registeredTypeIdentifiers.contains(identifier))
            XCTAssertFalse(marker.hasItemConformingToTypeIdentifier(identifier))
            XCTAssertTrue(MediaDropClassification.externalFileProviders(in: [fileProvider("first.jpg"), marker, fileProvider("second.mp4")]).isEmpty)
        }
    }

    func testExternalMultiFileDropRetainsOrderAndGenericDataRepresentations() {
        let first = fileProvider("first.jpg")
        let second = fileProvider("second.mp4")
        for provider in [first, second] {
            provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .all) { _ in
                XCTFail("Classification must not load external file representations")
                return nil
            }
        }
        let unrelated = NSItemProvider()
        unrelated.registerDataRepresentation(forTypeIdentifier: "com.example.external.payload", visibility: .all) { _ in
            XCTFail("Classification must not load unrelated providers")
            return nil
        }
        let classified = MediaDropClassification.externalFileProviders(in: [second, unrelated, first])
        XCTAssertEqual(classified.count, 2)
        XCTAssertTrue(classified[0] === second)
        XCTAssertTrue(classified[1] === first)
        XCTAssertTrue(MediaDropClassification.externalFileProviders(in: []).isEmpty)
    }

    func testFactoryFileCompanionsStayInternalWhenLeadingProviderIsFilteredOut() async throws {
        let support = try XCTUnwrap(ProcessInfo.processInfo.environment["NODRAW_APP_SUPPORT_DIR"])
        let directory = URL(fileURLWithPath: support).appendingPathComponent("drag-classification-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try (0..<3).map { index in
            let url = directory.appendingPathComponent("file-\(index).jpg")
            try Data("fixture \(index)".utf8).write(to: url)
            return url
        }
        let ids = [UUID(), UUID()]
        let providers = try makeMediaItemDragItemProviders(dragData: MediaItemDragData(itemIds: ids), externalFileURLs: files)
        XCTAssertEqual(providers.count, 3)
        for provider in providers {
            XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
            for identifier in kSupportedMediaItemTypeIdentifiers {
                XCTAssertTrue(provider.registeredTypeIdentifiers.contains(identifier))
            }
        }
        let companions = Array(providers.dropFirst())
        XCTAssertTrue(MediaDropClassification.externalFileProviders(in: companions).isEmpty)
        let loaded = expectation(description: "Companions retain complete internal identities")
        var value: MediaItemDragData?
        let task = loadMediaItemDragData(from: companions) { result in
            value = result
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 5)
        await task.value
        XCTAssertEqual(value?.itemIds, ids, "Repeated companion payloads must deduplicate identities")
    }

    private func fileProvider(_ name: String) -> NSItemProvider {
        NSItemProvider(object: URL(fileURLWithPath: "/tmp/nodraw-drag-classification/\(name)") as NSURL)
    }
}

private final class UnresolvedAppMarkerProvider: NSItemProvider {
    override func hasItemConformingToTypeIdentifier(_ typeIdentifier: String) -> Bool {
        if kSupportedMediaItemTypeIdentifiers.contains(typeIdentifier) { return false }
        return super.hasItemConformingToTypeIdentifier(typeIdentifier)
    }
}
