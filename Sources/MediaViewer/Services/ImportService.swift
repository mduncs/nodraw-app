import Foundation
import AVFoundation
import Yams

// MARK: - Import Result

/// Result of importing files
struct ImportResult: Sendable {
    let importedCount: Int
    let skippedCount: Int
    let failedCount: Int
    let createdItemIds: [UUID]
    let errors: [ImportError]
    var cancelledCount: Int = 0
    var skippedItems: [ImportSkippedItem] = []

    var summary: String {
        var parts: [String] = []
        if importedCount > 0 {
            parts.append("\(importedCount) imported")
        }
        if skippedCount > 0 {
            parts.append("\(skippedCount) skipped")
        }
        if failedCount > 0 {
            parts.append("\(failedCount) failed")
        }
        if cancelledCount > 0 { parts.append("\(cancelledCount) cancelled") }
        return parts.joined(separator: ", ")
    }
}

/// Import error with context
struct ImportError: Sendable, Error, LocalizedError {
    let filename: String
    let reason: String
    let sourceURL: URL?
    let operationID: UUID?

    init(filename: String, reason: String, sourceURL: URL? = nil, operationID: UUID? = nil) {
        self.filename = filename
        self.reason = reason
        self.sourceURL = sourceURL
        self.operationID = operationID
    }

    var errorDescription: String? {
        "\(filename): \(reason)"
    }
}

struct ImportProgress: Sendable {
    let completed: Int
    let total: Int
    let filename: String
}

/// Import behavior options for bulk import.
struct ImportOptions: Sendable, Equatable {
    enum RepeatPolicy: Sendable, Equatable { case skipUnchanged, importAnotherCopy }
    /// When true, use the file's creation date as archivedDate and year-month destination.
    let useFileDateAsArchiveDate: Bool
    var repeatPolicy: RepeatPolicy = .skipUnchanged
    var preventLibraryDuplicates = false

    static var fileDrop: ImportOptions { Self.default.forFileDrop }
    var forFileDrop: ImportOptions {
        var options = self
        options.repeatPolicy = .skipUnchanged
        options.preventLibraryDuplicates = true
        return options
    }

    static let `default` = ImportOptions(useFileDateAsArchiveDate: false)
}

// MARK: - Import Service

