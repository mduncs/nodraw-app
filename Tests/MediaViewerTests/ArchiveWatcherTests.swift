import XCTest
@testable import MediaViewer

/// Tests for ArchiveWatcher - the file system monitoring service.
/// Uses a temp directory to simulate file changes.
final class ArchiveWatcherTests: XCTestCase {

    private var tempDir: URL!
    private var watcher: TestableArchiveWatcher!

    override func setUpWithError() throws {
        // Create temp directory structure similar to MediaArchive
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create a year-month subfolder
        let monthFolder = tempDir.appendingPathComponent("2025-01")
        try FileManager.default.createDirectory(at: monthFolder, withIntermediateDirectories: true)

        watcher = TestableArchiveWatcher(archivePath: tempDir)
    }

    override func tearDownWithError() throws {
        watcher = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - File Change Detection Tests

    func testDetectFileCreation() async throws {
        try await watcher.start()

        let expectation = XCTestExpectation(description: "File creation detected")

        // Start collecting changes
        Task {
            for await change in watcher.changes {
                if case .created = change.type {
                    expectation.fulfill()
                    break
                }
            }
        }

        // Create a file
        let testFile = tempDir.appendingPathComponent("2025-01/test.md")
        FileManager.default.createFile(atPath: testFile.path, contents: "test".data(using: .utf8))

        await fulfillment(of: [expectation], timeout: 2.0)
        await watcher.stop()
    }

    func testDetectFileModification() async throws {
        // Create file first
        let testFile = tempDir.appendingPathComponent("2025-01/existing.md")
        FileManager.default.createFile(atPath: testFile.path, contents: "initial".data(using: .utf8))

        try await watcher.start()

        let expectation = XCTestExpectation(description: "File modification detected")

        Task {
            for await change in watcher.changes {
                if case .modified = change.type {
                    expectation.fulfill()
                    break
                }
            }
        }

        // Wait a bit then modify
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        try "modified".data(using: .utf8)?.write(to: testFile)

        await fulfillment(of: [expectation], timeout: 2.0)
        await watcher.stop()
    }

    func testDetectFileDeletion() async throws {
        // Create file first
        let testFile = tempDir.appendingPathComponent("2025-01/todelete.md")
        FileManager.default.createFile(atPath: testFile.path, contents: "delete me".data(using: .utf8))

        try await watcher.start()

        let expectation = XCTestExpectation(description: "File deletion detected")

        Task {
            for await change in watcher.changes {
                if case .deleted = change.type {
                    expectation.fulfill()
                    break
                }
            }
        }

        // Wait a bit then delete
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        try FileManager.default.removeItem(at: testFile)

        await fulfillment(of: [expectation], timeout: 2.0)
        await watcher.stop()
    }

    // MARK: - Rename/Move Detection Tests

    func testDetectFileRename() async throws {
        // Create file first
        let oldFile = tempDir.appendingPathComponent("2025-01/oldname.md")
        let newFile = tempDir.appendingPathComponent("2025-01/newname.md")
        FileManager.default.createFile(atPath: oldFile.path, contents: "test".data(using: .utf8))

        try await watcher.start()

        // For polling-based watcher, rename appears as delete + create
        // We just verify that SOME change is detected for the new file
        let deleteExpectation = XCTestExpectation(description: "Old file deletion detected")
        let createExpectation = XCTestExpectation(description: "New file creation detected")

        Task {
            for await change in watcher.changes {
                switch change.type {
                case .deleted where change.url.lastPathComponent == "oldname.md":
                    deleteExpectation.fulfill()
                case .created where change.url.lastPathComponent == "newname.md":
                    createExpectation.fulfill()
                case .renamed:
                    // Full rename detection (FSEvents) - also acceptable
                    deleteExpectation.fulfill()
                    createExpectation.fulfill()
                default:
                    break
                }
            }
        }

        // Wait a bit then rename
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        try FileManager.default.moveItem(at: oldFile, to: newFile)

        await fulfillment(of: [deleteExpectation, createExpectation], timeout: 2.0)
        await watcher.stop()
    }

    func testDetectFileMove() async throws {
        // Create source folder
        let sourceFolder = tempDir.appendingPathComponent("2025-01")
        let destFolder = tempDir.appendingPathComponent("2025-02")
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)

        // Create file in source
        let sourceFile = sourceFolder.appendingPathComponent("tomove.md")
        let destFile = destFolder.appendingPathComponent("tomove.md")
        FileManager.default.createFile(atPath: sourceFile.path, contents: "test".data(using: .utf8))

        try await watcher.start()

        // For polling-based watcher, move appears as delete + create
        let deleteExpectation = XCTestExpectation(description: "Source file deletion detected")
        let createExpectation = XCTestExpectation(description: "Dest file creation detected")

        Task {
            for await change in watcher.changes {
                switch change.type {
                case .deleted where change.url.path.contains("2025-01"):
                    deleteExpectation.fulfill()
                case .created where change.url.path.contains("2025-02"):
                    createExpectation.fulfill()
                case .moved:
                    // Full move detection (FSEvents) - also acceptable
                    deleteExpectation.fulfill()
                    createExpectation.fulfill()
                default:
                    break
                }
            }
        }

        // Wait a bit then move
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        try FileManager.default.moveItem(at: sourceFile, to: destFile)

        await fulfillment(of: [deleteExpectation, createExpectation], timeout: 2.0)
        await watcher.stop()
    }

