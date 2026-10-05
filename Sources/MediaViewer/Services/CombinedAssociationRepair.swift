import Foundation
import GRDB

extension MediaStore {
    /// Literal sidecars cannot take files back from a surviving combined post.
    /// Recover a combined row only when its discovered files have no active owner.
    func reconcileCombinedAssociations(_ input: [URL: ArchiveItemFiles]) async throws -> [URL: ArchiveItemFiles] {
        guard !input.isEmpty else { return input }
        let keys = Set(input.keys.map(ArchiveAssociationResolver.canonicalPath))
        let discoveredPaths = Set(input.values.flatMap { $0.mediaFiles + [$0.contextImage].compactMap { $0 } }
            .map(ArchiveAssociationResolver.canonicalPath))
        let hasCandidate = try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT metadataFileString, mediaFilesJSON, contextImageString
                FROM media_items WHERE deletionReason = 'combined'
                """)
            let decoder = JSONDecoder()
            for row in rows {
                let metadata: String = row["metadataFileString"]
                let key = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(URL(fileURLWithPath: metadata))).deletingPathExtension()
                if keys.contains(key.path) { return true }
                let json: String = row["mediaFilesJSON"]
                let media = try decoder.decode([String].self, from: Data(json.utf8))
                let context: String? = row["contextImageString"]
                if (media + [context].compactMap { $0 }).contains(where: {
                    discoveredPaths.contains(ArchiveAssociationResolver.canonicalPath(URL(fileURLWithPath: $0)))
                }) { return true }
            }
            return false
        }
        guard hasCandidate else { return input }
        // Re-read inside the transaction so ownership and deletion decisions
        // made after the read-only check still govern the repair.
        return try await reconcileCombinedAssociationsFullScan(input)
    }

    func reconcileCombinedAssociationsFullScan(_ input: [URL: ArchiveItemFiles]) async throws -> [URL: ArchiveItemFiles] {
        let result = try await database.write { db -> (groups: [URL: ArchiveItemFiles], restored: [UUID], updated: Set<UUID>) in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, metadataFileString, mediaFilesJSON, contextImageString, sourceURL, deletedAt, deletionReason
                FROM media_items
                """)
            let decoder = JSONDecoder()
            var activeKeys: [String: URL] = [:]
            var activeOwners: [String: Set<String>] = [:]
            var activePosts: [String: Set<String>] = [:]
            var protectedPaths = Set<String>()
            var combined: [(id: String, key: URL, paths: Set<String>, post: String?)] = []
            var groups = input
            let discovered = Set(input.values.flatMap { $0.mediaFiles + [$0.contextImage].compactMap { $0 } }
                .map(ArchiveAssociationResolver.canonicalPath))

            func postIdentity(_ source: String) -> String? {
                guard let url = URL(string: source), let author = MetadataParser.authorFromStatusURL(url) else { return nil }
                return author.lowercased() + "/" + url.path.split(separator: "/")[2]
            }

            for row in rows {
                let id: String = row["id"]
                let metadata: String = row["metadataFileString"]
                let key = URL(fileURLWithPath: ArchiveAssociationResolver.canonicalPath(URL(fileURLWithPath: metadata))).deletingPathExtension()
                let json: String = row["mediaFilesJSON"]
                let media = try decoder.decode([String].self, from: Data(json.utf8))
                let context: String? = row["contextImageString"]
                let paths = Set((media + [context].compactMap { $0 }).map {
                    ArchiveAssociationResolver.canonicalPath(URL(fileURLWithPath: $0))
                })
                let source: String = row["sourceURL"]
                let post = postIdentity(source)
                let reason: String? = row["deletionReason"]
                if reason == "combined" {
                    combined.append((id, key, paths, post))
                } else if (row["deletedAt"] as Date?) != nil {
                    if reason != "contextReattached" {
                        protectedPaths.formUnion(paths)
                    }
                } else {
                    activeKeys[id] = key
                    for path in paths { activeOwners[path, default: []].insert(id) }
                    if let post { activePosts[post, default: []].insert(id) }
                }
            }

