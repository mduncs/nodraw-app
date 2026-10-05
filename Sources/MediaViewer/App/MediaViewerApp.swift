import SwiftUI
import Combine
import AppKit
import Darwin

// MARK: - App Delegate

/// App delegate for single-instance enforcement and app lifecycle
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationPending = false
    private var terminationApproved = false
    private var terminationFlushTask: Task<Void, Never>?
    private var terminationDeadlineTask: Task<Void, Never>?
    private var backgroundQA: Bool { BackgroundQAConfiguration.usesNonactivatingWindows }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if BackgroundQAConfiguration.isEnabled {
            do { _ = try BackgroundQAConfiguration.validate(environment: ProcessInfo.processInfo.environment) }
            catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                _exit(64)
            }
        }
        // Install crash telemetry before anything else
        CrashTelemetry.install()

        // One library window: no Show Tab Bar / Merge All Windows items in View and Window.
        NSWindow.allowsAutomaticWindowTabbing = false

        logInfo("=== NoDraw Starting ===")

        if BackgroundQAConfiguration.launchMode == .editorPreview {
            logInfo("Editor preview: isolated data; background maintenance, notifications and server changes suppressed")
        }

        if backgroundQA {
            // QA never activates an installed instance. Explicit directory overrides are
            // required so a bare flag cannot accidentally run against the default library.
            logInfo("Background QA: browsing-only baseline; enrichment, maintenance, notifications and server changes suppressed")
            NSApp.setActivationPolicy(.accessory)
            return
        }

        // Check for existing instance before window appears
        if !SingleInstanceGuard.shared.acquireLock() {
            logWarning("Another instance is already running")
            // Exit immediately: the existing instance has already been activated.
            _exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !SingleInstanceGuard.shared.duplicateLaunchDetected else { return }

        // For CLI binaries, we need to set activation policy to show in dock and receive keyboard events
        NSApp.setActivationPolicy(backgroundQA ? .accessory : .regular)
        if !backgroundQA { NSApp.activate(ignoringOtherApps: true) }
        AppInteractionMonitor.shared.start()
        if !backgroundQA { NotificationService.shared.requestPermission() }

        // Make the window key and order front
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApp.windows.first else { return }
            if self.backgroundQA { window.orderBack(nil) }
            else {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationApproved { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        terminationFlushTask = Task { [weak self] in
            await AppState.flushWriteBackQueue()
            self?.approveTermination(sender)
        }
        terminationDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.approveTermination(sender)
        }
        return .terminateLater
    }

    private func approveTermination(_ sender: NSApplication) {
        guard !terminationApproved else { return }
        terminationApproved = true
        terminationFlushTask?.cancel()
        terminationDeadlineTask?.cancel()
        // Remaining projection intent is durable and resumes at startup if IO exceeded
        // the deadline. The main actor stays free for the flush and AppKit termination.
        sender.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationFlushTask?.cancel()
        terminationDeadlineTask?.cancel()

        // Clean shutdown telemetry
        CrashTelemetry.shutdown()

        AppInteractionMonitor.shared.stop()

        // Release the lock
        SingleInstanceGuard.shared.releaseLock()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let showItem = NSMenuItem(
            title: "Show NoDraw",
            action: #selector(showFromDock),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())

        let isServerRunning = DownloadServerManager.shared.isRunning
        let statusItem = NSMenuItem(
            title: "Download Server: \(isServerRunning ? "Running" : "Stopped")",
            action: nil,
            keyEquivalent: ""
        )
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        let toggleItem = NSMenuItem(
            title: "Toggle Download Server",
            action: #selector(toggleDownloadServerFromDock),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        return menu
    }

    @objc private func showFromDock() {
        guard !backgroundQA else { NSApp.windows.first?.orderBack(nil); return }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func toggleDownloadServerFromDock() {
        Task { @MainActor in
            let manager = DownloadServerManager.shared
            if manager.isRunning {
                manager.isEnabled = false
                manager.stop()
            } else {
                manager.isEnabled = true
                do {
                    try await manager.start()
                } catch {
                    logError("Failed to start download server from dock menu: \(error.localizedDescription)")
                }
            }
        }
    }
}

/// Check if a text field is the first responder (for Edit menu responder chain)
private func isTextFieldFirstResponder() -> Bool {
    guard let window = NSApp.keyWindow,
          let firstResponder = window.firstResponder else {
        return false
    }

    // Check if it's actually a text editing view (field editor)
    if let textView = firstResponder as? NSTextView {
        if textView.isFieldEditor {
            return true
        }
        // Catch SwiftUI TextEditor (standalone editable NSTextView, not a field editor)
        if textView.isEditable {
            return true
        }
    }

    // Direct NSTextField
    if firstResponder is NSTextField {
        return true
    }

    // Check class names for SwiftUI text input controls
    let className = firstResponder.className
    return className.contains("NSSearchField") ||
           className.contains("SecureTextField") ||
           (className.contains("TextField") && className.contains("Cell"))
}

/// Check whether the focused item's preferred display source is supported by the trim pipeline.
@MainActor
private func isCurrentFocusedItemTrimmable(appState: AppState) -> Bool {
    appState.focusedItem?.isPreferredDisplaySourceTrimmable ?? false
}

/// Issue #8: Help text for Trim Video menu item based on state
@MainActor
private func trimVideoHelpText(appState: AppState) -> String {
    if !appState.isShowingSingleFocus {
        return "Open a video in detail view first"
    } else if !isCurrentFocusedItemTrimmable(appState: appState) {
        return "Trim is available when the displayed source is MP4, MOV, or M4V"
    } else {
        return "Trim the video to a shorter clip"
    }
}

/// Zoom window to fill screen (like double-click title bar)
private func zoomWindow() {
    guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
    window.zoom(nil)
}

@main
struct NoDrawApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var keyboardManager = KeyboardShortcutManager()
    @StateObject private var testRunner = HeadlessTestRunner.shared
    @StateObject private var screenshotAutomation = ScreenshotAutomationRunner.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .background(MainWindowFrameRestoration())
                .environmentObject(appState)
                .environmentObject(keyboardManager)
                .environmentObject(testRunner)
                .environment(SettingsStore.shared)
                .preferredColorScheme(.dark)
                .onAppear {
                    keyboardManager.configure(with: appState)
                    testRunner.configure(appState: appState, keyboardManager: keyboardManager)
                    screenshotAutomation.startIfNeeded(appState: appState)

                    // Auto-run tests if requested via CLI
                    if HeadlessTestRunner.shouldRunOnLaunch && !BackgroundQAConfiguration.isEnabled {
                        Task {
                            let success = await testRunner.runAllTests()
                            if HeadlessTestRunner.isCIMode {
                                // Exit with appropriate code in CI
                                exit(success ? 0 : 1)
                            }
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appInfo) {
                Button("About NoDraw") {
                    AboutPanelController.shared.show()
                }
            }
            #if canImport(Sparkle)
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    UpdaterService.shared.checkForUpdates()
                }
                .disabled(!UpdaterService.shared.canCheckForUpdates)
            }
            #endif

            // MARK: - Edit Menu (Issue #2, #3, #8: Standard macOS Edit menu)
            // Note: Cut/Copy/Paste use responder chain - they work automatically in text fields
            // and we override Cmd+C for image copy when no text field is focused.
            // These replace the system Edit menu's groups; a CommandMenu("Edit") added a second Edit menu.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    // Route to text field's undo if a text field has focus,
                    // otherwise use app's custom undo stack
                    if isTextFieldFirstResponder() {
                        NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                    } else {
                        appState.performUndo()
                    }
                }
                .keyboardShortcut("z", modifiers: .command)

                Button("Redo") {
                    if isTextFieldFirstResponder() {
                        NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                    } else {
                        appState.performRedo()
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .pasteboard) {
                // Standard edit actions - these use responder chain for text fields
                // NSApp.sendAction handles routing to the appropriate responder
                Button("Cut") {
                    if appState.isAnnotationModeActive && !isTextFieldFirstResponder() { ImageEditorMenuAction.cut.send() }
                    else { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                }
                .keyboardShortcut("x", modifiers: .command)

                Button("Copy") {
                    // Check if text field has focus - if so, use standard copy
                    // Otherwise, copy image to clipboard
                    if isTextFieldFirstResponder() {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    } else if appState.isAnnotationModeActive {
                        ImageEditorMenuAction.copy.send()
                    } else {
                        appState.copyDisplayedImage()
                    }
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!appState.isAnnotationModeActive && !appState.mediaActionContext.canCopyImage && !isTextFieldFirstResponder())
                .help(appState.selectedItemID == nil && appState.focusedItem == nil ? "Select an item to copy" : "Copy image to clipboard")

                Button("Paste") {
                    if appState.isAnnotationModeActive && !isTextFieldFirstResponder() { ImageEditorMenuAction.paste.send() }
                    else { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                }
                .keyboardShortcut("v", modifiers: .command)

                Divider()

                // Issue #3: Select All with responder chain check
                Button(appState.isAnnotationModeActive ? "Select All Objects" : "Select All Loaded Items") {
                    if isTextFieldFirstResponder() {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    } else if appState.isAnnotationModeActive {
                        ImageEditorMenuAction.selectAll.send()
                    } else {
                        NotificationCenter.default.post(name: .selectAll, object: nil)
                    }
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!appState.isAnnotationModeActive && !isTextFieldFirstResponder() && !LibraryViewportCommandRouter.isAvailable(in: appState))

                Button(appState.isAnnotationModeActive ? "Duplicate Objects" : "Deselect All") {
                    if appState.isAnnotationModeActive { ImageEditorMenuAction.duplicate.send() }
                    else {
                        appState.selectedItemID = nil
                        NotificationCenter.default.post(name: .deselectAll, object: nil)
                    }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!appState.isAnnotationModeActive && appState.selectedItemIDs.isEmpty && appState.selectedItemID == nil)
                .help(appState.isAnnotationModeActive ? "Duplicate selected image objects" : "Deselect all selected library items")

                Divider()

                // Issue #8: Trim Video menu item (Cmd+T in detail view for videos)
                // Note: T key shortcut is handled by KeyboardShortcutManager for no-modifier
                Button("Trim Video") {
                    NotificationCenter.default.post(name: .trimVideo, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!appState.isShowingSingleFocus || !isCurrentFocusedItemTrimmable(appState: appState))
                .help(trimVideoHelpText(appState: appState))
            }

            // MARK: - View Menu (Issue #8: View settings per HIG)
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Inspector Panel") {
                    if appState.isShowingSingleFocus {
                        appState.showFocusMetadataPanel.toggle()
                    } else {
                        appState.showInspectorPanel.toggle()
                    }
                }
                .keyboardShortcut("i", modifiers: .command)
                .help("Show or hide the metadata inspector panel")

                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleNavigationSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help("Show or hide the navigation sidebar")

                Divider()

                // Grid density controls (Issue #8)
                Button("Increase Grid Density") {
                    appState.gridDensity = max(0, appState.gridDensity - 0.2)
                }
                .keyboardShortcut("[", modifiers: [])
                .disabled(appState.isShowingSingleFocus)
                .help("Show more, smaller thumbnails")

                Button("Decrease Grid Density") {
                    appState.gridDensity = min(1, appState.gridDensity + 0.2)
                }
                .keyboardShortcut("]", modifiers: [])
                .disabled(appState.isShowingSingleFocus)
                .help("Show fewer, larger thumbnails")

                Button("Larger Thumbnails") {
                    appState.gridDensity = min(1, appState.gridDensity + 0.1)
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(appState.isShowingSingleFocus)
                .help("Increase thumbnail size")

                Button("Smaller Thumbnails") {
                    appState.gridDensity = max(0, appState.gridDensity - 0.1)
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(appState.isShowingSingleFocus)
                .help("Decrease thumbnail size")

                Divider()

                Button(appState.isShuffleActive ? "Turn Shuffle Off" : "Turn Shuffle On") {
                    appState.toggleShuffle()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(appState.isShowingSingleFocus)
                .help(appState.isShuffleActive ? "Return to sorted order" : "Shuffle the library with a stable order")

                Button("Reshuffle") {
                    appState.reshuffle()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(appState.isShowingSingleFocus || !appState.isShuffleActive)
                .help("Generate a new shuffled order")

                Divider()

                Toggle("Group Similar Aspect Ratios", isOn: $appState.useHybridLayout)
                    .help("Group similar aspect ratios into rows between columns")
                    .disabled(appState.browseMode == .table)

                Toggle("Show Color Bars", isOn: $appState.showColorBars)
                    .help("Display dominant colors on thumbnails")
                    .disabled(appState.browseMode == .table)

                Divider()

                // Issue #1 fix: Visual Clusters entry point via View menu
                Button("Visual Clusters") {
                    appState.commitLibraryDestinationChange(.visualClusters)
                }
                .help("Browse items grouped by visual similarity")

                Divider()
            }

            // MARK: - Go Menu (Issue #8: Renamed from Navigate per HIG)
            CommandMenu("Go") {
                Button(AppCommandCatalog.back.title) {
                    appState.navigateBack()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!appState.canNavigateBack)
                .help(AppCommandCatalog.back.help)

                Divider()

                Button(AppCommandCatalog.focusFilter.title) {
                    appState.focusFilterBar()
                }
                .keyboardShortcut("/", modifiers: [])
                .help(AppCommandCatalog.focusFilter.help)

                Button(AppCommandCatalog.find.title) {
                    appState.focusFilterBar()
                }
                .keyboardShortcut("f", modifiers: .command)
                .help(AppCommandCatalog.find.help)

                Button(AppCommandCatalog.commandPalette.title) {
                    appState.showCommandPalette = true
                }
                .keyboardShortcut("k", modifiers: .command)
                .help(AppCommandCatalog.commandPalette.help)

                Button(AppCommandCatalog.retainedFileDataTitle) {
                    appState.showRetainedFileData = true
                }
                .disabled(appState.mediaStore == nil)
                .help("Inspect preserved annotations and analysis whose original file or item could not be identified")

                Divider()

                Button(AppCommandCatalog.pageUp.title) {
                    LibraryViewportCommandRouter.post(.pageUp, appState: appState)
                }
                .keyboardShortcut(.pageUp, modifiers: [])
                .disabled(!LibraryViewportCommandRouter.isAvailable(in: appState))
                .help(AppCommandCatalog.pageUp.help)

                Button(AppCommandCatalog.pageDown.title) {
                    LibraryViewportCommandRouter.post(.pageDown, appState: appState)
                }
                .keyboardShortcut(.pageDown, modifiers: [])
                .disabled(!LibraryViewportCommandRouter.isAvailable(in: appState))
                .help(AppCommandCatalog.pageDown.help)

                Button(AppCommandCatalog.libraryTop.title) {
                    LibraryViewportCommandRouter.post(.first, appState: appState)
                }
                .keyboardShortcut(.home, modifiers: [])
                .disabled(!LibraryViewportCommandRouter.isAvailable(in: appState))
                .help(AppCommandCatalog.libraryTop.help)

                Button(AppCommandCatalog.libraryBottom.title) {
                    LibraryViewportCommandRouter.post(.last, appState: appState)
                }
                .keyboardShortcut(.end, modifiers: [])
                .disabled(!LibraryViewportCommandRouter.isAvailable(in: appState))
                .help(AppCommandCatalog.libraryBottom.help)

                Divider()

                Button(AppCommandCatalog.nextResult.title) {
                    appState.navigateToNextItem()
                }
                .keyboardShortcut("n", modifiers: [])
                .disabled(!appState.canNavigateToNextResult)
                .help(appState.isShowingSingleFocus ? AppCommandCatalog.nextResult.help : "Open a result in detail first")

                Button(AppCommandCatalog.previousResult.title) {
                    appState.navigateToPrevItem()
                }
                .keyboardShortcut("p", modifiers: [])
                .disabled(!appState.canNavigateToPreviousResult)
                .help(appState.isShowingSingleFocus ? AppCommandCatalog.previousResult.help : "Open a result in detail first")

                Divider()

                Button(AppCommandCatalog.previousAsset.title) {
                    NotificationCenter.default.post(name: .prevSubImage, object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(appState.isAnnotationModeActive || !appState.isShowingSingleFocus || appState.focusedPageCount < 2)
                .help(appState.focusedPageCount > 1 ? AppCommandCatalog.previousAsset.help : "Open a multi-asset item in detail first")

                Button(AppCommandCatalog.nextAsset.title) {
                    NotificationCenter.default.post(name: .nextSubImage, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command])
                .disabled(appState.isAnnotationModeActive || !appState.isShowingSingleFocus || appState.focusedPageCount < 2)
                .help(appState.focusedPageCount > 1 ? AppCommandCatalog.nextAsset.help : "Open a multi-asset item in detail first")
            }

            // MARK: - Item Menu (Issue #8: Renamed from Media, focused on item actions)
            CommandMenu("Item") {
                Button("Toggle Star") {
                    appState.toggleStarOnSelected()
                }
                .keyboardShortcut("s", modifiers: [])
                .disabled(appState.selectedItemID == nil && appState.focusedItem == nil)
                .help(appState.selectedItemID != nil || appState.focusedItem != nil ? "Star or unstar this item" : "Select an item first")

                Button("Add Tag...") {
                    appState.showTagInput = true
                }
                .keyboardShortcut("t", modifiers: [])
                .disabled(appState.isAnnotationModeActive || (appState.selectedItemID == nil && appState.focusedItem == nil))
                .help(appState.selectedItemID != nil || appState.focusedItem != nil ? "Add a tag to this item" : "Select an item first")

                if FeatureFlags.boards || FeatureFlags.rediscover {
                    Divider()
                }

                if FeatureFlags.boards {
                    Button("Add to Board...") {
                        NotificationCenter.default.post(name: .addToBoard, object: nil)
                    }
                    .keyboardShortcut("b", modifiers: [])
                    .disabled(appState.selectedItemID == nil && appState.focusedItem == nil)
                    .help(appState.selectedItemID != nil || appState.focusedItem != nil ? "Add to a board for curation" : "Select an item first")
                }

                if FeatureFlags.rediscover {
                    Button("Add to Rediscover") {
                        NotificationCenter.default.post(name: .addToRediscover, object: nil)
                    }
                    .keyboardShortcut("r", modifiers: [])
                    .disabled(appState.selectedItemID == nil && appState.focusedItem == nil)
                    .help(appState.selectedItemID != nil || appState.focusedItem != nil ? "Add to spaced repetition review" : "Select an item first")
                }

                Divider()

                Button("Open Source URL") {
                    NotificationCenter.default.post(name: .openSourceURL, object: nil)
                }
                .keyboardShortcut("o", modifiers: [])
                .disabled(appState.selectedItemID == nil && appState.focusedItem == nil)
                .help("Open the original source URL in browser")

                Button("Quick Export...") {
                    MediaFileAction.exportMetadata.perform(context: appState.mediaActionContext, source: .downloaded, appState: appState)
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!appState.mediaActionContext.isEnabled(.exportMetadata, source: .downloaded))
                .help("Choose a destination and export images with embedded metadata")

                Menu("Transfer Source") {
                    MediaTransferActionsMenu(context: appState.mediaActionContext)
                        .environmentObject(appState)
                }
                .disabled(appState.mediaActionContext.items.isEmpty)

                if FeatureFlags.annotate {
                    Button("Export Annotated Image...") {
                        NotificationCenter.default.post(name: .exportAnnotatedImage, object: nil)
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!appState.isShowingSingleFocus)
                    .help(appState.isShowingSingleFocus ? "Export image with annotations baked in" : "Open an item in focus view first")
                }

                Divider()

                Button("Re-index Colors") {
                    appState.reindexAllColors()
                }
                .help("Re-analyze all images with the expanded 12-color palette")
            }

            // MARK: - Help Menu (Issue #4: Add Help menu with shortcuts reference)
            CommandGroup(replacing: .help) {
                Button("Keyboard & Mouse Reference") {
                    appState.showKeyboardShortcutsHelp = true
                }
                .keyboardShortcut("/", modifiers: .command)
                .help("Show keyboard shortcuts and mouse gestures")
            }
        }

        Settings {
            SettingsRootView()
                .environmentObject(appState)
                .environment(SettingsStore.shared)
        }
        .windowResizability(.contentMinSize)
    }
}

// MARK: - Root View

/// Root view that handles initialization state
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                StartupContentView(phase: appState.initPhase, onRetry: {
                    Task { await appState.retryInitialization() }
                }) {
                    ContentView()
                }
            } else {
                OnboardingView {
                    hasCompletedOnboarding = true
                }
            }
        }
        // The launch/error views must not advertise a tiny window that grows
        // when the split view arrives. This remains a minimum, not a fixed size.
        .frame(minWidth: 640, minHeight: 460)
        .task(id: hasCompletedOnboarding) {
            guard hasCompletedOnboarding else { return }
            guard !SingleInstanceGuard.shared.duplicateLaunchDetected else { return }
            await appState.initialize()
            await runDownloadReadinessWarnings()
        }
    }

    private func runDownloadReadinessWarnings() async {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        let manager = DownloadServerManager.shared
        guard manager.isEnabled else { return }

        var healthData: DownloadServerManager.HealthData?
        for attempt in 0..<4 {
            healthData = await manager.fetchHealthData()
            if healthData != nil { break }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }

        if let healthData {
            if !healthData.extensionSeenEver {
                await MainActor.run {
                    NotificationService.shared.showWarning(
                        title: "Browser extension not detected",
                        body: "Web saves are optional. Install the nodraw extension in Firefox or Chrome, or disable the download server in Settings > Downloads if you do not want this feature.",
                        dedupeKey: "extension_missing"
                    )
                }
            }
            return
        }

        await MainActor.run {
            NotificationService.shared.showWarning(
                title: "Download server offline",
                body: "Open Settings > Processing to start the local download server.",
                dedupeKey: "server_offline"
            )
        }
    }
}

// MARK: - Initialization Views

/// Keep the library at one structural identity from the first scan through ready.
/// Separate switch branches used to recreate its grid, queries and split view
/// each time initialization advanced, even when no archive contents changed.
struct StartupContentView<Library: View>: View {
    let phase: InitializationPhase
    let onRetry: () -> Void
    @ViewBuilder let library: () -> Library

    var body: some View {
        switch phase {
        case .notStarted, .initializingDatabase, .runningMigrations:
            LaunchView(phase: phase)
        case .failed(let message):
            ErrorView(message: message, onRetry: onRetry)
        default:
            library()
                .overlay(alignment: .bottom) {
                    switch phase {
                    case .scanningArchive, .parsingMetadata, .preparingArchive,
                         .generatingSidecars, .insertingItems, .updatingChangedItems,
                         .reconcilingArchive, .startingWatcher:
                        ScanBanner(progress: phase.progressFraction, text: phase.displayText)
                    case .processingItems(let current, let total):
                        ProcessingBanner(current: current, total: total)
                    default:
                        EmptyView()
                    }
                }
        }
    }
}

/// Attach legacy frame restoration as soon as SwiftUI attaches the root view,
/// before the delegate orders the window front. Never restore again on updates.
private struct MainWindowFrameRestoration: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowFrameRestorationView {
        MainWindowFrameRestorationView()
    }

    func updateNSView(_ nsView: MainWindowFrameRestorationView, context: Context) {}
}

final class MainWindowFrameRestorationView: NSView {
    var autosaveName = "MainWindow"
    private weak var configuredWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, configuredWindow !== window,
              !BackgroundQAConfiguration.isEnabled else { return }
        configuredWindow = window
        window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
    }
}

/// Branded launch screen shown only for the brief pre-library phases
/// (database open + migrations). Once the schema is ready the real library
/// shell takes over and any remaining work (scan, processing) runs behind a
/// non-blocking banner instead of another full-window takeover.
struct LaunchView: View {
    let phase: InitializationPhase

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .cornerRadius(18)

            VStack(spacing: 8) {
                Text("NoDraw")
                    .font(.title2.bold())
                Text(phase.displayText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ProgressView()
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x1a1a1a))
    }
}