    // MARK: - Debouncing Tests

    func testDebouncingRapidChanges() async throws {
        try await watcher.start()

        var changeCount = 0
        let expectation = XCTestExpectation(description: "Changes debounced")
        expectation.isInverted = true // We expect this NOT to trigger multiple times per file

        let testFile = tempDir.appendingPathComponent("2025-01/rapid.md")

        Task {
            for await _ in watcher.changes {
                changeCount += 1
                if changeCount > 10 {
                    expectation.fulfill() // Too many changes = debouncing failed
                    break
                }
            }
        }

        // Rapidly create and modify the same file
        for i in 0..<10 {
            try "\(i)".data(using: .utf8)?.write(to: testFile)
        }

        // Wait for debounce window to pass
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s

        // Should have received significantly fewer than 10 change events
        await fulfillment(of: [expectation], timeout: 0.5)
        await watcher.stop()

        XCTAssertLessThan(changeCount, 10)
    }

    // MARK: - Filter Tests

    func testFiltersHiddenFiles() async throws {
        try await watcher.start()

        var receivedChange = false
        let expectation = XCTestExpectation(description: "Should not receive hidden file")
        expectation.isInverted = true

        Task {
            for await change in watcher.changes {
                if change.url.lastPathComponent.hasPrefix(".") {
                    receivedChange = true
                    expectation.fulfill()
                    break
                }
            }
        }

        // Create a hidden file
        let hiddenFile = tempDir.appendingPathComponent("2025-01/.hidden")
        FileManager.default.createFile(atPath: hiddenFile.path, contents: nil)

        await fulfillment(of: [expectation], timeout: 1.0)
        await watcher.stop()

        XCTAssertFalse(receivedChange)
    }

