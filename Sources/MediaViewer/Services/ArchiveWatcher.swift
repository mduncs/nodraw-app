import Foundation

// MARK: - File Change Events

/// Type of change detected in the archive
enum FileChangeType: Sendable {
    case created
    case modified
    case deleted
    case renamed(oldPath: URL)
    case moved(oldPath: URL)  // Same as renamed but for cross-directory moves
}

/// A file system change event
struct FileChange: Sendable {
    let url: URL
    let type: FileChangeType
    let timestamp: Date

    init(url: URL, type: FileChangeType, timestamp: Date = Date()) {
        self.url = url
        self.type = type
        self.timestamp = timestamp
    }
}

// MARK: - Archive Watcher Protocol

/// Protocol for watching MediaArchive folder for changes
protocol ArchiveWatching: Sendable {
    /// Start watching the archive directory
    func start() async throws

    /// Stop watching
    func stop() async

    /// Stream of file change events
    var changes: AsyncStream<FileChange> { get }
}

// MARK: - FSEvents Implementation

/// FSEvents-based file watcher for MediaArchive
/// Uses low-level FSEvents API for efficient directory monitoring
actor ArchiveWatcher: ArchiveWatching {
    /// Dedicated queue for FSEvents callback delivery to avoid competing with UI work on main.
    private nonisolated static let fseventsQueue = DispatchQueue(
        label: "com.nodraw.archivewatcher.fsevents",
        qos: .utility
    )

    private nonisolated static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic"]
    private nonisolated static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "avi", "mkv"]
    private nonisolated static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "caf"]
    private nonisolated static let watchableExtensions: Set<String> = {
        Set(["md"]).union(imageExtensions).union(videoExtensions).union(audioExtensions)
    }()

    private let archivePath: URL
    private var eventStream: FSEventStreamRef?
    private var isRunning = false

    /// Retained pointer to self for FSEventStream context.
    /// Must be released in stop() to balance passRetained in start().
    private var retainedSelf: Unmanaged<ArchiveWatcher>?

    private var continuation: AsyncStream<FileChange>.Continuation?
    private let _changes: AsyncStream<FileChange>

    nonisolated var changes: AsyncStream<FileChange> {
        _changes
    }

    /// Debounce interval to coalesce rapid changes
    private let debounceInterval: TimeInterval = 0.5

    /// Track recently seen paths for debouncing
    private var recentPaths: [String: Date] = [:]

    /// Track pending rename events to detect rename pairs
    /// FSEvents emits renamed events for both old and new paths
    private var pendingRenames: [UInt64: PendingRename] = [:]

    /// Timeout for matching rename pairs (seconds)
    private let renamePairTimeout: TimeInterval = 0.5

    init(archivePath: URL) {
        self.archivePath = archivePath

        var continuation: AsyncStream<FileChange>.Continuation?
        self._changes = AsyncStream { cont in
            continuation = cont
        }
        self.continuation = continuation
    }

    deinit {
        // Warning: if we reach deinit without stop() being called, the stream wasn't cleaned up.
        // FSEventStream cleanup must happen via stop() due to actor isolation.
        if eventStream != nil {
            logWarning("ArchiveWatcher deallocated without calling stop(). Stream not properly cleaned up.")
        }
    }

    func start() async throws {
        guard !isRunning else { return }

        // Verify path exists
        guard FileManager.default.fileExists(atPath: archivePath.path) else {
            throw WatcherError.pathNotFound(archivePath)
        }

        // Create FSEvents stream
        let pathsToWatch = [archivePath.path] as CFArray

        // Context to pass self to callback
        // Using passRetained to prevent deallocation while stream is active.
        // Store the retained pointer so we can release it in stop().
        let retained = Unmanaged.passRetained(self)
        self.retainedSelf = retained

        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            nil,
            Self.eventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceInterval,
            flags
        ) else {
            // Release the retained pointer since we won't have a stream to clean up
            retainedSelf?.release()
            retainedSelf = nil
            throw WatcherError.streamCreationFailed
        }

        eventStream = stream

        // Schedule on a background queue so event bursts don't contend with UI rendering.
        FSEventStreamSetDispatchQueue(stream, Self.fseventsQueue)

        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            // Release the retained pointer since stream failed to start
            retainedSelf?.release()
            retainedSelf = nil
            eventStream = nil
            throw WatcherError.streamStartFailed
        }

        isRunning = true
    }

    func stop() async {
        guard isRunning, let stream = eventStream else { return }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)

        // Release the retained self from the context (balances passRetained in start())
        // We release the stored pointer, not a new passUnretained wrapper.
        retainedSelf?.release()
        retainedSelf = nil

        eventStream = nil
        isRunning = false
        continuation?.finish()
    }

    // MARK: - FSEvents Callback

    private static let eventCallback: FSEventStreamCallback = { (
        stream,
        contextInfo,
        numEvents,
        eventPaths,
        eventFlags,
        eventIds
    ) in
        guard let contextInfo = contextInfo else { return }
        let watcher = Unmanaged<ArchiveWatcher>.fromOpaque(contextInfo).takeUnretainedValue()

        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
            return
        }

        let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))

        Task {
            await watcher.processEvents(paths: paths, flags: flags)
        }
    }

    private func processEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        let now = Date()

        // Clean expired pending renames
        let renameTimeout = now.addingTimeInterval(-renamePairTimeout)
        pendingRenames = pendingRenames.filter { $0.value.timestamp > renameTimeout }

        for (index, path) in paths.enumerated() {
            let flag = flags[index]

            // Skip if we've seen this path very recently (debounce)
            if let lastSeen = recentPaths[path],
               now.timeIntervalSince(lastSeen) < debounceInterval {
                continue
            }
            recentPaths[path] = now

            // Clean old entries periodically
            if recentPaths.count > 1000 {
                let cutoff = now.addingTimeInterval(-debounceInterval * 2)
                recentPaths = recentPaths.filter { $0.value > cutoff }
            }

            let url = URL(fileURLWithPath: path)

            // Determine change type from flags
            let changeType: FileChangeType?

            if flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
                changeType = .deleted
            } else if flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
                // Handle rename pairs properly
                changeType = handleRenameEvent(path: path, flag: flag, timestamp: now)
            } else if flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
                changeType = .created
            } else if flag & UInt32(kFSEventStreamEventFlagItemModified) != 0 {
                changeType = .modified
            } else {
                // Some other flag, treat as modified
                changeType = .modified
            }

            // Only emit events for files we care about
            if let changeType = changeType, shouldEmitEvent(for: url, flag: flag) {
                let change = FileChange(url: url, type: changeType)
                continuation?.yield(change)
            }
        }
    }

    /// Handle rename events by tracking pairs.
    /// FSEvents emits kFSEventStreamEventFlagItemRenamed for both old and new paths.
    /// We detect the pair by checking file existence and matching inode.
    private func handleRenameEvent(path: String, flag: FSEventStreamEventFlags, timestamp: Date) -> FileChangeType? {
        let url = URL(fileURLWithPath: path)
        let fileExists = FileManager.default.fileExists(atPath: path)

        // Try to get inode for matching
        let inode = getInode(for: url)

        if fileExists {
            // This is the NEW path (file exists here now)
            // Look for a pending rename with matching inode
            if let inode = inode,
               let pending = pendingRenames.removeValue(forKey: inode) {
                // Found the pair - this is a rename/move
                let oldPath = URL(fileURLWithPath: pending.path)

                // Check if it's a cross-directory move or same-directory rename
                if oldPath.deletingLastPathComponent().path == url.deletingLastPathComponent().path {
                    return .renamed(oldPath: oldPath)
                } else {
                    return .moved(oldPath: oldPath)
                }
            } else {
                // No matching pending rename - could be new file or we missed the first event
                // Check if this might be an incoming rename from outside our watch scope
                return .created
            }
        } else {
            // This is the OLD path (file no longer exists here)
            // Store as pending, waiting for the new path event
            if let inode = inode {
                pendingRenames[inode] = PendingRename(path: path, timestamp: timestamp)
            } else {
                // Can't get inode (file already gone), treat as delete
                // But also check if we can match by timing with a recent create
                return .deleted
            }
            return nil  // Don't emit yet, wait for pair
        }
    }

    /// Get inode for a file (survives renames)
    private nonisolated func getInode(for url: URL) -> UInt64? {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return attrs[.systemFileNumber] as? UInt64
        } catch {
            return nil
        }
    }

    /// Filter events to only relevant file types
    private func shouldEmitEvent(for url: URL, flag: FSEventStreamEventFlags) -> Bool {
        // Skip directories
        if flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 {
            return false
        }

        // Skip hidden files
        if Self.isHiddenArchivePath(url, archivePath: archivePath) {
            return false
        }

        let ext = url.pathExtension.lowercased()

        return Self.watchableExtensions.contains(ext)
    }

    nonisolated static func isHiddenArchivePath(_ url: URL, archivePath: URL) -> Bool {
        let root = archivePath.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard components.starts(with: root) else { return true }
        return components.dropFirst(root.count).contains { $0.hasPrefix(".") }
    }
}

