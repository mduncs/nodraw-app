import Foundation

/// Canonical, path-aware lookup for large tag vocabularies.
///
/// Settings, the tagging queue overflow and the hold-to-tag grid all need to find a
/// tag among hundreds of definitions. Matching uses `TagCanonicalizer` so case and
/// Unicode composition variants resolve to the same tag, and results carry their
/// ancestor path so identically named leaves in different branches stay distinct.
enum TagDefinitionSearch {
    struct Match: Equatable {
        let definition: TagDefinition
        /// Ancestor names from the root down to the immediate parent.
        let ancestors: [String]
        /// Lower is better, matching `TagCanonicalizer.matchScore`.
        let score: Int
        /// True when only the ancestor path matched, not the tag's own name.
        let matchedPathOnly: Bool

        /// "parent › child" style breadcrumb, empty for root tags.
        var ancestorLabel: String { ancestors.joined(separator: " › ") }
    }

    /// Path-only hits rank after every direct name hit.
    private static let pathPenalty = 1_000

    /// Rank definitions whose name, or whose ancestor path, matches `query`.
    ///
    /// Name matches use the full fuzzy matcher. Ancestor-path matches only use the
    /// exact/prefix/word/substring tiers so a short query does not light up the
    /// whole tree through loose subsequence hits. An empty query returns nothing.
    static func matches(
        query rawQuery: String,
        in definitions: [TagDefinition],
        excluding excludedIDs: Set<UUID> = [],
        limit: Int? = nil
    ) -> [Match] {
        let query = TagCanonicalizer.displayName(rawQuery)
        guard !TagCanonicalizer.key(query).isEmpty else { return [] }

        let byID = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var results: [Match] = []
        results.reserveCapacity(min(definitions.count, 64))

        for definition in definitions where !excludedIDs.contains(definition.id) {
            let ancestors = ancestorNames(of: definition, in: byID)
            if let score = TagCanonicalizer.matchScore(query: query, candidate: definition.name) {
                results.append(Match(definition: definition, ancestors: ancestors, score: score, matchedPathOnly: false))
            } else if !ancestors.isEmpty,
                      let score = TagCanonicalizer.matchScore(
                        query: query,
                        candidate: ancestors.joined(separator: " > ")
                      ),
                      score < 100 {
                results.append(Match(
                    definition: definition,
                    ancestors: ancestors,
                    score: pathPenalty + score,
                    matchedPathOnly: true
                ))
            }
        }

        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            if lhs.ancestors.count != rhs.ancestors.count { return lhs.ancestors.count < rhs.ancestors.count }
            let nameOrder = lhs.definition.name.localizedStandardCompare(rhs.definition.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.ancestorLabel.localizedStandardCompare(rhs.ancestorLabel) == .orderedAscending
        }
        if let limit, results.count > limit {
            return Array(results.prefix(limit))
        }
        return results
    }

    /// IDs a filtered tree should display: each matching tag plus every ancestor, so
    /// the hierarchy context around a hit is never hidden.
    static func treeVisibility(
        query: String,
        in definitions: [TagDefinition]
    ) -> (matchedIDs: Set<UUID>, visibleIDs: Set<UUID>) {
        let hits = matches(query: query, in: definitions)
        guard !hits.isEmpty else { return ([], []) }
        let byID = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let matched = Set(hits.map(\.definition.id))
        var visible = matched
        for id in matched {
            var cursor = byID[id]?.parentId
            var guardSet: Set<UUID> = [id]
            while let parentID = cursor, guardSet.insert(parentID).inserted {
                visible.insert(parentID)
                cursor = byID[parentID]?.parentId
            }
        }
        return (matched, visible)
    }

    /// The existing definition for a typed tag name, if one exists canonically.
    static func existingDefinition(named rawName: String, in definitions: [TagDefinition]) -> TagDefinition? {
        let key = TagCanonicalizer.key(rawName)
        guard !key.isEmpty else { return nil }
        return definitions.first { TagCanonicalizer.key($0.name) == key }
    }

    /// The spelling to store for a typed tag: an existing definition keeps its
    /// established display name, otherwise the trimmed input is used as typed.
    /// Returns nil for blank input.
    static func resolvedDisplayName(for rawName: String, in definitions: [TagDefinition]) -> String? {
        let display = TagCanonicalizer.displayName(rawName)
        guard !TagCanonicalizer.key(display).isEmpty else { return nil }
        return existingDefinition(named: display, in: definitions)?.name ?? display
    }

    /// Append `name` unless a canonically equal tag is already present.
    /// Returns true when the list changed.
    @discardableResult
    static func appendUnique(_ name: String, to tags: inout [String]) -> Bool {
        let key = TagCanonicalizer.key(name)
        guard !key.isEmpty, !tags.contains(where: { TagCanonicalizer.key($0) == key }) else { return false }
        tags.append(name)
        return true
    }

    /// Canonically de-duplicated list, keeping the first spelling of each tag.
    static func uniqued(_ tags: [String]) -> [String] {
        var result: [String] = []
        for tag in tags {
            appendUnique(TagCanonicalizer.displayName(tag), to: &result)
        }
        return result
    }

    private static func ancestorNames(of definition: TagDefinition, in byID: [UUID: TagDefinition]) -> [String] {
        var names: [String] = []
        var visited: Set<UUID> = [definition.id]
        var cursor = definition.parentId
        while let parentID = cursor, visited.insert(parentID).inserted, let parent = byID[parentID] {
            names.append(parent.name)
            cursor = parent.parentId
        }
        return names.reversed()
    }
}
