import Foundation
import SwiftUI
import Combine

// MARK: - Command

/// Context indicator for command palette display (Issue #7)
enum CommandContext: String {
    case grid = "library"
    case detail = "detail"
    case annotate = "annotate"
    case global = ""  // No badge shown
}

// MARK: - Shared Command Reference Catalog

/// The concrete input route behind an advertised command or gesture.
/// Keyboard routes use `ShortcutAction` directly, so stale help entries fail to compile when
/// their implementation route is removed or renamed.
enum CommandReferenceRoute: Equatable {
    case keyboard(ShortcutAction)
    case menu(String)
    case focusView(String)
    case mouse(String)
}

/// Shared, user-facing command metadata. The menu, command palette, full reference panel, and
/// compact focus help reuse these entries instead of maintaining divergent labels by hand.
struct CommandReferenceEntry: Identifiable {
    let id: String
    let input: String
    let title: String
    let help: String
    let context: CommandContext
    let routes: [CommandReferenceRoute]
    let paletteShortcut: KeyboardShortcut?

    init(
        id: String,
        input: String,
        title: String,
        help: String,
        context: CommandContext = .global,
        routes: [CommandReferenceRoute],
        paletteShortcut: KeyboardShortcut? = nil
    ) {
        self.id = id
        self.input = input
        self.title = title
        self.help = help
        self.context = context
        self.routes = routes
        self.paletteShortcut = paletteShortcut
    }

    var contextLabel: String? {
        context == .global ? nil : context.rawValue
    }
}

struct CommandReferenceSection: Identifiable {
    let id: String
    let title: String
    let entries: [CommandReferenceEntry]
}

/// Canonical copy for every shortcut or mouse gesture shown in NoDraw's help UI.
@MainActor
enum AppCommandCatalog {
    static let retainedFileDataTitle = "Retained File Data…"
    static let back = CommandReferenceEntry(
        id: "navigation.back",
        input: "⌥⌘←",
        title: "Back",
        help: "Return through detail, search, filter, and library-destination history",
        routes: [.menu("appState.navigateBack")]
    )
    static let focusFilter = CommandReferenceEntry(
        id: "navigation.focus-filter",
        input: "/",
        title: "Focus Filter Bar",
        help: "Move keyboard focus to the library filter bar",
        context: .grid,
        routes: [.keyboard(.focusFilterBar)],
        paletteShortcut: KeyboardShortcut("/", modifiers: [])
    )
    static let find = CommandReferenceEntry(
        id: "navigation.find",
        input: "⌘F",
        title: "Find…",
        help: "Move keyboard focus to the library filter bar",
        routes: [.menu("appState.focusFilterBar")]
    )
    static let commandPalette = CommandReferenceEntry(
        id: "navigation.command-palette",
        input: "⌘K",
        title: "Command Palette",
        help: "Open the command palette; Return or a click runs the selected command",
        routes: [.menu("appState.showCommandPalette")],
        paletteShortcut: KeyboardShortcut("k", modifiers: .command)
    )
    static let previousResult = CommandReferenceEntry(
        id: "navigation.previous-result",
        input: "P",
        title: "Previous Result",
        help: "Open the previous item in the current result order",
        context: .detail,
        routes: [.keyboard(.previousItem)],
        paletteShortcut: KeyboardShortcut("p", modifiers: [])
    )
    static let nextResult = CommandReferenceEntry(
        id: "navigation.next-result",
        input: "N",
        title: "Next Result",
        help: "Open the next item in the current result order",
        context: .detail,
        routes: [.keyboard(.nextItem)],
        paletteShortcut: KeyboardShortcut("n", modifiers: [])
    )
    static let previousAsset = CommandReferenceEntry(
        id: "navigation.previous-asset",
        input: "[  or  ⌘[",
        title: "Previous Asset",
        help: "Show the previous downloaded asset within the current item",
        context: .detail,
        routes: [.keyboard(.prevSubImage), .menu("prevSubImage notification")],
        paletteShortcut: KeyboardShortcut("[", modifiers: [])
    )
    static let nextAsset = CommandReferenceEntry(
        id: "navigation.next-asset",
        input: "]  or  ⌘]",
        title: "Next Asset",
        help: "Show the next downloaded asset within the current item",
        context: .detail,
        routes: [.keyboard(.nextSubImage), .menu("nextSubImage notification")],
        paletteShortcut: KeyboardShortcut("]", modifiers: [])
    )
    static let previousInFolder = CommandReferenceEntry(
        id: "navigation.previous-in-folder",
        input: "Folder ‹",
        title: "Previous in Folder",
        help: "Open the previous result in this folder",
        context: .detail,
        routes: [.focusView("appState.prevItemInFolder")]
    )
    static let nextInFolder = CommandReferenceEntry(
        id: "navigation.next-in-folder",
        input: "Folder ›",
        title: "Next in Folder",
        help: "Open the next result in this folder",
        context: .detail,
        routes: [.focusView("appState.nextItemInFolder")]
    )
    static let arrowResultContinuation = CommandReferenceEntry(
        id: "navigation.arrow-result-continuation",
        input: "← / →",
        title: "Previous or Next Asset / Result",
        help: "Move between assets, then continue to the adjacent result at an item boundary",
        context: .detail,
        routes: [.focusView("SingleFocusNavigationPolicy")]
    )
    static let pageUp = CommandReferenceEntry(
        id: "navigation.page-up",
        input: "Page Up  (Fn-↑)",
        title: "Page Up in Library",
        help: "Move up one viewport while keeping continuity overlap",
        context: .grid,
        routes: [.keyboard(.pageUp)],
        paletteShortcut: KeyboardShortcut(.pageUp, modifiers: [])
    )
    static let pageDown = CommandReferenceEntry(
        id: "navigation.page-down",
        input: "Page Down  (Fn-↓)",
        title: "Page Down in Library",
        help: "Move down one viewport while keeping continuity overlap",
        context: .grid,
        routes: [.keyboard(.pageDown)],
        paletteShortcut: KeyboardShortcut(.pageDown, modifiers: [])
    )
    static let libraryTop = CommandReferenceEntry(
        id: "navigation.library-top",
        input: "Home  (Fn-←)",
        title: "Scroll to Top of Library",
        help: "Scroll to the beginning of the current library results",
        context: .grid,
        routes: [.keyboard(.firstItem)],
        paletteShortcut: KeyboardShortcut(.home, modifiers: [])
    )
    static let libraryBottom = CommandReferenceEntry(
        id: "navigation.library-bottom",
        input: "End  (Fn-→)",
        title: "Scroll to Bottom of Library",
        help: "Scroll to the end of the current library results",
        context: .grid,
        routes: [.keyboard(.lastItem)],
        paletteShortcut: KeyboardShortcut(.end, modifiers: [])
    )

