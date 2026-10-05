import SwiftUI

// MARK: - TagDefinition

/// A user-defined tag with name and color.
/// Stored in UserDefaults, referenced by items via tag name.
struct TagDefinition: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var colorHex: UInt
    /// Pre-hierarchy grouping. Nothing reads or edits it any more; it is decoded and
    /// re-encoded only so older stored definitions round-trip without losing the value.
    var group: String?
    var parentId: UUID?    // nil = root-level tag
    var sortOrder: Int     // ordering within siblings (0-based)
    /// Optional user override for the tagging HUD. Bindings are unique among siblings.
    var shortcutKey: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, colorHex, group, parentId, sortOrder, shortcutKey
    }

    init(id: UUID = UUID(), name: String, colorHex: UInt) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.group = nil
        self.parentId = nil
        self.sortOrder = 0
        self.shortcutKey = nil
    }

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.colorHex = Self.autoColor(for: name)
        self.group = nil
        self.parentId = nil
        self.sortOrder = 0
        self.shortcutKey = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colorHex = try container.decode(UInt.self, forKey: .colorHex)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        parentId = try container.decodeIfPresent(UUID.self, forKey: .parentId)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        shortcutKey = try container.decodeIfPresent(String.self, forKey: .shortcutKey)
    }

    var color: Color {
        Color(hex: colorHex)
    }

    static let colorPalette: [UInt] = [
        0xE57373, 0xF06292, 0xBA68C8, 0x9575CD,
        0x7986CB, 0x64B5F6, 0x4FC3F7, 0x4DD0E1,
        0x4DB6AC, 0x81C784, 0xAED581, 0xDCE775,
        0xFFD54F, 0xFFB74D, 0xFF8A65, 0xA1887F,
    ]

    /// Generate a deterministic color based on tag name hash
    static func autoColor(for name: String) -> UInt {
        let colors = colorPalette
        // djb2 hash -- deterministic across launches (String.hashValue is randomized per process)
        var hash: UInt64 = 5381
        for byte in TagCanonicalizer.key(name).utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return colors[Int(hash % UInt64(colors.count))]
    }
}

/// Layout of the hold-to-tag selector. Every layout shares type-to-filter, recents
/// and the size presets.
enum TagOverlayLayout: String, CaseIterable, Identifiable {
    case sunburst
    case grid
    case radial

    static let defaultLayout: TagOverlayLayout = .sunburst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sunburst: return "Sunburst"
        case .grid: return "Grid"
        case .radial: return "Radial"
        }
    }

    var summary: String {
        switch self {
        case .sunburst: return "Two rings of the hierarchy. Double-click a segment or click the outer rim to drill in."
        case .grid: return "One collapsible section per top-level tag; scrolls instead of growing."
        case .radial: return "One ring per level with larger labels. Best for small or flat tag sets."
        }
    }

    /// Resolve the stored preference. Older builds stored two exclusive bools
    /// ("always grid" / "always radial"); neither meant automatic, which now maps to
    /// the sunburst default.
    static func migrated(storedValue: String?, legacyAlwaysGrid: Bool, legacyAlwaysRadial: Bool) -> TagOverlayLayout {
        if let storedValue, let layout = TagOverlayLayout(rawValue: storedValue) {
            return layout
        }
        if legacyAlwaysGrid { return .grid }
        if legacyAlwaysRadial { return .radial }
        return defaultLayout
    }
}

enum TagGridSizePreset: CaseIterable {
    case small
    case medium
    case large
    case wide

    var label: String {
        switch self {
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        case .wide: return "W"
        }
    }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .wide: return "Wide"
        }
    }

    var help: String {
        "\(title) tag selector"
    }

    var scale: Double {
        switch self {
        case .small: return 0.85
        case .medium: return 1.0
        case .large: return 1.2
        case .wide: return 1.45
        }
    }

    func isSelected(scale currentScale: Double) -> Bool {
        abs(currentScale - scale) < 0.025
    }
}

