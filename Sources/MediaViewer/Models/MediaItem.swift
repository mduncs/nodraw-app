import Foundation
import GRDB
import PhotoPipeline

/// Why an item was soft-deleted. `nil` represents rows created before deletion
/// provenance was recorded.
enum MediaItemDeletionReason: String, Codable, Sendable {
    case user
    case missingFiles
    case combined
    case contextReattached
}

/// The file role an item uses for its primary presentation in the library and focus view.
/// This is deliberately separate from the stored file roles: choosing Context never turns a
/// screenshot into downloaded media, and choosing Downloaded never discards the screenshot.
enum MediaItemDisplaySource: String, CaseIterable, Identifiable, Sendable {
    case downloaded
    case context

    var id: Self { self }

    var label: String {
        switch self {
        case .downloaded: "Downloaded"
        case .context: "Context"
        }
    }
}

/// Shared eligibility for actions that operate on whichever concrete asset is displayed.
/// Video playback supports more formats than the trim pipeline, so these sets must not be
/// inferred from `hasVideo` or `ThumbnailGenerator.isVideo`.
enum MediaItemDisplayActionPolicy {
    private static let trimmableExtensions: Set<String> = ["mp4", "mov", "m4v"]

    static func isTrimmable(_ sourceURL: URL?) -> Bool {
        guard let sourceURL else { return false }
        return trimmableExtensions.contains(sourceURL.pathExtension.lowercased())
    }
}

// MARK: - MetadataFileFingerprint

struct MetadataFileFingerprint: Equatable, Sendable {
    let modifiedAt: Double
    let fileSize: Int64

    static func current(for url: URL, fileManager: FileManager = .default) -> MetadataFileFingerprint? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modifiedDate = attributes[.modificationDate] as? Date else {
            return nil
        }

        let size: Int64
        if let number = attributes[.size] as? NSNumber {
            size = number.int64Value
        } else if let intSize = attributes[.size] as? Int64 {
            size = intSize
        } else {
            size = 0
        }

        return MetadataFileFingerprint(
            modifiedAt: modifiedDate.timeIntervalSince1970,
            fileSize: size
        )
    }
}

// MARK: - MediaItem

/// Core media item representing a single archived piece of content.
/// One tweet/post = one MediaItem, which may contain multiple media files.
struct MediaItem: Identifiable, Equatable, Hashable {
    let id: UUID
    let basePath: URL              // Directory containing this item
    let metadataFile: URL          // .md file with frontmatter
    var mediaFiles: [URL]          // .jpg, .mp4, .gif, .png (can be empty for orphan .md)
    var contextImage: URL?         // .context.png (screenshot of source)
    /// Stable references hydrated with one batch query, including shallow library rows.
    var assets: [ItemAsset] = []
    /// Presentation preference only. This never changes capture, analysis, or file-index roles.
    var prefersContextImage: Bool
    var metadata: MediaMetadata
    var indexedContent: IndexedContent?
    var aspectRatio: CGFloat?      // width/height ratio for layout calculations
    var parseStatus: ParseStatus   // Status of metadata parsing
    var parseErrors: [String]      // Errors from parsing (for debugging)
    var deletionReason: MediaItemDeletionReason?

    // ML pipeline fields
    var generatedCaption: String?  // ML-generated description
    var pipelineStatus: String?    // none, pending, processing, complete, failed
    var pipelineLastError: String?
    var pipelineFailedAt: String?
    var pipelineRetryCount: Int?

    // Native video understanding fields
    var videoUnderstandingStatus: String?
    var videoUnderstandingLastError: String?
    var videoUnderstandingFailedAt: String?
    var videoUnderstandingRetryCount: Int?
    var videoUnderstandingVersion: Int?

    // Local Parakeet transcription fields
    var transcriptionStatus: String?
    var transcriptionLastError: String?
    var transcriptionFailedAt: String?
    var transcriptionRetryCount: Int?
    var transcriptionVersion: Int?

    /// ML attribute scores (flattened from media_attributes EAV table)
    /// Keys are "module.key" (e.g. "quality.aesthetics", "curation.score")
    var mlAttributes: [String: Double] = [:]

    /// Per-file OCR data for carousel/multi-image support
    /// Key: file index (0-based), Value: OCR content for that file
    var perFileOCR: [Int: MediaFileOCR] = [:]

    /// Native timestamped video understanding segments.
    var videoSegments: [VideoSegment] = []

    /// Timestamped speech transcript segments from local transcription.
    var transcriptSegments: [TranscriptSegment] = []

    /// Default aspect ratios by content type
    private static let videoDefaultAspectRatio: CGFloat = 16.0 / 9.0  // 1.78
    private static let imageDefaultAspectRatio: CGFloat = 1.0         // square

    /// Effective aspect ratio for layout - never nil.
    /// Uses stored ratio if available, otherwise defaults based on content type:
    /// - Videos: 16:9 (1.78)
    /// - Images/unknown: 1:1 (1.0)
    var effectiveAspectRatio: CGFloat {
        if let ratio = aspectRatio {
            return ratio
        }
        return hasVideo ? Self.videoDefaultAspectRatio : Self.imageDefaultAspectRatio
    }

    /// Convenience: first media file (for thumbnail/preview)
    var primaryMedia: URL? {
        mediaFiles.first
    }

    /// Whether this item has both roles required for an explicit presentation swap.
    var hasSwappablePresentationSources: Bool {
        primaryMedia != nil && contextImage != nil
    }

    /// Sources the user can choose for presentation. Ordering matches the focused-view control.
    var availableDisplaySources: [MediaItemDisplaySource] {
        var sources: [MediaItemDisplaySource] = []
        if primaryMedia != nil {
            sources.append(.downloaded)
        }
        if contextImage != nil {
            sources.append(.context)
        }
        return sources
    }

    func canDisplay(_ source: MediaItemDisplaySource) -> Bool {
        switch source {
        case .downloaded: primaryMedia != nil
        case .context: contextImage != nil
        }
    }

    /// The effective choice after applying safe missing-source fallbacks. A stale database
    /// preference can therefore never make an otherwise displayable item appear empty.
    var effectiveDisplaySource: MediaItemDisplaySource? {
        if prefersContextImage, contextImage != nil {
            return .context
        }
        if primaryMedia != nil {
            return .downloaded
        }
        if contextImage != nil {
            return .context
        }
        return nil
    }

    /// Preferred presentation source. Missing-role fallbacks keep context-only and media-only
    /// items displayable even if a stale preference is present in the database.
    var preferredDisplaySource: URL? {
        switch effectiveDisplaySource {
        case .downloaded:
            return primaryMedia
        case .context:
            return contextImage
        case nil:
            return nil
        }
    }

    var isPreferredDisplaySourceTrimmable: Bool {
        MediaItemDisplayActionPolicy.isTrimmable(preferredDisplaySource)
    }

    /// Thumbnail source follows the presentation preference without mutating file roles.
    var thumbnailSource: URL? {
        preferredDisplaySource
    }

    /// Convenience: check if this item has video
    var hasVideo: Bool {
        primaryVideoMedia != nil
    }

    /// First video file in mediaFiles (use this instead of primaryMedia for video operations)
    var primaryVideoMedia: URL? {
        let videoExts: Set<String> = ["mp4", "mov", "webm", "m4v", "avi", "mkv"]
        return mediaFiles.first { videoExts.contains($0.pathExtension.lowercased()) }
    }

    /// Convenience: check if this item has audio-only media.
    var hasAudio: Bool {
        primaryAudioMedia != nil
    }