    static let toggleDisplaySource = CommandReferenceEntry(
        id: "view.toggle-display-source",
        input: "X",
        title: "Jump to Context Screenshot",
        help: "Jump between the context screenshot page and the first media page",
        context: .detail,
        routes: [.focusView("SingleFocusKeyHandler.togglePreferredDisplay")]
    )

    static var keyboardSections: [CommandReferenceSection] {
        var itemEntries: [CommandReferenceEntry] = [
            entry("item.toggle-star", "S", "Toggle Star", "Star or unstar the selected item", .global, [.keyboard(.toggleStar)]),
            entry("item.add-tag", "T", "Add Tag…", "Add a tag to the selected library item", .grid, [.keyboard(.addTag)]),
            entry("item.trim-video", "T", "Trim Video…", "Trim the displayed MP4, MOV, or M4V asset", .detail, [.keyboard(.trimVideo)]),
        ]
        if FeatureFlags.boards {
            itemEntries.append(entry("item.add-board", "B", "Add to Board…", "Add the selected item to a board", .global, [.keyboard(.addToBoard)]))
        }
        if FeatureFlags.rediscover {
            itemEntries.append(entry("item.add-rediscover", "R", "Add to Rediscover", "Add the selected item to review", .global, [.keyboard(.addToRediscover)]))
        }
        itemEntries.append(contentsOf: [
            entry("item.open-source", "O", "Open Source URL", "Open the original post in the browser", .global, [.keyboard(.openSource)]),
            toggleDisplaySource,
            entry("item.copy-image", "⌘C", "Copy Image", "Copy the selected or displayed image when no text field is active", .global, [.menu("copyImageToClipboard notification")]),
            entry("item.quick-export", "⌘E", "Quick Export…", "Export the selected item to Downloads", .global, [.menu("quickExport notification")]),
        ])
        if FeatureFlags.annotate {
            itemEntries.append(entry("item.export-annotated", "⇧⌘E", "Export Annotated Image…", "Export the image with annotations rendered", .detail, [.menu("exportAnnotatedImage notification")]))
        }
        itemEntries.append(contentsOf: [
            entry("item.delete-library", "Delete", "Delete Selection", "Move the selected library items to Recently Deleted", .grid, [.keyboard(.deleteSelected)]),
            entry("item.delete-asset", "Delete", "Delete Displayed Asset", "Delete the displayed asset from the current item", .detail, [.keyboard(.deleteFocused)]),
            entry("item.delete-whole", "⌘Delete", "Delete Entire Item", "Move the whole focused item to Recently Deleted", .detail, [.keyboard(.deleteWholeItem)]),
        ])

        var sections: [CommandReferenceSection] = [
            CommandReferenceSection(id: "navigation", title: "Navigation", entries: [
                back,
                focusFilter,
                find,
                commandPalette,
                previousResult,
                nextResult,
                previousAsset,
                nextAsset,
                arrowResultContinuation,
                entry("navigation.grid-row", "J / K", "Next / Previous Library Row", "Move selection down or up by one visual row", .grid, [.keyboard(.navigateDown), .keyboard(.navigateUp)]),
                entry("navigation.grid-column", "H / L", "Move Left / Right in Library", "Move to the closest item in the adjacent spatial column; stop at the library edge", .grid, [.keyboard(.navigateLeft), .keyboard(.navigateRight)]),
                entry("navigation.arrow-library", "← ↑ → ↓", "Move Library Selection", "Move selection spatially; left and right stop at the library edge", .grid, [.keyboard(.navigateLeft), .keyboard(.navigateUp), .keyboard(.navigateRight), .keyboard(.navigateDown)]),
                entry("navigation.extend-selection", "⇧ + arrows", "Extend Library Selection", "Extend selection using the same spatial navigation rules", .grid, [.keyboard(.extendSelectionLeft), .keyboard(.extendSelectionUp), .keyboard(.extendSelectionRight), .keyboard(.extendSelectionDown)]),
                pageUp,
                pageDown,
                libraryTop,
                libraryBottom,
                entry("navigation.open-space", "Space", "Open Selected Result", "Open the selected library result in detail", .grid, [.keyboard(.togglePreview)]),
                entry("navigation.open-return", "Return", "Open Detail", "Open the selected library result in detail", .grid, [.keyboard(.openDetail)]),
                entry("navigation.escape", "Esc", "Close / Back / Clear", "Dismiss the most local active surface, then move back", .global, [.keyboard(.escape)]),
            ]),
            CommandReferenceSection(id: "item-actions", title: "Item Actions", entries: itemEntries),
            CommandReferenceSection(id: "view", title: "View", entries: [
                entry("view.inspector", "⌘I", "Toggle Inspector", "Show or hide the active metadata inspector", .global, [.menu("toggle inspector")]),
                entry("view.sidebar", "⌃⌘S", "Toggle Sidebar", "Show or hide the navigation sidebar", .global, [.menu("toggleNavigationSidebar notification")]),
                entry("view.density", "[ / ]", "Change Grid Density", "Show more smaller thumbnails or fewer larger thumbnails", .grid, [.keyboard(.decreaseDensity), .keyboard(.increaseDensity)]),
                entry("view.thumbnail-size", "⌘- / ⌘+", "Change Thumbnail Size", "Decrease or increase thumbnail size", .grid, [.menu("gridDensity")]),
                entry("view.full-screen", "⌃⌘F", "Toggle Full Screen", "Enter or leave immersive full screen", .global, [.menu("window.toggleFullScreen")]),
                entry("view.play-pause", "Space", "Play / Pause Video", "Toggle playback for the displayed video", .detail, [.keyboard(.togglePlayPause)]),
                entry("view.mute", "M", "Mute / Unmute Video", "Toggle audio for the displayed video", .detail, [.keyboard(.toggleVideoMute)]),
                entry("view.help", "⌘/", "Keyboard & Mouse Reference", "Show this input reference", .global, [.menu("showKeyboardShortcutsHelp")]),
            ]),
        ]

        if FeatureFlags.annotate {
            sections.append(CommandReferenceSection(id: "annotation", title: "Annotation Mode", entries: [
                entry("annotation.toggle", "A", "Enter / Exit Annotation Mode", "Toggle annotation mode for the displayed image", .detail, [.keyboard(.toggleAnnotation)]),
                entry("annotation.select", "V", "Select Tool", "Choose the annotation selection tool", .annotate, [.keyboard(.annotationToolSelect)]),
                entry("annotation.subject", "S", "Subject Select", "Choose the subject-selection tool", .annotate, [.keyboard(.annotationToolSniper)]),
                entry("annotation.rectangle", "R", "Rectangle Tool", "Choose the rectangle tool", .annotate, [.keyboard(.annotationToolRectangle)]),
                entry("annotation.arrow", "A", "Arrow Tool", "Choose the arrow tool", .annotate, [.keyboard(.annotationToolArrow)]),
                entry("annotation.line", "L", "Line Tool", "Choose the line tool", .annotate, [.keyboard(.annotationToolLine)]),
                entry("annotation.freeform", "F", "Freeform Tool", "Choose the freeform tool", .annotate, [.keyboard(.annotationToolFreeform)]),
                entry("annotation.highlighter", "H", "Highlighter Tool", "Choose the highlighter tool", .annotate, [.keyboard(.annotationToolHighlighter)]),
                entry("annotation.eraser", "E", "Eraser Tool", "Choose the eraser tool", .annotate, [.keyboard(.annotationToolEraser)]),
                entry("annotation.background", "B", "Remove Background", "Run background removal", .annotate, [.keyboard(.annotationToolBgRemove)]),
                entry("annotation.person", "P", "Isolate Person", "Run person isolation", .annotate, [.keyboard(.annotationToolPerson)]),
                entry("annotation.brush", "[ / ]", "Change Brush Size", "Decrease or increase the eraser brush size", .annotate, [.keyboard(.annotationBrushSizeDecrease), .keyboard(.annotationBrushSizeIncrease)]),
            ]))
        }

        sections.append(CommandReferenceSection(id: "edit", title: "Edit", entries: [
            entry("edit.undo", "⌘Z", "Undo", "Undo in the active text field or NoDraw history", .global, [.menu("undo responder or appState")]),
            entry("edit.redo", "⇧⌘Z", "Redo", "Redo in the active text field or NoDraw history", .global, [.menu("redo responder or appState")]),
            entry("edit.select-all", "⌘A", "Select All Loaded Items", "Select every currently loaded library result", .grid, [.menu("selectAll notification")]),
            entry("edit.deselect-all", "⌘D", "Deselect All", "Clear the current library selection", .grid, [.menu("deselectAll notification")]),
            entry("edit.standard", "⌘X / ⌘C / ⌘V", "Cut / Copy / Paste", "Use standard text editing; Copy copies the image when no text field is active", .global, [.menu("responder chain")]),
        ]))

        return sections
    }