enum TagNameValidation: Equatable {
    case valid(String)
    case empty
    case duplicate(existingName: String)
}

enum TagShortcutAssignmentError: Error, Equatable {
    case tagUnavailable
    case invalidKey(String)
    case duplicateKey(key: Character, existingTagName: String)

    var message: String {
        switch self {
        case .tagUnavailable:
            return "That tag no longer exists."
        case .invalidKey(let key):
            return "\(key.isEmpty ? "That key" : "‘\(key)’") is not available for tagging."
        case .duplicateKey(let key, let existingTagName):
            return "‘\(key)’ is already assigned to \(existingTagName) at this level."
        }
    }
}

// MARK: - TagSettings

/// Manages user-defined tags and tagging preferences.
/// Persists to UserDefaults.
@MainActor
final class TagSettings: ObservableObject {
    static let shared = TagSettings()

    private let definitionsKey = "tagDefinitions"
    private let tagSortOrderMigratedKey = "tagSortOrderMigrated"
    private let modifierKeyKey = "tagModifierKey"
    static let layoutKey = "tagOverlayLayout"
    /// Superseded by `layoutKey`: read once for migration, then removed.
    static let legacyLayoutKeys = ["tagAlwaysUseGrid", "tagAlwaysUseRadio", "tagGridThreshold"]
    private let gridScaleKey = "tagGridScale"
    private let recentTagIdsKey = "recentTagIds"
    /// Legacy preference migration may write its source domain. QA must not even
    /// open these suites, regardless of its own bundle identifier or defaults.
    static func legacyDefinitionDomains(backgroundQA: Bool = BackgroundQAConfiguration.isEnabled) -> [String] {
        guard !backgroundQA else { return [] }
        return ["MediaViewer", "com.mediaviewer.app", "com.md.mediaviewer"]
    }

    /// Issue 10: Cached computed colors to avoid repeated lookups
    private var colorCache: [String: Color] = [:]

    /// Debounce timer for save coalescing
    private var saveWorkItem: DispatchWorkItem?

    /// Maps definition IDs removed by canonical migration to their retained ID so
    /// persisted recents and hierarchy references survive the merge.
    private var canonicalDefinitionIDRemap: [UUID: UUID] = [:]

    /// All user-defined tags
    @Published var definitions: [TagDefinition] = [] {
        didSet {
            scheduleSave()
            // Invalidate caches when definitions change
            colorCache.removeAll()
            invalidateCache()
        }
    }

    /// Modifier key for tag overlay (default: option/alt)
    @Published var modifierKey: ModifierKey = .option {
        didSet { UserDefaults.standard.set(modifierKey.rawValue, forKey: modifierKeyKey) }
    }

