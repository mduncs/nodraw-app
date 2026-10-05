import Foundation
import Combine
import SwiftUI

// MARK: - Sidebar Selection

/// What's currently selected in the sidebar
enum SidebarSelection: Equatable, Hashable {
    case allMedia
    case folderYear(String)       // Year folder group like "2026"
    case folder(String)           // Year-month folder like "2025-12"
    case smartFolder(UUID)
    case board(UUID)              // Collection board
    case canvas(UUID)             // Infinite canvas view for a folder
    case platform(String)
    case tag(String)
    case recentlyDeleted         // Recover or permanently purge soft-deleted items
    case rediscover               // FSRS spaced repetition review
    case duplicates               // Duplicate detection review
    case visualClusters           // Visual similarity clustering browser

    var displayName: String {
        switch self {
        case .allMedia:
            return "All Media"
        case .folderYear(let year):
            return year
        case .folder(let name):
            return name
        case .smartFolder:
            return "Smart Folder"
        case .board:
            return "Board"
        case .canvas:
            return "Canvas"
        case .platform(let name):
            return LibraryFilterPresentation.platformName(name)
        case .tag(let name):
            return name
        case .recentlyDeleted:
            return "Recently Deleted"
        case .rediscover:
            return "Rediscover"
        case .duplicates:
            return "Duplicates"
        case .visualClusters:
            return "Visual Clusters"
        }
    }
}

// MARK: - Sidebar Item

/// A displayable item in the sidebar with count
struct SidebarItem: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    var count: Int
    let selection: SidebarSelection

    init(name: String, icon: String, count: Int = 0, selection: SidebarSelection) {
        self.id = "\(selection)"
        self.name = name
        self.icon = icon
        self.count = count
        self.selection = selection
    }
}

// MARK: - Sidebar ViewModel

/// Manages sidebar data: folders, smart folders, platforms, and tags.
/// Fetches counts and handles selection state.
@MainActor
final class SidebarViewModel: ObservableObject {
    // MARK: - Published State

    /// Year-month folders from archive
    @Published private(set) var folders: [SidebarItem] = []

    /// Smart folders (default + user-created)
    @Published private(set) var smartFolders: [SmartFolder] = []

    /// Platforms from data
    @Published private(set) var platforms: [SidebarItem] = []

    /// Tags from data
    @Published private(set) var tags: [SidebarItem] = []

    /// Current selection
    @Published var selection: SidebarSelection = .allMedia

    /// Total item count
    @Published private(set) var totalCount: Int = 0

    /// Whether data is loading
    @Published private(set) var isLoading: Bool = false

    /// Error message if load failed
    @Published private(set) var errorMessage: String?

    /// Cached smart folder counts (keyed by folder ID)
    @Published private(set) var smartFolderCounts: [UUID: Int] = [:]

    /// Cached tag colors (precomputed to avoid lookups in view body)
    @Published private(set) var tagColors: [String: Color] = [:]

    /// Count of items due for review (Rediscover)
    @Published private(set) var rediscoverCount: Int = 0

    /// Recoverable soft-deleted items (combine tombstones are excluded).
    @Published private(set) var recentlyDeletedCount: Int = 0

    // MARK: - Dependencies

    private var mediaStore: MediaStore?
    private let reviewScheduler = ReviewScheduler()
    private var archivePath: URL?
    private var cancellables = Set<AnyCancellable>()