    static let mouseSection = CommandReferenceSection(id: "mouse", title: "Mouse", entries: [
        entry("mouse.back", "Mouse Back", "Back", "Return through detail, search, filter, and library-destination history", .global, [.mouse("button 4 → appState.navigateBack")]),
        entry("mouse.forward", "Mouse Forward", "Reopen Last Detail", "From the library, reopen the last focused item", .grid, [.mouse("button 5 → appState.reopenLastFocusedItem")]),
        entry("mouse.middle-drag", "Middle-drag", "Pan Library", "Hold the middle button and drag to pan the library", .grid, [.mouse("MiddleMouseScrollStateMachine.dragging")]),
        entry("mouse.middle-click", "Middle-click", "Toggle Autoscroll", "Click without dragging, then move away from the anchor to control speed", .grid, [.mouse("MiddleMouseScrollStateMachine.autoScrolling")]),
        entry("mouse.stop-autoscroll", "Middle-click / left-click / Esc", "Stop Autoscroll", "A second middle click, a primary click, Escape, focus loss, or closing the window stops autoscroll", .grid, [.mouse("MiddleMouseScrollStateMachine.stopAutoScroll")]),
    ])

    static var focusHelpEntries: [CommandReferenceEntry] {
        let sharedEntries = Dictionary(
            uniqueKeysWithValues: keyboardSections
                .flatMap(\.entries)
                .map { ($0.id, $0) }
        )
        var entries: [CommandReferenceEntry] = [
            entry("focus.close", "Esc", "Close Detail", "Return to the library and keep the current result selected", .detail, [.keyboard(.escape)]),
            arrowResultContinuation,
            previousResult,
            nextResult,
            previousAsset,
            nextAsset,
            sharedEntries["item.toggle-star"],
            sharedEntries["view.toggle-display-source"],
            sharedEntries["view.play-pause"],
            sharedEntries["view.mute"],
            sharedEntries["item.open-source"],
            sharedEntries["item.copy-image"],
            sharedEntries["view.inspector"],
            sharedEntries["item.trim-video"],
            sharedEntries["item.delete-asset"],
        ].compactMap { $0 }
        if FeatureFlags.annotate, let annotation = sharedEntries["annotation.toggle"] {
            entries.insert(annotation, at: min(10, entries.count))
        }
        entries.append(
            entry("focus.help", "?", "Toggle This Reference", "Show or hide focus-view input help", .detail, [.focusView("SingleFocusKeyHandler.showShortcuts")])
        )
        return entries
    }