    /// First audio file in mediaFiles.
    var primaryAudioMedia: URL? {
        let audioExts: Set<String> = ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "caf"]
        return mediaFiles.first { audioExts.contains($0.pathExtension.lowercased()) }
    }

    /// First audio or video file that may contain speech.
    var primaryTranscribableMedia: URL? {
        primaryAudioMedia ?? primaryVideoMedia
    }

    /// Convenience: check if this item has media that can be considered for transcription.
    var hasTranscribableMedia: Bool {
        primaryTranscribableMedia != nil
    }

    /// Check if this is a metadata-only item (orphan .md with no media files)
    var isMetadataOnly: Bool {
        mediaFiles.isEmpty
    }

    /// Year-month folder name (e.g., "2025-12")
    var folderName: String {
        basePath.lastPathComponent
    }

    // MARK: - Sort Helpers (non-optional for Table column sorting)

    /// Author with empty string fallback for Comparable conformance
    var sortAuthor: String { metadata.author ?? "" }

    /// Original date with distant past fallback for Comparable conformance
    var sortOriginalDate: Date { metadata.originalDate ?? .distantPast }

    /// Download date with distant past fallback for Comparable conformance
    var sortDownloadDate: Date { metadata.downloadDate ?? .distantPast }

    /// Import date with distant past fallback for Comparable conformance
    var sortImportDate: Date { metadata.importDate ?? .distantPast }

    /// Upload date with distant past fallback for Comparable conformance
    var sortUploadDate: Date { metadata.uploadDate ?? .distantPast }

    /// Starred as Int for table column sorting (Bool isn't Comparable)
    var sortStarred: Int { metadata.starred ? 1 : 0 }

    /// Tag count for table column sorting
    var sortTagCount: Int { metadata.tags.count }

    /// Notes presence for table column sorting
    var sortNotes: String { metadata.notes ?? "" }

    /// Source URL string for table column sorting
    var sortSourceURL: String { metadata.source.absoluteString }

    /// Caption for table column sorting
    var sortCaption: String { generatedCaption ?? "" }

    /// OCR text for table column sorting
    var sortOCRText: String { combinedOCRText ?? "" }

    /// Aesthetics score for table column sorting
    var sortAesthetics: Double { mlAttributes["quality.aesthetics"] ?? 0 }

    /// Curation score for table column sorting
    var sortCuration: Double { mlAttributes["curation.score"] ?? 0 }

    /// Pipeline status for table column sorting
    var sortPipelineStatus: String { pipelineStatus ?? "none" }

    init(
        id: UUID,
        basePath: URL,
        metadataFile: URL,
        mediaFiles: [URL],
        contextImage: URL? = nil,
        prefersContextImage: Bool = false,
        metadata: MediaMetadata,
        indexedContent: IndexedContent? = nil,
        aspectRatio: CGFloat? = nil,
        parseStatus: ParseStatus = .success,
        parseErrors: [String] = [],
        deletionReason: MediaItemDeletionReason? = nil,
        generatedCaption: String? = nil,
        pipelineStatus: String? = nil,
        pipelineLastError: String? = nil,
        pipelineFailedAt: String? = nil,
        pipelineRetryCount: Int? = nil,
        videoUnderstandingStatus: String? = nil,
        videoUnderstandingLastError: String? = nil,
        videoUnderstandingFailedAt: String? = nil,
        videoUnderstandingRetryCount: Int? = nil,
        videoUnderstandingVersion: Int? = nil,
        transcriptionStatus: String? = nil,
        transcriptionLastError: String? = nil,
        transcriptionFailedAt: String? = nil,
        transcriptionRetryCount: Int? = nil,
        transcriptionVersion: Int? = nil,
        mlAttributes: [String: Double] = [:],
        perFileOCR: [Int: MediaFileOCR] = [:],
        videoSegments: [VideoSegment] = [],
        transcriptSegments: [TranscriptSegment] = [],
        assets: [ItemAsset] = []
    ) {
        self.id = id
        self.basePath = basePath
        self.metadataFile = metadataFile
        self.mediaFiles = mediaFiles
        self.contextImage = contextImage
        self.assets = assets
        self.prefersContextImage = prefersContextImage
        self.metadata = metadata
        self.indexedContent = indexedContent
        self.aspectRatio = aspectRatio
        self.parseStatus = parseStatus
        self.parseErrors = parseErrors
        self.deletionReason = deletionReason
        self.generatedCaption = generatedCaption
        self.pipelineStatus = pipelineStatus
        self.pipelineLastError = pipelineLastError
        self.pipelineFailedAt = pipelineFailedAt
        self.pipelineRetryCount = pipelineRetryCount
        self.videoUnderstandingStatus = videoUnderstandingStatus
        self.videoUnderstandingLastError = videoUnderstandingLastError
        self.videoUnderstandingFailedAt = videoUnderstandingFailedAt
        self.videoUnderstandingRetryCount = videoUnderstandingRetryCount
        self.videoUnderstandingVersion = videoUnderstandingVersion
        self.transcriptionStatus = transcriptionStatus
        self.transcriptionLastError = transcriptionLastError
        self.transcriptionFailedAt = transcriptionFailedAt
        self.transcriptionRetryCount = transcriptionRetryCount
        self.transcriptionVersion = transcriptionVersion
        self.mlAttributes = mlAttributes
        self.perFileOCR = perFileOCR
        self.videoSegments = videoSegments
        self.transcriptSegments = transcriptSegments
    }

    // MARK: - Per-File OCR Access

    /// Get OCR text for a specific file index.
    /// Falls back to legacy indexedContent.ocrText for file index 0 if no per-file data.
    func ocrText(forFileIndex index: Int) -> String? {
        // Check per-file OCR first - but fall through if value is nil
        if let fileOCR = perFileOCR[index], let text = fileOCR.ocrText {
            return text
        }

        // Backwards compat: if index 0 and legacy data exists, use it
        if assets.isEmpty, index == 0, let legacy = indexedContent?.ocrText {
            return legacy
        }

        return nil
    }

    /// Get OCR text blocks for a specific file index.
    /// Falls back to legacy indexedContent.ocrTextRegions for file index 0 if no per-file data.
    func ocrBlocks(forFileIndex index: Int) -> [SerializableTextBlock]? {
        // Check per-file OCR first - but fall through if blocks is nil
        if let fileOCR = perFileOCR[index], let blocks = fileOCR.ocrBlocks {
            return blocks
        }

        // Backwards compat: if index 0 and legacy data exists, wrap each region as a single-line block
        if assets.isEmpty, index == 0, let legacy = indexedContent?.ocrTextRegions {
            return legacy.map { region in
                SerializableTextBlock(
                    id: region.id.uuidString,
                    text: region.text,
                    lines: [SerializableTextObservation(
                        text: region.text,
                        boundingBox: region.boundingBox,
                        confidence: region.confidence
                    )],
                    boundingBox: region.boundingBox,
                    confidence: region.confidence,
                    role: TextRole.body.rawValue,
                    columnIndex: 0
                )
            }
        }

        return nil
    }

    /// Check if OCR data exists for a specific file index
    func hasOCR(forFileIndex index: Int) -> Bool {
        // Check per-file OCR - must have actual text or blocks
        if let fileOCR = perFileOCR[index] {
            if fileOCR.ocrText != nil || fileOCR.ocrBlocks != nil {
                return true
            }
            // Per-file record exists but has no data - fall through to legacy check
        }
        // Check legacy for index 0
        if assets.isEmpty, index == 0 {
            return indexedContent?.ocrText != nil || indexedContent?.ocrTextRegions != nil
        }
        return false
    }

    /// Get combined OCR text from all files (for search indexing)
    var combinedOCRText: String? {
        var texts: [String] = []

        // Add per-file OCR texts
        for index in perFileOCR.keys.sorted() {
            if let text = perFileOCR[index]?.ocrText {
                texts.append(text)
            }
        }

        // If no per-file data, fall back to legacy
        if texts.isEmpty, let legacy = indexedContent?.ocrText {
            return legacy
        }

        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }
}

// MARK: - MediaFileOCR

/// OCR data for a single media file within an item
struct MediaFileOCR: Codable, Equatable, Hashable {
    let fileIndex: Int
    let fileURL: String
    var ocrText: String?
    var ocrBlocks: [SerializableTextBlock]?

    init(fileIndex: Int, fileURL: String, ocrText: String? = nil, ocrBlocks: [SerializableTextBlock]? = nil) {
        self.fileIndex = fileIndex
        self.fileURL = fileURL
        self.ocrText = ocrText
        self.ocrBlocks = ocrBlocks
    }
}

// MARK: - MediaFileOCRRecord (GRDB)

