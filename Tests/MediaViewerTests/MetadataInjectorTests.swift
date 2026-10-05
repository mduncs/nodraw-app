import XCTest
@testable import MediaViewer
import ImageIO

final class MetadataInjectorTests: XCTestCase {

    var tempDirectory: URL!
    var testImageURL: URL!

    override func setUp() async throws {
        // Create temp directory for test files
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataInjectorTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        // Create a minimal test JPEG image
        testImageURL = tempDirectory.appendingPathComponent("test_image.jpg")
        try createMinimalJPEG(at: testImageURL)
    }

    override func tearDown() async throws {
        // Clean up temp directory
        if let tempDir = tempDirectory {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Basic Export Tests

    func testExportCreatesFile() throws {
        let injector = MetadataInjector()
        let destURL = tempDirectory.appendingPathComponent("exported.jpg")

        let metadata = ExportMetadata(
            caption: "Test caption",
            source: URL(string: "https://example.com/image")
        )

        let result = injector.export(sourceURL: testImageURL, to: destURL, metadata: metadata)

        XCTAssertTrue(result.success, "Export should succeed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path), "Exported file should exist")
    }

    func testExportWithAllMetadataFields() throws {
        let injector = MetadataInjector()
        let destURL = tempDirectory.appendingPathComponent("exported_full.jpg")

        let metadata = ExportMetadata(
            caption: "A beautiful sunset photo",
            source: URL(string: "https://twitter.com/user/status/123"),
            creator: "@photographer",
            copyright: "2025 @photographer",
            keywords: ["sunset", "nature", "photography"],
            dateCreated: Date(timeIntervalSince1970: 1737100800) // 2025-01-17
        )

        let result = injector.export(sourceURL: testImageURL, to: destURL, metadata: metadata)

        XCTAssertTrue(result.success, "Export should succeed")

        // Verify metadata was written
        guard let readMetadata = MetadataInjector.readMetadata(from: destURL) else {
            XCTFail("Could not read metadata from exported file")
            return
        }

        // Check IPTC fields
        if let caption = readMetadata.iptc["CaptionAbstract"] as? String {
            XCTAssertEqual(caption, "A beautiful sunset photo")
        }
        if let source = readMetadata.iptc["Source"] as? String {
            XCTAssertEqual(source, "https://twitter.com/user/status/123")
        }
        if let keywords = readMetadata.iptc["Keywords"] as? [String] {
            XCTAssertEqual(Set(keywords), Set(["sunset", "nature", "photography"]))
        }
        if let copyright = readMetadata.iptc["CopyrightNotice"] as? String {
            XCTAssertEqual(copyright, "2025 @photographer")
        }

        // Check TIFF fields
        if let artist = readMetadata.tiff["Artist"] as? String {
            XCTAssertEqual(artist, "@photographer")
        }
        if let imageDesc = readMetadata.tiff["ImageDescription"] as? String {
            XCTAssertEqual(imageDesc, "A beautiful sunset photo")
        }
    }

    func testExportWithEmptyMetadata() throws {
        let injector = MetadataInjector()
        let destURL = tempDirectory.appendingPathComponent("exported_empty.jpg")

        let metadata = ExportMetadata()

        let result = injector.export(sourceURL: testImageURL, to: destURL, metadata: metadata)

        XCTAssertTrue(result.success, "Export with empty metadata should succeed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
    }

    // MARK: - Format Tests

    func testExportAsJPEG() throws {
        let injector = MetadataInjector()
        let destURL = tempDirectory.appendingPathComponent("exported.jpg")

        var options = ExportOptions.default
        options.outputFormat = .jpeg
        options.jpegQuality = 0.9

        let result = injector.export(
            sourceURL: testImageURL,
            to: destURL,
            metadata: ExportMetadata(caption: "JPEG test"),
            options: options
        )

        XCTAssertTrue(result.success)

        // Verify it's a valid JPEG
        guard let imageSource = CGImageSourceCreateWithURL(destURL as CFURL, nil) else {
            XCTFail("Could not create image source")
            return
        }
        let utType = CGImageSourceGetType(imageSource) as String?
        XCTAssertEqual(utType, "public.jpeg")
    }

    func testExportAsPNG() throws {
        let injector = MetadataInjector()
        let destURL = tempDirectory.appendingPathComponent("exported.png")

        var options = ExportOptions.default
        options.outputFormat = .png

        let result = injector.export(
            sourceURL: testImageURL,
            to: destURL,
            metadata: ExportMetadata(caption: "PNG test"),
            options: options
        )

        XCTAssertTrue(result.success)

        // Verify it's a valid PNG
        guard let imageSource = CGImageSourceCreateWithURL(destURL as CFURL, nil) else {
            XCTFail("Could not create image source")
            return
        }
        let utType = CGImageSourceGetType(imageSource) as String?
        XCTAssertEqual(utType, "public.png")
    }

    // MARK: - Error Cases

    func testExportWithInvalidSource() {
        let injector = MetadataInjector()
        let invalidURL = tempDirectory.appendingPathComponent("nonexistent.jpg")
        let destURL = tempDirectory.appendingPathComponent("output.jpg")

        let result = injector.export(
            sourceURL: invalidURL,
            to: destURL,
            metadata: ExportMetadata()
        )

        XCTAssertFalse(result.success, "Export should fail for nonexistent source")
        XCTAssertNotNil(result.error)
    }

    func testExportCreatesDestinationDirectory() throws {
        let injector = MetadataInjector()
        let nestedDir = tempDirectory
            .appendingPathComponent("nested")
            .appendingPathComponent("deep")
        let destURL = nestedDir.appendingPathComponent("output.jpg")

        // Directory doesn't exist yet
        XCTAssertFalse(FileManager.default.fileExists(atPath: nestedDir.path))

        let result = injector.export(
            sourceURL: testImageURL,
            to: destURL,
            metadata: ExportMetadata()
        )

        XCTAssertTrue(result.success, "Export should create nested directories")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))
    }

    // MARK: - ExportMetadata.from Tests

    func testExportMetadataFromMediaItem() throws {
        let item = createTestMediaItem(
            notes: "Test notes",
            source: URL(string: "https://twitter.com/test")!,
            author: "@testuser",
            tags: ["tag1", "tag2"],
            originalDate: Date(timeIntervalSince1970: 1737100800)
        )

        let options = ExportOptions.default
        let metadata = ExportMetadata.from(item: item, options: options)

        XCTAssertEqual(metadata.caption, "Test notes")
        XCTAssertEqual(metadata.source?.absoluteString, "https://twitter.com/test")
        XCTAssertEqual(metadata.creator, "@testuser")
        XCTAssertEqual(metadata.keywords, ["tag1", "tag2"])
        XCTAssertNotNil(metadata.dateCreated)
    }

    func testExportMetadataRespectsOptions() throws {
        let item = createTestMediaItem(
            notes: "Test notes",
            source: URL(string: "https://twitter.com/test")!,
            author: "@testuser",
            tags: ["tag1", "tag2"]
        )

        var options = ExportOptions.default
        options.includeCaption = false
        options.includeSource = false
        options.includeCreator = true
        options.includeKeywords = false

        let metadata = ExportMetadata.from(item: item, options: options)

        XCTAssertNil(metadata.caption, "Caption should be nil when disabled")
        XCTAssertNil(metadata.source, "Source should be nil when disabled")
        XCTAssertEqual(metadata.creator, "@testuser", "Creator should be included when enabled")
        XCTAssertTrue(metadata.keywords.isEmpty, "Keywords should be empty when disabled")
    }

    func testExportMetadataAutoCopyright() throws {
        let item = createTestMediaItem(
            author: "@testuser",
            originalDate: Date(timeIntervalSince1970: 1737100800) // 2025-01-17
        )

        var options = ExportOptions.default
        options.includeCopyright = true

        let metadata = ExportMetadata.from(item: item, options: options)

        XCTAssertNotNil(metadata.copyright)
        XCTAssertTrue(metadata.copyright!.contains("2025"))
        XCTAssertTrue(metadata.copyright!.contains("@testuser"))
    }

    // MARK: - Date Format Tests

    func testExifDateFormat() throws {
        let injector = MetadataInjector()
        let destURL = tempDirectory.appendingPathComponent("date_test.jpg")

        // Create a specific date
        var components = DateComponents()
        components.year = 2025
        components.month = 1
        components.day = 17
        components.hour = 14
        components.minute = 30
        components.second = 45
        let testDate = Calendar.current.date(from: components)!

        let metadata = ExportMetadata(dateCreated: testDate)
        let result = injector.export(sourceURL: testImageURL, to: destURL, metadata: metadata)

        XCTAssertTrue(result.success)

        // Read back and verify EXIF date format
        guard let readMetadata = MetadataInjector.readMetadata(from: destURL) else {
            XCTFail("Could not read metadata")
            return
        }

        if let dateString = readMetadata.exif["DateTimeOriginal"] as? String {
            // EXIF format: "yyyy:MM:dd HH:mm:ss"
            XCTAssertTrue(dateString.contains("2025:01:17"), "Date should be in EXIF format")
        }
    }

    // MARK: - Helpers

    /// Create a minimal valid JPEG file for testing
    private func createMinimalJPEG(at url: URL) throws {
        // Create a 1x1 pixel red image
        let width = 100
        let height = 100
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create context"])
        }

        // Fill with red
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "TestError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create image"])
        }

        // Write as JPEG
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "TestError", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create destination"])
        }

        CGImageDestinationAddImage(destination, cgImage, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "TestError", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not finalize"])
        }
    }

    /// Create a test MediaItem with specified properties
    private func createTestMediaItem(
        notes: String? = nil,
        source: URL = URL(string: "https://example.com")!,
        author: String? = nil,
        tags: [String] = [],
        originalDate: Date? = nil
    ) -> MediaItem {
        MediaItem(
            id: UUID(),
            basePath: tempDirectory,
            metadataFile: tempDirectory.appendingPathComponent("test.md"),
            mediaFiles: [testImageURL],
            contextImage: nil,
            metadata: MediaMetadata(
                source: source,
                platform: "twitter",
                author: author,
                originalDate: originalDate,
                archivedDate: Date(),
                starred: false,
                tags: tags,
                notes: notes
            )
        )
    }
}