    /// Every reference rendered on any surface. Repeated IDs are intentional: they prove two
    /// surfaces are reusing one canonical entry rather than carrying duplicated copy.
    static var advertisedSurfaceEntries: [CommandReferenceEntry] {
        keyboardSections.flatMap(\.entries)
            + mouseSection.entries
            + [previousInFolder, nextInFolder]
            + focusHelpEntries
    }

    static var allAdvertisedEntries: [CommandReferenceEntry] {
        var seen = Set<String>()
        return advertisedSurfaceEntries.filter { seen.insert($0.id).inserted }
    }

    private static func entry(
        _ id: String,
        _ input: String,
        _ title: String,
        _ help: String,
        _ context: CommandContext,
        _ routes: [CommandReferenceRoute]
    ) -> CommandReferenceEntry {
        CommandReferenceEntry(
            id: id,
            input: input,
            title: title,
            help: help,
            context: context,
            routes: routes
        )
    }
}

/// A command that can be executed from the command palette.
struct Command: Identifiable {
    let id: String
    let title: String
    let category: CommandCategory
    let shortcut: KeyboardShortcut?
    let icon: String?
    let action: () -> Void
    let isEnabled: (AppState?) -> Bool

    /// Issue #7: Context badge for command palette display
    /// Shows "(grid)", "(detail)", etc. to indicate where the command works
    let context: CommandContext

    /// Primary initializer with context-aware isEnabled
    init(
        id: String,
        title: String,
        category: CommandCategory = .general,
        shortcut: KeyboardShortcut? = nil,
        icon: String? = nil,
        context: CommandContext = .global,
        isEnabled: @escaping (AppState?) -> Bool = { _ in true },
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.shortcut = shortcut
        self.icon = icon
        self.context = context
        self.isEnabled = isEnabled
        self.action = action
    }
}

// MARK: - Command Convenience Extensions

extension Command {
    /// Convenience factory for commands without context awareness (simpler isEnabled)
    static func simple(
        id: String,
        title: String,
        category: CommandCategory = .general,
        shortcut: KeyboardShortcut? = nil,
        icon: String? = nil,
        context: CommandContext = .global,
        isEnabled: @escaping () -> Bool = { true },
        action: @escaping () -> Void
    ) -> Command {
        Command(
            id: id,
            title: title,
            category: category,
            shortcut: shortcut,
            icon: icon,
            context: context,
            isEnabled: { _ in isEnabled() },
            action: action
        )
    }
}

// MARK: - Command Category

enum CommandCategory: String, CaseIterable {
    case navigation = "Navigation"
    case actions = "Actions"
    case filters = "Filters"
    case smartFolders = "Smart Folders"
    case system = "System"
    case general = "General"

    var sortOrder: Int {
        switch self {
        case .navigation: return 0
        case .actions: return 1
        case .filters: return 2
        case .smartFolders: return 3
        case .system: return 4
        case .general: return 5
        }
    }
}

