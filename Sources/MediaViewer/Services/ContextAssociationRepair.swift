import Foundation
import GRDB

extension MediaStore {
    struct ContextAssociationRepairResult: Sendable {
        var retiredIDs: [UUID] = []
        var enrichedOwnerIDs: [UUID] = []
    }

    /// Retires generated screenshot items after the scan has attached their files to posts.
    /// Original rows/files stay recoverable; only transferred tags create a sidecar intent.
    func reconcileContextAssociations(_ groups: [URL: ArchiveItemFiles]) async throws -> ContextAssociationRepairResult {
        var ownersByContext: [String: Set<String>] = [:]
        var suppressedSidecars: [URL] = []
        for files in groups.values {
            guard let metadata = files.metadataFile else { continue }
            let owner = ArchiveAssociationResolver.canonicalPath(metadata)
            let contexts = files.mediaFiles.filter(ArchiveAssociationResolver.isContext) + [files.contextImage].compactMap { $0 }
            for context in contexts {
                ownersByContext[ArchiveAssociationResolver.canonicalPath(context), default: []].insert(owner)
            }
            suppressedSidecars.append(contentsOf: files.absorbedContextSidecars)
        }
        guard !ownersByContext.isEmpty else { return ContextAssociationRepairResult() }

        // Preserve tags on a rebuilt DB too, without making suppressed sidecars active items.
        var generatedRecords: [String: MediaItemRecord] = [:]
        for sidecar in suppressedSidecars {
            guard let source = ArchiveAssociationResolver.generatedContextSidecarSource(at: sidecar),
                  let metadata = try? MetadataParser.parse(fileAt: sidecar) else { continue }
            let item = MediaItem(id: UUID(), basePath: sidecar.deletingPathExtension(), metadataFile: sidecar,
                                 mediaFiles: [], contextImage: source, metadata: metadata, aspectRatio: 1)
            generatedRecords[ArchiveAssociationResolver.canonicalPath(sidecar)] = MediaItemRecord(from: item)
        }
        let contextOwners = ownersByContext
        let additions = generatedRecords
        let result = try await database.write { db -> ContextAssociationRepairResult in
            let paths = try Row.fetchAll(db, sql: "SELECT id, metadataFileString FROM media_items")
            var IDsByPath: [String: [UUID]] = [:]
            for row in paths {
                guard let id = UUID(uuidString: row["id"]), let path: String = row["metadataFileString"] else { continue }
                IDsByPath[ArchiveAssociationResolver.canonicalPath(URL(fileURLWithPath: path)), default: []].append(id)
            }
            let existing = try MediaItemRecord.fetchAll(db, sql: """
                SELECT * FROM media_items
                WHERE mediaFilesJSON = '[]'
                  AND (sourceURL LIKE 'file://%.context.png' OR sourceURL LIKE 'file://%_context.png')
                  AND (COALESCE(deletedAt, '') = '' OR deletionReason = 'missingFiles')
                  AND COALESCE(deletionReason, '') != 'contextReattached'
                """)
            let candidates = existing + additions.filter { IDsByPath[$0.key] == nil }.map(\.value)
            var result = ContextAssociationRepairResult()
            var enriched = Set<UUID>()
            for candidate in candidates {
                guard let source = URL(string: candidate.sourceURL), source.isFileURL,
                      ArchiveAssociationResolver.isContext(source),
                      !candidate.starred, (candidate.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let sourcePath = ArchiveAssociationResolver.canonicalPath(source)
                if let context = candidate.contextImageString,
                   ArchiveAssociationResolver.canonicalPath(URL(fileURLWithPath: context)) != sourcePath { continue }
                guard let owners = contextOwners[sourcePath], owners.count == 1, let ownerPath = owners.first,
                      let ownerIDs = IDsByPath[ownerPath], ownerIDs.count == 1, let ownerID = ownerIDs.first,
                      ownerID != candidate.id, var owner = try MediaItemRecord.fetchOne(db, key: ownerID.uuidString),
                      owner.deletedAt == nil else { continue }
                let ownerMedia = try JSONDecoder().decode([String].self, from: Data(owner.mediaFilesJSON.utf8))
                let attachedPaths = ownerMedia + [owner.contextImageString].compactMap { $0 }
                guard attachedPaths.contains(where: {
                    ArchiveAssociationResolver.canonicalPath(URL(fileURLWithPath: $0)) == sourcePath
                }) else { continue }
                let sidecar = URL(fileURLWithPath: candidate.metadataFileString)
                let sidecarPath = ArchiveAssociationResolver.canonicalPath(sidecar)
                var sidecarTags: [String] = []
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    guard ArchiveAssociationResolver.generatedContextSidecarSource(at: sidecar)?.path == sourcePath,
                          let metadata = try? MetadataParser.parse(fileAt: sidecar) else { continue }
                    sidecarTags = metadata.tags
                } else {
                    // Removing generated sidecars must not change which item owns the screenshot.
                    guard sidecarPath == ArchiveAssociationResolver.canonicalPath(source.deletingPathExtension().appendingPathExtension("md")) else { continue }
                }
                let annotations = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM annotations WHERE itemId = ?", arguments: [candidate.id.uuidString]) ?? 0
                let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metadata_outbox WHERE itemID = ? AND state != 'synced'", arguments: [candidate.id.uuidString]) ?? 0
                guard annotations == 0, pending == 0 else { continue }

                let originalTags = try JSONDecoder().decode([String].self, from: Data(owner.tagsJSON.utf8))
                let orphanTags = try JSONDecoder().decode([String].self, from: Data(candidate.tagsJSON.utf8))
                var tags = originalTags
                var seen = Set(tags.map(TagCanonicalizer.key))
                for rawTag in orphanTags + sidecarTags {
                    let tag = TagCanonicalizer.displayName(rawTag)
                    let key = TagCanonicalizer.key(tag)
                    if !key.isEmpty, seen.insert(key).inserted { tags.append(tag) }
                }
                if tags != originalTags {
                    owner.tagsJSON = String(decoding: try JSONEncoder().encode(tags), as: UTF8.self)
                    try owner.updateWithFTSSync(db: db)
                    enriched.insert(ownerID)
                }
                // Suppress deletion projection, rather than merely skipping queue.enqueue.
                try MetadataOutbox.importing(in: db) {
                    if IDsByPath[sidecarPath] == nil {
                        var record = candidate
                        record.deletedAt = Date()
                        record.deletionReason = MediaItemDeletionReason.contextReattached.rawValue
                        try record.insertWithFTSSync(db: db)
                        IDsByPath[sidecarPath] = [record.id]
                    } else {
                        try db.execute(sql: "UPDATE media_items SET deletedAt = ?, deletionReason = 'contextReattached' WHERE id = ?", arguments: [Date(), candidate.id.uuidString])
                    }
                }
                result.retiredIDs.append(candidate.id)
            }
            result.enrichedOwnerIDs = enriched.sorted { $0.uuidString < $1.uuidString }
            return result
        }
        if !result.retiredIDs.isEmpty {
            await didRepairContextAssociations(enrichedOwnerIDs: result.enrichedOwnerIDs)
        }
        return result
    }
}
