import SwiftUI
import AppKit

/// Deliberately exhaustive: filtering and timer events are not execution triggers.
enum CommandPaletteExecutionTrigger: CaseIterable {
    case returnKey
    case pointerClick
}

// MARK: - Command Palette View

/// Spotlight/Alfred-style command palette overlay.
/// Floating dark panel with fuzzy search and keyboard navigation.
struct CommandPalette: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var registry: CommandRegistry
    @Binding var isPresented: Bool

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool

    private var filteredCommands: [Command] {
        registry.searchCommands(query: query, appState: appState)
    }
    private var navigationCommands: [Command] { groupedCommands.flatMap { $0.commands } }

    /// Grouped commands for section display (Issue #1 & #9)
    private var groupedCommands: [(header: String?, commands: [Command])] {
        guard query.isEmpty else {
            // When searching, return flat list (no headers)
            return [(header: nil, commands: filteredCommands)]
        }

        // When query is empty, group by recent + categories
        var groups: [(header: String?, commands: [Command])] = []

        // Recent commands section (Issue #9)
        let recentCommands = filteredCommands.filter { registry.recentCommandIDs.contains($0.id) }
        if !recentCommands.isEmpty {
            // Sort by recency order
            let sortedRecent = recentCommands.sorted { cmd1, cmd2 in
                let idx1 = registry.recentCommandIDs.firstIndex(of: cmd1.id) ?? Int.max
                let idx2 = registry.recentCommandIDs.firstIndex(of: cmd2.id) ?? Int.max
                return idx1 < idx2
            }
            groups.append((header: "Recent", commands: sortedRecent))
        }

        // Group remaining by category
        let nonRecentCommands = filteredCommands.filter { !registry.recentCommandIDs.contains($0.id) }
        let byCategory = Dictionary(grouping: nonRecentCommands) { $0.category }

        for category in CommandCategory.allCases {
            if let commands = byCategory[category], !commands.isEmpty {
                groups.append((header: category.rawValue, commands: commands))
            }
        }

        return groups
    }

    /// Total count for height calculation
    private var totalCommandCount: Int {
        filteredCommands.count
    }

    /// Section header count for height calculation
    private var sectionHeaderCount: Int {
        query.isEmpty ? groupedCommands.count : 0
    }

    private var panelHeight: CGFloat {
        let contentHeight = CGFloat(totalCommandCount * 44 + sectionHeaderCount * 28 + 56)
        return filteredCommands.isEmpty ? max(contentHeight, 156) : min(contentHeight, 400)
    }

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            // Palette panel, anchored near the top like Spotlight. Its height follows the result
            // count; centering it would move the search field on every keystroke.
            VStack(spacing: 0) {
                // Search input
                searchBar

                Divider()
                    .background(Color(hex: 0x3a3a3a))

                // Command list
                commandList
            }
            .frame(width: 560, height: panelHeight)
            .background(Color(hex: 0x1e1e1e))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(hex: 0x3a3a3a), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 96)
        }
        .onAppear {
            isSearchFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .background(
            KeyboardNavigationHandler(
                onUp: { moveSelection(by: -1) },
                onDown: { moveSelection(by: 1) },
                onPageUp: { moveSelection(by: -5) },
                onPageDown: { moveSelection(by: 5) },
                onHome: { moveToFirst() },
                onEnd: { moveToLast() },
                onTab: { autocompleteTopResult() },
                onEnter: { executeSelected() },
                onEscape: { dismiss() }
            )
        )
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "command")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentOrange)

            TextField("Type a command...", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .focused($isSearchFocused)
                .accessibilityLabel("Command search input")
                .accessibilityIdentifier("command-palette-search")
                .accessibilityHint("Type to filter available commands")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            HStack(spacing: 6) {
                Text("↩ run")
                Text("esc close")
            }
            .font(.system(size: 11, weight: .medium).monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(hex: 0x3a3a3a))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel("Return runs the selected command; Escape closes the command palette")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Command List

    private var commandList: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if filteredCommands.isEmpty {
                        emptyState
                    } else if query.isEmpty {
                        // Grouped view with section headers (Issue #1 & #9)
                        groupedCommandsView
                    } else {
                        // Flat search results with category badges
                        flatCommandsView
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(.easeOut(duration: 0.1)) {
                    scrollProxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    /// One palette row: its keyboard index and the section header that precedes it, if any.
    private struct GroupedRow: Identifiable {
        let index: Int
        let header: String?
        let command: Command
        var id: String { command.id }
    }

    /// Indices are assigned once here. Counting inside the lazy view builder gave colliding
    /// `.id`s, so the stack repeated some rows, dropped others, and arrow keys lost their place.
    private var groupedRows: [GroupedRow] {
        var rows: [GroupedRow] = []
        for group in groupedCommands {
            for (offset, command) in group.commands.enumerated() {
                rows.append(GroupedRow(index: rows.count, header: offset == 0 ? group.header : nil, command: command))
            }
        }
        return rows
    }

    /// Grouped commands with section headers (when query is empty)
    private var groupedCommandsView: some View {
        ForEach(groupedRows) { row in
            if let header = row.header {
                CommandSectionHeader(title: header)
            }
            CommandRow(
                command: row.command,
                isSelected: row.index == selectedIndex,
                showCategoryBadge: false,
                selectedCount: selectedItemCount(for: row.command),
                onExecute: {
                    executeCommand(row.command, trigger: .pointerClick)
                }
            )
            .id(row.index)
        }
    }

    /// Flat commands list (when searching)
    private var flatCommandsView: some View {
        ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
            CommandRow(
                command: command,
                isSelected: index == selectedIndex,
                showCategoryBadge: true,
                selectedCount: selectedItemCount(for: command),
                onExecute: {
                    executeCommand(command, trigger: .pointerClick)
                }
            )
            .id(index)
        }
    }

    /// Get selected item count for context-aware subtitles (Issue #6)
    private func selectedItemCount(for command: Command) -> Int? {
        // Only show count for action commands when multiple items selected
        guard command.category == .actions else { return nil }
        let count = appState.selectedItemIDs.count
        return count > 1 ? count : nil
    }

    /// Empty state with fuzzy suggestions (Issue #7)
    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No commands found")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Fuzzy suggestion (Issue #7)
            if let suggestion = registry.findClosestMatch(to: query) {
                HStack(spacing: 4) {
                    Text("Did you mean:")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button {
                        query = suggestion
                    } label: {
                        Text(suggestion)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentOrange)
                    }
                    .buttonStyle(.plain)
                    Text("?")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                // Show available categories
                VStack(spacing: 6) {
                    Text("Available categories:")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 8) {
                        ForEach(CommandCategory.allCases.prefix(4), id: \.self) { category in
                            Text(category.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(hex: 0x2a2a2a))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Actions

    private func moveSelection(by offset: Int) {
        let newIndex = selectedIndex + offset
        selectedIndex = max(0, min(newIndex, navigationCommands.count - 1))
    }

    /// Jump to first command (Issue #4 - Home key)
    private func moveToFirst() {
        selectedIndex = 0
    }

    /// Jump to last command (Issue #4 - End key)
    private func moveToLast() {
        selectedIndex = max(0, navigationCommands.count - 1)
    }

    /// Autocomplete the top result into the search field (Issue #8 - Tab key)
    private func autocompleteTopResult() {
        guard let first = navigationCommands.first else { return }
        query = first.title
    }

    private func executeSelected() {
        guard navigationCommands.indices.contains(selectedIndex) else { return }
        let command = navigationCommands[selectedIndex]
        executeCommand(command, trigger: .returnKey)
    }

    private func executeCommand(_ command: Command, trigger _: CommandPaletteExecutionTrigger) {
        guard command.isEnabled(appState) else { return }
        dismiss()
        // Small delay to allow dismiss animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Context can change while the palette dismisses. Re-check at the execution
            // boundary so a now-disabled command is never run from a stale result row.
            registry.execute(command, appState: appState)
        }
    }

    private func dismiss() {
        isPresented = false
        query = ""
        selectedIndex = 0
    }
}

// MARK: - Section Header (Issue #1 & #9)

private struct CommandSectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

// MARK: - Command Row

private struct CommandRow: View {
    let command: Command
    let isSelected: Bool
    var showCategoryBadge: Bool = true
    var selectedCount: Int? = nil
    let onExecute: () -> Void

    var body: some View {
        Button(action: onExecute) {
            HStack(spacing: 12) {
                // Icon
                if let icon = command.icon {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? Color.accentOrange : .secondary)
                        .frame(width: 20)
                }

                // Title and subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? .primary : .secondary)

                    // Context subtitle: "N items selected" (Issue #6)
                    if let count = selectedCount {
                        Text("\(count) items selected")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                // Category badge (when searching, not in grouped view)
                if showCategoryBadge && !isSelected {
                    Text(command.category.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: 0x2a2a2a))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                // Issue #7: Context badge (grid, detail, annotate)
                if command.context != .global {
                    Text(command.context.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentOrange.opacity(0.8) : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(isSelected ? Color.accentOrange.opacity(0.5) : Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }

                // Shortcut badge or "(No shortcut)" indicator (Issue #3)
                if let shortcut = command.shortcut {
                    ShortcutBadge(shortcut: shortcut, isHighlighted: isSelected)
                } else if isSelected {
                    // Show "No shortcut" hint when selected (Issue #3)
                    Text("No shortcut")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(hex: 0x2a2a2a))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? Color.accentOrange.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(command.title)
        .accessibilityIdentifier("command-palette-\(command.id)")
        .accessibilityHint("Execute command")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }
}

// MARK: - Shortcut Badge
// Issue #9: Standardize shortcut style - use Unicode symbols (⌘⇧⌥⌃) for command palette
// Menus automatically render using native format via SwiftUI .keyboardShortcut()

private struct ShortcutBadge: View {
    let shortcut: KeyboardShortcut
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(shortcutParts, id: \.self) { part in
                Text(part)
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .foregroundStyle(isHighlighted ? Color.accentOrange : .secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(hex: isHighlighted ? 0x3a3a3a : 0x2a2a2a))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var shortcutParts: [String] {
        var parts: [String] = []

        // Use Unicode symbols for modifiers (Issue #10)
        if shortcut.modifiers.contains(.control) { parts.append("\u{2303}") } // ⌃
        if shortcut.modifiers.contains(.option) { parts.append("\u{2325}") }  // ⌥
        if shortcut.modifiers.contains(.shift) { parts.append("\u{21E7}") }   // ⇧
        if shortcut.modifiers.contains(.command) { parts.append("\u{2318}") } // ⌘

        // Handle the key
        let keyStr: String
        switch shortcut.key {
        case .return: keyStr = "\u{21A9}" // ↩
        case .escape: keyStr = "\u{238B}" // ⎋
        case .delete: keyStr = "\u{232B}" // ⌫
        case .upArrow: keyStr = "\u{2191}" // ↑
        case .downArrow: keyStr = "\u{2193}" // ↓
        case .leftArrow: keyStr = "\u{2190}" // ←
        case .rightArrow: keyStr = "\u{2192}" // →
        case .space: keyStr = "\u{2423}" // ␣
        case .tab: keyStr = "\u{21E5}" // ⇥
        default:
            keyStr = String(shortcut.key.character).uppercased()
        }

        parts.append(keyStr)
        return parts
    }
}

// MARK: - Keyboard Navigation Handler (Issue #4 & #8)

/// NSViewRepresentable that captures keyboard events for palette navigation.
private struct KeyboardNavigationHandler: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void
    let onPageUp: () -> Void
    let onPageDown: () -> Void
    let onHome: () -> Void
    let onEnd: () -> Void
    let onTab: () -> Void
    let onEnter: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> PaletteKeyView {
        let view = PaletteKeyView()
        view.onUp = onUp
        view.onDown = onDown
        view.onPageUp = onPageUp
        view.onPageDown = onPageDown
        view.onHome = onHome
        view.onEnd = onEnd
        view.onTab = onTab
        view.onEnter = onEnter
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: PaletteKeyView, context: Context) {
        nsView.onUp = onUp
        nsView.onDown = onDown
        nsView.onPageUp = onPageUp
        nsView.onPageDown = onPageDown
        nsView.onHome = onHome
        nsView.onEnd = onEnd
        nsView.onTab = onTab
        nsView.onEnter = onEnter
        nsView.onEscape = onEscape
    }
}

private class PaletteKeyView: NSView {
    private var monitor: Any?
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onPageUp: (() -> Void)?
    var onPageDown: (() -> Void)?
    var onHome: (() -> Void)?
    var onEnd: (() -> Void)?
    var onTab: (() -> Void)?
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        // Leave text entry in the real search field. Capture only palette
        // navigation keys before AppKit sends them to its field editor.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window === event.window,
                  [126, 125, 116, 121, 115, 119, 48, 36, 76, 53].contains(Int(event.keyCode)),
                  !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.option) else { return event }
            self.keyDown(with: event)
            return nil
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 126: // Up arrow
            onUp?()
        case 125: // Down arrow
            onDown?()
        case 116: // Page Up
            onPageUp?()
        case 121: // Page Down
            onPageDown?()
        case 115: // Home
            onHome?()
        case 119: // End
            onEnd?()
        case 48: // Tab (Issue #8)
            onTab?()
        case 36, 76: // Enter
            onEnter?()
        case 53: // Escape
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct CommandPalette_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color(hex: 0x1a1a1a)
                .ignoresSafeArea()

            CommandPalette(
                registry: {
                    let registry = CommandRegistry.shared
                    registry.register([
                        Command(id: "test1", title: "Go to Grid", category: .navigation, shortcut: KeyboardShortcut(.escape), icon: "square.grid.3x3", isEnabled: { _ in true }, action: {}),
                        Command(id: "test2", title: "Toggle Star", category: .actions, shortcut: KeyboardShortcut("s", modifiers: []), icon: "star", isEnabled: { _ in true }, action: {}),
                        Command(id: "test3", title: "Show Starred", category: .filters, icon: "star.fill", isEnabled: { _ in true }, action: {}),
                        Command(id: "test4", title: "Clear Cache", category: .system, icon: "trash", isEnabled: { _ in true }, action: {}),
                    ])
                    return registry
                }(),
                isPresented: .constant(true)
            )
        }
        .frame(width: 800, height: 600)
        .environmentObject(AppState())
    }
}
#endif