// MARK: - Keyboard Shortcut Display

extension KeyboardShortcut {
    /// Human-readable shortcut string for display
    var displayString: String {
        var parts: [String] = []

        if modifiers.contains(.command) { parts.append("Cmd") }
        if modifiers.contains(.option) { parts.append("Opt") }
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.shift) { parts.append("Shift") }

        // Handle the key - use character directly since switch on KeyEquivalent requires macOS 14+
        let keyChar = key.character
        let keyStr: String
        switch keyChar {
        case "\r": keyStr = "Return"
        case "\u{1B}": keyStr = "Esc"
        case "\u{7F}": keyStr = "Del"
        case "\u{F729}": keyStr = "Home"
        case "\u{F72B}": keyStr = "End"
        case "\u{F72C}": keyStr = "Page Up"
        case "\u{F72D}": keyStr = "Page Down"
        case " ": keyStr = "Space"
        case "\t": keyStr = "Tab"
        default:
            keyStr = String(keyChar).uppercased()
        }

        parts.append(keyStr)
        return parts.joined(separator: "+")
    }
}

// MARK: - Command Registry

/// Central registry for all executable commands.
/// Manages command registration, fuzzy search, and context-aware filtering.
@MainActor
final class CommandRegistry: ObservableObject {
    static let shared = CommandRegistry()

    @Published private(set) var commands: [Command] = []

    /// Recent command IDs - persisted to UserDefaults (Issue #9)
    @Published private(set) var recentCommandIDs: [String] = []

    /// Smart folders loading state (Issue #5)
    @Published private(set) var isLoadingSmartFolders: Bool = false

    private let maxRecentCommands = 5
    private let recentCommandsKey = "CommandPalette.recentCommands"

    private init() {
        // Load recent commands from UserDefaults
        if let saved = UserDefaults.standard.stringArray(forKey: recentCommandsKey) {
            recentCommandIDs = saved
        }
    }

    /// Set smart folders loading state (Issue #5)
    func setSmartFoldersLoading(_ loading: Bool) {
        isLoadingSmartFolders = loading
    }

    // MARK: - Registration

    /// Register a single command
    func register(_ command: Command) {
        // Remove existing command with same ID
        commands.removeAll { $0.id == command.id }
        commands.append(command)
    }

    /// Register multiple commands at once
    func register(_ newCommands: [Command]) {
        for command in newCommands {
            register(command)
        }
    }

    /// Unregister a command by ID
    func unregister(id: String) {
        commands.removeAll { $0.id == id }
    }

