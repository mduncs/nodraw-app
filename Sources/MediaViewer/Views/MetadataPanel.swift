import SwiftUI
import AppKit
import ImageIO
import AVFoundation
import CoreMedia
import PhotoPipeline

// MARK: - Cached DateFormatter

private let metadataDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

// MARK: - FileInfo

/// Loaded file metadata for the current media file (dimensions, size, format, duration).
private struct FileInfo: Equatable {
    var width: Int?
    var height: Int?
    var fileSize: Int64?
    var format: String?
    var duration: Double?  // seconds, audio/video only

    /// Whether at least one displayable field has data
    var hasAnyData: Bool {
        width != nil || fileSize != nil || format != nil || duration != nil
    }

    var dimensionsString: String? {
        guard let w = width, let h = height else { return nil }
        return "\(w) x \(h)"
    }

    var aspectRatioString: String? {
        guard let w = width, let h = height, h > 0 else { return nil }
        let ratio = Double(w) / Double(h)

        // Named ratios: (name, value)
        let namedRatios: [(String, Double)] = [
            ("1:1", 1.0),
            ("4:3", 4.0 / 3.0),
            ("3:2", 3.0 / 2.0),
            ("16:9", 16.0 / 9.0),
            ("21:9", 21.0 / 9.0),
            ("9:16", 9.0 / 16.0),
            ("2:3", 2.0 / 3.0),
            ("3:4", 3.0 / 4.0),
        ]

        for (name, value) in namedRatios {
            if abs(ratio - value) < 0.05 {
                return name
            }
        }

        return String(format: "%.2f:1", ratio)
    }

    var fileSizeString: String? {
        guard let size = fileSize else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var durationString: String? {
        guard let dur = duration, dur > 0 else { return nil }
        let totalSeconds = Int(dur.rounded())
        if totalSeconds == 0 {
            return "< 1s"
        }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Load file info from a URL. Detects image vs audio/video by extension.
    static func load(from url: URL) async -> FileInfo {
        var info = FileInfo()
        let ext = url.pathExtension.lowercased()
        let isVideo = ["mp4", "mov", "webm", "m4v", "avi", "mkv"].contains(ext)
        let isAudio = ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "caf"].contains(ext)

        // File size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            info.fileSize = size
        }

        if isVideo {
            info = await loadVideoInfo(url: url, info: info, ext: ext)
        } else if isAudio {
            info = await loadAudioInfo(url: url, info: info, ext: ext)
        } else {
            info = loadImageInfo(url: url, info: info, ext: ext)
        }

        return info
    }

    private static func loadAudioInfo(url: URL, info: FileInfo, ext: String) async -> FileInfo {
        var info = info
        info.format = "\(ext.uppercased()) audio"

        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite && seconds > 0 {
                info.duration = seconds
            }
        }

        if let file = try? AVAudioFile(forReading: url) {
            let format = file.processingFormat
            let sampleRate = Int(format.sampleRate.rounded())
            let channels = Int(format.channelCount)
            info.format = "\(ext.uppercased()) audio, \(sampleRate) Hz, \(channels) ch"
        }

        return info
    }

    private static func loadImageInfo(url: URL, info: FileInfo, ext: String) -> FileInfo {
        var info = info

        // Format from extension
        let formatMap: [String: String] = [
            "jpg": "JPEG", "jpeg": "JPEG",
            "png": "PNG",
            "gif": "GIF",
            "webp": "WebP",
            "heic": "HEIC",
            "tiff": "TIFF", "tif": "TIFF",
            "bmp": "BMP",
            "avif": "AVIF",
        ]
        info.format = formatMap[ext] ?? ext.uppercased()

        // Dimensions from CGImageSource
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return info }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return info }

        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            info.width = w
            info.height = h
        }

        return info
    }

    private static func loadVideoInfo(url: URL, info: FileInfo, ext: String) async -> FileInfo {
        var info = info
        let asset = AVURLAsset(url: url)

        // Duration
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite && seconds > 0 {
                info.duration = seconds
            }
        }

        // Video track: dimensions + codec
        if let tracks = try? await asset.loadTracks(withMediaType: .video),
           let track = tracks.first {

            // Natural size + transform for rotation
            if let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let transformed = size.applying(transform)
                info.width = Int(abs(transformed.width))
                info.height = Int(abs(transformed.height))
            }

            // Codec FourCC from format descriptions
            if let descs = try? await track.load(.formatDescriptions),
               let desc = descs.first {
                let codecType = CMFormatDescriptionGetMediaSubType(desc)
                let fourCC = fourCCString(codecType)
                info.format = "\(fourCC) \(ext.uppercased())"
            } else {
                info.format = ext.uppercased()
            }
        } else {
            info.format = ext.uppercased()
        }

        return info
    }

    /// Convert a FourCharCode to a readable string (e.g., 'avc1', 'hvc1').
    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }
}

// MARK: - MetadataPanel

/// Right-side panel showing full metadata for a MediaItem.
/// Bloomberg-dense aesthetic: monospace values, no wasted space, orange accents.
struct MetadataPanel: View {
    let item: MediaItem
    let onTagsChanged: ([String]) -> Void
    let onNotesChanged: (UUID, String?) -> Void
    let onStarChanged: (Bool) -> Void
    @EnvironmentObject private var appState: AppState

    /// Current media index for per-file OCR display (carousel support)
    var currentMediaIndex: Int = 0

    /// True while the detail view shows the item's context screenshot page.
    var showingContext: Bool = false
    var contextImageURL: URL? = nil

    /// The detail toolbar already owns starring; other hosts keep the header star.
    var showsStarToggle: Bool = true

    // OCR block hover state (optional - only for SingleFocusView with OCR overlay)
    var hoveredOCRBlock: Binding<SerializableTextBlock?>?

    // OCR overlay toggle (optional - controls whether bounding boxes show on image)
    var showOCROverlay: Binding<Bool>?

    // OCR reprocessing callback (optional - only when VisionJobQueue is available)
    var onReprocessOCR: ((UUID) -> Void)?

    // Video seek state (optional - only for SingleFocusView)
    var videoPlaybackTime: Double?
    var onSeekToVideoTime: ((Double) -> Void)?

    /// Opens "source & metadata" and "media analysis" on first appearance; both stay collapsed by default.
    var expandsDetailSections: Bool = false

    @State private var isReprocessingOCR: Bool = false