    /// Cached regex for folder pattern matching
    private static let yearMonthRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"^\d{4}-\d{2}$"#)
    }()

    // MARK: - Initialization

    init() {}

    /// Configure with dependencies
    func configure(mediaStore: MediaStore, archivePath: URL) {
        self.mediaStore = mediaStore
        self.archivePath = archivePath

        // Observe database changes to refresh counts
        Task {
            mediaStore.changes
                .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
                .sink { [weak self] in
                    Task {
                        await self?.refreshCounts()
                    }
                }
                .store(in: &cancellables)
        }

        // Observe TagSettings changes to re-sort sidebar tags
        TagSettings.shared.$definitions
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.sortTagsByDefinitionOrder()
                self?.precomputeTagColors()
            }
            .store(in: &cancellables)
    }

    // MARK: - Data Loading

    /// Load all sidebar data
    func loadData() async {
        guard let store = mediaStore else { return }

        isLoading = true
        errorMessage = nil

        do {
            // Load in parallel
            async let foldersTask = loadFolders()
            async let smartFoldersTask = store.fetchSmartFolders()
            async let platformsTask = loadPlatforms(store: store)
            async let tagsTask = loadTags(store: store)
            async let totalTask = store.countItems()

            folders = await foldersTask
            smartFolders = try await smartFoldersTask
            platforms = try await platformsTask
            tags = try await tagsTask
            totalCount = try await totalTask

            // Precompute tag colors (avoid lookups in view body)
            precomputeTagColors()

            // If no smart folders exist, seed with defaults
            if smartFolders.isEmpty {
                await seedDefaultSmartFolders(store: store)
            }

            // Load smart folder counts in parallel
            await loadAllSmartFolderCounts()

            // Load rediscover count
            await loadRediscoverCount()

            await loadRecentlyDeletedCount()

            // Load folder, platform, and tag counts
            await refreshCounts()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Precompute tag colors to avoid repeated lookups in view body
    private func precomputeTagColors() {
        var colors: [String: Color] = [:]
        for tag in tags {
            colors[tag.name] = TagSettings.shared.colorOnly(for: tag.name)
        }
        tagColors = colors
    }

    /// Load all smart folder counts in parallel
    private func loadAllSmartFolderCounts() async {
        await withTaskGroup(of: (UUID, Int).self) { group in
            for folder in smartFolders {
                group.addTask { [weak self] in
                    let count = await self?.countForSmartFolder(folder) ?? 0
                    return (folder.id, count)
                }
            }
            for await (id, count) in group {
                smartFolderCounts[id] = count
            }
        }
    }

    /// Load count for a single smart folder and cache it
    func loadSmartFolderCount(_ folder: SmartFolder) async {
        let count = await countForSmartFolder(folder)
        smartFolderCounts[folder.id] = count
    }

    /// Load count of items due for review (Rediscover). Parked with its feature flag:
    /// no FSRS query runs while the Rediscover row is hidden.
    func loadRediscoverCount() async {
        guard FeatureFlags.rediscover else {
            rediscoverCount = 0
            return
        }
        do {
            rediscoverCount = try await reviewScheduler.countDueItems()
        } catch {
            logError("Failed to load rediscover count: \(error.localizedDescription)")
            rediscoverCount = 0
        }
    }

    func loadRecentlyDeletedCount() async {
        guard let store = mediaStore else { return }
        do {
            var filter = FilterState()
            filter.deletionScope = .deletedOnly
            filter.hideJunk = false
            filter.hideSafetyFlagged = false
            recentlyDeletedCount = try await store.countItems(filter: filter)
        } catch {
            logWarning("Failed to load Recently Deleted count: \(error.localizedDescription)")
            recentlyDeletedCount = 0
        }
    }

    /// Refresh counts only (lighter operation) - grouped queries, not one per row
    func refreshCounts() async {
        guard let store = mediaStore else { return }

        do {
            // Re-fetch tag list from DB so newly-added tags appear
            let freshTags = try await loadTags(store: store)
            let freshTagNames = Set(freshTags.map(\.name))
            let currentTagNames = Set(tags.map(\.name))
            if freshTagNames != currentTagNames {
                tags = freshTags
            }

            // Re-fetch folder list so new import folders appear
            let freshFolders = await loadFolders()
            let freshFolderNames = Set(freshFolders.map(\.name))
            let currentFolderNames = Set(folders.map(\.name))
            if freshFolderNames != currentFolderNames {
                folders = freshFolders
            }

            // Re-fetch platforms so a first scan or a capture from a new site appears
            // without relaunching (the grid and filter totals already update).
            let freshPlatforms = try await loadPlatforms(store: store)
            if freshPlatforms.map(\.name) != platforms.map(\.name) {
                platforms = freshPlatforms
            }

            // One grouped query per kind instead of one countItems per row.
            let counts = try await store.fetchSidebarCounts(
                folders: folders.map(\.name),
                platforms: platforms.compactMap { item in
                    // Count by the stored value, never the display label ("Google Arts" ≠ "googlearts").
                    guard case .platform(let rawPlatform) = item.selection else { return nil }
                    return rawPlatform
                },
                tags: tags.map(\.name)
            )
            // Assign each list once so the sidebar redraws once, not per row.
            totalCount = counts.total
            folders = folders.map { item in
                var item = item
                item.count = counts.folders[item.name] ?? 0
                return item
            }
            platforms = platforms.map { item in
                var item = item
                if case .platform(let rawPlatform) = item.selection {
                    item.count = counts.platforms[rawPlatform] ?? 0
                }
                return item
            }
            tags = tags.map { item in
                var item = item
                item.count = counts.tags[TagCanonicalizer.key(item.name)] ?? 0
                return item
            }

            // Also refresh smart folder counts, tag colors, and rediscover count
            await loadAllSmartFolderCounts()
            precomputeTagColors()
            await loadRediscoverCount()
            await loadRecentlyDeletedCount()
        } catch {
            // Silent failure for refresh - data is stale but visible
            logWarning("Failed to refresh sidebar counts: \(error.localizedDescription)")
        }
    }

    // MARK: - Selection

    /// Build FilterState from current selection
    func buildFilterState() -> FilterState {
        var filter = FilterState()

        switch selection {
        case .allMedia:
            // No filters
            break

        case .folderYear(let year):
            // Year group: match all month folders in that year (e.g. "2026-")
            filter.folderPath = "\(year)-"

        case .folder(let folderName):
            // Filter by folder path (e.g., "2025-12")
            filter.folderPath = folderName

        case .smartFolder(let id):
            if let folder = smartFolders.first(where: { $0.id == id }) {
                filter.smartFolder = folder
            }

        case .board(let id):
            // Board filtering handled by BoardView, not grid
            filter.boardId = id

        case .canvas:
            // Canvas uses separate CanvasView, not grid filter
            break

        case .platform(let name):
            filter.platform = name.lowercased()

        case .tag(let name):
            filter.tags = [name]

        case .recentlyDeleted:
            filter.deletionScope = .deletedOnly
            filter.hideJunk = false
            filter.hideSafetyFlagged = false

        case .rediscover:
            // Rediscover uses special FSRS query, not standard filter
            filter.rediscoverMode = true

        case .duplicates:
            // Duplicates opens a separate review overlay, not a grid filter
            break

        case .visualClusters:
            // Visual clusters uses ClusterBrowserView overlay, not grid filter
            break
        }

        return filter
    }

    // MARK: - Smart Folder CRUD

    /// Save a smart folder (create or update)
    func saveSmartFolder(_ folder: SmartFolder) async {
        guard let store = mediaStore else { return }

        do {
            try await store.saveSmartFolder(folder)
            smartFolders = try await store.fetchSmartFolders()
            // Invalidate cached count for this folder so it gets recalculated
            smartFolderCounts[folder.id] = nil
            await loadSmartFolderCount(folder)
        } catch {
            errorMessage = "Failed to save smart folder: \(error.localizedDescription)"
        }
    }

    /// Delete a smart folder
    func deleteSmartFolder(_ folder: SmartFolder) async {
        guard let store = mediaStore else { return }

        do {
            try await store.deleteSmartFolder(id: folder.id)
            smartFolders = try await store.fetchSmartFolders()
            // Remove cached count
            smartFolderCounts.removeValue(forKey: folder.id)

            // If we deleted the selected folder, go back to all
            if case .smartFolder(let id) = selection, id == folder.id {
                selection = .allMedia
            }
        } catch {
            errorMessage = "Failed to delete smart folder: \(error.localizedDescription)"
        }
    }

    /// Get count for a smart folder
    func countForSmartFolder(_ folder: SmartFolder) async -> Int {
        guard let store = mediaStore else { return 0 }

        do {
            var filter = FilterState()
            filter.smartFolder = folder
            return try await store.countItems(filter: filter)
        } catch {
            return 0
        }
    }

    // MARK: - Private Helpers

    private func loadFolders() async -> [SidebarItem] {
        guard let archivePath = archivePath,
              let regex = Self.yearMonthRegex else { return [] }

        let fileManager = FileManager.default

        do {
            let contents = try fileManager.contentsOfDirectory(
                at: archivePath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            var folderItems: [SidebarItem] = []

            for url in contents {
                let name = url.lastPathComponent
                let range = NSRange(name.startIndex..., in: name)

                if regex.firstMatch(in: name, range: range) != nil {
                    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    if isDirectory {
                        folderItems.append(SidebarItem(
                            name: name,
                            icon: "folder",
                            count: 0, // Will be populated by refresh
                            selection: .folder(name)
                        ))
                    }
                }
            }

            // Sort descending (newest first)
            return folderItems.sorted { $0.name > $1.name }
        } catch {
            logError("Failed to enumerate archive folders: \(error.localizedDescription)")
            return []
        }
    }

    private func loadPlatforms(store: MediaStore) async throws -> [SidebarItem] {
        let platforms = try await store.fetchPlatforms()
        return platforms.map { platform in
            SidebarItem(
                name: LibraryFilterPresentation.platformName(platform),
                icon: platformIcon(platform),
                count: 0,
                selection: .platform(platform)
            )
        }
    }

    private func loadTags(store: MediaStore) async throws -> [SidebarItem] {
        let databaseTags = try await store.fetchAllTags()
        let definitionTags = TagSettings.shared.definitions.map(\.name)
        let tags = Self.mergedTagDisplayNames(
            databaseTags: databaseTags,
            definitionTags: definitionTags
        )
        let items = tags.map { tag in
            SidebarItem(
                name: tag,
                icon: "tag",
                count: 0,
                selection: .tag(tag)
            )
        }
        return Self.sortedByTagDefinitions(items)
    }

    /// Merge by canonical identity while preferring the spelling explicitly saved
    /// in tag definitions over whichever item happened to represent a DB key.
    static func mergedTagDisplayNames(
        databaseTags: [String],
        definitionTags: [String]
    ) -> [String] {
        var displayNameByKey: [String: String] = [:]
        for rawName in databaseTags {
            let displayName = TagCanonicalizer.displayName(rawName)
            let key = TagCanonicalizer.key(displayName)
            guard !key.isEmpty, displayNameByKey[key] == nil else { continue }
            displayNameByKey[key] = displayName
        }
        for rawName in definitionTags {
            let displayName = TagCanonicalizer.displayName(rawName)
            let key = TagCanonicalizer.key(displayName)
            guard !key.isEmpty else { continue }
            displayNameByKey[key] = displayName
        }
        return displayNameByKey.values.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    /// Sort sidebar tag items to match TagSettings hierarchy order.
    /// Tags with definitions are ordered by flattened tree walk (parent sortOrder, then children).
    /// Tags without definitions (orphans from DB) are appended alphabetically at the end.
    private static func sortedByTagDefinitions(_ items: [SidebarItem]) -> [SidebarItem] {
        let settings = TagSettings.shared
        // Build a flattened walk order: index by tag name (lowercased)
        var orderMap: [String: Int] = [:]
        var order = 0
        func walk(_ parentId: UUID?) {
            let kids = parentId == nil ? settings.rootTags() : settings.children(of: parentId!)
            for child in kids {
                orderMap[TagCanonicalizer.key(child.name)] = order
                order += 1
                walk(child.id)
            }
        }
        walk(nil)

        // Partition into defined (has order) and orphan (no definition)
        var defined: [(item: SidebarItem, order: Int)] = []
        var orphans: [SidebarItem] = []
        for item in items {
            if let idx = orderMap[TagCanonicalizer.key(item.name)] {
                defined.append((item, idx))
            } else {
                orphans.append(item)
            }
        }
        defined.sort { $0.order < $1.order }
        orphans.sort { TagCanonicalizer.key($0.name) < TagCanonicalizer.key($1.name) }

        return defined.map(\.item) + orphans
    }

    /// Re-sort tags in place to match current TagSettings hierarchy order.
    /// Called when TagSettings definitions change (e.g. reorder in settings UI).
    private func sortTagsByDefinitionOrder() {
        tags = Self.sortedByTagDefinitions(tags)
    }

    private func seedDefaultSmartFolders(store: MediaStore) async {
        for folder in SmartFolder.defaultFolders {
            do {
                try await store.saveSmartFolder(folder)
            } catch {
                logError("Failed to seed default smart folder \(folder.name): \(error.localizedDescription)")
            }
        }

        // Reload
        do {
            smartFolders = try await store.fetchSmartFolders()
        } catch {
            logError("Failed to reload smart folders after seeding: \(error.localizedDescription)")
        }
    }

    private func platformIcon(_ platform: String) -> String {
        switch platform.lowercased() {
        case "twitter", "x":
            return "bird"
        case "instagram":
            return "camera"
        case "reddit":
            return "bubble.left.and.bubble.right"
        case "youtube":
            return "play.rectangle"
        case "tiktok":
            return "music.note"
        case "flickr":
            return "camera.aperture"
        case "googlearts", "google arts":
            return "building.columns"
        case "tumblr":
            return "t.square"
        case "pinterest":
            return "pin"
        case "bluesky", "bsky":
            return "cloud"
        default:
            return "globe"
        }
    }
}
