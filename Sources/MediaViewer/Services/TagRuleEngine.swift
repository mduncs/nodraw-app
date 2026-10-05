import Foundation
import GRDB

@MainActor
class TagRuleEngine: ObservableObject {
    static let shared = TagRuleEngine(database: .shared)

    @Published var rules: [TagRule] = []
    private let database: DatabaseManager

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    // MARK: - CRUD

    func loadRules() async throws {
        let records: [TagRuleRecord] = try await database.read { db in
            try TagRuleRecord.fetchAll(
                db,
                sql: "SELECT * FROM tag_rules ORDER BY priority ASC, name ASC"
            )
        }
        rules = records.compactMap { $0.toTagRule() }
    }

    func addRule(_ rule: TagRule) async throws {
        let record = TagRuleRecord(from: rule)
        try await database.write { db in
            try record.insert(db)
        }
        rules.append(rule)
        rules.sort { $0.priority < $1.priority }
        logInfo("TagRuleEngine: added rule '\(rule.name)' -> tag '\(rule.tagName)'")
    }

    func updateRule(_ rule: TagRule) async throws {
        var updated = rule
        updated.updatedAt = Date()
        let record = TagRuleRecord(from: updated)
        try await database.write { db in
            try record.update(db)
        }
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = updated
        }
        rules.sort { $0.priority < $1.priority }
        logInfo("TagRuleEngine: updated rule '\(rule.name)'")
    }

    func deleteRule(_ rule: TagRule) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM tag_rules WHERE id = ?",
                arguments: [rule.id.uuidString]
            )
        }
        rules.removeAll { $0.id == rule.id }
        logInfo("TagRuleEngine: deleted rule '\(rule.name)'")
    }

    // MARK: - Rule Evaluation

    func evaluateRules(for metadata: MediaMetadata, attributes: [MediaAttribute] = []) -> [String] {
        let enabledRules = rules.filter(\.enabled).sorted { $0.priority < $1.priority }
        return evaluateRules(enabledRules, for: metadata, attributes: attributes)
    }

    private func evaluateRules(
        _ enabledRules: [TagRule],
        for metadata: MediaMetadata,
        attributes: [MediaAttribute]
    ) -> [String] {
        var tagNames: [String] = []
        var seen = Set<String>()

        for rule in enabledRules {
            let values = extractFieldValues(rule.sourceField, from: metadata, attributes: attributes)
            for value in values {
                if matches(value: value, pattern: rule.pattern, matchType: rule.matchType) {
                    let key = TagCanonicalizer.key(rule.tagName)
                    if !key.isEmpty, seen.insert(key).inserted {
                        tagNames.append(TagCanonicalizer.displayName(rule.tagName))
                    }
                }
            }
        }

        return tagNames
    }

    // MARK: - Batch Operations

    func applyRulesToAll(mediaStore: MediaStore) async throws -> (tagsApplied: Int, itemsAffected: Int) {
        let enabledRules = rules.filter(\.enabled)
        guard !enabledRules.isEmpty else { return (0, 0) }

        var affectedItemIds = Set<UUID>()
        // Collect tag -> [itemIds] for batch DB writes (Bug 3)
        var tagToItemIds: [String: [UUID]] = [:]
        var allNewTagNames = Set<String>()
        // Items needing source context backfill
        var backfillItems: [(id: UUID, metadata: MediaMetadata)] = []

        // Process in batches of 500
        let batchSize = 500
        var offset = 0

        while true {
            var filter = FilterState()
            filter.limit = batchSize
            filter.offset = offset

            let items = try await mediaStore.fetchItems(
                filter: filter,
                includeMLAttributes: false,
                includePerFileOCR: false,
                includeVideoSegments: false,
                includeTranscriptSegments: false
            )
            if items.isEmpty { break }

            // Bug 2: Extract file I/O off the main actor
            let parsedResults = await parseMetadataOffMainActor(items: items)
            let attributesByItem = enabledRules.contains(where: { $0.sourceField.isMLField })
                ? try await mediaStore.fetchAttributes(itemIds: items.map(\.id))
                : [:]

            for (index, item) in items.enumerated() {
                let (freshMetadata, needsBackfill) = parsedResults[index]

                // Collect backfill items for later
                if needsBackfill {
                    backfillItems.append((id: item.id, metadata: freshMetadata))
                }

                let newTags = evaluateRules(
                    enabledRules,
                    for: freshMetadata,
                    attributes: attributesByItem[item.id] ?? []
                )
                let existingTags = Set(item.metadata.tags.map(TagCanonicalizer.key))
                let toAdd = newTags.filter { !existingTags.contains(TagCanonicalizer.key($0)) }

                if !toAdd.isEmpty {
                    for tag in toAdd {
                        tagToItemIds[tag, default: []].append(item.id)
                        allNewTagNames.insert(tag)
                    }
                    affectedItemIds.insert(item.id)
                }
            }

            offset += batchSize
            if items.count < batchSize { break }
        }

        // Backfill source context columns in DB
        for item in backfillItems {
            try await mediaStore.updateSourceContext(id: item.id, metadata: item.metadata)
        }

        // Bug 3: Batch DB writes -- one addTagToItems call per tag name
        var totalTagsApplied = 0
        for (tag, itemIds) in tagToItemIds {
            try await mediaStore.addTagToItems(ids: itemIds, tag: tag)
            totalTagsApplied += itemIds.count
        }

        // Bug 5: Batch-ensure TagDefinitions exist ONCE after the loop
        for tagName in allNewTagNames {
            let _ = TagSettings.shared.definition(for: tagName)
        }

        logInfo("TagRuleEngine: applied rules to all - \(totalTagsApplied) tags on \(affectedItemIds.count) items")
        return (totalTagsApplied, affectedItemIds.count)
    }

    // Bug 2: File I/O off the main actor -- nonisolated helper
    private nonisolated func parseMetadataOffMainActor(items: [MediaItem]) async -> [(metadata: MediaMetadata, needsBackfill: Bool)] {
        var results: [(metadata: MediaMetadata, needsBackfill: Bool)] = []
        results.reserveCapacity(items.count)
        for item in items {
            let parsed = parseSingleItemMetadata(item)
            results.append(parsed)
        }
        return results
    }

    private nonisolated func parseSingleItemMetadata(_ item: MediaItem) -> (metadata: MediaMetadata, needsBackfill: Bool) {
        let mdURL = item.metadataFile
        guard FileManager.default.fileExists(atPath: mdURL.path) else {
            return (item.metadata, false)
        }
        let result = MetadataParser.parseGracefully(fileAt: mdURL)
        guard let parsed = result.metadata else {
            return (item.metadata, false)
        }
        let needsBackfill: Bool = checkNeedsBackfill(existing: item.metadata, parsed: parsed)
        return (parsed, needsBackfill)
    }

    private nonisolated func checkNeedsBackfill(existing: MediaMetadata, parsed: MediaMetadata) -> Bool {
        if existing.subreddit == nil && parsed.subreddit != nil { return true }
        if existing.boardName == nil && parsed.boardName != nil { return true }
        if existing.blogName == nil && parsed.blogName != nil { return true }
        if existing.channelName == nil && parsed.channelName != nil { return true }
        if existing.artistName == nil && parsed.artistName != nil { return true }
        if existing.galleryName == nil && parsed.galleryName != nil { return true }
        if existing.sourceTags == nil && parsed.sourceTags != nil { return true }
        if existing.likeCount == nil && parsed.likeCount != nil { return true }
        if existing.viewCount == nil && parsed.viewCount != nil { return true }
        return false
    }

    func previewRuleMatch(_ rule: TagRule, mediaStore: MediaStore) async throws -> Int {
        var matchCount = 0
        let batchSize = 500
        var offset = 0

        while true {
            var filter = FilterState()
            filter.limit = batchSize
            filter.offset = offset

            let items = try await mediaStore.fetchItems(
                filter: filter,
                includeMLAttributes: false,
                includePerFileOCR: false,
                includeVideoSegments: false,
                includeTranscriptSegments: false
            )
            if items.isEmpty { break }

            let attributesByItem = rule.sourceField.isMLField
                ? try await mediaStore.fetchAttributes(itemIds: items.map(\.id))
                : [:]

            for item in items {
                let attrs = attributesByItem[item.id] ?? []
                let values = extractFieldValues(rule.sourceField, from: item.metadata, attributes: attrs)
                for value in values {
                    if matches(value: value, pattern: rule.pattern, matchType: rule.matchType) {
                        matchCount += 1
                        break
                    }
                }
            }

            offset += batchSize
            if items.count < batchSize { break }
        }

        return matchCount
    }

    // MARK: - Tag Rename Cascade

    func renameTagInRules(oldName: String, newName: String) async throws {
        let oldKey = TagCanonicalizer.key(oldName)
        let newDisplayName = TagCanonicalizer.displayName(newName)
        guard !oldKey.isEmpty, !TagCanonicalizer.key(newDisplayName).isEmpty else { return }
        let affectedIDs = rules
            .filter { TagCanonicalizer.key($0.tagName) == oldKey }
            .map(\.id.uuidString)
        guard !affectedIDs.isEmpty else { return }

        try await database.write { db in
            let placeholders = affectedIDs.map { _ in "?" }.joined(separator: ", ")
            var arguments: [DatabaseValueConvertible] = [newDisplayName, Date()]
            arguments.append(contentsOf: affectedIDs)
            try db.execute(
                sql: "UPDATE tag_rules SET tag_name = ?, updated_at = ? WHERE id IN (\(placeholders))",
                arguments: StatementArguments(arguments)
            )
        }

        // Update in-memory rules
        for i in rules.indices {
            if TagCanonicalizer.key(rules[i].tagName) == oldKey {
                rules[i].tagName = newDisplayName
                rules[i].updatedAt = Date()
            }
        }

        logInfo("TagRuleEngine: renamed tag '\(oldName)' -> '\(newName)' in rules")
    }

    // MARK: - Private Helpers

    private func extractFieldValues(_ field: SourceField, from metadata: MediaMetadata, attributes: [MediaAttribute] = []) -> [String] {
        switch field {
        case .subreddit:
            return metadata.subreddit.map { [$0] } ?? []
        case .boardName:
            return metadata.boardName.map { [$0] } ?? []
        case .blogName:
            return metadata.blogName.map { [$0] } ?? []
        case .channelName:
            return metadata.channelName.map { [$0] } ?? []
        case .artistName:
            return metadata.artistName.map { [$0] } ?? []
        case .galleryName:
            return metadata.galleryName.map { [$0] } ?? []
        case .platform:
            return [metadata.platform]
        case .sourceTag:
            return metadata.sourceTags ?? []
        // ML pipeline fields — matched against media_attributes
        case .sceneLabel:
            return attributes
                .filter { $0.module == PipelineModule.scene.rawValue }
                .map { $0.key }
        case .detectedObject:
            return attributes
                .filter { $0.module == PipelineModule.object.rawValue }
                .map { $0.key }
        case .safetyFlag:
            if let flag = attributes.first(where: { $0.module == PipelineModule.safety.rawValue && $0.key == "is_safe" }) {
                return [flag.value > 0.5 ? "safe" : "unsafe"]
            }
            return []
        case .curationScore:
            if let s = attributes.first(where: { $0.module == PipelineModule.curation.rawValue && $0.key == "score" }) {
                return [String(format: "%.2f", s.value)]
            }
            return []
        case .junkFlag:
            if let flag = attributes.first(where: { $0.module == PipelineModule.junk.rawValue && $0.key == "is_junk" }) {
                return [flag.value > 0.5 ? "junk" : "not_junk"]
            }
            return []
        }
    }

    private func matches(value: String, pattern: String, matchType: MatchType) -> Bool {
        let valueLower = value.lowercased()
        let patternLower = pattern.lowercased()

        switch matchType {
        case .exact:
            return valueLower == patternLower
        case .contains:
            return valueLower.contains(patternLower)
        case .prefix:
            return valueLower.hasPrefix(patternLower)
        }
    }
}
