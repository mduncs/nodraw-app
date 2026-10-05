import XCTest
import SwiftUI
@testable import MediaViewer

// MARK: - CommandRegistryTests

@MainActor
final class CommandRegistryTests: XCTestCase {

    var registry: CommandRegistry!

    override func setUp() async throws {
        // Use shared singleton and clear it for clean state
        registry = CommandRegistry.shared
        registry.clearAll()
    }

    override func tearDown() async throws {
        registry.clearAll()
        registry = nil
    }

    // MARK: - Registration Tests

    func testRegisterSingleCommand() async throws {
        let command = Command(
            id: "test.command",
            title: "Test Command",
            action: { }
        )

        registry.register(command)

        XCTAssertEqual(registry.commands.count, 1)
        XCTAssertEqual(registry.commands.first?.id, "test.command")
    }

    func testRegisterMultipleCommands() async throws {
        let commands = [
            Command(id: "cmd1", title: "Command 1", action: {}),
            Command(id: "cmd2", title: "Command 2", action: {}),
            Command(id: "cmd3", title: "Command 3", action: {})
        ]

        registry.register(commands)

        XCTAssertEqual(registry.commands.count, 3)
    }

    func testRegisterReplacesExistingCommand() async throws {
        let original = Command(id: "same.id", title: "Original", action: {})
        let replacement = Command(id: "same.id", title: "Replacement", action: {})

        registry.register(original)
        registry.register(replacement)

        XCTAssertEqual(registry.commands.count, 1)
        XCTAssertEqual(registry.commands.first?.title, "Replacement")
    }

    func testUnregisterCommand() async throws {
        let command = Command(id: "to.remove", title: "Remove Me", action: {})
        registry.register(command)

        XCTAssertEqual(registry.commands.count, 1)

        registry.unregister(id: "to.remove")

        XCTAssertEqual(registry.commands.count, 0)
    }

    func testUnregisterNonexistentCommandNoOp() async throws {
        let command = Command(id: "keep", title: "Keep", action: {})
        registry.register(command)

        registry.unregister(id: "nonexistent")

        XCTAssertEqual(registry.commands.count, 1)
    }

    func testClearAll() async throws {
        registry.register([
            Command(id: "cmd1", title: "Command 1", action: {}),
            Command(id: "cmd2", title: "Command 2", action: {})
        ])

        registry.clearAll()

        XCTAssertTrue(registry.commands.isEmpty)
        XCTAssertTrue(registry.recentCommandIDs.isEmpty)
    }

    // MARK: - Search Tests

    func testSearchEmptyQueryReturnsAll() async throws {
        registry.register([
            Command(id: "cmd1", title: "Alpha", action: {}),
            Command(id: "cmd2", title: "Beta", action: {}),
            Command(id: "cmd3", title: "Gamma", action: {})
        ])

        let results = registry.searchCommands(query: "")

        XCTAssertEqual(results.count, 3)
    }

    func testSearchExactMatch() async throws {
        registry.register([
            Command(id: "cmd1", title: "Open File", action: {}),
            Command(id: "cmd2", title: "Close File", action: {}),
            Command(id: "cmd3", title: "Open Folder", action: {})
        ])

        let results = registry.searchCommands(query: "open file")

        XCTAssertEqual(results.first?.title, "Open File")
    }

