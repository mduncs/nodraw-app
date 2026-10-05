import Foundation
import AppKit
import Darwin

// MARK: - Export Format

/// Supported export formats for boards
enum BoardExportFormat {
    case folder          // Copy files + manifest.json
    case html            // Generate HTML gallery
}

// MARK: - Export Result

struct BoardExportResult {
    let outputURL: URL
    let itemCount: Int
    let errors: [String]
    var recoveryURL: URL? = nil

    var isSuccess: Bool {
        errors.isEmpty
    }
}

enum BoardExportCollisionPolicy { case failIfExists, replacePreservingPrevious }

// MARK: - BoardExporter

/// Exports collection boards to various formats.
/// - Folder export: Copies media files and creates a manifest.json
/// - HTML export: Generates a standalone HTML gallery
final class BoardExporter {
    private let beforePublication: (() throws -> Void)?
    init(beforePublication: (() throws -> Void)? = nil) { self.beforePublication = beforePublication }

    // MARK: - Folder Export

    /// Export board as a folder with copied files and manifest.json
    /// - Parameters:
    ///   - board: The board to export
    ///   - items: Media items in the board (in order)
    ///   - outputDirectory: Where to create the export folder
    ///   - includeMetadata: Whether to copy .md metadata files
    /// - Returns: Export result with output path and any errors
    func exportAsFolder(
        board: CollectionBoard,
        items: [MediaItem],
        to outputDirectory: URL,
        includeMetadata: Bool = true,
        collisionPolicy: BoardExportCollisionPolicy = .failIfExists
    ) throws -> BoardExportResult {
        let fileManager = FileManager.default
        var errors: [String] = []

        // Create board folder with sanitized name
        let folderName = sanitizeFilename(board.name)
        let attempt = try prepareExport(name: folderName, in: outputDirectory, policy: collisionPolicy)
        let boardFolder = attempt.stage

        // Create manifest
        var manifest = BoardManifest(
            id: board.id.uuidString,
            name: board.name,
            description: board.description,
            createdAt: ISO8601DateFormatter().string(from: board.createdAt),
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            items: []
        )

        // Copy files and build manifest
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            var manifestItem = ManifestItem(
                id: item.id.uuidString,
                position: index,
                source: item.metadata.source.absoluteString,
                platform: item.metadata.platform,
                author: item.metadata.author,
                originalDate: item.metadata.originalDate.map { ISO8601DateFormatter().string(from: $0) },
                archivedDate: ISO8601DateFormatter().string(from: item.metadata.archivedDate),
                starred: item.metadata.starred,
                tags: item.metadata.tags,
                notes: item.metadata.notes,
                mediaFiles: [],
                contextImage: nil
            )

            // Copy media files
            for mediaFile in item.mediaFiles {
                let destFilename = "\(index + 1)_\(mediaFile.lastPathComponent)"
                let destURL = boardFolder.appendingPathComponent(destFilename)

                do {
                    try copyExportFile(mediaFile, to: destURL)
                    manifestItem.mediaFiles.append(destFilename)
                } catch {
                    errors.append("Failed to copy \(mediaFile.lastPathComponent): \(error.localizedDescription)")
                }
            }

            // Copy context image if present
            if let contextImage = item.contextImage {
                let destFilename = "\(index + 1)_context_\(contextImage.lastPathComponent)"
                let destURL = boardFolder.appendingPathComponent(destFilename)

                do {
                    try copyExportFile(contextImage, to: destURL)
                    manifestItem.contextImage = destFilename
                } catch {
                    errors.append("Failed to copy context image: \(error.localizedDescription)")
                }
            }

            // Copy metadata file if requested
            if includeMetadata && fileManager.fileExists(atPath: item.metadataFile.path) {
                let destFilename = "\(index + 1)_\(item.metadataFile.lastPathComponent)"
                let destURL = boardFolder.appendingPathComponent(destFilename)

                do {
                    try copyExportFile(item.metadataFile, to: destURL)
                } catch {
                    errors.append("Failed to copy metadata: \(error.localizedDescription)")
                }
            }

            manifest.items.append(manifestItem)
        }

