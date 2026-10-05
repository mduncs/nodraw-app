import XCTest
@testable import MediaViewer

final class ContextAssociationResolverTests: XCTestCase {
    private var directory: URL!
    private var files: [URL] = []

    override func setUpWithError() throws {
        let support = try XCTUnwrap(ProcessInfo.processInfo.environment["NODRAW_APP_SUPPORT_DIR"])
        // Canonical like the resolver: macOS drops "/private" from /private/tmp paths.
        directory = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(URL(fileURLWithPath: support)))
            .appendingPathComponent("context-resolver-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
        files = []
    }

    func testTweetIDParentOwnsEmbeddedVideoAndNumberedContext() throws {
        let stem = "2026-10-03-twitter-SampleXAuthor-1000000000000000010"
        let video = try file("\(stem)-1.mp4")
        let context = try file("\(stem)-1.context.png")
        let sidecar = try file("\(stem).md", content: "---\nsource: https://x.com/user/status/1000000000000000010\n---\n![[\(video.lastPathComponent)]]\n")
        let groups = resolve()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[key(sidecar)]?.mediaFiles, [video])
        XCTAssertEqual(groups[key(sidecar)]?.contextImage, context)
    }

    func testNumberedGalleryFilesUseExactParentWithoutEmbeds() throws {
        let stem = "2026-10-03-twitter-user-1000000000000000010"
        let first = try file("\(stem)-1.jpg")
        let second = try file("\(stem)-2.jpg")
        let context = try file("\(stem)-2.context.png")
        let sidecar = try file("\(stem).md")
        let groups = resolve()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[key(sidecar)]?.mediaFiles, [first, second])
        XCTAssertEqual(groups[key(sidecar)]?.contextImage, context)
    }

    func testBlueskyParentOwnsNumberedContext() throws {
        let stem = "2026-09-28-bluesky-handle-3md6voiknbs27"
        let sidecar = try file("\(stem).md")
        let media = try file("\(stem)-1.jpg")
        let context = try file("\(stem)-1.context.png")
        let groups = resolve()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[key(sidecar)]?.mediaFiles, [media])
        XCTAssertEqual(groups[key(sidecar)]?.contextImage, context)
    }

    func testUnderscoreContextAndRepeatedContextSuffixes() throws {
        for (index, suffix) in ["_context", ".context.context"].enumerated() {
            let stem = "2026-10-03-twitter-user\(index)-1000000000000000010"
            let sidecar = try file("\(stem).md")
            let context = try file("\(stem)-1\(suffix).png")
            XCTAssertEqual(resolve()[key(sidecar)]?.contextImage, context)
        }
        XCTAssertEqual(resolve().count, 2)
    }

    func testExactParentWinsInFamilyWhileLiteralStemsStayReserved() throws {
        let stem = "2026-10-03-twitter-user-1000000000000000010"
        let parent = try file("\(stem).md")
        let literal = try file("\(stem)-2.md")
        let first = try file("\(stem)-1.mp4")
        let second = try file("\(stem)-2.mp4")
        let firstContext = try file("\(stem)-1.context.png")
        let secondContext = try file("\(stem)-2.context.png")
        let groups = resolve()
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[key(parent)]?.mediaFiles, [first])
        XCTAssertEqual(groups[key(parent)]?.contextImage, firstContext)
        XCTAssertEqual(groups[key(literal)]?.mediaFiles, [second])
        XCTAssertEqual(groups[key(literal)]?.contextImage, secondContext)
    }

    func testAmbiguousNumberedSidecarsDoNotClaimAnotherFamilyMember() throws {
        let first = try file("foo_1.md")
        let tenth = try file("foo_10.md")
        let extra = try file("foo_2.jpg")
        let context = try file("foo_2.context.png")
        let groups = resolve()
        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups[key(first)]?.mediaFiles.isEmpty == true)
        XCTAssertTrue(groups[key(tenth)]?.mediaFiles.isEmpty == true)
        let separate = directory.appendingPathComponent("foo_2")
        XCTAssertEqual(groups[separate]?.mediaFiles, [extra])
        XCTAssertEqual(groups[separate]?.contextImage, context)
    }

    func testUnownedFirstAndTenthFilesRemainSeparate() throws {
        let first = try file("foo_1.jpg")
        let tenth = try file("foo_10.jpg")
        let groups = resolve()
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[key(first)]?.mediaFiles, [first])
        XCTAssertEqual(groups[key(tenth)]?.mediaFiles, [tenth])
    }

    func testGeneratedSidecarWithTagsIsAbsorbedWithoutChangingFiles() throws {
        let stem = "2026-09-28-bluesky-handle-3md6voiknbs27"
        let parent = try file("\(stem).md")
        let media = try file("\(stem)-1.jpg")
        let context = try file("\(stem)-1.context.png")
        let generated = try generatedSidecar(for: context, fields: "tags:\n  - art\n")
        let before = try Data(contentsOf: generated)
        XCTAssertEqual(ArchiveAssociationResolver.generatedContextSidecarSource(at: generated), context)
        let groups = resolve()
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[key(generated)])
        XCTAssertEqual(groups[key(parent)]?.mediaFiles, [media])
        XCTAssertEqual(groups[key(parent)]?.contextImage, context)
        XCTAssertEqual(groups[key(parent)]?.absorbedContextSidecars, [generated])
        XCTAssertEqual(try MetadataParser.parse(fileAt: generated).tags, ["art"])
        XCTAssertEqual(try Data(contentsOf: generated), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.path))
    }

    func testGeneratedSidecarUsesExactStemOwnerBeforeGalleryParent() throws {
        let parent = try file("post.md")
        let literal = try file("post-1.md")
        let context = try file("post-1.context.png")
        let generated = try generatedSidecar(for: context)
        let groups = resolve()
        XCTAssertEqual(groups.count, 2)
        XCTAssertNil(groups[key(parent)]?.contextImage)
        XCTAssertEqual(groups[key(literal)]?.contextImage, context)
        XCTAssertEqual(groups[key(literal)]?.absorbedContextSidecars, [generated])
    }

    func testGeneratedRepeatedAndUnderscoreContextsCanBeAbsorbed() throws {
        for (index, suffix) in ["_context", ".context.context"].enumerated() {
            let stem = "post\(index)"
            let parent = try file("\(stem).md")
            let context = try file("\(stem)-2\(suffix).png")
            let generated = try generatedSidecar(for: context)
            let groups = resolve()
            XCTAssertNil(groups[key(generated)])
            XCTAssertEqual(groups[key(parent)]?.contextImage, context)
            XCTAssertEqual(groups[key(parent)]?.absorbedContextSidecars, [generated])
        }
        XCTAssertEqual(resolve().count, 2)
    }

    func testAuthoredContextSidecarRemainsLiteralOwner() throws {
        let fixtures = [
            ("notes: a note\n", "", false),
            ("notes: ''\n", "", false),
            ("", "Authored body\n", false),
            ("custom: preserved\n", "", false),
            ("", "", true)
        ]
        for (index, fixture) in fixtures.enumerated() {
            let stem = "post\(index)"
            let parent = try file("\(stem).md")
            let context = try file("\(stem)-1.context.png")
            let sidecar = try generatedSidecar(for: context, fields: fixture.0, body: fixture.1, starred: fixture.2)
            XCTAssertNil(ArchiveAssociationResolver.generatedContextSidecarSource(at: sidecar))
            let groups = resolve()
            XCTAssertNil(groups[key(parent)]?.contextImage)
            XCTAssertEqual(groups[key(sidecar)]?.contextImage, context)
            XCTAssertTrue(groups[key(parent)]?.absorbedContextSidecars.isEmpty == true)
        }
        XCTAssertEqual(resolve().count, fixtures.count * 2)
    }

    func testGeneratedContextWithoutPostRemainsIndependent() throws {
        let context = try file("2025-11-27-twitter-x.context.png")
        let generated = try generatedSidecar(for: context)
        XCTAssertEqual(ArchiveAssociationResolver.generatedContextSidecarSource(at: generated), context)
        let groups = resolve()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[key(generated)]?.contextImage, context)
        XCTAssertTrue(groups[key(generated)]?.absorbedContextSidecars.isEmpty == true)
    }

    func testGeneratedHeaderRequiresArchivedAndOwnLocalSourceAndValidStar() throws {
        let context = try file("post-1.context.png")
        let sidecar = try file("post-1.context.md")
        let other = try file("other.context.png")
        let headers = [
            "source: \(context.absoluteString)\nstarred: false\n",
            "source: \(context.absoluteString)\narchived: 2026-09-28T00:00:00Z\nstarred: malformed\n",
            "source: https://example.com/post-1.context.png\narchived: 2026-09-28T00:00:00Z\nstarred: false\n",
            "source: \(other.absoluteString)\narchived: 2026-09-28T00:00:00Z\nstarred: false\n"
        ]
        for header in headers {
            try "---\n\(header)---\n".write(to: sidecar, atomically: true, encoding: .utf8)
            XCTAssertNil(ArchiveAssociationResolver.generatedContextSidecarSource(at: sidecar))
        }
    }

    func testMinimalTaggedHeaderDefaultsToUnstarredAndResolvesArchiveAlias() throws {
        let parent = try file("post.md")
        let context = try file("post-1.context.png")
        let alias = directory.appendingPathComponent("old-archive")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let aliasedContext = alias.appendingPathComponent(context.lastPathComponent)
        let generated = try file("post-1.context.md", content: "---\narchived: '2026-01-25T02:14:02Z'\nsource: \(aliasedContext.absoluteString)\ntags: [art]\n---\n")
        XCTAssertEqual(ArchiveAssociationResolver.generatedContextSidecarSource(at: generated), context)
        let groups = resolve()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[key(parent)]?.contextImage, context)
        XCTAssertEqual(groups[key(parent)]?.absorbedContextSidecars, [generated])
        XCTAssertEqual(try MetadataParser.parse(fileAt: generated).tags, ["art"])
    }

    func testInvalidTagValuesKeepGeneratedLookingSidecarsSeparate() throws {
        let parent = try file("post.md")
        let context = try file("post-1.context.png")
        for fields in ["tags: 7\n", "tags: [art, 7]\n", "tags: {art: true}\n", "tags: null\n"] {
            let generated = try generatedSidecar(for: context, fields: fields)
            XCTAssertNil(ArchiveAssociationResolver.generatedContextSidecarSource(at: generated))
            XCTAssertNil(resolve()[key(parent)]?.contextImage)
        }
    }

    func testExactGalleryParentMustBeInSameDirectory() throws {
        _ = try file("post.md")
        let subdirectory = directory.appendingPathComponent("other-month")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let context = try file("other-month/post-1.context.png")
        let groups = resolve()
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[subdirectory.appendingPathComponent("post-1")]?.contextImage, context)
    }

    private func resolve() -> [URL: ArchiveItemFiles] {
        ArchiveAssociationResolver.resolve(files, archivePath: directory)
    }

    private func key(_ url: URL) -> URL { url.deletingPathExtension() }

    @discardableResult
    private func file(_ name: String, content: String = "") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        if !files.contains(url) { files.append(url) }
        return url
    }

    private func generatedSidecar(for context: URL, fields: String = "", body: String = "", starred: Bool = false) throws -> URL {
        let content = "---\narchived: 2026-09-28T00:00:00Z\nauthor: user\nplatform: twitter\nsource: \(context.absoluteString)\nstarred: \(starred)\n\(fields)---\n\(body)"
        return try file(context.deletingPathExtension().lastPathComponent + ".md", content: content)
    }
}