    @State private var fileInfo: FileInfo?
    @State private var editingNotes: String = ""
    @State private var newTag: String = ""
    @State private var isAddingTag: Bool = false
    @State private var isPipelineDebugExpanded: Bool = false
    @State private var isSourceDetailsExpanded: Bool = false
    @State private var isMediaAnalysisExpanded: Bool = false
    @State private var showsAllVideoSegments: Bool = false
    @State private var showsAllTranscriptSegments: Bool = false
    @State private var ruleEditorSourceField: SourceField? = nil
    @State private var ruleEditorPattern: String = ""
    @State private var showingRuleEditor: Bool = false
    @State private var notesDebounceTasks: [UUID: Task<Void, Never>] = [:]
    @State private var suppressNextNotesChange: Bool = false
    @State private var editingNotesItemID: UUID?
    @State private var isGeneratedCaptionExpanded: Bool = false
    @State private var isOCRExpanded: Bool = true
    @State private var ocrDetailHeight: CGFloat = 360
    @State private var notesEditorHeight: CGFloat = 120

    /// Current media file URL based on carousel index
    private var currentMediaURL: URL? {
        if showingContext || item.mediaFiles.isEmpty {
            return contextImageURL
        }
        guard !item.mediaFiles.isEmpty else { return nil }
        let safeIndex = min(currentMediaIndex, item.mediaFiles.count - 1)
        return item.mediaFiles[max(0, safeIndex)]
    }

    private var currentMediaExtension: String? {
        guard let ext = currentMediaURL?.pathExtension.lowercased(), !ext.isEmpty else { return nil }
        return ext
    }