    func testFiltersDirectories() async throws {
        try await watcher.start()

        let expectation = XCTestExpectation(description: "Should not receive directory change")
        expectation.isInverted = true

        Task {
            for await _ in watcher.changes {
                // Any directory change would indicate failure
                expectation.fulfill()
                break
            }
        }

        // Create a subdirectory
        let subdir = tempDir.appendingPathComponent("2025-01/subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        await fulfillment(of: [expectation], timeout: 0.5)
        await watcher.stop()
    }

    func testOnlyRelevantExtensions() async throws {
        try await watcher.start()

        var relevantCount = 0
        var irrelevantReceived = false

        Task {
            for await change in watcher.changes {
                let ext = change.url.pathExtension.lowercased()
                let relevant = ["md", "jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "mov", "webm"]
                if relevant.contains(ext) {
                    relevantCount += 1
                } else {
                    irrelevantReceived = true
                }
            }
        }

        // Create various file types
        let monthFolder = tempDir.appendingPathComponent("2025-01")
        FileManager.default.createFile(atPath: monthFolder.appendingPathComponent("test.md").path, contents: nil)
        FileManager.default.createFile(atPath: monthFolder.appendingPathComponent("test.jpg").path, contents: nil)
        FileManager.default.createFile(atPath: monthFolder.appendingPathComponent("test.txt").path, contents: nil) // Should be filtered
        FileManager.default.createFile(atPath: monthFolder.appendingPathComponent("test.exe").path, contents: nil) // Should be filtered

        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s

        await watcher.stop()

        XCTAssertFalse(irrelevantReceived, "Should not receive events for irrelevant file types")
    }

    // MARK: - Base Name Extraction Tests

    func testExtractBaseName() async throws {
        // These tests verify the base name extraction logic
        XCTAssertEqual(watcher.extractBaseName(from: URL(fileURLWithPath: "/test/tweet_123.jpg")), "tweet_123")
        XCTAssertEqual(watcher.extractBaseName(from: URL(fileURLWithPath: "/test/tweet_123_1.jpg")), "tweet_123")
        XCTAssertEqual(watcher.extractBaseName(from: URL(fileURLWithPath: "/test/tweet_123_2.jpg")), "tweet_123")
        XCTAssertEqual(watcher.extractBaseName(from: URL(fileURLWithPath: "/test/item.md")), "item")
        XCTAssertEqual(watcher.extractBaseName(from: URL(fileURLWithPath: "/test/item_1.md")), "item")
    }

    // MARK: - Item Grouping Tests

    func testItemGrouping() async throws {
        let monthFolder = tempDir.appendingPathComponent("2025-01")

        // Create a complete item group
        FileManager.default.createFile(atPath: monthFolder.appendingPathComponent("tweet_abc.md").path, contents: "---\nsource: https://x.com\n---".data(using: .utf8))
        FileManager.default.createFile(atPath: monthFolder.appendingPathComponent("tweet_abc_1.jpg").path, contents: nil)
        FileManager.default.createFile(atPath: monthFolder.appendingPathComponent("tweet_abc_2.jpg").path, contents: nil)
        FileManager.default.createFile(atPath: monthFolder.appendingPathComponent("tweet_abc.context.png").path, contents: nil)

        let items = try await watcher.scanArchive()

        // Should group all files under same base name
        XCTAssertEqual(items.count, 1)

        if let (_, files) = items.first {
            XCTAssertNotNil(files.metadataFile)
            XCTAssertEqual(files.mediaFiles.count, 2)
            XCTAssertNotNil(files.contextImage)
            XCTAssertTrue(files.isComplete)
        }
    }

    func testMultipleItemGroups() async throws {
        let monthFolder = tempDir.appendingPathComponent("2025-01")

        // Create multiple item groups
        FileManager.default.createFile(atPath: monthFolder.appendingPathComponent("item1.md").path, contents: "---\nsource: https://a.com\n---".data(using: .utf8))
        FileManager.default.createFile(atPath: monthFolder.appendingPathComponent("item1.jpg").path, contents: nil)

        FileManager.default.createFile(atPath: monthFolder.appendingPathComponent("item2.md").path, contents: "---\nsource: https://b.com\n---".data(using: .utf8))
        FileManager.default.createFile(atPath: monthFolder.appendingPathComponent("item2.png").path, contents: nil)

        let items = try await watcher.scanArchive()

        XCTAssertEqual(items.count, 2)
    }

    func testMetadataOnlyItem() async throws {
        let monthFolder = tempDir.appendingPathComponent("2025-01")

        // Create orphan .md file (no media)
        FileManager.default.createFile(atPath: monthFolder.appendingPathComponent("orphan.md").path, contents: "---\nsource: https://example.com\n---".data(using: .utf8))

        let items = try await watcher.scanArchive()

        XCTAssertEqual(items.count, 1)

        if let (_, files) = items.first {
            XCTAssertTrue(files.isMetadataOnly)
            XCTAssertNotNil(files.metadataFile)
            XCTAssertTrue(files.mediaFiles.isEmpty)
        }
    }

    // MARK: - Start/Stop Tests

    func testStartAndStop() async throws {
        try await watcher.start()
        let isRunningAfterStart = await watcher.isRunning
        XCTAssertTrue(isRunningAfterStart)

        await watcher.stop()
        let isRunningAfterStop = await watcher.isRunning
        XCTAssertFalse(isRunningAfterStop)
    }

    func testDoubleStartIsIdempotent() async throws {
        try await watcher.start()
        try await watcher.start() // Should not throw or crash
        let isRunning = await watcher.isRunning
        XCTAssertTrue(isRunning)

        await watcher.stop()
    }

    func testDoubleStopIsIdempotent() async throws {
        try await watcher.start()
        await watcher.stop()
        await watcher.stop() // Should not crash
        let isRunning = await watcher.isRunning
        XCTAssertFalse(isRunning)
    }

    // MARK: - Error Handling Tests

    func testStartWithInvalidPath() async throws {
        let invalidPath = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
        let invalidWatcher = TestableArchiveWatcher(archivePath: invalidPath)

        do {
            try await invalidWatcher.start()
            XCTFail("Should have thrown error for invalid path")
        } catch let error as WatcherError {
            if case .pathNotFound = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }
}

// MARK: - Testable Archive Watcher

/// Test implementation of ArchiveWatcher with synchronous testing support
actor TestableArchiveWatcher {

    private let archivePath: URL
    private var _isRunning = false
    private var continuation: AsyncStream<FileChange>.Continuation?
    private let _changes: AsyncStream<FileChange>

    nonisolated var changes: AsyncStream<FileChange> {
        _changes
    }

    var isRunning: Bool {
        _isRunning
    }

    private let debounceInterval: TimeInterval = 0.05 // Shorter debounce for tests
    private var recentPaths: [String: Date] = [:]

    init(archivePath: URL) {
        self.archivePath = archivePath

        var continuation: AsyncStream<FileChange>.Continuation?
        self._changes = AsyncStream { cont in
            continuation = cont
        }
        self.continuation = continuation

        // Setup file system monitoring in background
        Task {
            await self.setupDirectoryMonitor()
        }
    }

    private func setupDirectoryMonitor() {
        // In tests, we use a simpler polling-based approach
        // The real implementation uses FSEvents
    }

    func start() async throws {
        guard !_isRunning else { return }

        guard FileManager.default.fileExists(atPath: archivePath.path) else {
            throw WatcherError.pathNotFound(archivePath)
        }

        _isRunning = true

        // Establish the baseline before start returns. Otherwise a caller can
        // create a file before the background task's first scan and that file
        // is silently treated as pre-existing (not a timeout/FSEvents failure).
        let initialScan = performScan()
        Task {
            await monitorDirectory(initialScan: initialScan)
        }
    }

    func stop() async {
        _isRunning = false
        continuation?.finish()
    }

    private func monitorDirectory(initialScan: [String: Date]) async {
        // Simple polling-based monitoring for tests
        // Start with initial baseline scan (no events emitted)
        var lastScan = initialScan

        while _isRunning {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms poll interval

            guard _isRunning else { break }

            let currentFiles = performScan()

            // Check for new or modified files
            for (path, modDate) in currentFiles {
                if let lastMod = lastScan[path] {
                    if modDate > lastMod {
                        emitChange(FileChange(url: URL(fileURLWithPath: path), type: .modified))
                    }
                } else {
                    emitChange(FileChange(url: URL(fileURLWithPath: path), type: .created))
                }
            }

            // Check for deletions
            for (path, _) in lastScan {
                if currentFiles[path] == nil {
                    emitChange(FileChange(url: URL(fileURLWithPath: path), type: .deleted))
                }
            }

            lastScan = currentFiles
        }
    }

    /// Perform a single scan of the archive directory
    private func performScan() -> [String: Date] {
        var files: [String: Date] = [:]

        guard let enumerator = FileManager.default.enumerator(
            at: archivePath,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return files }

        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])

            // Skip directories
            if resourceValues?.isDirectory == true { continue }

            // Skip irrelevant extensions
            guard shouldEmitEvent(for: fileURL) else { continue }

            let modDate = resourceValues?.contentModificationDate ?? Date()
            files[fileURL.path] = modDate
        }

        return files
    }

