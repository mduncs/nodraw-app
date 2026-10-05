import Foundation
import GRDB

// MARK: - CanvasDocument

/// A PureRef-style infinite canvas that can contain multiple media items
/// arranged spatially. Each folder can have one default canvas, or users
/// can create named canvases that span multiple folders.
struct CanvasDocument: Identifiable, Equatable {
    let id: UUID
    let folderId: String?       // nil for cross-folder canvases
    var name: String?
    var viewportX: CGFloat      // Viewport center X
    var viewportY: CGFloat      // Viewport center Y
    var zoomLevel: CGFloat
    var createdAt: Date
    var updatedAt: Date

    var viewport: CGPoint {
        get { CGPoint(x: viewportX, y: viewportY) }
        set {
            viewportX = newValue.x
            viewportY = newValue.y
        }
    }

    init(
        id: UUID = UUID(),
        folderId: String? = nil,
        name: String? = nil,
        viewportX: CGFloat = 0,
        viewportY: CGFloat = 0,
        zoomLevel: CGFloat = 1.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.folderId = folderId
        self.name = name
        self.viewportX = viewportX
        self.viewportY = viewportY
        self.zoomLevel = zoomLevel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - CanvasItemPlacement

/// Position and size of a media item on a canvas.
/// References MediaItem by ID - does not embed the item data.
struct CanvasItemPlacement: Identifiable, Equatable {
    let id: UUID
    let canvasId: UUID
    let mediaItemId: UUID
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var zIndex: Int
    var isManuallyPlaced: Bool
    var rotation: Double  // Rotation in degrees (Issue #11)

    var position: CGPoint {
        get { CGPoint(x: x, y: y) }
        set {
            x = newValue.x
            y = newValue.y
        }
    }

    var size: CGSize {
        get { CGSize(width: width, height: height) }
        set {
            width = newValue.width
            height = newValue.height
        }
    }

    var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(
        id: UUID = UUID(),
        canvasId: UUID,
        mediaItemId: UUID,
        x: CGFloat = 0,
        y: CGFloat = 0,
        width: CGFloat = 200,
        height: CGFloat = 200,
        zIndex: Int = 0,
        isManuallyPlaced: Bool = false,
        rotation: Double = 0
    ) {
        self.id = id
        self.canvasId = canvasId
        self.mediaItemId = mediaItemId
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.zIndex = zIndex
        self.isManuallyPlaced = isManuallyPlaced
        self.rotation = rotation
    }
}

// MARK: - CanvasLOD (Level of Detail)

/// Level of detail for canvas items based on zoom scale.
/// Lower zoom levels use smaller/simpler representations for performance.
enum CanvasLOD: Int, Comparable, CaseIterable {
    case dot = 0       // scale < 0.1: colored rectangle only
    case micro = 1     // scale 0.1-0.25: 32px thumbnail
    case thumb = 2     // scale 0.25-0.75: 128px thumbnail
    case preview = 3   // scale 0.75-1.5: 256px thumbnail
    case full = 4      // scale >= 1.5: original resolution

    static func forScale(_ scale: CGFloat) -> CanvasLOD {
        switch scale {
        case ..<0.1: return .dot
        case ..<0.25: return .micro
        case ..<0.75: return .thumb
        case ..<1.5: return .preview
        default: return .full
        }
    }

    /// Thumbnail size to load for this LOD level
    var thumbnailSize: ThumbnailGenerator.Size? {
        switch self {
        case .dot: return nil  // No thumbnail needed
        case .micro: return .small
        case .thumb: return .small
        case .preview: return .medium
        case .full: return .medium  // Full uses medium + original if needed
        }
    }

    /// Pixel size hint for this LOD (for cache keys)
    var pixelSize: Int {
        switch self {
        case .dot: return 0
        case .micro: return 32
        case .thumb: return 128
        case .preview: return 256
        case .full: return 800
        }
    }

    static func < (lhs: CanvasLOD, rhs: CanvasLOD) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - GRDB Record: CanvasDocument

extension CanvasDocument: FetchableRecord, PersistableRecord {
    static let databaseTableName = "canvas_documents"

    /// Association to placements
    static let placements = hasMany(CanvasItemPlacement.self)

    static func createTable(in db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("folderId", .text)
            t.column("name", .text)
            t.column("viewportX", .double).notNull().defaults(to: 0)
            t.column("viewportY", .double).notNull().defaults(to: 0)
            t.column("zoomLevel", .double).notNull().defaults(to: 1.0)
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull()
        }

        // Index for finding canvas by folder
        try db.create(
            index: "idx_canvas_documents_folder",
            on: databaseTableName,
            columns: ["folderId"],
            ifNotExists: true
        )
    }

    // MARK: - Custom Encoding

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["folderId"] = folderId
        container["name"] = name
        container["viewportX"] = viewportX
        container["viewportY"] = viewportY
        container["zoomLevel"] = zoomLevel
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
    }

    // MARK: - Custom Decoding

    init(row: Row) throws {
        guard let idString: String = row["id"],
              let id = UUID(uuidString: idString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid or missing UUID in id column"
                )
            )
        }
        self.id = id
        self.folderId = row["folderId"]
        self.name = row["name"]
        self.viewportX = row["viewportX"]
        self.viewportY = row["viewportY"]
        self.zoomLevel = row["zoomLevel"]
        self.createdAt = row["createdAt"]
        self.updatedAt = row["updatedAt"]
    }
}

// MARK: - GRDB Record: CanvasItemPlacement

extension CanvasItemPlacement: FetchableRecord, PersistableRecord {
    static let databaseTableName = "canvas_placements"