    func testSearchPrefixMatch() async throws {
        registry.register([
            Command(id: "cmd1", title: "Toggle Sidebar", action: {}),
            Command(id: "cmd2", title: "Show Settings", action: {}),
            Command(id: "cmd3", title: "Toggle Preview", action: {})
        ])

        let results = registry.searchCommands(query: "tog")

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.title.lowercased().hasPrefix("tog") })
    }

    func testSearchContainsMatch() async throws {
        registry.register([
            Command(id: "cmd1", title: "Show Starred Items", action: {}),
            Command(id: "cmd2", title: "Toggle Star", action: {}),
            Command(id: "cmd3", title: "Remove Tag", action: {})
        ])

        let results = registry.searchCommands(query: "star")

        XCTAssertEqual(results.count, 2)
    }

    func testSearchFuzzyMatch() async throws {
        registry.register([
            Command(id: "cmd1", title: "Create Smart Folder", action: {}),
            Command(id: "cmd2", title: "Delete Item", action: {}),
            Command(id: "cmd3", title: "Show Grid", action: {})
        ])

        let results = registry.searchCommands(query: "crtsmtfldr")

        XCTAssertEqual(results.map(\.id), ["cmd1"])
    }

    func testSearchAbbreviationMatch() async throws {
        registry.register([
            Command(id: "cmd1", title: "Smart Folder", action: {}),
            Command(id: "cmd2", title: "Show Files", action: {}),
            Command(id: "cmd3", title: "Save Filter", action: {})
        ])

        // "sf" should match commands where words start with s and f
        let results = registry.searchCommands(query: "sf")

        XCTAssertEqual(Set(results.map(\.id)), ["cmd1", "cmd2", "cmd3"])
    }

    func testSearchCaseInsensitive() async throws {
        registry.register([
            Command(id: "cmd1", title: "UPPERCASE COMMAND", action: {}),
            Command(id: "cmd2", title: "lowercase command", action: {}),
            Command(id: "cmd3", title: "MixedCase Command", action: {})
        ])

        let results = registry.searchCommands(query: "COMMAND")

        XCTAssertEqual(results.count, 3)
    }

    func testSearchNoMatch() async throws {
        registry.register([
            Command(id: "cmd1", title: "Open File", action: {}),
            Command(id: "cmd2", title: "Save File", action: {})
        ])

        let results = registry.searchCommands(query: "xyz123")

        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Category Filtering Tests

    func testCommandsInCategory() async throws {
        registry.register([
            Command(id: "nav1", title: "Go Home", category: .navigation, action: {}),
            Command(id: "nav2", title: "Go Back", category: .navigation, action: {}),
            Command(id: "act1", title: "Delete Item", category: .actions, action: {}),
            Command(id: "sys1", title: "Settings", category: .system, action: {})
        ])

        let navigationCommands = registry.commands(in: .navigation)
        let actionCommands = registry.commands(in: .actions)
        let filterCommands = registry.commands(in: .filters)

        XCTAssertEqual(navigationCommands.count, 2)
        XCTAssertEqual(actionCommands.count, 1)
        XCTAssertEqual(filterCommands.count, 0)
    }

    func testCategorySortOrder() async throws {
        // Verify categories have expected sort order
        XCTAssertLessThan(CommandCategory.navigation.sortOrder, CommandCategory.actions.sortOrder)
        XCTAssertLessThan(CommandCategory.actions.sortOrder, CommandCategory.filters.sortOrder)
        XCTAssertLessThan(CommandCategory.filters.sortOrder, CommandCategory.smartFolders.sortOrder)
        XCTAssertLessThan(CommandCategory.smartFolders.sortOrder, CommandCategory.system.sortOrder)
        XCTAssertLessThan(CommandCategory.system.sortOrder, CommandCategory.general.sortOrder)
    }

    // MARK: - isEnabled Filtering Tests

    func testSearchFiltersDisabledCommands() async throws {
        var isEnabled = true

        registry.register([
            Command(
                id: "enabled",
                title: "Enabled Command",
                isEnabled: { _ in true },
                action: {}
            ),
            Command(
                id: "disabled",
                title: "Disabled Command",
                isEnabled: { _ in isEnabled },
                action: {}
            )
        ])

        isEnabled = false
        let results = registry.searchCommands(query: "")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, "enabled")
    }

    func testCategoryFilterExcludesDisabled() async throws {
        registry.register([
            Command(
                id: "act1",
                title: "Enabled Action",
                category: .actions,
                isEnabled: { _ in true },
                action: {}
            ),
            Command(
                id: "act2",
                title: "Disabled Action",
                category: .actions,
                isEnabled: { _ in false },
                action: {}
            )
        ])

        let actions = registry.commands(in: .actions)

        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.id, "act1")
    }

    // MARK: - Recent Commands Tests

    func testExecuteTracksRecentCommand() async throws {
        let command = Command(id: "recent.test", title: "Recent Test", action: {})
        registry.register(command)

        XCTAssertTrue(registry.recentCommandIDs.isEmpty)

        registry.execute(command)

        XCTAssertEqual(registry.recentCommandIDs.count, 1)
        XCTAssertEqual(registry.recentCommandIDs.first, "recent.test")
    }

    func testRecentCommandsOrderedByRecency() async throws {
        let commands = [
            Command(id: "cmd1", title: "First", action: {}),
            Command(id: "cmd2", title: "Second", action: {}),
            Command(id: "cmd3", title: "Third", action: {})
        ]
        registry.register(commands)

        registry.execute(commands[0])
        registry.execute(commands[1])
        registry.execute(commands[2])

        XCTAssertEqual(registry.recentCommandIDs, ["cmd3", "cmd2", "cmd1"])
    }

    func testRecentCommandsLimitedTo5() async throws {
        let commands = (1...10).map { i in
            Command(id: "cmd\(i)", title: "Command \(i)", action: {})
        }
        registry.register(commands)

        for command in commands {
            registry.execute(command)
        }

        XCTAssertEqual(registry.recentCommandIDs.count, 5)
        // Most recent should be first
        XCTAssertEqual(registry.recentCommandIDs.first, "cmd10")
    }

    func testRecentCommandsMoveToFrontOnReuse() async throws {
        let commands = [
            Command(id: "cmd1", title: "First", action: {}),
            Command(id: "cmd2", title: "Second", action: {})
        ]
        registry.register(commands)

        registry.execute(commands[0])
        registry.execute(commands[1])

        XCTAssertEqual(registry.recentCommandIDs, ["cmd2", "cmd1"])

        // Execute first again
        registry.execute(commands[0])

        XCTAssertEqual(registry.recentCommandIDs, ["cmd1", "cmd2"])
    }

    func testSearchSortsRecentFirst() async throws {
        let commands = [
            Command(id: "cmd1", title: "Alpha Action", category: .actions, action: {}),
            Command(id: "cmd2", title: "Beta Action", category: .actions, action: {}),
            Command(id: "cmd3", title: "Gamma Action", category: .actions, action: {})
        ]
        registry.register(commands)

        // Execute cmd3 to make it recent
        registry.execute(commands[2])

        let results = registry.searchCommands(query: "")

        // cmd3 should be first due to recency
        XCTAssertEqual(results.first?.id, "cmd3")
    }

    // MARK: - Execution Tests

    func testExecuteRunsCommandAction() async throws {
        var executed = false
        let command = Command(id: "exec.test", title: "Execute Test") {
            executed = true
        }
        registry.register(command)

        registry.execute(command)

        XCTAssertTrue(executed)
    }

    func testExecuteByIdReturnsTrue() async throws {
        var executed = false
        let command = Command(id: "by.id", title: "By ID") {
            executed = true
        }
        registry.register(command)

        let result = registry.execute(id: "by.id")

        XCTAssertTrue(result)
        XCTAssertTrue(executed)
    }

    func testExecuteByIdReturnsFalseForUnknown() async throws {
        let result = registry.execute(id: "unknown.id")

        XCTAssertFalse(result)
    }

    func testExecuteByIdReturnsFalseForDisabled() async throws {
        let command = Command(
            id: "disabled.cmd",
            title: "Disabled",
            isEnabled: { _ in false },
            action: {}
        )
        registry.register(command)

        let result = registry.execute(id: "disabled.cmd")

        XCTAssertFalse(result)
    }

    // MARK: - Lookup Tests

    func testCommandById() async throws {
        let command = Command(id: "lookup.test", title: "Lookup Test", action: {})
        registry.register(command)

        let found = registry.command(id: "lookup.test")
        let notFound = registry.command(id: "nonexistent")

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.title, "Lookup Test")
        XCTAssertNil(notFound)
    }

    func testDefaultCommandsDoNotExposeUnwiredRemoveTagCommand() async throws {
        let appState = AppState()

        registry.registerDefaultCommands(appState: appState)

        XCTAssertNil(registry.command(id: "action.removeTag"))
    }

    func testSmartFolderRegistrationDoesNotExposeUnwiredCreateCommand() async throws {
        let folder = SmartFolder(name: "Starred", icon: "star.fill", rules: [.starred(true)])

        registry.registerSmartFolderCommands(folders: [folder]) { _ in }

        XCTAssertNil(registry.command(id: "smartfolder.create"))
        XCTAssertNotNil(registry.command(id: "smartfolder.\(folder.id.uuidString)"))
    }

    // MARK: - Command Properties Tests

    func testCommandWithAllProperties() async throws {
        var executed = false
        let command = Command(
            id: "full.command",
            title: "Full Command",
            category: .actions,
            shortcut: KeyboardShortcut("s", modifiers: .command),
            icon: "star.fill",
            isEnabled: { _ in true },
            action: { executed = true }
        )

        XCTAssertEqual(command.id, "full.command")
        XCTAssertEqual(command.title, "Full Command")
        XCTAssertEqual(command.category, .actions)
        XCTAssertNotNil(command.shortcut)
        XCTAssertEqual(command.icon, "star.fill")
        XCTAssertTrue(command.isEnabled(nil))

        command.action()
        XCTAssertTrue(executed)
    }

    func testCommandDefaultCategory() async throws {
        let command = Command(id: "default.cat", title: "Default Category", action: {})

        XCTAssertEqual(command.category, .general)
    }

    func testCommandDefaultIsEnabled() async throws {
        let command = Command(id: "default.enabled", title: "Default Enabled", action: {})

        XCTAssertTrue(command.isEnabled(nil))
    }

    // MARK: - Keyboard Shortcut Display Tests

    func testShortcutDisplayString() async throws {
        let shortcut1 = KeyboardShortcut("s", modifiers: .command)
        XCTAssertEqual(shortcut1.displayString, "Cmd+S")

        let shortcut2 = KeyboardShortcut("z", modifiers: [.command, .shift])
        XCTAssertEqual(shortcut2.displayString, "Cmd+Shift+Z")

        let shortcut3 = KeyboardShortcut("/", modifiers: [])
        XCTAssertEqual(shortcut3.displayString, "/")
    }

    func testShortcutDisplayStringAllModifiers() async throws {
        let shortcut = KeyboardShortcut("a", modifiers: [.command, .option, .control, .shift])
        let display = shortcut.displayString

        XCTAssertTrue(display.contains("Cmd"))
        XCTAssertTrue(display.contains("Opt"))
        XCTAssertTrue(display.contains("Ctrl"))
        XCTAssertTrue(display.contains("Shift"))
        XCTAssertTrue(display.contains("A"))
    }

    // MARK: - CommandCategory Tests

    func testCommandCategoryAllCases() async throws {
        let allCases = CommandCategory.allCases

        XCTAssertTrue(allCases.contains(.navigation))
        XCTAssertTrue(allCases.contains(.actions))
        XCTAssertTrue(allCases.contains(.filters))
        XCTAssertTrue(allCases.contains(.smartFolders))
        XCTAssertTrue(allCases.contains(.system))
        XCTAssertTrue(allCases.contains(.general))
    }

    func testCommandCategoryRawValues() async throws {
        XCTAssertEqual(CommandCategory.navigation.rawValue, "Navigation")
        XCTAssertEqual(CommandCategory.actions.rawValue, "Actions")
        XCTAssertEqual(CommandCategory.filters.rawValue, "Filters")
        XCTAssertEqual(CommandCategory.smartFolders.rawValue, "Smart Folders")
        XCTAssertEqual(CommandCategory.system.rawValue, "System")
        XCTAssertEqual(CommandCategory.general.rawValue, "General")
    }
}

