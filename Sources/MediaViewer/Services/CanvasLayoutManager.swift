import Foundation
import Combine
import GRDB

// MARK: - SpatialHash

/// Grid-based spatial index for O(1) viewport queries.
/// Items are bucketed by position into a sparse grid, enabling fast
/// "which items are visible" queries without scanning all placements.
final class SpatialHash {
    /// Grid cell size in canvas units. Larger = fewer buckets, more items per bucket.
    /// 500 is a good balance for typical image sizes (200-400px).
    private let cellSize: CGFloat

    /// Sparse grid storage: [GridKey: Set of item IDs in that cell]
    private var buckets: [GridKey: Set<UUID>] = [:]

    /// Reverse lookup: item ID -> which cells it occupies
    private var itemCells: [UUID: Set<GridKey>] = [:]

    init(cellSize: CGFloat = 500) {
        self.cellSize = cellSize
    }

    // MARK: - GridKey

    struct GridKey: Hashable {
        let x: Int
        let y: Int
    }

    // MARK: - Insert/Update/Remove

    /// Insert or update an item's position in the spatial hash.
    func upsert(id: UUID, frame: CGRect) {
        // Remove from old cells first
        remove(id: id)

        // Calculate which grid cells this frame overlaps
        let cells = gridKeys(for: frame)

        // Add to each overlapping cell
        for cell in cells {
            buckets[cell, default: []].insert(id)
        }
        itemCells[id] = cells
    }

    /// Remove an item from the spatial hash.
    func remove(id: UUID) {
        guard let cells = itemCells[id] else { return }

        for cell in cells {
            buckets[cell]?.remove(id)
            if buckets[cell]?.isEmpty == true {
                buckets.removeValue(forKey: cell)
            }
        }
        itemCells.removeValue(forKey: id)
    }

    /// Clear all items from the spatial hash.
    func clear() {
        buckets.removeAll()
        itemCells.removeAll()
    }

    // MARK: - Query

    /// Query for all item IDs that might be visible in the given rect.
    /// Returns a superset - items in overlapping grid cells.
    /// Caller should do precise intersection check if needed.
    func query(rect: CGRect) -> Set<UUID> {
        let cells = gridKeys(for: rect)
        var result = Set<UUID>()

        for cell in cells {
            if let items = buckets[cell] {
                result.formUnion(items)
            }
        }

        return result
    }

    /// Get count of items in the spatial hash.
    var itemCount: Int {
        itemCells.count
    }

    /// Get count of non-empty buckets (for debugging).
    var bucketCount: Int {
        buckets.count
    }

    // MARK: - Private

    /// Calculate which grid cells a rect overlaps.
    private func gridKeys(for rect: CGRect) -> Set<GridKey> {
        let minX = Int(floor(rect.minX / cellSize))
        let maxX = Int(floor(rect.maxX / cellSize))
        let minY = Int(floor(rect.minY / cellSize))
        let maxY = Int(floor(rect.maxY / cellSize))

        var keys = Set<GridKey>()
        for x in minX...maxX {
            for y in minY...maxY {
                keys.insert(GridKey(x: x, y: y))
            }
        }
        return keys
    }
}

struct CanvasVisibilityState {
    let visiblePlacements: [CanvasItemPlacement]
    let totalCount: Int
    let indexedCount: Int
}

// MARK: - CanvasLayoutManager

