import XCTest
import SwiftUI
@testable import MediaViewer

@MainActor
final class CommandParityTests: XCTestCase {
    private var registry: CommandRegistry!

    override func setUp() async throws {
        registry = CommandRegistry.shared
        registry.clearAll()
    }

    override func tearDown() async throws {
        registry.clearAll()
        registry = nil
    }

    func testEveryAdvertisedInputHasUniqueIdentityCopyAndRoute() {
        let entries = AppCommandCatalog.allAdvertisedEntries
        let ids = entries.map(\.id)

        XCTAssertEqual(ids.count, Set(ids).count, "Reference entries must have stable unique IDs")
        XCTAssertTrue(entries.contains { $0.id == "mouse.middle-click" })
        XCTAssertTrue(entries.contains { $0.id == "mouse.stop-autoscroll" })

        for entry in entries {
            XCTAssertFalse(entry.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.id)
            XCTAssertFalse(entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.id)
            XCTAssertFalse(entry.help.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.id)
            XCTAssertFalse(entry.routes.isEmpty, "\(entry.id) advertises input without an implementation route")

            for route in entry.routes {
                switch route {
                case .keyboard:
                    break // Associated ShortcutAction is compile-checked.
                case .menu(let identifier), .focusView(let identifier), .mouse(let identifier):
                    XCTAssertFalse(
                        identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "\(entry.id) has an unnamed implementation route"
                    )
                }
            }
        }
    }

    func testAdvertisedInputTitleAndScopeTriplesDoNotConflict() {
        let triples = AppCommandCatalog.allAdvertisedEntries.map {
            "\($0.input)|\($0.title)|\($0.context.rawValue)"
        }
        XCTAssertEqual(
            triples.count,
            Set(triples).count,
            "Duplicate static claims should share one catalog entry instead"
        )
    }

    func testRepeatedEntriesAcrossHelpSurfacesReuseIdenticalCatalogCopy() {
        let grouped = Dictionary(grouping: AppCommandCatalog.advertisedSurfaceEntries, by: \.id)
        let repeated = grouped.values.filter { $0.count > 1 }
        XCTAssertFalse(repeated.isEmpty, "Focus and full help should share canonical entries")

        for entries in repeated {
            let canonical = entries[0]
            for entry in entries.dropFirst() {
                XCTAssertEqual(entry.input, canonical.input, canonical.id)
                XCTAssertEqual(entry.title, canonical.title, canonical.id)
                XCTAssertEqual(entry.help, canonical.help, canonical.id)
                XCTAssertEqual(entry.context, canonical.context, canonical.id)
                XCTAssertEqual(entry.routes, canonical.routes, canonical.id)
                XCTAssertEqual(
                    entry.paletteShortcut?.displayString,
                    canonical.paletteShortcut?.displayString,
                    canonical.id
                )
            }
        }
    }

    func testPaletteNavigationCommandsReuseCatalogNamesShortcutsAndScopes() {
        let appState = AppState()
        registry.registerDefaultCommands(appState: appState)

        let expected: [(id: String, entry: CommandReferenceEntry)] = [
            ("nav.filter", AppCommandCatalog.focusFilter),
            ("nav.nextItem", AppCommandCatalog.nextResult),
            ("nav.prevItem", AppCommandCatalog.previousResult),
            ("nav.pageUp", AppCommandCatalog.pageUp),
            ("nav.pageDown", AppCommandCatalog.pageDown),
            ("nav.firstItem", AppCommandCatalog.libraryTop),
            ("nav.lastItem", AppCommandCatalog.libraryBottom),
            ("system.commandPalette", AppCommandCatalog.commandPalette),
        ]

        for pair in expected {
            let command = registry.command(id: pair.id)
            XCTAssertEqual(command?.title, pair.entry.title, pair.id)
            XCTAssertEqual(command?.context, pair.entry.context, pair.id)
            XCTAssertEqual(
                command?.shortcut?.displayString,
                pair.entry.paletteShortcut?.displayString,
                pair.id
            )
        }
    }