    private var currentMediaTypeLabel: String? {
        guard let ext = currentMediaExtension else {
            return item.hasVideo ? "video" : nil
        }

        if Self.videoExtensions.contains(ext) {
            return "video"
        }
        if Self.audioExtensions.contains(ext) {
            return "audio"
        }
        if ext == "gif" {
            return "gif"
        }
        if Self.documentExtensions.contains(ext) {
            return "document"
        }
        if Self.imageExtensions.contains(ext) {
            return "image"
        }
        return ext
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "webm", "m4v", "avi", "mkv"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "flac", "ogg", "opus", "aac"]
    private static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "rtf", "txt"]

    /// Get OCR text for the current file index
    private var currentOCRText: String? {
        item.ocrText(forFileIndex: currentMediaIndex)
    }

    /// Get OCR blocks for the current file index
    private var currentOCRBlocks: [SerializableTextBlock]? {
        item.ocrBlocks(forFileIndex: currentMediaIndex)
    }

    /// Check if current file has OCR blocks
    private var hasOCRBlocks: Bool {
        guard let blocks = currentOCRBlocks else { return false }
        return !blocks.isEmpty
    }

    private var currentVideoSegments: [VideoSegment] {
        let segments = item.videoSegments
            .filter { $0.mediaFileIndex == currentMediaIndex }
        let marlinSegments = segments.filter { $0.analysisSource == "marlin-2b" }
        let preferredSegments = marlinSegments.isEmpty ? segments : marlinSegments
        return preferredSegments
            .sorted { $0.startTime < $1.startTime }
    }

    private var currentVideoSegmentSource: String? {
        currentVideoSegments.first?.analysisSource
    }

    private var currentTranscriptSegments: [TranscriptSegment] {
        item.transcriptSegments
            .filter { $0.mediaFileIndex == currentMediaIndex }
            .sorted { $0.startTime < $1.startTime }
    }

    private var shouldShowVideoTimeline: Bool {
        guard item.hasVideo else { return false }
        if !currentVideoSegments.isEmpty { return true }
        let status = item.videoUnderstandingStatus ?? "none"
        return status == "processing" || status == "failed"
    }

    private var shouldShowTranscriptTimeline: Bool {
        guard item.hasTranscribableMedia else { return false }
        if !currentTranscriptSegments.isEmpty { return true }
        let status = item.transcriptionStatus ?? "none"
        return status == "processing" || status == "failed"
    }

    /// What the collapsed "media analysis" group holds, so a transcript or extracted text is discoverable.
    private var mediaAnalysisSummary: String? {
        var parts: [String] = []
        if !currentTranscriptSegments.isEmpty { parts.append("transcript") }
        if !currentVideoSegments.isEmpty { parts.append("timeline") }
        if hasOCRBlocks || !(currentOCRText ?? "").isEmpty { parts.append("text") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func disclosureLabel(_ title: String, summary: String?, isExpanded: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if let summary, !isExpanded {
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Identity and user-owned fields stay at the top; derived detail remains available below.
                headerSection
                sectionSeparator()
                tagsSection
                sectionSeparator()
                notesSection
                // Grips sit on the bottom edge of the section they resize, so they track the pointer.
                sectionSeparator(resizing: $notesEditorHeight, range: 80...260, label: "Resize notes")

                DisclosureGroup(isExpanded: $isSourceDetailsExpanded) {
                    VStack(alignment: .leading, spacing: 0) {
                        mlInsightsSection
                        metadataSection
                        if let srcTags = item.metadata.sourceTags, !srcTags.isEmpty {
                            sourceTagsSection(srcTags)
                        }
                    }
                } label: {
                    disclosureLabel("source & metadata", summary: nil, isExpanded: isSourceDetailsExpanded)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                sectionSeparator()

                DisclosureGroup(isExpanded: $isMediaAnalysisExpanded) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let info = fileInfo, info.hasAnyData {
                            fileInfoSection
                            sectionSeparator()
                        }
                        if shouldShowVideoTimeline {
                            videoTimelineSection
                            Divider().background(Color.white.opacity(0.1))
                        }
                        if shouldShowTranscriptTimeline {
                            transcriptTimelineSection
                            Divider().background(Color.white.opacity(0.1))
                        }
                        if let blocks = currentOCRBlocks, !blocks.isEmpty,
                           let hoveredBinding = hoveredOCRBlock {
                            ocrBlocksSection(blocks: blocks, hoveredBlock: hoveredBinding)
                            sectionSeparator(resizing: $ocrDetailHeight, range: 260...720, label: "Resize extracted text")
                        } else if let ocrText = currentOCRText, !ocrText.isEmpty {
                            ocrSection(text: ocrText)
                            sectionSeparator(resizing: $ocrDetailHeight, range: 260...720, label: "Resize extracted text")
                        } else if onReprocessOCR != nil {
                            noOCRSection
                            sectionSeparator()
                        }
                        pipelineDebugSection
                    }
                } label: {
                    disclosureLabel("media analysis", summary: mediaAnalysisSummary, isExpanded: isMediaAnalysisExpanded)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 240, maxWidth: 360)
        .background(Color(hex: 0x1f1f1f))
        .task(id: currentMediaURL) {
            guard let url = currentMediaURL else {
                fileInfo = nil
                return
            }
            fileInfo = await FileInfo.load(from: url)
        }
        .onAppear {
            syncEditingNotes(for: item.id, notes: item.metadata.notes)
            if expandsDetailSections {
                isSourceDetailsExpanded = true
                isMediaAnalysisExpanded = true
            }
        }
        .onChange(of: item.id) { _, _ in
            // CRITICAL: Update local state when item changes
            // onAppear only fires once; without this, notes stay stale
            syncEditingNotes(for: item.id, notes: item.metadata.notes)
            newTag = ""
            isAddingTag = false
            isReprocessingOCR = false
            isPipelineDebugExpanded = false
            isGeneratedCaptionExpanded = false
            isOCRExpanded = true
            showsAllVideoSegments = false
            showsAllTranscriptSegments = false
            fileInfo = nil
        }
        .onChange(of: item.metadata.notes) { newNotes in
            guard !isNotesFocused else { return }
            syncEditingNotes(for: item.id, notes: newNotes)
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaStoreDidChange)) { notification in
            // Clear processing state when OCR completes for this item
            if let changedID = notification.userInfo?["itemId"] as? UUID,
               changedID == item.id {
                isReprocessingOCR = false
            }
        }
        .sheet(isPresented: $showingRuleEditor) {
            TagRuleEditorSheet(
                engine: TagRuleEngine.shared,
                tagSettings: TagSettings.shared,
                editingRule: nil,
                prefilledSourceField: ruleEditorSourceField,
                prefilledPattern: ruleEditorPattern,
                mediaStore: appState.mediaStore
            )
        }
    }

    private func syncEditingNotes(for itemID: UUID, notes: String?) {
        if editingNotesItemID == itemID {
            notesDebounceTasks[itemID]?.cancel()
            notesDebounceTasks[itemID] = nil
        }

        editingNotesItemID = itemID
        let nextNotes = notes ?? ""
        guard editingNotes != nextNotes else {
            suppressNextNotesChange = false
            return
        }

        suppressNextNotesChange = true
        editingNotes = nextNotes
    }

    @ViewBuilder
    private func sectionSeparator(
        resizing height: Binding<CGFloat>? = nil,
        range: ClosedRange<CGFloat> = 80...260,
        label: String = "Resize section"
    ) -> some View {
        if let height {
            SidebarSectionResizeHandle(height: height, range: range, label: label)
        } else {
            Divider()
                .background(Color.white.opacity(0.1))
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                PlatformBadge(
                    platform: item.metadata.platform,
                    onFilter: { applyPlatformFilter(item.metadata.platform) }
                )
                Spacer()
                if showsStarToggle {
                    StarToggleButton(
                        isStarred: item.metadata.starred,
                        action: { onStarChanged(!item.metadata.starred) }
                    )
                }
            }

            if let author = item.metadata.author, !author.isEmpty {
                HStack(spacing: 4) {
                    Text("by")
                        .foregroundStyle(.secondary)
                    Text(author)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Author: \(author)")
            }
        }
        .padding(12)
    }

    // MARK: - Metadata Rows

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let originalDate = item.metadata.originalDate {
                MetadataRow(label: "date", value: formatDate(originalDate))
            }

            if let uploadDate = item.metadata.uploadDate {
                MetadataRow(label: "uploaded", value: formatDate(uploadDate))
            }
            if let downloadDate = item.metadata.downloadDate {
                MetadataRow(label: "downloaded", value: formatDate(downloadDate))
            }
            if let importDate = item.metadata.importDate {
                MetadataRow(label: "imported", value: formatDate(importDate))
            }
            MetadataRow(label: "archived", value: formatDate(item.metadata.archivedDate))

            MetadataRow(label: "folder", value: item.folderName)

            if item.mediaFiles.count > 1 {
                MetadataRow(label: "media", value: "\(item.mediaFiles.count) files")
            }

            if let typeLabel = currentMediaTypeLabel {
                FilterableMetadataRow(label: "type", value: typeLabel, help: "Filter by \(typeLabel)") {
                    applyTypeFilter(typeLabel)
                }
            }

            if let views = item.metadata.viewCount {
                MetadataRow(label: "views", value: formatCount(views))
            }
            if let likes = item.metadata.likeCount {
                MetadataRow(label: "likes", value: formatCount(likes))
            }

            // Source context fields with rule creation buttons
            if let sub = item.metadata.subreddit {
                sourceContextRow(label: "subreddit", value: "r/\(sub)", field: .subreddit, pattern: sub)
            }
            if let board = item.metadata.boardName {
                sourceContextRow(label: "board", value: board, field: .boardName, pattern: board)
            }
            if let blog = item.metadata.blogName {
                sourceContextRow(label: "blog", value: blog, field: .blogName, pattern: blog)
            }
            if let channel = item.metadata.channelName {
                sourceContextRow(label: "channel", value: channel, field: .channelName, pattern: channel)
            }
            if let artist = item.metadata.artistName {
                sourceContextRow(label: "artist", value: artist, field: .artistName, pattern: artist)
            }
            if let gallery = item.metadata.galleryName {
                sourceContextRow(label: "gallery", value: gallery, field: .galleryName, pattern: gallery)
            }

            // Source URL with copy button
            HStack(alignment: .top) {
                Text("source")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Button {
                    applySourceFilter()
                } label: {
                    Text(truncatedSource(item.metadata.source))
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.accentOrange)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Filter by source")
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.metadata.source.absoluteString, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentOrange.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Copy full URL")
            }
        }
        .padding(12)
    }

    // MARK: - Source Context Row

    private func sourceContextRow(label: String, value: String, field: SourceField, pattern: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            Spacer()

            Button {
                ruleEditorSourceField = field
                ruleEditorPattern = pattern
                showingRuleEditor = true
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentOrange.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Create tag rule from \(label)")
        }
    }

    // MARK: - File Info Section

    private var fileInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("file info")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let info = fileInfo {
                if let dims = info.dimensionsString {
                    FilterableMetadataRow(label: "dims", value: dims, help: "Filter by this aspect ratio") {
                        applyAspectRatioFilter(info)
                    }
                }

                if let ratio = info.aspectRatioString {
                    FilterableMetadataRow(label: "ratio", value: ratio, help: "Filter by this aspect ratio") {
                        applyAspectRatioFilter(info)
                    }
                }

                if let size = info.fileSizeString {
                    MetadataRow(label: "size", value: size)
                }

                if let format = info.format {
                    if let ext = currentMediaExtension {
                        FilterableMetadataRow(label: "format", value: format, help: "Filter by .\(ext)") {
                            appendSearchToken("ext:\(ext)")
                        }
                    } else {
                        MetadataRow(label: "format", value: format)
                    }
                }

                if let dur = info.durationString {
                    MetadataRow(label: "duration", value: dur)
                }
            }

            if let colors = item.indexedContent?.dominantColors, !colors.isEmpty {
                HStack(alignment: .top) {
                    Text("colors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    HStack(spacing: 3) {
                        ForEach(Array(colors.enumerated()), id: \.offset) { _, bucket in
                            let rgb = bucket.uiColor
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                                .frame(width: 14, height: 14)
                                .help(bucket.displayName)
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private func segmentOverflowButton(hidden: Int, isShowingAll: Binding<Bool>) -> some View {
        Button(isShowingAll.wrappedValue ? "show fewer" : "+ \(hidden) more") {
            isShowingAll.wrappedValue.toggle()
        }
        .buttonStyle(.plain)
        .font(.caption2.monospaced())
        .foregroundStyle(Color.accentOrange.opacity(0.85))
        .help(isShowingAll.wrappedValue ? "Collapse to the first 12 segments" : "Show every segment")
    }

    // MARK: - Video Timeline Section

    @ViewBuilder
    private var videoTimelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("video timeline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let source = currentVideoSegmentSource {
                    Text(source)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                Spacer()
                if let status = item.videoUnderstandingStatus, status != "none" {
                    PipelineStatusCell(status: status)
                }
            }

            if !currentVideoSegments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(currentVideoSegments.prefix(showsAllVideoSegments ? .max : 12))) { segment in
                        videoSegmentRow(segment)
                    }

                    if currentVideoSegments.count > 12 {
                        segmentOverflowButton(hidden: currentVideoSegments.count - 12, isShowingAll: $showsAllVideoSegments)
                    }
                }
            } else if item.videoUnderstandingStatus == "processing" {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                    Text("Analyzing video...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if item.videoUnderstandingStatus == "failed" {
                Text(item.videoUnderstandingLastError ?? "Video analysis failed")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func videoSegmentRow(_ segment: VideoSegment) -> some View {
        let isActive = isActiveVideoSegment(segment)
        let row = HStack(alignment: .top, spacing: 8) {
            Text(VideoSegment.formatTime(segment.startTime))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isActive ? Color.accentOrange : Color.accentOrange.opacity(0.85))
                .frame(width: 42, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(segment.summary)
                        .font(.caption)
                        .foregroundStyle(.primary.opacity(isActive ? 0.96 : 0.88))
                        .lineLimit(2)
                        .textSelection(.enabled)

                    if segment.analysisSource != currentVideoSegmentSource {
                        Text(segment.analysisSource)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if !segment.labels.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(segment.labels.prefix(3), id: \.label) { label in
                            Text(label.label)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white.opacity(0.06))
                                )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentOrange.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentOrange.opacity(0.24) : Color.clear, lineWidth: 1)
        )
        .help(onSeekToVideoTime == nil ? segment.timestampRange : "Seek to \(VideoSegment.formatTime(segment.startTime))")

        if let onSeekToVideoTime {
            Button {
                onSeekToVideoTime(segment.startTime)
            } label: {
                row
            }
            .buttonStyle(.plain)
        } else {
            row
        }
    }

    private func isActiveVideoSegment(_ segment: VideoSegment) -> Bool {
        guard let videoPlaybackTime else { return false }
        let endTime = max(segment.endTime, segment.startTime + 0.25)
        return videoPlaybackTime >= segment.startTime && videoPlaybackTime < endTime
    }

    // MARK: - Transcript Timeline Section

    @ViewBuilder
    private var transcriptTimelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("speech transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let status = item.transcriptionStatus, status != "none" {
                    PipelineStatusCell(status: status)
                }
            }

            if !currentTranscriptSegments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(currentTranscriptSegments.prefix(showsAllTranscriptSegments ? .max : 12))) { segment in
                        transcriptSegmentRow(segment)
                    }

                    if currentTranscriptSegments.count > 12 {
                        segmentOverflowButton(hidden: currentTranscriptSegments.count - 12, isShowingAll: $showsAllTranscriptSegments)
                    }
                }
            } else if item.transcriptionStatus == "processing" {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                    Text("Transcribing speech...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if item.transcriptionStatus == "failed" {
                Text(item.transcriptionLastError ?? "Transcription failed")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func transcriptSegmentRow(_ segment: TranscriptSegment) -> some View {
        let isActive = isActiveTranscriptSegment(segment)
        let row = HStack(alignment: .top, spacing: 8) {
            Text(VideoSegment.formatTime(segment.startTime))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isActive ? Color.accentOrange : Color.accentOrange.opacity(0.85))
                .frame(width: 42, alignment: .leading)

            Text(segment.text)
                .font(.caption)
                .foregroundStyle(.primary.opacity(isActive ? 0.96 : 0.88))
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentOrange.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.accentOrange.opacity(0.24) : Color.clear, lineWidth: 1)
        )
        .help(onSeekToVideoTime == nil ? segment.timestampRange : "Seek to \(VideoSegment.formatTime(segment.startTime))")

        if let onSeekToVideoTime {
            Button {
                onSeekToVideoTime(segment.startTime)
            } label: {
                row
            }
            .buttonStyle(.plain)
        } else {
            row
        }
    }

    private func isActiveTranscriptSegment(_ segment: TranscriptSegment) -> Bool {
        guard let videoPlaybackTime else { return false }
        let endTime = max(segment.endTime, segment.startTime + 0.25)
        return videoPlaybackTime >= segment.startTime && videoPlaybackTime < endTime
    }

    // MARK: - Helpers

    private func roleOrder(_ role: TextRole) -> Int {
        switch role {
        case .heading: return 0
        case .body: return 1
        case .caption: return 2
        default: return 3
        }
    }

    /// Truncate source URL to domain or first 30 chars
    private func truncatedSource(_ url: URL) -> String {
        if let host = url.host {
            return host
        }
        let str = url.absoluteString
        if str.count > 30 {
            return String(str.prefix(30)) + "..."
        }
        return str
    }

    // MARK: - OCR Section

    @State private var ocrCopied: Bool = false

    private func ocrSection(text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("OCR text")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // Reprocess button - show when OCR text exists but no bounding boxes
                if let reprocessCallback = onReprocessOCR,
                   !hasOCRBlocks {
                    Button {
                        isReprocessingOCR = true
                        reprocessCallback(item.id)
                        // Reset state after a delay (actual completion happens async)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            isReprocessingOCR = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isReprocessingOCR {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isReprocessingOCR ? "Processing" : "Reprocess")
                        }
                        .font(.caption)
                        .foregroundStyle(isReprocessingOCR ? .secondary : Color.accentOrange)
                    }
                    .buttonStyle(.plain)
                    .disabled(isReprocessingOCR)
                }

                // Copy button
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    ocrCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        ocrCopied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: ocrCopied ? "checkmark" : "doc.on.doc")
                        if ocrCopied {
                            Text("Copied")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(ocrCopied ? .green : Color.accentOrange)
                }
                .buttonStyle(.plain)
            }

            let lineCount = text.split(whereSeparator: { $0.isNewline }).count
            let needsBoundedDetail = text.count > 5_000 || lineCount > 60
            let canCollapse = text.count > 1_200 || lineCount > 18
            Group {
                if isOCRExpanded && needsBoundedDetail {
                    ScrollView {
                        Text(text)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary.opacity(0.9))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: ocrDetailHeight)
                } else {
                    Text(text)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary.opacity(0.9))
                        .textSelection(.enabled)
                        .lineLimit(isOCRExpanded ? nil : 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if canCollapse {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isOCRExpanded.toggle()
                    }
                } label: {
                    Label(isOCRExpanded ? "Show less" : "Show all", systemImage: isOCRExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(Color.accentOrange)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    /// Section shown when image has no OCR data (needs reprocessing)
    private var noOCRSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OCR")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isReprocessingOCR {
                // Show processing state
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                    Text("Processing OCR...")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else if let reprocessCallback = onReprocessOCR {
                Button {
                    isReprocessingOCR = true
                    reprocessCallback(item.id)
                    // Keep processing state until OCR completes (via notification)
                    // or timeout after 30 seconds as fallback
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
                        isReprocessingOCR = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.viewfinder")
                        Text("Scan for Text")
                    }
                    .font(.callout)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentOrange.opacity(0.8))
                    )
                }
                .buttonStyle(.plain)
            }

            if !isReprocessingOCR {
                Text("No text detected yet")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .padding(12)
    }

    // MARK: - OCR Blocks Section (Interactive)

    @State private var ocrBlockCopied: String? = nil

    private func ocrBlocksSection(blocks: [SerializableTextBlock], hoveredBlock: Binding<SerializableTextBlock?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("OCR text")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // Always allow force reprocessing for this item
                if let reprocessCallback = onReprocessOCR {
                    Button {
                        isReprocessingOCR = true
                        reprocessCallback(item.id)
                        // Fallback reset if completion notification doesn't arrive
                        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {
                            if isReprocessingOCR {
                                isReprocessingOCR = false
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isReprocessingOCR {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isReprocessingOCR ? "Processing" : "Reprocess")
                        }
                        .font(.caption)
                        .foregroundStyle(isReprocessingOCR ? .secondary : Color.accentOrange)
                    }
                    .buttonStyle(.plain)
                    .disabled(isReprocessingOCR)
                    .help("Re-run OCR for this item")
                }

                // Show on image toggle
                if let overlayBinding = showOCROverlay {
                    Button {
                        overlayBinding.wrappedValue.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: overlayBinding.wrappedValue ? "text.viewfinder" : "doc.text.viewfinder")
                            Text(overlayBinding.wrappedValue ? "Hide" : "Show")
                        }
                        .font(.caption)
                        .foregroundStyle(overlayBinding.wrappedValue ? Color.accentOrange : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(overlayBinding.wrappedValue ? "Hide text blocks on image" : "Show text blocks on image")
                }

                // Copy all button
                Button {
                    let allText = blocks.map { $0.text }.joined(separator: "\n\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(allText, forType: .string)
                    ocrCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        ocrCopied = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: ocrCopied ? "checkmark" : "doc.on.doc")
                        Text(ocrCopied ? "Copied" : "Copy all")
                    }
                    .font(.caption)
                    .foregroundStyle(ocrCopied ? .green : Color.accentOrange)
                }
                .buttonStyle(.plain)
            }

            let ordered = blocks.sorted { roleOrder($0.textRole) < roleOrder($1.textRole) }
            let visibleBlocks = isOCRExpanded ? ordered : Array(ordered.prefix(12))
            let needsBoundedDetail = ordered.count > 48

            if ordered.count > visibleBlocks.count {
                Text("\(ordered.count) text blocks; showing \(visibleBlocks.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.7))
            }

            Group {
                if isOCRExpanded && needsBoundedDetail {
                    ScrollView {
                        ocrBlockList(blocks: visibleBlocks, hoveredBlock: hoveredBlock)
                    }
                    .frame(maxHeight: ocrDetailHeight)
                } else {
                    ocrBlockList(blocks: visibleBlocks, hoveredBlock: hoveredBlock)
                }
            }

            if ordered.count > 12 {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isOCRExpanded.toggle()
                    }
                } label: {
                    Label(isOCRExpanded ? "Show fewer blocks" : "Show all blocks", systemImage: isOCRExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(Color.accentOrange)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    private func ocrBlockList(
        blocks: [SerializableTextBlock],
        hoveredBlock: Binding<SerializableTextBlock?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(blocks) { block in
                OCRBlockRow(
                    block: block,
                    isHovered: hoveredBlock.wrappedValue?.id == block.id,
                    isCopied: ocrBlockCopied == block.id,
                    onHover: { isHovered in
                        if isHovered {
                            hoveredBlock.wrappedValue = block
                            // Auto-show OCR overlay when hovering sidebar text
                            showOCROverlay?.wrappedValue = true
                        } else if hoveredBlock.wrappedValue?.id == block.id {
                            hoveredBlock.wrappedValue = nil
                        }
                    },
                    onCopy: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(block.text, forType: .string)
                        ocrBlockCopied = block.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            if ocrBlockCopied == block.id {
                                ocrBlockCopied = nil
                            }
                        }
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tags Section

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("tags")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                AddTagButton(action: { isAddingTag = true })
            }

            // Tag chips
            FlowLayout(spacing: 4) {
                ForEach(item.metadata.tags, id: \.self) { tag in
                    InspectorTagChip(
                        tag: tag,
                        onRemove: { removeTag(tag) }
                    )
                }

                if isAddingTag {
                    TagInputField(
                        text: $newTag,
                        onSubmit: addTag,
                        onCancel: { isAddingTag = false }
                    )
                }
            }

            if item.metadata.tags.isEmpty && !isAddingTag {
                Text("no tags")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .padding(12)
    }

    // MARK: - Source Tags Section

    private func sourceTagsSection(_ tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("source tags")
                .font(.caption)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 4) {
                        Text(tag)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Button {
                            ruleEditorSourceField = .sourceTag
                            ruleEditorPattern = tag
                            showingRuleEditor = true
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.accentOrange.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Create tag rule from source tag '\(tag)'")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                            )
                    )
                }
            }
        }
        .padding(12)
    }

    // MARK: - Notes Section

    @FocusState private var isNotesFocused: Bool

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("notes")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $editingNotes)
                .font(.caption.monospaced())
                .scrollContentBackground(.hidden)
                .background(Color(hex: 0x2a2a2a))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(height: notesEditorHeight)
                .focused($isNotesFocused)
                .onChange(of: editingNotes) { _, newValue in
                    if suppressNextNotesChange {
                        suppressNextNotesChange = false
                        return
                    }

                    let itemID = item.id
                    let normalizedNotes = newValue.isEmpty ? nil : newValue
                    notesDebounceTasks[itemID]?.cancel()
                    notesDebounceTasks[itemID] = Task {
                        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            onNotesChanged(itemID, normalizedNotes)
                            notesDebounceTasks[itemID] = nil
                        }
                    }
                }

            // Character count feedback while editing
            if isNotesFocused {
                Text("\(editingNotes.count) characters")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .padding(12)
    }

    // MARK: - Actions

    private func openSource() {
        NSWorkspace.shared.open(item.metadata.source)
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !item.metadata.tags.contains(tag) else {
            newTag = ""
            isAddingTag = false
            return
        }

        var newTags = item.metadata.tags
        newTags.append(tag)
        onTagsChanged(newTags)
        newTag = ""
        isAddingTag = false
    }

    private func removeTag(_ tag: String) {
        var newTags = item.metadata.tags
        newTags.removeAll { $0 == tag }
        onTagsChanged(newTags)
    }

    private func formatDate(_ date: Date) -> String {
        metadataDateFormatter.string(from: date)
    }

    private func formatCount(_ n: Int) -> String {
        switch n {
        case 0..<1_000: return "\(n)"
        case 1_000..<1_000_000: return String(format: "%.1fK", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    private func togglePipelineFilter(_ filter: AttributeFilter) {
        appState.commitLibraryFilterChange {
            if appState.pipelineAttributeFilters.contains(filter) {
                appState.pipelineAttributeFilters.removeAll { $0 == filter }
            } else {
                appState.pipelineAttributeFilters.append(filter)
            }
        }
    }

    private func applyPlatformFilter(_ platform: String) {
        appState.commitLibraryFilterChange {
            appState.platformFilter = platform.lowercased()
        }
    }

    private func applyTypeFilter(_ typeLabel: String) {
        appendSearchToken("type:\(typeLabel.lowercased())")
    }

    private func applyAspectRatioFilter(_ info: FileInfo) {
        if let width = info.width, let height = info.height, height > 0 {
            appendSearchToken("ratio:\(width):\(height)")
        } else if let ratio = info.aspectRatioString {
            appendSearchToken("ratio:\(ratio)")
        }
    }

    private func applySourceFilter() {
        let source = item.metadata.source
        let value = source.host ?? source.absoluteString
        appendSearchToken("source:\(value)")
    }

    private func applyCaptionTermFilter(_ term: String) {
        appendSearchToken(term, searchScope: .all)
    }

    private func appendSearchToken(_ token: String, searchScope: SearchScope? = nil) {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { return }

        let existingTokens = appState.filterText
            .split(separator: " ")
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased() }
        guard !existingTokens.contains(normalizedToken.lowercased()) else { return }

        let queryToken = normalizedToken.contains(" ") ? "\"\(normalizedToken)\"" : normalizedToken
        appState.commitLibraryFilterChange {
            if let searchScope {
                appState.searchScope = searchScope
            }
            if appState.filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                appState.filterText = queryToken
            } else {
                appState.filterText += " \(queryToken)"
            }
        }
    }

    // MARK: - ML Insights Section

    private func generatedCaptionSection(_ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("generated caption")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(caption)
                .font(.callout.italic())
                .foregroundStyle(.primary.opacity(0.85))
                .textSelection(.enabled)
                .lineLimit(isGeneratedCaptionExpanded ? 20 : 4)

            let isLongCaption = caption.count > 320 || caption.split(whereSeparator: { $0.isNewline }).count > 4
            if isLongCaption {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isGeneratedCaptionExpanded.toggle()
                    }
                } label: {
                    Label(isGeneratedCaptionExpanded ? "Show less" : "Show more", systemImage: isGeneratedCaptionExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(Color.accentOrange)
                }
                .buttonStyle(.plain)
            }

            let terms = captionFilterTerms(from: caption)
            if !terms.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(terms, id: \.self) { term in
                        CaptionTermChip(term: term) {
                            applyCaptionTermFilter(term)
                        }
                    }
                }
            }
        }
    }

    private func captionFilterTerms(from caption: String) -> [String] {
        let stopwords: Set<String> = [
            "about", "above", "after", "again", "against", "along", "also", "among",
            "around", "because", "before", "being", "between", "could", "during",
            "from", "into", "near", "over", "showing", "that", "their", "there",
            "these", "this", "through", "under", "with", "within", "would"
        ]

        let words = caption
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 4 && !stopwords.contains($0) }

        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }.prefix(8).map { $0 }
    }

    @ViewBuilder
    private var mlInsightsSection: some View {
        let status = item.pipelineStatus ?? "none"
        if status != "none" {
            VStack(alignment: .leading, spacing: 8) {
                if status == "phase1" || status == "processing" {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                        Text("Analyzing...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if status == "complete" || status == "failed" {
                    if let caption = item.generatedCaption, !caption.isEmpty {
                        generatedCaptionSection(caption)
                    }

                    // Top scene/object labels
                    let filterChips = buildPipelineFilterChips()
                    if !filterChips.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(filterChips, id: \.id) { chip in
                                PipelineAttributeChip(
                                    label: chip.label,
                                    value: chip.valueLabel,
                                    isActive: appState.pipelineAttributeFilters.contains(chip.filter),
                                    action: {
                                        togglePipelineFilter(chip.filter)
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(12)

            Divider()
                .background(Color.white.opacity(0.1))
        }
    }

    private struct PipelineFilterChipEntry {
        let id: String
        let label: String
        let valueLabel: String?
        let filter: AttributeFilter
    }

    private func buildPipelineFilterChips() -> [PipelineFilterChipEntry] {
        var chips = item.mlAttributes
            .compactMap { entry -> (chip: PipelineFilterChipEntry, score: Double)? in
                if entry.key.hasPrefix("scene."), entry.value >= 0.4 {
                    let key = cleanAttributeKey(entry.key, prefix: "scene.")
                    return (PipelineFilterChipEntry(
                        id: "scene.\(key)",
                        label: key,
                        valueLabel: String(format: "%.0f", entry.value * 100),
                        filter: AttributeFilter(module: .scene, key: key, minValue: 0.4)
                    ), entry.value)
                }

                if entry.key.hasPrefix("object."), entry.value >= 0.4 {
                    let key = cleanAttributeKey(entry.key, prefix: "object.")
                    return (PipelineFilterChipEntry(
                        id: "object.\(key)",
                        label: key,
                        valueLabel: String(format: "%.0f", entry.value * 100),
                        filter: AttributeFilter(module: .object, key: key, minValue: 0.4)
                    ), entry.value)
                }

                return nil
            }
            .sorted { $0.score > $1.score }
            .prefix(5)
            .map(\.chip)

        if let personCount = item.mlAttributes["body_pose.person_count"], personCount > 0 {
            chips.append(PipelineFilterChipEntry(
                id: "body_pose.person_count",
                label: "subjects",
                valueLabel: "\(Int(personCount))",
                filter: AttributeFilter(module: .bodyPose, key: "person_count", minValue: 1)
            ))
        }

        if let faceCount = item.mlAttributes["face.count"], faceCount > 0 {
            chips.append(PipelineFilterChipEntry(
                id: "face.count",
                label: "faces",
                valueLabel: "\(Int(faceCount))",
                filter: AttributeFilter(module: .face, key: "count", minValue: 1)
            ))
        }

        return chips
    }

    private func cleanAttributeKey(_ key: String, prefix: String) -> String {
        String(key.dropFirst(prefix.count))
    }

    // MARK: - Pipeline Debug Section

    @ViewBuilder
    private var pipelineDebugSection: some View {
        if item.pipelineStatus != nil || !item.mlAttributes.isEmpty {
            Divider()
                .background(Color.white.opacity(0.1))

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isPipelineDebugExpanded.toggle()
                    }
                } label: {
                    HStack {
                        Image(systemName: isPipelineDebugExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        Text("pipeline debug")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        PipelineStatusCell(status: item.pipelineStatus)
                    }
                }
                .buttonStyle(.plain)
                .padding(12)

                if isPipelineDebugExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        MetadataRow(label: "status", value: item.pipelineStatus ?? "none")
                        MetadataRow(label: "id", value: String(item.id.uuidString.prefix(8)))
                        if let error = item.pipelineLastError {
                            MetadataRow(label: "error", value: error)
                        }
                        if let failedAt = item.pipelineFailedAt {
                            MetadataRow(label: "failed", value: failedAt)
                        }
                        if let retries = item.pipelineRetryCount, retries > 0 {
                            MetadataRow(label: "retries", value: "\(retries)")
                        }
                        let debugAttributes = sidebarDebugAttributes()
                        if !debugAttributes.isEmpty {
                            Text("attributes")
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.6))
                                .padding(.top, 4)
                            ForEach(debugAttributes.keys.sorted(), id: \.self) { key in
                                HStack {
                                    Text(key)
                                        .font(.system(size: 10).monospaced())
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(String(format: "%.3f", debugAttributes[key]!))
                                        .font(.system(size: 10).monospaced())
                                        .foregroundStyle(.primary.opacity(0.7))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func sidebarDebugAttributes() -> [String: Double] {
        item.mlAttributes.filter { entry in
            !sidebarHiddenAttributeKeys.contains(entry.key)
        }
    }

    private var sidebarHiddenAttributeKeys: Set<String> {
        [
            "quality.aesthetics",
            "quality.is_sharp",
            "quality.is_well_exposed",
            "curation.score",
            "caption.text"
        ]
    }
}

// MARK: - MetadataRow

private struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

private struct FilterableMetadataRow: View {
    let label: String
    let value: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            Button(action: action) {
                HStack(spacing: 4) {
                    Text(value)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 9))
                        .opacity(isHovered ? 0.9 : 0.45)
                }
                .foregroundStyle(isHovered ? Color.accentOrange : .primary)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(help)
        }
    }
}

private struct SidebarSectionResizeHandle: View {
    @Binding var height: CGFloat
    let range: ClosedRange<CGFloat>
    let label: String

    @State private var dragStartHeight: CGFloat?
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(isHovered ? 0.16 : 0.08))
            .frame(height: isHovered ? 6 : 4)
            .overlay {
                Capsule()
                    .fill(Color.white.opacity(isHovered ? 0.35 : 0.18))
                    .frame(width: 34, height: 2)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartHeight == nil {
                            dragStartHeight = height
                        }
                        let proposed = (dragStartHeight ?? height) + value.translation.height
                        height = min(max(proposed, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        dragStartHeight = nil
                    }
            )
            .help("Drag to resize the section above")
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(height)) points")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 20 : -20
                height = min(max(height + step, range.lowerBound), range.upperBound)
            }
    }
}

// MARK: - PlatformBadge

private struct PlatformBadge: View {
    let platform: String
    let onFilter: () -> Void

    private var icon: String {
        switch platform.lowercased() {
        case "twitter", "x": return "bird"
        case "instagram": return "camera"
        case "reddit": return "bubble.left.and.bubble.right"
        case "youtube": return "play.rectangle"
        case "tumblr": return "t.square"
        case "flickr": return "f.circle"
        case "pinterest": return "pin"
        case "bluesky", "bsky": return "cloud"
        default: return "globe"
        }
    }

    var body: some View {
        Button(action: onFilter) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(platform)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentOrange)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color(hex: 0x333333))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Filter library by platform: \(platform)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Platform: \(platform)")
        .accessibilityHint("Filters the library by this platform")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - StarToggleButton

private struct StarToggleButton: View {
    let isStarred: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isStarred ? "star.fill" : "star")
                .font(.body)
                .foregroundStyle(isStarred ? Color.accentOrange : (isHovered ? .primary : .secondary))
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(isStarred ? "Unstar" : "Star")
        .accessibilityLabel(isStarred ? "Remove star" : "Add star")
        .accessibilityValue(isStarred ? "starred" : "not starred")
    }
}