/// Non-blocking archive-scan indicator, shown over the live library shell.
struct ScanBanner: View {
    /// The current phase supplies both its fraction and its label.
    let progress: Double?
    var text: String = "Preparing your library…"

    var body: some View {
        HStack(spacing: 10) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
            } else {
                ProgressView()
                    .scaleEffect(0.7)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 60)
    }
}

struct ProcessingBanner: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.7)
            Text("Processing \(current)/\(total) items...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 60)
    }
}

struct ErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Failed to Initialize")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry") {
                onRetry()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x1a1a1a))
    }
}

// MARK: - Navigation Direction

enum NavigationDirection {
    case forward  // next result → start at its first asset
    case backward // previous result → start at its first asset
}

enum DisplaySurface: String, Equatable {
    case grid
    case table
    case visualClusters
    case canvas
    case rediscover
    case duplicateReview
    case unknown
}

struct DisplayContext: Equatable {
    let surface: DisplaySurface
    var itemIDs: [UUID]
    var selectedIDs: Set<UUID>
    var anchorID: UUID?
    var generation: Int
}

struct FocusSession: Equatable {
    var origin: DisplayContext
    var navigationIDs: [UUID]
    var currentID: UUID
    var returnAnchorID: UUID?

    @MainActor
    func navigationItems(in store: MediaSelectionStore) -> [MediaItem] {
        navigationIDs.compactMap(store.item(for:))
    }

    var currentIndex: Int? {
        navigationIDs.firstIndex(of: currentID)
    }

    func previousID() -> UUID? {
        guard let index = currentIndex, index > 0 else { return nil }
        return navigationIDs[index - 1]
    }

    func nextID() -> UUID? {
        guard let index = currentIndex, index < navigationIDs.count - 1 else { return nil }
        return navigationIDs[index + 1]
    }

    /// Resolve the closest item still present in the live result set. When the current
    /// item disappeared, continuing forward is less surprising than jumping back to the
    /// item that originally opened detail; the previous neighbor is the secondary choice.
    func nearestAvailableID(to referenceID: UUID, among availableIDs: Set<UUID>) -> UUID? {
        guard !availableIDs.isEmpty else { return nil }

        let orderedIDs = navigationIDs
        guard let referenceIndex = orderedIDs.firstIndex(of: referenceID) else {
            return orderedIDs.first { availableIDs.contains($0) }
        }

        if availableIDs.contains(referenceID) {
            return referenceID
        }

        for distance in 1..<orderedIDs.count {
            let nextIndex = referenceIndex + distance
            if orderedIDs.indices.contains(nextIndex), availableIDs.contains(orderedIDs[nextIndex]) {
                return orderedIDs[nextIndex]
            }

            let previousIndex = referenceIndex - distance
            if orderedIDs.indices.contains(previousIndex), availableIDs.contains(orderedIDs[previousIndex]) {
                return orderedIDs[previousIndex]
            }
        }

        return nil
    }
}

/// The committed library state restored by the shared Back command.
/// Browse presentation (grid/table and window geometry) is intentionally excluded so a
/// presentation-only change cannot reorder or discard navigation history.
struct LibraryNavigationSnapshot: Equatable {
    var sidebarSelection: SidebarSelection
    var activeSmartFolder: SmartFolder?
    var filterText: String
    var pipelineAttributeFilters: [AttributeFilter]
    var dateRangeFilter: ClosedRange<Date>?
    var colorFilters: Set<ColorBucket>
    var colorSearchRGB: ColorSearchRGB?
    var starredFilter: Bool?
    var hasOCRFilter: Bool?
    var platformFilter: String?
    var searchScope: SearchScope
    var sortOrder: SortOrder
    var shuffleSeed: UInt64?
    var selectedItemID: UUID?
    var selectedItemIDs: Set<UUID>
    var browseAnchorID: UUID?
    var gridScrollOffset: CGFloat
    var focusedItemID: UUID?
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    var selectedItemID: UUID? {
        get { mediaSelectionStore.focusedID }
        set { mediaSelectionStore.focusedID = newValue }
    }
    @Published var filterText: String = ""
    @Published var pipelineAttributeFilters: [AttributeFilter] = []
    @Published var showCommandPalette: Bool = false
    @Published var showTagInput: Bool = false
    @Published var isFilterBarFocused: Bool = false

