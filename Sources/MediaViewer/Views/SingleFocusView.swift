import SwiftUI
import AVKit
import AppKit
import CoreMedia
import UniformTypeIdentifiers

// MARK: - Annotation Tool Shortcut Modifier

/// Handles keyboard shortcut notifications for annotation tools to reduce body complexity
struct AnnotationToolShortcutModifier: ViewModifier {
    @Binding var selectedTool: AnnotationTool
    @Binding var isAnnotationModeActive: Bool
    @Binding var eraserBrushSize: CGFloat
    let isCurrentMediaVideo: Bool
    let onRemoveBackground: () async -> Void
    let onIsolatePerson: () async -> Void

    func body(content: Content) -> some View {
        content
            // Toggle annotation mode via A key (when NOT in annotation mode)
            .onReceive(NotificationCenter.default.publisher(for: .toggleAnnotationMode)) { _ in
                if !isCurrentMediaVideo {
                    isAnnotationModeActive.toggle()
                }
            }
            // Tool selection shortcuts (fire when annotation mode is active via KeyboardShortcutManager context)
            .onReceive(NotificationCenter.default.publisher(for: .annotationSelectTool)) { _ in
                selectedTool = .select
            }
            .onReceive(NotificationCenter.default.publisher(for: .annotationSniperTool)) { _ in
                selectedTool = .subjectSelect
            }
            .onReceive(NotificationCenter.default.publisher(for: .annotationRectangleTool)) { _ in
                selectedTool = .rectangle
            }
            .onReceive(NotificationCenter.default.publisher(for: .annotationArrowTool)) { _ in
                selectedTool = .arrow
            }
            .onReceive(NotificationCenter.default.publisher(for: .annotationLineTool)) { _ in
                selectedTool = .freeform  // L maps to freeform (line drawing)
            }
            .onReceive(NotificationCenter.default.publisher(for: .annotationFreeformTool)) { _ in
                selectedTool = .freeform
            }
            .onReceive(NotificationCenter.default.publisher(for: .annotationHighlighterTool)) { _ in
                selectedTool = .highlighter
            }
            .onReceive(NotificationCenter.default.publisher(for: .annotationEraserTool)) { _ in
                selectedTool = .eraser
            }
            .onReceive(NotificationCenter.default.publisher(for: .annotationBgRemoveTool)) { _ in
                Task { await onRemoveBackground() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .annotationPersonTool)) { _ in
                Task { await onIsolatePerson() }
            }
            // Eraser brush size shortcuts
            .onReceive(NotificationCenter.default.publisher(for: .annotationBrushSizeDecrease)) { _ in
                eraserBrushSize = max(2, eraserBrushSize - 10)
            }
            .onReceive(NotificationCenter.default.publisher(for: .annotationBrushSizeIncrease)) { _ in
                eraserBrushSize = min(300, eraserBrushSize + 10)
            }
    }
}

// MARK: - TrimButton

/// Button to open video trim UI, shown in topBar for video media.
private struct TrimButton: View {
    let onTrim: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTrim) {
            HStack(spacing: 6) {
                Image(systemName: "scissors")
                    .font(.body)
                Text("Trim")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isHovered ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help("Trim video (T)")
        .accessibilityLabel("Trim video")
        .accessibilityIdentifier("trim-video-button")
    }
}

// MARK: - DeleteButton

/// Trash icon button for deleting items from focus view.
/// Shows red highlight on hover for danger affordance.
private struct DeleteButton: View {
    let label: String
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .font(.body)
                .foregroundStyle(isHovered ? .red : .secondary)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.red.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help("\(label) (Delete key)")
        .accessibilityLabel(label)
        .accessibilityIdentifier("focus-delete-button")
    }
}

// MARK: - Item Change Modifier

/// Handles onChange/onAppear events for item navigation and OCR state
struct ItemChangeModifier: ViewModifier {
    let item: MediaItem
    @Binding var selectedMediaIndex: Int
    @Binding var hoveredOCRBlock: SerializableTextBlock?
    @Binding var selectedOCRBlock: SerializableTextBlock?
    @Binding var showOCROverlay: Bool
    @Binding var displayedOCRBlocks: [SerializableTextBlock]
    @Binding var currentAnnotations: AnnotationSet
    @Binding var hasAnnotations: Bool
    @Binding var isEyedropperActive: Bool
    @Binding var isAnnotationModeActive: Bool
    @Binding var navigationTask: Task<Void, Never>?
    let annotationStore: AnnotationStore
    let currentOCRBlocks: [SerializableTextBlock]?
    let loadAnnotations: () async -> Void
    let handleSidebarSelectionChange: (SidebarSelection) -> Void
    let sidebarSelection: SidebarSelection
    let navigationDirection: NavigationDirection
    let prefetchNext: (UUID) -> Void

    private var initialPageIndex: Int {
        SingleFocusPagePolicy.initialPageIndex(
            mediaCount: item.mediaFiles.count,
            hasContextPage: item.contextImage != nil,
            prefersContext: item.prefersContextImage,
            navigationDirection: navigationDirection
        )
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: item.id) { _, _ in
                CrashTelemetry.leave("nav-item id=\(item.id) files=\(item.mediaFiles.count) dir=\(navigationDirection)")
                selectedMediaIndex = initialPageIndex
                hoveredOCRBlock = nil
                selectedOCRBlock = nil
                showOCROverlay = false
                displayedOCRBlocks = []
                isAnnotationModeActive = false
                currentAnnotations = .empty
                hasAnnotations = false
                isEyedropperActive = false
                navigationTask?.cancel()
                navigationTask = Task {
                    annotationStore.clearUndoHistory()
                    guard !Task.isCancelled else { return }
                    await loadAnnotations()
                }
                let currentItemId = item.id
                prefetchNext(currentItemId)
            }
            .onChange(of: showOCROverlay) { _, _ in
                displayedOCRBlocks = showOCROverlay ? (currentOCRBlocks ?? []) : []
            }
            .onChange(of: selectedMediaIndex) { _, _ in
                displayedOCRBlocks = showOCROverlay ? (currentOCRBlocks ?? []) : []
                currentAnnotations = .empty
                hasAnnotations = false
                Task { await loadAnnotations() }
            }
            .onChange(of: item.perFileOCR) { _, _ in
                displayedOCRBlocks = showOCROverlay ? (currentOCRBlocks ?? []) : []
            }
            .onChange(of: item.indexedContent?.ocrTextRegions) { _, _ in
                displayedOCRBlocks = showOCROverlay ? (currentOCRBlocks ?? []) : []
            }
            .onAppear {
                selectedMediaIndex = initialPageIndex
                if showOCROverlay {
                    displayedOCRBlocks = currentOCRBlocks ?? []
                }
            }
            .onChange(of: sidebarSelection) { _, _ in
                handleSidebarSelectionChange(sidebarSelection)
            }
    }
}

// MARK: - Notification Handlers Modifier

/// Handles onReceive notifications for keyboard shortcuts (sub-image nav, copy, open source, etc.)
struct NotificationHandlersModifier: ViewModifier {
    var isEditorActive = false
    /// Media files plus the context screenshot page, when the item has both.
    let pageCount: Int
    @Binding var selectedMediaIndex: Int
    let openSource: () -> Void
    let copyImageToClipboard: () -> Void
    let exportAnnotatedImage: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .prevSubImage)) { _ in
                guard !isEditorActive else { return }
                if pageCount > 1 && selectedMediaIndex > 0 {
                    selectedMediaIndex -= 1
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .nextSubImage)) { _ in
                guard !isEditorActive else { return }
                if pageCount > 1 && selectedMediaIndex < pageCount - 1 {
                    selectedMediaIndex += 1
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSourceURL)) { _ in
                openSource()
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyImageToClipboard)) { _ in
                guard !isEditorActive else { return }
                copyImageToClipboard()
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportAnnotatedImage)) { _ in
                guard !isEditorActive else { return }
                exportAnnotatedImage()
            }
    }
}

// MARK: - Trim and Delete Sheets Modifier