private struct AddTagButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text("add")
            }
            .font(.caption)
            .foregroundStyle(Color.accentOrange)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.accentOrange.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityLabel("Add tag")
    }
}

private struct PipelineAttributeChip: View {
    let label: String
    let value: String?
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                if let value {
                    Text(value)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? Color.accentOrange.opacity(0.18) : Color.white.opacity(isHovered ? 0.1 : 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isActive ? Color.accentOrange.opacity(0.45) : Color.white.opacity(0.08), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isActive ? "Remove this filter" : "Filter by \(label)")
        .accessibilityLabel("Filter by \(label)")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

private struct CaptionTermChip: View {
    let term: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(term)
                .font(.system(size: 10))
                .foregroundStyle(isHovered ? Color.accentOrange : .secondary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(isHovered ? 0.1 : 0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Search generated captions for \(term)")
        .accessibilityLabel("Search generated captions for \(term)")
    }
}

/// The shared TagChip plus the inspector's keyboard path: Tab focuses a chip, Delete removes it.
private struct InspectorTagChip: View {
    let tag: String
    let onRemove: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TagChip(name: tag, onRemove: onRemove)
            .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5).opacity(isFocused ? 1 : 0))
            .contentShape(Capsule())
            .focusable()
            // The chip draws its own capsule ring; the system's square ring would sit outside it.
            .focusEffectDisabled()
            .focused($isFocused)
            .modifier(DeleteKeyModifier(action: onRemove))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tag: \(tag)")
            .accessibilityHint("Press Delete to remove")
    }
}