    /// Association to the canvas
    static let canvas = belongsTo(CanvasDocument.self)

    /// Association to the media item
    static let item = belongsTo(MediaItemRecord.self, using: ForeignKey(["mediaItemId"]))

    static func createTable(in db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("canvasId", .text).notNull()
                .references("canvas_documents", onDelete: .cascade)
            t.column("mediaItemId", .text).notNull()
                .references("media_items", onDelete: .cascade)
            t.column("x", .double).notNull()
            t.column("y", .double).notNull()
            t.column("width", .double).notNull()
            t.column("height", .double).notNull()
            t.column("zIndex", .integer).notNull().defaults(to: 0)
            t.column("isManuallyPlaced", .boolean).defaults(to: false)
            t.column("rotation", .double).defaults(to: 0)  // Issue #11: Rotation in degrees
            t.uniqueKey(["canvasId", "mediaItemId"])
        }

        // Index for fast canvas queries
        try db.create(
            index: "idx_canvas_placements_canvas",
            on: databaseTableName,
            columns: ["canvasId"],
            ifNotExists: true
        )

        // Index for finding placements by media item
        try db.create(
            index: "idx_canvas_placements_item",
            on: databaseTableName,
            columns: ["mediaItemId"],
            ifNotExists: true
        )
    }

    // MARK: - Custom Encoding

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["canvasId"] = canvasId.uuidString
        container["mediaItemId"] = mediaItemId.uuidString
        container["x"] = x
        container["y"] = y
        container["width"] = width
        container["height"] = height
        container["zIndex"] = zIndex
        container["isManuallyPlaced"] = isManuallyPlaced
        container["rotation"] = rotation
    }

    // MARK: - Custom Decoding

    init(row: Row) throws {
        guard let idString: String = row["id"],
              let id = UUID(uuidString: idString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid or missing UUID in id column"
                )
            )
        }
        guard let canvasIdString: String = row["canvasId"],
              let canvasId = UUID(uuidString: canvasIdString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid or missing UUID in canvasId column"
                )
            )
        }
        guard let mediaItemIdString: String = row["mediaItemId"],
              let mediaItemId = UUID(uuidString: mediaItemIdString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid or missing UUID in mediaItemId column"
                )
            )
        }
        self.id = id
        self.canvasId = canvasId
        self.mediaItemId = mediaItemId
        self.x = row["x"]
        self.y = row["y"]
        self.width = row["width"]
        self.height = row["height"]
        self.zIndex = row["zIndex"]
        self.isManuallyPlaced = row["isManuallyPlaced"]
        self.rotation = row["rotation"] ?? 0  // Default to 0 for existing records
    }
}

// MARK: - Request Helpers

extension CanvasDocument {
    /// Fetch canvas for a specific folder
    static func fetchForFolder(db: Database, folderId: String) throws -> CanvasDocument? {
        try CanvasDocument
            .filter(Column("folderId") == folderId)
            .fetchOne(db)
    }

    /// Fetch all user-created canvases (no folder association)
    static func fetchUserCanvases(db: Database) throws -> [CanvasDocument] {
        try CanvasDocument
            .filter(Column("folderId") == nil)
            .filter(Column("name") != nil)
            .order(Column("updatedAt").desc)
            .fetchAll(db)
    }

    /// Create or get existing canvas for a folder
    static func getOrCreate(db: Database, folderId: String) throws -> CanvasDocument {
        if let existing = try fetchForFolder(db: db, folderId: folderId) {
            return existing
        }

        let canvas = CanvasDocument(folderId: folderId)
        try canvas.insert(db)
        return canvas
    }

    /// Get placement count for this canvas
    func placementCount(db: Database) throws -> Int {
        try CanvasItemPlacement
            .filter(Column("canvasId") == id.uuidString)
            .fetchCount(db)
    }
}

extension CanvasItemPlacement {
    /// Fetch all placements for a canvas
    static func fetchForCanvas(db: Database, canvasId: UUID) throws -> [CanvasItemPlacement] {
        try CanvasItemPlacement
            .filter(Column("canvasId") == canvasId.uuidString)
            .order(Column("zIndex").asc)
            .fetchAll(db)
    }

    /// Fetch placements within a viewport rect (for virtualization)
    static func fetchInViewport(
        db: Database,
        canvasId: UUID,
        viewport: CGRect,
        buffer: CGFloat = 500
    ) throws -> [CanvasItemPlacement] {
        let expandedRect = viewport.insetBy(dx: -buffer, dy: -buffer)

        return try CanvasItemPlacement
            .filter(Column("canvasId") == canvasId.uuidString)
            // Item is visible if it overlaps the viewport
            // (x + width > left) AND (x < right) AND (y + height > top) AND (y < bottom)
            .filter(Column("x") + Column("width") > expandedRect.minX)
            .filter(Column("x") < expandedRect.maxX)
            .filter(Column("y") + Column("height") > expandedRect.minY)
            .filter(Column("y") < expandedRect.maxY)
            .order(Column("zIndex").asc)
            .fetchAll(db)
    }

    /// Get next available zIndex for a canvas
    static func nextZIndex(db: Database, canvasId: UUID) throws -> Int {
        let maxZ = try Int.fetchOne(
            db,
            sql: "SELECT MAX(zIndex) FROM canvas_placements WHERE canvasId = ?",
            arguments: [canvasId.uuidString]
        ) ?? -1
        return maxZ + 1
    }

    /// Bring placement to front (highest zIndex)
    mutating func bringToFront(db: Database) throws {
        let newZ = try CanvasItemPlacement.nextZIndex(db: db, canvasId: canvasId)
        zIndex = newZ
        try update(db)
    }
}