    private func emitChange(_ change: FileChange) {
        // Debounce
        let now = Date()
        if let lastSeen = recentPaths[change.url.path],
           now.timeIntervalSince(lastSeen) < debounceInterval {
            return
        }
        recentPaths[change.url.path] = now

        continuation?.yield(change)
    }

    private func shouldEmitEvent(for url: URL) -> Bool {
        if url.lastPathComponent.hasPrefix(".") {
            return false
        }

        let ext = url.pathExtension.lowercased()
        let relevantExtensions = Set([
            "md", "jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "mov", "webm"
        ])

        return relevantExtensions.contains(ext)
    }

    nonisolated func extractBaseName(from url: URL) -> String {
        var filename = url.deletingPathExtension().lastPathComponent

        // Strip .context suffix (e.g., tweet_abc.context.png -> tweet_abc)
        if filename.hasSuffix(".context") {
            filename = String(filename.dropLast(".context".count))
        }

        // Only strip trailing _N suffixes where N is a single digit (1-9)
        // This handles multi-image posts like tweet_123_1.jpg, tweet_123_2.jpg -> tweet_123
        // But keeps tweet_123.jpg -> tweet_123 (the _123 is part of the base name)
        let pattern = #"^(.+)_[1-9]$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
           let range = Range(match.range(at: 1), in: filename) {
            return String(filename[range])
        }

        return filename
    }

    func scanArchive() async throws -> [URL: ArchiveItemFiles] {
        var items: [URL: ArchiveItemFiles] = [:]
        let fileURLs = try Self.enumeratedFileURLs(at: archivePath)

        for fileURL in fileURLs {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])

            if resourceValues?.isDirectory == true {
                continue
            }

            let baseName = extractBaseName(from: fileURL)
            let baseURL = fileURL.deletingLastPathComponent().appendingPathComponent(baseName)

            if items[baseURL] == nil {
                items[baseURL] = ArchiveItemFiles()
            }

            categorizeFile(fileURL, into: &items[baseURL]!)
        }

        return items
    }

    private nonisolated static func enumeratedFileURLs(at archivePath: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: archivePath,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw WatcherError.pathNotFound(archivePath)
        }

        var fileURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            fileURLs.append(fileURL)
        }
        return fileURLs
    }

    private func categorizeFile(_ url: URL, into files: inout ArchiveItemFiles) {
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent.lowercased()

        if ext == "md" {
            files.metadataFile = url
        } else if filename.contains(".context.") || filename.hasSuffix("_context.png") {
            files.contextImage = url
        } else if ["jpg", "jpeg", "png", "gif", "webp", "heic", "mp4", "mov", "webm"].contains(ext) {
            files.mediaFiles.append(url)
        }
    }
}