    /// One app-level history authority shared by detail, search, filter, and destination changes.
    @Published private(set) var canNavigateBack: Bool = false
    @Published private(set) var libraryScrollRequest = LibraryScrollRequest()
    private var libraryNavigationHistory = LibraryNavigationHistory<LibraryNavigationSnapshot>()
    private var pendingSearchHistoryCommit: Task<Void, Never>?

    // Multi-selection tracking (updated by MasonryGridContainer)
    var selectedItemIDs: Set<UUID> {
        get { mediaSelectionStore.selectedIDs }
        set { mediaSelectionStore.selectedIDs = newValue }
    }
    let mediaSelectionStore = MediaSelectionStore()
    /// The fully resolved library query (search applied, CLIP IDs included) as soon as a
    /// browser has it, before rows are fetched. The result badge counts it in parallel
    /// with the fetch instead of waiting for `committedFilter`; it never re-runs CLIP.
    let resolvedLibraryQuery = PassthroughSubject<FilterState, Never>()

    // Batch tagging queue
    @Published var taggingQueue: TaggingQueueViewModel?



    // Single focus (detail) view
    var focusedItem: MediaItem? {
        get { mediaSelectionStore.focusedItem }
        set { mediaSelectionStore.focusedItem = newValue }
    }
    var focusedItemPublisher: AnyPublisher<MediaItem?, Never> { mediaSelectionStore.focusedItemPublisher }

    // Last focused item (for mouse forward button to re-open)
    var lastFocusedItem: MediaItem? {
        get { mediaSelectionStore.lastFocusedItem }
        set { mediaSelectionStore.lastFocusedItem = newValue }
    }

    // Annotation mode active in single focus view (global state for escape handling)
    @Published var isAnnotationModeActive: Bool = false

    // Whether there's a selected annotation shape (for escape key hierarchy)
    @Published var hasSelectedAnnotationShape: Bool = false

    // Whether there's a selected subject mask (for escape key hierarchy - sniper tool)
    @Published var hasSelectedSubjectMask: Bool = false

    // Issue #4: Help menu keyboard shortcuts panel
    @Published var showKeyboardShortcutsHelp: Bool = false

    // Direction of last navigation (for sub-image index selection)
    @Published var navigationDirection: NavigationDirection = .forward

    // Currently displayed items (for prev/next navigation in single focus)
    var displayedItems: [MediaItem] { mediaSelectionStore.displayedItems }

    private(set) var activeDisplayContext: DisplayContext? {
        get { mediaSelectionStore.activeDisplayContext }
        set { mediaSelectionStore.activeDisplayContext = newValue }
    }
    private(set) var focusSession: FocusSession? {
        get { mediaSelectionStore.focusSession }
        set { mediaSelectionStore.focusSession = newValue }
    }
    private var displayContextGeneration: Int = 0

    // Index cache for O(1) item lookups (UUID → array index)
    var orderedSelectedItemIDs: [UUID] { mediaSelectionStore.orderedSelectedIDs }
    func orderedItemIDs(in ids: Set<UUID>) -> [UUID] { mediaSelectionStore.orderedIDs(in: ids) }

    // Folder-grouped items cache for O(1) folder navigation
    // Key: folder name (e.g., "2025-12"), Value: array of item IDs in display order
    private var folderItemsCache: [String: [UUID]] = [:]

    // Reverse lookup: item ID → (folder name, index within folder)
    private var itemFolderIndex: [UUID: (folder: String, index: Int)] = [:]
    private(set) var folderCacheRebuildCount = 0

    /// Update displayed items and rebuild all index caches
    func setDisplayedItems(_ items: [MediaItem]) {
        objectWillChange.send()
        mediaSelectionStore.replaceItems(items)
        mediaSelectionStore.setDisplayOrder(items)

        rebuildFolderCacheIfNeeded(items)
    }

    func setDisplayContext(
        surface: DisplaySurface,
        items: [MediaItem],
        selectedIDs: Set<UUID>? = nil,
        anchorID: UUID? = nil
    ) {
        if Set(items.map(\.id)) != Set(mediaSelectionStore.items.map(\.id)) {
            mediaSelectionStore.replaceItems(items)
        } else {
            mediaSelectionStore.retain(items)
        }
        mediaSelectionStore.setDisplayOrder(items)
        rebuildFolderCacheIfNeeded(items)

        let itemIDs = items.map(\.id)
        let visibleIDs = Set(itemIDs)
        let resolvedSelectedIDs = (selectedIDs ?? selectedItemIDs).intersection(visibleIDs)
        let resolvedAnchorID = [anchorID, selectedItemID, itemIDs.first { resolvedSelectedIDs.contains($0) }]
            .compactMap { $0 }
            .first { visibleIDs.contains($0) }

        displayContextGeneration += 1
        activeDisplayContext = DisplayContext(
            surface: surface,
            itemIDs: itemIDs,
            selectedIDs: resolvedSelectedIDs,
            anchorID: resolvedAnchorID,
            generation: displayContextGeneration
        )
    }

    func updateDisplayContextSelection(
        surface: DisplaySurface? = nil,
        selectedIDs: Set<UUID>,
        anchorID: UUID? = nil
    ) {
        guard var context = activeDisplayContext else { return }
        if let surface, context.surface != surface { return }

        let visibleIDs = Set(context.itemIDs)
        let resolvedSelectedIDs = selectedIDs.intersection(visibleIDs)
        context.selectedIDs = resolvedSelectedIDs
        context.anchorID = [anchorID, selectedItemID, context.itemIDs.first { resolvedSelectedIDs.contains($0) }]
            .compactMap { $0 }
            .first { visibleIDs.contains($0) }
        activeDisplayContext = context
    }

    /// Replace a cached displayed item after an in-place database update.
    func replaceDisplayedItemIfPresent(_ updated: MediaItem) {
        replaceDisplayedItemsIfPresent([updated])
    }

    func replaceDisplayedItemsIfPresent(_ updates: [MediaItem]) {
        let records = updates.filter { displayedItem(for: $0.id) != nil }
        guard !records.isEmpty else { return }
        let folderChanged = records.contains { itemFolderIndex[$0.id]?.folder != $0.folderName }
        mediaSelectionStore.replaceRecords(records)
        if folderChanged { rebuildFolderCache(displayedItems) }
    }
    /// Replace every in-memory snapshot that may seed focus/inspector state.
    func replaceCachedItemIfPresent(_ updated: MediaItem) {
        let folderChanged = itemFolderIndex[updated.id].map { $0.folder != updated.folderName } ?? false
        mediaSelectionStore.replaceRecord(updated)
        if folderChanged { rebuildFolderCache(displayedItems) }
    }

    /// Notes update the canonical record used by browse, inspector and detail.
    func updateCachedNotes(for itemID: UUID, notes: String?) {
        guard var item = mediaSelectionStore.item(for: itemID) else { return }
        item.metadata.notes = notes
        replaceCachedItemIfPresent(item)
    }
    /// Optimistically remove items from in-memory displayed cache for instant UI feedback.
    /// Callers should still perform the real database mutation and reload/sync afterwards.
    func removeDisplayedItems(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }

        let filtered = displayedItems.filter { !ids.contains($0.id) }
        let removesDisplayedItem = filtered.count != displayedItems.count
        let removesFolderCacheItem = ids.contains { itemFolderIndex[$0] != nil }
        let removesFocusSessionItem = focusSession?.navigationIDs.contains { ids.contains($0) } == true
        let removesContextItem = activeDisplayContext?.itemIDs.contains { ids.contains($0) } == true
        guard removesDisplayedItem || removesFolderCacheItem || removesFocusSessionItem || removesContextItem else { return }

        var replacementForRemovedFocus: MediaItem?
        let removedCurrentFocus: Bool
        if let session = focusSession, ids.contains(session.currentID) {
            removedCurrentFocus = true
            let survivingIDs = Set(session.navigationIDs).subtracting(ids)
            if let replacementID = session.nearestAvailableID(to: session.currentID, among: survivingIDs) {
                replacementForRemovedFocus = mediaSelectionStore.item(for: replacementID)
            }
        } else {
            removedCurrentFocus = false
        }

        if removesDisplayedItem {
            setDisplayedItems(filtered)
        } else if removesFolderCacheItem {
            rebuildFolderCache(displayedItems)
        }

        if var context = activeDisplayContext {
            context.itemIDs.removeAll { ids.contains($0) }
            context.selectedIDs.subtract(ids)
            if let anchorID = context.anchorID, ids.contains(anchorID) {
                context.anchorID = context.itemIDs.first { context.selectedIDs.contains($0) }
            }
            activeDisplayContext = context
        }

        if var session = focusSession {
            session.navigationIDs.removeAll { ids.contains($0) }
            session.origin.itemIDs.removeAll { ids.contains($0) }
            session.origin.selectedIDs.subtract(ids)

            if let anchorID = session.origin.anchorID, ids.contains(anchorID) {
                session.origin.anchorID = session.origin.itemIDs.first { session.origin.selectedIDs.contains($0) } ?? session.origin.itemIDs.first
            }

            if ids.contains(session.currentID), let replacement = replacementForRemovedFocus {
                session.currentID = replacement.id
                session.returnAnchorID = replacement.id
            } else if let returnAnchorID = session.returnAnchorID, ids.contains(returnAnchorID) {
                session.returnAnchorID = session.currentID
            }

            focusSession = session
        }

        selectedItemIDs.subtract(ids)
        mediaSelectionStore.remove(ids)
        if let selectedID = selectedItemID, ids.contains(selectedID) {
            selectedItemID = orderedSelectedItemIDs.first
        }