    /// Clear all commands
    func clearAll() {
        commands.removeAll()
        recentCommandIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: recentCommandsKey)
    }

    // MARK: - Search

    /// Search commands with fuzzy matching (Issue #6: context-aware filtering)
    /// Returns filtered and sorted commands
    func searchCommands(query: String, appState: AppState? = nil) -> [Command] {
        // Filter to enabled commands, passing appState for context awareness
        var enabledCommands = commands.filter { $0.isEnabled(appState) }

        // Add loading placeholder for smart folders if loading (Issue #5)
        if isLoadingSmartFolders && query.isEmpty {
            // Insert a placeholder command
            let loadingCommand = Command(
                id: "smartfolder.loading",
                title: "Loading smart folders...",
                category: .smartFolders,
                icon: "hourglass",
                action: {}
            )
            enabledCommands.append(loadingCommand)
        }

        guard !query.isEmpty else {
            // Return recent commands first, then all by category
            return sortedByRelevance(enabledCommands)
        }

        let lowercasedQuery = query.lowercased()

        // Score each command based on match quality
        var scoredCommands: [(command: Command, score: Int)] = []

        for command in enabledCommands {
            if let score = fuzzyMatchScore(query: lowercasedQuery, target: command.title.lowercased()) {
                scoredCommands.append((command, score))
            }
        }

        // Sort by score (higher is better), then alphabetically
        return scoredCommands
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.command.title < rhs.command.title
            }
            .map(\.command)
    }

    /// Find closest matching command title for "did you mean" suggestions (Issue #7)
    func findClosestMatch(to query: String) -> String? {
        guard !query.isEmpty else { return nil }

        let lowercasedQuery = query.lowercased()
        var bestMatch: (title: String, score: Int)?

        for command in commands {
            // Use a more lenient matching for suggestions
            let target = command.title.lowercased()

            // Check if any word starts with the query
            let words = target.split(separator: " ").map { String($0) }
            for word in words {
                if word.hasPrefix(lowercasedQuery) || lowercasedQuery.hasPrefix(word.prefix(2)) {
                    let score = 100 - abs(word.count - lowercasedQuery.count)
                    if bestMatch == nil || score > bestMatch!.score {
                        bestMatch = (command.title, score)
                    }
                    break
                }
            }

            // Check edit distance for typos
            if bestMatch == nil {
                let distance = levenshteinDistance(lowercasedQuery, target)
                if distance <= 3 {
                    let score = 50 - distance
                    if bestMatch == nil || score > bestMatch!.score {
                        bestMatch = (command.title, score)
                    }
                }
            }
        }

        return bestMatch?.title
    }

    /// Simple Levenshtein distance for typo detection
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Array = Array(s1)
        let s2Array = Array(s2)
        let m = s1Array.count
        let n = s2Array.count

        if m == 0 { return n }
        if n == 0 { return m }

        var matrix = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)

        for i in 0...m { matrix[i][0] = i }
        for j in 0...n { matrix[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = s1Array[i - 1] == s2Array[j - 1] ? 0 : 1
                matrix[i][j] = min(
                    matrix[i - 1][j] + 1,      // deletion
                    matrix[i][j - 1] + 1,      // insertion
                    matrix[i - 1][j - 1] + cost // substitution
                )
            }
        }

        return matrix[m][n]
    }

    /// Fuzzy match scoring
    /// Returns nil if no match, or a score (higher = better match)
    private func fuzzyMatchScore(query: String, target: String) -> Int? {
        guard !query.isEmpty else { return 100 }

        // Exact match gets highest score
        if target == query {
            return 1000
        }

        // Prefix match is very good
        if target.hasPrefix(query) {
            return 900 + (100 - target.count)
        }

        // Contains match is good
        if target.contains(query) {
            return 800 + (100 - target.count)
        }

        // Word prefix matching (e.g., "gs" matches "Go to Sidebar")
        let words = target.split(separator: " ").map { String($0) }
        let queryChars = Array(query)
        var queryIndex = 0
        var matchedWordStarts = 0

        for word in words {
            if queryIndex < queryChars.count,
               word.lowercased().hasPrefix(String(queryChars[queryIndex])) {
                matchedWordStarts += 1
                queryIndex += 1
            }
        }

        if queryIndex == queryChars.count && matchedWordStarts > 0 {
            return 700 + matchedWordStarts * 50
        }

        // Fuzzy character matching
        var targetIndex = target.startIndex
        var matchCount = 0
        var consecutiveBonus = 0
        var lastMatchIndex: String.Index?

        for char in query {
            while targetIndex < target.endIndex {
                if target[targetIndex] == char {
                    matchCount += 1
                    // Bonus for consecutive matches
                    if let last = lastMatchIndex,
                       target.index(after: last) == targetIndex {
                        consecutiveBonus += 10
                    }
                    lastMatchIndex = targetIndex
                    targetIndex = target.index(after: targetIndex)
                    break
                }
                targetIndex = target.index(after: targetIndex)
            }
        }

        // All query chars must match
        guard matchCount == query.count else { return nil }

        return 500 + consecutiveBonus + (50 - target.count)
    }

    /// Sort commands by recent usage, then category
    private func sortedByRelevance(_ commands: [Command]) -> [Command] {
        return commands.sorted { lhs, rhs in
            let lhsRecent = recentCommandIDs.firstIndex(of: lhs.id) ?? Int.max
            let rhsRecent = recentCommandIDs.firstIndex(of: rhs.id) ?? Int.max

            // Recent commands first
            if lhsRecent != rhsRecent {
                return lhsRecent < rhsRecent
            }

            // Then by category
            if lhs.category.sortOrder != rhs.category.sortOrder {
                return lhs.category.sortOrder < rhs.category.sortOrder
            }

            // Then alphabetically
            return lhs.title < rhs.title
        }
    }

    // MARK: - Execution

    /// Execute an enabled command and track it as recent.
    ///
    /// Callers must supply the current app state for context-sensitive commands. Keeping the
    /// enablement check here (rather than only in the palette's filtered list) closes the race
    /// where focus or selection changes while the palette is dismissing.
    @discardableResult
    func execute(_ command: Command, appState: AppState? = nil) -> Bool {
        guard command.isEnabled(appState) else { return false }

        // Track as recent (Issue #9: persist to UserDefaults)
        recentCommandIDs.removeAll { $0 == command.id }
        recentCommandIDs.insert(command.id, at: 0)
        if recentCommandIDs.count > maxRecentCommands {
            recentCommandIDs = Array(recentCommandIDs.prefix(maxRecentCommands))
        }
        UserDefaults.standard.set(recentCommandIDs, forKey: recentCommandsKey)

        // Execute
        command.action()
        return true
    }

    /// Find and execute a command by ID
    func execute(id: String, appState: AppState? = nil) -> Bool {
        guard let command = commands.first(where: { $0.id == id && $0.isEnabled(appState) }) else {
            return false
        }
        return execute(command, appState: appState)
    }

    // MARK: - Lookup

    /// Get all commands in a category
    func commands(in category: CommandCategory, appState: AppState? = nil) -> [Command] {
        commands.filter { $0.category == category && $0.isEnabled(appState) }
    }

    /// Get a command by ID
    func command(id: String) -> Command? {
        commands.first { $0.id == id }
    }
}

// MARK: - Default Commands

extension CommandRegistry {
    /// Register default application commands
    /// Issue #3: Added shortcuts to more commands
    /// Issue #6: Added context-aware isEnabled closures
    func registerDefaultCommands(appState: AppState) {
        // Split into smaller arrays to help compiler type-checking
        let navigationCommands = buildNavigationCommands(appState: appState)
        let actionCommands = buildActionCommands(appState: appState)
        let filterCommands = buildFilterCommands(appState: appState)
        let systemCommands = buildSystemCommands(appState: appState)

        register(navigationCommands)
        register(actionCommands)
        register(filterCommands)
        register(systemCommands)
    }