// MARK: - Search Quality Tests

@MainActor
final class CommandSearchQualityTests: XCTestCase {

    var registry: CommandRegistry!

    override func setUp() async throws {
        registry = CommandRegistry.shared
        registry.clearAll()
    }

    override func tearDown() async throws {
        registry.clearAll()
        registry = nil
    }

    func testExactMatchRanksHighest() async throws {
        registry.register([
            Command(id: "cmd1", title: "star", action: {}),
            Command(id: "cmd2", title: "Toggle Star", action: {}),
            Command(id: "cmd3", title: "Starred Items", action: {})
        ])

        let results = registry.searchCommands(query: "star")

        // Exact match should be first
        XCTAssertEqual(results.first?.title, "star")
    }

    func testPrefixMatchRanksAboveContains() async throws {
        registry.register([
            Command(id: "cmd1", title: "toggle star", action: {}),
            Command(id: "cmd2", title: "star items", action: {}),
            Command(id: "cmd3", title: "unstar all", action: {})
        ])

        let results = registry.searchCommands(query: "star")

        // Prefix match "star items" should rank above "toggle star" (contains)
        XCTAssertEqual(results.first?.title, "star items")
    }

    func testShorterMatchesPreferred() async throws {
        registry.register([
            Command(id: "cmd1", title: "Open", action: {}),
            Command(id: "cmd2", title: "Open File", action: {}),
            Command(id: "cmd3", title: "Open File in Editor", action: {})
        ])

        let results = registry.searchCommands(query: "open")

        // Shorter match should rank higher
        XCTAssertEqual(results.first?.title, "Open")
    }