    /// Hold-to-tag selector layout.
    @Published var layout: TagOverlayLayout = .defaultLayout {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: Self.layoutKey) }
    }

    /// Size scale for the hold-to-tag selector, shared by every layout.
    @Published var gridScale: Double = 1.0 {
        didSet {
            let clamped = min(max(gridScale, 0.75), 1.45)
            if gridScale != clamped {
                gridScale = clamped
                return
            }
            UserDefaults.standard.set(gridScale, forKey: gridScaleKey)
        }
    }

    /// Recently used tag IDs - persisted to UserDefaults
    @Published var recentTagIds: [UUID] = [] {
        didSet {
            let data = try? JSONEncoder().encode(recentTagIds)
            UserDefaults.standard.set(data, forKey: recentTagIdsKey)
        }
    }

    /// Available modifier keys
    enum ModifierKey: String, CaseIterable {
        case option = "option"
        case control = "control"
        case command = "command"
        case optionShift = "optionShift"

        var eventFlag: NSEvent.ModifierFlags {
            switch self {
            case .option: return .option
            case .control: return .control
            case .command: return .command
            case .optionShift: return [.option, .shift]
            }
        }

        var displayName: String {
            switch self {
            case .option: return "Option (⌥)"
            case .control: return "Control (⌃)"
            case .command: return "Command (⌘)"
            case .optionShift: return "Option+Shift (⌥⇧)"
            }
        }
    }

    private init() {
        loadDefinitions()
        loadPreferences()
    }

    // MARK: - Persistence

    private func loadDefinitions() {
        if let decoded = decodedDefinitions(from: .standard) {
            definitions = normalizedDefinitions(decoded, defaults: .standard)
            return
        }

        for domain in Self.legacyDefinitionDomains() {
            guard let defaults = UserDefaults(suiteName: domain),
                  let decoded = decodedDefinitions(from: defaults),
                  !decoded.isEmpty else {
                continue
            }

            definitions = normalizedDefinitions(decoded, defaults: defaults)
            UserDefaults.standard.set(true, forKey: tagSortOrderMigratedKey)
            saveDefinitions()
            logInfo("TagSettings: imported \(definitions.count) tag definitions from legacy domain \(domain)")
            return
        }
    }

    private func decodedDefinitions(from defaults: UserDefaults) -> [TagDefinition]? {
        guard let data = defaults.data(forKey: definitionsKey),
              let decoded = try? JSONDecoder().decode([TagDefinition].self, from: data) else {
            return nil
        }
        return decoded
    }

    private func normalizedDefinitions(_ decoded: [TagDefinition], defaults: UserDefaults) -> [TagDefinition] {
        var migrated = decoded
        if !defaults.bool(forKey: tagSortOrderMigratedKey) {
            for (index, _) in migrated.enumerated() where migrated[index].sortOrder == 0 && index > 0 {
                migrated[index].sortOrder = index
            }
            defaults.set(true, forKey: tagSortOrderMigratedKey)
        }

        let canonicalized = Self.canonicalizedDefinitions(migrated)
        canonicalDefinitionIDRemap = canonicalized.idRemap
        if canonicalized.definitions.count != migrated.count {
            logInfo(
                "TagSettings: merged \(migrated.count - canonicalized.definitions.count) "
                    + "canonical-equivalent legacy definitions"
            )
        }
        return canonicalized.definitions
    }

    /// Canonicalize a persisted definition set while keeping the first stored UUID,
    /// remapping children of folded duplicates, removing blank entries, breaking
    /// invalid/cyclic parents, and compacting sibling order. Kept internal for a
    /// focused migration test; normal callers mutate through TagSettings APIs.
    static func canonicalizedDefinitions(
        _ decoded: [TagDefinition]
    ) -> (definitions: [TagDefinition], idRemap: [UUID: UUID]) {
        var survivorIDByKey: [String: UUID] = [:]
        var idRemap: [UUID: UUID] = [:]
        var result: [TagDefinition] = []

        for rawDefinition in decoded {
            var definition = rawDefinition
            definition.name = TagCanonicalizer.displayName(definition.name)
            let key = TagCanonicalizer.key(definition.name)
            guard !key.isEmpty else { continue }

            if let survivorID = survivorIDByKey[key] {
                idRemap[definition.id] = survivorID
                continue
            }

            survivorIDByKey[key] = definition.id
            idRemap[definition.id] = definition.id
            result.append(definition)
        }

        let retainedIDs = Set(result.map(\.id))
        for index in result.indices {
            guard let oldParentID = result[index].parentId else { continue }
            let parentID = idRemap[oldParentID] ?? oldParentID
            result[index].parentId = retainedIDs.contains(parentID) && parentID != result[index].id
                ? parentID
                : nil
        }

        // Historical settings could contain a longer parent cycle. Promote the
        // affected definition to root rather than letting traversal loop forever.
        for index in result.indices {
            var visited: Set<UUID> = [result[index].id]
            var nextParentID = result[index].parentId
            var foundCycle = false
            while let parentID = nextParentID {
                guard visited.insert(parentID).inserted else {
                    foundCycle = true
                    break
                }
                nextParentID = result.first(where: { $0.id == parentID })?.parentId
            }
            if foundCycle {
                result[index].parentId = nil
            }
        }

        // Retain only valid, unique sibling-level shortcut overrides. Older or manually
        // edited defaults must never shadow another visible action in the tagging HUD.
        var claimedShortcuts: [UUID?: Set<Character>] = [:]
        for index in result.indices.sorted(by: {
            if result[$0].parentId != result[$1].parentId {
                return String(describing: result[$0].parentId) < String(describing: result[$1].parentId)
            }
            return result[$0].sortOrder < result[$1].sortOrder
        }) {
            guard let shortcut = Self.normalizedShortcut(result[index].shortcutKey) else {
                result[index].shortcutKey = nil
                continue
            }
            let parentID = result[index].parentId
            guard claimedShortcuts[parentID, default: []].insert(shortcut).inserted else {
                result[index].shortcutKey = nil
                continue
            }
            result[index].shortcutKey = String(shortcut)
        }

        let parentIDs = Set(result.map(\.parentId))
        for parentID in parentIDs {
            let orderedIndices = result.indices
                .filter { result[$0].parentId == parentID }
                .sorted { lhs, rhs in
                    if result[lhs].sortOrder != result[rhs].sortOrder {
                        return result[lhs].sortOrder < result[rhs].sortOrder
                    }
                    return lhs < rhs
                }
            for (sortOrder, index) in orderedIndices.enumerated() {
                result[index].sortOrder = sortOrder
            }
        }

        return (result, idRemap)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveDefinitions()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func saveDefinitions() {
        guard let data = try? JSONEncoder().encode(definitions) else { return }
        UserDefaults.standard.set(data, forKey: definitionsKey)
    }

    private func loadPreferences() {
        if let rawValue = UserDefaults.standard.string(forKey: modifierKeyKey),
           let key = ModifierKey(rawValue: rawValue) {
            modifierKey = key
        }
        layout = Self.loadLayout(from: .standard)
        let storedGridScale = UserDefaults.standard.double(forKey: gridScaleKey)
        gridScale = storedGridScale > 0 ? storedGridScale : 1.0

        if let data = UserDefaults.standard.data(forKey: recentTagIdsKey),
           let ids = try? JSONDecoder().decode([UUID].self, from: data) {
            let validIDs = Set(definitions.map(\.id))
            var seen = Set<UUID>()
            recentTagIds = ids.compactMap { storedID in
                let retainedID = canonicalDefinitionIDRemap[storedID] ?? storedID
                guard validIDs.contains(retainedID), seen.insert(retainedID).inserted else {
                    return nil
                }
                return retainedID
            }
        }
    }

    /// Read the layout preference, migrating the legacy bool pair on first read. The
    /// resolved value is written back and the legacy keys are removed.
    static func loadLayout(from defaults: UserDefaults) -> TagOverlayLayout {
        let layout = TagOverlayLayout.migrated(
            storedValue: defaults.string(forKey: layoutKey),
            legacyAlwaysGrid: defaults.bool(forKey: "tagAlwaysUseGrid"),
            legacyAlwaysRadial: defaults.bool(forKey: "tagAlwaysUseRadio")
        )
        defaults.set(layout.rawValue, forKey: layoutKey)
        for key in legacyLayoutKeys {
            defaults.removeObject(forKey: key)
        }
        return layout
    }

    // MARK: - Tree Structure

    /// Cache for tree computations (invalidated when definitions change)
    private var _childrenCache: [UUID?: [TagDefinition]]?

    private func buildChildrenCache() -> [UUID?: [TagDefinition]] {
        var cache: [UUID?: [TagDefinition]] = [:]
        for def in definitions {
            cache[def.parentId, default: []].append(def)
        }
        for key in cache.keys {
            cache[key]?.sort { $0.sortOrder < $1.sortOrder }
        }
        return cache
    }

    private var childrenCache: [UUID?: [TagDefinition]] {
        if let cache = _childrenCache { return cache }
        let cache = buildChildrenCache()
        _childrenCache = cache
        return cache
    }

    private func invalidateCache() {
        _childrenCache = nil
    }

    /// Root-level tags (parentId == nil), sorted by sortOrder
    func rootTags() -> [TagDefinition] {
        childrenCache[nil] ?? []
    }

    /// Direct children of a tag
    func children(of parentId: UUID) -> [TagDefinition] {
        childrenCache[parentId] ?? []
    }

    /// Walk up the tree from a tag to root, returns [immediate parent, ..., root]
    func ancestors(of tagId: UUID) -> [TagDefinition] {
        var result: [TagDefinition] = []
        var currentId: UUID? = tagId
        var visited = Set<UUID>()
        while let id = currentId,
              let def = definitions.first(where: { $0.id == id }) {
            if !visited.insert(id).inserted { break }
            if id != tagId { result.append(def) }
            currentId = def.parentId
        }
        return result
    }

    /// All descendant tag NAMES (for query expansion in filtering)
    func allDescendantNames(of tagId: UUID) -> Set<String> {
        var names = Set<String>()
        var visited = Set<UUID>()
        var queue = children(of: tagId)
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard visited.insert(current.id).inserted else { continue }
            names.insert(current.name)
            queue.append(contentsOf: children(of: current.id))
        }
        return names
    }

    /// Same as above but lookup by tag name instead of UUID
    func allDescendantNames(ofTagNamed name: String) -> Set<String> {
        let key = TagCanonicalizer.key(name)
        guard let def = definitions.first(where: { TagCanonicalizer.key($0.name) == key }) else { return [] }
        return allDescendantNames(of: def.id)
    }

    /// Whether a tag is a leaf (has no children)
    func isLeaf(_ tagId: UUID) -> Bool {
        children(of: tagId).isEmpty
    }

    /// Depth of a tag in the tree (root = 0)
    func depth(of tagId: UUID) -> Int {
        ancestors(of: tagId).count
    }

    /// Full display path: "aesthetics › 1980s › hair metal" (same separator as search results)
    func fullPath(of tagId: UUID) -> String {
        guard let def = definitions.first(where: { $0.id == tagId }) else { return "" }
        let path = ancestors(of: tagId).reversed() + [def]
        return path.map(\.name).joined(separator: " › ")
    }

    /// Full display path by tag name (returns nil if tag has no parent -- no tooltip needed)
    func fullPath(ofTagNamed name: String) -> String? {
        let key = TagCanonicalizer.key(name)
        guard let def = definitions.first(where: { TagCanonicalizer.key($0.name) == key }) else { return nil }
        guard def.parentId != nil else { return nil }
        return fullPath(of: def.id)
    }

    /// All descendant TagDefinitions (BFS with cycle protection)
    func allDescendants(of tagId: UUID) -> [TagDefinition] {
        var result: [TagDefinition] = []
        var visited = Set<UUID>()
        var queue = children(of: tagId)
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard visited.insert(current.id).inserted else { continue }
            result.append(current)
            queue.append(contentsOf: children(of: current.id))
        }
        return result
    }

    /// All descendant tag IDs (for cycle detection in reparent)
    func allDescendantIDs(of tagId: UUID) -> Set<UUID> {
        var ids = Set<UUID>()
        var visited = Set<UUID>()
        var queue = children(of: tagId)
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard visited.insert(current.id).inserted else { continue }
            ids.insert(current.id)
            queue.append(contentsOf: children(of: current.id))
        }
        return ids
    }

    /// Current index of a tag among its siblings (0-based), or nil if not found.
    /// Used to capture position for undo before a move.
    func siblingIndex(of tagId: UUID) -> Int? {
        guard let tag = definitions.first(where: { $0.id == tagId }) else { return nil }
        let siblings = tag.parentId == nil ? rootTags() : children(of: tag.parentId!)
        return siblings.firstIndex(where: { $0.id == tagId })
    }

    /// THE canonical move. Move `tagId` to become a child of `newParentId` (nil = root)
    /// at position `index` among the *destination* siblings (the sibling list with the
    /// moved tag excluded -- "insert at this slot" semantics). Reparents if the parent
    /// changes, reorders otherwise.
    ///
    /// - Rejects cycles, self-drops, and descendant-drops (returns false, no mutation).
    /// - Renumbers the destination sibling list 0…n contiguously and compacts the source
    ///   sibling list it left behind, so `sortOrder` never goes sparse or duplicated.
    /// - Performs exactly one `definitions =` assignment so `didSet` (save + cache
    ///   invalidation) fires once.
    /// - Returns false on illegal moves and on genuine no-ops (same parent + same slot).
    ///
    /// All other movers (`reparent`, `moveSortOrder`, the editor buttons, drag-and-drop)
    /// route through here so sort order is computed in exactly one place.
    @discardableResult
    func move(tagId: UUID, toParent newParentId: UUID?, atIndex index: Int) -> Bool {
        // Cycle / self guard (by ID -- names aren't unique).
        if let newPid = newParentId {
            if newPid == tagId { return false }
            if allDescendantIDs(of: tagId).contains(newPid) { return false }
        }
        guard let movedTag = definitions.first(where: { $0.id == tagId }) else { return false }
        let oldParentId = movedTag.parentId

        // Destination siblings (pre-mutation cache), excluding the moved tag, in order.
        let destSiblings = (newParentId == nil ? rootTags() : children(of: newParentId!))
            .filter { $0.id != tagId }
        if let movedShortcut = Self.normalizedShortcut(movedTag.shortcutKey),
           destSiblings.contains(where: { Self.normalizedShortcut($0.shortcutKey) == movedShortcut }) {
            return false
        }
        let clamped = max(0, min(index, destSiblings.count))

        // No-op: same parent and the tag already occupies that slot.
        if oldParentId == newParentId {
            let currentSiblings = newParentId == nil ? rootTags() : children(of: newParentId!)
            if let originalIndex = currentSiblings.firstIndex(where: { $0.id == tagId }),
               originalIndex == clamped {
                return false
            }
        }

        // Mutable working copy keyed by id.
        var byId = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })

        // Apply the parent change.
        byId[tagId]?.parentId = newParentId

        // Insert into the destination order and renumber contiguously.
        var orderedDest = destSiblings
        orderedDest.insert(movedTag, at: clamped)
        for (i, sib) in orderedDest.enumerated() {
            byId[sib.id]?.sortOrder = i
        }

        // Compact the source siblings the tag left behind (only if parent changed).
        if oldParentId != newParentId {
            let sourceSiblings = (oldParentId == nil ? rootTags() : children(of: oldParentId!))
                .filter { $0.id != tagId }
            for (i, sib) in sourceSiblings.enumerated() {
                byId[sib.id]?.sortOrder = i
            }
        }

        // Single assignment -> one didSet (save + cache invalidation).
        definitions = definitions.map { byId[$0.id] ?? $0 }
        return true
    }

    /// Move a tag to a new parent (nil = root), appended to the end of the new parent's
    /// children. Returns false if it would create a cycle or is a no-op.
    @discardableResult
    func reparent(tagId: UUID, newParentId: UUID?) -> Bool {
        let endIndex = (newParentId == nil ? rootTags() : children(of: newParentId!))
            .filter { $0.id != tagId }.count
        return move(tagId: tagId, toParent: newParentId, atIndex: endIndex)
    }

    /// Move a tag up or down among its siblings. direction: -1 = up, +1 = down.
    func moveSortOrder(tagId: UUID, direction: Int) {
        guard let tag = definitions.first(where: { $0.id == tagId }) else { return }
        let siblings = tag.parentId == nil ? rootTags() : children(of: tag.parentId!)
        guard let currentIndex = siblings.firstIndex(where: { $0.id == tagId }) else { return }
        let targetIndex = currentIndex + direction
        guard targetIndex >= 0 && targetIndex < siblings.count else { return }
        _ = move(tagId: tagId, toParent: tag.parentId, atIndex: targetIndex)
    }

    /// Number of direct children for a tag
    func childCount(of parentId: UUID) -> Int {
        children(of: parentId).count
    }

    /// Add a child tag under a parent. Returns false if the name is empty or already exists.
    @discardableResult
    func addChildTag(name: String, parentId: UUID?) -> Bool {
        guard case .valid(let displayName) = validateName(name) else { return false }
        let siblingCount = parentId == nil ? rootTags().count : children(of: parentId!).count
        var tag = TagDefinition(name: displayName)
        tag.parentId = parentId
        tag.sortOrder = siblingCount
        // didSet on definitions handles saveDefinitions() + invalidateCache()
        definitions.append(tag)
        return true
    }

    // MARK: - Tag Management

    /// Add a new tag definition
    func addTag(name: String) {
        guard case .valid(let displayName) = validateName(name) else { return }
        definitions.append(TagDefinition(name: displayName))
    }

    /// Validate a user-facing tag name without changing it or discarding the caller's input.
    func validateName(_ rawName: String, excluding tagID: UUID? = nil) -> TagNameValidation {
        let displayName = TagCanonicalizer.displayName(rawName)
        let canonicalKey = TagCanonicalizer.key(displayName)
        guard !canonicalKey.isEmpty else { return .empty }
        if let existing = definitions.first(where: {
            $0.id != tagID && TagCanonicalizer.key($0.name) == canonicalKey
        }) {
            return .duplicate(existingName: existing.name)
        }
        return .valid(displayName)
    }

    /// Apply or clear a sibling-scoped shortcut override. Auto bindings are represented by nil.
    @discardableResult
    func setShortcutKey(_ rawKey: String?, for tagID: UUID) -> Result<Character?, TagShortcutAssignmentError> {
        guard let index = definitions.firstIndex(where: { $0.id == tagID }) else {
            return .failure(.tagUnavailable)
        }

        guard let rawKey, !TagCanonicalizer.displayName(rawKey).isEmpty else {
            definitions[index].shortcutKey = nil
            return .success(nil)
        }
        guard let key = Self.normalizedShortcut(rawKey) else {
            return .failure(.invalidKey(rawKey))
        }

        let parentID = definitions[index].parentId
        if let conflict = definitions.first(where: {
            $0.id != tagID
                && $0.parentId == parentID
                && Self.normalizedShortcut($0.shortcutKey) == key
        }) {
            return .failure(.duplicateKey(key: key, existingTagName: conflict.name))
        }

        definitions[index].shortcutKey = String(key)
        return .success(key)
    }

    nonisolated static func normalizedShortcut(_ rawKey: String?) -> Character? {
        guard let rawKey else { return nil }
        let normalized = TagCanonicalizer.key(rawKey)
        guard normalized.count == 1, let key = normalized.first,
              TagTreeNode.keySequence.contains(key) else { return nil }
        return key
    }

    /// Remove a tag definition
    func removeTag(_ tag: TagDefinition) {
        definitions.removeAll { $0.id == tag.id }
    }

    /// Update a tag's color
    func updateColor(for tagId: UUID, color: UInt) {
        if let index = definitions.firstIndex(where: { $0.id == tagId }) {
            definitions[index].colorHex = color
        }
    }

    /// GAP #2 Fix: Rename a tag and cascade to smart folders.
    /// Updates the tag definition and all smart folder rules referencing it.
    func renameTag(tagId: UUID, newName: String, mediaStore: MediaStore) {
        guard case .valid(let displayName) = validateName(newName, excluding: tagId) else { return }

        guard let index = definitions.firstIndex(where: { $0.id == tagId }) else { return }
        let oldName = definitions[index].name

        // Skip if name unchanged
        guard oldName != displayName else { return }

        // Update the definition
        definitions[index].name = displayName

        // Cascade to smart folders, media items, and tag rules
        Task {
            do {
                try await mediaStore.renameTagGlobally(oldName: oldName, newName: displayName)
            } catch {
                logError("TagSettings: Failed to cascade tag rename to media items: \(error)")
            }
            do {
                try await mediaStore.renameTagInSmartFolders(oldName: oldName, newName: displayName)
            } catch {
                logError("TagSettings: Failed to cascade tag rename to smart folders: \(error)")
            }
            do {
                try await mediaStore.renameTagInRules(oldName: oldName, newName: displayName)
            } catch {
                logError("TagSettings: Failed to cascade tag rename to tag rules: \(error)")
            }
        }
    }

    /// Get or create a tag definition for a name
    func definition(for name: String) -> TagDefinition {
        let key = TagCanonicalizer.key(name)
        let _ = ensureDefinitionsExist(for: [name])
        return definitions.first(where: { TagCanonicalizer.key($0.name) == key })
            ?? TagDefinition(name: TagCanonicalizer.displayName(name))
    }

    /// Ensure definitions exist for the given tag names, appending missing tags as roots.
    @discardableResult
    func ensureDefinitionsExist(for tagNames: [String]) -> Int {
        guard !tagNames.isEmpty else { return 0 }

        var existingNames = Set(definitions.map { TagCanonicalizer.key($0.name) })
        var updated = definitions
        var addedCount = 0
        var nextRootSortOrder = rootTags().count

        for rawName in tagNames {
            let displayName = TagCanonicalizer.displayName(rawName)
            let key = TagCanonicalizer.key(displayName)
            guard !key.isEmpty, !existingNames.contains(key) else { continue }

            var definition = TagDefinition(name: displayName)
            definition.sortOrder = nextRootSortOrder
            nextRootSortOrder += 1

            updated.append(definition)
            existingNames.insert(key)
            addedCount += 1
        }

        if addedCount > 0 {
            definitions = updated
        }

        return addedCount
    }

    /// Get the color for a tag name without creating a definition.
    /// Falls back to auto-generated color if no definition exists.
    func colorOnly(for name: String) -> Color {
        let key = TagCanonicalizer.key(name)
        if let cached = colorCache[key] {
            return cached
        }
        let color: Color
        if let existing = definitions.first(where: { TagCanonicalizer.key($0.name) == key }) {
            color = existing.color
        } else {
            color = Color(hex: TagDefinition.autoColor(for: key))
        }
        colorCache[key] = color
        return color
    }

    func resetPreferencesToDefaults() {
        modifierKey = .option
        layout = .defaultLayout
        gridScale = 1.0
    }

    // MARK: - Recent Tags

    /// Record a tag as recently used (add to front, dedupe, limit to 10)
    func recordTagUsage(_ tagId: UUID) {
        recentTagIds.removeAll { $0 == tagId }
        recentTagIds.insert(tagId, at: 0)
        if recentTagIds.count > 10 {
            recentTagIds = Array(recentTagIds.prefix(10))
        }
    }

    /// Record usage by display name. Names without a definition are ignored.
    func recordTagUsage(named name: String) {
        guard let definition = TagDefinitionSearch.existingDefinition(named: name, in: definitions) else { return }
        recordTagUsage(definition.id)
    }

    /// Recently used definitions, most recent first. This is the single persisted
    /// recents source: the hold-to-tag overlay and the tagging queue both write it.
    var recentTags: [TagDefinition] {
        recentTagIds.compactMap { id in
            definitions.first { $0.id == id }
        }
    }
}