/// Database record for per-file OCR data
struct MediaFileOCRRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "media_file_ocr"

    let id: UUID
    let itemId: UUID
    let fileURL: String
    let fileIndex: Int
    var assetID: UUID?
    var ocrText: String?
    var ocrRegionsJSON: String?

    init(id: UUID = UUID(), itemId: UUID, fileURL: String, fileIndex: Int, ocrText: String? = nil, ocrBlocks: [SerializableTextBlock]? = nil, assetID: UUID? = nil) {
        self.id = id
        self.itemId = itemId
        self.fileURL = fileURL
        self.fileIndex = fileIndex
        self.assetID = assetID
        self.ocrText = ocrText
        self.ocrRegionsJSON = ocrBlocks.flatMap { blocks in
            (try? JSONEncoder().encode(blocks)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    // MARK: - GRDB PersistableRecord

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["item_id"] = itemId.uuidString
        container["file_url"] = fileURL
        container["file_index"] = fileIndex
        container["asset_id"] = assetID?.uuidString
        container["ocr_text"] = ocrText
        container["ocr_regions_json"] = ocrRegionsJSON
    }

    // MARK: - GRDB FetchableRecord

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
        guard let itemIdString: String = row["item_id"],
              let itemId = UUID(uuidString: itemIdString) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Invalid or missing UUID in item_id column"
                )
            )
        }
        self.id = id
        self.itemId = itemId
        self.fileURL = row["file_url"]
        self.fileIndex = row["file_index"]
        self.assetID = (row["asset_id"] as String?).flatMap(UUID.init(uuidString:))
        self.ocrText = row["ocr_text"]
        self.ocrRegionsJSON = row["ocr_regions_json"]
    }

    // MARK: - Conversion

    func toMediaFileOCR() -> MediaFileOCR {
        let blocks: [SerializableTextBlock]? = ocrRegionsJSON.flatMap { json in
            try? JSONDecoder().decode([SerializableTextBlock].self, from: Data(json.utf8))
        }
        return MediaFileOCR(
            fileIndex: fileIndex,
            fileURL: fileURL,
            ocrText: ocrText,
            ocrBlocks: blocks
        )
    }

    // MARK: - Static Fetch Methods

    /// Fetch all OCR records for a given item ID
    static func fetchAll(db: Database, itemId: UUID) throws -> [MediaFileOCRRecord] {
        try MediaFileOCRRecord.fetchAll(
            db,
            sql: "SELECT * FROM media_file_ocr WHERE item_id = ? AND association_state = 'attached' ORDER BY file_index",
            arguments: [itemId.uuidString]
        )
    }

    /// Fetch OCR record for a specific file index
    static func fetch(db: Database, itemId: UUID, fileIndex: Int) throws -> MediaFileOCRRecord? {
        try MediaFileOCRRecord.fetchOne(
            db,
            sql: "SELECT * FROM media_file_ocr WHERE item_id = ? AND file_index = ? AND association_state = 'attached'",
            arguments: [itemId.uuidString, fileIndex]
        )
    }

    /// Delete all OCR records for an item
    static func deleteAll(db: Database, itemId: UUID) throws {
        try db.execute(
            sql: "DELETE FROM media_file_ocr WHERE item_id = ? AND association_state = 'attached'",
            arguments: [itemId.uuidString]
        )
    }

    /// Upsert (insert or replace) OCR data for a file
    func upsert(db: Database) throws {
        let asset = try ItemAssetStore.prepareWrite(in: db, itemID: itemId, assetID: assetID, path: fileURL, index: fileIndex)
        try db.execute(
            sql: """
                INSERT INTO media_file_ocr (id, item_id, file_url, file_index, ocr_text, ocr_regions_json, asset_id, association_state)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'attached')
                ON CONFLICT(item_id, file_index) DO UPDATE SET
                    file_url = excluded.file_url,
                    ocr_text = excluded.ocr_text,
                    ocr_regions_json = excluded.ocr_regions_json,
                    asset_id = excluded.asset_id, association_state = 'attached'
            """,
            arguments: [id.uuidString, itemId.uuidString, asset.path, asset.index, ocrText, ocrRegionsJSON, asset.id.uuidString]
        )
    }
}

// MARK: - MediaMetadata

/// Parsed frontmatter from .md files + user-added data
struct MediaMetadata: Codable, Equatable, Hashable {
    let source: URL                // Original URL
    let platform: String           // twitter, instagram, etc
    let author: String?            // @username or display name
    let originalDate: Date?        // When content was created
    let archivedDate: Date         // When we archived it
    let downloadDate: Date?        // When we downloaded it from the source
    let importDate: Date?          // When we imported it into the library
    let originalDateString: String? // Original date string for debugging ambiguous formats

    // User-editable fields
    var starred: Bool
    var tags: [String]
    var notes: String?

    // Vault-persisted state flags (written by WriteBackQueue, parsed on DB rebuild)
    var deleted: Bool            // soft-delete flag from frontmatter
    var annotated: Bool          // true if annotations exist (informational)

    // Source context fields (for auto-tagging rules)
    var subreddit: String?
    var boardName: String?
    var blogName: String?
    var channelName: String?
    var artistName: String?
    var galleryName: String?
    var sourceTags: [String]?    // tags from the source platform (not user tags)
    var uploadDate: Date?
    var viewCount: Int?
    var likeCount: Int?

    init(
        source: URL,
        platform: String,
        author: String? = nil,
        originalDate: Date? = nil,
        archivedDate: Date = Date(),
        downloadDate: Date? = nil,
        importDate: Date? = nil,
        starred: Bool = false,
        tags: [String] = [],
        notes: String? = nil,
        originalDateString: String? = nil,
        deleted: Bool = false,
        annotated: Bool = false,
        subreddit: String? = nil,
        boardName: String? = nil,
        blogName: String? = nil,
        channelName: String? = nil,
        artistName: String? = nil,
        galleryName: String? = nil,
        sourceTags: [String]? = nil,
        uploadDate: Date? = nil,
        viewCount: Int? = nil,
        likeCount: Int? = nil
    ) {
        self.source = source
        self.platform = platform
        self.author = author
        self.originalDate = originalDate
        self.archivedDate = archivedDate
        self.downloadDate = downloadDate
        self.importDate = importDate
        self.starred = starred
        self.tags = tags
        self.notes = notes
        self.originalDateString = originalDateString
        self.deleted = deleted
        self.annotated = annotated
        self.subreddit = subreddit
        self.boardName = boardName
        self.blogName = blogName
        self.channelName = channelName
        self.artistName = artistName
        self.galleryName = galleryName
        self.sourceTags = sourceTags
        self.uploadDate = uploadDate
        self.viewCount = viewCount
        self.likeCount = likeCount
    }
}

// MARK: - IndexedContent

/// Content extracted by Vision framework processing
struct IndexedContent: Codable, Equatable, Hashable {
    let ocrText: String?                    // Recognized text
    let ocrTextRegions: [OCRTextRegion]?    // Bounding boxes for each detected text region
    let dominantColors: [ColorBucket]       // Simplified color classification
    let perceptualHash: String?             // For duplicate detection
    let saliencyRect: SerializableCGRect?   // Interest region for smart thumbnails

    init(
        ocrText: String? = nil,
        ocrTextRegions: [OCRTextRegion]? = nil,
        dominantColors: [ColorBucket] = [],
        perceptualHash: String? = nil,
        saliencyRect: CGRect? = nil
    ) {
        self.ocrText = ocrText
        self.ocrTextRegions = ocrTextRegions
        self.dominantColors = dominantColors
        self.perceptualHash = perceptualHash
        self.saliencyRect = saliencyRect.map { SerializableCGRect(rect: $0) }
    }

    var cgSaliencyRect: CGRect? {
        saliencyRect?.cgRect
    }
}

// MARK: - OCRTextRegion

/// A detected text region with its bounding box and content.
/// Coordinates are normalized (0-1) in Vision coordinate system (origin bottom-left).
struct OCRTextRegion: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    let text: String
    let boundingBox: SerializableCGRect  // Normalized 0-1 coordinates (Vision: origin bottom-left)
    let confidence: Float

    init(text: String, boundingBox: CGRect, confidence: Float) {
        self.id = UUID()
        self.text = text
        self.boundingBox = SerializableCGRect(rect: boundingBox)
        self.confidence = confidence
    }

    /// Convert Vision coordinates (origin bottom-left) to SwiftUI coordinates (origin top-left)
    /// for rendering overlays on images.
    /// - Parameter imageSize: The actual image size in points
    /// - Returns: CGRect in SwiftUI coordinate space
    func swiftUIRect(imageSize: CGSize) -> CGRect {
        let box = boundingBox.cgRect
        // Vision: origin bottom-left, normalized 0-1
        // SwiftUI: origin top-left, actual pixels
        return CGRect(
            x: box.origin.x * imageSize.width,
            y: (1 - box.origin.y - box.height) * imageSize.height,
            width: box.width * imageSize.width,
            height: box.height * imageSize.height
        )
    }
}

// MARK: - SerializableTextBlock