/// Handles trim sheet, trim save mode dialog, trim error alert, trim progress overlay, and delete confirmation sheets
struct TrimAndDeleteSheetsModifier: ViewModifier {
    let item: MediaItem
    let currentDeleteScope: FocusDeleteScope
    @Binding var showTrimSheet: Bool
    @Binding var showTrimSaveModeDialog: Bool
    @Binding var pendingTrimSaveRange: CMTimeRange?
    @Binding var showTrimErrorAlert: Bool
    let trimErrorMessage: String
    @Binding var isTrimming: Bool
    let trimProgress: Double
    @Binding var showDeleteConfirmation: Bool
    @Binding var showDeleteWholeItemConfirmation: Bool
    let deleteFromDisk: Bool
    @Binding var skipDeleteConfirmation: Bool
    let isCurrentMediaTrimmable: Bool
    let currentMediaURL: URL?
    let handleTrimReplaceOriginal: (CMTimeRange) async -> Void
    let handleTrimSaveAsNew: (CMTimeRange) async -> Void
    let handleDelete: () async -> Void
    let handleDeleteWholeItem: () async -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .trimVideo)) { _ in
                if isCurrentMediaTrimmable {
                    showTrimSheet = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteFocusedItem)) { _ in
                if skipDeleteConfirmation {
                    Task { await handleDelete() }
                } else {
                    showDeleteConfirmation = true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteWholeItem)) { _ in
                if skipDeleteConfirmation {
                    Task { await handleDeleteWholeItem() }
                } else {
                    showDeleteWholeItemConfirmation = true
                }
            }
            .sheet(isPresented: $showTrimSheet) {
                if let url = currentMediaURL {
                    VideoTrimSheetWrapper(
                        sourceURL: url,
                        onComplete: { range in
                            if let range = range {
                                pendingTrimSaveRange = range
                                showTrimSaveModeDialog = true
                            }
                        },
                        onDismiss: { showTrimSheet = false }
                    )
                    .frame(minWidth: 800, minHeight: 550)
                }
            }
            .confirmationDialog(
                "Save Trimmed Video",
                isPresented: $showTrimSaveModeDialog,
                titleVisibility: .visible
            ) {
                Button("Replace Original") {
                    if let range = pendingTrimSaveRange {
                        pendingTrimSaveRange = nil
                        Task { await handleTrimReplaceOriginal(range) }
                    }
                }
                Button("Save as New Clip") {
                    if let range = pendingTrimSaveRange {
                        pendingTrimSaveRange = nil
                        Task { await handleTrimSaveAsNew(range) }
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingTrimSaveRange = nil
                }
            } message: {
                Text("Choose how to save the trimmed video.")
            }
            .alert("Trim Failed", isPresented: $showTrimErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(trimErrorMessage)
            }
            .overlay {
                if isTrimming {
                    ZStack {
                        Color.black.opacity(0.6)
                            .ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView(value: trimProgress)
                                .progressViewStyle(.linear)
                                .frame(width: 200)
                            Text("Exporting... \(Int(trimProgress * 100))%")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("Please wait while the video is being trimmed")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(24)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(hex: 0x2a2a2a))
                        )
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isTrimming)
            .sheet(isPresented: $showDeleteConfirmation) {
                DeleteConfirmDialog(
                    itemCount: 1,
                    fileCount: item.mediaFiles.count,
                    hasContext: item.contextImage != nil,
                    scope: currentDeleteScope,
                    deleteFromDisk: deleteFromDisk,
                    onConfirm: { Task { await handleDelete() } },
                    onCancel: { showDeleteConfirmation = false },
                    skipFutureConfirmations: $skipDeleteConfirmation
                )
                .frame(minWidth: 360, minHeight: 220)
            }
            .sheet(isPresented: $showDeleteWholeItemConfirmation) {
                DeleteConfirmDialog(
                    itemCount: 1,
                    fileCount: item.mediaFiles.count,
                    hasContext: item.contextImage != nil,
                    scope: .wholeItem,
                    deleteFromDisk: deleteFromDisk,
                    onConfirm: { Task { await handleDeleteWholeItem() } },
                    onCancel: { showDeleteWholeItemConfirmation = false },
                    skipFutureConfirmations: $skipDeleteConfirmation
                )
                .frame(minWidth: 360, minHeight: 220)
            }
    }
}

/// Sidebar selections are destinations, so every selection transition leaves item focus.
/// Keeping this policy separate makes the synchronous dismissal contract testable without
/// introducing another navigation authority.
enum SingleFocusSidebarNavigationPolicy {
    static func handleSelectionChange(_ selection: SidebarSelection, dismiss: () -> Void) {
        switch selection {
        case .allMedia, .folderYear, .folder, .smartFolder,
             .board, .canvas, .platform, .tag, .recentlyDeleted,
             .rediscover, .duplicates, .visualClusters:
            dismiss()
        }
    }
}

enum SingleFocusNavigationIntent: Equatable {
    case previousMediaOrItem
    case nextMediaOrItem
    case previousItemControl
    case nextItemControl
}

enum SingleFocusNavigationAction: Equatable {
    case selectMedia(index: Int)
    case previousItem
    case nextItem
}

/// A child selection belongs to one parent item only. Entering another parent always starts at
/// its first media asset, regardless of which direction reached it.
enum SingleFocusParentChangePolicy {
    static func initialMediaIndex(navigationDirection: NavigationDirection) -> Int {
        _ = navigationDirection
        return 0
    }
}

/// An item's pages are its media files followed by its context screenshot, when it has both.
/// The context page sits at `mediaCount`, the same address its OCR uses, so arrows, the
/// carousel and the position badge browse it like any other asset. Context-only items show
/// the screenshot as their single page. A stored context preference only picks the first page.
enum SingleFocusPagePolicy {
    static func pages(mediaFiles: [URL], contextImage: URL?) -> [URL] {
        mediaFiles + (contextImage.map { [$0] } ?? [])
    }

    static func pageCount(mediaCount: Int, hasContextPage: Bool) -> Int {
        mediaCount + (hasContextPage ? 1 : 0)
    }

    static func isContextPage(_ index: Int, mediaCount: Int, hasContextPage: Bool) -> Bool {
        hasContextPage && index == mediaCount
    }

    static func initialPageIndex(
        mediaCount: Int,
        hasContextPage: Bool,
        prefersContext: Bool,
        navigationDirection: NavigationDirection
    ) -> Int {
        if hasContextPage && prefersContext { return mediaCount }
        return SingleFocusParentChangePolicy.initialMediaIndex(navigationDirection: navigationDirection)
    }
}

/// Arrow navigation traverses assets inside an item, then continues through the result order.
/// The outer transport controls are intentionally different: their contract is always Previous
/// Result / Next Result, independent of the selected asset index.
enum SingleFocusNavigationPolicy {
    static func action(
        for intent: SingleFocusNavigationIntent,
        selectedMediaIndex: Int,
        mediaCount: Int
    ) -> SingleFocusNavigationAction {
        switch intent {
        case .previousMediaOrItem:
            if mediaCount > 1, selectedMediaIndex > 0 {
                return .selectMedia(index: selectedMediaIndex - 1)
            }
            return .previousItem
        case .nextMediaOrItem:
            if mediaCount > 1, selectedMediaIndex < mediaCount - 1 {
                return .selectMedia(index: selectedMediaIndex + 1)
            }
            return .nextItem
        case .previousItemControl:
            return .previousItem
        case .nextItemControl:
            return .nextItem
        }
    }

    static func perform(
        _ action: SingleFocusNavigationAction,
        selectMedia: (Int) -> Void,
        previousItem: () -> Void,
        nextItem: () -> Void
    ) {
        switch action {
        case .selectMedia(let index):
            selectMedia(index)
        case .previousItem:
            previousItem()
        case .nextItem:
            nextItem()
        }
    }
}

// MARK: - SingleFocusView

/// Full detail view for a single MediaItem.
/// Shows large media, context.png, and metadata panel.
/// Layout per SPEC.md:
/// - Left: main media, with a page strip only for multiple pages
/// - Right: MetadataPanel
struct SingleFocusView: View {
    let item: MediaItem
    let onClose: () -> Void
    let onItemUpdated: (MediaItem) -> Void
    var onPrevItem: (() -> Void)?
    var onNextItem: (() -> Void)?

    @EnvironmentObject var appState: AppState
    @Environment(SettingsStore.self) private var settings
    @State private var selectedMediaIndex: Int = 0
    @State private var isVideoPlaying: Bool = false
    @State private var videoPlaybackRate: Float = 1.0
    @State private var isVideoMuted: Bool = UserDefaults.standard.object(forKey: "videoMuteByDefault") as? Bool ?? true
    @State private var videoVolume: Float = VideoPlaybackDefaults.initialVolume()
    @State private var lastAudibleVideoVolume: Float = max(VideoPlaybackDefaults.initialVolume(), VideoPlaybackDefaults.defaultVolume)
    @State private var videoCurrentTime: Double = 0
    @State private var videoDuration: Double = 0
    @State private var videoSeekRequest: VideoSeekRequest?
    @State private var mediaReloadID = UUID()
    @State private var starPulse: Bool = false
    @State private var showOCROverlay: Bool = false  // Toggle for OCR text region highlighting (default OFF)
    @State private var displayedOCRBlocks: [SerializableTextBlock] = []  // Cached regions to avoid array copies
    @State private var hoveredOCRBlock: SerializableTextBlock?
    @State private var selectedOCRBlock: SerializableTextBlock?
    @State private var showTagOverlay: Bool = false  // Toggle for tag selector overlay (modifier key held)
    @State private var isTagModifierHeld: Bool = false
    @State private var isTagOverlayPinned = false
    @State private var tagOverlayPosition: CGPoint = .zero  // mouse position for radial menu
    // PERF: NOT @State — writing @State on every mouse move causes full body re-eval.
    @State private var mousePositionTracker = MousePositionTracker()
    @State private var hoveredTagName: String? = nil  // Currently hovered tag in radial menu
    @ObservedObject private var tagSettings = TagSettings.shared

    // Saved edits for the displayed asset; the native editor owns all drawing state.
    @State private var currentAnnotations: AnnotationSet = .empty
    @State private var currentAnnotationStyle: ShapeStyle = Self.initialAnnotationStyle()
    @State private var hasAnnotations: Bool = false
    @State private var retainedAssetIssueCount = 0
    @State private var showRetainedAssetData = false
    @StateObject private var annotationStore = AnnotationStore()
    @State private var errorToastMessage: String? = nil  // Shows error toasts for failed actions
    @State private var errorDismissTask: Task<Void, Never>?

    // Navigation task tracking - cancelled on rapid navigation to prevent lag
    @State private var navigationTask: Task<Void, Never>?

    // Video trim state
    @State private var showTrimSheet: Bool = false
    @State private var isTrimming: Bool = false
    @State private var trimProgress: Double = 0.0
    @State private var showTrimErrorAlert: Bool = false
    @State private var trimErrorMessage: String = ""
    @State private var pendingTrimSaveRange: CMTimeRange?  // Range awaiting save mode choice
    @State private var showTrimSaveModeDialog: Bool = false  // Confirmation dialog for save mode

    // Delete state
    @State private var showDeleteConfirmation: Bool = false
    @State private var showDeleteWholeItemConfirmation: Bool = false
    @State private var isImageEditing: Bool = false

    // Shortcuts help overlay
    @State private var showShortcutsOverlay: Bool = false

    // Focus context menu state (right-click)
    @State private var showingFocusContextMenu: Bool = false
    @State private var focusContextMenuPosition: CGPoint = .zero

    // Tagging queue loading state
    @State private var isStartingQueue: Bool = false
    @State private var inspectorTab: FocusInspectorTab = .info

    // Eyedropper state for color sampling
    @State private var isEyedropperActive: Bool = false

    // Session-based annotation editor (gated by feature flag)
    @State private var editorSession: AnnotationEditorSession?
    @State private var editorSessionSourceURL: URL?
    @ObservedObject private var editorRegistry = AnnotationSessionRegistry.shared
    @State private var annotationLoadGeneration = UUID()

    private var deleteFromDisk: Bool {
        settings.deleteFilesFromDisk
    }