// MARK: - ExportOptions Tests

final class ExportOptionsTests: XCTestCase {

    func testDefaultOptions() {
        let options = ExportOptions.default

        XCTAssertTrue(options.includeCaption)
        XCTAssertTrue(options.includeSource)
        XCTAssertTrue(options.includeCreator)
        XCTAssertFalse(options.includeCopyright) // Copyright is opt-in
        XCTAssertTrue(options.includeKeywords)
        XCTAssertTrue(options.includeDate)
        XCTAssertEqual(options.outputFormat, .jpeg)
        XCTAssertEqual(options.jpegQuality, 0.92, accuracy: 0.01)
    }

    func testExportFormatProperties() {
        XCTAssertEqual(ExportFormat.jpeg.fileExtension, "jpg")
        XCTAssertEqual(ExportFormat.png.fileExtension, "png")
        XCTAssertEqual(ExportFormat.tiff.fileExtension, "tiff")
    }
}

// MARK: - ExportResult Tests

final class ExportResultTests: XCTestCase {

    func testSuccessResult() {
        let source = URL(fileURLWithPath: "/source.jpg")
        let dest = URL(fileURLWithPath: "/dest.jpg")

        let result = ExportResult.success(source: source, destination: dest)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.sourceURL, source)
        XCTAssertEqual(result.destinationURL, dest)
        XCTAssertNil(result.error)
    }

    func testFailureResult() {
        let source = URL(fileURLWithPath: "/source.jpg")
        let dest = URL(fileURLWithPath: "/dest.jpg")
        let error = ExportError.sourceLoadFailed(source)

        let result = ExportResult.failure(source: source, destination: dest, error: error)

        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
    }
}

// MARK: - ExportError Tests

final class ExportErrorTests: XCTestCase {

    func testErrorDescriptions() {
        let url = URL(fileURLWithPath: "/test/image.jpg")

        XCTAssertTrue(
            ExportError.sourceLoadFailed(url).errorDescription?.contains("image.jpg") ?? false
        )
        XCTAssertTrue(
            ExportError.destinationCreationFailed(url).errorDescription?.contains("destination") ?? false
        )
        XCTAssertTrue(
            ExportError.writeFailed(url).errorDescription?.contains("write") ?? false
        )
        XCTAssertTrue(
            ExportError.unsupportedFormat("xyz").errorDescription?.contains("xyz") ?? false
        )
        XCTAssertTrue(
            ExportError.noMediaFiles.errorDescription?.contains("no media") ?? false
        )
    }
}