        if removedCurrentFocus {
            if let replacement = replacementForRemovedFocus {
                setFocusedNavigationTarget(replacement)
            } else {
                // A deleted item must not become the mouse-forward reopen target.
                focusedItem = nil
                closeSingleFocus(consumingNavigationHistory: true)
            }
        }
    }

    private func rebuildDisplayedItemIndexes() {
        rebuildFolderCache(displayedItems)
    }

    private func rebuildFolderCacheIfNeeded(_ items: [MediaItem]) {
        if items.count == itemFolderIndex.count {
            var folderOffsets: [String: Int] = [:]
            let matches = items.allSatisfy { item in
                let offset = folderOffsets[item.folderName, default: 0]
                folderOffsets[item.folderName] = offset + 1
                guard let cached = itemFolderIndex[item.id] else { return false }
                return cached.folder == item.folderName && cached.index == offset
            }
            if matches { return }
        }
        rebuildFolderCache(items)
    }

    /// Rebuild folder caches for O(1) folder navigation
    private func rebuildFolderCache(_ items: [MediaItem]) {
        folderCacheRebuildCount += 1
        folderItemsCache.removeAll()
        itemFolderIndex.removeAll()

        // Group items by folder while preserving display order
        for item in items {
            let folder = item.folderName
            if folderItemsCache[folder] == nil {
                folderItemsCache[folder] = []
            }
            let index = folderItemsCache[folder]!.count
            folderItemsCache[folder]!.append(item.id)
            itemFolderIndex[item.id] = (folder, index)
        }
    }

    /// O(1) lookup for item index in displayedItems
    func indexOfDisplayedItem(id: UUID) -> Int? {
        mediaSelectionStore.displayPosition(of: id)
    }

    func displayedItem(for id: UUID) -> MediaItem? {
        mediaSelectionStore.displayedItem(for: id)
    }

    /// O(k log k) order-preserving lookup without scanning the loaded corpus.
    func displayedItems(for ids: Set<UUID>) -> [MediaItem] {
        orderedItemIDs(in: ids).compactMap(mediaSelectionStore.displayedItem(for:))
    }
    /// O(1) lookup for item's position within its folder
    /// Returns: (1-based index, total items in folder) or nil if not found
    func folderPositionOfItem(id: UUID) -> (index: Int, total: Int)? {
        guard let (folder, index) = itemFolderIndex[id],
              let folderItems = folderItemsCache[folder] else {
            return nil
        }
        return (index + 1, folderItems.count)
    }

    /// O(1) lookup for previous item in same folder
    func prevItemInFolder(currentId: UUID) -> MediaItem? {
        guard let (folder, index) = itemFolderIndex[currentId],
              let ids = folderItemsCache[folder], index > 0 else { return nil }
        return displayedItem(for: ids[index - 1])
    }

    func nextItemInFolder(currentId: UUID) -> MediaItem? {
        guard let (folder, index) = itemFolderIndex[currentId],
              let ids = folderItemsCache[folder], index + 1 < ids.count else { return nil }
        return displayedItem(for: ids[index + 1])
    }
    // Initialization state
    @Published private(set) var initPhase: InitializationPhase = .notStarted

    // Display-only queue and thumbnail progress has its own observation boundary.
    let backgroundStatus = BackgroundProcessingStatus()

    // Scroll position preservation
    @Published var gridScrollOffset: CGFloat = 0

    // Timeline date filter
    @Published var dateRangeFilter: ClosedRange<Date>?

    // Color filter (warm/cool/neutral bucket-based)
    @Published var colorFilters: Set<ColorBucket> = []

    // Precision color search (RGB with tolerance)
    @Published var colorSearchRGB: ColorSearchRGB? = nil

    // Starred filter: nil = all, true = starred only
    @Published var starredFilter: Bool? = nil

    // OCR filter: nil = all, true = has OCR text only
    @Published var hasOCRFilter: Bool? = nil

    // Platform filter
    @Published var platformFilter: String? = nil

    // Search scope: which fields to search (all, OCR only, notes only, author only)
    @Published var searchScope: SearchScope = SettingsStore.shared.defaultSearchScope {
        didSet { SettingsStore.shared.defaultSearchScope = searchScope }
    }

    @Published var sortOrder: SortOrder = SettingsStore.shared.lastSortOrder {
        didSet { SettingsStore.shared.lastSortOrder = sortOrder }
    }

    @Published var shuffleSeed: UInt64?

    var isShuffleActive: Bool {
        shuffleSeed != nil
    }

    func toggleShuffle() {
        commitLibraryFilterChange {
            if self.shuffleSeed == nil {
                self.shuffleSeed = UInt64.random(in: UInt64.min...UInt64.max)
            } else {
                self.shuffleSeed = nil
            }
        }
    }

    func reshuffle() {
        commitLibraryFilterChange {
            self.shuffleSeed = UInt64.random(in: UInt64.min...UInt64.max)
        }
    }

    // Grid density: 0.0 = compact (more tiles), 1.0 = spacious (larger tiles)
    // Persisted via UserDefaults
    @Published var gridDensity: CGFloat = UserDefaults.standard.object(forKey: "gridDensity") as? CGFloat ?? 0.5 {
        didSet { UserDefaults.standard.set(gridDensity, forKey: "gridDensity") }
    }

    // Browse mode: grid (masonry) or table (database browser)
    // Persisted via UserDefaults
    enum BrowseMode: String, CaseIterable {
        case grid, table
    }
    @Published var browseMode: BrowseMode = AppState.restoredBrowseMode(
        UserDefaults.standard.string(forKey: "browseMode")
    ) {
        didSet { UserDefaults.standard.set(browseMode.rawValue, forKey: "browseMode") }
    }

    /// The table has no UI entry point while `FeatureFlags.tableBrowser` is off, so a
    /// persisted table choice reopens in the grid instead of stranding the user there.
    nonisolated static func restoredBrowseMode(_ rawValue: String?) -> BrowseMode {
        guard FeatureFlags.tableBrowser else { return .grid }
        return rawValue.flatMap(BrowseMode.init(rawValue:)) ?? .grid
    }

    // Layout mode: false = columns (default), true = hybrid (columns + rows by aspect ratio)
    // Persisted via UserDefaults
    @Published var useHybridLayout: Bool = UserDefaults.standard.bool(forKey: "useHybridLayout") {
        didSet { UserDefaults.standard.set(useHybridLayout, forKey: "useHybridLayout") }
    }

    // Show color bars on thumbnails: displays dominant colors at bottom of each cell
    // Persisted via UserDefaults
    @Published var showColorBars: Bool = UserDefaults.standard.bool(forKey: "showColorBars") {
        didSet { UserDefaults.standard.set(showColorBars, forKey: "showColorBars") }
    }

    // Show inspector panel (Cmd+I toggle)
    // Persisted via UserDefaults - default false
    @Published var showInspectorPanel: Bool = UserDefaults.standard.bool(forKey: "showInspectorPanel") {
        didSet { UserDefaults.standard.set(showInspectorPanel, forKey: "showInspectorPanel") }
    }

    // showFocusSidebar moved to SettingsStore

    // Show metadata panel in focus view (right sidebar)
    // Persisted via UserDefaults - default true
    @Published var showFocusMetadataPanel: Bool = {
        if UserDefaults.standard.object(forKey: "showFocusMetadataPanel") == nil {
            return true // default to true
        }
        return UserDefaults.standard.bool(forKey: "showFocusMetadataPanel")
    }() {
        didSet { UserDefaults.standard.set(showFocusMetadataPanel, forKey: "showFocusMetadataPanel") }
    }

    // Duplicate review view visibility
    @Published var showDuplicateReview: Bool = false

    // Pending duplicate count for sidebar badge
    @Published var pendingDuplicateCount: Int = 0

    // Issue #1: Rediscover session state (separate from sidebar selection)
    // When .rediscover is selected in sidebar, we show preview grid
    // When this is true, we show the full-screen review session
    @Published var showRediscoverSession: Bool = false

    // Sidebar selection state
    @Published var sidebarSelection: SidebarSelection = .allMedia

    // Active smart folder (when selected)
    @Published var activeSmartFolder: SmartFolder?

    // Services
    private var coordinator: AppCoordinator?
    @Published private(set) var mediaStore: MediaStore?

    /// Shared instance for shutdown flush (accessed from AppDelegate)
    private static weak var _shared: AppState?
    private(set) var boardStore: BoardStore?
    private(set) var duplicateDetector: DuplicateDetector?
    private(set) var duplicateReviewService: DuplicateReviewService?

    // FSRS Review Scheduler
    let reviewScheduler = ReviewScheduler()

    // Undo system
    let undoStack = UndoStack()

    // Subscriptions
    private var cancellables = Set<AnyCancellable>()
    private var browsingCancellable: AnyCancellable?
    @Published var mediaExportRequest: MediaExportRequest?
    @Published var showRetainedFileData = false
    private var focusedRefreshCancellable: AnyCancellable?
    private var focusedRefreshGeneration = 0
    private let focusedItemLoader: (@MainActor (UUID) async throws -> MediaItem?)?

    init(mediaStore: MediaStore? = nil, focusedItemLoader: (@MainActor (UUID) async throws -> MediaItem?)? = nil) {
        self.mediaStore = mediaStore
        self.focusedItemLoader = focusedItemLoader
        browsingCancellable = mediaSelectionStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        focusedRefreshCancellable = NotificationCenter.default.publisher(for: .mediaStoreDidChange)
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] notification in
                guard let self, let id = self.focusedItem?.id else { return }
                if let changedID = notification.userInfo?["itemId"] as? UUID, changedID != id { return }
                self.hydrateFocusedItem(id)
            }
    }

    /// Whether we're showing the detail view
    /// Pages browsable in detail: media files plus the context screenshot page.
    var focusedPageCount: Int {
        guard let item = focusedItem else { return 0 }
        return item.mediaFiles.count + (item.hasSwappablePresentationSources ? 1 : 0)
    }

    var isShowingSingleFocus: Bool {
        focusedItem != nil
    }

    // MARK: - Initialization

    /// Flush pending write-back queue (called from AppDelegate on termination)
    static func flushWriteBackQueue() async {
        guard let shared = _shared,
              let store = shared.mediaStore else { return }
        await store.writeBackQueue.flushNow()
    }

    func initialize() async {
        guard initPhase == .notStarted else { return }
        Self._shared = self

        // --test-vault flag: use fixture data instead of real archive
        let testVaultPath: URL? = {
            if CommandLine.arguments.contains("--test-vault") {
                // Resolve from executable location → Sources/../Tests/Fixtures/test-vault
                // Try relative to working directory first
                let cwdPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("Tests/Fixtures/test-vault")
                if FileManager.default.fileExists(atPath: cwdPath.path) {
                    logInfo("Using test vault at: \(cwdPath.path)")
                    return cwdPath
                }
                // Fallback: explicit repo root supplied by the environment
                if let root = ProcessInfo.processInfo.environment["NODRAW_TEST_VAULT_ROOT"] {
                    let repoPath = URL(fileURLWithPath: root)
                        .appendingPathComponent("Tests/Fixtures/test-vault")
                    if FileManager.default.fileExists(atPath: repoPath.path) {
                        logInfo("Using test vault at: \(repoPath.path)")
                        return repoPath
                    }
                }
                logWarning("--test-vault flag set but fixture path not found, using default")
                return nil
            }
            return nil
        }()

        // Use isolated DB for test vault so real data is untouched
        if let testPath = testVaultPath {
            let testDB = testPath.appendingPathComponent(".media-test.sqlite")
            DatabaseManager.shared = DatabaseManager(databaseURL: testDB)
            logInfo("Using isolated test DB at: \(testDB.path)")
        }

        let coordinator = AppCoordinator(archivePath: testVaultPath)
        self.coordinator = coordinator

        // Observe initialization phase
        coordinator.phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                CrashTelemetry.leave("init-phase: \(phase)")
                self?.initPhase = phase
            }
            .store(in: &cancellables)

        // Wire up data services up front. These objects exist as soon as the
        // coordinator is constructed, so the library shell can render (behind a
        // scan banner) while initialization runs, instead of a full-screen
        // spinner wall. DB queries against them stay empty until migrations land.
        self.mediaStore = await coordinator.getMediaStore()
        self.boardStore = BoardStore(database: DatabaseManager.shared)
        self.duplicateDetector = DuplicateDetector(db: DatabaseManager.shared)
        if let mediaStore = self.mediaStore {
            self.duplicateReviewService = DuplicateReviewService(database: DatabaseManager.shared, mediaStore: mediaStore)
        }

        // Start initialization
        await coordinator.initialize()

        // Isolated preview/QA only: normal launches never scan or open triage implicitly.
        if BackgroundQAConfiguration.isEnabled, CommandLine.arguments.contains("--duplicate-review") {
            if CommandLine.arguments.contains("--scan-duplicates"), let detector = duplicateDetector {
                do { _ = try await detector.detectDuplicates() }
                catch { logError("Isolated duplicate scan failed: \(error)") }
            }
            showDuplicateReview = true
        }
        // Load pending duplicate count
        await refreshDuplicateCount()

        // Observe vision queue status
        let visionQueue = await coordinator.getVisionQueue()
        visionQueue.status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                self.updateQueueStatus(.vision, processing: status.processing, queued: status.queued)
            }
            .store(in: &cancellables)

        // Observe ML pipeline queue status (embeddings/object/scene/etc.)
        let pipelineQueue = await coordinator.getPipelineQueue()
        pipelineQueue.status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                self.updateQueueStatus(.pipeline, processing: status.processing, queued: status.queued)
            }
            .store(in: &cancellables)

        // Observe native video understanding queue status.
        let videoUnderstandingQueue = await coordinator.getVideoUnderstandingQueue()
        videoUnderstandingQueue.status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                self.updateQueueStatus(.videoUnderstanding, processing: status.processing, queued: status.queued)
            }
            .store(in: &cancellables)

        // Observe local Parakeet transcription queue status.
        let transcriptionQueue = await coordinator.getTranscriptionQueue()
        transcriptionQueue.status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                self.updateQueueStatus(.transcription, processing: status.processing, queued: status.queued)
            }
            .store(in: &cancellables)

        // GAP #7 fix: Observe duplicate group changes to refresh sidebar badge
        NotificationCenter.default.publisher(for: .duplicateGroupsDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task { await self.refreshDuplicateCount() }
            }
            .store(in: &cancellables)

        // Maintenance work should not block the first usable library view.
        guard !BackgroundQAConfiguration.isEnabled else { return }
        Task { [visionQueue, reviewScheduler] in
            await visionQueue.syncColorsToJunctionTable()
            try? await reviewScheduler.recalculateOverdueReviews()
        }
    }

    func retryInitialization() async {
        initPhase = .notStarted
        coordinator = nil
        mediaStore = nil
        duplicateDetector = nil
        duplicateReviewService = nil
        cancellables.removeAll()
        await initialize()
    }

    enum BackgroundQueue: CaseIterable {
        case vision, pipeline, videoUnderstanding, transcription
    }

    func updateQueueStatus(_ queue: BackgroundQueue, processing: Int, queued: Int) {
        backgroundStatus.updateQueueStatus(queue, processing: processing, queued: queued)
    }

    /// Update archive path across all subsystems (import/watcher/server settings).
    func updateArchivePath(_ path: URL) async {
        guard !BackgroundQAConfiguration.isEnabled else {
            logWarning("Isolated preview archive cannot be changed")
            return
        }
        let normalizedPath = path.standardizedFileURL
        ArchivePathStore.setCurrentPath(normalizedPath)

        guard let coordinator else { return }

        do {
            try await coordinator.setArchivePath(normalizedPath)
        } catch {
            logError("Failed to update archive path: \(error.localizedDescription)")
        }
    }

    // MARK: - Actions

    func focusFilterBar() {
        isFilterBarFocused = true
    }

    // MARK: - Shared Library Navigation

    /// Update live search text while coalescing the edit session into one Back entry.
    func updateSearchText(_ text: String) {
        guard filterText != text else { return }
        finishFocusBeforeLibraryTransition()
        let previousState = makeLibraryNavigationSnapshot()
        filterText = text
        let currentState = makeLibraryNavigationSnapshot()
        libraryNavigationHistory.stageCoalescedTransition(
            from: previousState,
            to: currentState,
            kind: .search
        )
        refreshCanNavigateBack()

        pendingSearchHistoryCommit?.cancel()
        pendingSearchHistoryCommit = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            self?.commitPendingSearchTransition()
        }
    }

    /// Commit a search affordance immediately (clear, token insertion, or scope change).
    func commitSearchText(_ text: String) {
        pendingSearchHistoryCommit?.cancel()
        pendingSearchHistoryCommit = nil
        finishFocusBeforeLibraryTransition()

        let previousState = makeLibraryNavigationSnapshot()
        filterText = text
        let currentState = makeLibraryNavigationSnapshot()
        libraryNavigationHistory.stageCoalescedTransition(
            from: previousState,
            to: currentState,
            kind: .search
        )
        let committed = libraryNavigationHistory.commitCoalescedTransition()
        refreshCanNavigateBack()
        if committed {
            issueLibraryScrollRequest(.top)
        }
    }

    /// Commit a filter/order mutation as one visible result-set transition.
    func commitLibraryFilterChange(_ mutation: () -> Void) {
        performCommittedLibraryTransition(kind: .filter, mutation: mutation)
    }

    /// Change sidebar destination through the same history authority as every other Back step.
    /// `clearingQuery` also clears every narrowing filter inside the same Back step.
    func commitLibraryDestinationChange(
        _ selection: SidebarSelection,
        smartFolder: SmartFolder? = nil,
        selecting itemID: UUID? = nil,
        clearingQuery: Bool = false
    ) {
        performCommittedLibraryTransition(kind: .destination) {
            if clearingQuery { self.clearLibrarySearchAndFilterState() }
            self.sidebarSelection = selection
            self.activeSmartFolder = smartFolder
            self.filterText = ""
            self.selectedItemID = itemID
            self.selectedItemIDs = itemID.map { Set([$0]) } ?? []
            self.mediaSelectionStore.select(itemID)
            self.showDuplicateReview = selection == .duplicates
        }
    }

    /// The single Back entrypoint used by menu, keyboard, toolbar, and mouse inputs.
    @discardableResult
    func navigateBack() -> Bool {
        pendingSearchHistoryCommit?.cancel()
        pendingSearchHistoryCommit = nil

        guard let entry = libraryNavigationHistory.navigateBack() else {
            refreshCanNavigateBack()
            return false
        }

        if entry.transition == .detail, isShowingSingleFocus {
            closeSingleFocus(consumingNavigationHistory: false)
        } else {
            if isShowingSingleFocus {
                closeSingleFocus(consumingNavigationHistory: false)
            }
            restoreLibraryNavigationSnapshot(entry.state)
        }

        refreshCanNavigateBack()
        return true
    }

    private func performCommittedLibraryTransition(
        kind: LibraryNavigationTransitionKind,
        mutation: () -> Void
    ) {
        pendingSearchHistoryCommit?.cancel()
        pendingSearchHistoryCommit = nil
        finishFocusBeforeLibraryTransition()
        let committedPendingSearch = libraryNavigationHistory.commitCoalescedTransition()
        let previousState = makeLibraryNavigationSnapshot()
        mutation()
        let currentState = makeLibraryNavigationSnapshot()
        let recorded = libraryNavigationHistory.recordTransition(
            from: previousState,
            to: currentState,
            kind: kind
        )
        refreshCanNavigateBack()
        if committedPendingSearch || recorded {
            issueLibraryScrollRequest(.top)
        }
    }

    private func commitPendingSearchTransition() {
        pendingSearchHistoryCommit = nil
        let committed = libraryNavigationHistory.commitCoalescedTransition()
        refreshCanNavigateBack()
        if committed {
            issueLibraryScrollRequest(.top)
        }
    }

    private func makeLibraryNavigationSnapshot() -> LibraryNavigationSnapshot {
        LibraryNavigationSnapshot(
            sidebarSelection: sidebarSelection,
            activeSmartFolder: activeSmartFolder,
            filterText: filterText,
            pipelineAttributeFilters: pipelineAttributeFilters,
            dateRangeFilter: dateRangeFilter,
            colorFilters: colorFilters,
            colorSearchRGB: colorSearchRGB,
            starredFilter: starredFilter,
            hasOCRFilter: hasOCRFilter,
            platformFilter: platformFilter,
            searchScope: searchScope,
            sortOrder: sortOrder,
            shuffleSeed: shuffleSeed,
            selectedItemID: selectedItemID,
            selectedItemIDs: selectedItemIDs,
            browseAnchorID: activeDisplayContext?.anchorID ?? selectedItemID,
            gridScrollOffset: gridScrollOffset,
            focusedItemID: focusedItem?.id
        )
    }

    private func restoreLibraryNavigationSnapshot(_ snapshot: LibraryNavigationSnapshot) {
        sidebarSelection = snapshot.sidebarSelection
        activeSmartFolder = snapshot.activeSmartFolder
        filterText = snapshot.filterText
        pipelineAttributeFilters = snapshot.pipelineAttributeFilters
        dateRangeFilter = snapshot.dateRangeFilter
        colorFilters = snapshot.colorFilters
        colorSearchRGB = snapshot.colorSearchRGB
        starredFilter = snapshot.starredFilter
        hasOCRFilter = snapshot.hasOCRFilter
        platformFilter = snapshot.platformFilter
        searchScope = snapshot.searchScope
        sortOrder = snapshot.sortOrder
        shuffleSeed = snapshot.shuffleSeed
        gridScrollOffset = snapshot.gridScrollOffset
        selectedItemID = snapshot.selectedItemID
        selectedItemIDs = snapshot.selectedItemIDs
        mediaSelectionStore.selectedIDs = snapshot.selectedItemIDs
        mediaSelectionStore.focusedID = snapshot.selectedItemID
        showDuplicateReview = snapshot.sidebarSelection == .duplicates

        issueLibraryScrollRequest(snapshot.browseAnchorID.map(LibraryScrollTarget.item) ?? .top)
    }

    private func issueLibraryScrollRequest(_ target: LibraryScrollTarget) {
        var request = libraryScrollRequest
        request.issue(target)
        libraryScrollRequest = request
    }

    private func refreshCanNavigateBack() {
        let value = libraryNavigationHistory.canNavigateBack
        guard canNavigateBack != value else { return }
        canNavigateBack = value
    }

    /// Result-set changes start from browse state, never from a half-dismissed detail state.
    /// This consumes the one detail entry first, so a sidebar/workspace/filter transition
    /// contributes exactly one Back step and restores the item current at detail exit.
    private func finishFocusBeforeLibraryTransition() {
        guard isShowingSingleFocus else { return }
        closeSingleFocus(consumingNavigationHistory: true)
    }

    private func hydrateFocusedItem(_ id: UUID) {
        let fetch: @MainActor (UUID) async throws -> MediaItem?
        if let focusedItemLoader { fetch = focusedItemLoader }
        else if let store = mediaStore { fetch = { try await store.fetchItem(id: $0) } }
        else { return }
        Task { [weak self] in await self?.refreshFocusedRecord(fetch: fetch) }
    }

    func refreshFocusedRecord(fetch: @MainActor (UUID) async throws -> MediaItem?) async {
        guard let id = focusedItem?.id else { return }
        focusedRefreshGeneration += 1
        let request = focusedRefreshGeneration
        let generation = mediaSelectionStore.focusGeneration
        do {
            guard let item = try await fetch(id), request == focusedRefreshGeneration,
                  generation == mediaSelectionStore.focusGeneration, focusedItem?.id == id else { return }
            replaceCachedItemIfPresent(item)
        } catch {
            logDebug("Failed to hydrate focused item \(id): \(error.localizedDescription)")
        }
    }

    func openSingleFocus(_ item: MediaItem, navigationItems explicitNavigationItems: [MediaItem]? = nil) {
        // Calls from folder controls, tagging queues, and delete continuation can target a
        // different item while detail is already open. That is navigation within the existing
        // focus session, not another detail entry in browse history.
        if var session = focusSession, focusedItem != nil {
            let candidates = focusNavigationItems(containing: item, explicitItems: explicitNavigationItems)
            mediaSelectionStore.retain(candidates)
            if explicitNavigationItems != nil || !session.navigationIDs.contains(item.id) {
                session.navigationIDs = candidates.map(\.id)
            }
            if !session.navigationIDs.contains(item.id) {
                session.navigationIDs.append(item.id)
            }
            session.currentID = item.id
            session.returnAnchorID = item.id
            focusSession = session
            setFocusedNavigationTarget(item)
            return
        }

        pendingSearchHistoryCommit?.cancel()
        pendingSearchHistoryCommit = nil
        _ = libraryNavigationHistory.commitCoalescedTransition()
        let previousNavigationState = makeLibraryNavigationSnapshot()

        CrashTelemetry.leave("open-focus id=\(item.id) files=\(item.mediaFiles.count)")
        CrashTelemetry.flushBreadcrumbs()
        let navigationItems = focusNavigationItems(containing: item, explicitItems: explicitNavigationItems)
        mediaSelectionStore.retain(navigationItems)
        let origin = focusOriginContext(containing: item, navigationItems: navigationItems)
        focusSession = FocusSession(
            origin: origin,
            navigationIDs: navigationItems.map(\.id),
            currentID: item.id,
            returnAnchorID: item.id
        )
        focusedItem = item
        selectedItemID = item.id
        selectedItemIDs = [item.id]
        mediaSelectionStore.select(item.id)
        updateDisplayContextSelection(selectedIDs: [item.id], anchorID: item.id)
        focusedItemOpenedAt = Date()
        hydrateFocusedItem(item.id)

        // Track view event for FSRS
        Task {
            try? await reviewScheduler.recordViewEvent(itemId: item.id)
        }

        libraryNavigationHistory.recordTransition(
            from: previousNavigationState,
            to: makeLibraryNavigationSnapshot(),
            kind: .detail
        )
        refreshCanNavigateBack()
    }

    private func focusNavigationItems(containing item: MediaItem, explicitItems: [MediaItem]?) -> [MediaItem] {
        let candidates: [MediaItem]
        if let explicitItems {
            candidates = explicitItems
        } else if let context = activeDisplayContext, context.itemIDs.contains(item.id) {
            let byID = Dictionary(displayedItems.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            candidates = context.itemIDs.compactMap { id in
                if id == item.id {
                    return byID[id] ?? item
                }
                return byID[id]
            }
        } else if activeDisplayContext == nil && displayedItems.contains(where: { $0.id == item.id }) {
            candidates = displayedItems
        } else {
            candidates = [item]
        }

        guard !candidates.isEmpty else { return [item] }
        return candidates.contains(where: { $0.id == item.id }) ? candidates : [item] + candidates
    }

    private func focusOriginContext(containing item: MediaItem, navigationItems: [MediaItem]) -> DisplayContext {
        if let context = activeDisplayContext, context.itemIDs.contains(item.id) {
            return context
        }

        return DisplayContext(
            surface: .unknown,
            itemIDs: navigationItems.map(\.id),
            selectedIDs: [item.id],
            anchorID: item.id,
            generation: displayContextGeneration
        )
    }

    func closeSingleFocus() {
        closeSingleFocus(consumingNavigationHistory: true)
    }

    /// The sole focus-exit transaction. Escape, the visible Back button, command-palette
    /// dismissal, history Back, mouse Back, and pre-destination closure all converge here.
    private func closeSingleFocus(consumingNavigationHistory: Bool) {
        CrashTelemetry.leave("close-focus id=\(focusedItem?.id.uuidString ?? "nil")")

        if consumingNavigationHistory, focusSession != nil {
            _ = libraryNavigationHistory.discardLatestTransition(ifKind: .detail)
        }

        // Record view duration for interest scoring
        if let item = focusedItem, let openedAt = focusedItemOpenedAt {
            let duration = Date().timeIntervalSince(openedAt)
            Task {
                try? await reviewScheduler.recordViewEvent(itemId: item.id, duration: duration)
            }
        }

        // Save for mouse forward button to re-open
        lastFocusedItem = focusedItem

        if let session = focusSession {
            restoreFocusReturnState(from: session, closingItem: focusedItem)
        }

        focusedItem = nil
        focusSession = nil
        focusedItemOpenedAt = nil
        isAnnotationModeActive = false  // Reset annotation mode when closing focus
        hasSelectedAnnotationShape = false  // Reset annotation selection state
        taggingQueue?.exitTagging()  // Exit tagging mode when closing focus
        taggingQueue = nil
        refreshCanNavigateBack()
    }

    /// Re-open the last focused item (for mouse forward button)
    func reopenLastFocusedItem() {
        guard let item = lastFocusedItem else { return }
        openSingleFocus(item)
    }

    /// Track when single focus view was opened (for duration calculation)
    private var focusedItemOpenedAt: Date?

    /// Whether detail navigation has a previous item in the captured result order.
    /// This mirrors `navigateToPrevItem()` without mutating selection or focus.
    var canNavigateToPreviousResult: Bool {
        guard isShowingSingleFocus, let current = focusedItem else { return false }
        if let focusSession {
            return focusSession.previousID() != nil
        }
        return (indexOfDisplayedItem(id: current.id) ?? 0) > 0
    }

    /// Whether detail navigation has a next item in the captured result order.
    /// This mirrors `navigateToNextItem()` without mutating selection or focus.
    var canNavigateToNextResult: Bool {
        guard isShowingSingleFocus, let current = focusedItem else { return false }
        if let focusSession {
            return focusSession.nextID() != nil
        }
        guard let index = indexOfDisplayedItem(id: current.id) else { return false }
        return index < displayedItems.count - 1
    }

    /// Navigate to previous item in single focus view
    func navigateToPrevItem() {
        if let id = focusSession?.previousID(), let target = mediaSelectionStore.item(for: id) {
            navigationDirection = .backward
            setFocusedNavigationTarget(target)
            return
        }

        guard let current = focusedItem,
              let index = indexOfDisplayedItem(id: current.id),
              index > 0 else { return }
        navigationDirection = .backward
        let target = displayedItems[index - 1]
        setFocusedNavigationTarget(target)
    }

    /// Navigate to next item in single focus view
    func navigateToNextItem() {
        if let id = focusSession?.nextID(), let target = mediaSelectionStore.item(for: id) {
            navigationDirection = .forward
            setFocusedNavigationTarget(target)
            return
        }

        guard let current = focusedItem,
              let index = indexOfDisplayedItem(id: current.id),
              index < displayedItems.count - 1 else { return }
        navigationDirection = .forward
        let target = displayedItems[index + 1]
        setFocusedNavigationTarget(target)
    }

    private func setFocusedNavigationTarget(_ target: MediaItem) {
        if var session = focusSession {
            session.currentID = target.id
            session.returnAnchorID = target.id
            focusSession = session
        }

        focusedItem = target
        taggingQueue?.synchronizeFocusedItem(target)
        selectedItemID = target.id
        selectedItemIDs = [target.id]
        mediaSelectionStore.select(target.id)
        updateDisplayContextSelection(selectedIDs: [target.id], anchorID: target.id)
        hydrateFocusedItem(target.id)
    }

    private func restoreFocusReturnState(from session: FocusSession, closingItem: MediaItem?) {
        guard let anchorID = focusReturnFallbackID(in: session, closingItemID: closingItem?.id) else {
            selectedItemID = nil
            selectedItemIDs = []
            mediaSelectionStore.clear()
            if var context = activeDisplayContext, context.surface == session.origin.surface {
                context.selectedIDs = []
                context.anchorID = nil
                activeDisplayContext = context
            }
            issueLibraryScrollRequest(.top)
            return
        }

        selectedItemID = anchorID
        selectedItemIDs = [anchorID]
        mediaSelectionStore.select(anchorID)

        if var context = activeDisplayContext,
           context.surface == session.origin.surface,
           context.itemIDs.contains(anchorID) {
            context.selectedIDs = [anchorID]
            context.anchorID = anchorID
            activeDisplayContext = context
            issueLibraryScrollRequest(.item(anchorID))
            return
        }

        guard session.origin.itemIDs.contains(anchorID) else { return }

        var origin = session.origin
        origin.selectedIDs = [anchorID]
        origin.anchorID = anchorID

        let restoredItems = origin.itemIDs.compactMap { id -> MediaItem? in
            if let item = mediaSelectionStore.item(for: id) {
                return item
            }
            if let item = displayedItem(for: id) {
                return item
            }
            if closingItem?.id == id {
                return closingItem
            }
            return nil
        }

        if !restoredItems.isEmpty {
            setDisplayedItems(restoredItems)
        }
        activeDisplayContext = origin
        issueLibraryScrollRequest(.item(anchorID))
    }

    private func focusReturnFallbackID(in session: FocusSession, closingItemID: UUID?) -> UUID? {
        let availableIDs: Set<UUID>
        if let context = activeDisplayContext, context.surface == session.origin.surface {
            availableIDs = Set(context.itemIDs)
        } else {
            availableIDs = Set(session.origin.itemIDs)
        }

        guard !availableIDs.isEmpty else { return nil }

        let referenceID = closingItemID ?? session.currentID
        if let nearbyID = session.nearestAvailableID(to: referenceID, among: availableIDs) {
            return nearbyID
        }

        let candidates: [UUID?] = [
            session.currentID,
            session.returnAnchorID,
            session.origin.anchorID,
            session.origin.itemIDs.first { session.origin.selectedIDs.contains($0) },
            session.origin.itemIDs.first
        ]

        return candidates
            .compactMap { $0 }
            .first { availableIDs.contains($0) }
    }

    func toggleStarOnSelected() {
        guard let store = mediaStore,
              let itemID = selectedItemID ?? focusedItem?.id else { return }

        let previousSnapshot = displayedItem(for: itemID) ?? (focusedItem?.id == itemID ? focusedItem : nil)
        if var optimistic = previousSnapshot {
            optimistic.metadata.starred.toggle()
            replaceCachedItemIfPresent(optimistic)
        }

        Task {
            do {
                let wasStarred = try await store.isStarred(id: itemID)
                let action = ToggleStarAction(
                    itemId: itemID,
                    wasStarred: wasStarred,
                    mediaStore: store
                )
                try await undoStack.performAction(action)

                if var updated = displayedItem(for: itemID) ?? (focusedItem?.id == itemID ? focusedItem : nil) ?? previousSnapshot {
                    updated.metadata.starred = !wasStarred
                    replaceCachedItemIfPresent(updated)
                }

                // Update FSRS interest score
                try? await reviewScheduler.updateInterestScore(itemId: itemID)
            } catch {
                if let previousSnapshot {
                    replaceCachedItemIfPresent(previousSnapshot)
                }
                logError("Failed to toggle star: \(error.localizedDescription)")
            }
        }
    }

    func addTag(_ tag: String) {
        guard let itemID = selectedItemID,
              let store = mediaStore else { return }

        Task {
            do {
                let action = AddTagAction(
                    itemId: itemID,
                    tag: tag,
                    mediaStore: store
                )
                try await undoStack.performAction(action)

                // Update FSRS interest score
                try? await reviewScheduler.updateInterestScore(itemId: itemID)
            } catch {
                logError("Failed to add tag: \(error.localizedDescription)")
            }
        }
    }

    func removeTag(_ tag: String, from itemID: UUID) {
        guard let store = mediaStore else { return }

        Task {
            do {
                let action = RemoveTagAction(
                    itemId: itemID,
                    tag: tag,
                    mediaStore: store
                )
                try await undoStack.performAction(action)
            } catch {
                logError("Failed to remove tag: \(error.localizedDescription)")
            }
        }
    }

    func updateNotes(for itemID: UUID, oldNotes: String?, newNotes: String?) {
        guard let store = mediaStore else { return }
        updateCachedNotes(for: itemID, notes: newNotes)

        Task {
            do {
                let action = UpdateNotesAction(
                    itemId: itemID,
                    oldNotes: oldNotes,
                    newNotes: newNotes,
                    mediaStore: store
                )
                try await undoStack.performAction(action)

                // Update FSRS interest score
                try? await reviewScheduler.updateInterestScore(itemId: itemID)
            } catch {
                await MainActor.run {
                    updateCachedNotes(for: itemID, notes: oldNotes)
                }
                logError("Failed to update notes: \(error.localizedDescription)")
            }
        }
    }

    func starItem(_ itemID: UUID, starred: Bool) {
        guard let store = mediaStore else { return }

        Task {
            do {
                let wasStarred = try await store.isStarred(id: itemID)
                guard wasStarred != starred else { return }

                let action = ToggleStarAction(
                    itemId: itemID,
                    wasStarred: wasStarred,
                    mediaStore: store
                )
                try await undoStack.performAction(action)
            } catch {
                logError("Failed to star item: \(error.localizedDescription)")
            }
        }
    }

    func deleteItems(_ itemIDs: [UUID], deleteFromDisk: Bool? = nil) {
        guard let store = mediaStore else { return }
        let uniqueIDs = Set(itemIDs)
        guard !uniqueIDs.isEmpty else { return }

        // Optimistic local update so library UI reflects deletes immediately.
        let previousDisplayedItems = displayedItems
        let previousSelectedItemIDs = selectedItemIDs
        let previousSelectedItemID = selectedItemID
        let previousDisplayContext = activeDisplayContext
        let previousFocusSession = focusSession
        let previousFocusedItem = focusedItem
        let previousNavigationHistory = libraryNavigationHistory
        removeDisplayedItems(ids: uniqueIDs)

        var userInfo: [AnyHashable: Any] = ["deletedItemIds": Array(uniqueIDs)]
        if uniqueIDs.count == 1, let itemId = uniqueIDs.first {
            userInfo["itemId"] = itemId
        }
        NotificationCenter.default.post(name: .mediaStoreDidChange, object: nil, userInfo: userInfo)

        Task {
            do {
                let action = DeleteItemsAction(
                    itemIds: Array(uniqueIDs),
                    mediaStore: store,
                    deleteService: DeleteService(mediaStore: store, deleteFromDisk: deleteFromDisk)
                )
                try await undoStack.performAction(action)
            } catch let partial as DeleteService.PartialDeletionError {
                // DB soft-delete committed; only the optional filesystem stage
                // failed. Retain Recently Deleted/undo state, never resurrect rows.
                MediaTransferFeedback.shared.reportFileFailures(
                    [partial.localizedDescription], urls: partial.result.failedFileURLs,
                    retryTargets: partial.result.retryTargets,
                    service: DeleteService(mediaStore: store, deleteFromDisk: deleteFromDisk), excludingItemIDs: Array(uniqueIDs))
            } catch {
                // Roll back optimistic cache state if delete fails.
                setDisplayedItems(previousDisplayedItems)
                activeDisplayContext = previousDisplayContext
                focusSession = previousFocusSession
                focusedItem = previousFocusedItem
                libraryNavigationHistory = previousNavigationHistory
                refreshCanNavigateBack()
                selectedItemIDs = previousSelectedItemIDs
                selectedItemID = previousSelectedItemID
                mediaSelectionStore.selectedIDs = previousSelectedItemIDs
                mediaSelectionStore.focusedID = previousSelectedItemID
                logError("Failed to delete items: \(error.localizedDescription)")
                MediaTransferFeedback.shared.report(error)
            }
        }
    }

    func performUndo() {
        if isAnnotationModeActive { ImageEditorMenuAction.undo.send(); return }
        Task {
            do {
                try await undoStack.undo()
            } catch {
                logError("Failed to undo: \(error.localizedDescription)")
            }
        }
    }

    func performRedo() {
        if isAnnotationModeActive { ImageEditorMenuAction.redo.send(); return }
        Task {
            do {
                try await undoStack.redo()
            } catch {
                logError("Failed to redo: \(error.localizedDescription)")
            }
        }
    }

    /// Rebuild search index by re-queueing all unprocessed items for Vision processing
    func rebuildSearchIndex() {
        logInfo("rebuildSearchIndex() called")
        guard let coordinator = coordinator else {
            logInfo("rebuildSearchIndex: coordinator is nil!")
            return
        }

        Task {
            logInfo("rebuildSearchIndex: Starting requeue...")
            let visionQueue = await coordinator.getVisionQueue()
            await visionQueue.requeueIncomplete()
            logInfo("rebuildSearchIndex: Requeue complete")
        }
    }

    /// Reprocess OCR for a specific item to regenerate bounding boxes.
    /// Use this for items that have OCR text but no bounding boxes (processed before that feature existed).
    func reprocessOCR(for itemID: UUID) {
        guard let coordinator = coordinator else { return }

        Task {
            let visionQueue = await coordinator.getVisionQueue()
            await visionQueue.reprocessOCR(itemId: itemID)
        }
    }

    /// Bulk reprocess OCR for all items with the updated quality filter.
    func reprocessAllOCR() {
        guard let coordinator = coordinator else { return }

        Task {
            let visionQueue = await coordinator.getVisionQueue()
            let count = await visionQueue.reprocessAllOCR()
            Log.info("Bulk OCR reprocess started: \(count) items queued")
        }
    }

    /// Bulk reprocess all items through the full ML pipeline from scratch.
    func reprocessAllPipeline() {
        Task {
            guard let pipelineQueue = PipelineQueue.sharedIfConfigured else {
                logWarning("reprocessAllPipeline requested before PipelineQueue initialization")
                return
            }
            let count = await pipelineQueue.reprocessAll()
            Log.info("Bulk pipeline reprocess started: \(count) items queued")
        }
    }

    /// Re-index colors for all items using the expanded 12-color bucket system.
    /// Use this after updating the color classification system.
    func reindexAllColors() {
        logInfo("reindexAllColors() called")
        guard let coordinator = coordinator else {
            logInfo("reindexAllColors: coordinator is nil!")
            return
        }

        Task {
            logInfo("reindexAllColors: Starting...")
            let visionQueue = await coordinator.getVisionQueue()
            await visionQueue.reindexAllColors()
            logInfo("reindexAllColors: Complete")
        }
    }

    // MARK: - Duplicate Detection

    /// Refresh the pending duplicate count for sidebar badge
    func refreshDuplicateCount() async {
        guard let detector = duplicateDetector else { return }
        do {
            let count = try await detector.countPendingGroups()
            if pendingDuplicateCount != count {
                pendingDuplicateCount = count
            }
        } catch {
            logError("Failed to count pending duplicates: \(error)")
        }
    }

    /// Open duplicate review; scanning is an explicit, cancellable action there.
    func findDuplicates() {
        guard FeatureFlags.deduplicate else { return }
        showDuplicateReview = true
    }

    // MARK: - FTS Index Health

    /// FTS index health: (indexed count, expected count)
    @Published var ftsHealth: (indexed: Int, expected: Int)? = nil

    /// Whether FTS index is currently being rebuilt
    @Published var isRebuildingFTS: Bool = false

    /// Check FTS index health
    func checkFTSHealth() async {
        guard let store = mediaStore else { return }
        do {
            let health = try await store.checkFTSHealth()
            if ftsHealth?.indexed != health.indexed || ftsHealth?.expected != health.expected {
                ftsHealth = health
            }
        } catch {
            logError("FTS health check failed: \(error)")
        }
    }

    /// Rebuild the FTS index from scratch
    func rebuildFTSIndex() async {
        guard let store = mediaStore else { return }
        isRebuildingFTS = true
        do {
            try await store.rebuildFTSIndex()
            await checkFTSHealth()
        } catch {
            logError("FTS rebuild failed: \(error)")
        }
        isRebuildingFTS = false
    }

    /// Sync existing color data from dominantColorsJSON to the junction table for filtering.
    /// Fast operation - doesn't re-extract colors, just populates the junction table.
    func syncColorsToJunctionTable() async {
        guard let coordinator = coordinator else { return }
        let visionQueue = await coordinator.getVisionQueue()
        await visionQueue.syncColorsToJunctionTable()
    }

    // MARK: - Filesystem Sync

    /// Whether filesystem sync is in progress
    @Published var isFilesystemSyncing: Bool = false

    /// Result of last filesystem sync
    @Published var lastFilesystemSyncResult: MediaStore.FilesystemSyncResult? = nil

    /// Sync database with filesystem: soft-delete items whose media files no longer exist.
    /// Use after manually deleting files in Finder to clean up stale DB entries.
    func syncWithFilesystem() async {
        guard let store = mediaStore else {
            logError("syncWithFilesystem: mediaStore is nil")
            return
        }

        isFilesystemSyncing = true
        defer { isFilesystemSyncing = false }

        do {
            let result = try await store.syncWithFilesystem()
            lastFilesystemSyncResult = result
            logInfo("Filesystem sync complete: scanned \(result.scannedCount), deleted \(result.softDeletedCount), cleaned \(result.cleanedUpCount), pruned \(result.duplicateGroupsPruned) groups")

            // Refresh duplicate count if any groups were pruned
            if result.duplicateGroupsPruned > 0 {
                await refreshDuplicateCount()
            }
        } catch {
            logError("Filesystem sync failed: \(error)")
        }
    }

    // MARK: - Database Cleanup

    /// Whether database cleanup is in progress
    @Published var isDatabaseCleaning: Bool = false

    /// Result of last database cleanup
    @Published var lastDatabaseCleanupResult: MediaStore.DatabaseCleanupResult? = nil

    /// Clean up database issues:
    /// - Delete file:// URL entries that duplicate real URL entries
    /// - Fix items with month-only basePath
    func cleanupDatabaseIssues() async {
        guard let store = mediaStore else {
            logError("cleanupDatabaseIssues: mediaStore is nil")
            return
        }

        isDatabaseCleaning = true
        defer { isDatabaseCleaning = false }

        do {
            let result = try await store.cleanupDatabaseIssues()
            lastDatabaseCleanupResult = result
            logInfo("Database cleanup complete: deleted \(result.duplicateFileUrlsDeleted) duplicate file:// entries, fixed \(result.basePathsFixed) basePaths")

            // Refresh duplicate count as cleanup may affect groups
            await refreshDuplicateCount()
        } catch {
            logError("Database cleanup failed: \(error)")
        }
    }

    // MARK: - Thumbnail Regeneration

    /// Progress state for thumbnail regeneration
    var thumbnailRegenerationProgress: (completed: Int, total: Int)? {
        get { backgroundStatus.thumbnailRegenerationProgress }
        set { backgroundStatus.updateThumbnailRegenerationProgress(newValue) }
    }

    /// Regenerate all thumbnails from source images.
    /// Clears cache and regenerates fresh thumbnails.
    /// Does NOT use saliency cropping (preserves original aspect ratio for grid).
    func regenerateAllThumbnails() {
        logInfo("regenerateAllThumbnails() called")
        guard let store = mediaStore else {
            logInfo("regenerateAllThumbnails: mediaStore is nil!")
            return
        }

        Task {
            logInfo("regenerateAllThumbnails: Fetching all items...")

            // Get all items
            let allItems: [MediaItem]
            do {
                allItems = try await store.fetchItems(filter: .all.withUnlimitedLimit())
            } catch {
                logInfo("regenerateAllThumbnails: Failed to fetch items: \(error)")
                return
            }
            guard !allItems.isEmpty else {
                logInfo("regenerateAllThumbnails: No items to regenerate")
                return
            }

            logInfo("regenerateAllThumbnails: Regenerating \(allItems.count) thumbnails...")

            await MainActor.run {
                thumbnailRegenerationProgress = (0, allItems.count)
            }

            await ImageCache.shared.regenerateThumbnails(
                for: allItems,
                size: .small,
                useSaliency: false
            ) { [weak self] completed, total in
                Task { @MainActor in
                    self?.thumbnailRegenerationProgress = (completed, total)
                }
            }

            await MainActor.run {
                thumbnailRegenerationProgress = nil
            }

            logInfo("regenerateAllThumbnails: Complete")
        }
    }

    /// Regenerate thumbnail for a specific item with optional saliency cropping.
    /// Use saliency=true for focus view, saliency=false for grid.
    func regenerateThumbnail(for itemID: UUID, useSaliency: Bool = false) {
        guard let store = mediaStore else { return }

        Task {
            guard let item = try? await store.fetchItem(id: itemID) else { return }
            _ = await ImageCache.shared.regenerateThumbnail(
                for: item,
                size: .small,
                useSaliency: useSaliency
            )
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var keyboardManager: KeyboardShortcutManager
    @StateObject private var commandRegistry = CommandRegistry.shared
    @SceneStorage("librarySplitVisibility") private var librarySplitVisibilityRaw: String = "all"
    @State private var existingTags: [String] = []
    /// Mirrors the persisted TagSettings recents, which the tagging HUD also records into.
    @State private var recentlyUsedTags: [String] = TagSettings.shared.recentTags.map(\.name)

    private var librarySplitVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                switch librarySplitVisibilityRaw {
                case "automatic":
                    return .automatic
                case "detailOnly":
                    return .detailOnly
                case "doubleColumn":
                    return .doubleColumn
                default:
                    return .all
                }
            },
            set: { newValue in
                switch newValue {
                case .automatic:
                    librarySplitVisibilityRaw = "automatic"
                case .detailOnly:
                    librarySplitVisibilityRaw = "detailOnly"
                case .doubleColumn:
                    librarySplitVisibilityRaw = "doubleColumn"
                case .all:
                    librarySplitVisibilityRaw = "all"
                default:
                    librarySplitVisibilityRaw = "all"
                }
            }
        )
    }

    var body: some View {
        ZStack {
            // Single NavigationSplitView - sidebar stays constant, detail content swaps
            NavigationSplitView(columnVisibility: librarySplitVisibility) {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 210, ideal: 245, max: 400)
            } detail: {
                // ZStack inside detail area - both views share same sidebar width
                ZStack {
                    // Issue #1: Show preview when Rediscover is selected
                    if FeatureFlags.rediscover,
                       appState.sidebarSelection == .rediscover,
                       let store = appState.mediaStore {
                        RediscoverPreviewView(mediaStore: store)
                            .environmentObject(appState)
                            .opacity(appState.isShowingSingleFocus ? 0 : 1)
                            .allowsHitTesting(!appState.isShowingSingleFocus)
                    } else {
                        // Keep MainGridView alive but hidden when in single focus mode
                        // This preserves the loaded items and scroll position
                        MainGridView()
                            .opacity(appState.isShowingSingleFocus ? 0 : 1)
                            .allowsHitTesting(!appState.isShowingSingleFocus)
                    }

                    // Focus view - inside same detail area, no separate sidebar
                    if let item = appState.focusedItem {
                        SingleFocusContainer(
                            item: item,
                            onClose: {
                                appState.closeSingleFocus()
                            }
                        )
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                    }
                }
            }
            // Disable sidebar animation - causes expensive grid relayout during animation
            .transaction { $0.animation = nil }
            // Hide toolbar (including sidebar toggle) when in focus mode
            .toolbar(appState.isShowingSingleFocus ? .hidden : .automatic, for: .windowToolbar)
            .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                VStack(alignment: .trailing, spacing: 0) {
                    if let store = appState.mediaStore {
                        MetadataSyncStatusView(queue: store.writeBackQueue)
                    }
                    MediaTransferFeedbackView()
                }
            }
            .sheet(item: $appState.mediaExportRequest) { request in
                ExportOptionsView(items: request.context.items, transferContext: request.context, initialSource: request.source)
            }
            .sheet(isPresented: $appState.showRetainedFileData) {
                if let store = appState.mediaStore {
                    RetainedAssetDataView(store: store, itemID: nil, displayedAssetID: nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .quickExport)) { _ in
                MediaFileAction.exportMetadata.perform(context: appState.mediaActionContext, source: .downloaded, appState: appState)
            }
            .onReceive(NotificationCenter.default.publisher(for: .copyImageToClipboard)) { _ in
                guard appState.focusedItem == nil else { return }
                appState.copyDisplayedImage()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSourceURL)) { _ in
                guard appState.focusedItem == nil else { return }
                for item in appState.mediaActionContext.items.prefix(5) { NSWorkspace.shared.open(item.metadata.source) }
            }

            // Tag input overlay
            TagInputOverlay(
                isPresented: $appState.showTagInput,
                selectedItemID: appState.selectedItemID ?? appState.focusedItem?.id,
                existingTags: existingTags,
                recentlyUsedTags: recentlyUsedTags,
                onAddTag: { tag in
                    appState.addTag(tag)
                    TagSettings.shared.recordTagUsage(named: tag)
                    recentlyUsedTags = TagSettings.shared.recentTags.map(\.name)
                }
            )

            // Delete confirmation overlay
            if keyboardManager.showDeleteConfirmation {
                DeleteConfirmationOverlay(
                    itemCount: keyboardManager.itemsPendingDeletion.count,
                    onConfirm: {
                        appState.deleteItems(keyboardManager.itemsPendingDeletion)
                        keyboardManager.showDeleteConfirmation = false
                        keyboardManager.itemsPendingDeletion = []
                    },
                    onCancel: {
                        keyboardManager.showDeleteConfirmation = false
                        keyboardManager.itemsPendingDeletion = []
                    }
                )
            }

            // Undo toast overlay
            UndoToastContainer(
                undoStack: appState.undoStack,
                onUndo: {
                    appState.performUndo()
                }
            )

            // Command palette overlay (topmost)
            if appState.showCommandPalette {
                CommandPalette(
                    registry: commandRegistry,
                    isPresented: $appState.showCommandPalette
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .animation(.easeOut(duration: 0.15), value: appState.showCommandPalette)
            }

            // Duplicate triage overlay (redesigned UX)
            if FeatureFlags.deduplicate, appState.showDuplicateReview,
               let detector = appState.duplicateDetector,
               let service = appState.duplicateReviewService {
                DuplicateTriageView(detector: detector, reviewService: service)
                    .environmentObject(appState)
                    .environment(SettingsStore.shared)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .animation(.easeOut(duration: 0.15), value: appState.showDuplicateReview)
            }

            // Issue #1: Rediscover session overlay (only when explicitly started)
            // Clicking "Rediscover" in sidebar shows preview grid, not this overlay
            if FeatureFlags.rediscover,
               appState.showRediscoverSession,
               let store = appState.mediaStore {
                RediscoverView(
                    onClose: {
                        appState.showRediscoverSession = false
                        // Stay on rediscover in sidebar to show preview
                    },
                    mediaStore: store
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }

            // Board detail overlay
            if FeatureFlags.boards, case .board(let boardId) = appState.sidebarSelection {
                BoardDetailView(boardId: boardId)
                    .environmentObject(appState)
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }

            // Canvas overlay (infinite canvas view)
            if FeatureFlags.canvas, case .canvas(let canvasId) = appState.sidebarSelection {
                CanvasViewContainer(
                    canvasId: canvasId,
                    onItemSelected: { itemId in
                        appState.selectedItemID = itemId
                        appState.selectedItemIDs = [itemId]
                    },
                    onItemDoubleClicked: { itemId in
                        // Open in single focus view
                        if let item = appState.displayedItem(for: itemId) {
                            appState.openSingleFocus(item)
                        }
                    }
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }

            // Issue #1 fix: Visual Clusters overlay
            if case .visualClusters = appState.sidebarSelection {
                ClusterBrowserView(
                    onItemSelected: { item in
                        appState.selectedItemID = item.id
                        appState.selectedItemIDs = [item.id]
                    },
                    onItemDoubleClicked: { item in
                        appState.openSingleFocus(item)
                    },
                    onDismiss: {
                        appState.commitLibraryDestinationChange(.allMedia)
                    }
                )
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }

            // Issue #4: Full keyboard shortcuts help panel (from Help menu)
            if appState.showKeyboardShortcutsHelp {
                KeyboardShortcutsHelpPanel(isPresented: $appState.showKeyboardShortcutsHelp)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }

            // Issue #5: Annotation mode indicator badge
            // Shows "ANNOTATE" badge when in annotation mode to indicate shortcut override
            if FeatureFlags.annotate, appState.isAnnotationModeActive {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        AnnotationModeIndicator()
                            .padding(.trailing, 20)
                            .padding(.bottom, 20)
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }

            // Issue #11: Escape key hint when multiple layers can be dismissed
            EscapeKeyHint()
        }
        .background(Color(hex: 0x1a1a1a))
        .background(
            // Keyboard handler for Cmd+Z / Cmd+Shift+Z
            UndoKeyHandler(
                onUndo: { appState.performUndo() },
                onRedo: { appState.performRedo() }
            )
        )
        .task {
            await loadExistingTags()
        }
        .onAppear {
            commandRegistry.registerDefaultCommands(appState: appState)
            loadSmartFoldersForPalette()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleNavigationSidebar)) { _ in
            // Toggle NavigationSplitView sidebar visibility
            withAnimation(.easeInOut(duration: 0.15)) {
                switch librarySplitVisibilityRaw {
                case "detailOnly":
                    librarySplitVisibilityRaw = "all"
                default:
                    librarySplitVisibilityRaw = "detailOnly"
                }
            }
        }
    }

    private func loadExistingTags() async {
        guard let store = appState.mediaStore else { return }
        do {
            existingTags = try await store.fetchAllTags()
            recentlyUsedTags = TagSettings.shared.recentTags.map(\.name)
            // With no recorded history yet, offer the first few library tags.
            if recentlyUsedTags.isEmpty && !existingTags.isEmpty {
                recentlyUsedTags = Array(existingTags.prefix(8))
            }
        } catch {
            logError("Failed to load tags: \(error.localizedDescription)")
        }
    }

    private func loadSmartFoldersForPalette() {
        guard let store = appState.mediaStore else { return }
        Task {
            do {
                let folders = try await store.fetchSmartFolders()
                await MainActor.run {
                    commandRegistry.registerSmartFolderCommands(folders: folders) { folder in
                        appState.commitLibraryDestinationChange(
                            .smartFolder(folder.id),
                            smartFolder: folder
                        )
                    }
                }
            } catch {
                logError("Failed to load smart folders for command palette: \(error.localizedDescription)")
            }
        }
    }
}