    func testWordPrefixAbbreviation() async throws {
        registry.register([
            Command(id: "sf", title: "Smart Folder", action: {}),
            Command(id: "ss", title: "Show Settings", action: {}),
            Command(id: "sc", title: "Start Capture", action: {})
        ])

        let results = registry.searchCommands(query: "sf")

        // "sf" should match "Smart Folder" via word prefix abbreviation
        XCTAssertTrue(results.contains { $0.id == "sf" })
    }

    func testConsecutiveMatchBonus() async throws {
        registry.register([
            Command(id: "cmd1", title: "abcdef", action: {}),
            Command(id: "cmd2", title: "aXbXcXdXeXf", action: {})
        ])

        let results = registry.searchCommands(query: "abcdef")

        // Exact consecutive match should rank higher
        XCTAssertEqual(results.first?.id, "cmd1")
    }
}

// MARK: - Concurrent Access Tests

@MainActor
final class CommandRegistryConcurrencyTests: XCTestCase {

    var registry: CommandRegistry!

    override func setUp() async throws {
        registry = CommandRegistry.shared
        registry.clearAll()
    }

    override func tearDown() async throws {
        registry.clearAll()
        registry = nil
    }

    func testConcurrentRegistration() async throws {
        // Register commands from multiple tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask { @MainActor in
                    let command = Command(id: "cmd\(i)", title: "Command \(i)", action: {})
                    self.registry.register(command)
                }
            }
        }

        // All commands should be registered
        XCTAssertEqual(registry.commands.count, 10)
    }

    func testConcurrentSearch() async throws {
        registry.register([
            Command(id: "cmd1", title: "Alpha", action: {}),
            Command(id: "cmd2", title: "Beta", action: {}),
            Command(id: "cmd3", title: "Gamma", action: {})
        ])

        // Perform multiple concurrent searches
        let results = await withTaskGroup(of: [Command].self) { group -> [[Command]] in
            for query in ["a", "b", "g", "", "alpha"] {
                group.addTask { @MainActor in
                    self.registry.searchCommands(query: query)
                }
            }

            var allResults: [[Command]] = []
            for await result in group {
                allResults.append(result)
            }
            return allResults
        }

        // All searches should complete without error
        XCTAssertEqual(results.count, 5)
    }
}