/// Codable wrapper for PhotoPipeline's TextBlock for JSON storage in the database.
/// TextBlock itself is not Codable, so we serialize/deserialize through this.
struct SerializableTextBlock: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let text: String
    let lines: [SerializableTextObservation]
    let boundingBox: SerializableCGRect
    let confidence: Float
    let role: String  // TextRole.rawValue
    let columnIndex: Int

    init(id: String, text: String, lines: [SerializableTextObservation], boundingBox: SerializableCGRect, confidence: Float, role: String, columnIndex: Int) {
        self.id = id
        self.text = text
        self.lines = lines
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.role = role
        self.columnIndex = columnIndex
    }

    init(from block: TextBlock) {
        self.id = block.id
        self.text = block.text
        self.lines = block.lines.map { SerializableTextObservation(from: $0) }
        self.boundingBox = SerializableCGRect(rect: block.boundingBox)
        self.confidence = block.confidence
        self.role = block.role.rawValue
        self.columnIndex = block.columnIndex
    }

    /// Convert Vision coordinates (origin bottom-left) to SwiftUI coordinates (origin top-left)
    func swiftUIRect(imageSize: CGSize) -> CGRect {
        let box = boundingBox.cgRect
        return CGRect(
            x: box.origin.x * imageSize.width,
            y: (1 - box.origin.y - box.height) * imageSize.height,
            width: box.width * imageSize.width,
            height: box.height * imageSize.height
        )
    }

    /// Get the TextRole enum value
    var textRole: TextRole {
        TextRole(rawValue: role) ?? .body
    }
}

/// Codable wrapper for PhotoPipeline's TextObservation
struct SerializableTextObservation: Codable, Equatable, Hashable {
    let text: String
    let boundingBox: SerializableCGRect
    let confidence: Float

    init(text: String, boundingBox: SerializableCGRect, confidence: Float) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }

    init(from obs: TextObservation) {
        self.text = obs.text
        self.boundingBox = SerializableCGRect(rect: obs.boundingBox)
        self.confidence = obs.confidence
    }

    /// Convert Vision coordinates to SwiftUI coordinates
    func swiftUIRect(imageSize: CGSize) -> CGRect {
        let box = boundingBox.cgRect
        return CGRect(
            x: box.origin.x * imageSize.width,
            y: (1 - box.origin.y - box.height) * imageSize.height,
            width: box.width * imageSize.width,
            height: box.height * imageSize.height
        )
    }
}

/// Color classification for filtering
/// Specific hues plus neutral tones. Warm/cool are aggregate categories.
enum ColorBucket: String, Codable, CaseIterable {
    // Specific hues
    case red
    case orange
    case yellow
    case green
    case cyan
    case blue
    case purple
    case pink
    case brown

    // Neutrals
    case black
    case white
    case gray

    /// Display name for UI
    var displayName: String {
        rawValue.capitalized
    }

    /// Color for UI representation - muted pastels that work on dark backgrounds
    var uiColor: (red: Double, green: Double, blue: Double) {
        switch self {
        case .red:    return (0.75, 0.40, 0.40)   // muted rose
        case .orange: return (0.80, 0.55, 0.35)   // muted peach
        case .yellow: return (0.80, 0.75, 0.45)   // muted gold
        case .green:  return (0.45, 0.65, 0.45)   // muted sage
        case .cyan:   return (0.45, 0.65, 0.70)   // muted teal
        case .blue:   return (0.50, 0.58, 0.75)   // muted slate blue
        case .purple: return (0.60, 0.50, 0.70)   // muted lavender
        case .pink:   return (0.75, 0.55, 0.62)   // muted blush
        case .brown:  return (0.55, 0.45, 0.38)   // muted taupe
        case .black:  return (0.25, 0.25, 0.28)   // soft charcoal
        case .white:  return (0.85, 0.85, 0.83)   // warm off-white
        case .gray:   return (0.50, 0.50, 0.52)   // neutral gray
        }
    }

    /// Warm colors (reds, oranges, yellows, pinks, browns)
    static let warmColors: Set<ColorBucket> = [.red, .orange, .yellow, .pink, .brown]

    /// Cool colors (greens, cyans, blues, purples)
    static let coolColors: Set<ColorBucket> = [.green, .cyan, .blue, .purple]

    /// Neutral colors (black, white, gray)
    static let neutralColors: Set<ColorBucket> = [.black, .white, .gray]

    /// Specific hues (excludes neutrals)
    static let hueColors: [ColorBucket] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .brown]
}

/// CGRect wrapper for Codable conformance
struct SerializableCGRect: Codable, Equatable, Hashable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - GRDB Records