// MARK: - DeleteKeyModifier

private struct DeleteKeyModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.onKeyPress(.delete) {
                action()
                return .handled
            }
        } else {
            content
        }
    }
}

// MARK: - TagInputField

private struct TagInputField: View {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("tag", text: $text)
            .font(.caption.monospaced())
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color(hex: 0x2a2a2a))
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.accentOrange, lineWidth: 1)
                    )
            )
            .frame(width: 80)
            .focused($isFocused)
            .onSubmit(onSubmit)
            .onExitCommand(perform: onCancel)
            .onAppear { isFocused = true }
    }
}

// MARK: - OCRBlockRow

/// Individual OCR text block row in the sidebar.
/// Shows truncated text with hover highlighting and click-to-copy.
/// Displays role badge for non-body blocks (headings, captions, etc.).
private struct OCRBlockRow: View {
    let block: SerializableTextBlock
    let isHovered: Bool
    let isCopied: Bool
    let onHover: (Bool) -> Void
    let onCopy: () -> Void

    @State private var isLocalHover = false

    private var rolePillColor: Color {
        switch block.textRole {
        case .heading: return Color.accentOrange
        case .caption: return .gray
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                // Role badge for non-body blocks
                if block.textRole != .body {
                    Text(block.role)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(rolePillColor.opacity(0.8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(rolePillColor.opacity(0.12)))
                }

                // Role-aware text styling
                Group {
                    switch block.textRole {
                    case .heading:
                        Text(block.text)
                            .font(.caption.bold())
                            .foregroundStyle(.primary)
                    case .caption:
                        Text(block.text)
                            .font(.caption.italic())
                            .foregroundStyle(.primary.opacity(0.7))
                    default:
                        Text(block.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary.opacity(0.9))
                    }
                }
                .lineLimit(isLocalHover || isHovered ? 10 : 2)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .animation(.easeInOut(duration: 0.15), value: isLocalHover)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Copy indicator / button
            if isCopied {
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else if isLocalHover || isHovered {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(Color.accentOrange)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.accentOrange.opacity(0.15) : (isLocalHover ? Color.white.opacity(0.05) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isHovered ? Color.accentOrange.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isLocalHover = hovering
            onHover(hovering)
        }
        .onTapGesture {
            onCopy()
        }
    }
}

// MARK: - Preview

#if DEBUG
struct MetadataPanel_Previews: PreviewProvider {
    static var previews: some View {
        MetadataPanel(
            item: MediaItem(
                id: UUID(),
                basePath: URL(fileURLWithPath: "/tmp/2025-12"),
                metadataFile: URL(fileURLWithPath: "/tmp/2025-12/test.md"),
                mediaFiles: [
                    URL(fileURLWithPath: "/tmp/test1.jpg"),
                    URL(fileURLWithPath: "/tmp/test2.jpg")
                ],
                contextImage: nil,
                metadata: MediaMetadata(
                    source: URL(string: "https://twitter.com/samplegif/status/123")!,
                    platform: "twitter",
                    author: "@samplegif",
                    originalDate: Date().addingTimeInterval(-86400 * 30),
                    archivedDate: Date(),
                    starred: true,
                    tags: ["art", "inspiration", "saved"],
                    notes: "Really interesting perspective on color theory."
                ),
                indexedContent: IndexedContent(
                    ocrText: "Dance major energy right here. The way they move is just incredible. Full commitment."
                ),
                aspectRatio: 1.5
            ),
            onTagsChanged: { _ in },
            onNotesChanged: { _, _ in },
            onStarChanged: { _ in }
        )
        .frame(height: 600)
        .environmentObject(AppState())
    }
}
#endif
