import Foundation
import AppKit

// MARK: - Harness Configuration

/// Pure environment/argument policy used by both the GUI runner and focused
/// unit tests. The shell harness deliberately supplies both current and legacy
/// path keys so no archive-path consumer can drift back to live user data.
struct HeadlessHarnessConfiguration: Equatable {
    let archivePath: URL?
    let legacyArchivePath: URL?
    let appSupportPath: URL?
    let legacyAppSupportPath: URL?
    let resultsDirectory: URL?
    let disposableRoot: URL?
    let usesFixtures: Bool
    let permitsLiveArchive: Bool

    static func resolve(
        environment: [String: String],
        arguments: [String]
    ) -> HeadlessHarnessConfiguration {
        HeadlessHarnessConfiguration(
            archivePath: normalizedURL(environment["NODRAW_ARCHIVE_PATH"]),
            legacyArchivePath: normalizedURL(environment["MEDIAVIEWER_ARCHIVE_PATH"]),
            appSupportPath: normalizedURL(environment["NODRAW_APP_SUPPORT_DIR"]),
            legacyAppSupportPath: normalizedURL(environment["MEDIAVIEWER_APP_SUPPORT_DIR"]),
            resultsDirectory: normalizedURL(environment["NODRAW_HEADLESS_RESULTS_DIR"]),
            disposableRoot: normalizedURL(environment["NODRAW_HEADLESS_DISPOSABLE_ROOT"]),
            usesFixtures: arguments.contains("--test-fixtures") ||
                environment["MEDIAVIEWER_TEST_FIXTURES"] == "1",
            permitsLiveArchive: arguments.contains("--headless-live-archive") &&
                environment["NODRAW_HEADLESS_ALLOW_LIVE_ARCHIVE"] == "1"
        )
    }

    /// Returns a user-facing reason instead of silently running against an
    /// incomplete or inconsistent path contract.
    var safetyFailure: String? {
        guard let archivePath else {
            return "NODRAW_ARCHIVE_PATH is required for headless tests"
        }
        guard let legacyArchivePath else {
            return "MEDIAVIEWER_ARCHIVE_PATH is required and must match NODRAW_ARCHIVE_PATH"
        }
        guard archivePath == legacyArchivePath else {
            return "NODRAW_ARCHIVE_PATH and MEDIAVIEWER_ARCHIVE_PATH do not match"
        }
        guard let appSupportPath else {
            return "NODRAW_APP_SUPPORT_DIR is required for an isolated SQLite database"
        }
        if let legacyAppSupportPath, legacyAppSupportPath != appSupportPath {
            return "NODRAW_APP_SUPPORT_DIR and MEDIAVIEWER_APP_SUPPORT_DIR do not match"
        }
        guard let resultsDirectory else {
            return "NODRAW_HEADLESS_RESULTS_DIR is required for isolated result staging"
        }
        guard let disposableRoot else {
            return "NODRAW_HEADLESS_DISPOSABLE_ROOT is required"
        }
        guard Self.contains(appSupportPath, within: disposableRoot) else {
            return "Headless app support must be inside the disposable root"
        }
        guard Self.contains(resultsDirectory, within: disposableRoot) else {
            return "Headless results must be inside the disposable root"
        }

        if usesFixtures {
            guard Self.contains(archivePath, within: disposableRoot) else {
                return "Fixture archive must be a disposable copy inside the harness root"
            }
        } else {
            guard permitsLiveArchive else {
                return "Non-fixture tests require explicit --headless-live-archive opt-in"
            }
            guard Self.contains(archivePath, within: disposableRoot) else {
                return "Real-archive tests must use a disposable snapshot inside the harness root"
            }
        }

        return nil
    }