/// Database record for MediaItem (without the computed URL properties)
struct MediaItemRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    static let databaseTableName = "media_items"

    let id: UUID
    let basePathString: String
    let metadataFileString: String
    let mediaFilesJSON: String      // JSON array of paths
    let contextImageString: String? // Optional path
    var prefersContextImage: Bool   // Presentation role only; files retain their original roles

    // Flattened metadata
    let sourceURL: String
    let platform: String
    let author: String?
    let originalDate: Date?
    let archivedDate: Date
    var downloadDate: Date?
    var importDate: Date?
    var starred: Bool
    var tagsJSON: String            // JSON array
    var notes: String?
    var originalDateString: String? // Original date string for debugging

    // Flattened indexed content (nullable - not yet processed)
    var ocrText: String?
    var ocrBoundingBoxesJSON: String? // JSON array of OCRTextRegion
    var dominantColorsJSON: String? // JSON array of ColorBucket raw values
    var perceptualHash: String?
    var saliencyRectJSON: String?   // JSON object

    // Source context (for auto-tagging)
    var subreddit: String?
    var boardName: String?
    var blogName: String?
    var channelName: String?
    var artistName: String?
    var galleryName: String?
    var sourceTagsJSON: String?     // JSON array of source platform tags
    var uploadDate: Date?
    var viewCount: Int?
    var likeCount: Int?


    // Soft-delete timestamp (nil = not deleted)
    var deletedAt: Date?
    var deletionReason: String?

    // Layout metadata
    var aspectRatio: Double?        // width/height for masonry layout

    // ML pipeline
    var generatedCaption: String?
    var pipelineStatus: String?
    var pipelineLastError: String?
    var pipelineFailedAt: String?
    var pipelineRetryCount: Int?
    var videoUnderstandingStatus: String?
    var videoUnderstandingLastError: String?
    var videoUnderstandingFailedAt: String?
    var videoUnderstandingRetryCount: Int?
    var videoUnderstandingVersion: Int?
    var transcriptionStatus: String?
    var transcriptionLastError: String?
    var transcriptionFailedAt: String?
    var transcriptionRetryCount: Int?
    var transcriptionVersion: Int?

    // Parse status
    var parseStatus: String         // success, partial, failed
    var parseErrorsJSON: String?    // JSON array of error strings

    init(from item: MediaItem) {
        self.id = item.id
        self.basePathString = item.basePath.path
        self.metadataFileString = item.metadataFile.path
        self.mediaFilesJSON = (try? JSONEncoder().encode(item.mediaFiles.map(\.path)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        self.contextImageString = item.contextImage?.path
        self.prefersContextImage = item.prefersContextImage

        self.sourceURL = item.metadata.source.absoluteString
        self.platform = item.metadata.platform
        self.author = item.metadata.author
        self.originalDate = item.metadata.originalDate
        self.archivedDate = item.metadata.archivedDate
        self.downloadDate = item.metadata.downloadDate
        self.importDate = item.metadata.importDate
        self.starred = item.metadata.starred
        self.tagsJSON = (try? JSONEncoder().encode(item.metadata.tags))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        self.notes = item.metadata.notes
        self.originalDateString = item.metadata.originalDateString

        self.subreddit = item.metadata.subreddit
        self.boardName = item.metadata.boardName
        self.blogName = item.metadata.blogName
        self.channelName = item.metadata.channelName
        self.artistName = item.metadata.artistName
        self.galleryName = item.metadata.galleryName
        self.sourceTagsJSON = item.metadata.sourceTags.flatMap { tags in
            (try? JSONEncoder().encode(tags)).flatMap { String(data: $0, encoding: .utf8) }
        }
        self.uploadDate = item.metadata.uploadDate
        self.viewCount = item.metadata.viewCount
        self.likeCount = item.metadata.likeCount

        if let indexed = item.indexedContent {
            self.ocrText = indexed.ocrText
            self.ocrBoundingBoxesJSON = indexed.ocrTextRegions.flatMap { regions in
                (try? JSONEncoder().encode(regions)).flatMap { String(data: $0, encoding: .utf8) }
            }
            self.dominantColorsJSON = (try? JSONEncoder().encode(indexed.dominantColors.map(\.rawValue)))
                .flatMap { String(data: $0, encoding: .utf8) }
            self.perceptualHash = indexed.perceptualHash
            self.saliencyRectJSON = indexed.saliencyRect.flatMap { rect in
                (try? JSONEncoder().encode(rect)).flatMap { String(data: $0, encoding: .utf8) }
            }
        } else {
            self.ocrText = nil
            self.ocrBoundingBoxesJSON = nil
            self.dominantColorsJSON = nil
            self.perceptualHash = nil
            self.saliencyRectJSON = nil
        }

        // Derive deletedAt from metadata.deleted flag
        // Note: loses original timestamp, but prevents the un-delete bug
        // where updateItem() would null out deletedAt
        self.deletedAt = item.metadata.deleted ? Date() : nil
        self.deletionReason = item.deletionReason?.rawValue

        self.aspectRatio = item.aspectRatio.map { Double($0) }
        self.generatedCaption = item.generatedCaption
        self.pipelineStatus = item.pipelineStatus ?? "none"
        self.videoUnderstandingStatus = item.videoUnderstandingStatus ?? "none"
        self.videoUnderstandingVersion = item.videoUnderstandingVersion ?? 0
        self.videoUnderstandingRetryCount = item.videoUnderstandingRetryCount ?? 0
        self.videoUnderstandingLastError = item.videoUnderstandingLastError
        self.videoUnderstandingFailedAt = item.videoUnderstandingFailedAt
        self.transcriptionStatus = item.transcriptionStatus ?? "none"
        self.transcriptionVersion = item.transcriptionVersion ?? 0
        self.transcriptionRetryCount = item.transcriptionRetryCount ?? 0
        self.transcriptionLastError = item.transcriptionLastError
        self.transcriptionFailedAt = item.transcriptionFailedAt
        self.parseStatus = item.parseStatus.rawValue
        self.parseErrorsJSON = item.parseErrors.isEmpty ? nil :
            (try? JSONEncoder().encode(item.parseErrors))
                .flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - GRDB PersistableRecord (custom encoding for UUID as string)

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["basePathString"] = basePathString
        container["metadataFileString"] = metadataFileString
        container["mediaFilesJSON"] = mediaFilesJSON
        container["contextImageString"] = contextImageString
        container["prefersContextImage"] = prefersContextImage
        container["sourceURL"] = sourceURL
        container["platform"] = platform
        container["author"] = author
        container["originalDate"] = originalDate
        container["archivedDate"] = archivedDate
        container["downloadDate"] = downloadDate
        container["importDate"] = importDate
        container["starred"] = starred
        container["tagsJSON"] = tagsJSON
        container["notes"] = notes
        container["originalDateString"] = originalDateString
        container["subreddit"] = subreddit
        container["boardName"] = boardName
        container["blogName"] = blogName
        container["channelName"] = channelName
        container["artistName"] = artistName
        container["galleryName"] = galleryName
        container["sourceTagsJSON"] = sourceTagsJSON
        container["uploadDate"] = uploadDate
        container["viewCount"] = viewCount
        container["likeCount"] = likeCount
        container["ocrText"] = ocrText
        container["ocrBoundingBoxesJSON"] = ocrBoundingBoxesJSON
        container["dominantColorsJSON"] = dominantColorsJSON
        container["perceptualHash"] = perceptualHash
        container["saliencyRectJSON"] = saliencyRectJSON
        container["deletedAt"] = deletedAt
        container["deletionReason"] = deletionReason
        container["aspectRatio"] = aspectRatio
        container["generatedCaption"] = generatedCaption
        container["pipeline_status"] = pipelineStatus
        container["video_understanding_status"] = videoUnderstandingStatus
        container["video_understanding_version"] = videoUnderstandingVersion
        container["video_understanding_retry_count"] = videoUnderstandingRetryCount
        container["video_understanding_last_error"] = videoUnderstandingLastError
        container["video_understanding_failed_at"] = videoUnderstandingFailedAt
        container["transcription_status"] = transcriptionStatus
        container["transcription_version"] = transcriptionVersion
        container["transcription_retry_count"] = transcriptionRetryCount
        container["transcription_last_error"] = transcriptionLastError
        container["transcription_failed_at"] = transcriptionFailedAt
        container["parseStatus"] = parseStatus
        container["parseErrorsJSON"] = parseErrorsJSON
    }

    // MARK: - GRDB FetchableRecord (custom decoding for UUID from string)

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
        self.basePathString = row["basePathString"]
        self.metadataFileString = row["metadataFileString"]
        self.mediaFilesJSON = row["mediaFilesJSON"]
        self.contextImageString = row["contextImageString"]
        self.prefersContextImage = row["prefersContextImage"]
        self.sourceURL = row["sourceURL"]
        self.platform = row["platform"]
        self.author = row["author"]
        self.originalDate = row["originalDate"]
        self.archivedDate = row["archivedDate"]
        self.downloadDate = row["downloadDate"]
        self.importDate = row["importDate"]
        self.starred = row["starred"]
        self.tagsJSON = row["tagsJSON"]
        self.notes = row["notes"]
        self.originalDateString = row["originalDateString"]
        self.subreddit = row["subreddit"]
        self.boardName = row["boardName"]
        self.blogName = row["blogName"]
        self.channelName = row["channelName"]
        self.artistName = row["artistName"]
        self.galleryName = row["galleryName"]
        self.sourceTagsJSON = row["sourceTagsJSON"]
        self.uploadDate = row["uploadDate"]
        self.viewCount = row["viewCount"]
        self.likeCount = row["likeCount"]
        self.ocrText = row["ocrText"]
        self.ocrBoundingBoxesJSON = row["ocrBoundingBoxesJSON"]
        self.dominantColorsJSON = row["dominantColorsJSON"]
        self.perceptualHash = row["perceptualHash"]
        self.saliencyRectJSON = row["saliencyRectJSON"]
        self.deletedAt = row["deletedAt"]
        self.deletionReason = row["deletionReason"]
        self.aspectRatio = row["aspectRatio"]
        self.generatedCaption = row["generatedCaption"]
        self.pipelineStatus = row["pipeline_status"]
        self.pipelineLastError = row["pipeline_last_error"]
        self.pipelineFailedAt = row["pipeline_failed_at"]
        self.pipelineRetryCount = row["pipeline_retry_count"]
        self.videoUnderstandingStatus = row["video_understanding_status"]
        self.videoUnderstandingLastError = row["video_understanding_last_error"]
        self.videoUnderstandingFailedAt = row["video_understanding_failed_at"]
        self.videoUnderstandingRetryCount = row["video_understanding_retry_count"]
        self.videoUnderstandingVersion = row["video_understanding_version"]
        self.transcriptionStatus = row["transcription_status"]
        self.transcriptionLastError = row["transcription_last_error"]
        self.transcriptionFailedAt = row["transcription_failed_at"]
        self.transcriptionRetryCount = row["transcription_retry_count"]
        self.transcriptionVersion = row["transcription_version"]
        self.parseStatus = row["parseStatus"]
        self.parseErrorsJSON = row["parseErrorsJSON"]
    }

    func toMediaItem() -> MediaItem? {
        guard let source = URL(string: sourceURL) else { return nil }

        let mediaFiles: [URL] = (try? JSONDecoder().decode([String].self, from: Data(mediaFilesJSON.utf8)))
            .map { $0.map { URL(fileURLWithPath: $0) } } ?? []

        let tags: [String] = (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? []

        let sourceTags: [String]? = sourceTagsJSON.flatMap { json in
            try? JSONDecoder().decode([String].self, from: Data(json.utf8))
        }

        let metadata = MediaMetadata(
            source: source,
            platform: platform,
            author: author,
            originalDate: originalDate,
            archivedDate: archivedDate,
            downloadDate: downloadDate,
            importDate: importDate,
            starred: starred,
            tags: tags,
            notes: notes,
            originalDateString: originalDateString,
            deleted: deletedAt != nil,
            subreddit: subreddit,
            boardName: boardName,
            blogName: blogName,
            channelName: channelName,
            artistName: artistName,
            galleryName: galleryName,
            sourceTags: sourceTags,
            uploadDate: uploadDate,
            viewCount: viewCount,
            likeCount: likeCount
        )

        var indexedContent: IndexedContent? = nil
        if ocrText != nil || ocrBoundingBoxesJSON != nil || dominantColorsJSON != nil || perceptualHash != nil {
            let colors: [ColorBucket] = dominantColorsJSON.flatMap { json in
                (try? JSONDecoder().decode([String].self, from: Data(json.utf8)))
                    .map { $0.compactMap { ColorBucket(rawValue: $0) } }
            } ?? []

            let textRegions: [OCRTextRegion]? = ocrBoundingBoxesJSON.flatMap { json in
                let data = Data(json.utf8)

                // Preferred legacy format: OCRTextRegion[]
                if let regions = try? JSONDecoder().decode([OCRTextRegion].self, from: data) {
                    return regions
                }

                // Compatibility: some versions wrote SerializableTextBlock[] to this column.
                if let blocks = try? JSONDecoder().decode([SerializableTextBlock].self, from: data) {
                    return blocks.map { block in
                        OCRTextRegion(
                            text: block.text,
                            boundingBox: block.boundingBox.cgRect,
                            confidence: block.confidence
                        )
                    }
                }

                return nil
            }

            let saliencyRect: SerializableCGRect? = saliencyRectJSON.flatMap { json in
                try? JSONDecoder().decode(SerializableCGRect.self, from: Data(json.utf8))
            }

            indexedContent = IndexedContent(
                ocrText: ocrText,
                ocrTextRegions: textRegions,
                dominantColors: colors,
                perceptualHash: perceptualHash,
                saliencyRect: saliencyRect?.cgRect
            )
        }

        let status = ParseStatus(rawValue: parseStatus) ?? .success
        let errors: [String] = parseErrorsJSON.flatMap { json in
            try? JSONDecoder().decode([String].self, from: Data(json.utf8))
        } ?? []

        return MediaItem(
            id: id,
            basePath: URL(fileURLWithPath: basePathString),
            metadataFile: URL(fileURLWithPath: metadataFileString),
            mediaFiles: mediaFiles,
            contextImage: contextImageString.map { URL(fileURLWithPath: $0) },
            prefersContextImage: prefersContextImage,
            metadata: metadata,
            indexedContent: indexedContent,
            aspectRatio: aspectRatio.map { CGFloat($0) },
            parseStatus: status,
            parseErrors: errors,
            deletionReason: deletionReason.flatMap(MediaItemDeletionReason.init(rawValue:)),
            generatedCaption: generatedCaption,
            pipelineStatus: pipelineStatus,
            pipelineLastError: pipelineLastError,
            pipelineFailedAt: pipelineFailedAt,
            pipelineRetryCount: pipelineRetryCount,
            videoUnderstandingStatus: videoUnderstandingStatus,
            videoUnderstandingLastError: videoUnderstandingLastError,
            videoUnderstandingFailedAt: videoUnderstandingFailedAt,
            videoUnderstandingRetryCount: videoUnderstandingRetryCount,
            videoUnderstandingVersion: videoUnderstandingVersion,
            transcriptionStatus: transcriptionStatus,
            transcriptionLastError: transcriptionLastError,
            transcriptionFailedAt: transcriptionFailedAt,
            transcriptionRetryCount: transcriptionRetryCount,
            transcriptionVersion: transcriptionVersion
        )
    }

    /// Convert to MediaItem with per-file OCR data and ML attributes
    func toMediaItem(
        withPerFileOCR perFileOCR: [Int: MediaFileOCR],
        mlAttributes: [String: Double] = [:],
        videoSegments: [VideoSegment] = [],
        transcriptSegments: [TranscriptSegment] = [],
        assets: [ItemAsset] = []
    ) -> MediaItem? {
        guard var item = toMediaItem() else { return nil }
        item.perFileOCR = perFileOCR
        item.mlAttributes = mlAttributes
        item.videoSegments = videoSegments
        item.transcriptSegments = transcriptSegments
        item.assets = assets
        return item
    }
}

// MARK: - Database Schema

extension MediaItemRecord {
    static func createTable(in db: Database) throws {
        try db.create(table: databaseTableName, ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("basePathString", .text).notNull()
            t.column("metadataFileString", .text).notNull().unique()
            t.column("mediaFilesJSON", .text).notNull()
            t.column("contextImageString", .text)
            t.column("prefersContextImage", .boolean).notNull().defaults(to: false)

            t.column("sourceURL", .text).notNull()
            t.column("platform", .text).notNull()
            t.column("author", .text)
            t.column("originalDate", .datetime)
            t.column("archivedDate", .datetime).notNull()
            t.column("downloadDate", .datetime)
            t.column("importDate", .datetime)
            t.column("starred", .boolean).notNull().defaults(to: false)
            t.column("tagsJSON", .text).notNull().defaults(to: "[]")
            t.column("notes", .text)
            t.column("originalDateString", .text)

            // Source context (for auto-tagging)
            t.column("subreddit", .text)
            t.column("boardName", .text)
            t.column("blogName", .text)
            t.column("channelName", .text)
            t.column("artistName", .text)
            t.column("galleryName", .text)
            t.column("sourceTagsJSON", .text)
            t.column("uploadDate", .datetime)
            t.column("viewCount", .integer)
            t.column("likeCount", .integer)

            t.column("ocrText", .text)
            t.column("ocrBoundingBoxesJSON", .text)
            t.column("dominantColorsJSON", .text)
            t.column("perceptualHash", .text)
            t.column("saliencyRectJSON", .text)

            // Soft-delete (migration 2)
            t.column("deletedAt", .datetime)
            t.column("deletionReason", .text)

            t.column("aspectRatio", .double)

            // ML pipeline
            t.column("generatedCaption", .text)
            t.column("pipeline_status", .text).defaults(to: "none")
            t.column("pipeline_version", .integer).defaults(to: 0)
            t.column("pipeline_retry_count", .integer).defaults(to: 0)

            // Native video understanding
            t.column("video_understanding_status", .text).defaults(to: "none")
            t.column("video_understanding_version", .integer).defaults(to: 0)
            t.column("video_understanding_retry_count", .integer).defaults(to: 0)
            t.column("video_understanding_last_error", .text)
            t.column("video_understanding_failed_at", .text)

            // Local Parakeet transcription
            t.column("transcription_status", .text).defaults(to: "none")
            t.column("transcription_version", .integer).defaults(to: 0)
            t.column("transcription_retry_count", .integer).defaults(to: 0)
            t.column("transcription_last_error", .text)
            t.column("transcription_failed_at", .text)

            // Parse status tracking
            t.column("parseStatus", .text).notNull().defaults(to: "success")
            t.column("parseErrorsJSON", .text)
        }

        // Indexes for common queries
        try db.create(index: "idx_media_items_platform", on: databaseTableName, columns: ["platform"], ifNotExists: true)
        try db.create(index: "idx_media_items_author", on: databaseTableName, columns: ["author"], ifNotExists: true)
        try db.create(index: "idx_media_items_starred", on: databaseTableName, columns: ["starred"], ifNotExists: true)
        try db.create(index: "idx_media_items_archivedDate", on: databaseTableName, columns: ["archivedDate"], ifNotExists: true)
        try db.create(index: "idx_media_items_parseStatus", on: databaseTableName, columns: ["parseStatus"], ifNotExists: true)
        try createStartupScanCacheTable(in: db)

        // Searchable filename text (derived). Must exist before the FTS table is
        // created because the FTS is external-content over media_items.
        try addFileNamesGeneratedColumn(in: db)

        // FTS for full-text search on OCR + text metadata.
        // Content-synced with media_items — triggers handle automatic sync
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS media_items_fts USING fts5(
                id UNINDEXED,
                ocrText,
                notes,
                author,
                generatedCaption,
                platform,
                sourceURL,
                subreddit,
                boardName,
                blogName,
                channelName,
                artistName,
                galleryName,
                tagsJSON,
                sourceTagsJSON,
                ftsFileNames,
                content='media_items',
                content_rowid='rowid'
            )
        """)

        // FTS sync triggers — content-synced FTS5 requires explicit triggers
        try createFTSSyncTriggers(in: db)
    }

    /// Create the content-synced FTS5 sync triggers (idempotent).
    /// Kept as a single source of truth so both initial schema creation and
    /// `rebuildFTSIndex` install identical triggers, including filename text.
    static func createFTSSyncTriggers(in db: Database) throws {
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS media_items_fts_ai AFTER INSERT ON media_items BEGIN
                INSERT INTO media_items_fts(
                    rowid, id, ocrText, notes, author, generatedCaption,
                    platform, sourceURL, subreddit, boardName, blogName,
                    channelName, artistName, galleryName, tagsJSON, sourceTagsJSON, ftsFileNames
                )
                VALUES (
                    new.rowid, new.id, new.ocrText, new.notes, new.author, new.generatedCaption,
                    new.platform, new.sourceURL, new.subreddit, new.boardName, new.blogName,
                    new.channelName, new.artistName, new.galleryName, new.tagsJSON, new.sourceTagsJSON, new.ftsFileNames
                );
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS media_items_fts_ad AFTER DELETE ON media_items BEGIN
                INSERT INTO media_items_fts(
                    media_items_fts, rowid, id, ocrText, notes, author, generatedCaption,
                    platform, sourceURL, subreddit, boardName, blogName,
                    channelName, artistName, galleryName, tagsJSON, sourceTagsJSON, ftsFileNames
                )
                VALUES(
                    'delete', old.rowid, old.id, old.ocrText, old.notes, old.author, old.generatedCaption,
                    old.platform, old.sourceURL, old.subreddit, old.boardName, old.blogName,
                    old.channelName, old.artistName, old.galleryName, old.tagsJSON, old.sourceTagsJSON, old.ftsFileNames
                );
            END
        """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS media_items_fts_au AFTER UPDATE ON media_items BEGIN
                INSERT INTO media_items_fts(
                    media_items_fts, rowid, id, ocrText, notes, author, generatedCaption,
                    platform, sourceURL, subreddit, boardName, blogName,
                    channelName, artistName, galleryName, tagsJSON, sourceTagsJSON, ftsFileNames
                )
                VALUES(
                    'delete', old.rowid, old.id, old.ocrText, old.notes, old.author, old.generatedCaption,
                    old.platform, old.sourceURL, old.subreddit, old.boardName, old.blogName,
                    old.channelName, old.artistName, old.galleryName, old.tagsJSON, old.sourceTagsJSON, old.ftsFileNames
                );
                INSERT INTO media_items_fts(
                    rowid, id, ocrText, notes, author, generatedCaption,
                    platform, sourceURL, subreddit, boardName, blogName,
                    channelName, artistName, galleryName, tagsJSON, sourceTagsJSON, ftsFileNames
                )
                VALUES (
                    new.rowid, new.id, new.ocrText, new.notes, new.author, new.generatedCaption,
                    new.platform, new.sourceURL, new.subreddit, new.boardName, new.blogName,
                    new.channelName, new.artistName, new.galleryName, new.tagsJSON, new.sourceTagsJSON, new.ftsFileNames
                );
            END
        """)
    }

    /// Add the derived `ftsFileNames` virtual generated column to media_items
    /// (idempotent). Concatenates the base path and the JSON array of media file
    /// paths into one text blob; the FTS unicode61 tokenizer then splits the
    /// path components — including each filename's words — into searchable tokens.
    static func addFileNamesGeneratedColumn(in db: Database) throws {
        // MUST be table_xinfo, not table_info: SQLite's table_info omits generated
        // columns entirely (they only appear in table_xinfo, hidden flag 2 for
        // VIRTUAL). With table_info the guard never saw ftsFileNames, so a second
        // call — e.g. a fresh DB running migration 1's createTable() and then
        // migration 32's redundant add in the same pass — threw
        // "duplicate column name: ftsFileNames".
        let existing = try Row.fetchAll(db, sql: "PRAGMA table_xinfo(media_items)")
            .compactMap { $0["name"] as? String }
        guard !existing.contains("ftsFileNames") else { return }
        try db.execute(sql: """
            ALTER TABLE media_items ADD COLUMN ftsFileNames TEXT
            GENERATED ALWAYS AS (
                coalesce(basePathString, '') || ' ' || coalesce(mediaFilesJSON, '')
            ) VIRTUAL
        """)
    }

    // MARK: - FTS5 Sync Methods

    /// No-op: FTS is now content-synced (migration 24) — triggers handle sync automatically.
    /// Kept for API compatibility with callers.
    func syncToFTS(db: Database) throws {
        // Content-synced FTS5 uses triggers; manual sync is not needed.
    }

    /// No-op: FTS is now content-synced (migration 24) — triggers handle sync automatically.
    static func deleteFromFTS(db: Database, id: UUID) throws {
        // Content-synced FTS5 uses triggers; manual delete is not needed.
    }

    // MARK: - Path Update Methods

    /// Update all file paths when an item is moved/renamed.
    /// Preserves all user data (stars, tags, notes, indexed content).
    /// - Parameters:
    ///   - db: Database connection
    ///   - oldBasePath: The previous base path
    ///   - newBasePath: The new base path
    /// - Returns: Number of affected rows
    @discardableResult
    static func updatePaths(
        db: Database,
        oldBasePath: String,
        newBasePath: String
    ) throws -> Int {
        try ItemAssetStore.movePaths(in: db, from: oldBasePath, to: newBasePath, directory: true)
        // Update all records that match the old base path
        // This handles both exact matches and child paths
        let sql = """
            UPDATE \(databaseTableName)
            SET basePathString = replace(basePathString, ?, ?),
                metadataFileString = replace(metadataFileString, ?, ?),
                mediaFilesJSON = (SELECT json_group_array(CASE
                    WHEN value = ? OR substr(value, 1, length(?) + 1) = ? || '/'
                    THEN ? || substr(value, length(?) + 1) ELSE value END)
                    FROM json_each(mediaFilesJSON)),
                contextImageString = replace(contextImageString, ?, ?)
            WHERE basePathString = ? OR substr(basePathString, 1, length(?) + 1) = ? || '/'
        """

        try db.execute(
            sql: sql,
            arguments: [
                oldBasePath, newBasePath,
                oldBasePath, newBasePath,
                oldBasePath, oldBasePath, oldBasePath, newBasePath, oldBasePath,
                oldBasePath, newBasePath,
                oldBasePath, oldBasePath, oldBasePath
            ]
        )

        let affectedRows = db.changesCount

        if try db.tableExists(VideoSegmentRecord.databaseTableName) {
            try db.execute(
                sql: """
                    UPDATE \(VideoSegmentRecord.databaseTableName)
                    SET source_path = replace(source_path, ?, ?)
                    WHERE source_path LIKE ? || '%'
                """,
                arguments: [oldBasePath, newBasePath, oldBasePath]
            )
        }

        if try db.tableExists(TranscriptSegmentRecord.databaseTableName) {
            try db.execute(
                sql: """
                    UPDATE \(TranscriptSegmentRecord.databaseTableName)
                    SET source_path = replace(source_path, ?, ?)
                    WHERE source_path LIKE ? || '%'
                """,
                arguments: [oldBasePath, newBasePath, oldBasePath]
            )
        }

        try db.execute(
            sql: """
                UPDATE archive_scan_cache
                SET metadataFileString = replace(metadataFileString, ?, ?),
                    mediaFilesJSON = (SELECT json_group_array(CASE
                        WHEN value = ? OR substr(value, 1, length(?) + 1) = ? || '/'
                        THEN ? || substr(value, length(?) + 1) ELSE value END)
                        FROM json_each(mediaFilesJSON)),
                    contextImageString = replace(contextImageString, ?, ?)
                WHERE metadataFileString LIKE ? || '%'
            """,
            arguments: [
                oldBasePath, newBasePath,
                oldBasePath, oldBasePath, oldBasePath, newBasePath, oldBasePath,
                oldBasePath, newBasePath,
                oldBasePath
            ]
        )

        return affectedRows
    }

    /// Update a single file path when a specific file is renamed.
    /// - Parameters:
    ///   - db: Database connection
    ///   - oldPath: The old file path
    ///   - newPath: The new file path
    /// - Returns: true if a record was updated
    @discardableResult
    static func updateFilePath(
        db: Database,
        oldPath: String,
        newPath: String
    ) throws -> Bool {
        try ItemAssetStore.movePaths(in: db, from: oldPath, to: newPath, directory: false)
        // Check if this is the metadata file
        if let record = try MediaItemRecord.filter(Column("metadataFileString") == oldPath).fetchOne(db) {
            // Update using direct SQL since we're changing the stored path
            try db.execute(
                sql: """
                    UPDATE \(databaseTableName)
                    SET metadataFileString = ?
                    WHERE id = ?
                """,
                arguments: [newPath, record.id.uuidString]
            )
            try db.execute(
                sql: """
                    UPDATE archive_scan_cache
                    SET metadataFileString = ?
                    WHERE metadataFileString = ?
                """,
                arguments: [newPath, oldPath]
            )
            return true
        }

        // Compare decoded JSON values: JSONEncoder may escape forward slashes,
        // while SQLite/imported rows may not. Text replacement misses one form.
        let mediaUpdateSql = """
            UPDATE \(databaseTableName)
            SET mediaFilesJSON = (
                SELECT json_group_array(CASE WHEN value = ? THEN ? ELSE value END)
                FROM json_each(mediaFilesJSON)
            )
            WHERE EXISTS (SELECT 1 FROM json_each(mediaFilesJSON) WHERE value = ?)
        """
        try db.execute(
            sql: mediaUpdateSql,
            arguments: [oldPath, newPath, oldPath]
        )
        if db.changesCount > 0 {
            if try db.tableExists(VideoSegmentRecord.databaseTableName) {
                try db.execute(
                    sql: """
                        UPDATE \(VideoSegmentRecord.databaseTableName)
                        SET source_path = ?
                        WHERE source_path = ?
                    """,
                    arguments: [newPath, oldPath]
                )
            }
            if try db.tableExists(TranscriptSegmentRecord.databaseTableName) {
                try db.execute(
                    sql: """
                        UPDATE \(TranscriptSegmentRecord.databaseTableName)
                        SET source_path = ?
                        WHERE source_path = ?
                    """,
                    arguments: [newPath, oldPath]
                )
            }
            try db.execute(
                sql: """
                    UPDATE archive_scan_cache
                    SET mediaFilesJSON = (
                        SELECT json_group_array(CASE WHEN value = ? THEN ? ELSE value END)
                        FROM json_each(mediaFilesJSON)
                    )
                    WHERE EXISTS (SELECT 1 FROM json_each(mediaFilesJSON) WHERE value = ?)
                """,
                arguments: [oldPath, newPath, oldPath]
            )
            return true
        }

        // Check if this is the context image
        let contextUpdateSql = """
            UPDATE \(databaseTableName)
            SET contextImageString = ?
            WHERE contextImageString = ?
        """
        try db.execute(sql: contextUpdateSql, arguments: [newPath, oldPath])

        let didUpdateContext = db.changesCount > 0
        if didUpdateContext {
            try db.execute(
                sql: """
                    UPDATE archive_scan_cache
                    SET contextImageString = ?
                    WHERE contextImageString = ?
                """,
                arguments: [newPath, oldPath]
            )
        }

        return didUpdateContext
    }

    /// Rebuild the entire FTS index from media_items.
    /// Use for recovery or after bulk imports.
    static func rebuildFTSIndex(db: Database) throws {
        try db.execute(sql: "DROP TRIGGER IF EXISTS media_items_fts_ai")
        try db.execute(sql: "DROP TRIGGER IF EXISTS media_items_fts_ad")
        try db.execute(sql: "DROP TRIGGER IF EXISTS media_items_fts_au")
        try db.execute(sql: "DROP TABLE IF EXISTS media_items_fts")

        // Ensure the derived filename column exists before (re)creating the
        // external-content FTS table that references it.
        try addFileNamesGeneratedColumn(in: db)

        // Recreate as content-synced FTS (matches current schema).
        try db.execute(sql: """
            CREATE VIRTUAL TABLE media_items_fts USING fts5(
                id UNINDEXED,
                ocrText,
                notes,
                author,
                generatedCaption,
                platform,
                sourceURL,
                subreddit,
                boardName,
                blogName,
                channelName,
                artistName,
                galleryName,
                tagsJSON,
                sourceTagsJSON,
                ftsFileNames,
                content='media_items',
                content_rowid='rowid'
            )
        """)

        // Repopulate from media_items using the FTS5 'rebuild' command rather
        // than a manual INSERT...SELECT. 'rebuild' reads each row's rowid from
        // the external content table, so FTS rowids stay aligned with
        // media_items.rowid — which has gaps from soft-deletes. A manual INSERT
        // without an explicit rowid auto-assigns sequential rowids and corrupts
        // the external-content mapping (MATCH returns the wrong rows and the FTS
        // integrity-check reports the index as malformed).
        try db.execute(sql: "INSERT INTO media_items_fts(media_items_fts) VALUES('rebuild')")

        // Recreate FTS sync triggers (single source of truth).
        try createFTSSyncTriggers(in: db)
    }

    // MARK: - Transactional Persistence Helpers

    func aroundInsert(_ db: Database, insert: () throws -> InsertionSuccess) throws {
        _ = try insert()
        try ItemAssetStore.reconcile(in: db, itemID: id.uuidString)
    }

    func aroundUpdate(_ db: Database, columns: Set<String>, update: () throws -> PersistenceSuccess) throws {
        _ = try update()
        try ItemAssetStore.reconcile(in: db, itemID: id.uuidString)
    }

    /// Insert record and sync to FTS and junction tables in the same transaction.
    func insertWithFTSSync(db: Database) throws {
        try insert(db)
        try syncToFTS(db: db)
        try syncTagsToJunctionTable(db: db)
        try syncColorsToJunctionTable(db: db)
        try syncStartupScanCache(db: db)
    }

    /// Update record and sync to FTS and junction tables in the same transaction.
    func updateWithFTSSync(db: Database) throws {
        try update(db)
        try syncToFTS(db: db)
        try syncTagsToJunctionTable(db: db)
        try syncColorsToJunctionTable(db: db)
        try syncStartupScanCache(db: db)
    }

    /// Save (insert or update) record and sync to FTS and junction tables in the same transaction.
    func saveWithFTSSync(db: Database) throws {
        try save(db)
        try syncToFTS(db: db)
        try syncTagsToJunctionTable(db: db)
        try syncColorsToJunctionTable(db: db)
        try syncStartupScanCache(db: db)
    }

    /// Delete record and remove from FTS in the same transaction.
    /// Note: Tags are auto-deleted via ON DELETE CASCADE.
    func deleteWithFTSSync(db: Database) throws -> Bool {
        try MediaItemRecord.deleteFromFTS(db: db, id: id)
        try db.execute(
            sql: "DELETE FROM archive_scan_cache WHERE metadataFileString = ?",
            arguments: [metadataFileString]
        )
        return try delete(db)
    }

    // MARK: - Startup Scan Cache

    static func createStartupScanCacheTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS archive_scan_cache (
                metadataFileString TEXT PRIMARY KEY,
                itemId TEXT NOT NULL,
                metadataFileModifiedAt REAL NOT NULL,
                metadataFileSize INTEGER NOT NULL,
                mediaFilesJSON TEXT NOT NULL,
                contextImageString TEXT,
                FOREIGN KEY (itemId) REFERENCES media_items(id) ON DELETE CASCADE
            )
        """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_archive_scan_cache_item
            ON archive_scan_cache(itemId)
        """)
    }

    func syncStartupScanCache(db: Database) throws {
        try db.execute(
            sql: """
                DELETE FROM archive_scan_cache
                WHERE itemId = ? AND metadataFileString != ?
            """,
            arguments: [id.uuidString, metadataFileString]
        )

        guard let fingerprint = MetadataFileFingerprint.current(for: URL(fileURLWithPath: metadataFileString)) else {
            try db.execute(
                sql: "DELETE FROM archive_scan_cache WHERE itemId = ?",
                arguments: [id.uuidString]
            )
            return
        }

        try db.execute(
            sql: """
                INSERT INTO archive_scan_cache (
                    metadataFileString, itemId, metadataFileModifiedAt,
                    metadataFileSize, mediaFilesJSON, contextImageString
                )
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(metadataFileString) DO UPDATE SET
                    itemId = excluded.itemId,
                    metadataFileModifiedAt = excluded.metadataFileModifiedAt,
                    metadataFileSize = excluded.metadataFileSize,
                    mediaFilesJSON = excluded.mediaFilesJSON,
                    contextImageString = excluded.contextImageString
            """,
            arguments: [
                metadataFileString,
                id.uuidString,
                fingerprint.modifiedAt,
                fingerprint.fileSize,
                mediaFilesJSON,
                contextImageString
            ]
        )
    }

    // MARK: - Tags Junction Table Sync

    /// Sync tags from tagsJSON to the media_tags junction table.
    /// Replaces all existing tags for this item.
    private func syncTagsToJunctionTable(db: Database) throws {
        // Delete existing tags for this item
        try db.execute(
            sql: "DELETE FROM media_tags WHERE item_id = ?",
            arguments: [id.uuidString]
        )

        // Parse tags from JSON and insert
        if let tags = try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8)) {
            for tag in tags {
                let normalizedTag = TagCanonicalizer.key(tag)
                guard !normalizedTag.isEmpty else { continue }
                try db.execute(
                    sql: "INSERT OR IGNORE INTO media_tags (item_id, tag) VALUES (?, ?)",
                    arguments: [id.uuidString, normalizedTag]
                )
            }
        }
    }

    // MARK: - Colors Junction Table Sync

    /// Sync colors from dominantColorsJSON to the media_colors junction table.
    /// Replaces all existing colors for this item.
    private func syncColorsToJunctionTable(db: Database) throws {
        // Delete existing colors for this item
        try db.execute(
            sql: "DELETE FROM media_colors WHERE item_id = ?",
            arguments: [id.uuidString]
        )

        // Parse colors from JSON and insert
        guard let colorsJSON = dominantColorsJSON,
              let colors = try? JSONDecoder().decode([String].self, from: Data(colorsJSON.utf8)) else {
            return
        }

        for color in colors {
            try db.execute(
                sql: "INSERT OR IGNORE INTO media_colors (item_id, color_bucket) VALUES (?, ?)",
                arguments: [id.uuidString, color]
            )
        }
    }

    // MARK: - FTS Health Check

    /// Check FTS index health - returns (indexed count, expected count)
    /// Compare FTS row count to total media_items count.
    /// Content-synced FTS with triggers keeps ALL rows (including soft-deleted) in sync.
    static func checkFTSHealth(db: Database) throws -> (indexed: Int, expected: Int) {
        let ftsCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items_fts") ?? 0
        let itemCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items") ?? 0
        return (ftsCount, itemCount)
    }
}