/// Actor for importing files from Finder drag-drop into the archive.
/// Handles:
/// - File type filtering
/// - Destination folder determination (year-month)
/// - File copying with collision handling
/// - Metadata (.md) file creation
/// - Vision queue integration
actor ImportService {

    // MARK: - Supported Types

    /// Supported image extensions
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic"]

    /// Supported video extensions
    static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "avi", "mkv"]

    /// Supported audio extensions
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "caf"]

    /// All supported media extensions
    static let supportedExtensions: Set<String> = imageExtensions.union(videoExtensions).union(audioExtensions)

    // MARK: - Dependencies

    private let mediaStore: MediaStore
    private let visionQueue: VisionJobQueue?
    private let videoUnderstandingQueue: VideoUnderstandingQueue?
    private let transcriptionQueue: TranscriptionQueue?
    private let archivePath: URL
    private let checkpoint: (@Sendable (ImportOperation.Phase) throws -> Void)?
    private let libraryFileVersionReader: @Sendable (URL) throws -> DuplicateFileVersion
    private let libraryIndexDidBuild: (@Sendable (ImportLibraryDuplicatePrevention.IndexMetrics) -> Void)?
    private var journal: ImportOperationJournal { ImportOperationJournal(archivePath: archivePath) }

    // MARK: - Initialization

    init(
        mediaStore: MediaStore,
        visionQueue: VisionJobQueue?,
        videoUnderstandingQueue: VideoUnderstandingQueue? = nil,
        transcriptionQueue: TranscriptionQueue? = nil,
        archivePath: URL,
        checkpoint: (@Sendable (ImportOperation.Phase) throws -> Void)? = nil,
        libraryFileVersionReader: @escaping @Sendable (URL) throws -> DuplicateFileVersion = { try DuplicateFileVersion.read($0) },
        libraryIndexDidBuild: (@Sendable (ImportLibraryDuplicatePrevention.IndexMetrics) -> Void)? = nil
    ) {
        self.mediaStore = mediaStore
        self.visionQueue = visionQueue
        self.videoUnderstandingQueue = videoUnderstandingQueue
        self.transcriptionQueue = transcriptionQueue
        self.archivePath = archivePath
        self.checkpoint = checkpoint
        self.libraryFileVersionReader = libraryFileVersionReader
        self.libraryIndexDidBuild = libraryIndexDidBuild
    }

    // MARK: - Public API

    /// Import files from URLs (e.g., dropped from Finder).
    /// - Parameter urls: File URLs to import
    /// - Returns: Import result with statistics and created item IDs
    func importFiles(
        _ urls: [URL],
        tags: [String] = [],
        options: ImportOptions = .default,
        progress: (@Sendable (ImportProgress) async -> Void)? = nil
    ) async throws -> ImportResult {
        let key = ArchiveAssociationResolver.canonicalPath(archivePath)
        await ImportArchiveGate.shared.acquire(key)
        do {
            try Task.checkCancellation()
            let result = try await importFilesExclusively(urls, tags: tags, options: options, progress: progress)
            await ImportArchiveGate.shared.release(key)
            return result
        } catch {
            await ImportArchiveGate.shared.release(key)
            throw error
        }
    }

    private func importFilesExclusively(
        _ urls: [URL], tags: [String], options: ImportOptions,
        progress: (@Sendable (ImportProgress) async -> Void)?
    ) async throws -> ImportResult {
        logInfo("ImportService: Starting import of \(urls.count) files")

        // Keep provider security scopes alive before resolving file aliases.
        let scopes = urls.map(ImportSecurityScope.init)
        defer { withExtendedLifetime(scopes) {} }
        var seenSources = Set<String>()
        var originalSources: [String: URL] = [:]
        // One source is one operation per drop, even with repeated/aliased URLs.
        let supportedFiles = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return (ImportLibraryDuplicatePrevention.isInArchive(url, archivePath: archivePath)
                    || Self.supportedExtensions.contains(ext))
                && seenSources.insert(ArchiveAssociationResolver.canonicalPath(url)).inserted
        }.map { url in
            originalSources[ArchiveAssociationResolver.canonicalPath(url)] = url
            return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
                ? url.resolvingSymlinksInPath() : url.standardizedFileURL
        }

        var skippedCount = urls.count - supportedFiles.count
        if skippedCount > 0 {
            logInfo("ImportService: Skipped \(skippedCount) unsupported or repeated source URLs")
        }

        guard !supportedFiles.isEmpty else {
            return ImportResult(
                importedCount: 0,
                skippedCount: skippedCount,
                failedCount: 0,
                createdItemIds: [],
                errors: []
            )
        }

        // Import each file
        var importedCount = 0
        var failedCount = 0
        var createdItemIds: [UUID] = []
        var errors: [ImportError] = []
        var cancelledCount = 0
        // Record the entire accepted batch before copying its first byte.
        var preparationErrors: [URL: ImportError] = [:]
        var prepared: [URL: ImportOperation] = [:]
        let existingOperations = try journal.operations()
        var reserved = Set(existingOperations.filter { $0.phase != .completed }.flatMap { [$0.destinationURL, $0.metadataURL] })
        var skippedSources = Set<URL>()
        var skippedItems: [ImportSkippedItem] = []
        let library = ImportLibraryDuplicatePrevention(database: mediaStore.database)
        let needsIndex = options.preventLibraryDuplicates || supportedFiles.contains {
            ImportLibraryDuplicatePrevention.isInArchive($0, archivePath: archivePath)
        }
        let libraryIndex: ImportLibraryDuplicatePrevention.Index?
        if needsIndex {
            let reader = libraryFileVersionReader
            let archive = archivePath
            let indexing = Task.detached(priority: .utility) { try await library.makeIndex(archivePath: archive, fileVersionReader: reader) }
            libraryIndex = try await withTaskCancellationHandler(operation: { try await indexing.value }, onCancel: { indexing.cancel() })
            try Task.checkCancellation()
            if let metrics = libraryIndex?.metrics { libraryIndexDidBuild?(metrics) }
        } else { libraryIndex = nil }
        for sourceURL in supportedFiles {
            do {
                try Task.checkCancellation()
                let archiveResident = ImportLibraryDuplicatePrevention.isInArchive(sourceURL, archivePath: archivePath)
                if let libraryIndex, archiveResident || options.preventLibraryDuplicates {
                    let original = originalSources[ArchiveAssociationResolver.canonicalPath(sourceURL)] ?? sourceURL
                    let existing = try await library.existingItem(for: original, compareBytes: !archiveResident, index: libraryIndex)
                    if archiveResident || existing != nil {
                        skippedSources.insert(sourceURL)
                        skippedCount += 1
                        skippedItems.append(existing ?? ImportSkippedItem(sourceURL: original, existingItemID: nil,
                            existingURL: sourceURL, existingName: sourceURL.lastPathComponent))
                        continue
                    }
                }
                if options.repeatPolicy == .skipUnchanged,
                   try await isAlreadyImported(sourceURL, operations: existingOperations) {
                    skippedSources.insert(sourceURL)
                    skippedCount += 1
                    continue
                }
                let sourcePath = ArchiveAssociationResolver.canonicalPath(sourceURL)
                if options.repeatPolicy == .skipUnchanged,
                   let existing = existingOperations.first(where: { $0.phase != .completed && ArchiveAssociationResolver.canonicalPath($0.sourceURL) == sourcePath }) {
                    prepared[sourceURL] = existing
                } else {
                    let operation = try prepareOperation(sourceURL, tags: tags, options: options, reserved: reserved)
                    try journal.save(operation)
                    prepared[sourceURL] = operation
                    reserved.insert(operation.destinationURL)
                    reserved.insert(operation.metadataURL)
                }
            } catch {
                preparationErrors[sourceURL] = ImportError(filename: sourceURL.lastPathComponent, reason: error.localizedDescription, sourceURL: sourceURL)
            }
        }

        for (index, sourceURL) in supportedFiles.enumerated() {
            if skippedSources.contains(sourceURL) { continue }
            if Task.isCancelled {
                if var operation = prepared[sourceURL] {
                    await retractUncommitted(operation)
                    operation.phase = .cancelled
                    operation.error = "Import cancelled before completion"
                    try? journal.save(operation)
                }
                cancelledCount += 1
                errors.append(ImportError(filename: sourceURL.lastPathComponent, reason: "Import cancelled before completion", sourceURL: sourceURL))
                continue
            }
            await progress?(ImportProgress(completed: index, total: supportedFiles.count, filename: sourceURL.lastPathComponent))
            do {
                if let error = preparationErrors[sourceURL] { throw error }
                guard let operation = prepared[sourceURL] else { throw ImportError(filename: sourceURL.lastPathComponent, reason: "Import could not be prepared") }
                let itemId = try await importSingleFile(sourceURL, operation: operation)
                createdItemIds.append(itemId)
                importedCount += 1
            } catch {
                if Task.isCancelled || error is CancellationError { cancelledCount += 1 } else { failedCount += 1 }
                errors.append((error as? ImportError) ?? ImportError(filename: sourceURL.lastPathComponent, reason: error.localizedDescription, sourceURL: sourceURL))
                logError("ImportService: Failed to import \(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
            await progress?(ImportProgress(completed: index + 1, total: supportedFiles.count, filename: sourceURL.lastPathComponent))
        }

        logInfo("ImportService: Import complete. \(importedCount) imported, \(failedCount) failed")

        return ImportResult(
            importedCount: importedCount,
            skippedCount: skippedCount,
            failedCount: failedCount,
            createdItemIds: createdItemIds,
            errors: errors,
            cancelledCount: cancelledCount,
            skippedItems: skippedItems
        )
    }

    /// Called before startup scanning. Never needs access to the original when
    /// staging is complete; incomplete/ambiguous attempts remain visible failures.
    func recoverInterruptedImports() async -> ImportResult {
        let key = ArchiveAssociationResolver.canonicalPath(archivePath)
        await ImportArchiveGate.shared.acquire(key)
        let result = await recoverInterruptedImportsExclusively()
        await ImportArchiveGate.shared.release(key)
        return result
    }

    private func recoverInterruptedImportsExclusively() async -> ImportResult {
        var ids: [UUID] = []
        var errors: [ImportError] = []
        do {
            let scan = try journal.scan()
            errors.append(contentsOf: scan.errors)
            for var operation in scan.operations where operation.phase != .completed {
                do {
                    if let existing = try await ownedDatabaseItem(operation) {
                        operation.phase = .completed
                        try? journal.save(operation)
                        ids.append(existing.id)
                    } else if operation.phase == .cancelled {
                        throw ImportError(filename: operation.sourceURL.lastPathComponent, reason: "Import was cancelled. Retry when ready; staged files are preserved.")
                    } else if operation.mediaEvidence != nil && operation.sidecarEvidence != nil {
                        ids.append(try await resume(&operation))
                    } else {
                        throw ImportError(filename: operation.sourceURL.lastPathComponent, reason: "Import was interrupted before staging finished. Retry from the original file; partial files are preserved.")
                    }
                } catch {
                    await retractUncommitted(operation)
                    operation.error = error.localizedDescription
                    if operation.phase != .cancelled { operation.phase = .failed }
                    try? journal.save(operation)
                    errors.append(ImportError(filename: operation.sourceURL.lastPathComponent, reason: error.localizedDescription, sourceURL: operation.sourceURL, operationID: operation.id))
                }
            }
        } catch {
            errors.append(ImportError(filename: "Import recovery", reason: error.localizedDescription))
        }
        return ImportResult(importedCount: ids.count, skippedCount: 0, failedCount: errors.count, createdItemIds: ids, errors: errors)
    }

    func unresolvedImportErrors() -> [ImportError] {
        do {
            let scan = try journal.scan()
            return scan.errors + scan.operations.filter { $0.phase != .completed }.map { operation in
                ImportError(filename: operation.sourceURL.lastPathComponent, reason: operation.error ?? "Import is waiting for retry", sourceURL: operation.sourceURL, operationID: operation.id)
            }
        } catch { return [ImportError(filename: "Import recovery", reason: error.localizedDescription)] }
    }

    // MARK: - Private Methods

    /// Preserve receipt replay rules for explicit imports. Window drops also
    /// check live library bytes before reaching this recovery path.
    private func isAlreadyImported(_ source: URL, operations: [ImportOperation]) async throws -> Bool {
        let sourcePath = ArchiveAssociationResolver.canonicalPath(source)
        let candidates = operations.filter {
            $0.phase == .completed && $0.sourceEvidence != nil
                && ArchiveAssociationResolver.canonicalPath($0.sourceURL) == sourcePath
        }
        guard !candidates.isEmpty else { return false }
        let current = try ImportFileEvidence(url: source)
        let sourceSidecar = source.deletingPathExtension().appendingPathExtension("md")
        let hasSidecar = FileManager.default.fileExists(atPath: sourceSidecar.path)
        for operation in candidates {
            guard current.sha256 == operation.sourceEvidence?.sha256,
                  operation.hadSourceSidecar == hasSidecar,
                  !hasSidecar || operation.sourceSidecarEvidence?.matches(sourceSidecar) == true,
                  operation.mediaEvidence?.matches(operation.destinationURL) == true,
                  try await ownedDatabaseItem(operation) != nil else { continue }
            return true
        }
        return false
    }

    /// Import a single file to the destination folder.
    /// - Parameters:
    ///   - sourceURL: Source file URL
    /// - Returns: UUID of the created MediaItem
    private func importSingleFile(
        _ sourceURL: URL,
        operation initial: ImportOperation
    ) async throws -> UUID {
        let scope = ImportSecurityScope(sourceURL)
        defer { withExtendedLifetime(scope) {} }
        var operation = initial
        do {
            return try await resume(&operation)
        } catch {
            await retractUncommitted(operation)
            operation.phase = Task.isCancelled || error is CancellationError ? .cancelled : .failed
            operation.error = error.localizedDescription
            try? journal.save(operation)
            throw ImportError(filename: sourceURL.lastPathComponent, reason: error.localizedDescription, sourceURL: sourceURL, operationID: operation.id)
        }
    }

    private func prepareOperation(_ sourceURL: URL, tags: [String], options: ImportOptions, reserved: Set<URL> = []) throws -> ImportOperation {
        let importedAt: Date
        if options.useFileDateAsArchiveDate {
            if let fileDate = fileArchiveDate(for: sourceURL) {
                importedAt = fileDate
            } else {
                importedAt = Date()
                logWarning("ImportService: Missing file date metadata for \(sourceURL.lastPathComponent), using current date")
            }
        } else {
            importedAt = Date()
        }

        let destinationFolderName = yearMonthFolder(for: importedAt)
        let destinationFolder = archivePath.appendingPathComponent(destinationFolderName)
        logInfo("ImportService: Importing \(sourceURL.lastPathComponent) into \(destinationFolderName)")
        try ensureDirectoryExists(at: destinationFolder)

        let sidecar = sourceURL.deletingPathExtension().appendingPathExtension("md")
        let hadSourceSidecar = FileManager.default.fileExists(atPath: sidecar.path)
        let sourceSidecarEvidence = hadSourceSidecar ? try? ImportFileEvidence(url: sidecar) : nil
        let existingMetadata = hadSourceSidecar ? existingMetadataSidecar(for: sourceURL) : nil
        if let sourceSidecarEvidence, !sourceSidecarEvidence.matches(sidecar) {
            throw ImportError(filename: sidecar.lastPathComponent, reason: "Source sidecar changed during import; retry when it is stable")
        }
        let originalDate = existingMetadata?.originalDate ?? fileCreationDate(for: sourceURL)
        let mergedTags = mergedTags(existingMetadata?.tags ?? [], tags)

        // Generate unique filename if collision exists
        let destinationURL = uniqueDestinationURL(for: sourceURL, in: destinationFolder, avoiding: reserved)

        let source = existingMetadata?.source ?? sourceURL
        let metadata = MediaMetadata(
            source: source,
            platform: existingMetadata?.platform ?? "import",
            author: existingMetadata?.author,
            originalDate: originalDate,
            archivedDate: importedAt,
            downloadDate: existingMetadata?.downloadDate,
            importDate: importedAt,
            starred: existingMetadata?.starred ?? false,
            tags: mergedTags,
            notes: existingMetadata?.notes,
            uploadDate: existingMetadata?.uploadDate
        )

        var operation = ImportOperation(id: UUID(), itemID: UUID(), sourceURL: sourceURL, destinationURL: destinationURL, metadataURL: destinationURL.deletingPathExtension().appendingPathExtension("md"), metadata: metadata)
        operation.hadSourceSidecar = hadSourceSidecar
        operation.sourceSidecarEvidence = sourceSidecarEvidence
        return operation
    }

    private func resume(_ operation: inout ImportOperation) async throws -> UUID {
        if let existing = try await ownedDatabaseItem(operation) {
            operation.phase = .completed
            try journal.save(operation)
            return existing.id
        }
        try Task.checkCancellation()
        let stagedMedia = journal.stagedMedia(operation)
        if operation.mediaEvidence == nil {
            try journal.validateContained(operation.destinationURL)
            if FileManager.default.fileExists(atPath: stagedMedia.path) {
                try DurableArchiveFile.publish(stagedMedia, to: journal.folder(operation.id).appendingPathComponent(".partial-\(UUID().uuidString)"))
            }
            // A retry with no complete stage may read a now-stable source again.
            // Once a stage exists, recovery never replaces its intended bytes.
            operation.sourceEvidence = try ImportFileEvidence(url: operation.sourceURL)
            try DurableArchiveFile.copyCancellable(operation.sourceURL, to: stagedMedia)
            operation.mediaEvidence = try ImportFileEvidence(url: stagedMedia)
            if let sourceEvidence = operation.sourceEvidence {
                guard sourceEvidence.sha256 == operation.mediaEvidence?.sha256 else {
                    operation.mediaEvidence = nil
                    throw ImportError(filename: operation.sourceURL.lastPathComponent, reason: "Source changed during import; recovery files were preserved")
                }
            }
            try journal.save(operation)
        }
        if operation.sidecarEvidence == nil {
            let stagedSidecar = journal.stagedSidecar(operation)
            let sourceContent = try sourceSidecarContent(for: operation)
            _ = try createMetadataFile(for: operation.destinationURL, metadata: operation.metadata, at: stagedSidecar, operationID: operation.id, sourceContent: sourceContent)
            try DurableArchiveFile.sync(stagedSidecar)
            operation.sidecarEvidence = try ImportFileEvidence(url: stagedSidecar)
        }
        operation.phase = .staged
        try journal.save(operation)
        try checkpoint?(.staged)
        try Task.checkCancellation()
        try journal.publish(stagedMedia, to: operation.destinationURL, evidence: operation.mediaEvidence!)
        operation.phase = .mediaPublished
        try journal.save(operation)
        try checkpoint?(.mediaPublished)
        try Task.checkCancellation()
        try journal.publish(journal.stagedSidecar(operation), to: operation.metadataURL, evidence: operation.sidecarEvidence!)
        operation.phase = .filesPublished
        try journal.save(operation)
        try checkpoint?(.filesPublished)
        let aspectRatio = await calculateAspectRatio(for: operation.destinationURL)
        try Task.checkCancellation()
        let item = MediaItem(
            id: operation.itemID,
            basePath: operation.destinationURL.deletingLastPathComponent(),
            metadataFile: operation.metadataURL,
            mediaFiles: [operation.destinationURL],
            contextImage: nil,
            metadata: operation.metadata,
            indexedContent: nil,
            aspectRatio: aspectRatio
        )

        do { try await mediaStore.insertItem(item) }
        catch {
            // A watcher may have indexed the just-published sidecar first.
            guard let existing = try await ownedDatabaseItem(operation) else { throw error }
            operation.phase = .completed
            try? journal.save(operation)
            return existing.id
        }
        operation.phase = .completed
        operation.error = nil
        // A journal-ack failure cannot undo an already committed DB item.
        do { try checkpoint?(.databaseCommitted); try journal.save(operation); try checkpoint?(.completed) }
        catch { logWarning("Import receipt remains recoverable after DB commit: \(error)") }
        let itemId = operation.itemID
        let destinationURL = operation.destinationURL

        // Enqueue for Vision processing only for visual media.
        if !Self.audioExtensions.contains(destinationURL.pathExtension.lowercased()) {
            if let visionQueue {
                await visionQueue.enqueue(itemId: itemId, priority: .normal)
            } else {
                logWarning("ImportService: Vision queue unavailable, skipping processing enqueue for \(itemId)")
            }
        }

        if Self.videoExtensions.contains(destinationURL.pathExtension.lowercased()) {
            if let videoUnderstandingQueue {
                await videoUnderstandingQueue.enqueue(itemId: itemId)
            } else {
                logWarning("ImportService: Video understanding queue unavailable, skipping video enqueue for \(itemId)")
            }
        }

        if Self.audioExtensions.contains(destinationURL.pathExtension.lowercased()) ||
            Self.videoExtensions.contains(destinationURL.pathExtension.lowercased()) {
            if let transcriptionQueue {
                await transcriptionQueue.enqueue(itemId: itemId)
            } else {
                logWarning("ImportService: Transcription queue unavailable, skipping transcript enqueue for \(itemId)")
            }
        }

        return itemId
    }

    private func ownedDatabaseItem(_ operation: ImportOperation) async throws -> MediaItem? {
        guard let existing = try await mediaStore.fetchItem(byMetadataPath: operation.metadataURL.path) else { return nil }
        let marker: String? = {
            guard let content = try? String(contentsOf: operation.metadataURL, encoding: .utf8),
                  let boundaries = try? FrontmatterWriter.parseBoundaries(content),
                  let values = try? SidecarYAML.load(yaml: boundaries.yamlText) as? [String: Any] else { return nil }
            return values["import_operation_id"] as? String
        }()
        guard existing.id == operation.itemID || (existing.mediaFiles.contains(operation.destinationURL) && (operation.sidecarEvidence?.matches(operation.metadataURL) == true || marker == operation.id.uuidString)) else {
            throw ImportError(filename: operation.metadataURL.lastPathComponent, reason: "Another archive item occupies this import destination. Files were preserved for review.")
        }
        return existing
    }

    private func retractUncommitted(_ operation: ImportOperation) async {
        // Completed DB ownership wins even if the journal acknowledgement failed.
        if let existing = try? await mediaStore.fetchItem(id: operation.itemID), existing.id == operation.itemID { return }
        if let existing = try? await mediaStore.fetchItem(byMetadataPath: operation.metadataURL.path), existing.mediaFiles.contains(operation.destinationURL) { return }
        for (published, staged, evidence) in [(operation.metadataURL, journal.stagedSidecar(operation), operation.sidecarEvidence), (operation.destinationURL, journal.stagedMedia(operation), operation.mediaEvidence)] {
            guard let evidence, evidence.matches(published), !FileManager.default.fileExists(atPath: staged.path) else { continue }
            do { try journal.validateContained(published); try DurableArchiveFile.publish(published, to: staged) }
            catch { logError("Import recovery could not preserve \(published.path): \(error)") }
        }
    }

    /// Re-read only before staging, checking the same version that supplied metadata.
    /// Legacy receipts without source evidence retain their original generated output.
    private func sourceSidecarContent(for operation: ImportOperation) throws -> String? {
        let sidecar = operation.sourceURL.deletingPathExtension().appendingPathExtension("md")
        if operation.hadSourceSidecar == false, FileManager.default.fileExists(atPath: sidecar.path) {
            throw ImportError(filename: sidecar.lastPathComponent, reason: "Source sidecar changed during import; retry when it is stable")
        }
        guard let evidence = operation.sourceSidecarEvidence else { return nil }
        guard evidence.matches(sidecar) else {
            throw ImportError(filename: sidecar.lastPathComponent, reason: "Source sidecar changed during import; retry when it is stable")
        }
        // Unreadable UTF-8 retains the existing graceful metadata fallback.
        let content = try? String(contentsOf: sidecar, encoding: .utf8)
        guard evidence.matches(sidecar) else {
            throw ImportError(filename: sidecar.lastPathComponent, reason: "Source sidecar changed during import; retry when it is stable")
        }
        return content
    }

    /// Create a .md metadata file for an imported media file.
    /// - Parameter mediaURL: URL of the media file
    /// - Returns: URL of the created .md file
    private func createMetadataFile(for mediaURL: URL, metadata: MediaMetadata, at explicitURL: URL? = nil, operationID: UUID? = nil, sourceContent: String? = nil) throws -> URL {
        let mdURL = explicitURL ?? mediaURL.deletingPathExtension().appendingPathExtension("md")

        // Build frontmatter and preserve important date fields for future DB rebuilds.
        let iso8601 = ISO8601DateFormatter()
        var yaml: [String: Any] = [
            "source": metadata.source.absoluteString,
            "platform": metadata.platform,
            "archived": iso8601.string(from: metadata.archivedDate),
            "starred": metadata.starred,
            "tags": metadata.tags,
        ]
        if let operationID { yaml["import_operation_id"] = operationID.uuidString }

        if let downloadDate = metadata.downloadDate {
            yaml["download_date"] = iso8601.string(from: downloadDate)
        }
        if let importDate = metadata.importDate {
            yaml["import_date"] = iso8601.string(from: importDate)
        }
        if let uploadDate = metadata.uploadDate {
            yaml["upload_date"] = iso8601.string(from: uploadDate)
        }

        if let author = metadata.author, !author.isEmpty {
            yaml["author"] = author
        }
        if let originalDate = metadata.originalDate {
            let dateString = iso8601.string(from: originalDate)
            yaml["date"] = dateString
            yaml["created"] = dateString
        }
        if let notes = metadata.notes, !notes.isEmpty {
            yaml["notes"] = notes
        }

        var body = "\n"
        if let sourceContent,
           let bounds = try? FrontmatterWriter.parseBoundaries(sourceContent),
           let sourceYAML = try? SidecarYAML.load(yaml: bounds.yamlText) as? [String: Any] {
            // Optional managed fields must stay absent when the app omits them. The imported
            // item starts out neither deleted nor annotated, whatever the source said.
            let managedKeys: Set<String> = ["source", "platform", "archived", "starred", "tags", "notes", "author", "date", "created", "download_date", "import_date", "upload_date", "import_operation_id", "deleted", "annotated"]
            for (key, value) in sourceYAML where !managedKeys.contains(key) {
                yaml[key] = preservingTimestampPrecision(value, formatter: iso8601)
            }
            body = String(sourceContent[bounds.bodyStartIndex...])
        }

        let frontmatter = try Yams.dump(object: yaml, allowUnicode: true, sortKeys: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let content = "---\n\(frontmatter)\n---\(body)"
        try content.write(to: mdURL, atomically: true, encoding: .utf8)
        return mdURL
    }

    /// Yams' default Date representation rounds to milliseconds, including nested dates.
    private func preservingTimestampPrecision(_ value: Any, formatter: ISO8601DateFormatter) -> Any {
        if let date = value as? Date {
            let whole = floor(date.timeIntervalSinceReferenceDate)
            let nanoseconds = Int(((date.timeIntervalSinceReferenceDate - whole) * 1_000_000_000).rounded())
            let seconds = Date(timeIntervalSinceReferenceDate: whole + Double(nanoseconds / 1_000_000_000))
            let fraction = String(format: ".%09d", nanoseconds % 1_000_000_000)
            return Node("\(formatter.string(from: seconds).dropLast())\(fraction)Z", Tag(.timestamp))
        }
        if let values = value as? [String: Any] {
            return values.mapValues { preservingTimestampPrecision($0, formatter: formatter) }
        }
        if let values = value as? [Any] {
            return values.map { preservingTimestampPrecision($0, formatter: formatter) }
        }
        return value
    }

    /// Generate a unique destination URL, adding numeric suffix if collision exists.
    /// - Parameters:
    ///   - sourceURL: Original source URL
    ///   - folder: Destination folder
    /// - Returns: Unique URL in the destination folder
    private func uniqueDestinationURL(for sourceURL: URL, in folder: URL, avoiding reserved: Set<URL> = []) -> URL {
        let fm = FileManager.default
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension

        var candidate = folder.appendingPathComponent("\(baseName).\(ext)")
        var counter = 1

        while reserved.contains(candidate) || reserved.contains(candidate.deletingPathExtension().appendingPathExtension("md")) || fm.fileExists(atPath: candidate.path) || fm.fileExists(atPath: candidate.deletingPathExtension().appendingPathExtension("md").path) {
            candidate = folder.appendingPathComponent("\(baseName)_\(counter).\(ext)")
            counter += 1
        }

        return candidate
    }

    /// Get year-month folder name for a date (e.g., "2026-01").
    private func yearMonthFolder(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    /// Ensure a directory exists, creating it if needed.
    private func ensureDirectoryExists(at url: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ImportError(
                    filename: url.lastPathComponent,
                    reason: "Destination exists but is not a directory"
                )
            }
            return
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        logInfo("ImportService: Created directory \(url.lastPathComponent)")
    }

    /// Load sibling sidecar metadata for a source file when available.
    private func existingMetadataSidecar(for sourceURL: URL) -> MediaMetadata? {
        let sidecarURL = sourceURL.deletingPathExtension().appendingPathExtension("md")
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            return nil
        }

        let parsed = MetadataParser.parseGracefully(fileAt: sidecarURL)
        switch parsed {
        case .success(let metadata), .partial(let metadata, _):
            return metadata
        case .failed:
            return nil
        }
    }

    /// Merge sidecar tags and import preset tags while keeping deterministic order.
    private func mergedTags(_ existing: [String], _ incoming: [String]) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        for tag in existing + incoming {
            let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(normalized)
        }
        return merged
    }

    /// Get the creation date of a file when available.
    private func fileCreationDate(for url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.creationDate] as? Date
    }

    /// Resolve a stable archive date from filesystem metadata.
    /// Prefers creation date, then modification date.
    private func fileArchiveDate(for url: URL) -> Date? {
        if let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]),
           let date = values.creationDate ?? values.contentModificationDate {
            return date
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let creation = attributes?[.creationDate] as? Date {
            return creation
        }
        if let modified = attributes?[.modificationDate] as? Date {
            return modified
        }
        return nil
    }

    /// Calculate aspect ratio for a media file.
    private func calculateAspectRatio(for url: URL) async -> CGFloat? {
        let ext = url.pathExtension.lowercased()

        if Self.videoExtensions.contains(ext) {
            return await calculateVideoAspectRatio(for: url)
        }

        guard Self.imageExtensions.contains(ext) else {
            return 1.0
        }

        // Load image dimensions
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return 1.0
        }

        // Check EXIF orientation - orientations 5-8 indicate 90/270 degree rotation
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let isRotated = [5, 6, 7, 8].contains(orientation)

        let ratio: CGFloat
        if isRotated {
            ratio = CGFloat(height) / CGFloat(width)
        } else {
            ratio = CGFloat(width) / CGFloat(height)
        }

        // Clamp to reasonable bounds
        return min(max(ratio, 0.25), 4.0)
    }

    /// Calculate aspect ratio from video file.
    private func calculateVideoAspectRatio(for url: URL) async -> CGFloat? {
        let asset = AVAsset(url: url)

        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = tracks.first else {
                return 16.0 / 9.0
            }

            let size = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)

            let transformedSize = size.applying(transform)
            let width = abs(transformedSize.width)
            let height = abs(transformedSize.height)

            guard width > 0, height > 0 else {
                return 16.0 / 9.0
            }

            let ratio = width / height
            return min(max(ratio, 0.25), 4.0)
        } catch {
            logDebug("ImportService: Failed to get video dimensions for \(url.lastPathComponent): \(error.localizedDescription)")
            return 16.0 / 9.0
        }
    }
}