// MARK: - Pending Rename Tracking

/// Represents a rename event waiting for its pair
private struct PendingRename {
    let path: String
    let timestamp: Date
}

// MARK: - Errors

enum WatcherError: Error, LocalizedError {
    case pathNotFound(URL)
    case streamCreationFailed
    case streamStartFailed

    var errorDescription: String? {
        switch self {
        case .pathNotFound(let url):
            return "Archive path not found: \(url.path)"
        case .streamCreationFailed:
            return "Failed to create FSEvents stream"
        case .streamStartFailed:
            return "Failed to start FSEvents stream"
        }
    }
}

// MARK: - Initial Scan

extension ArchiveWatcher {
    /// Perform initial scan of archive to find all existing items
    /// Returns grouped files by base name (for multi-file items)
    func scanArchive() async throws -> [URL: ArchiveItemFiles] {
        var fileURLs: [URL] = []

        let fileManager = FileManager.default

        // Enumerate year-month folders
        guard let enumerator = fileManager.enumerator(
            at: archivePath,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw WatcherError.pathNotFound(archivePath)
        }

        for case let fileURL as URL in enumerator {
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])

            // Skip directories
            if resourceValues?.isDirectory == true {
                continue
            }

            // Skip non-archive file types early to reduce scan churn and allocations.
            guard shouldIncludeInInitialScan(fileURL) else {
                continue
            }

            fileURLs.append(fileURL)
        }

        return ArchiveAssociationResolver.resolve(fileURLs, archivePath: archivePath)
    }

    /// Fast include-check for initial scan to avoid allocating entries for unrelated files.
    private func shouldIncludeInInitialScan(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        if filename.hasPrefix(".") {
            return false
        }

        let ext = url.pathExtension.lowercased()
        guard Self.watchableExtensions.contains(ext) else {
            return false
        }

        if ext == "md" && filename == "index.md" {
            return false
        }

        return true
    }

}

/// Files associated with a single archive item
struct ArchiveItemFiles {
    var metadataFile: URL?
    var mediaFiles: [URL] = []
    var contextImage: URL?
    var absorbedContextSidecars: [URL] = []

    /// Item is complete if it has metadata - media files are optional (orphan .md support)
    var isComplete: Bool {
        metadataFile != nil
    }

    /// Item has no media files (metadata-only / orphan .md)
    var isMetadataOnly: Bool {
        metadataFile != nil && mediaFiles.isEmpty
    }
}