/// Manages canvas layout, persistence, and spatial indexing.
/// Provides auto-tile algorithm for initial layout and debounced position persistence.
actor CanvasLayoutManager {
    private let database: DatabaseManager
    private var spatialHash: SpatialHash
    private var placements: [UUID: CanvasItemPlacement] = [:] // itemId -> placement
    private var currentCanvasId: UUID?

    /// Warning threshold for item count
    static let itemCountWarning = 500

    // Debounced save
    private var pendingSaves: Set<UUID> = []
    private var saveTask: Task<Void, Never>?
    private let saveDebounceInterval: UInt64 = 300_000_000 // 300ms

    init(database: DatabaseManager = .shared, cellSize: CGFloat = 500) {
        self.database = database
        self.spatialHash = SpatialHash(cellSize: cellSize)
    }

    /// GAP #6 fix: Clear in-memory state if the specified canvas matches current
    /// Called when a canvas is deleted to prevent stale state
    func invalidateIfCurrent(canvasId: UUID) {
        if currentCanvasId == canvasId {
            spatialHash.clear()
            placements.removeAll()
            currentCanvasId = nil
        }
    }

    // MARK: - Canvas Loading

    /// Load placements for a canvas into memory and build spatial index.
    func loadCanvas(_ canvasId: UUID) async throws {
        let loadedPlacements = try await database.read { db in
            try CanvasItemPlacement.fetchForCanvas(db: db, canvasId: canvasId)
        }

        // Clear existing state
        spatialHash.clear()
        placements.removeAll()
        currentCanvasId = canvasId

        // Build spatial index
        for placement in loadedPlacements {
            placements[placement.mediaItemId] = placement
            spatialHash.upsert(id: placement.mediaItemId, frame: placement.frame)
        }

        logInfo("Loaded canvas \(canvasId) with \(loadedPlacements.count) placements")
    }

    /// Get placements visible in viewport (uses spatial hash for O(1) lookup).
    func visiblePlacements(in viewport: CGRect, buffer: CGFloat = 500) -> [CanvasItemPlacement] {
        visibilityState(in: viewport, buffer: buffer).visiblePlacements
    }

    /// Get visible placements plus index health for verification and recovery UI.
    func visibilityState(in viewport: CGRect, buffer: CGFloat = 500) -> CanvasVisibilityState {
        rebuildSpatialHashIfNeeded()

        let expandedViewport = viewport.insetBy(dx: -buffer, dy: -buffer)
        let candidateIds = spatialHash.query(rect: expandedViewport)

        let visiblePlacements = candidateIds.compactMap { itemId -> CanvasItemPlacement? in
            guard let placement = placements[itemId] else { return nil }
            // Precise intersection check
            if placement.frame.intersects(expandedViewport) {
                return placement
            }
            return nil
        }.sorted { $0.zIndex < $1.zIndex }

        return CanvasVisibilityState(
            visiblePlacements: visiblePlacements,
            totalCount: placements.count,
            indexedCount: spatialHash.itemCount
        )
    }

    /// Get all placements (for small canvases or export).
    func allPlacements() -> [CanvasItemPlacement] {
        Array(placements.values).sorted { $0.zIndex < $1.zIndex }
    }

    /// Get placement for a specific item.
    func placement(for itemId: UUID) -> CanvasItemPlacement? {
        placements[itemId]
    }

    /// Check if canvas has many items (for warning).
    var itemCount: Int {
        placements.count
    }

    var shouldWarnAboutItemCount: Bool {
        placements.count > Self.itemCountWarning
    }

    private func rebuildSpatialHashIfNeeded() {
        guard spatialHash.itemCount != placements.count else { return }

        logWarning(
            "CanvasLayoutManager: spatial index out of sync " +
            "(indexed=\(spatialHash.itemCount), placements=\(placements.count)); rebuilding"
        )

        spatialHash.clear()
        for placement in placements.values {
            spatialHash.upsert(id: placement.mediaItemId, frame: placement.frame)
        }
    }

    // MARK: - Position Updates

    /// Update item position (e.g., from drag gesture).
    /// Position changes are debounced before persisting to database.
    func updatePosition(itemId: UUID, position: CGPoint) {
        guard var placement = placements[itemId] else { return }

        placement.position = position
        placement.isManuallyPlaced = true
        placements[itemId] = placement

        // Update spatial hash
        spatialHash.upsert(id: itemId, frame: placement.frame)

        // Queue for debounced save
        pendingSaves.insert(itemId)
        scheduleSave()
    }

    /// Update item size (e.g., from resize gesture).
    func updateSize(itemId: UUID, size: CGSize) {
        guard var placement = placements[itemId] else { return }

        placement.size = size
        placement.isManuallyPlaced = true
        placements[itemId] = placement

        // Update spatial hash
        spatialHash.upsert(id: itemId, frame: placement.frame)

        // Queue for debounced save
        pendingSaves.insert(itemId)
        scheduleSave()
    }

    /// Update item rotation (Issue #11).
    func updateRotation(itemId: UUID, rotation: Double) {
        guard var placement = placements[itemId] else { return }

        placement.rotation = rotation
        placement.isManuallyPlaced = true
        placements[itemId] = placement

        // Queue for debounced save
        pendingSaves.insert(itemId)
        scheduleSave()
    }

    /// Bring item to front (highest z-index).
    func bringToFront(itemId: UUID) async throws {
        guard var placement = placements[itemId],
              let canvasId = currentCanvasId else { return }

        let newZ = try await database.write { db in
            try CanvasItemPlacement.nextZIndex(db: db, canvasId: canvasId)
        }

        placement.zIndex = newZ
        placements[itemId] = placement

        // Save immediately (z-index changes are important)
        try await savePlacement(placement)
    }

    // MARK: - Debounced Save

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            do {
                try await Task.sleep(nanoseconds: saveDebounceInterval)
                await flushPendingSaves()
            } catch {
                // Task cancelled - that's fine
            }
        }
    }

    private func flushPendingSaves() async {
        let itemsToSave = pendingSaves
        pendingSaves.removeAll()

        guard !itemsToSave.isEmpty else { return }

        let placementsToSave = itemsToSave.compactMap { placements[$0] }

        do {
            try await database.write { db in
                for placement in placementsToSave {
                    try placement.save(db)
                }
            }
        } catch {
            logError("Failed to save placements: \(error.localizedDescription)")
            // Put items back in pending queue for retry
            pendingSaves.formUnion(itemsToSave)
        }
    }

    private func savePlacement(_ placement: CanvasItemPlacement) async throws {
        try await database.write { db in
            try placement.save(db)
        }
    }

    // MARK: - Auto-Tile Layout

    /// Generate initial tile positions for items that don't have manual placements.
    /// Uses a simple grid layout with some variation for visual interest.
    func autoTileLayout(
        items: [MediaItem],
        canvasId: UUID,
        startPosition: CGPoint = .zero,
        tileWidth: CGFloat = 250,
        spacing: CGFloat = 20
    ) async throws -> [CanvasItemPlacement] {
        // Calculate grid dimensions based on item count
        let columns = max(1, Int(ceil(sqrt(Double(items.count)))))
        var placements: [CanvasItemPlacement] = []

        // Track column heights for masonry-style stacking
        var columnHeights = [CGFloat](repeating: 0, count: columns)

        for (index, item) in items.enumerated() {
            // Find shortest column
            let shortestColumn = columnHeights.enumerated()
                .min(by: { $0.element < $1.element })?.offset ?? 0

            let x = startPosition.x + CGFloat(shortestColumn) * (tileWidth + spacing)
            let y = startPosition.y + columnHeights[shortestColumn]

            // Calculate height based on aspect ratio
            let aspectRatio = item.effectiveAspectRatio
            let height = tileWidth / aspectRatio

            let placement = CanvasItemPlacement(
                canvasId: canvasId,
                mediaItemId: item.id,
                x: x,
                y: y,
                width: tileWidth,
                height: height,
                zIndex: index,
                isManuallyPlaced: false
            )
            placements.append(placement)

            // Update column height
            columnHeights[shortestColumn] += height + spacing
        }

        return placements
    }

    /// Add items to canvas using auto-tile layout.
    /// Returns count of items added.
    @discardableResult
    func addItemsToCanvas(
        items: [MediaItem],
        canvasId: UUID,
        startPosition: CGPoint? = nil
    ) async throws -> Int {
        // Filter out items already on canvas
        let existingIds = Set(placements.keys)
        let newItems = items.filter { !existingIds.contains($0.id) }

        guard !newItems.isEmpty else { return 0 }

        // Calculate start position if not provided
        let start: CGPoint
        if let provided = startPosition {
            start = provided
        } else {
            // Place below existing content
            let maxY = placements.values.map { $0.frame.maxY }.max() ?? 0
            start = CGPoint(x: 0, y: maxY + 50)
        }

        // Generate layout
        let newPlacements = try await autoTileLayout(
            items: newItems,
            canvasId: canvasId,
            startPosition: start
        )

        // Save to database
        try await database.write { db in
            for placement in newPlacements {
                try placement.insert(db)
            }
        }

        // Update in-memory state
        for placement in newPlacements {
            placements[placement.mediaItemId] = placement
            spatialHash.upsert(id: placement.mediaItemId, frame: placement.frame)
        }

        self.currentCanvasId = canvasId

        return newPlacements.count
    }

    /// Remove item from canvas.
    func removeItem(itemId: UUID) async throws {
        guard let placement = placements[itemId] else { return }

        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM canvas_placements WHERE id = ?",
                arguments: [placement.id.uuidString]
            )
        }

        placements.removeValue(forKey: itemId)
        spatialHash.remove(id: itemId)
    }

    // MARK: - Canvas Viewport Persistence

    /// Save viewport state (position and zoom).
    func saveViewport(canvasId: UUID, viewport: CGPoint, zoomLevel: CGFloat) async throws {
        try await database.write { db in
            try db.execute(
                sql: """
                    UPDATE canvas_documents
                    SET viewportX = ?, viewportY = ?, zoomLevel = ?, updatedAt = ?
                    WHERE id = ?
                """,
                arguments: [viewport.x, viewport.y, zoomLevel, Date(), canvasId.uuidString]
            )
        }
    }

    // MARK: - Canvas Creation

    /// Create a new canvas for a folder.
    func createCanvas(folderId: String, name: String? = nil) async throws -> CanvasDocument {
        let canvas = CanvasDocument(folderId: folderId, name: name)

        try await database.write { db in
            try canvas.insert(db)
        }

        return canvas
    }

    /// Get or create canvas for a folder.
    func getOrCreateCanvas(folderId: String) async throws -> CanvasDocument {
        try await database.write { db in
            try CanvasDocument.getOrCreate(db: db, folderId: folderId)
        }
    }

    /// Fetch canvas by ID.
    func fetchCanvas(id: UUID) async throws -> CanvasDocument? {
        try await database.read { db in
            try CanvasDocument.fetchOne(
                db,
                sql: "SELECT * FROM canvas_documents WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    // MARK: - Bounds Calculation

    /// Calculate bounding rect of all placements (for zoom-to-fit).
    func contentBounds() -> CGRect {
        guard !placements.isEmpty else {
            return CGRect(x: 0, y: 0, width: 1000, height: 1000)
        }

        var minX = CGFloat.infinity
        var minY = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var maxY = -CGFloat.infinity

        for placement in placements.values {
            minX = min(minX, placement.x)
            minY = min(minY, placement.y)
            maxX = max(maxX, placement.x + placement.width)
            maxY = max(maxY, placement.y + placement.height)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Calculate zoom level to fit all content in viewport.
    func zoomToFit(viewportSize: CGSize, padding: CGFloat = 50) -> (center: CGPoint, zoom: CGFloat) {
        let bounds = contentBounds()

        // Add padding
        let contentWidth = bounds.width + padding * 2
        let contentHeight = bounds.height + padding * 2

        // Calculate zoom to fit
        let zoomX = viewportSize.width / contentWidth
        let zoomY = viewportSize.height / contentHeight
        let zoom = min(zoomX, zoomY, 2.0) // Cap at 2x

        // Calculate center
        let center = CGPoint(
            x: bounds.midX,
            y: bounds.midY
        )

        return (center, zoom)
    }
}

// MARK: - Canvas Store

/// Standalone store for canvas operations using DatabaseManager directly
final class CanvasStore {
    private let database: DatabaseManager

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    /// Fetch all canvases
    func fetchCanvases() async throws -> [CanvasDocument] {
        try await database.read { db in
            try CanvasDocument
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    /// Delete a canvas and all its placements
    /// GAP #6 fix: Posts notification so CanvasLayoutManager instances can clear state
    func deleteCanvas(id: UUID) async throws {
        try await database.write { db in
            try db.execute(
                sql: "DELETE FROM canvas_documents WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
        // Notify so any CanvasLayoutManager can clear state if viewing this canvas
        await MainActor.run {
            NotificationCenter.default.post(name: .canvasDidDelete, object: nil, userInfo: ["canvasId": id])
        }
    }

    /// Save a canvas document
    func saveCanvas(_ canvas: CanvasDocument) async throws {
        try await database.write { db in
            try canvas.save(db)
        }
    }

    /// Fetch a single canvas by ID
    func fetchCanvas(id: UUID) async throws -> CanvasDocument? {
        try await database.read { db in
            try CanvasDocument
                .filter(Column("id") == id.uuidString)
                .fetchOne(db)
        }
    }
}
