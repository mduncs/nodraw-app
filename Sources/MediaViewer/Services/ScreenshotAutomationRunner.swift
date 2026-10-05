import Combine
import Foundation

@MainActor
final class ScreenshotAutomationRunner: ObservableObject {
    static let shared = ScreenshotAutomationRunner()

    struct Config {
        let tag: String?
        let browseMode: AppState.BrowseMode?
        let itemID: UUID?
        let openFocus: Bool
        let showInspector: Bool
        let showFocusMetadata: Bool
        let readyFile: URL?
    }

    private var hasStarted = false

    private init() {}

    static var configuration: Config? {
        let env = ProcessInfo.processInfo.environment
        let watchedKeys = [
            "NODRAW_AUTOMATION_TAG",
            "NODRAW_AUTOMATION_VIEW",
            "NODRAW_AUTOMATION_ITEM_ID",
            "NODRAW_AUTOMATION_OPEN_FOCUS",
            "NODRAW_AUTOMATION_SHOW_INSPECTOR",
            "NODRAW_AUTOMATION_SHOW_FOCUS_METADATA",
            "NODRAW_AUTOMATION_READY_FILE"
        ]

        guard watchedKeys.contains(where: { env[$0] != nil }) else {
            return nil
        }

        let browseMode = env["NODRAW_AUTOMATION_VIEW"].flatMap(AppState.BrowseMode.init(rawValue:))
        let itemID = env["NODRAW_AUTOMATION_ITEM_ID"].flatMap(UUID.init(uuidString:))
        let readyFile = env["NODRAW_AUTOMATION_READY_FILE"].map(URL.init(fileURLWithPath:))

        return Config(
            tag: env["NODRAW_AUTOMATION_TAG"],
            browseMode: browseMode,
            itemID: itemID,
            openFocus: truthy(env["NODRAW_AUTOMATION_OPEN_FOCUS"]),
            showInspector: truthy(env["NODRAW_AUTOMATION_SHOW_INSPECTOR"]),
            showFocusMetadata: truthy(env["NODRAW_AUTOMATION_SHOW_FOCUS_METADATA"]),
            readyFile: readyFile
        )
    }

    func startIfNeeded(appState: AppState) {
        guard !hasStarted, let config = Self.configuration else { return }
        hasStarted = true

        Task { @MainActor in
            await run(config: config, appState: appState)
        }
    }

    private func run(config: Config, appState: AppState) async {
        logInfo("Screenshot automation starting")

        await waitUntilReady(appState)

        let initialDisplayedIDs = Set(appState.displayedItems.map(\.id))

        if let browseMode = config.browseMode {
            appState.browseMode = browseMode
        }

        if let tag = config.tag, !tag.isEmpty {
            appState.sidebarSelection = .tag(tag)
            appState.filterText = ""
            appState.activeSmartFolder = nil
        }

        if config.showInspector {
            appState.showInspectorPanel = true
        }

        if config.showFocusMetadata {
            appState.showFocusMetadataPanel = true
        }

        appState.selectedItemID = nil
        appState.selectedItemIDs = []

        await settle()
        guard let item = await waitForResolvableItem(
            config: config,
            appState: appState,
            initialDisplayedIDs: initialDisplayedIDs
        ) else {
            writeReadyFile(config.readyFile, payload: """
            status=error
            reason=no-item
            displayed_count=\(appState.displayedItems.count)
            """)
            return
        }

        appState.selectedItemID = item.id
        appState.selectedItemIDs = [item.id]
        appState.updateDisplayContextSelection(selectedIDs: [item.id], anchorID: item.id)

        if config.openFocus {
            appState.openSingleFocus(item, navigationItems: appState.displayedItems)
            if config.showFocusMetadata {
                appState.showFocusMetadataPanel = true
            }
        }

        await settle()

        writeReadyFile(config.readyFile, payload: """
        status=ready
        item_id=\(item.id.uuidString)
        displayed_count=\(appState.displayedItems.count)
        browse_mode=\(appState.browseMode.rawValue)
        focused=\(appState.focusedItem != nil)
        selected_id=\(appState.selectedItemID?.uuidString ?? "")
        """)

        logInfo("Screenshot automation ready for capture")
    }

    private func waitUntilReady(_ appState: AppState) async {
        for _ in 0..<120 {
            if appState.initPhase == .ready || isProcessingPhase(appState.initPhase) {
                return
            }
            await settle()
        }
    }

    private func waitForResolvableItem(
        config: Config,
        appState: AppState,
        initialDisplayedIDs: Set<UUID>
    ) async -> MediaItem? {
        for _ in 0..<120 {
            if let item = await resolveItem(config: config, appState: appState) {
                return item
            }

            if shouldWaitForDisplayRefresh(config: config, appState: appState, initialDisplayedIDs: initialDisplayedIDs) {
                await settle()
                continue
            }

            await settle()
        }

        return await resolveItem(config: config, appState: appState)
    }

    private func shouldWaitForDisplayRefresh(
        config: Config,
        appState: AppState,
        initialDisplayedIDs: Set<UUID>
    ) -> Bool {
        guard config.tag != nil || config.itemID != nil else {
            return false
        }

        let currentIDs = Set(appState.displayedItems.map(\.id))
        return currentIDs == initialDisplayedIDs
    }

    private func resolveItem(config: Config, appState: AppState) async -> MediaItem? {
        if let itemID = config.itemID,
           let displayed = appState.displayedItems.first(where: { $0.id == itemID }),
           itemMatchesAutomationTarget(displayed, config: config) {
            return displayed
        }

        if let itemID = config.itemID,
           let store = appState.mediaStore,
           let fetched = try? await store.fetchItem(id: itemID),
           itemMatchesAutomationTarget(fetched, config: config) {
            return fetched
        }

        return appState.displayedItems.first { itemMatchesAutomationTarget($0, config: config) }
    }

    private func itemMatchesAutomationTarget(_ item: MediaItem, config: Config) -> Bool {
        if let tag = config.tag, !tag.isEmpty, !item.metadata.tags.contains(tag) {
            return false
        }

        return true
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    private func isProcessingPhase(_ phase: InitializationPhase) -> Bool {
        if case .processingItems = phase {
            return true
        }
        return false
    }

    private func writeReadyFile(_ url: URL?, payload: String) {
        guard let url else { return }
        do {
            try payload.appending("\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logError("Failed to write screenshot automation ready file: \(error.localizedDescription)")
        }
    }
}

private func truthy(_ value: String?) -> Bool {
    guard let value else { return false }
    switch value.lowercased() {
    case "1", "true", "yes", "on":
        return true
    default:
        return false
    }
}