            var scannedOwners: [String: Set<String>] = [:]
            for (id, key) in activeKeys {
                guard let files = groups[key] else { continue }
                for url in files.mediaFiles + [files.contextImage].compactMap({ $0 }) {
                    scannedOwners[ArchiveAssociationResolver.canonicalPath(url), default: []].insert(id)
                }
            }
            var restored: [UUID] = []
            var adoptedOwners = Set<String>()
            for candidate in combined.sorted(by: { $0.id < $1.id }) {
                let literal = groups[candidate.key]
                let literalPaths = (literal?.mediaFiles ?? []) + [literal?.contextImage].compactMap { $0 }
                let paths = candidate.paths.union(literalPaths.map(ArchiveAssociationResolver.canonicalPath)).intersection(discovered)
                guard !paths.isEmpty, paths.isDisjoint(with: protectedPaths) else { continue }
                var owners = Set(paths.flatMap { activeOwners[$0] ?? [] })
                var ownersByPath = Dictionary(uniqueKeysWithValues: paths.map { ($0, activeOwners[$0] ?? []) })
                // Generated context sidecars may already be absorbed by the resolver.
                for path in paths {
                    let scanned = scannedOwners[path] ?? []
                    owners.formUnion(scanned)
                    ownersByPath[path, default: []].formUnion(scanned)
                }
                if owners.isEmpty, let post = candidate.post,
                   let matching = activePosts[post], matching.count == 1,
                   let id = matching.first, let key = activeKeys[id],
                   key.deletingLastPathComponent() == candidate.key.deletingLastPathComponent(),
                   ArchiveAssociationResolver.galleryBase(candidate.key.lastPathComponent) == key.lastPathComponent {
                    owners.insert(id)
                }

                let availableOwners = owners.filter { id in
                    guard let key = activeKeys[id] else { return false }
                    return groups[key]?.metadataFile != nil
                }.sorted { activeKeys[$0]!.path < activeKeys[$1]!.path }
                if let preferred = availableOwners.first {
                    // Preserve deliberate shared files in every active owner. Only
                    // unowned leftovers need a surviving post to adopt them.
                    for path in paths.sorted() {
                        let carried = ownersByPath[path] ?? []
                        let targets = carried.isEmpty ? Set([preferred]) : carried
                        let targetKeys = Set(targets.compactMap { activeKeys[$0] })
                        for other in Array(groups.keys) where !targetKeys.contains(other) {
                            groups[other]?.mediaFiles.removeAll { ArchiveAssociationResolver.canonicalPath($0) == path }
                            if let context = groups[other]?.contextImage, ArchiveAssociationResolver.canonicalPath(context) == path {
                                groups[other]?.contextImage = nil
                            }
                        }
                        for owner in targets {
                            guard let key = activeKeys[owner], groups[key]?.metadataFile != nil else { continue }
                            let url = URL(fileURLWithPath: path)
                            if groups[key]?.contextImage != url, groups[key]?.mediaFiles.contains(url) != true {
                                if ArchiveAssociationResolver.isContext(url), groups[key]?.contextImage == nil { groups[key]?.contextImage = url }
                                else { groups[key]?.mediaFiles.append(url) }
                            }
                            adoptedOwners.insert(owner)
                            activeOwners[path, default: []].insert(owner)
                            scannedOwners[path, default: []].insert(owner)
                        }
                    }
                } else if owners.isEmpty, let id = UUID(uuidString: candidate.id),
                          groups[candidate.key]?.metadataFile != nil {
                    // This is scan restoration authority, separate from updateItem.
                    // The deletion intent keeps an old deleted:true sidecar from
                    // undoing the recovery before write-back acknowledges it.
                    try db.execute(sql: "UPDATE media_items SET deletedAt = NULL, deletionReason = NULL WHERE id = ? AND deletionReason = 'combined'", arguments: [candidate.id])
                    if db.changesCount > 0 {
                        restored.append(id)
                        activeKeys[candidate.id] = candidate.key
                        for path in paths { activeOwners[path, default: []].insert(candidate.id) }
                    }
                }
            }
            for key in groups.keys {
                groups[key]?.mediaFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }
            var updated = Set<UUID>()
            for owner in adoptedOwners {
                guard let key = activeKeys[owner], let files = groups[key],
                      let record = try MediaItemRecord.fetchOne(db, key: owner),
                      record.deletedAt == nil, var item = try record.toMediaItem() else { continue }
                // Union with existing paths: a directory event is a partial scan.
                for url in files.mediaFiles where !item.mediaFiles.contains(url) && item.contextImage != url {
                    item.mediaFiles.append(url)
                }
                if let context = files.contextImage, item.contextImage != context, !item.mediaFiles.contains(context) {
                    if item.contextImage == nil { item.contextImage = context }
                    else { item.mediaFiles.append(context) }
                }
                item.mediaFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                let repaired = MediaItemRecord(from: item)
                guard repaired.mediaFilesJSON != record.mediaFilesJSON || repaired.contextImageString != record.contextImageString else { continue }
                try MetadataOutbox.importing(in: db) { try repaired.updateWithFTSSync(db: db) }
                updated.insert(item.id)
            }
            return (groups, restored, updated)
        }
        await didRepairCombinedAssociations(restoredIDs: result.restored, updatedIDs: result.updated)
        return result.groups
    }
}