/// Takes the size its container proposes without measuring its content. An `HSplitView` pane
/// re-measures its minimum size on every layout pass; measuring the library pane walked the
/// filter bar's `ViewThatFits` (all three layouts) and took ~40% of the main thread while scrolling.
private struct ContainerSizedPane: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// Main grid view with search/filter bar, timeline filter, and masonry grid
struct MainGridView: View {
    @EnvironmentObject var appState: AppState

    /// Get the selected item for the inspector panel
    private var selectedItem: MediaItem? {
        guard let id = appState.selectedItemID else { return nil }
        return appState.displayedItem(for: id)
    }

    /// Count of selected items (for multi-select display)
    private var selectedCount: Int {
        // For now, only single selection is tracked in appState
        // Multi-select count comes from MasonryGridViewModel but isn't easily accessible here
        appState.selectedItemID != nil ? 1 : 0
    }

    var body: some View {
        HSplitView {
            // Main content (filter bar + timeline + grid)
            ContainerSizedPane() {
                VStack(spacing: 0) {
                    // Enhanced search filter bar at top
                    // Double-click empty space here to zoom the window — with .hiddenTitleBar there's
                    // no real title bar for AppKit's double-click-to-zoom to attach to, so this strip
                    // is the closest equivalent. .simultaneousGesture on the whole bar would fire
                    // inside the search field too (breaking word-select-by-double-click), so this is
                    // a background layer instead — real controls hit-test first and keep priority.
                    SearchFilterBar()
                        .background(
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { zoomWindow() }
                        )

                    if appState.sidebarSelection == .recentlyDeleted {
                        RecentlyDeletedToolbar()
                    }

                    // Timeline filter (below filter bar, above grid per SPEC.md)
                    TimelineFilterContainer { dateRange in
                        appState.commitLibraryFilterChange {
                            appState.dateRangeFilter = dateRange
                        }
                    }

                    // Main content: grid or table based on browse mode
                    switch appState.browseMode {
                    case .grid:
                        MasonryGridContainer()
                    case .table:
                        TableBrowserContainer()
                    }
                }
            }
            // Sidebar min (210) + this + inspector (280) must fit an ~820pt window, or the
            // split view pushes the sidebar past its leading edge. The toolbar collapses
            // its filter chips into a menu to fit this width.
            .frame(minWidth: 320)

            // Right inspector panel (conditional)
            if appState.showInspectorPanel {
                GridInspectorPanel(item: selectedItem)
                    .frame(width: 280)
            }
        }
        // Add drag-drop import capability (Finder -> app)
        .importDropZone()
    }
}

