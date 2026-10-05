import Foundation
import GRDB

/// Sidebar badge totals from a handful of grouped queries instead of one
/// `countItems` per folder, platform and tag (cludge map workbench H2 / data H4).
struct SidebarCounts: Equatable, Sendable {
    /// Keyed by year-month folder name.
    var folders: [String: Int] = [:]
    /// Keyed by the stored platform value the sidebar selects (never the display label).
    var platforms: [String: Int] = [:]
    /// Keyed by `TagCanonicalizer.key` of the sidebar tag name.
    var tags: [String: Int] = [:]
    var total = 0
}

extension MediaStore {
    /// Each value equals `countItems(filter:)` for the matching single-field
    /// `FilterState` (`folderPath`, `platform`, or `tags = [name]`): the same default
    /// base conditions (active, has media, junk/safety hidden), the same folder LIKE,
    /// the same exact-then-alias platform match, and the same canonical tag keys with
    /// descendant expansion from `TagSettings`.
    func fetchSidebarCounts(folders: [String], platforms: [String], tags: [String]) async throws -> SidebarCounts {
        // One MainActor hop for the whole tag tree, not one per tag.
        let tagMembers: [(key: String, member: String)] = await MainActor.run {
            var pairs: [(String, String)] = []
            var seen = Set<String>()
            for tag in tags {
                let key = TagCanonicalizer.key(tag)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                let members = Set(TagSettings.shared.allDescendantNames(ofTagNamed: tag).map(TagCanonicalizer.key))
                    .union([key])
                pairs += members.sorted().map { (key, $0) }
            }
            return pairs
        }

        let folderJSON = try Self.jsonArray(folders.map { [$0, "%/\(MediaStore.escapeLikeValue($0))%"] })
        let tagJSON = try Self.jsonArray(tagMembers.map { [$0.key, $0.member] })

        return try await database.read { db in
            var counts = SidebarCounts()
            let base = self.buildFilterQueryParts(filter: FilterState(), tagExpansion: [:], searchMode: .disabled)
            let baseWhere = base.conditions.isEmpty ? "1" : base.conditions.joined(separator: " AND ")
            let baseArguments = base.arguments

            counts.total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM media_items WHERE \(baseWhere)",
                arguments: StatementArguments(baseArguments)
            ) ?? 0

            if !folders.isEmpty {
                let rows = try Row.fetchAll(db, sql: """
                    WITH folder(name, pattern) AS (
                        SELECT json_extract(value, '$[0]'), json_extract(value, '$[1]') FROM json_each(?)
                    )
                    SELECT folder.name AS name, COUNT(live.id) AS total
                    FROM folder
                    JOIN (SELECT id, basePathString FROM media_items WHERE \(baseWhere)) AS live
                      ON live.basePathString LIKE folder.pattern ESCAPE '\\'
                    GROUP BY folder.name
                    """, arguments: StatementArguments([folderJSON as DatabaseValueConvertible] + baseArguments))
                for row in rows {
                    let name: String = row["name"]
                    counts.folders[name] = row["total"] as Int
                }
            }

            if !platforms.isEmpty {
                // Group by the raw stored value, then apply the builder's own matching:
                // one canonical value compares exactly, aliases compare lowercased.
                let rows = try Row.fetchAll(db, sql: """
                    SELECT platform, COUNT(*) AS total FROM media_items
                    WHERE \(baseWhere) AND platform IS NOT NULL
                    GROUP BY platform
                    """, arguments: StatementArguments(baseArguments))
                let stored: [(value: String, total: Int)] = rows.map { row in (row["platform"] as String, row["total"] as Int) }
                for platform in platforms {
                    let values = MediaStore.platformFilterValues(for: platform)
                    if values.count == 1, let only = values.first {
                        counts.platforms[platform] = stored.first { $0.value == only }?.total ?? 0
                    } else {
                        let accepted = Set(values)
                        counts.platforms[platform] = stored
                            .filter { accepted.contains($0.value.lowercased()) }
                            .reduce(0) { $0 + $1.total }
                    }
                }
            }

            if !tagMembers.isEmpty {
                let rows = try Row.fetchAll(db, sql: """
                    WITH member(tag_key, tag) AS (
                        SELECT json_extract(value, '$[0]'), json_extract(value, '$[1]') FROM json_each(?)
                    )
                    SELECT member.tag_key AS tag_key, COUNT(DISTINCT media_tags.item_id) AS total
                    FROM member
                    JOIN media_tags ON media_tags.tag = member.tag
                    WHERE media_tags.item_id IN (SELECT id FROM media_items WHERE \(baseWhere))
                    GROUP BY member.tag_key
                    """, arguments: StatementArguments([tagJSON as DatabaseValueConvertible] + baseArguments))
                for row in rows {
                    let key: String = row["tag_key"]
                    counts.tags[key] = row["total"] as Int
                }
            }

            return counts
        }
    }

    private static func jsonArray(_ pairs: [[String]]) throws -> String {
        String(decoding: try JSONEncoder().encode(pairs), as: UTF8.self)
    }
}