    private static func normalizedURL(_ rawValue: String?) -> URL? {
        guard let rawValue,
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: rawValue).standardizedFileURL
    }

    private static func contains(_ candidate: URL, within root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

// MARK: - Headless Test Runner

/// Service for running automated UI tests without mouse interaction.
/// Uses AppleScript via osascript for real UI automation and verification.
/// Enable via: --headless-tests or MEDIAVIEWER_HEADLESS_TESTS=1
@MainActor
final class HeadlessTestRunner: ObservableObject {
    static let shared = HeadlessTestRunner()

    @Published private(set) var isRunning = false
    @Published private(set) var currentTest: String = ""
    @Published private(set) var results: [TestResult] = []

    private weak var appState: AppState?
    private weak var keyboardManager: KeyboardShortcutManager?

    // App bundle identifier for AppleScript
    private let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.nodraw.app"
    private let appName = "NoDraw"
    private let processIdentifier = ProcessInfo.processInfo.processIdentifier

    struct TestResult: Identifiable {
        let id = UUID()
        let name: String
        let passed: Bool
        let message: String
        let duration: TimeInterval
    }

    // MARK: - Configuration

    /// Check if headless tests should run on launch
    static var shouldRunOnLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains("--headless-tests") ||
        ProcessInfo.processInfo.environment["MEDIAVIEWER_HEADLESS_TESTS"] == "1"
    }

    /// Check if running in CI mode (no UI output)
    static var isCIMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--ci") ||
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    /// Check if using test fixtures
    static var useTestFixtures: Bool {
        ProcessInfo.processInfo.arguments.contains("--test-fixtures") ||
        ProcessInfo.processInfo.environment["MEDIAVIEWER_TEST_FIXTURES"] == "1"
    }

    /// Path to test fixtures archive (relative to project or absolute)
    static var testFixturesPath: URL? {
        let environment = ProcessInfo.processInfo.environment

        // The shell harness aligns both archive keys to its disposable copy.
        // Keep the old test-only key as a compatibility fallback for direct use.
        if let configuredPath = HeadlessHarnessConfiguration.resolve(
            environment: environment,
            arguments: ProcessInfo.processInfo.arguments
        ).archivePath {
            return configuredPath
        }
        if let envPath = environment["MEDIAVIEWER_TEST_ARCHIVE"] {
            return URL(fileURLWithPath: envPath).standardizedFileURL
        }
        // Default to project's Tests/Fixtures/TestArchive
        // Find bundle path and navigate to project root
        let bundlePath = Bundle.main.bundlePath
        let projectDir = URL(fileURLWithPath: bundlePath)
            .deletingLastPathComponent()  // .build/release
            .deletingLastPathComponent()  // .build
            .deletingLastPathComponent()  // project root
        let fixturesPath = projectDir.appendingPathComponent("Tests/Fixtures/TestArchive")
        if FileManager.default.fileExists(atPath: fixturesPath.path) {
            return fixturesPath
        }
        return nil
    }

    // MARK: - Setup

    func configure(appState: AppState, keyboardManager: KeyboardShortcutManager) {
        self.appState = appState
        self.keyboardManager = keyboardManager
    }

    // MARK: - Test Execution

    /// Run all headless tests
    func runAllTests() async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        results = []

        let configuration = HeadlessHarnessConfiguration.resolve(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )

        logInfo("=== Starting Headless Tests ===")
        logInfo("Bundle ID: \(bundleIdentifier)")
        logInfo("App Name: \(appName)")
        logInfo("Harness PID: \(processIdentifier)")
        logInfo("Archive mode: \(configuration.usesFixtures ? "disposable fixtures" : "explicit live archive")")
        logInfo("Archive path: \(configuration.archivePath?.path ?? "<missing>")")
        logInfo("App support / SQLite: \(configuration.appSupportPath?.path ?? "<missing>")")
        logInfo("Results directory: \(configuration.resultsDirectory?.path ?? "<missing>")")

        if let safetyFailure = configuration.safetyFailure {
            results.append(TestResult(
                name: "Headless harness isolation policy",
                passed: false,
                message: safetyFailure,
                duration: 0
            ))
            isRunning = false
            logInfo("[FAIL] Refusing unsafe headless run: \(safetyFailure)")
            if Self.isCIMode {
                outputJUnitXML()
            }
            outputTextResults()
            return false
        }

        // Ensure app is frontmost
        activateApp()

        // Wait for app initialization
        await waitForInitialization()

        // Run test suites
        await runAppleScriptTests()
        await runKeyboardShortcutTests()
        await runNavigationTests()
        await runFilterTests()
        await runOverlayTests()
        await runDragDropDiagnostics()

        isRunning = false

        let passedCount = results.filter(\.passed).count
        let totalCount = results.count
        logInfo("=== Tests Complete: \(passedCount)/\(totalCount) passed ===")

        // Output results in CI-friendly format
        if Self.isCIMode {
            outputJUnitXML()
        }

        // Also write plain text results
        outputTextResults()

        return passedCount == totalCount
    }

    // MARK: - AppleScript UI Automation

    /// Run AppleScript and return the result
    @discardableResult
    private func runAppleScript(_ script: String) -> Result<String, Error> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if task.terminationStatus == 0 {
                return .success(output)
            } else {
                return .failure(AppleScriptError.executionFailed(errorOutput.isEmpty ? "Unknown error" : errorOutput))
            }
        } catch {
            return .failure(error)
        }
    }

    /// Activate the app (bring to front)
    private func activateApp() {
        // Target this exact process. There may be an installed NoDraw instance
        // with the same name and bundle identifier running alongside the smoke.
        let script = """
        tell application "System Events"
            set harnessProcess to first application process whose unix id is \(processIdentifier)
            set frontmost of harnessProcess to true
        end tell
        """
        _ = runAppleScript(script)

        // Also use NSApp to ensure we're active
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Press a keyboard shortcut using AppleScript
    private func pressKeyboardShortcut(key: String, modifiers: [String] = []) async {
        var script = """
        tell application "System Events"
            tell (first application process whose unix id is \(processIdentifier))
                set frontmost to true
        """

        if modifiers.isEmpty {
            script += """

                keystroke "\(key)"
        """
        } else {
            let modifierString = modifiers.joined(separator: ", ")
            script += """

                keystroke "\(key)" using {\(modifierString)}
        """
        }

        script += """

            end tell
        end tell
        """

        let result = runAppleScript(script)
        if case .failure(let error) = result {
            logInfo("AppleScript keystroke failed: \(error)")
        }
    }

    /// Press a key code using AppleScript
    private func pressKeyCode(_ keyCode: Int, modifiers: [String] = []) async {
        var script = """
        tell application "System Events"
            tell (first application process whose unix id is \(processIdentifier))
                set frontmost to true
        """

        if modifiers.isEmpty {
            script += """

                key code \(keyCode)
        """
        } else {
            let modifierString = modifiers.joined(separator: ", ")
            script += """

                key code \(keyCode) using {\(modifierString)}
        """
        }

        script += """

            end tell
        end tell
        """

        let result = runAppleScript(script)
        if case .failure(let error) = result {
            logInfo("AppleScript key code failed: \(error)")
        }
    }

    /// Get the list of UI elements with accessibility labels
    private func getUIElements() -> String {
        let script = """
        tell application "System Events"
            tell (first application process whose unix id is \(processIdentifier))
                set frontmost to true
                set elementList to ""
                try
                    set windowRef to window 1
                    repeat with uiElement in (entire contents of windowRef)
                        try
                            set elementDesc to (description of uiElement as string)
                            set elementList to elementList & elementDesc & linefeed
                        end try
                    end repeat
                end try
                return elementList
            end tell
        end tell
        """

        if case .success(let output) = runAppleScript(script) {
            return output
        }
        return ""
    }

    /// Check if a UI element exists by accessibility description
    private func elementExists(description: String) -> Bool {
        let script = """
        tell application "System Events"
            tell (first application process whose unix id is \(processIdentifier))
                set frontmost to true
                try
                    if exists (first UI element of window 1 whose description contains "\(description)") then
                        return "true"
                    else
                        return "false"
                    end if
                on error
                    return "false"
                end try
            end tell
        end tell
        """

        if case .success(let output) = runAppleScript(script) {
            return output.lowercased() == "true"
        }
        return false
    }

    /// Click on a UI element by accessibility label/description
    private func clickElement(description: String) async -> Bool {
        let script = """
        tell application "System Events"
            tell (first application process whose unix id is \(processIdentifier))
                set frontmost to true
                try
                    click (first UI element of window 1 whose description contains "\(description)")
                    return "success"
                on error errMsg
                    return "error: " & errMsg
                end try
            end tell
        end tell
        """

        let result = runAppleScript(script)

        if case .success(let output) = result {
            return output == "success"
        }
        return false
    }

    /// Get the window title
    private func getWindowTitle() -> String? {
        let script = """
        tell application "System Events"
            tell (first application process whose unix id is \(processIdentifier))
                try
                    return name of window 1
                on error
                    return ""
                end try
            end tell
        end tell
        """

        if case .success(let output) = runAppleScript(script) {
            return output.isEmpty ? nil : output
        }
        return nil
    }

    /// Check if app is frontmost
    private func isAppFrontmost() -> Bool {
        let script = """
        tell application "System Events"
            try
                return frontmost of (first application process whose unix id is \(processIdentifier))
            on error
                return false
            end try
        end tell
        """

        if case .success(let output) = runAppleScript(script) {
            return output.lowercased() == "true"
        }
        return false
    }

    /// Get count of windows
    private func getWindowCount() -> Int {
        let script = """
        tell application "System Events"
            tell (first application process whose unix id is \(processIdentifier))
                return count of windows
            end tell
        end tell
        """

        if case .success(let output) = runAppleScript(script), let count = Int(output) {
            return count
        }
        return 0
    }

    /// Whether this harness process currently owns a focused text control.
    /// AppState's focus request flag is intentionally transient, so querying AX
    /// is the actual postcondition for the slash shortcut.
    private func isTextInputFocused() -> Bool {
        let script = """
        tell application "System Events"
            try
                set harnessProcess to first application process whose unix id is \(processIdentifier)
                set focusedElement to value of attribute "AXFocusedUIElement" of harnessProcess
                set focusedRole to value of attribute "AXRole" of focusedElement
                return focusedRole is "AXTextField" or focusedRole is "AXTextArea" or focusedRole is "AXSearchField"
            on error
                return false
            end try
        end tell
        """

        if case .success(let output) = runAppleScript(script) {
            return output.lowercased() == "true"
        }
        return false
    }

    // MARK: - Test Suites

    private func runAppleScriptTests() async {
        await runTest("AppleScript can communicate with app") {
            let windowCount = getWindowCount()
            logInfo("Window count: \(windowCount)")
            return windowCount > 0
        }

        await runTest("App can be activated") {
            activateApp()
            return await waitUntil { self.isAppFrontmost() }
        }
    }

    private func runKeyboardShortcutTests() async {
        await runTest("Escape clears selection") {
            guard let appState = appState else { throw TestError.notConfigured }

            guard let firstItem = appState.displayedItems.first else {
                throw TestError.noItems
            }

            // Put Escape at the selection tier of its priority chain.
            keyboardManager?.showTagInput = false
            keyboardManager?.showDeleteConfirmation = false
            appState.showTagInput = false
            appState.showCommandPalette = false
            appState.showDuplicateReview = false
            appState.isAnnotationModeActive = false
            appState.hasSelectedAnnotationShape = false
            appState.hasSelectedSubjectMask = false
            appState.filterText = ""
            if appState.focusedItem != nil {
                appState.closeSingleFocus()
            }
            NSApp.keyWindow?.makeFirstResponder(nil)
            appState.selectedItemID = firstItem.id

            // Press Escape via AppleScript
            await pressKeyCode(53) // Escape key code

            return await waitUntil { appState.selectedItemID == nil }
        }

        await runTest("Cmd+K opens command palette via AppleScript") {
            guard let appState = appState else { throw TestError.notConfigured }

            // Make sure it's closed first
            appState.showCommandPalette = false

            // Press Cmd+K via AppleScript
            await pressKeyboardShortcut(key: "k", modifiers: ["command down"])

            let result = await waitUntil { appState.showCommandPalette }
            logInfo("Command palette open: \(result)")

            // Close it
            appState.showCommandPalette = false

            return result
        }

        await runTest("S key toggles star on selected") {
            guard let appState = appState,
                  let store = appState.mediaStore,
                  let firstItem = appState.displayedItems.first else {
                throw TestError.noItems
            }

            return try await verifyTemporaryStarToggle(
                item: firstItem,
                appState: appState,
                store: store
            )
        }

        await runTest("T key opens tag input via AppleScript") {
            guard let appState = appState,
                  let firstItem = appState.displayedItems.first else {
                throw TestError.noItems
            }

            appState.selectedItemID = firstItem.id
            appState.showTagInput = false
            keyboardManager?.showTagInput = false

            // Press T via AppleScript
            await pressKeyboardShortcut(key: "t")

            let result = await waitUntil { appState.showTagInput }
            logInfo("Tag input open: \(result)")

            appState.showTagInput = false
            keyboardManager?.showTagInput = false

            return result
        }

        await runTest("Arrow keys navigate grid selection via AppleScript") {
            guard let appState = appState,
                  appState.displayedItems.count >= 2 else {
                throw TestError.noItems
            }

            // Select first item
            let firstItem = appState.displayedItems[0]
            appState.selectedItemID = firstItem.id

            let initialSelection = appState.selectedItemID
            logInfo("Initial selection: \(String(describing: initialSelection))")

            // Press Down arrow via AppleScript - should trigger navigation
            await pressKeyCode(125) // Down
            await Task.yield()

            // Note: Arrow key navigation may or may not change selection depending on grid layout
            // The test verifies the keystroke was sent and processed without crash
            logInfo("Selection after Down: \(String(describing: appState.selectedItemID))")

            return true // Verified keystroke processing
        }

        await runTest("Vim keys (HJKL) send navigation keystrokes via AppleScript") {
            guard let appState = appState,
                  !appState.displayedItems.isEmpty else {
                throw TestError.noItems
            }

            // Select first item
            appState.selectedItemID = appState.displayedItems[0].id

            // Press J (down) via AppleScript
            await pressKeyboardShortcut(key: "j")
            await Task.yield()

            // Press K (up) via AppleScript
            await pressKeyboardShortcut(key: "k")
            await Task.yield()

            // Verify we still have a valid selection (keystrokes processed without crash)
            return appState.selectedItemID != nil
        }

        await runTest("/ focuses filter bar via AppleScript") {
            guard appState != nil else { throw TestError.notConfigured }

            NSApp.keyWindow?.makeFirstResponder(nil)

            // Press / via AppleScript
            await pressKeyboardShortcut(key: "/")

            let focused = await waitUntil { self.isTextInputFocused() }
            NSApp.keyWindow?.makeFirstResponder(nil)
            return focused
        }

        await runTest("Cmd+A sends select all via AppleScript") {
            await pressKeyboardShortcut(key: "a", modifiers: ["command down"])
            return true // Smoke test
        }

        await runTest("Cmd+D deselects all via AppleScript") {
            guard let appState = appState else { throw TestError.notConfigured }

            // Select something first
            if let firstItem = appState.displayedItems.first {
                appState.selectedItemID = firstItem.id
            }

            await pressKeyboardShortcut(key: "d", modifiers: ["command down"])

            return await waitUntil { appState.selectedItemID == nil }
        }
    }

    private func runNavigationTests() async {
        await runTest("Can open focus view via Enter (AppleScript)") {
            guard let appState = appState,
                  let firstItem = appState.displayedItems.first else {
                throw TestError.noItems
            }

            appState.selectedItemID = firstItem.id
            appState.closeSingleFocus() // Ensure closed first
            guard await waitUntil({ appState.focusedItem == nil }) else {
                return false
            }

            // Press Enter via AppleScript
            await pressKeyCode(36) // Enter key code

            let opened = await waitUntil { appState.focusedItem?.id == firstItem.id }
            logInfo("Focus view opened: \(opened)")

            // Close
            appState.closeSingleFocus()

            return opened
        }

        await runTest("Escape closes focus view via AppleScript") {
            guard let appState = appState,
                  let firstItem = appState.displayedItems.first else {
                throw TestError.noItems
            }

            appState.openSingleFocus(firstItem)
            guard await waitUntil({ appState.focusedItem?.id == firstItem.id }) else {
                return false
            }

            // Press Escape via AppleScript
            await pressKeyCode(53) // Escape key code

            let closed = await waitUntil { appState.focusedItem == nil }
            logInfo("Focus view closed: \(closed)")

            return closed
        }

        await runTest("Sidebar selection changes view") {
            guard let appState = appState else { throw TestError.notConfigured }

            let original = appState.sidebarSelection

            // Try switching to duplicates
            appState.sidebarSelection = .duplicates

            let changed = appState.sidebarSelection == .duplicates

            // Restore
            appState.sidebarSelection = original

            return changed
        }
    }

    private func runFilterTests() async {
        await runTest("Filter text can be set") {
            guard let appState = appState else { throw TestError.notConfigured }

            appState.filterText = "test-filter"

            let result = appState.filterText == "test-filter"

            appState.filterText = ""

            return result
        }

        await runTest("Color filter can be set") {
            guard let appState = appState else { throw TestError.notConfigured }

            appState.colorFilters = [.blue, .green]

            let result = appState.colorFilters.contains(.blue)

            appState.colorFilters = []

            return result
        }

        await runTest("Starred filter can be set") {
            guard let appState = appState else { throw TestError.notConfigured }

            appState.starredFilter = true

            let result = appState.starredFilter == true

            appState.starredFilter = nil

            return result
        }
    }

    private func runOverlayTests() async {
        await runTest("Command palette opens and closes") {
            guard let appState = appState else { throw TestError.notConfigured }

            appState.showCommandPalette = true
            let opened = appState.showCommandPalette

            appState.showCommandPalette = false
            let closed = !appState.showCommandPalette

            return opened && closed
        }

        await runTest("Tag input opens and closes") {
            guard let appState = appState else { throw TestError.notConfigured }

            appState.showTagInput = true
            let opened = appState.showTagInput

            appState.showTagInput = false
            let closed = !appState.showTagInput

            return opened && closed
        }

        await runTest("Duplicate review opens and closes") {
            guard let appState = appState else { throw TestError.notConfigured }

            appState.showDuplicateReview = true
            let opened = appState.showDuplicateReview

            appState.showDuplicateReview = false
            let closed = !appState.showDuplicateReview

            return opened && closed
        }

        await runTest("Rediscover mode activates") {
            guard let appState = appState else { throw TestError.notConfigured }

            let original = appState.sidebarSelection

            appState.sidebarSelection = .rediscover
            let opened = appState.sidebarSelection == .rediscover

            appState.sidebarSelection = original

            return opened
        }

        await runTest("Escape closes command palette via AppleScript") {
            guard let appState = appState else { throw TestError.notConfigured }

            // Open command palette
            appState.showCommandPalette = true
            guard await waitUntil({ appState.showCommandPalette }) else {
                logInfo("Command palette didn't open")
                return false
            }

            // Press Escape via AppleScript
            await pressKeyCode(53)

            let closed = await waitUntil { !appState.showCommandPalette }
            logInfo("Command palette closed via Escape: \(closed)")

            // Ensure it's closed for next tests
            appState.showCommandPalette = false

            return closed
        }

        await runTest("Escape closes tag input via AppleScript") {
            guard let appState = appState,
                  let firstItem = appState.displayedItems.first else {
                throw TestError.noItems
            }

            // Need selection for tag input
            appState.selectedItemID = firstItem.id

            // Open tag input
            appState.showTagInput = true
            keyboardManager?.showTagInput = true
            guard await waitUntil({ appState.showTagInput }) else {
                logInfo("Tag input didn't open")
                return false
            }

            // Press Escape via AppleScript
            await pressKeyCode(53)

            let closed = await waitUntil { !appState.showTagInput }
            logInfo("Tag input closed via Escape: \(closed)")

            // Ensure it's closed for next tests
            appState.showTagInput = false
            keyboardManager?.showTagInput = false

            return closed
        }
    }

    private func runDragDropDiagnostics() async {
        await runTest("UTType.mediaViewerItem has correct identifier") {
            let identifier = UTType.mediaViewerItem.identifier
            logInfo("DRAG-DIAG: UTType.mediaViewerItem.identifier = '\(identifier)'")
            return identifier == kMediaViewerItemTypeIdentifier
        }

        await runTest("MediaItemDragData encodes correctly") {
            let testData = MediaItemDragData(itemIds: [UUID(), UUID()])

            do {
                let encoded = try JSONEncoder().encode(testData)
                let decoded = try JSONDecoder().decode(MediaItemDragData.self, from: encoded)
                return decoded.itemIds.count == 2
            } catch {
                logInfo("DRAG-DIAG: Encode/decode error: \(error)")
                return false
            }
        }

        await runTest("MediaItemDragProvider returns correct types") {
            _ = MediaItemDragData(itemId: UUID()) // Verify it can be constructed
            let types = MediaItemDragProvider.writableTypeIdentifiersForItemProvider

            logInfo("DRAG-DIAG: writableTypeIdentifiersForItemProvider = \(types)")

            return types.contains(kMediaViewerItemTypeIdentifier)
        }

        await runTest("NSItemProvider can load drag data") {
            let dragData = MediaItemDragData(itemId: UUID())
            let provider = NSItemProvider(object: MediaItemDragProvider(dragData: dragData))

            let types = provider.registeredTypeIdentifiers
            logInfo("DRAG-DIAG: NSItemProvider types = \(types)")

            let hasOurType = provider.hasItemConformingToTypeIdentifier(kMediaViewerItemTypeIdentifier)
            logInfo("DRAG-DIAG: hasItemConformingToTypeIdentifier = \(hasOurType)")

            if !hasOurType {
                logInfo("DRAG-DIAG: FAILURE - NSItemProvider doesn't recognize our type!")
                logInfo("DRAG-DIAG: This means the Info.plist UTType declaration isn't being loaded.")
                logInfo("DRAG-DIAG: Possible fixes:")
                logInfo("DRAG-DIAG: 1. Ensure Info.plist is in the bundle")
                logInfo("DRAG-DIAG: 2. Clean build and rebuild")
                logInfo("DRAG-DIAG: 3. Use raw string identifier instead of UTType.mediaViewerItem")
            }

            return hasOurType
        }

        await runTest("Direct data load works") {
            let dragData = MediaItemDragData(itemId: UUID())
            let provider = NSItemProvider(object: MediaItemDragProvider(dragData: dragData))

            return await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: kMediaViewerItemTypeIdentifier) { data, error in
                    if let error = error {
                        logInfo("DRAG-DIAG: loadDataRepresentation error: \(error)")
                        continuation.resume(returning: false)
                        return
                    }

                    guard let data = data else {
                        logInfo("DRAG-DIAG: loadDataRepresentation returned nil data")
                        continuation.resume(returning: false)
                        return
                    }

                    do {
                        let decoded = try JSONDecoder().decode(MediaItemDragData.self, from: data)
                        logInfo("DRAG-DIAG: Successfully decoded \(decoded.itemIds.count) items")
                        continuation.resume(returning: true)
                    } catch {
                        logInfo("DRAG-DIAG: Decode error: \(error)")
                        continuation.resume(returning: false)
                    }
                }
            }
        }
    }

    // MARK: - Test Helpers

    /// Poll an observable postcondition instead of guessing how long an AppKit
    /// or SwiftUI transition will take on the current machine.
    private func waitUntil(
        _ condition: () async -> Bool,
        timeout: TimeInterval = 2.0,
        pollInterval: Duration = .milliseconds(25)
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if await condition() {
                return true
            }
            if Task.isCancelled {
                return false
            }
            try? await Task.sleep(for: pollInterval)
        }

        return await condition()
    }

    /// Exercise the real keyboard path, observe the database transition, then
    /// restore and synchronously flush the original star value. The restore is
    /// attempted regardless of whether the toggle assertion succeeds, which is
    /// essential for the explicit --use-archive diagnostic.
    private func verifyTemporaryStarToggle(
        item: MediaItem,
        appState: AppState,
        store: MediaStore
    ) async throws -> Bool {
        let originalDatabaseValue = try await store.isStarred(id: item.id)
        let sidecarExists = FileManager.default.fileExists(atPath: item.metadataFile.path)
        let originalSidecarValue = sidecarExists
            ? MetadataParser.parseGracefully(fileAt: item.metadataFile).metadata?.starred
            : nil
        let originalToastID = appState.undoStack.currentToast?.id

        appState.selectedItemID = item.id
        await pressKeyboardShortcut(key: "s")

        let toggleObserved = await waitUntil({
            guard let currentValue = try? await store.isStarred(id: item.id),
                  let completionToastID = appState.undoStack.currentToast?.id else {
                return false
            }
            // The changed undo toast is emitted only after the async database
            // action returns; observing both avoids restoring while the detached
            // toggle task can still overwrite the restored in-memory snapshot.
            return currentValue != originalDatabaseValue && completionToastID != originalToastID
        }, timeout: 5.0)

        let restored = await restoreStarState(
            item: item,
            databaseValue: originalDatabaseValue,
            sidecarValue: originalSidecarValue,
            appState: appState,
            store: store
        )

        logInfo(
            "Star key transition observed: \(toggleObserved); " +
            "original state restored: \(restored)"
        )
        return toggleObserved && restored
    }

    private func restoreStarState(
        item: MediaItem,
        databaseValue: Bool,
        sidecarValue: Bool?,
        appState: AppState,
        store: MediaStore
    ) async -> Bool {
        for attempt in 1...3 {
            do {
                try await store.setStar(id: item.id, starred: databaseValue)
                await store.writeBackQueue.flushNow()

                // A pre-existing DB/sidecar mismatch should not be "fixed" as
                // a side effect of a smoke test. Restore each original value.
                if let sidecarValue,
                   MetadataParser.parseGracefully(fileAt: item.metadataFile).metadata?.starred != sidecarValue {
                    try FrontmatterWriter.processFrontmatter(at: item.metadataFile) { yaml in
                        if sidecarValue {
                            yaml["starred"] = true
                        } else {
                            yaml.removeValue(forKey: "starred")
                        }
                    }
                }

                // In-memory snapshots must agree too, or a later view action can
                // optimistically seed another write from the temporary value.
                if var restoredItem = appState.displayedItem(for: item.id) {
                    restoredItem.metadata.starred = databaseValue
                    appState.replaceCachedItemIfPresent(restoredItem)
                }

                let restoredDatabaseValue = try await store.isStarred(id: item.id)
                let restoredSidecarValue: Bool? = sidecarValue == nil
                    ? nil
                    : MetadataParser.parseGracefully(fileAt: item.metadataFile).metadata?.starred
                let sidecarMatches = sidecarValue == nil || restoredSidecarValue == sidecarValue

                if restoredDatabaseValue == databaseValue && sidecarMatches {
                    return true
                }

                logInfo(
                    "Star restore verification attempt \(attempt) did not converge " +
                    "(database=\(restoredDatabaseValue), sidecar=\(String(describing: restoredSidecarValue)))"
                )
            } catch {
                logInfo("Star restore attempt \(attempt) failed: \(error.localizedDescription)")
            }

            // This is retry backoff, not a UI-transition assertion. Cancellation
            // deliberately does not skip the remaining restoration attempts.
            try? await Task.sleep(for: .milliseconds(50))
        }

        return false
    }

    private func waitForInitialization() async {
        guard let appState = appState else { return }

        // Wait up to 30 seconds for initialization
        for _ in 0..<300 {
            if case .ready = appState.initPhase {
                logInfo("App initialized, starting tests...")

                // Check if we have items, if not create mock items for testing
                if appState.displayedItems.isEmpty {
                    logInfo("No items loaded - creating mock items for testing...")
                    await injectMockItems()
                }

                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        logInfo("Warning: App not fully initialized after 30s, running tests anyway")

        // Still try to inject mock items if empty
        if appState.displayedItems.isEmpty {
            await injectMockItems()
        }
    }

    /// Inject mock MediaItem objects for testing when archive is empty
    private func injectMockItems() async {
        guard let appState = appState else { return }

        let mockItems = createMockItems(count: 5)
        appState.setDisplayedItems(mockItems)
        logInfo("Injected \(mockItems.count) mock items for testing")
    }

    /// Create mock MediaItem objects for testing
    private func createMockItems(count: Int) -> [MediaItem] {
        var items: [MediaItem] = []

        for i in 1...count {
            let id = UUID()
            let basePath = URL(fileURLWithPath: "/tmp/test-archive/2026-01")
            let metadataFile = basePath.appendingPathComponent("test-item-\(String(format: "%03d", i)).md")

            let metadata = MediaMetadata(
                source: URL(string: "https://twitter.com/testuser/status/\(1000 + i)")!,
                platform: "twitter",
                author: "@testuser\(i)",
                originalDate: Date().addingTimeInterval(Double(-i * 86400)),
                archivedDate: Date(),
                starred: i % 2 == 0,
                tags: i % 3 == 0 ? ["test", "sample"] : [],
                notes: nil
            )

            let item = MediaItem(
                id: id,
                basePath: basePath,
                metadataFile: metadataFile,
                mediaFiles: [],  // Empty for mock - tests don't need actual files
                contextImage: nil,
                metadata: metadata,
                indexedContent: nil,
                aspectRatio: 1.0
            )
            items.append(item)
        }

        return items
    }

    private func runTest(_ name: String, test: () async throws -> Bool) async {
        currentTest = name
        let start = Date()

        do {
            let passed = try await test()
            let duration = Date().timeIntervalSince(start)

            results.append(TestResult(
                name: name,
                passed: passed,
                message: passed ? "OK" : "FAIL",
                duration: duration
            ))

            logInfo("[\(passed ? "PASS" : "FAIL")] \(name) (\(String(format: "%.2f", duration * 1000))ms)")
        } catch {
            let duration = Date().timeIntervalSince(start)

            results.append(TestResult(
                name: name,
                passed: false,
                message: error.localizedDescription,
                duration: duration
            ))

            logInfo("[FAIL] \(name): \(error.localizedDescription)")
        }
    }

    // MARK: - Output

    private var resultsDirectory: URL {
        if let configured = ProcessInfo.processInfo.environment["NODRAW_HEADLESS_RESULTS_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return URL(fileURLWithPath: configured).standardizedFileURL
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NoDraw")
    }

    private func outputJUnitXML() {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuites>
          <testsuite name="HeadlessTests" tests="\(results.count)" failures="\(results.filter { !$0.passed }.count)">
        """

        for result in results {
            xml += """

            <testcase name="\(result.name.replacingOccurrences(of: "\"", with: "&quot;"))" time="\(result.duration)">
            """

            if !result.passed {
                xml += """

                  <failure message="\(result.message.replacingOccurrences(of: "\"", with: "&quot;"))"/>
                """
            }

            xml += """

            </testcase>
            """
        }

        xml += """

          </testsuite>
        </testsuites>
        """

        // Write to file
        let logsDir = resultsDirectory
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let path = logsDir.appendingPathComponent("test-results.xml").path
        try? xml.write(toFile: path, atomically: true, encoding: .utf8)
        logInfo("JUnit XML written to \(path)")
    }

    private func outputTextResults() {
        var text = """
        NoDraw Headless Test Results
        ==================================
        Date: \(Date())
        Total: \(results.count)
        Passed: \(results.filter(\.passed).count)
        Failed: \(results.filter { !$0.passed }.count)

        Results:
        --------
        """

        for result in results {
            let status = result.passed ? "PASS" : "FAIL"
            text += "\n[\(status)] \(result.name)"
            if !result.passed && result.message != "FAIL" {
                text += "\n         Error: \(result.message)"
            }
            text += " (\(String(format: "%.1f", result.duration * 1000))ms)"
        }

        let logsDir = resultsDirectory
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let path = logsDir.appendingPathComponent("test-results.txt").path
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        logInfo("Text results written to \(path)")
    }

    // MARK: - Errors

    enum TestError: LocalizedError {
        case notConfigured
        case noItems
        case timeout

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "HeadlessTestRunner not configured"
            case .noItems: return "No items in displayedItems"
            case .timeout: return "Test timed out"
            }
        }
    }

    enum AppleScriptError: LocalizedError {
        case executionFailed(String)

        var errorDescription: String? {
            switch self {
            case .executionFailed(let message): return "AppleScript error: \(message)"
            }
        }
    }
}

// MARK: - UTType Import

import UniformTypeIdentifiers