    /// Issue #7: Added context badges to commands
    private func buildNavigationCommands(appState: AppState) -> [Command] {
        [
            Command(
                id: "nav.grid",
                title: "Go to Grid",
                category: .navigation,
                shortcut: KeyboardShortcut(.escape),
                icon: "square.grid.3x3",
                context: .detail,  // Issue #7: Context badge
                isEnabled: { state in state?.isShowingSingleFocus == true },
                action: { appState.closeSingleFocus() }
            ),
            Command(
                id: "nav.filter",
                title: AppCommandCatalog.focusFilter.title,
                category: .navigation,
                shortcut: AppCommandCatalog.focusFilter.paletteShortcut,
                icon: "magnifyingglass",
                context: .grid,  // Issue #7: Context badge
                isEnabled: { state in state?.isShowingSingleFocus == false },
                action: { appState.focusFilterBar() }
            ),
            Command(
                id: "nav.nextItem",
                title: AppCommandCatalog.nextResult.title,
                category: .navigation,
                shortcut: AppCommandCatalog.nextResult.paletteShortcut,
                icon: "arrow.right",
                context: .detail,  // Issue #7: Context badge
                isEnabled: { state in state?.canNavigateToNextResult == true },
                action: { appState.navigateToNextItem() }
            ),
            Command(
                id: "nav.prevItem",
                title: AppCommandCatalog.previousResult.title,
                category: .navigation,
                shortcut: AppCommandCatalog.previousResult.paletteShortcut,
                icon: "arrow.left",
                context: .detail,  // Issue #7: Context badge
                isEnabled: { state in state?.canNavigateToPreviousResult == true },
                action: { appState.navigateToPrevItem() }
            ),
            Command(
                id: "nav.pageUp",
                title: AppCommandCatalog.pageUp.title,
                category: .navigation,
                shortcut: AppCommandCatalog.pageUp.paletteShortcut,
                icon: "arrow.up.to.line",
                context: .grid,
                isEnabled: { state in
                    state.map { LibraryViewportCommandRouter.isAvailable(in: $0) } ?? false
                },
                action: { LibraryViewportCommandRouter.post(.pageUp, appState: appState) }
            ),
            Command(
                id: "nav.pageDown",
                title: AppCommandCatalog.pageDown.title,
                category: .navigation,
                shortcut: AppCommandCatalog.pageDown.paletteShortcut,
                icon: "arrow.down.to.line",
                context: .grid,
                isEnabled: { state in
                    state.map { LibraryViewportCommandRouter.isAvailable(in: $0) } ?? false
                },
                action: { LibraryViewportCommandRouter.post(.pageDown, appState: appState) }
            ),
            Command(
                id: "nav.firstItem",
                title: AppCommandCatalog.libraryTop.title,
                category: .navigation,
                shortcut: AppCommandCatalog.libraryTop.paletteShortcut,
                icon: "arrow.up.to.line.compact",
                context: .grid,
                isEnabled: { state in
                    state.map { LibraryViewportCommandRouter.isAvailable(in: $0) } ?? false
                },
                action: { LibraryViewportCommandRouter.post(.first, appState: appState) }
            ),
            Command(
                id: "nav.lastItem",
                title: AppCommandCatalog.libraryBottom.title,
                category: .navigation,
                shortcut: AppCommandCatalog.libraryBottom.paletteShortcut,
                icon: "arrow.down.to.line.compact",
                context: .grid,
                isEnabled: { state in
                    state.map { LibraryViewportCommandRouter.isAvailable(in: $0) } ?? false
                },
                action: { LibraryViewportCommandRouter.post(.last, appState: appState) }
            )
        ]
    }

    private func buildActionCommands(appState: AppState) -> [Command] {
        [
            Command(
                id: "action.star",
                title: "Toggle Star",
                category: .actions,
                shortcut: KeyboardShortcut("s", modifiers: []),
                icon: "star",
                isEnabled: { state in state?.selectedItemID != nil || state?.focusedItem != nil },
                action: { appState.toggleStarOnSelected() }
            ),
            Command(
                id: "action.addTag",
                title: "Add Tag...",
                category: .actions,
                shortcut: KeyboardShortcut("t", modifiers: []),
                icon: "tag",
                isEnabled: { state in state?.selectedItemID != nil || state?.focusedItem != nil },
                action: { appState.showTagInput = true }
            ),
            Command(
                id: "action.openSource",
                title: "Open Source URL",
                category: .actions,
                shortcut: KeyboardShortcut("o", modifiers: []),
                icon: "link",
                isEnabled: { state in state?.mediaActionContext.items.isEmpty == false },
                action: {
                    for item in appState.mediaActionContext.items.prefix(5) { NSWorkspace.shared.open(item.metadata.source) }
                }
            ),
            Command(
                id: "action.revealFinder",
                title: "Reveal in Finder",
                category: .actions,
                icon: "folder",
                isEnabled: { state in state?.mediaActionContext.isEnabled(.reveal, source: .displayed) == true },
                action: {
                    MediaFileAction.reveal.perform(context: appState.mediaActionContext, appState: appState)
                }
            ),
            Command(
                id: "action.copyImage",
                title: "Copy Image",
                category: .actions,
                shortcut: KeyboardShortcut("c", modifiers: .command),
                icon: "doc.on.clipboard",
                isEnabled: { state in state?.mediaActionContext.canCopyImage == true },
                action: { appState.copyDisplayedImage() }
            )
        ] + MediaTransferSource.allCases.flatMap { source in
            MediaFileAction.allCases.map { action in
                Command(id: "transfer.\(source.rawValue).\(action.rawValue)",
                    title: "\(action.title) — \(source.label)", category: .actions, icon: "arrow.up.doc",
                    isEnabled: { state in state?.mediaActionContext.isEnabled(action, source: source) == true },
                    action: { action.perform(context: appState.mediaActionContext, source: source, appState: appState) })
            }
        }
    }

