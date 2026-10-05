import Foundation
import AppKit

/// Handles deletion of MediaItems and their files.
/// Supports both soft-delete (database only) and hard-delete (with disk trash).
final class DeleteService: @unchecked Sendable {
    private let mediaStore: MediaStore
    private let diskPreferenceOverride: Bool?
    private let trashOperation: (@Sendable (URL) async -> String?)?

    /// UserDefaults key for delete-from-disk preference
    static let deleteFromDiskKey = "deleteFilesFromDisk"

    /// Whether to also delete files from disk
    var deleteFromDisk: Bool {
        diskPreferenceOverride ?? UserDefaults.standard.bool(forKey: Self.deleteFromDiskKey)
    }

    init(mediaStore: MediaStore, deleteFromDisk: Bool? = nil, trashOperation: (@Sendable (URL) async -> String?)? = nil) {
        self.mediaStore = mediaStore
        self.diskPreferenceOverride = deleteFromDisk
        self.trashOperation = trashOperation
    }

    // MARK: - Delete Whole Items

    /// Delete items (soft-delete in DB, optionally trash files)
    /// - Returns: Count of items deleted, and any file errors
    func deleteItems(_ items: [MediaItem]) async throws -> DeleteResult {
        var seen = Set<UUID>()
        let requestedIDs = items.map(\.id).filter { seen.insert($0).inserted }
        let current = try await mediaStore.fetchItems(ids: requestedIDs, includeMLAttributes: false,
            includePerFileOCR: false, includeVideoSegments: false, includeTranscriptSegments: false)
        let ids = current.map(\.id)
        let files = current.flatMap { $0.mediaFiles + [$0.contextImage].compactMap { $0 } }
        let snapshot = captureTargets(deleteFromDisk ? files : [])

        // Soft delete in database
        try await mediaStore.softDelete(ids: ids)

        // Optionally trash files
        if deleteFromDisk {
            var result = await trashCaptured(snapshot, excludingItemIDs: ids)
            result.deletedCount = current.count
            return result
        }

        return DeleteResult(
            deletedCount: current.count,
            fileErrors: []
        )
    }

    /// Permanently remove items from NoDraw after moving every surviving file
    /// (including the sidecar) to the system Trash. An item whose files cannot
    /// all be moved remains in Recently Deleted for another attempt.
    func purgeDeletedItems(ids: [UUID]) async throws -> DeleteResult {
        let plan = try await mediaStore.makeDeletedItemPurgePlan(ids: ids)
        var purgeableIDs: [UUID] = []
        var fileErrors: [String] = []
        var failedFileURLs: [URL] = []
        var retryTargets: [RetryTarget] = []

        for entry in plan.entries {
            let urls = entry.fileURLs
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            let snapshot = captureTargets(urls)

            // Prevent the archive watcher from treating our sidecar removal as
            // an unrelated external delete while the DB transaction completes.
            if urls.contains(where: { $0.standardizedFileURL == entry.metadataFileURL.standardizedFileURL }) {
                await mediaStore.selfWriteTracker.markWritten(entry.metadataFileURL.path)
            }
            let result = await trashCaptured(snapshot, excludingItemIDs: ids)
            let itemErrors = result.fileErrors
            failedFileURLs.append(contentsOf: result.failedFileURLs)
            retryTargets.append(contentsOf: result.retryTargets)

            if itemErrors.isEmpty {
                purgeableIDs.append(entry.id)
            } else {
                fileErrors.append(contentsOf: itemErrors)
            }
        }

        let purgedCount = try await mediaStore.purgeDeletedRecords(ids: purgeableIDs)
        return DeleteResult(deletedCount: purgedCount, fileErrors: fileErrors, failedFileURLs: failedFileURLs, retryTargets: retryTargets)
    }

    // MARK: - Remove Single File from Item

    /// Remove a single file from a multi-file item.
    /// Does NOT delete the whole item.
    /// - Parameters:
    ///   - item: The MediaItem
    ///   - fileIndex: Index in mediaFiles array
    /// - Returns: Updated MediaItem with file removed
    func removeFile(from item: MediaItem, at fileIndex: Int) async throws -> FileRemovalResult {
        guard fileIndex >= 0 && fileIndex < item.mediaFiles.count else {
            throw DeleteError.invalidFileIndex
        }

        let fileURL = item.mediaFiles[fileIndex]
        let assets = item.assets.isEmpty ? try await mediaStore.fetchAssets(itemID: item.id) : item.assets
        guard let asset = assets.first(where: { $0.role == .media && $0.url == fileURL && $0.order == fileIndex }) else { throw DeleteError.invalidFileIndex }
        let snapshot = captureTargets(deleteFromDisk ? [fileURL] : [])
        let updatedItem = try await mediaStore.removeAsset(itemID: item.id, assetID: asset.assetID)

        // Optionally trash the file
        if deleteFromDisk {
            let result = await trashCaptured(snapshot, excludingItemIDs: [])
            return FileRemovalResult(updatedItem: updatedItem, fileErrors: result.fileErrors,
                failedFileURLs: result.failedFileURLs, retryTargets: result.retryTargets)
        }

        return FileRemovalResult(updatedItem: updatedItem, fileErrors: [], failedFileURLs: [])
    }