    func testResultAssetAndFolderSequencesUseDistinctTruthfulVocabulary() {
        XCTAssertEqual(AppCommandCatalog.previousResult.title, "Previous Result")
        XCTAssertEqual(AppCommandCatalog.nextResult.title, "Next Result")
        XCTAssertEqual(AppCommandCatalog.previousAsset.title, "Previous Asset")
        XCTAssertEqual(AppCommandCatalog.nextAsset.title, "Next Asset")
        XCTAssertEqual(AppCommandCatalog.previousInFolder.title, "Previous in Folder")
        XCTAssertEqual(AppCommandCatalog.nextInFolder.title, "Next in Folder")
        XCTAssertTrue(AppCommandCatalog.arrowResultContinuation.help.contains("item boundary"))
    }

    func testDirectExecutionRechecksEnablementAndDoesNotRecordDisabledCommand() {
        let appState = AppState()
        var didRun = false
        let command = Command(
            id: "disabled-at-execution",
            title: "Disabled at Execution",
            isEnabled: { state in state?.isShowingSingleFocus == true },
            action: { didRun = true }
        )

        XCTAssertFalse(registry.execute(command, appState: appState))
        XCTAssertFalse(didRun)
        XCTAssertFalse(registry.recentCommandIDs.contains(command.id))
    }

    func testCommandPaletteHasOnlyExplicitExecutionTriggers() {
        XCTAssertEqual(CommandPaletteExecutionTrigger.allCases.count, 2)
        XCTAssertTrue(CommandPaletteExecutionTrigger.allCases.contains { trigger in
            if case .returnKey = trigger { return true }
            return false
        })
        XCTAssertTrue(CommandPaletteExecutionTrigger.allCases.contains { trigger in
            if case .pointerClick = trigger { return true }
            return false
        })
    }

    func testRetainedFileUtilityIsGlobalWithoutSelectionOrPendingMetadata() throws {
        let unavailableState = AppState()
        registry.registerDefaultCommands(appState: unavailableState)
        let command = try XCTUnwrap(registry.command(id: "system.retainedFileData"))
        XCTAssertEqual(command.title, AppCommandCatalog.retainedFileDataTitle)
        XCTAssertFalse(command.isEnabled(unavailableState))
        let database = DatabaseManager(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-retained-command-\(UUID()).sqlite"))
        let appState = AppState(mediaStore: MediaStore(database: database))
        registry.registerDefaultCommands(appState: appState)
        let availableCommand = try XCTUnwrap(registry.command(id: "system.retainedFileData"))
        XCTAssertNil(appState.focusedItem)
        XCTAssertTrue(appState.selectedItemIDs.isEmpty)
        XCTAssertTrue(command.isEnabled(appState))
        XCTAssertTrue(registry.execute(availableCommand, appState: appState))
        XCTAssertTrue(appState.showRetainedFileData)
    }

    func testResultCommandEnablementTracksTrueFocusSessionBoundaries() {
        let appState = AppState()
        let items = (0..<3).map(makeItem(index:))
        appState.setDisplayContext(surface: .grid, items: items)
        appState.openSingleFocus(items[0])
        registry.registerDefaultCommands(appState: appState)

        XCTAssertFalse(appState.canNavigateToPreviousResult)
        XCTAssertTrue(appState.canNavigateToNextResult)
        XCTAssertFalse(registry.command(id: "nav.prevItem")!.isEnabled(appState))
        XCTAssertTrue(registry.command(id: "nav.nextItem")!.isEnabled(appState))

        appState.navigateToNextItem()
        XCTAssertTrue(appState.canNavigateToPreviousResult)
        XCTAssertTrue(appState.canNavigateToNextResult)

        appState.navigateToNextItem()
        XCTAssertTrue(appState.canNavigateToPreviousResult)
        XCTAssertFalse(appState.canNavigateToNextResult)
        XCTAssertTrue(registry.command(id: "nav.prevItem")!.isEnabled(appState))
        XCTAssertFalse(registry.command(id: "nav.nextItem")!.isEnabled(appState))
    }

    private func makeItem(index: Int) -> MediaItem {
        let id = UUID()
        let basePath = URL(fileURLWithPath: "/tmp/nodraw-command-parity-tests")
        return MediaItem(
            id: id,
            basePath: basePath,
            metadataFile: basePath.appendingPathComponent("\(id.uuidString).md"),
            mediaFiles: [basePath.appendingPathComponent("\(id.uuidString)-\(index).jpg")],
            metadata: MediaMetadata(
                source: URL(string: "https://example.com/\(id.uuidString)")!,
                platform: "web",
                author: "Author \(index)",
                archivedDate: Date(timeIntervalSince1970: TimeInterval(index))
            )
        )
    }
}