private struct RecentlyDeletedToolbar: View {
    @EnvironmentObject private var appState: AppState
    @State private var pendingConfirmation: Confirmation?
    @State private var errorMessage: String?
    @State private var errorTitle = "Couldn’t Restore"
    @State private var isWorking = false
    /// Whole-bin count (not just the loaded page), for Empty's enabled state and confirmation.
    @State private var binCount: Int?

    private enum Confirmation: Identifiable {
        case selected([UUID])
        case all

        var id: String {
            switch self {
            case .selected(let ids): return "selected:" + ids.map(\.uuidString).joined(separator: ",")
            case .all: return "all"
            }
        }
    }

    private var visibleSelectedIDs: [UUID] {
        appState.displayedItems.compactMap { item in
            appState.selectedItemIDs.contains(item.id) ? item.id : nil
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text("Items stay here until you restore or permanently delete them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
                .help("Items stay here until you restore or permanently delete them.")

            Spacer(minLength: 12)

            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Restore") {
                restoreSelection()
            }
            .disabled(visibleSelectedIDs.isEmpty || isWorking)
            .help("Restore the selected items to the library. Missing files must be put back first.")

            Button("Delete Permanently…", role: .destructive) {
                pendingConfirmation = .selected(visibleSelectedIDs)
            }
            .disabled(visibleSelectedIDs.isEmpty || isWorking)

            Button("Empty Recently Deleted…", role: .destructive) {
                pendingConfirmation = .all
            }
            .disabled(isWorking || binCount == 0)
        }
        .task(id: appState.displayedItems.count) { await refreshBinCount() }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .alert(item: $pendingConfirmation) { confirmation in
            let count: Int
            let subject: String
            switch confirmation {
            case .selected(let ids):
                count = ids.count
                subject = "\(count) item\(count == 1 ? "" : "s")"
            case .all:
                count = binCount ?? 0
                subject = binCount.map { "all \($0) item\($0 == 1 ? "" : "s")" } ?? "every item"
            }
            return Alert(
                title: Text({
                    if case .selected = confirmation { return "Delete Permanently?" }
                    return "Empty Recently Deleted?"
                }()),
                message: Text("Remove \(subject) from NoDraw? Any files still on disk will be moved to the system Trash."),
                primaryButton: .destructive(Text("Delete Permanently")) {
                    purge(confirmation)
                },
                secondaryButton: .cancel()
            )
        }
        .alert(errorTitle, isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func restoreSelection() {
        let ids = visibleSelectedIDs
        guard let store = appState.mediaStore, !ids.isEmpty else { return }
        isWorking = true
        Task {
            do {
                try await store.restoreDeletedWithFileValidation(ids: ids)
                await MainActor.run {
                    clearSelection()
                    isWorking = false
                    appState.undoStack.showSuccessToast("Restored \(ids.count) item\(ids.count == 1 ? "" : "s")")
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorTitle = "Couldn’t Restore"
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func refreshBinCount() async {
        guard let store = appState.mediaStore else { return }
        var filter = FilterState()
        filter.deletionScope = .deletedOnly
        filter.hideJunk = false
        filter.hideSafetyFlagged = false
        binCount = try? await store.countItems(filter: filter)
    }

    private func purge(_ confirmation: Confirmation) {
        guard let store = appState.mediaStore else { return }
        let selectedSnapshot: [UUID]
        switch confirmation {
        case .selected(let ids): selectedSnapshot = ids
        case .all: selectedSnapshot = []
        }
        if case .selected = confirmation, selectedSnapshot.isEmpty { return }
        isWorking = true
        Task {
            do {
                let ids: [UUID]
                if case .all = confirmation {
                    var filter = FilterState()
                    filter.deletionScope = .deletedOnly
                    filter.hideJunk = false
                    filter.hideSafetyFlagged = false
                    filter.limit = -1
                    ids = try await store.fetchItems(
                        filter: filter,
                        includeMLAttributes: false,
                        includePerFileOCR: false,
                        includeVideoSegments: false,
                        includeTranscriptSegments: false
                    ).map(\.id)
                } else {
                    ids = selectedSnapshot
                }
                guard !ids.isEmpty else {
                    await MainActor.run { isWorking = false }
                    return
                }
                let result = try await DeleteService(mediaStore: store).purgeDeletedItems(ids: ids)
                await MainActor.run {
                    clearSelection()
                    isWorking = false
                    if result.hasFileErrors {
                        errorTitle = "Some Files Couldn’t Be Removed"
                        errorMessage = result.fileErrors.joined(separator: "\n")
                    } else {
                        appState.undoStack.showSuccessToast("Permanently deleted \(result.deletedCount) item\(result.deletedCount == 1 ? "" : "s")")
                    }
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    errorTitle = "Couldn’t Delete Permanently"
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func clearSelection() {
        appState.selectedItemIDs = []
        appState.selectedItemID = nil
    }
}

// MARK: - Grid Inspector Panel

/// Right sidebar inspector panel for the library grid view.
/// Shows metadata for the selected item, aggregate info for multi-select, or a placeholder when nothing is selected.
private struct GridInspectorPanel: View {
    let item: MediaItem?
    @EnvironmentObject var appState: AppState

    /// Selected items for multi-select aggregate display
    private var selectedItems: [MediaItem] {
        appState.displayedItems(for: appState.selectedItemIDs)
    }

    /// Common tags across all selected items
    private var commonTags: [String] {
        guard !selectedItems.isEmpty else { return [] }
        var common = Set(selectedItems.first?.metadata.tags ?? [])
        for item in selectedItems.dropFirst() {
            common = common.intersection(Set(item.metadata.tags))
        }
        return common.sorted()
    }

    var body: some View {
        Group {
            if appState.selectedItemIDs.count > 1 {
                // Multi-select aggregate view
                multiSelectView
            } else if let item = item {
                MetadataPanel(
                    item: item,
                    onTagsChanged: { newTags in
                        updateTags(for: item.id, tags: newTags)
                    },
                    onNotesChanged: { itemID, newNotes in
                        let oldNotes = itemID == item.id
                            ? item.metadata.notes
                            : appState.displayedItem(for: itemID)?.metadata.notes
                        updateNotes(for: itemID, oldNotes: oldNotes, notes: newNotes)
                    },
                    onStarChanged: { starred in
                        updateStar(for: item.id, starred: starred)
                    }
                )
            } else {
                // Empty state
                VStack(spacing: 12) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No Selection")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Select an item to view details")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: 0x1f1f1f))
            }
        }
    }

    // MARK: - Multi-Select View

    private var multiSelectView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    Text("\(appState.selectedItemIDs.count.formatted(.number)) items selected")
                        .font(.headline)
                }
                .padding(.bottom, 8)

                Divider()

                // Platforms breakdown
                let platforms = Dictionary(grouping: selectedItems, by: { $0.metadata.platform })
                if !platforms.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Platforms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(platforms.keys.sorted(), id: \.self) { platform in
                            HStack {
                                Text(LibraryFilterPresentation.platformName(platform))
                                    .font(.subheadline)
                                Spacer()
                                Text((platforms[platform]?.count ?? 0).formatted(.number))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Divider()

                // Starred count
                let starredCount = selectedItems.filter { $0.metadata.starred }.count
                HStack {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                    Text("Starred")
                        .font(.subheadline)
                    Spacer()
                    Text("\(starredCount.formatted(.number)) of \(selectedItems.count.formatted(.number))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                // Common tags
                if !commonTags.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Common Tags")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(commonTags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule()
                                                .fill(Color.orange.opacity(0.2))
                                        )
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding()
        }
        .background(Color(hex: 0x1f1f1f))
    }

    // MARK: - Update Actions

    private func updateTags(for id: UUID, tags: [String]) {
        guard let store = appState.mediaStore else { return }
        Task {
            do {
                // Calculate delta
                if let currentItem = appState.displayedItem(for: id) {
                    let currentTags = Set(currentItem.metadata.tags)
                    let newTags = Set(tags)
                    let toAdd = newTags.subtracting(currentTags)
                    let toRemove = currentTags.subtracting(newTags)

                    for tag in toAdd {
                        try await store.addTag(id: id, tag: tag)
                    }
                    for tag in toRemove {
                        try await store.removeTag(id: id, tag: tag)
                    }
                }
            } catch {
                logError("Failed to update tags: \(error.localizedDescription)")
            }
        }
    }

    private func updateNotes(for id: UUID, oldNotes: String?, notes: String?) {
        guard oldNotes != notes else { return }
        appState.updateNotes(for: id, oldNotes: oldNotes, newNotes: notes)
    }

    private func updateStar(for id: UUID, starred: Bool) {
        guard let store = appState.mediaStore else { return }
        Task {
            do {
                try await store.setStar(id: id, starred: starred)
            } catch {
                logError("Failed to update star: \(error.localizedDescription)")
            }
        }
    }
}

// CommandPaletteView stub removed - using CommandPalette from CommandPalette.swift
// MARK: - Delete Confirmation Overlay

struct DeleteConfirmationOverlay: View {
    let itemCount: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // Dismiss background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    onCancel()
                }

            // Confirmation dialog
            VStack(spacing: 16) {
                Image(systemName: "trash")
                    .font(.system(size: 32))
                    .foregroundStyle(.red)

                Text("Move to Trash?")
                    .font(.headline)

                Text("Move \(itemCount) item\(itemCount == 1 ? "" : "s") to Trash?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .buttonStyle(.bordered)

                    Button("Move to Trash") {
                        onConfirm()
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(.top, 8)
            }
            .padding(24)
            .background(Color(hex: 0x1a1a1a))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 8)
        }
        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }

    /// App interaction accent, following the user's macOS accent color.
    static var accentOrange: Color { .accentColor }
}

// MARK: - Keyboard & Mouse Reference Panel

/// Shared input reference, shown from Help > Keyboard & Mouse Reference (Cmd+/).
struct KeyboardShortcutsHelpPanel: View {
    @Binding var isPresented: Bool

    private var referenceSections: [CommandReferenceSection] {
        AppCommandCatalog.keyboardSections + [AppCommandCatalog.mouseSection]
    }

    var body: some View {
        ZStack {
            // Dim background - tap to dismiss
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            // Main panel
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Keyboard & Mouse")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

                Divider()
                    .background(Color.white.opacity(0.2))

                // Scrollable content
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(referenceSections) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title)
                                    .font(.headline)
                                    .foregroundStyle(Color.accentOrange)

                                ForEach(section.entries) { entry in
                                    HStack {
                                        Text(entry.input)
                                            .font(.system(.body, design: .monospaced).weight(.semibold))
                                            .foregroundStyle(.white)
                                            .frame(width: 150, alignment: .leading)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.title)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(.white.opacity(0.95))
                                            Text(entry.help)
                                                .font(.caption)
                                                .foregroundStyle(.white.opacity(0.62))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }

                                        Spacer()

                                        if let context = entry.contextLabel {
                                            Text(context)
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.white.opacity(0.1))
                                                .cornerRadius(4)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                    .padding(.vertical, 16)
                }
            }
            .frame(width: 650, height: 660)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: 0x2a2a2a))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
            )
        }
    }

}

