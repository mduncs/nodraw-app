import Foundation
import GRDB

enum ItemAssetRole: String, Codable, Sendable { case media, context }

/// Persistent file identity. Order and path may change without changing assetID;
/// a suspected content replacement gets a new identity and retains old associations.
struct ItemAsset: Identifiable, Codable, Hashable, Sendable {
    let assetID: UUID
    let itemID: UUID
    let url: URL
    let role: ItemAssetRole
    let order: Int
    let availability: String
    var id: UUID { assetID }
}

enum ItemAssetStore {
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
    enum AssociationError: LocalizedError {
        case staleAsset, ambiguousAsset, occupiedAsset, draftRetained
        var errorDescription: String? {
            switch self {
            case .staleAsset: return "This file changed while the operation was running. Its previous annotations and analysis were retained."
            case .ambiguousAsset: return "The file association is ambiguous and needs review."
            case .occupiedAsset: return "The selected file already has annotations. Both versions were retained."
            case .draftRetained: return "The file changed while you were editing. Your draft was saved in Retained File Data for review."
            }
        }
    }
    struct AssociationIssue: Sendable {
        let table: String
        let recordID: String
        let itemID: UUID
        let assetID: UUID?
        let reason: String
        let sourcePath: String?
        let originalIndex: Int?
    }

    private static let dependencies = [
        (table: "annotations", item: "itemId", ordinal: "mediaFileIndex", path: Optional<String>.none),
        (table: "media_file_ocr", item: "item_id", ordinal: "file_index", path: Optional("file_url")),
        (table: "video_segments", item: "item_id", ordinal: "media_file_index", path: Optional("source_path")),
        (table: "transcript_segments", item: "item_id", ordinal: "media_file_index", path: Optional("source_path"))
    ]