    private func buildFilterCommands(appState: AppState) -> [Command] {
        [
            Command(
                id: "filter.all",
                title: "Show All",
                category: .filters,
                icon: "square.grid.2x2",
                action: {
                    appState.commitLibraryFilterChange {
                        appState.filterText = ""
                        appState.searchScope = .all
                        appState.starredFilter = nil
                        appState.hasOCRFilter = nil
                        appState.platformFilter = nil
                        appState.colorFilters = []
                        appState.colorSearchRGB = nil
                    }
                }
            ),
            Command(
                id: "filter.starred",
                title: "Show Starred",
                category: .filters,
                icon: "star.fill",
                action: {
                    appState.commitLibraryFilterChange {
                        appState.starredFilter = appState.starredFilter == true ? nil : true
                    }
                }
            ),
            Command(
                id: "filter.videos",
                title: "Show Videos",
                category: .filters,
                icon: "video",
                action: {
                    appState.commitLibraryFilterChange {
                        appState.searchScope = .all
                        appState.filterText = "type:video"
                    }
                }
            ),
            Command(
                id: "filter.recent",
                title: "Show Recent (7 days)",
                category: .filters,
                icon: "clock",
                action: {
                    appState.commitLibraryFilterChange {
                        appState.searchScope = .all
                        appState.filterText = "recent:7d"
                    }
                }
            ),
            Command(
                id: "filter.untagged",
                title: "Show Untagged",
                category: .filters,
                icon: "tag.slash",
                action: {
                    appState.commitLibraryFilterChange {
                        appState.searchScope = .all
                        appState.filterText = "tags:none"
                    }
                }
            ),
            Command(
                id: "filter.hasOCR",
                title: "Show With OCR Text",
                category: .filters,
                icon: "text.viewfinder",
                action: {
                    appState.commitLibraryFilterChange {
                        appState.hasOCRFilter = appState.hasOCRFilter == true ? nil : true
                    }
                }
            ),
            // Issue #1 fix: Command palette entry for Visual Clusters
            Command(
                id: "view.visualClusters",
                title: "Visual Clusters",
                category: .navigation,
                icon: "square.grid.3x3.middle.filled",
                action: { appState.commitLibraryDestinationChange(.visualClusters) }
            )
        ]
    }

    private func buildSystemCommands(appState: AppState) -> [Command] {
        [
            Command(
                id: "system.retainedFileData",
                title: AppCommandCatalog.retainedFileDataTitle,
                category: .system,
                icon: "doc.text.magnifyingglass",
                isEnabled: { $0?.mediaStore != nil },
                action: { appState.showRetainedFileData = true }
            ),
            Command(
                id: "system.clearCache",
                title: "Clear Thumbnail Cache",
                category: .system,
                icon: "trash",
                action: {
                    Task { await ImageCache.shared.clearAllCaches() }
                }
            ),
            Command(
                id: "system.regenerateThumbnails",
                title: "Regenerate All Thumbnails",
                category: .system,
                icon: "photo.on.rectangle",
                action: { appState.regenerateAllThumbnails() }
            ),
            Command(
                id: "system.rebuildIndex",
                title: "Rebuild Search Index",
                category: .system,
                icon: "arrow.clockwise",
                action: { appState.rebuildSearchIndex() }
            ),
            Command(
                id: "system.findDuplicates",
                title: "Find Duplicates",
                category: .system,
                icon: "rectangle.on.rectangle",
                action: { appState.findDuplicates() }
            ),
            Command(
                id: "system.preferences",
                title: "Preferences...",
                category: .system,
                shortcut: KeyboardShortcut(",", modifiers: .command),
                icon: "gear",
                action: { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
            ),
            Command(
                id: "system.commandPalette",
                title: AppCommandCatalog.commandPalette.title,
                category: .system,
                shortcut: AppCommandCatalog.commandPalette.paletteShortcut,
                icon: "command",
                action: { appState.showCommandPalette = true }
            )
        ]
    }

    private static func selectedItem(in appState: AppState?) -> MediaItem? {
        guard let appState else { return nil }
        if let focusedItem = appState.focusedItem {
            return focusedItem
        }
        guard let selectedID = appState.selectedItemID else { return nil }
        return appState.displayedItem(for: selectedID)
    }

    /// Register smart folder commands dynamically
    func registerSmartFolderCommands(folders: [SmartFolder], onSelect: @escaping (SmartFolder) -> Void) {
        // Remove old smart folder commands
        commands.removeAll { $0.id.hasPrefix("smartfolder.") }

        // Add command for each folder
        for folder in folders {
            register(Command(
                id: "smartfolder.\(folder.id.uuidString)",
                title: folder.name,
                category: .smartFolders,
                icon: folder.icon,
                action: {
                    onSelect(folder)
                }
            ))
        }
    }
}