// MARK: - Annotation Mode Indicator (Issue #5)

/// Badge shown when annotation mode is active to indicate shortcut overrides.
/// Displays "ANNOTATE" with pulsing border animation.
struct AnnotationModeIndicator: View {
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil.and.scribble")
                .font(.caption.weight(.bold))
            Text("ANNOTATE")
                .font(.caption.weight(.bold))
                .tracking(1)
        }
        .foregroundStyle(Color.accentOrange)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentOrange.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentOrange.opacity(isPulsing ? 0.8 : 0.3), lineWidth: 1)
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
        .help("Annotation mode active - some shortcuts are remapped (S=sniper, R=rectangle, etc.)")
    }
}

// MARK: - Escape Key Hint (Issue #11)

/// Shows a subtle hint about what Escape will do when multiple dismissible layers exist.
/// Only appears briefly when relevant, positioned at bottom-center.
struct EscapeKeyHint: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var keyboardManager: KeyboardShortcutManager

    @State private var showHint = false
    @State private var hintText = ""
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        VStack {
            Spacer()
            if showHint {
                HStack(spacing: 6) {
                    Text("Esc")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color.accentOrange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(3)
                    Text(hintText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color(hex: 0x2a2a2a).opacity(0.95))
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 16)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: escapeLayerCount) { _, count in
            updateHint(layerCount: count)
        }
        .onAppear {
            updateHint(layerCount: escapeLayerCount)
        }
    }

    /// Count of layers that Escape can dismiss
    private var escapeLayerCount: Int {
        var count = 0
        if keyboardManager.showTagInput || appState.showTagInput { count += 1 }
        if appState.showCommandPalette { count += 1 }
        if keyboardManager.showDeleteConfirmation { count += 1 }
        if appState.hasSelectedSubjectMask { count += 1 }
        if appState.hasSelectedAnnotationShape { count += 1 }
        if appState.isAnnotationModeActive { count += 1 }
        if appState.isShowingSingleFocus { count += 1 }
        if appState.showDuplicateReview { count += 1 }
        if !appState.filterText.isEmpty { count += 1 }
        if appState.selectedItemID != nil { count += 1 }
        return count
    }

    private func updateHint(layerCount: Int) {
        dismissTask?.cancel()

        // Only show hint when there are multiple layers
        guard layerCount >= 2 else {
            withAnimation(.easeOut(duration: 0.2)) {
                showHint = false
            }
            return
        }

        // Determine what Escape will do (same priority as KeyboardShortcutManager.handleEscape)
        if keyboardManager.showTagInput || appState.showTagInput {
            hintText = "close tag input"
        } else if appState.showCommandPalette {
            hintText = "close palette"
        } else if keyboardManager.showDeleteConfirmation {
            hintText = "cancel delete"
        } else if appState.hasSelectedSubjectMask {
            hintText = "deselect mask"
        } else if appState.hasSelectedAnnotationShape {
            hintText = "deselect shape"
        } else if appState.isAnnotationModeActive {
            hintText = "exit annotation"
        } else if appState.isShowingSingleFocus {
            hintText = "close detail"
        } else if appState.showDuplicateReview {
            hintText = "close review"
        } else if !appState.filterText.isEmpty {
            hintText = "clear filter"
        } else if appState.selectedItemID != nil {
            hintText = "clear selection"
        } else {
            showHint = false
            return
        }

        withAnimation(.easeOut(duration: 0.2)) {
            showHint = true
        }

        // Auto-hide after 3 seconds
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    showHint = false
                }
            }
        }
    }
}