        // Write manifest.json
        let manifestURL = boardFolder.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: manifestURL)

        return try finishExport(attempt, itemCount: items.count, errors: errors)
    }

    // MARK: - HTML Export

    /// Export board as a standalone HTML gallery
    /// - Parameters:
    ///   - board: The board to export
    ///   - items: Media items in the board (in order)
    ///   - outputDirectory: Where to create the export folder
    ///   - embedImages: If true, embed images as base64; if false, copy files
    /// - Returns: Export result with output path and any errors
    func exportAsHTML(
        board: CollectionBoard,
        items: [MediaItem],
        to outputDirectory: URL,
        embedImages: Bool = false,
        collisionPolicy: BoardExportCollisionPolicy = .failIfExists
    ) throws -> BoardExportResult {
        let fileManager = FileManager.default
        var errors: [String] = []

        // Create board folder
        let folderName = sanitizeFilename(board.name) + "_gallery"
        let attempt = try prepareExport(name: folderName, in: outputDirectory, policy: collisionPolicy)
        let boardFolder = attempt.stage

        // Generate HTML
        var imageRefs: [(filename: String, item: MediaItem)] = []

        if !embedImages {
            // Copy images and track filenames
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                guard let primaryMedia = item.primaryMedia else { continue }

                let destFilename = "\(index + 1)_\(primaryMedia.lastPathComponent)"
                let destURL = boardFolder.appendingPathComponent(destFilename)

                do {
                    try copyExportFile(primaryMedia, to: destURL)
                    imageRefs.append((filename: destFilename, item: item))
                } catch {
                    errors.append("Failed to copy \(primaryMedia.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } else {
            // Just track items for embedding
            for item in items {
                guard let primaryMedia = item.primaryMedia else { continue }
                guard FileManager.default.isReadableFile(atPath: primaryMedia.path) else {
                    errors.append("Cannot read \(primaryMedia.lastPathComponent) for embedding")
                    continue
                }
                imageRefs.append((filename: primaryMedia.path, item: item))
            }
        }

        let html = try generateHTML(
            board: board,
            images: imageRefs,
            embedImages: embedImages
        )

        let htmlURL = boardFolder.appendingPathComponent("index.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        return try finishExport(attempt, itemCount: items.count, errors: errors)
    }

    // MARK: - Private Helpers

    private func sanitizeFilename(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let result = name.components(separatedBy: invalidChars).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return result.isEmpty ? "Untitled Board" : result
    }

    private struct ExportAttempt {
        let id: UUID
        let stage: URL
        let destination: URL
        let previousIdentity: String?
    }

    private func copyExportFile(_ source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        let source = source.resolvingSymlinksInPath()
        let values = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw ExportError("Export source is not a regular file: \(source.path)") }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func directoryIdentity(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ExportError("Export destination is not a regular directory: \(url.path)")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(attributes[.systemNumber] ?? "unknown"):\(attributes[.systemFileNumber] ?? "unknown")"
    }

    private func prepareExport(name: String, in parent: URL, policy: BoardExportCollisionPolicy) throws -> ExportAttempt {
        let parent = parent.resolvingSymlinksInPath()
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists && policy == .failIfExists {
            throw ExportError("An export already exists at \(destination.path). Choose another destination or explicitly replace it; the existing export was preserved.")
        }
        let previous = exists ? try directoryIdentity(destination) : nil
        let id = UUID()
        let stage = parent.appendingPathComponent(".nodraw-board-export-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let attempt = ExportAttempt(id: id, stage: stage, destination: destination, previousIdentity: previous)
        try writeAttempt(attempt, phase: "staging")
        return attempt
    }

    private func writeAttempt(_ attempt: ExportAttempt, phase: String) throws {
        let record = ["id": attempt.id.uuidString, "destination": attempt.destination.path, "stage": attempt.stage.path, "phase": phase]
        try DurableArchiveFile.write(JSONEncoder().encode(record), to: attempt.stage.appendingPathComponent(".nodraw-export-attempt.json"))
        try DurableArchiveFile.write(JSONEncoder().encode(record), to: attempt.stage.appendingPathExtension("json"))
        try DurableArchiveFile.sync(attempt.stage.deletingLastPathComponent())
    }

    private func finishExport(_ attempt: ExportAttempt, itemCount: Int, errors: [String]) throws -> BoardExportResult {
        guard errors.isEmpty else {
            try writeAttempt(attempt, phase: "failed")
            return BoardExportResult(outputURL: attempt.stage, itemCount: itemCount, errors: errors, recoveryURL: attempt.stage)
        }
        try Task.checkCancellation()
        try writeAttempt(attempt, phase: "ready")
        let files = try FileManager.default.contentsOfDirectory(at: attempt.stage, includingPropertiesForKeys: nil)
        for file in files { try DurableArchiveFile.sync(file) }
        try DurableArchiveFile.sync(attempt.stage)
        try beforePublication?()
        if let identity = attempt.previousIdentity {
            guard try directoryIdentity(attempt.destination) == identity else {
                throw ExportError("Export destination changed during staging. Both versions were preserved; reveal \(attempt.stage.path).")
            }
            // Atomic exchange leaves the complete previous export in our
            // identifiable stage directory. Never delete it during replacement.
            guard renamex_np(attempt.stage.path, attempt.destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw ExportError("Could not publish export; existing output and staged files at \(attempt.stage.path) were preserved: \(DurableArchiveFile.posixError().localizedDescription)")
            }
            try DurableArchiveFile.sync(attempt.destination.deletingLastPathComponent())
            return BoardExportResult(outputURL: attempt.destination, itemCount: itemCount, errors: [], recoveryURL: attempt.stage)
        }
        do { try DurableArchiveFile.publish(attempt.stage, to: attempt.destination) }
        catch {
            throw ExportError("Export could not be durably confirmed at \(attempt.destination.path). Review it and retained staging at \(attempt.stage.path); no existing output was removed. \(error.localizedDescription)")
        }
        return BoardExportResult(outputURL: attempt.destination, itemCount: itemCount, errors: [])
    }

    struct ExportError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// Inspect attempt-owned residue after a process interruption. Recovery is
    /// explicit: never guess which directory should replace a user's export.
    func recoverableExportDirectories(in parent: URL) throws -> [URL] {
        let parent = parent.resolvingSymlinksInPath()
        return try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".nodraw-board-export-") && $0.pathExtension == "json" }
            .compactMap { receipt in
                guard let data = try? Data(contentsOf: receipt),
                      let record = try? JSONDecoder().decode([String: String].self, from: data),
                      let id = record["id"].flatMap(UUID.init(uuidString:)),
                      let path = record["stage"] else { return nil }
                let expected = parent.appendingPathComponent(".nodraw-board-export-\(id.uuidString)")
                guard expected.path == path, FileManager.default.fileExists(atPath: path) else { return nil }
                return expected
            }
    }

    private func generateHTML(
        board: CollectionBoard,
        images: [(filename: String, item: MediaItem)],
        embedImages: Bool
    ) throws -> String {
        let escapedName = escapeHTML(board.name)
        let escapedDescription = board.description.map { escapeHTML($0) } ?? ""

        var imageCards = ""
        for (filename, item) in images {
            let src: String
            if embedImages {
                // Embed as base64
                let data = try Data(contentsOf: URL(fileURLWithPath: filename))
                guard let mimeType = mimeType(for: filename) else { throw ExportError("Unsupported embedded media: \(filename)") }
                src = "data:\(mimeType);base64,\(data.base64EncodedString())"
            } else {
                src = filename
            }

            let author = item.metadata.author.map { escapeHTML($0) } ?? ""
            let platform = escapeHTML(item.metadata.platform)
            let tags = item.metadata.tags.map { escapeHTML($0) }.joined(separator: ", ")

            imageCards += """
                <div class="card">
                    <img src="\(src)" alt="" loading="lazy" onclick="openLightbox(this.src)">
                    <div class="card-info">
                        <span class="platform">\(platform)</span>
                        \(author.isEmpty ? "" : "<span class=\"author\">\(author)</span>")
                        \(tags.isEmpty ? "" : "<div class=\"tags\">\(tags)</div>")
                    </div>
                </div>

            """
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(escapedName)</title>
            <style>
                :root {
                    --bg: #1a1a1a;
                    --card-bg: #2a2a2a;
                    --text: #e0e0e0;
                    --text-muted: #888;
                    --accent: #ff9500;
                }
                * { box-sizing: border-box; margin: 0; padding: 0; }
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    background: var(--bg);
                    color: var(--text);
                    line-height: 1.5;
                }
                header {
                    padding: 2rem;
                    text-align: center;
                    border-bottom: 1px solid #333;
                }
                header h1 { font-size: 2rem; margin-bottom: 0.5rem; }
                header p { color: var(--text-muted); }
                .gallery {
                    display: grid;
                    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
                    gap: 1rem;
                    padding: 1rem;
                }
                .card {
                    background: var(--card-bg);
                    border-radius: 8px;
                    overflow: hidden;
                }
                .card img {
                    width: 100%;
                    height: auto;
                    display: block;
                    cursor: pointer;
                    transition: opacity 0.2s;
                }
                .card img:hover { opacity: 0.9; }
                .card-info {
                    padding: 0.75rem;
                    font-size: 0.85rem;
                }
                .platform {
                    background: var(--accent);
                    color: #000;
                    padding: 0.15rem 0.5rem;
                    border-radius: 4px;
                    font-size: 0.75rem;
                    text-transform: uppercase;
                }
                .author {
                    color: var(--text-muted);
                    margin-left: 0.5rem;
                }
                .tags {
                    margin-top: 0.5rem;
                    color: var(--text-muted);
                    font-size: 0.8rem;
                }
                #lightbox {
                    display: none;
                    position: fixed;
                    top: 0; left: 0; right: 0; bottom: 0;
                    background: rgba(0,0,0,0.95);
                    z-index: 1000;
                    cursor: pointer;
                }
                #lightbox img {
                    max-width: 95%;
                    max-height: 95%;
                    position: absolute;
                    top: 50%; left: 50%;
                    transform: translate(-50%, -50%);
                }
                footer {
                    text-align: center;
                    padding: 2rem;
                    color: var(--text-muted);
                    font-size: 0.8rem;
                }
            </style>
        </head>
        <body>
            <header>
                <h1>\(escapedName)</h1>
                \(escapedDescription.isEmpty ? "" : "<p>\(escapedDescription)</p>")
                <p>\(images.count) items</p>
            </header>
            <div class="gallery">
        \(imageCards)
            </div>
            <div id="lightbox" onclick="closeLightbox()">
                <img src="" alt="">
            </div>
            <footer>
                Exported from NoDraw
            </footer>
            <script>
                function openLightbox(src) {
                    const lb = document.getElementById('lightbox');
                    lb.querySelector('img').src = src;
                    lb.style.display = 'block';
                }
                function closeLightbox() {
                    document.getElementById('lightbox').style.display = 'none';
                }
                document.addEventListener('keydown', e => {
                    if (e.key === 'Escape') closeLightbox();
                });
            </script>
        </body>
        </html>
        """
    }

    private func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func mimeType(for path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return nil
        }
    }
}

// MARK: - Manifest Types

/// JSON structure for board manifest
struct BoardManifest: Codable {
    let id: String
    let name: String
    let description: String?
    let createdAt: String
    let exportedAt: String
    var items: [ManifestItem]
}

struct ManifestItem: Codable {
    let id: String
    let position: Int
    let source: String
    let platform: String
    let author: String?
    let originalDate: String?
    let archivedDate: String
    let starred: Bool
    let tags: [String]
    let notes: String?
    var mediaFiles: [String]
    var contextImage: String?
}