    /// Retry only explicit failed filesystem targets. Already-absent files are
    /// settled, and paths still referenced by another item remain untouched.
    func retryTrashFiles(_ targets: [RetryTarget], excludingItemIDs: [UUID]) async throws -> DeleteResult {
        let urls = targets.map(\.url)
        let protected = try await mediaStore.protectedFilePaths(candidates: urls, excludingItemIDs: excludingItemIDs)
        var seen = Set<String>()
        var errors: [String] = []
        var failed: [URL] = []
        var retryTargets: [RetryTarget] = []
        for target in targets {
            let url = target.url
            let identity = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard seen.insert(identity).inserted, !protected.contains(identity), FileManager.default.fileExists(atPath: url.path) else { continue }
            guard target.matchesCurrentFile else {
                errors.append("\(url.lastPathComponent) changed since the Trash attempt. The replacement was preserved; reveal and review it before a new deletion.")
                failed.append(url)
                continue
            }
            if let error = await trashFile(url) { errors.append(error); failed.append(url); retryTargets.append(target) }
        }
        return DeleteResult(deletedCount: 0, fileErrors: errors, failedFileURLs: failed, retryTargets: retryTargets)
    }

    private struct CapturedTargets {
        var targets: [RetryTarget] = []
        var errors: [String] = []
        var failedURLs: [URL] = []
    }

    private func captureTargets(_ urls: [URL]) -> CapturedTargets {
        var result = CapturedTargets()
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do { result.targets.append(try RetryTarget(url: url)) }
            catch { result.errors.append("Could not verify \(url.lastPathComponent); file was preserved: \(error.localizedDescription)"); result.failedURLs.append(url) }
        }
        return result
    }

    private func trashCaptured(_ snapshot: CapturedTargets, excludingItemIDs: [UUID]) async -> DeleteResult {
        do {
            let result = try await retryTrashFiles(snapshot.targets, excludingItemIDs: excludingItemIDs)
            return DeleteResult(deletedCount: 0, fileErrors: snapshot.errors + result.fileErrors,
                failedFileURLs: snapshot.failedURLs + result.failedFileURLs, retryTargets: result.retryTargets)
        } catch {
            return DeleteResult(deletedCount: 0, fileErrors: snapshot.errors + ["Could not verify ownership before Trash: \(error.localizedDescription)"],
                failedFileURLs: snapshot.failedURLs + snapshot.targets.map(\.url), retryTargets: snapshot.targets)
        }
    }

    // MARK: - Combine Orphan Cleanup

    /// Trash files orphaned by a combine (see `MediaStore.combineItems`), honoring the
    /// disk-delete preference exactly like a normal delete. No-op when disk-delete is off,
    /// so combine matches the rest of the app: soft-delete leaves files on disk, hard-delete
    /// trashes them. The URLs come pre-filtered by `combineItems` to exclude every path the
    /// merged primary still references, so this can't remove a live carousel file.
    /// - Returns: any per-file trashing errors (empty on success or when disk-delete is off).
    @discardableResult
    func trashCombineOrphans(_ urls: [URL]) async -> [String] {
        await trashCombineOrphansResult(urls).fileErrors
    }

    func trashCombineOrphansResult(_ urls: [URL]) async -> DeleteResult {
        guard deleteFromDisk, !urls.isEmpty else { return DeleteResult(deletedCount: 0, fileErrors: []) }
        return await trashCaptured(captureTargets(urls), excludingItemIDs: [])
    }

    // MARK: - File Trashing

    /// Move a single file to Trash
    @discardableResult
    private func trashFile(_ url: URL) async -> String? {
        if let trashOperation { return await trashOperation(url) }
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { trashedURLs, error in
                if let error = error {
                    continuation.resume(returning: "Failed to trash \(url.lastPathComponent): \(error.localizedDescription)")
                } else if !FileManager.default.fileExists(atPath: url.path) || trashedURLs[url] != nil {
                    Log.info("Trashed file: \(url.lastPathComponent)")
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: "Finder did not confirm moving \(url.lastPathComponent) to Trash")
                }
            }
        }
    }

    // MARK: - Types

    enum DeleteError: Error, LocalizedError {
        case invalidFileIndex

        var errorDescription: String? {
            switch self {
            case .invalidFileIndex:
                return "Invalid file index"
            }
        }
    }

    struct DeleteResult {
        var deletedCount: Int
        let fileErrors: [String]
        var failedFileURLs: [URL] = []
        var retryTargets: [RetryTarget] = []

        var hasFileErrors: Bool { !fileErrors.isEmpty }
    }

    struct FileRemovalResult {
        let updatedItem: MediaItem
        let fileErrors: [String]
        let failedFileURLs: [URL]
        var retryTargets: [RetryTarget] = []
        var hasFileErrors: Bool { !fileErrors.isEmpty }
    }

    struct RetryTarget: Sendable {
        let url: URL
        private let device: UInt64
        private let inode: UInt64
        private let size: UInt64
        private let modification: Date

        init(url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber,
                  let modification = attributes[.modificationDate] as? Date else { throw CocoaError(.fileReadUnknown) }
            self.url = url
            self.device = device.uint64Value
            self.inode = inode.uint64Value
            self.size = size.uint64Value
            self.modification = modification
        }

        var matchesCurrentFile: Bool {
            guard let current = try? RetryTarget(url: url) else { return false }
            return current.device == device && current.inode == inode && current.size == size && current.modification == modification
        }
    }

    struct PartialDeletionError: LocalizedError {
        let result: DeleteResult
        var errorDescription: String? {
            "Items remain in Recently Deleted, but some files could not be moved to Trash. Retry or reveal the surviving files. " + result.fileErrors.joined(separator: "\n")
        }
    }
}