    private var showsRelatedPanel: Bool {
        settings.showFocusSidebar && !appState.isAnnotationModeActive
    }

    private func toggleRelatedPanel() {
        withAnimation(.easeInOut(duration: 0.15)) {
            settings.showFocusSidebar.toggle()
        }
    }

    private var toolbarDeleteScope: FocusDeleteScope {
        showingContext && !item.mediaFiles.isEmpty
            ? .wholeItem
            : FocusDeleteScopePolicy.toolbarScope(fileCount: item.mediaFiles.count)
    }

    private var skipDeleteConfirmation: Bool {
        settings.skipDeleteConfirmation
    }

    private var skipDeleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { settings.skipDeleteConfirmation },
            set: { settings.skipDeleteConfirmation = $0 }
        )
    }

    /// Builds the initial annotation style from UserDefaults settings
    private static func initialAnnotationStyle() -> ShapeStyle {
        let strokeWidth = UserDefaults.standard.integer(forKey: "annotationDefaultStrokeWidth")
        let color = UserDefaults.standard.object(forKey: "annotationDefaultColor") != nil
            ? UserDefaults.standard.integer(forKey: "annotationDefaultColor")
            : AnnotationColorDefaults.systemAccentRGBA
        return ShapeStyle(
            strokeColor: color != 0 ? UInt32(color) : UInt32(AnnotationColorDefaults.systemAccentRGBA),
            strokeWidth: strokeWidth > 0 ? CGFloat(strokeWidth) : 3,
            fillColor: nil
        )
    }

    /// Current item's position within its folder (O(1) lookup via cached index)
    private var currentFolderPosition: (index: Int, total: Int)? {
        appState.folderPositionOfItem(id: item.id)
    }

    /// Context is the last page, including the sole page of a context-only item.
    private var hasContextPage: Bool {
        item.contextImage != nil
    }

    private var pageCount: Int {
        SingleFocusPagePolicy.pageCount(mediaCount: item.mediaFiles.count, hasContextPage: hasContextPage)
    }

    private var showingContext: Bool {
        SingleFocusPagePolicy.isContextPage(
            selectedMediaIndex,
            mediaCount: item.mediaFiles.count,
            hasContextPage: hasContextPage
        )
    }

    private var currentMediaURL: URL? {
        if showingContext, let contextImage = item.contextImage {
            return contextImage
        }
        if !item.mediaFiles.isEmpty {
            // Clamp index to valid range to prevent "no media" flash during navigation
            let safeIndex = min(selectedMediaIndex, item.mediaFiles.count - 1)
            return item.mediaFiles[max(0, safeIndex)]
        }
        return item.contextImage
    }

    private var currentAnnotationAssetID: UUID? {
        guard let url = currentMediaURL else { return nil }
        let role: ItemAssetRole = showingContext || item.mediaFiles.isEmpty ? .context : .media
        return item.assets.first {
            $0.role == role && ItemAssetStore.canonicalPath($0.url.path) == ItemAssetStore.canonicalPath(url.path)
        }?.assetID
    }

    /// Time-based media: video, and audio-only files, which play through the same player and transport.
    private var isCurrentMediaVideo: Bool {
        guard let url = currentMediaURL else { return false }
        return ThumbnailGenerator.isVideo(url) || isCurrentMediaAudio
    }

    private var isCurrentMediaAudio: Bool {
        guard let url = currentMediaURL else { return false }
        return TranscriptionQueue.isAudioExtension(url.pathExtension)
    }

    /// False when the displayed file has vanished from disk; edit tools are hidden rather than left to fail.
    private var currentMediaExists: Bool {
        guard let url = currentMediaURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private var isCurrentMediaTrimmable: Bool {
        MediaItemDisplayActionPolicy.isTrimmable(currentMediaURL)
    }

    /// Check if the current image has OCR text regions for overlay display
    private var hasOCRBlocks: Bool {
        guard let regions = currentOCRBlocks else { return false }
        return !regions.isEmpty
    }

    /// Get the OCR text regions for the currently selected media file
    private var currentOCRBlocks: [SerializableTextBlock]? {
        item.ocrBlocks(forFileIndex: currentOCRFileIndex)
    }

    /// Get the OCR text for the currently selected media file
    private var currentOCRText: String? {
        item.ocrText(forFileIndex: currentOCRFileIndex)
    }

    /// Context OCR is stored immediately after the media array. This keeps context-only items at
    /// index 0 while giving mixed media/context items a stable, collision-free address.
    private var currentOCRFileIndex: Int {
        showingContext && item.contextImage != nil ? item.mediaFiles.count : selectedMediaIndex
    }

    // MARK: - Navigation Actions

    private func navigateLeft() {
        performNavigation(.previousMediaOrItem)
    }

    private func navigateRight() {
        performNavigation(.nextMediaOrItem)
    }

    private func navigateToPreviousItem() {
        performNavigation(.previousItemControl)
    }

    private func navigateToNextItem() {
        performNavigation(.nextItemControl)
    }

    private func performNavigation(_ intent: SingleFocusNavigationIntent) {
        let action = SingleFocusNavigationPolicy.action(
            for: intent,
            selectedMediaIndex: selectedMediaIndex,
            mediaCount: pageCount
        )
        SingleFocusNavigationPolicy.perform(
            action,
            selectMedia: { index in selectedMediaIndex = index },
            previousItem: { onPrevItem?() },
            nextItem: { onNextItem?() }
        )
    }

    // MARK: - Item Actions

    private func setStarred(_ starred: Bool) {
        guard item.metadata.starred != starred else { return }
        var updated = item
        updated.metadata.starred = starred
        onItemUpdated(updated)
    }

    private func toggleStar() {
        setStarred(!item.metadata.starred)
    }

    /// X jumps between the context screenshot and the first media file. Browsing never
    /// rewrites the item's stored library-thumbnail preference.
    private func toggleContextPage() {
        guard hasContextPage else { return }
        selectedMediaIndex = showingContext ? 0 : item.mediaFiles.count
    }

    private func triggerStarPulse() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.5)) {
            starPulse = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.75)) {
                starPulse = false
            }
        }
    }

    private func toggleVideoMute() {
        if isVideoMuted || videoVolume <= 0.001 {
            if videoVolume <= 0.001 {
                videoVolume = max(lastAudibleVideoVolume, VideoPlaybackDefaults.defaultVolume)
            }
            isVideoMuted = false
        } else {
            lastAudibleVideoVolume = videoVolume
            isVideoMuted = true
        }
    }

    private func seekVideo(to time: Double) {
        guard isCurrentMediaVideo, let sourceURL = currentMediaURL else { return }
        videoSeekRequest = VideoSeekRequest(sourceURL: sourceURL, time: time)
    }

    /// Stop playback synchronously, then dismiss — otherwise audio runs through the fade-out.
    private func requestClose() {
        isVideoPlaying = false
        let focusedID = appState.focusedItem?.id
        guard let session = editorSession, session.isDirty else { onClose(); return }
        if let url = editorSessionSourceURL { editorRegistry.retain(session, sourceURL: url) }
        Task {
            do {
                try await session.saveNow()
                guard !session.isDirty else { return }
                editorRegistry.releaseIfClean(session)
                if appState.focusedItem?.id == focusedID { onClose() }
            } catch {
                errorToastMessage = error.localizedDescription
                if appState.focusedItem?.id == focusedID { appState.isAnnotationModeActive = true }
            }
        }
    }

    private func refreshCurrentMediaAfterEdit(_ mediaURL: URL) async {
        ThumbnailGenerator.deleteThumbnails(for: item.id)
        await ImageCache.shared.evict(itemId: item.id)
        await ImageCache.shared.evict(url: mediaURL)
        await MainActor.run {
            mediaReloadID = UUID()
        }
        NotificationCenter.default.post(
            name: .mediaStoreDidChange,
            object: nil,
            userInfo: ["itemId": item.id]
        )
    }

    /// Navigate to previous item within the same folder (O(1) via cached index)
    private func navigateToPrevInFolder() {
        guard let prevItem = appState.prevItemInFolder(currentId: item.id) else { return }
        appState.navigationDirection = .backward
        appState.openSingleFocus(prevItem)
    }

    /// Navigate to next item within the same folder (O(1) via cached index)
    private func navigateToNextInFolder() {
        guard let nextItem = appState.nextItemInFolder(currentId: item.id) else { return }
        appState.navigationDirection = .forward
        appState.openSingleFocus(nextItem)
    }

    // MARK: - Image Editing

    private func handleRotateCW() async {
        guard let mediaURL = currentMediaURL else { return }
        do {
            try ImageEditor.rotateClockwise(url: mediaURL)
            await refreshCurrentMediaAfterEdit(mediaURL)
        } catch {
            Log.error("Rotate CW failed: \(error)")
        }
    }

    private func handleRotateCCW() async {
        guard let mediaURL = currentMediaURL else { return }
        do {
            try ImageEditor.rotateCounterClockwise(url: mediaURL)
            await refreshCurrentMediaAfterEdit(mediaURL)
        } catch {
            Log.error("Rotate CCW failed: \(error)")
        }
    }

    private func handleFlipH() async {
        guard let mediaURL = currentMediaURL else { return }
        do {
            try ImageEditor.flipHorizontal(url: mediaURL)
            await refreshCurrentMediaAfterEdit(mediaURL)
        } catch {
            Log.error("Flip H failed: \(error)")
        }
    }

    private func handleFlipV() async {
        guard let mediaURL = currentMediaURL else { return }
        do {
            try ImageEditor.flipVertical(url: mediaURL)
            await refreshCurrentMediaAfterEdit(mediaURL)
        } catch {
            Log.error("Flip V failed: \(error)")
        }
    }

    private func handleConvert(to format: UTType) async {
        guard let mediaURL = currentMediaURL else { return }
        do {
            let newURL = try ImageEditor.convert(url: mediaURL, to: format)
            Log.info("Converted \(mediaURL.lastPathComponent) → \(newURL.lastPathComponent)")
            await refreshCurrentMediaAfterEdit(mediaURL)
        } catch {
            Log.error("Convert failed: \(error)")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !appState.isAnnotationModeActive { topBar }
            if !editorRegistry.failedSessions.isEmpty {
                HStack {
                    Label("Image edits need saving", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Retry Saves") { Task { await editorRegistry.flush() } }
                }
                .font(.callout).padding(10).background(Color.orange.opacity(0.12))
            }
            if retainedAssetIssueCount > 0 {
                HStack {
                    Label("\(retainedAssetIssueCount) saved file data entries need review", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("Review Retained Data") { showRetainedAssetData = true }
                        .disabled(appState.isAnnotationModeActive)
                }
                .font(.callout)
                .padding(10)
                .background(Color.orange.opacity(0.12))
            }
            Divider().background(Color.white.opacity(0.1))
            // Native editing has its own workspace; legacy in-place file tools remain opt-in.
            if isImageEditing && !appState.isAnnotationModeActive && !isCurrentMediaVideo && currentMediaURL != nil {
                editingToolbar
            }
            HSplitView {
                mediaSection
                    .frame(minWidth: 400)
                    .accessibilityLabel("Focused media content")
                    .accessibilityIdentifier("focus-media-content")
                if !appState.isAnnotationModeActive && (appState.showFocusMetadataPanel || showsRelatedPanel) {
                    FocusInspectorColumn(showInfo: appState.showFocusMetadataPanel, showRelated: showsRelatedPanel,
                        selection: $inspectorTab) {
                        focusMetadataPanel
                            .accessibilityLabel("Metadata inspector")
                            .accessibilityIdentifier("focus-metadata-panel")
                    } related: {
                        FocusContextSidebar(item: item, showsHeader: !appState.showFocusMetadataPanel) { related in
                            appState.openSingleFocus(related)
                        }
                        .accessibilityLabel("Related items")
                        .accessibilityIdentifier("focus-related-panel")
                    }
                }
            }
        }
        .background(Color(hex: 0x1a1a1a))
        .onChange(of: settings.showFocusSidebar) { _, visible in
            if visible { inspectorTab = .related }
        }
        .onChange(of: appState.showFocusMetadataPanel) { _, visible in
            if visible { inspectorTab = .info }
        }
        .task(id: currentAnnotationAssetID) {
            await loadAnnotations()
            await refreshRetainedAssetIssues()
        }
        .sheet(isPresented: $showRetainedAssetData, onDismiss: {
            Task { await loadAnnotations(forceReload: true); await refreshRetainedAssetIssues() }
        }) {
            if let store = appState.mediaStore {
                RetainedAssetDataView(store: store, itemID: item.id, displayedAssetID: currentAnnotationAssetID)
            }
        }
        .background { if !appState.isAnnotationModeActive { keyHandlerBackground } }
        .overlay { MouseTrackingView(tracker: mousePositionTracker) }
        .overlay { tagOverlayContent }
        .overlay {
            if showShortcutsOverlay {
                ShortcutsHelpOverlay(isPresented: $showShortcutsOverlay)
            }
        }
        .overlay(alignment: .bottom) { taggingHUDContent }
        .modifier(ItemChangeModifier(
            item: item,
            selectedMediaIndex: $selectedMediaIndex,
            hoveredOCRBlock: $hoveredOCRBlock,
            selectedOCRBlock: $selectedOCRBlock,
            showOCROverlay: $showOCROverlay,
            displayedOCRBlocks: $displayedOCRBlocks,
            currentAnnotations: $currentAnnotations,
            hasAnnotations: $hasAnnotations,
            isEyedropperActive: $isEyedropperActive,
            isAnnotationModeActive: $appState.isAnnotationModeActive,
            navigationTask: $navigationTask,
            annotationStore: annotationStore,
            currentOCRBlocks: currentOCRBlocks,
            loadAnnotations: loadAnnotations,
            handleSidebarSelectionChange: handleSidebarSelectionChange,
            sidebarSelection: appState.sidebarSelection,
            navigationDirection: appState.navigationDirection,
            prefetchNext: { currentItemId in
                Task.detached(priority: .low) {
                    if let nextItem = await appState.nextItemInFolder(currentId: currentItemId),
                       let nextURL = nextItem.mediaFiles.first {
                        _ = await ImageCache.shared.loadFullImage(from: nextURL)
                    }
                    if let prevItem = await appState.prevItemInFolder(currentId: currentItemId),
                       let prevURL = prevItem.mediaFiles.first {
                        _ = await ImageCache.shared.loadFullImage(from: prevURL)
                    }
                }
            }
        ))
        .modifier(NotificationHandlersModifier(
            isEditorActive: appState.isAnnotationModeActive,
            pageCount: pageCount,
            selectedMediaIndex: $selectedMediaIndex,
            openSource: openSource,
            copyImageToClipboard: copyImageToClipboard,
            exportAnnotatedImage: exportAnnotatedImage
        ))
        .onAppear {
            onFocusViewAppear()
            appState.mediaSelectionStore.setActiveDetailAsset(itemID: item.id, url: currentMediaURL)
            closeTagOverlayIfModifierIsUp()
        }
        .onChange(of: currentMediaURL) { _, url in
            appState.mediaSelectionStore.setActiveDetailAsset(itemID: item.id, url: url)
        }
        .onChange(of: item.assets) { _, _ in
            appState.mediaSelectionStore.setActiveDetailAsset(itemID: item.id, url: currentMediaURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            closeTagOverlay()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            closeTagOverlayIfModifierIsUp()
        }
        .onChange(of: appState.focusedItem?.id) { _, _ in
            closeTagOverlayIfModifierIsUp()
        }
        .onChange(of: item.id) { _, _ in
            // A seek belongs to one concrete source. Clear the old request even when both items
            // use media index 0, where the selected-index observer would otherwise not fire.
            videoCurrentTime = 0
            videoDuration = 0
            videoSeekRequest = nil
        }
        .onChange(of: selectedMediaIndex) { _, _ in
            videoCurrentTime = 0
            videoDuration = 0
            videoSeekRequest = nil
            isImageEditing = false
        }
        .onChange(of: currentMediaURL) { _, _ in isImageEditing = false }
        .onChange(of: item.metadata.starred) { oldValue, newValue in
            if oldValue != newValue {
                triggerStarPulse()
            }
        }
        .onChange(of: videoVolume) { _, newValue in
            let clamped = VideoPlaybackDefaults.clampVolume(newValue)
            if clamped != newValue {
                videoVolume = clamped
                return
            }
            VideoPlaybackDefaults.persistVolume(clamped)
            if clamped > 0.001 {
                lastAudibleVideoVolume = clamped
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleAnnotationMode)) { _ in
            guard FeatureFlags.annotate, !isCurrentMediaVideo, !appState.isAnnotationModeActive,
                  editorSession != nil, editorSessionSourceURL == currentMediaURL else { return }
            appState.isAnnotationModeActive = true
        }
        .onChange(of: appState.isAnnotationModeActive) { _, active in
            guard !active, let session = editorSession else { return }
            if session.isDirty, let url = editorSessionSourceURL { editorRegistry.retain(session, sourceURL: url) }
            Task {
                do {
                    if session.isDirty { try await session.saveNow() }
                    editorRegistry.releaseIfClean(session)
                    // Navigation may have been held on this document after a failed save.
                    // Once saved, refresh the new source before leaving its original edits behind.
                    await loadAnnotations()
                } catch {
                    errorToastMessage = error.localizedDescription
                    appState.isAnnotationModeActive = true
                }
            }
        }
        .onDisappear {
            if let session = editorSession, let url = editorSessionSourceURL, session.isDirty {
                editorRegistry.retain(session, sourceURL: url)
                Task { await editorRegistry.flush() }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.isAnnotationModeActive)
        .modifier(TrimAndDeleteSheetsModifier(
            item: item,
            currentDeleteScope: toolbarDeleteScope,
            showTrimSheet: $showTrimSheet,
            showTrimSaveModeDialog: $showTrimSaveModeDialog,
            pendingTrimSaveRange: $pendingTrimSaveRange,
            showTrimErrorAlert: $showTrimErrorAlert,
            trimErrorMessage: trimErrorMessage,
            isTrimming: $isTrimming,
            trimProgress: trimProgress,
            showDeleteConfirmation: $showDeleteConfirmation,
            showDeleteWholeItemConfirmation: $showDeleteWholeItemConfirmation,
            deleteFromDisk: deleteFromDisk,
            skipDeleteConfirmation: skipDeleteConfirmationBinding,
            isCurrentMediaTrimmable: isCurrentMediaTrimmable,
            currentMediaURL: currentMediaURL,
            handleTrimReplaceOriginal: handleTrimReplaceOriginal,
            handleTrimSaveAsNew: handleTrimSaveAsNew,
            handleDelete: handleDelete,
            handleDeleteWholeItem: handleDeleteWholeItem
        ))
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayPause)) { _ in
            if isCurrentMediaVideo {
                isVideoPlaying.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleVideoMute)) { _ in
            if isCurrentMediaVideo {
                toggleVideoMute()
            }
        }
    }

    // MARK: - Metadata Panel

    private var focusMetadataPanel: some View {
        MetadataPanel(
            item: item,
            onTagsChanged: { tags in
                var updated = item
                updated.metadata.tags = tags
                onItemUpdated(updated)
            },
            onNotesChanged: { itemID, notes in
                guard itemID == item.id else {
                    let oldNotes = appState.displayedItem(for: itemID)?.metadata.notes
                    appState.updateNotes(for: itemID, oldNotes: oldNotes, newNotes: notes)
                    return
                }

                var updated = item
                updated.metadata.notes = notes
                onItemUpdated(updated)
            },
            onStarChanged: { starred in
                setStarred(starred)
            },
            currentMediaIndex: currentOCRFileIndex,
            showingContext: showingContext,
            contextImageURL: item.contextImage,
            showsStarToggle: false,
            hoveredOCRBlock: hasOCRBlocks ? $hoveredOCRBlock : nil,
            showOCROverlay: hasOCRBlocks && !isCurrentMediaVideo ? $showOCROverlay : nil,
            onReprocessOCR: { itemID in
                appState.reprocessOCR(for: itemID)
            },
            videoPlaybackTime: isCurrentMediaVideo ? videoCurrentTime : nil,
            onSeekToVideoTime: isCurrentMediaVideo ? { time in
                seekVideo(to: time)
            } : nil
        )
    }

    // MARK: - Editing Toolbar

    private var editingToolbar: some View {
        HStack(spacing: 12) {
            Spacer()

            Button {
                Task { await handleRotateCCW() }
            } label: {
                Label("Rotate 90° Left", systemImage: "rotate.left")
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
            .help("Modify current file in place: rotate 90° counter-clockwise")

            Button {
                Task { await handleRotateCW() }
            } label: {
                Label("Rotate 90° Right", systemImage: "rotate.right")
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
            .help("Modify current file in place: rotate 90° clockwise")

            Divider().frame(height: 16)

            Button {
                Task { await handleFlipH() }
            } label: {
                Label("Flip Horizontally", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
            .help("Modify current file in place: flip horizontally")

            Button {
                Task { await handleFlipV() }
            } label: {
                Label("Flip Vertically", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
            .help("Modify current file in place: flip vertically")

            Divider().frame(height: 16)

            Menu {
                Button("Save JPEG Copy") {
                    Task { await handleConvert(to: .jpeg) }
                }
                Button("Save PNG Copy") {
                    Task { await handleConvert(to: .png) }
                }
                Button("Save HEIC Copy") {
                    Task { await handleConvert(to: .heic) }
                }
            } label: {
                Label("Save Copy As…", systemImage: "doc.badge.arrow.up")
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
            .help("Save a sibling copy in another format; the current file is unchanged")

            Spacer()
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Key Handler Background

    private var keyHandlerBackground: some View {
        SingleFocusKeyHandler(
            onClose: {
                if isEyedropperActive {
                    isEyedropperActive = false
                } else {
                    requestClose()
                }
            },
            onLeft: navigateLeft,
            onRight: navigateRight,
            onStar: toggleStar,
            onTogglePreferredDisplay: hasContextPage ? { toggleContextPage() } : nil,
            onModifierChanged: { isPressed in
                guard !isTagOverlayPinned else { return }
                if isPressed {
                    isTagModifierHeld = true
                    tagOverlayPosition = mousePositionTracker.position
                    hoveredTagName = nil
                    showTagOverlay = true
                } else {
                    let shouldApplyHoveredTag = showTagOverlay && !NSEvent.modifierFlags.contains(tagSettings.modifierKey.eventFlag)
                    isTagModifierHeld = false
                    if shouldApplyHoveredTag, let tagName = hoveredTagName {
                        var updated = item
                        updated.metadata.tags = TagOverlaySelection.toggled(tagName, in: updated.metadata.tags)
                        onItemUpdated(updated)
                    }
                    closeTagOverlay()
                }
            },
            onShowShortcuts: {
                showShortcutsOverlay.toggle()
            },
            modifierKey: tagSettings.modifierKey
        )
    }

    // MARK: - Tag Overlay Content

    private func closeTagOverlay() {
        isTagOverlayPinned = false
        isTagModifierHeld = false
        hoveredTagName = nil
        showTagOverlay = false
    }

    private func closeTagOverlayIfModifierIsUp() {
        if !isTagOverlayPinned && !NSEvent.modifierFlags.contains(tagSettings.modifierKey.eventFlag) {
            closeTagOverlay()
        }
    }

    @ViewBuilder
    private var tagOverlayContent: some View {
        if showTagOverlay && (isTagModifierHeld || isTagOverlayPinned) && appState.taggingQueue?.isActive != true {
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture { closeTagOverlay() }
                    TagOverlay(
                        currentTags: item.metadata.tags,
                        onTagsChanged: { newTags in
                            var updated = item
                            updated.metadata.tags = newTags
                            onItemUpdated(updated)
                        },
                        onDismiss: { closeTagOverlay() },
                        position: tagOverlayPosition,
                        hoveredTagName: $hoveredTagName,
                        onBeginTextEntry: { isTagOverlayPinned = true }
                    )
                    .position(
                        x: min(max(tagOverlayPosition.x, 180), geo.size.width - 180),
                        y: min(max(tagOverlayPosition.y, 180), geo.size.height - 180)
                    )
                }
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.15)))
        }
    }

    // MARK: - Tagging HUD Content

    @ViewBuilder
    private var taggingHUDContent: some View {
        if let queue = appState.taggingQueue, queue.isActive {
            TaggingHUD(viewModel: queue)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: queue.isActive)
        }
    }

    // MARK: - Focus Context Menu (Right-Click)

    /// Transparent overlay that detects right-clicks on the media section.
    /// Suppressed during annotation mode so drawing tools get the events.
    @ViewBuilder
    private var focusRightClickOverlay: some View {
        if !appState.isAnnotationModeActive {
            FocusRightClickDetector { position in
                // The detector and menu share mediaSection coordinates; (0, 0) is valid too.
                focusContextMenuPosition = position
                showingFocusContextMenu = true
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Context menu overlay with dismiss backdrop, positioned at click location.
    @ViewBuilder
    private var focusContextMenuOverlay: some View {
        if showingFocusContextMenu {
            FocusContextMenuOverlay(
                position: focusContextMenuPosition,
                actions: buildFocusContextMenuActions(),
                onDismiss: { showingFocusContextMenu = false }
            )
            .transition(.opacity.animation(.easeInOut(duration: 0.1)))
        }
    }

    /// Assembles the actions struct from existing SingleFocusView functions and state.
    private func buildFocusContextMenuActions() -> FocusContextMenuActions {
        let isMulti = item.mediaFiles.count > 1

        return FocusContextMenuActions(
            // Navigate
            onPrevItem: appState.canNavigateToPreviousResult && onPrevItem != nil ? {
                onPrevItem?()
            } : nil,
            onNextItem: appState.canNavigateToNextResult && onNextItem != nil ? {
                onNextItem?()
            } : nil,
            onPrevInSet: pageCount > 1 && selectedMediaIndex > 0 ? {
                selectedMediaIndex -= 1
            } : nil,
            onNextInSet: pageCount > 1 && selectedMediaIndex < pageCount - 1 ? {
                selectedMediaIndex += 1
            } : nil,
            hasMultiplePages: pageCount > 1,
            isMultiFile: isMulti,

            // Organize
            isStarred: item.metadata.starred,
            onToggleStar: toggleStar,
            onAddTag: {
                appState.showTagInput = true
            },
            onAddToBoard: {
                NotificationCenter.default.post(name: .addToBoard, object: nil)
            },
            onAddToRediscover: {
                NotificationCenter.default.post(name: .addToRediscover, object: nil)
            },

            // Clipboard & Export
            onCopyImage: copyImageToClipboard,
            onCopyFilePath: copyCurrentMediaPath,
            onCopySourceURL: {
                let urlString = item.metadata.source.absoluteString
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlString, forType: .string)
            },
            onQuickExport: {
                NotificationCenter.default.post(name: .quickExport, object: nil)
            },
            hasAnnotations: hasAnnotations,
            onExportAnnotated: hasAnnotations ? {
                NotificationCenter.default.post(name: .exportAnnotatedImage, object: nil)
            } : nil,

            // File
            onRevealInFinder: {
                MediaFileAction.reveal.perform(context: focusedActionContext, appState: appState)
            },
            onOpenSource: openSource,
            isVideo: isCurrentMediaVideo,
            onTrimVideo: isCurrentMediaTrimmable ? { showTrimSheet = true } : nil,
            hasOCR: hasOCRBlocks,
            showingOCROverlay: showOCROverlay,
            onToggleOCR: hasOCRBlocks ? { showOCROverlay.toggle() } : nil,
            onReprocessOCR: hasOCRBlocks ? { appState.reprocessOCR(for: item.id) } : nil,

            // View
            showingMetadataPanel: appState.showFocusMetadataPanel,
            onToggleMetadataPanel: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.showFocusMetadataPanel.toggle()
                }
            },
            showingRelatedPanel: settings.showFocusSidebar,
            onToggleRelatedPanel: toggleRelatedPanel,

            // Destructive
            onDeleteCurrentFile: showingContext && !item.mediaFiles.isEmpty ? nil : {
                if skipDeleteConfirmation {
                    Task { await handleDelete() }
                } else {
                    showDeleteConfirmation = true
                }
            },
            onDeleteWholeItem: (isMulti || showingContext) ? {
                if skipDeleteConfirmation {
                    Task { await handleDeleteWholeItem() }
                } else {
                    showDeleteWholeItemConfirmation = true
                }
            } : nil,
            transferContext: focusedActionContext
        )
    }

    // MARK: - Top Bar

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                topBarNavigation
                Spacer(minLength: 12)
                topBarActions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) { topBarNavigation; Spacer(minLength: 0) }
                FlowLayout(spacing: 6) { topBarActions }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(hex: 0x1f1f1f))
    }

    @ViewBuilder private var topBarNavigation: some View {
            // Back button - larger hit target, hover state
            BackButton(action: requestClose)

            FocusToolbarIconButton(
                systemImage: "sidebar.left",
                accessibilityLabel: "Related panel",
                isActive: settings.showFocusSidebar,
                action: toggleRelatedPanel
            )
            .help(settings.showFocusSidebar ? "Hide related items" : "Show related items")
            .accessibilityValue(settings.showFocusSidebar ? "visible" : "hidden")
            .accessibilityIdentifier("focus-related-toggle")

            Image(systemName: "doc.on.doc")
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .help("Drag the displayed file to Finder or another app")
                .accessibilityLabel("Drag displayed file")
                .mediaFileDrag { try focusedTransferPlan() }

            // Inline folder position indicator; "1 of 1" with two dead chevrons is just chrome.
            if let position = currentFolderPosition, position.total > 1 {
                FolderPositionIndicator(
                    folderName: item.folderName,
                    position: position,
                    onPrev: navigateToPrevInFolder,
                    onNext: navigateToNextInFolder
                )
            }

    }

    @ViewBuilder private var topBarActions: some View {
            FocusToolbarIconButton(
                systemImage: item.metadata.starred ? "star.fill" : "star",
                accessibilityLabel: item.metadata.starred ? "Unstar item" : "Star item",
                isActive: item.metadata.starred,
                activeColor: Color.accentOrange,
                action: toggleStar
            )
            .scaleEffect(starPulse ? 1.24 : 1.0)
            .help(item.metadata.starred ? "Unstar (S)" : "Star (S)")
            .accessibilityIdentifier("focus-star-toggle")

            // Annotation/Trim toggle (mutually exclusive by media type)
            if isCurrentMediaTrimmable {
                TrimButton {
                    showTrimSheet = true
                }
            } else if FeatureFlags.annotate, currentMediaExists, !isCurrentMediaVideo {
                AnnotationModeToggle(
                    isActive: $appState.isAnnotationModeActive,
                    hasAnnotations: hasAnnotations
                )
                .disabled(editorSession == nil || editorSessionSourceURL != currentMediaURL || isCurrentMediaVideo)
            }

            // Batch tagging queue toggle
            Button {
                if let queue = appState.taggingQueue, queue.isActive {
                    queue.exitTagging()
                    appState.taggingQueue = nil
                } else {
                    isStartingQueue = true
                    Task {
                        defer { isStartingQueue = false }
                        let store = appState.mediaStore
                        guard let store = store else { return }
                        let queue = TaggingQueueViewModel(mediaStore: store)
                        appState.taggingQueue = queue
                        await queue.startQueue(scope: .untagged, startingItemId: item.id)
                        // Clean up dead queue if it didn't activate (empty results)
                        if !queue.isActive {
                            appState.taggingQueue = nil
                            showError(queue.emptyQueueMessage ?? "All items are already tagged")
                            return
                        }
                        // Focus on the queue's starting item (may differ if current item isn't untagged)
                        if let startItem = queue.currentItem {
                            appState.openSingleFocus(startItem)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if isStartingQueue {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "tag.square")
                            .font(.body)
                    }
                    if let queue = appState.taggingQueue, queue.isActive {
                        Text("[\(queue.currentIndex + 1)/\(queue.totalCount)]")
                            .font(.caption.monospacedDigit())
                    }
                }
                .foregroundStyle(appState.taggingQueue?.isActive == true ? Color.accentColor : .secondary)
                .frame(minWidth: 36, minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .disabled(isStartingQueue)
            .help(appState.taggingQueue?.isActive == true ? "Exit tagging mode" : "Start batch tagging (untagged items)")
            .accessibilityLabel("Batch tagging")
            .accessibilityIdentifier("focus-tagging-queue-toggle")

            // Metadata panel toggle
            FocusToolbarIconButton(
                systemImage: "sidebar.right",
                accessibilityLabel: "Metadata panel",
                isActive: appState.showFocusMetadataPanel
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.showFocusMetadataPanel.toggle()
                }
            }
            .help(appState.showFocusMetadataPanel ? "Hide metadata (⌘I)" : "Show metadata (⌘I)")
            .accessibilityValue(appState.showFocusMetadataPanel ? "visible" : "hidden")
            .accessibilityIdentifier("focus-metadata-toggle")

            if !isCurrentMediaVideo, currentMediaExists, !appState.isAnnotationModeActive {
                Button {
                    isImageEditing.toggle()
                } label: {
                    // Not a pencil: these tools rewrite the file in place, unlike the nondestructive editor.
                    Label(isImageEditing ? "Done" : "File tools", systemImage: isImageEditing ? "checkmark" : "wrench.and.screwdriver")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isImageEditing ? Color.accentOrange : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .help(isImageEditing ? "Close file tools" : "Show in-place rotate/flip and format-copy tools")
                .accessibilityIdentifier("focus-image-edit-toggle")
            }

            // Delete button
            DeleteButton(label: toolbarDeleteScope == .currentFile ? "Delete current file" : "Delete item") {
                if toolbarDeleteScope == .wholeItem && showingContext && !item.mediaFiles.isEmpty {
                    if skipDeleteConfirmation {
                        Task { await handleDeleteWholeItem() }
                    } else {
                        showDeleteWholeItemConfirmation = true
                    }
                } else if skipDeleteConfirmation {
                    Task { await handleDelete() }
                } else {
                    showDeleteConfirmation = true
                }
            }

            Button(action: copyCurrentMediaPath) {
                HStack(spacing: 6) {
                    // Distinct from the drag-file handle beside Back, which uses doc.on.doc.
                    Image(systemName: "doc.on.clipboard")
                    Text("Path")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.06))
                )
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .help("Copy current file path")
            .accessibilityLabel("Copy path")

            // Open source button - larger hit target
            Button(action: openSource) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Source")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(Color.accentOrange)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentOrange.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Open source")
            .accessibilityHint("Opens the original \(item.metadata.platform) post in browser")
    }

    // MARK: - Media Section

    private func focusedTransferPlan(source: MediaTransferSource = .displayed) throws -> MediaTransferPlan {
        try focusedActionContext.resolve(source)
    }

    private var focusedActionContext: MediaActionContext {
        let asset = currentMediaURL.flatMap { url in
            item.assets.first { ItemAssetStore.canonicalPath($0.url.path) == ItemAssetStore.canonicalPath(url.path) }
        }
        return MediaActionContext(items: [item], displayedURLs: currentMediaURL.map { [item.id: $0] } ?? [:],
            displayedAssetIDs: asset.map { [item.id: $0.assetID] } ?? [:])
    }

    @ViewBuilder
    private var mediaSection: some View {
        if appState.isAnnotationModeActive, let session = editorSession, let url = editorSessionSourceURL {
            NativeImageEditorView(session: session, sourceURL: url,
                isPresented: $appState.isAnnotationModeActive, initialStyle: currentAnnotationStyle) { document in
                    currentAnnotations = document
                    hasAnnotations = !document.isEmpty
                }
                .id(ObjectIdentifier(session))
        } else {
            viewerMediaSection
        }
    }

    /// Read-only viewer. Media files and the context screenshot are pages of one sequence:
    /// the same viewer renders each, and the strip below browses them like a gallery.
    private var viewerMediaSection: some View {
        FocusPagePreview(mediaFiles: item.mediaFiles, contextImage: item.contextImage,
            selectedIndex: $selectedMediaIndex, showsPositionBadge: currentMediaExists) {
            mainMediaView
        }
        // Scope the local event monitor to the media area. Inspector controls and editors retain
        // their native right-click behavior instead of being consumed by the focus menu.
        .overlay { focusRightClickOverlay }
        .overlay { focusContextMenuOverlay }
    }

    // MARK: - Main Media View

    @ViewBuilder
    private var mainMediaView: some View {
        if let url = currentMediaURL {
            if !FileManager.default.fileExists(atPath: url.path) {
                // File missing from disk — show error instead of blank player/image
                DetailMediaPlaceholder(
                    systemImage: "exclamationmark.triangle",
                    title: "Media file missing",
                    detail: url.lastPathComponent,
                    note: "It was moved or deleted outside NoDraw.",
                    revealURL: FileManager.default.fileExists(atPath: item.metadataFile.path) ? item.metadataFile : nil
                )
            } else if isCurrentMediaVideo {
                UniversalVideoPlayerView(
                    url: url,
                    isPlaying: $isVideoPlaying,
                    playbackRate: $videoPlaybackRate,
                    isMuted: $isVideoMuted,
                    volume: $videoVolume,
                    currentTime: $videoCurrentTime,
                    duration: $videoDuration,
                    seekRequest: $videoSeekRequest,
                    onLeft: navigateLeft,
                    onRight: navigateRight
                )
                .overlay {
                    // Covers the player's own audio artwork; playback continues underneath.
                    if isCurrentMediaAudio {
                        DetailMediaPlaceholder(systemImage: "waveform", title: url.lastPathComponent,
                                               detail: "Audio", note: nil, revealURL: nil)
                            .background(Color(hex: 0x1a1a1a))
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    VideoTransportControls(
                        isPlaying: $isVideoPlaying,
                        isMuted: $isVideoMuted,
                        volume: $videoVolume,
                        rate: $videoPlaybackRate,
                        currentTime: videoCurrentTime,
                        duration: videoDuration,
                        onSeek: seekVideo(to:),
                        onToggleMute: toggleVideoMute,
                        canGoToPreviousResult: appState.canNavigateToPreviousResult,
                        canGoToNextResult: appState.canNavigateToNextResult,
                        onPreviousItem: navigateToPreviousItem,
                        onNextItem: navigateToNextItem
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            } else {
                FullImageViewWithAnnotations(
                    url: url,
                    ocrBlocks: $displayedOCRBlocks,
                    hoveredOCRBlock: $hoveredOCRBlock,
                    selectedOCRBlock: $selectedOCRBlock,
                    annotations: currentAnnotations,
                    errorMessage: errorToastMessage,
                    isEyedropperActive: $isEyedropperActive,
                    onEyedropperColorPicked: { r, g, b in
                        handleEyedropperColorPicked(r: r, g: g, b: b)
                    }
                )
                .id("\(url.path)-\(mediaReloadID)")
                .mediaFileDrag(enabled: { !appState.isAnnotationModeActive && !isEyedropperActive && hoveredOCRBlock == nil }) {
                    try focusedTransferPlan()
                }
            }
        } else {
            // No viewable media, e.g. a document-only item; the sidecar is still reachable.
            DetailMediaPlaceholder(
                systemImage: "doc",
                title: "Nothing to preview",
                detail: item.metadataFile.lastPathComponent,
                note: "This item has no image, video or audio file NoDraw can show.",
                revealURL: FileManager.default.fileExists(atPath: item.metadataFile.path) ? item.metadataFile : nil
            )
        }
    }

    // MARK: - Actions

    private func openSource() {
        NSWorkspace.shared.open(item.metadata.source)
    }

    private func copyCurrentMediaPath() {
        MediaFileAction.copyPaths.perform(context: focusedActionContext, appState: appState)
    }

    private func copyImageToClipboard() {
        guard let url = currentMediaURL else { return }
        guard let sourceImage = NSImage(contentsOf: url) else { return }

        // Issue #2: If annotations exist, render them onto the copied image
        if !currentAnnotations.isEmpty {
            Task {
                if let annotatedImage = await renderImageWithAnnotations(sourceImage: sourceImage, annotations: currentAnnotations) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([annotatedImage])
                    Log.info("Copied annotated image to clipboard")
                } else {
                    // Render failed - copy original image
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([sourceImage])
                }
            }
            return
        }

        // No annotations - copy original image
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([sourceImage])
    }

    // Issue #1: Export annotated image to file
    private func exportAnnotatedImage() {
        guard let url = currentMediaURL else { return }
        guard let sourceImage = NSImage(contentsOf: url) else { return }

        Task {
            let imageToExport: NSImage
            if !currentAnnotations.isEmpty {
                if let annotated = await renderImageWithAnnotations(sourceImage: sourceImage, annotations: currentAnnotations) {
                    imageToExport = annotated
                } else {
                    imageToExport = sourceImage
                }
            } else {
                imageToExport = sourceImage
            }
            showExportPanel(for: imageToExport, defaultName: url.deletingPathExtension().lastPathComponent + "_annotated.png")
        }
    }

    private func showExportPanel(for image: NSImage, defaultName: String) {
        let imageToExport = image

        // Show save panel
        let panel = NSSavePanel()
        panel.title = "Export Annotated Image"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.png, .jpeg, .tiff]
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let saveURL = panel.url else { return }

            // Export the image
            guard let tiffData = imageToExport.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData) else {
                Log.error("Failed to create bitmap for export")
                return
            }

            let imageData: Data?
            let fileExtension = saveURL.pathExtension.lowercased()
            switch fileExtension {
            case "jpg", "jpeg":
                imageData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            case "tiff", "tif":
                imageData = bitmap.representation(using: .tiff, properties: [:])
            default:
                imageData = bitmap.representation(using: .png, properties: [:])
            }

            guard let data = imageData else {
                Log.error("Failed to generate image data for export")
                return
            }

            do {
                try data.write(to: saveURL)
                Log.info("Exported annotated image to \(saveURL.path)")
                NSSound.beep()  // Success feedback
            } catch {
                Log.error("Failed to save annotated image: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Annotation Rendering

    /// Render annotations onto source image using unified renderer.
    /// Handles all shape types including masks and extracted subjects.
    private func renderImageWithAnnotations(sourceImage: NSImage, annotations: AnnotationSet) async -> NSImage? {
        guard let cgSource = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return await AnnotationRenderer.render(
            annotations: annotations,
            onto: cgSource,
            assetStore: AnnotationAssetStore.shared
        )
    }

    // Old renderShapeToContext removed — replaced by AnnotationRenderer (ANNO-030)

    // MARK: - Sidebar Navigation

    /// Handle sidebar selection changes while in focus view.
    /// Route every actual sidebar destination through the existing close/return path.
    private func handleSidebarSelectionChange(_ selection: SidebarSelection) {
        SingleFocusSidebarNavigationPolicy.handleSelectionChange(selection, dismiss: requestClose)
    }

    // MARK: - Video Trim Actions

    /// Replace Original: exports trimmed video over the source file.
    /// The original is backed up as .bak for undo support.
    @MainActor
    private func handleTrimReplaceOriginal(_ range: CMTimeRange) async {
        guard let sourceURL = currentMediaURL else { return }

        isTrimming = true
        trimProgress = 0.0
        defer {
            isTrimming = false
            trimProgress = 0.0
        }

        let service = VideoTrimService()

        do {
            let result = try await service.exportAndReplace(
                source: sourceURL,
                timeRange: range,
                progressHandler: { progress in
                    Task { @MainActor in
                        self.trimProgress = progress
                    }
                }
            )

            // Same URL, new content -- trigger aspect ratio recalc
            onItemUpdated(item)
            if let videoQueue = VideoUnderstandingQueue.sharedIfConfigured,
               item.hasVideo {
                await videoQueue.enqueue(itemId: item.id, force: true)
            }
            if let transcriptionQueue = TranscriptionQueue.sharedIfConfigured,
               item.hasTranscribableMedia {
                await transcriptionQueue.enqueue(itemId: item.id, force: true)
            }

            // Register undo action
            if let store = appState.mediaStore {
                let undoAction = ReplaceOriginalUndoAction(
                    originalURL: result.replacedURL,
                    backupURL: result.backupURL,
                    mediaItem: item,
                    mediaStore: store
                )
                try? await appState.undoStack.performAction(undoAction, skipExecution: true)
            }

            Log.info("Trim replaced original: \(sourceURL.lastPathComponent)")

        } catch {
            Log.error("Trim replace failed: \(error.localizedDescription)")
            trimErrorMessage = error.localizedDescription
            showTrimErrorAlert = true
        }
    }

    /// Save as New Clip: exports trimmed video as a new file with its own sidecar and DB entry.
    @MainActor
    private func handleTrimSaveAsNew(_ range: CMTimeRange) async {
        guard let sourceURL = currentMediaURL else { return }

        isTrimming = true
        trimProgress = 0.0
        defer {
            isTrimming = false
            trimProgress = 0.0
        }

        let service = VideoTrimService()
        let outputURL = VideoTrimService.newClipPath(for: sourceURL)

        do {
            // Export the trimmed clip
            let trimmedURL = try await service.exportTrimmed(
                source: sourceURL,
                timeRange: range,
                outputURL: outputURL,
                progressHandler: { progress in
                    Task { @MainActor in
                        self.trimProgress = progress
                    }
                }
            )

            // Create derivative sidecar inheriting parent metadata
            let metadataURL = try MetadataParser.createDerivativeMetadataFile(
                forMediaAt: trimmedURL,
                parentMetadata: item.metadata,
                parentMetadataPath: item.metadataFile
            )

            // Create new MediaItem for the clip
            let newItemId = UUID()
            let newItem = MediaItem(
                id: newItemId,
                basePath: item.basePath,
                metadataFile: metadataURL,
                mediaFiles: [trimmedURL],
                metadata: MediaMetadata(
                    source: item.metadata.source,
                    platform: item.metadata.platform,
                    author: item.metadata.author,
                    originalDate: item.metadata.originalDate,
                    archivedDate: Date(),
                    starred: false,
                    tags: item.metadata.tags,
                    notes: item.metadata.notes
                ),
                parseStatus: .success
            )

            // Insert into DB
            if let store = appState.mediaStore {
                try await store.insertItem(newItem)
                if let visionQueue = VisionJobQueue.sharedIfConfigured {
                    await visionQueue.enqueue(itemId: newItemId, priority: .normal)
                }
                if let videoQueue = VideoUnderstandingQueue.sharedIfConfigured {
                    await videoQueue.enqueue(itemId: newItemId)
                }
                if let transcriptionQueue = TranscriptionQueue.sharedIfConfigured {
                    await transcriptionQueue.enqueue(itemId: newItemId)
                }

                // Register undo action
                let undoAction = SaveAsNewClipUndoAction(
                    newItemId: newItemId,
                    trimmedFileURL: trimmedURL,
                    metadataFileURL: metadataURL,
                    mediaStore: store
                )
                try? await appState.undoStack.performAction(undoAction, skipExecution: true)
            }

            Log.info("Trim saved as new clip: \(trimmedURL.lastPathComponent)")

        } catch {
            Log.error("Trim save-as-new failed: \(error.localizedDescription)")
            trimErrorMessage = error.localizedDescription
            showTrimErrorAlert = true
        }
    }

    // MARK: - Delete Actions

    /// Handle delete confirmation.
    /// For multi-file items: removes current file only.
    /// For single-file or last file: deletes whole item.
    @MainActor
    private func handleDelete() async {
        showDeleteConfirmation = false

        guard !(showingContext && !item.mediaFiles.isEmpty) else {
            showError("Deleting only the context screenshot isn’t supported")
            return
        }

        guard let store = appState.mediaStore else {
            showError("Delete failed: No media store")
            return
        }

        let deleteService = DeleteService(mediaStore: store)

        if item.mediaFiles.count > 1 {
            // Multi-file: remove current file only
            do {
                let removal = try await deleteService.removeFile(from: item, at: selectedMediaIndex)
                let updated = removal.updatedItem
                onItemUpdated(updated)
                if removal.hasFileErrors {
                    MediaTransferFeedback.shared.reportFileFailures(removal.fileErrors, urls: removal.failedFileURLs,
                        retryTargets: removal.retryTargets, service: deleteService)
                }

                // Navigate carousel
                if selectedMediaIndex >= updated.mediaFiles.count {
                    selectedMediaIndex = max(0, updated.mediaFiles.count - 1)
                }

                // If no files left, delete whole item via undo stack
                if updated.mediaFiles.isEmpty {
                    let itemId = item.id
                    appState.deleteItems([itemId])
                }

                Log.info(removal.hasFileErrors ? "Removed file reference; Trash requires recovery for item \(item.id)" : "Deleted file at index \(selectedMediaIndex) from item \(item.id)")
            } catch {
                showError("Delete failed: \(error.localizedDescription)")
            }
        } else {
            // Single file or last file: delete whole item via undo stack
            let itemId = item.id
            appState.deleteItems([itemId])

            Log.info("Deleted item \(itemId)")
        }
    }

    /// Handle Cmd+Delete: always deletes the entire item regardless of file count.
    /// Unlike handleDelete() which removes only the current sub-image for multi-file items,
    /// this always nukes the whole thing.
    @MainActor
    private func handleDeleteWholeItem() async {
        showDeleteWholeItemConfirmation = false

        let itemId = item.id
        appState.deleteItems([itemId])

        Log.info("Deleted whole item \(itemId) via Cmd+Delete")
    }

    // MARK: - Lifecycle

    private func onFocusViewAppear() {
        PerfLog.event("focusViewOpen", category: .view, context: item.id.uuidString.prefix(8).description)

        // Wire up write-back queue for annotation state persistence
        if annotationStore.writeBackQueue == nil, let store = appState.mediaStore {
            annotationStore.writeBackQueue = store.writeBackQueue
        }

        // Load initial OCR regions (onChange doesn't fire on first load)
        if showOCROverlay {
            displayedOCRBlocks = currentOCRBlocks ?? []
        }
        // Load annotations for this item
        Task { await refreshRetainedAssetIssues() }
    }

    // MARK: - Annotation Actions

    private func refreshRetainedAssetIssues() async {
        guard let store = appState.mediaStore else { return }
        do { retainedAssetIssueCount = try await store.assetAssociationIssues(itemID: item.id).count }
        catch { Log.error("Failed to load retained file data: \(error.localizedDescription)") }
    }

    private func loadAnnotations() async {
        await loadAnnotations(forceReload: false)
    }

    private func loadAnnotations(forceReload: Bool) async {
        let generation = UUID()
        annotationLoadGeneration = generation
        let itemID = item.id
        let index = selectedMediaIndex
        let assetID = currentAnnotationAssetID
        let sourceURL = currentMediaURL
        if !forceReload, let session = editorSession, session.itemId == itemID, session.assetID == assetID,
           (assetID != nil || session.mediaFileIndex == index), editorSessionSourceURL == sourceURL {
            currentAnnotations = session.annotationSet
            hasAnnotations = !session.annotationSet.isEmpty
            return
        }
        if let session = editorSession, session.isDirty {
            if let url = editorSessionSourceURL { editorRegistry.retain(session, sourceURL: url) }
            do {
                try await session.saveNow()
                guard !session.isDirty else { return }
                editorRegistry.releaseIfClean(session)
            } catch {
                errorToastMessage = error.localizedDescription
                appState.isAnnotationModeActive = true
                return // Keep the original source and its retryable document together.
            }
        }
        guard annotationLoadGeneration == generation, !Task.isCancelled else { return }
        editorSession = nil
        editorSessionSourceURL = nil
        if let url = sourceURL,
           let retained = editorRegistry.session(itemID: itemID, assetID: assetID, index: index, sourceURL: url) {
            editorSession = retained
            editorSessionSourceURL = url
            currentAnnotations = retained.annotationSet
            hasAnnotations = !retained.annotationSet.isEmpty
            return
        }
        do {
            let loaded = try await annotationStore.fetchAnnotations(itemId: itemID, mediaFileIndex: index, assetID: assetID)
            guard annotationLoadGeneration == generation, item.id == itemID,
                  currentAnnotationAssetID == assetID, currentMediaURL == sourceURL, !Task.isCancelled else { return }
            currentAnnotations = loaded
            hasAnnotations = !loaded.isEmpty
            if let url = sourceURL, !isCurrentMediaVideo {
                editorSession = AnnotationEditorSession(itemId: itemID, mediaFileIndex: index,
                    annotationSet: loaded, store: annotationStore, assetID: assetID)
                editorSessionSourceURL = url
            }
        } catch {
            guard annotationLoadGeneration == generation else { return }
            Log.error("Failed to load annotations: \(error.localizedDescription)")
            errorToastMessage = error.localizedDescription
            currentAnnotations = .empty
            hasAnnotations = false
            appState.isAnnotationModeActive = false
        }
    }

    /// Shows an error toast that auto-dismisses after 3 seconds
    private func showError(_ message: String) {
        errorToastMessage = message
        NSSound(named: "Basso")?.play()  // Error sound

        // Cancel any pending dismiss and start new timer
        errorDismissTask?.cancel()
        errorDismissTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if errorToastMessage == message {
                    errorToastMessage = nil
                }
            }
        }
    }

    // MARK: - Eyedropper Actions

    /// Handle color picked from eyedropper tool.
    /// Sets the precision color search in appState and closes focus view to show results.
    private func handleEyedropperColorPicked(r: Int, g: Int, b: Int) {
        // Consume the explicit detail transition before recording the new result set.
        // That keeps the detail return anchor separate from the filter's top reset.
        requestClose()
        appState.commitLibraryFilterChange {
            appState.colorSearchRGB = ColorSearchRGB(r: r, g: g, b: b, tolerance: 25)
        }

        Log.info("Eyedropper: picked color RGB(\(r), \(g), \(b)) - starting color search")
    }
}

// MARK: - SingleFocusContainer

/// Container that manages SingleFocusView state and database updates.
/// Embed this in the navigation flow.
struct SingleFocusContainer: View {
    let item: MediaItem
    let onClose: () -> Void

    @EnvironmentObject var appState: AppState
    @State private var currentItem: MediaItem
    @State private var previousNotes: String?

    init(item: MediaItem, onClose: @escaping () -> Void) {
        self.item = item
        self.onClose = onClose
        self._currentItem = State(initialValue: item)
        self._previousNotes = State(initialValue: item.metadata.notes)
    }

    var body: some View {
        SingleFocusView(
            item: currentItem,
            onClose: onClose,
            onItemUpdated: { updated in
                handleItemUpdate(updated)
            },
            onPrevItem: {
                appState.navigateToPrevItem()
            },
            onNextItem: {
                appState.navigateToNextItem()
            }
        )
        .onChange(of: appState.focusedItem?.id) { _, _ in
            // sync when navigating to different item
            if let newItem = appState.focusedItem, newItem.id != currentItem.id {
                // FIX: Use cached item immediately for responsiveness
                currentItem = newItem
                previousNotes = newItem.metadata.notes

                // FIX: Then refresh from database to ensure mediaFiles are current
                // This fixes "No media" bug when cached displayedItems has stale data
                Task {
                    if let store = appState.mediaStore,
                       let refreshed = try? await store.fetchItem(id: newItem.id) {
                        await MainActor.run {
                            // Only update if we're still viewing this item
                            if currentItem.id == refreshed.id {
                                currentItem = refreshed
                                appState.replaceCachedItemIfPresent(refreshed)
                            }
                        }
                    }
                }
            }
        }
        .onReceive(appState.focusedItemPublisher) { newItem in
            guard let newItem, newItem.id == currentItem.id else { return }
            currentItem = newItem
            previousNotes = newItem.metadata.notes
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaStoreDidChange)) { notification in
            // Refresh item when OCR processing completes
            if let changedID = notification.userInfo?["itemId"] as? UUID,
               changedID == currentItem.id {
                Task {
                    if let store = appState.mediaStore,
                       let refreshed = try? await store.fetchItem(id: changedID) {
                        await MainActor.run {
                            currentItem = refreshed
                            appState.replaceCachedItemIfPresent(refreshed)
                        }
                    }
                }
            }
        }
    }

    private func handleItemUpdate(_ updated: MediaItem) {
        guard updated.id == currentItem.id else {
            let oldNotes = appState.displayedItem(for: updated.id)?.metadata.notes
            if oldNotes != updated.metadata.notes {
                appState.updateNotes(
                    for: updated.id,
                    oldNotes: oldNotes,
                    newNotes: updated.metadata.notes
                )
            }
            return
        }

        let old = currentItem
        currentItem = updated
        appState.replaceCachedItemIfPresent(updated)

        // Star changed
        if old.metadata.starred != updated.metadata.starred {
            appState.starItem(updated.id, starred: updated.metadata.starred)
        }

        // Tags added
        let addedTags = Set(updated.metadata.tags).subtracting(old.metadata.tags)
        for tag in addedTags {
            if let store = appState.mediaStore {
                Task {
                    do {
                        let action = AddTagAction(
                            itemId: updated.id,
                            tag: tag,
                            mediaStore: store
                        )
                        try await appState.undoStack.performAction(action)
                    } catch {
                        logError("Failed to add tag: \(error.localizedDescription)")
                    }
                }
            }
        }

        // Tags removed
        let removedTags = Set(old.metadata.tags).subtracting(updated.metadata.tags)
        for tag in removedTags {
            appState.removeTag(tag, from: updated.id)
        }

        // Notes changed (debounced - only register undo when focus leaves)
        // For now, we update notes immediately but could add debouncing
        if old.metadata.notes != updated.metadata.notes {
            appState.updateNotes(
                for: updated.id,
                oldNotes: previousNotes,
                newNotes: updated.metadata.notes
            )
            previousNotes = updated.metadata.notes
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SingleFocusView_Previews: PreviewProvider {
    static var previews: some View {
        SingleFocusContainer(
            item: MediaItem(
                id: UUID(),
                basePath: URL(fileURLWithPath: "/tmp/2025-12"),
                metadataFile: URL(fileURLWithPath: "/tmp/2025-12/test.md"),
                mediaFiles: [
                    URL(fileURLWithPath: "/tmp/test1.jpg"),
                    URL(fileURLWithPath: "/tmp/test2.jpg"),
                    URL(fileURLWithPath: "/tmp/test3.mp4")
                ],
                contextImage: URL(fileURLWithPath: "/tmp/context.png"),
                metadata: MediaMetadata(
                    source: URL(string: "https://twitter.com/samplegif/status/123")!,
                    platform: "twitter",
                    author: "@samplegif",
                    originalDate: Date().addingTimeInterval(-86400 * 30),
                    archivedDate: Date(),
                    starred: true,
                    tags: ["art", "inspiration"],
                    notes: "Great example of color theory in action."
                ),
                indexedContent: IndexedContent(
                    ocrText: "Dance major energy right here. The way they move is just incredible.",
                    ocrTextRegions: [
                        OCRTextRegion(
                            text: "Dance major energy right here.",
                            boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.08),
                            confidence: 0.95
                        ),
                        OCRTextRegion(
                            text: "The way they move is just incredible.",
                            boundingBox: CGRect(x: 0.1, y: 0.6, width: 0.6, height: 0.08),
                            confidence: 0.92
                        )
                    ]
                ),
                aspectRatio: 1.5
            ),
            onClose: {}
        )
        .frame(width: 1200, height: 800)
    }
}
#endif

/// Centered stand-in for media the viewer cannot show: missing files, document-only items,
/// and the audio-only artwork slot. Sits on the viewer background rather than a grey slab.
private struct DetailMediaPlaceholder: View {
    let systemImage: String
    let title: String
    let detail: String
    let note: String?
    let revealURL: URL?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            if let revealURL {
                Button("Show Sidecar in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                }
                .controlSize(.small)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: 360)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
