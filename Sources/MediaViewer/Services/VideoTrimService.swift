import AVFoundation
import Foundation

// MARK: - Trim Error

/// Errors that can occur during video trim export
enum TrimError: Error, LocalizedError {
    case exportSessionCreationFailed
    case cancelled
    case unknown
    case backupFailed(String)
    case replaceFailed(String)

    var errorDescription: String? {
        switch self {
        case .exportSessionCreationFailed:
            return "Failed to create export session"
        case .cancelled:
            return "Export was cancelled"
        case .unknown:
            return "Unknown export error"
        case .backupFailed(let detail):
            return "Failed to back up original: \(detail)"
        case .replaceFailed(let detail):
            return "Failed to replace original: \(detail)"
        }
    }
}

// MARK: - Video Trim Service

/// Actor for thread-safe video trim export operations.
/// Uses passthrough export to avoid re-encoding.
///
/// ## Issue #10: Single Video Only Limitation
/// Currently, trim operations work on a single video at a time.
/// A future enhancement could add batch trim capability for multi-select in grid view:
/// - Allow selecting a trim range that applies to multiple clips
/// - Parallel export with aggregate progress feedback
/// - Useful for standardizing clip lengths across a collection
actor VideoTrimService {

    // MARK: - File Naming

    /// Generate output path for trimmed video.
    /// - `video.mp4` -> `video-trim.mp4`
    /// - `video-trim.mp4` -> `video-trim-trim.mp4`
    /// - If `video-trim.mp4` exists and we're trimming `video.mp4`, overwrite it
    static func outputPath(for sourceURL: URL, existingFiles: [URL]) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension

        // Determine output name
        let outputName: String
        if baseName.hasSuffix("-trim") {
            // Trimming a trim -> chain it
            outputName = "\(baseName)-trim"
        } else {
            // Trimming original -> use -trim suffix
            outputName = "\(baseName)-trim"
        }

        return directory.appendingPathComponent("\(outputName).\(ext)")
    }

    /// Check if this is re-trimming (output file already exists)
    static func isRetrim(sourceURL: URL, existingFiles: [URL]) -> Bool {
        let outputPath = Self.outputPath(for: sourceURL, existingFiles: existingFiles)
        return existingFiles.contains(where: { $0.lastPathComponent == outputPath.lastPathComponent })
    }

    // MARK: - New Clip Path

    /// Generate output path for "Save as New Clip" mode.
    /// Uses timestamp to avoid collisions and prevent grouping with parent item.
    /// - `video.mp4` -> `video-trimmed-20260216-143052.mp4`
    static func newClipPath(for sourceURL: URL) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())

        return directory.appendingPathComponent("\(baseName)-trimmed-\(timestamp).\(ext)")
    }

    // MARK: - Export and Replace

    /// Export trimmed video and replace the original file in-place.
    /// 1. Export to a temp file in the same directory
    /// 2. Move original to .bak backup
    /// 3. Move temp to original path
    /// - Returns: Tuple of (replacedURL, backupURL) for undo support
    func exportAndReplace(
        source: URL,
        timeRange: CMTimeRange,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> (replacedURL: URL, backupURL: URL) {
        let fm = FileManager.default
        let directory = source.deletingLastPathComponent()
        let tempName = ".trim-temp-\(UUID().uuidString).mp4"
        let tempURL = directory.appendingPathComponent(tempName)
        let backupURL = source.appendingPathExtension("bak")

        // Step 1: Export to temp file
        let _ = try await exportTrimmed(
            source: source,
            timeRange: timeRange,
            outputURL: tempURL,
            progressHandler: progressHandler
        )

        // Step 2: Move original to backup
        do {
            // Remove existing backup if present (from a previous replace)
            if fm.fileExists(atPath: backupURL.path) {
                try fm.removeItem(at: backupURL)
            }
            try fm.moveItem(at: source, to: backupURL)
        } catch {
            // Clean up temp file on failure
            try? fm.removeItem(at: tempURL)
            throw TrimError.backupFailed(error.localizedDescription)
        }

        // Step 3: Move temp to original path
        do {
            try fm.moveItem(at: tempURL, to: source)
        } catch {
            // Try to restore original from backup
            try? fm.moveItem(at: backupURL, to: source)
            try? fm.removeItem(at: tempURL)
            throw TrimError.replaceFailed(error.localizedDescription)
        }

        return (replacedURL: source, backupURL: backupURL)
    }

    // MARK: - Export

    /// Export trimmed video to output path.
    /// Returns the output URL on success.
    func exportTrimmed(
        source: URL,
        timeRange: CMTimeRange,
        outputURL: URL,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: source)

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough  // No re-encoding
        ) else {
            throw TrimError.exportSessionCreationFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.timeRange = timeRange

        // Delete existing file if re-trimming
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Progress monitoring
        let progressTask = Task {
            while !Task.isCancelled && exportSession.status == .exporting {
                progressHandler?(Double(exportSession.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
            }
        }

        // Export
        await exportSession.export()
        progressTask.cancel()

        switch exportSession.status {
        case .completed:
            return outputURL
        case .cancelled:
            throw TrimError.cancelled
        case .failed:
            throw exportSession.error ?? TrimError.unknown
        default:
            throw TrimError.unknown
        }
    }
}