    static func install(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE item_assets (
                asset_id TEXT PRIMARY KEY, item_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
                path TEXT NOT NULL, role TEXT NOT NULL, position INTEGER NOT NULL,
                is_current INTEGER NOT NULL DEFAULT 1, fingerprint TEXT, availability TEXT NOT NULL,
                retirement_reason TEXT
            );
            CREATE INDEX idx_item_assets_current ON item_assets(item_id, is_current, role, position);
            CREATE TABLE asset_association_resolutions (
                id INTEGER PRIMARY KEY AUTOINCREMENT, record_id TEXT NOT NULL,
                previous_asset_id TEXT, selected_asset_id TEXT NOT NULL,
                previous_state TEXT NOT NULL, resolved_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
            );
            """)
        for dependency in dependencies {
            try db.execute(sql: "ALTER TABLE \(dependency.table) ADD COLUMN asset_id TEXT REFERENCES item_assets(asset_id) ON DELETE CASCADE")
            try db.execute(sql: "ALTER TABLE \(dependency.table) ADD COLUMN association_state TEXT NOT NULL DEFAULT 'legacy'")
            try db.execute(sql: "ALTER TABLE \(dependency.table) ADD COLUMN legacy_file_index INTEGER")
            try db.execute(sql: "CREATE INDEX idx_\(dependency.table)_asset ON \(dependency.table)(asset_id)")
        }
        try db.execute(sql: "CREATE TRIGGER asset_annotation_parent_delete AFTER DELETE ON media_items BEGIN DELETE FROM annotations WHERE itemId = OLD.id; END")
        for id in try String.fetchAll(db, sql: "SELECT id FROM media_items") {
            try reconcile(in: db, itemID: id)
        }
        // Raw queue INSERTs retain compatibility, resolving by their captured
        // source path when present. Annotation saves supply an explicit asset ID.
        for dependency in dependencies {
            let match: String
            if let path = dependency.path {
                match = "a.path = NEW.\(path)"
            } else {
                match = """
                    ((a.role = 'media' AND a.position = NEW.\(dependency.ordinal)
                      AND NOT (NEW.\(dependency.ordinal) = 0 AND EXISTS(SELECT 1 FROM item_assets c WHERE c.item_id = a.item_id AND c.is_current = 1 AND c.role = 'context')))
                     OR (a.role = 'context' AND NEW.\(dependency.ordinal) = 0
                       AND NOT EXISTS(SELECT 1 FROM item_assets m WHERE m.item_id = a.item_id AND m.is_current = 1 AND m.role = 'media')))
                    """
            }
            try db.execute(sql: """
                CREATE TRIGGER asset_attach_\(dependency.table) AFTER INSERT ON \(dependency.table)
                WHEN NEW.asset_id IS NULL
                BEGIN
                    UPDATE \(dependency.table) SET
                        asset_id = (SELECT MIN(a.asset_id) FROM item_assets a WHERE a.item_id = NEW.\(dependency.item) AND a.is_current = 1 AND \(match) HAVING COUNT(*) = 1),
                        association_state = CASE WHEN (SELECT COUNT(*) FROM item_assets a WHERE a.item_id = NEW.\(dependency.item) AND a.is_current = 1 AND \(match)) = 1 THEN 'attached' ELSE 'ambiguous' END
                    WHERE id = NEW.id;
                END;
                """)
        }
    }

    /// Cheap, persistent replacement evidence; no archive-wide content hashing.
    /// Changed size or times are treated conservatively, never as proof that old
    /// annotations describe the replacement bytes. Missing files retain evidence.
    private static func fingerprint(_ path: String) -> String? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: path),
              let size = values[.size] as? NSNumber,
              let modified = values[.modificationDate] as? Date else { return nil }
        let inode = (values[.systemFileNumber] as? NSNumber)?.stringValue ?? "?"
        let device = (values[.systemNumber] as? NSNumber)?.stringValue ?? "?"
        let created = (values[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(device):\(inode):\(size):\(modified.timeIntervalSince1970):\(created)"
    }

    /// Device and inode say where the bytes live, not what they are: a backup restore, drive
    /// migration, remount or times-preserving copy changes them while size, mtime and birth
    /// time stay. Only those three decide replacement; unparseable evidence compares exactly.
    private static func sameContentEvidence(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == rhs }
        let a = lhs.split(separator: ":", omittingEmptySubsequences: false)
        let b = rhs.split(separator: ":", omittingEmptySubsequences: false)
        guard a.count == 5, b.count == 5 else { return lhs == rhs }
        return a[2...] == b[2...]
    }

    static func reconcile(in db: Database, itemID: String) throws {
        guard try db.tableExists("item_assets"),
              let item = try Row.fetchOne(db, sql: "SELECT mediaFilesJSON, contextImageString FROM media_items WHERE id = ?", arguments: [itemID]) else { return }
        let json: String = item["mediaFilesJSON"]
        let files = try JSONDecoder().decode([String].self, from: Data(json.utf8))
        var desired = files.enumerated().map { (path: $0.element, role: "media", order: $0.offset) }
        if let context: String = item["contextImageString"], !context.isEmpty { desired.append((context, "context", 0)) }
        let allAssets = try Row.fetchAll(db, sql: "SELECT * FROM item_assets WHERE item_id = ?", arguments: [itemID])
        let old = allAssets.filter { $0["is_current"] as Bool }
        var retained = Set<String>()
        var identityChanged = false
        for entry in desired {
            let identity = canonicalPath(entry.path)
            let matches = old.filter { canonicalPath($0["path"] as String) == identity && ($0["role"] as String) == entry.role }
            let duplicates = desired.filter { canonicalPath($0.path) == identity && $0.role == entry.role }.count > 1
            let currentFingerprint = fingerprint(entry.path)
            let existing = matches.count == 1 && !duplicates ? matches.first : nil
            let oldFingerprint: String? = existing?["fingerprint"]
            let changed = existing != nil && currentFingerprint != nil && !sameContentEvidence(oldFingerprint, currentFingerprint)
            if let existing, !changed {
                let id: String = existing["asset_id"]
                if (existing["position"] as Int) != entry.order { identityChanged = true }
                retained.insert(id)
                // Refresh moved device/inode; a missing file keeps its last evidence.
                try db.execute(sql: "UPDATE item_assets SET path = ?, position = ?, availability = ?, fingerprint = COALESCE(?, fingerprint) WHERE asset_id = ?", arguments: [entry.path, entry.order, currentFingerprint == nil ? "missing" : "available", currentFingerprint, id])
            } else {
                if let existing {
                    let id: String = existing["asset_id"]
                    try db.execute(sql: "UPDATE item_assets SET is_current = 0, retirement_reason = 'replacement' WHERE asset_id = ?", arguments: [id])
                    identityChanged = true
                }
                let restorable = allAssets.filter {
                    !($0["is_current"] as Bool) && currentFingerprint != nil
                        && sameContentEvidence($0["fingerprint"] as String?, currentFingerprint)
                        && canonicalPath($0["path"] as String) == identity && ($0["role"] as String) == entry.role
                }
                let recovered = restorable.count == 1 && !duplicates ? restorable.first : nil
                let id: String = recovered?["asset_id"] ?? UUID().uuidString
                retained.insert(id)
                if recovered != nil {
                    try db.execute(sql: "UPDATE item_assets SET is_current = 1, path = ?, position = ?, retirement_reason = NULL, availability = 'available', fingerprint = ? WHERE asset_id = ?", arguments: [entry.path, entry.order, currentFingerprint, id])
                } else {
                    try db.execute(sql: """
                    INSERT INTO item_assets(asset_id, item_id, path, role, position, fingerprint, availability)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [id, itemID, entry.path, entry.role, entry.order, currentFingerprint, duplicates ? "ambiguous" : (currentFingerprint == nil ? "missing" : "available")])
                }
            }
        }
        for row in old where !retained.contains(row["asset_id"] as String) {
            let id: String = row["asset_id"]
            try db.execute(sql: "UPDATE item_assets SET is_current = 0, retirement_reason = COALESCE(retirement_reason, 'removed') WHERE asset_id = ?", arguments: [id])
            identityChanged = true
        }
        try reconcileAssociations(in: db, itemID: itemID, legacyContextAmbiguity: !files.isEmpty && item["contextImageString"] as String? != nil)
        if identityChanged {
            // Aggregated item-level OCR cannot safely retain index-zero fallback
            // after removal/replacement. Per-asset records remain recoverable.
            try db.execute(sql: "UPDATE media_items SET ocrText = NULL, ocrBoundingBoxesJSON = NULL WHERE id = ?", arguments: [itemID])
        }
    }

    private static func reconcileAssociations(in db: Database, itemID: String, legacyContextAmbiguity: Bool = false) throws {
        let assets = try Row.fetchAll(db, sql: "SELECT * FROM item_assets WHERE item_id = ?", arguments: [itemID])
        for dependency in dependencies {
            try db.execute(sql: "UPDATE \(dependency.table) SET legacy_file_index = COALESCE(legacy_file_index, \(dependency.ordinal)) WHERE \(dependency.item) = ?", arguments: [itemID])
            let rows = try Row.fetchAll(db, sql: "SELECT rowid AS association_rowid, * FROM \(dependency.table) WHERE \(dependency.item) = ?", arguments: [itemID])
            // Park all ordinals in unique negative slots before any permutation;
            // this also makes unresolved rows unreachable by ordinal adapters.
            for row in rows {
                let rowID: Int64 = row["association_rowid"]
                try db.execute(sql: "UPDATE \(dependency.table) SET \(dependency.ordinal) = ? WHERE id = ?", arguments: [-rowID - 1, row["id"] as String])
            }
            var occupied = Set<Int>()
            for row in rows {
                let rowID: String = row["id"]
                let state: String = row["association_state"]
                let existingID: String? = row["asset_id"]
                var selected = assets.first { ($0["asset_id"] as String) == existingID }
                var reason = "ambiguous"
                if selected == nil && state == "legacy" {
                    let index: Int = row[dependency.ordinal]
                    let candidates = assets.filter { asset in
                        guard (asset["is_current"] as Bool) else { return false }
                        if let path = dependency.path { return canonicalPath(asset["path"] as String) == canonicalPath(row[path] as String) }
                        if legacyContextAmbiguity && index == 0 { return false }
                        let mediaCount = assets.filter { ($0["is_current"] as Bool) && ($0["role"] as String) == "media" }.count
                        return (asset["role"] as String) == "context" ? index == mediaCount : (asset["position"] as Int) == index
                    }
                    if candidates.count == 1 { selected = candidates[0] }
                }
                if let asset = selected {
                    let id: String = asset["asset_id"]
                    let isCurrent: Bool = asset["is_current"]
                    let availability: String = asset["availability"]
                    let isContext = (asset["role"] as String) == "context"
                    let mediaCount = assets.filter { ($0["is_current"] as Bool) && ($0["role"] as String) == "media" }.count
                    let position: Int = isContext ? mediaCount : asset["position"]
                    if state == "retained-draft" { reason = "retained-draft" }
                    else if !isCurrent { reason = asset["retirement_reason"] ?? "removed" }
                    else if (state == "legacy" || state == "unverified") && availability != "available" { reason = "unverified" }
                    else if availability == "ambiguous" { reason = "ambiguous" }
                    else if dependency.table == "annotations" || dependency.table == "media_file_ocr" {
                        reason = occupied.insert(position).inserted ? "attached" : "ambiguous"
                    } else { reason = "attached" }
                    if reason == "attached" {
                        try db.execute(sql: "UPDATE \(dependency.table) SET asset_id = ?, association_state = 'attached', \(dependency.ordinal) = ? WHERE id = ?", arguments: [id, position, rowID])
                        if let path = dependency.path {
                            try db.execute(sql: "UPDATE \(dependency.table) SET \(path) = ? WHERE id = ?", arguments: [asset["path"] as String, rowID])
                        }
                    } else {
                        try db.execute(sql: "UPDATE \(dependency.table) SET asset_id = ?, association_state = ? WHERE id = ?", arguments: [id, reason, rowID])
                    }
                } else {
                    try db.execute(sql: "UPDATE \(dependency.table) SET association_state = ? WHERE id = ?", arguments: [reason, rowID])
                }
            }
        }
    }

    static func fetchBatch(in db: Database, itemIDs: [UUID]) throws -> [UUID: [ItemAsset]] {
        guard !itemIDs.isEmpty else { return [:] }
        var result: [UUID: [ItemAsset]] = [:]
        for start in stride(from: 0, to: itemIDs.count, by: 400) {
            let batch = Array(itemIDs[start..<min(start + 400, itemIDs.count)])
            let placeholders = batch.map { _ in "?" }.joined(separator: ",")
            for row in try Row.fetchAll(db, sql: "SELECT * FROM item_assets WHERE item_id IN (\(placeholders)) AND is_current = 1 ORDER BY role DESC, position", arguments: StatementArguments(batch.map(\.uuidString))) {
                guard let id = UUID(uuidString: row["asset_id"]), let itemID = UUID(uuidString: row["item_id"]), let role = ItemAssetRole(rawValue: row["role"]) else { continue }
                result[itemID, default: []].append(ItemAsset(assetID: id, itemID: itemID, url: URL(fileURLWithPath: row["path"]), role: role, order: row["position"], availability: row["availability"]))
            }
        }
        return result
    }

    /// Resolve against identity captured by the caller before async work. A
    /// stale asset never degrades to a same-path or same-ordinal match.
    static func prepareWrite(in db: Database, itemID: UUID, assetID: UUID?, path: String? = nil, index: Int) throws -> (id: UUID, index: Int, path: String) {
        // Most callers insert many segments in one transaction. Only perform
        // full remapping when evidence changed, avoiding quadratic remap work.
        let stored = try Row.fetchAll(db, sql: "SELECT path, fingerprint, availability FROM item_assets WHERE item_id = ? AND is_current = 1", arguments: [itemID.uuidString])
        if stored.isEmpty || stored.contains(where: { row in
            let current = fingerprint(row["path"])
            return current != (row["fingerprint"] as String?) && current != nil
        }) { try reconcile(in: db, itemID: itemID.uuidString) }
        let assets = try fetchBatch(in: db, itemIDs: [itemID])[itemID] ?? []
        let matches = assets.filter { asset in
            if let assetID { return asset.assetID == assetID }
            if let path { return canonicalPath(asset.url.path) == canonicalPath(path) }
            return asset.order == index && (asset.role == .media || !assets.contains { $0.role == .media })
        }
        guard matches.count == 1, let asset = matches.first else {
            throw assetID == nil ? AssociationError.ambiguousAsset : AssociationError.staleAsset
        }
        guard asset.availability != "ambiguous" else { throw AssociationError.ambiguousAsset }
        let ordinal = asset.role == .context ? assets.filter { $0.role == .media }.count : asset.order
        return (asset.assetID, ordinal, asset.url.path)
    }

    static func issues(in db: Database, itemID: UUID? = nil) throws -> [AssociationIssue] {
        var result: [AssociationIssue] = []
        for dependency in dependencies {
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(dependency.table) WHERE association_state != 'attached' \(itemID == nil ? "" : "AND \(dependency.item) = ?")", arguments: itemID.map { StatementArguments([$0.uuidString]) } ?? StatementArguments())
            for row in rows {
                guard let id = UUID(uuidString: row[dependency.item]) else { continue }
                let asset: String? = row["asset_id"]
                let source: String?
                if let path = dependency.path { source = row[path] }
                else if let asset { source = try String.fetchOne(db, sql: "SELECT path FROM item_assets WHERE asset_id = ?", arguments: [asset]) }
                else { source = nil }
                var reason: String = row["association_state"]
                if dependency.table == "annotations", asset == nil,
                   try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM media_items WHERE id = ?)", arguments: [id.uuidString]) == false {
                    reason = "orphaned-item"
                }
                result.append(AssociationIssue(table: dependency.table, recordID: row["id"], itemID: id, assetID: asset.flatMap(UUID.init(uuidString:)), reason: reason, sourcePath: source, originalIndex: row["legacy_file_index"]))
            }
        }
        return result
    }

    static func transfer(in db: Database, primaryID: UUID, secondaryIDs: [UUID], preservingAssetIDs: Set<UUID>) throws {
        for secondaryID in secondaryIDs {
            let secondaryAssets = try fetchBatch(in: db, itemIDs: [secondaryID])[secondaryID] ?? []
            for asset in secondaryAssets {
                let primaryAssets = try fetchBatch(in: db, itemIDs: [primaryID])[primaryID] ?? []
                // Adopt only files actually retained by combine. An unadopted
                // context remains recoverable on its secondary tombstone.
                guard let destination = primaryAssets.first(where: { canonicalPath($0.url.path) == canonicalPath(asset.url.path) && $0.role == asset.role }) else { continue }
                let destinationHadData = try dependencies.contains { dependency in
                    try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(dependency.table) WHERE asset_id = ?)", arguments: [destination.assetID.uuidString]) ?? false
                }
                if !destinationHadData && !preservingAssetIDs.contains(destination.assetID) {
                    // The merged list allocated a fresh empty identity. Replace
                    // it with the secondary's existing identity, not a new one.
                    try db.execute(sql: "UPDATE item_assets SET is_current = 0, retirement_reason = 'combined-alias' WHERE asset_id = ?", arguments: [destination.assetID.uuidString])
                    try db.execute(sql: "UPDATE item_assets SET item_id = ?, position = ? WHERE asset_id = ?", arguments: [primaryID.uuidString, destination.order, asset.assetID.uuidString])
                } else {
                    // Two source items can name the same file. Do not guess which
                    // annotation version wins; retain the second for review.
                    try db.execute(sql: "UPDATE item_assets SET item_id = ?, is_current = 0, retirement_reason = 'combined-duplicate' WHERE asset_id = ?", arguments: [primaryID.uuidString, asset.assetID.uuidString])
                }
                for dependency in dependencies {
                    // Park before crossing an item's unique ordinal boundary.
                    try db.execute(sql: "UPDATE \(dependency.table) SET \(dependency.ordinal) = -rowid - 1, \(dependency.item) = ? WHERE asset_id = ?", arguments: [primaryID.uuidString, asset.assetID.uuidString])
                }
            }
        }
        try reconcileAssociations(in: db, itemID: primaryID.uuidString)
    }

    static func movePaths(in db: Database, from old: String, to new: String, directory: Bool) throws {
        guard try db.tableExists("item_assets") else { return }
        for row in try Row.fetchAll(db, sql: "SELECT asset_id, path FROM item_assets") {
            let path: String = row["path"]
            guard path == old || (directory && path.hasPrefix(old + "/")) else { continue }
            let updated = new + path.dropFirst(old.count)
            try db.execute(sql: "UPDATE item_assets SET path = ? WHERE asset_id = ?", arguments: [updated, row["asset_id"] as String])
            for dependency in dependencies {
                guard let sourceColumn = dependency.path else { continue }
                try db.execute(sql: "UPDATE \(dependency.table) SET \(sourceColumn) = ? WHERE asset_id = ?", arguments: [updated, row["asset_id"] as String])
            }
        }
    }
}
