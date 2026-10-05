import Foundation
import GRDB

struct ImportSkippedItem: Sendable {
    let sourceURL: URL
    let existingItemID: UUID?
    let existingURL: URL
    let existingName: String
}

/// Window drops compare live media, including captures without import receipts.
/// Index paths and sizes once per batch; stream only same-size candidates, without decoding.
struct ImportLibraryDuplicatePrevention {
    let database: DatabaseManager

    static func isInArchive(_ url: URL, archivePath: URL) -> Bool {
        let root = ArchiveAssociationResolver.canonicalPath(archivePath)
        let path = ArchiveAssociationResolver.canonicalPath(url)
        return path == root || path.hasPrefix(root + "/")
    }

    struct IndexMetrics: Sendable {
        let itemCount: Int
        let fileCount: Int
        let pageCount: Int
        let durationSeconds: Double
    }

    struct Index: Sendable {
        fileprivate let bySize: [Int64: [Candidate]]
        fileprivate let byPath: [String: Item]
        let metrics: IndexMetrics
    }

    fileprivate struct Candidate: Sendable {
        let item: Item
        let url: URL
        let version: DuplicateFileVersion
    }

    fileprivate struct Item: Sendable {
        let id: String
        let metadataPath: String
        let mediaJSON: String
        let contextPath: String?

        var metadataURL: URL { Self.url(metadataPath) }
        var urls: [URL] {
            autoreleasepool {
                let paths = (try? JSONDecoder().decode([String].self, from: Data(mediaJSON.utf8))) ?? []
                return (paths + [contextPath].compactMap { $0 }).filter {
                    $0.hasPrefix("/") || URL(string: $0)?.isFileURL == true
                }.map(Self.url)
            }
        }
        static func url(_ path: String) -> URL {
            if let url = URL(string: path), url.isFileURL { return url }
            return URL(fileURLWithPath: path)
        }
        func notice(for source: URL) -> ImportSkippedItem {
            ImportSkippedItem(sourceURL: source, existingItemID: UUID(uuidString: id),
                existingURL: metadataURL, existingName: metadataURL.deletingPathExtension().lastPathComponent)
        }
    }

    func makeIndex(archivePath: URL,
                   fileVersionReader: @Sendable (URL) throws -> DuplicateFileVersion) async throws -> Index {
        let started = ProcessInfo.processInfo.systemUptime
        let archiveRoot = ArchiveAssociationResolver.canonicalPath(archivePath)
        var bySize: [Int64: [Candidate]] = [:]
        var byPath: [String: Item] = [:]
        var versions: [String: DuplicateFileVersion] = [:]
        var seenFiles = Set<String>()
        var itemCount = 0
        var pageCount = 0
        var cursor = ""
        while true {
            try Task.checkCancellation()
            let after = cursor
            let items = try await database.read { db in
                try autoreleasepool {
                    try Row.fetchAll(db, sql: """
                        SELECT id, metadataFileString, mediaFilesJSON, contextImageString FROM media_items
                        WHERE COALESCE(deletedAt, '') = '' AND id > ? ORDER BY id LIMIT 200
                        """, arguments: [after]).map { row in
                            Item(id: row["id"], metadataPath: row["metadataFileString"],
                                 mediaJSON: row["mediaFilesJSON"], contextPath: row["contextImageString"])
                        }
                }
            }
            guard let last = items.last else { break }
            cursor = last.id
            pageCount += 1
            itemCount += items.count
            try autoreleasepool {
                for item in items {
                    try Task.checkCancellation()
                    let files = item.urls
                    for url in files + [item.metadataURL] {
                        let path = ArchiveAssociationResolver.canonicalPath(url)
                        if byPath[path] == nil { byPath[path] = item }
                        // Folder drops get the same constant-time lookup as file drops.
                        var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                        while parent == archiveRoot || parent.hasPrefix(archiveRoot + "/") {
                            if byPath[parent] == nil { byPath[parent] = item }
                            if parent == archiveRoot { break }
                            parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
                        }
                    }
                    for url in files {
                        let path = ArchiveAssociationResolver.canonicalPath(url)
                        let canonicalURL = URL(fileURLWithPath: path)
                        if seenFiles.insert(path).inserted {
                            do { versions[path] = try fileVersionReader(canonicalURL) }
                            catch is CancellationError { throw CancellationError() }
                            catch { continue }
                        }
                        if let version = versions[path] {
                            bySize[version.size, default: []].append(Candidate(item: item, url: canonicalURL, version: version))
                        }
                    }
                }
            }
        }
        let metrics = IndexMetrics(itemCount: itemCount, fileCount: seenFiles.count, pageCount: pageCount,
            durationSeconds: ProcessInfo.processInfo.systemUptime - started)
        return Index(bySize: bySize, byPath: byPath, metrics: metrics)
    }

    func existingItem(for source: URL, compareBytes: Bool, index: Index) async throws -> ImportSkippedItem? {
        try Task.checkCancellation()
        let sourcePath = ArchiveAssociationResolver.canonicalPath(source)
        if !compareBytes {
            guard let item = index.byPath[sourcePath], try await stillLive(item) else { return nil }
            return item.notice(for: source)
        }
        let sourceVersion = try DuplicateFileVersion.read(source)
        guard let candidates = index.bySize[sourceVersion.size], !candidates.isEmpty else { return nil }
        let sourceDigest = try DuplicateEvidenceService.sha256(url: source)
        for candidate in candidates {
            try Task.checkCancellation()
            // The index is a snapshot; never trust a file that changed after it was built.
            guard (try? DuplicateFileVersion.read(candidate.url)) == candidate.version,
                  let digest = try await cachedDigest(candidate.url, version: candidate.version),
                  digest == sourceDigest,
                  (try? DuplicateFileVersion.read(candidate.url)) == candidate.version else { continue }
            guard try DuplicateFileVersion.read(source) == sourceVersion else { throw DuplicateEvidenceError.stale }
            if try await stillLive(candidate.item) { return candidate.item.notice(for: source) }
        }
        return nil
    }

    private func stillLive(_ item: Item) async throws -> Bool {
        try await database.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM media_items WHERE id = ? AND COALESCE(deletedAt, '') = ''
                    AND metadataFileString = ? AND mediaFilesJSON = ? AND contextImageString IS ?)
                """, arguments: [item.id, item.metadataPath, item.mediaJSON, item.contextPath]) ?? false
        }
    }

    private func cachedDigest(_ url: URL, version: DuplicateFileVersion) async throws -> String? {
        let path = url.path
        let encodedVersion = try DuplicateEvidencePersistence.json(version)
        let cached = try await database.read { db in
            try String.fetchOne(db, sql: """
                SELECT sha256 FROM duplicate_digest_cache WHERE path = ? AND algorithmVersion = ? AND versionJSON = ?
                """, arguments: [path, DuplicateEvidence.currentVersion, encodedVersion])
        }
        if let cached { return cached }
        let digest: String
        do { digest = try DuplicateEvidenceService.sha256(url: url) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
        guard (try? DuplicateFileVersion.read(url)) == version else { return nil }
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO duplicate_digest_cache(path, algorithmVersion, versionJSON, sha256)
                VALUES (?, ?, ?, ?) ON CONFLICT(path) DO UPDATE SET algorithmVersion = excluded.algorithmVersion,
                    versionJSON = excluded.versionJSON, sha256 = excluded.sha256, visualJSON = NULL
                """, arguments: [path, DuplicateEvidence.currentVersion, encodedVersion, digest])
        }
        return digest
    }
}
