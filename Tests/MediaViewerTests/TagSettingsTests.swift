import XCTest
@testable import MediaViewer

@MainActor
final class TagSettingsTests: XCTestCase {
    func testBackgroundQANeverOpensLegacyDefinitionDomains() {
        // Exercise the exact candidate policy used before UserDefaults(suiteName:).
        // No real legacy suite is opened by this regression test either.
        XCTAssertTrue(TagSettings.legacyDefinitionDomains(backgroundQA: true).isEmpty)
        XCTAssertEqual(TagSettings.legacyDefinitionDomains(backgroundQA: false), [
            "MediaViewer", "com.mediaviewer.app", "com.md.mediaviewer"
        ])
    }

    func testCanonicalDefinitionMigrationDeduplicatesAndRemapsHierarchy() {
        var retainedParent = TagDefinition(name: "Straße")
        retainedParent.sortOrder = 4
        var foldedDuplicate = TagDefinition(name: " STRASSE ")
        foldedDuplicate.sortOrder = 8
        var child = TagDefinition(name: "Nebenstraße")
        child.parentId = foldedDuplicate.id
        child.sortOrder = 3
        let retainedAccent = TagDefinition(name: "É")
        let decomposedDuplicate = TagDefinition(name: "E\u{301}")
        let blank = TagDefinition(name: "  \n")

        let migrated = TagSettings.canonicalizedDefinitions([
            retainedParent,
            foldedDuplicate,
            child,
            retainedAccent,
            decomposedDuplicate,
            blank
        ])

        XCTAssertEqual(migrated.definitions.count, 3)
        XCTAssertEqual(migrated.idRemap[foldedDuplicate.id], retainedParent.id)
        XCTAssertEqual(migrated.idRemap[decomposedDuplicate.id], retainedAccent.id)
        XCTAssertEqual(
            migrated.definitions.first(where: { $0.id == child.id })?.parentId,
            retainedParent.id
        )
        XCTAssertEqual(
            migrated.definitions.filter { TagCanonicalizer.key($0.name) == "strasse" }.count,
            1
        )
        XCTAssertEqual(
            migrated.definitions.filter { TagCanonicalizer.key($0.name) == "é" }.count,
            1
        )
    }

    func testCanonicalIdentityPreventsDuplicatesAndPreservesHierarchyLookup() {
        let settings = TagSettings.shared
        let snapshot = DefinitionSnapshot(settings)
        defer { snapshot.restore(to: settings) }

        var parent = TagDefinition(name: "Straße")
        parent.sortOrder = 0
        var child = TagDefinition(name: "Nebenstraße")
        child.parentId = parent.id
        child.sortOrder = 0
        settings.definitions = [parent, child]

        XCTAssertEqual(settings.ensureDefinitionsExist(for: ["STRASSE", " straße "]), 0)
        XCTAssertEqual(settings.ensureDefinitionsExist(for: ["É", "E\u{301}"]), 1)
        XCTAssertEqual(settings.allDescendantNames(ofTagNamed: "STRASSE"), ["Nebenstraße"])
        XCTAssertEqual(
            SidebarViewModel.mergedTagDisplayNames(
                databaseTags: ["STRASSE"],
                definitionTags: ["Straße"]
            ),
            ["Straße"]
        )
    }

    func testNameValidationReportsCanonicalCollisionWithoutChangingInput() {
        let settings = TagSettings.shared
        let snapshot = DefinitionSnapshot(settings)
        defer { snapshot.restore(to: settings) }
        let existing = TagDefinition(name: "Élan")
        settings.definitions = [existing]

        XCTAssertEqual(
            settings.validateName("  e\u{301}LAN  "),
            .duplicate(existingName: "Élan")
        )
        XCTAssertEqual(settings.validateName("  New Tag  "), .valid("New Tag"))
        XCTAssertEqual(settings.validateName(" \n "), .empty)
        XCTAssertEqual(settings.definitions, [existing])
    }

    func testCanonicalMigrationDropsInvalidAndDuplicateSiblingShortcutsOnly() {
        var first = TagDefinition(name: "First")
        first.shortcutKey = "1"
        first.sortOrder = 0
        var duplicate = TagDefinition(name: "Duplicate")
        duplicate.shortcutKey = "1"
        duplicate.sortOrder = 1
        var invalid = TagDefinition(name: "Invalid")
        invalid.shortcutKey = "!"
        invalid.sortOrder = 2
        var child = TagDefinition(name: "Child")
        child.parentId = first.id
        child.shortcutKey = "1"

        let migrated = TagSettings.canonicalizedDefinitions([first, duplicate, invalid, child]).definitions

        XCTAssertEqual(migrated.first(where: { $0.id == first.id })?.shortcutKey, "1")
        XCTAssertNil(migrated.first(where: { $0.id == duplicate.id })?.shortcutKey)
        XCTAssertNil(migrated.first(where: { $0.id == invalid.id })?.shortcutKey)
        XCTAssertEqual(migrated.first(where: { $0.id == child.id })?.shortcutKey, "1")
    }

    func testLayoutPreferencePersistsAndDefaultsToSunburst() {
        let settings = TagSettings.shared
        let snapshot = PreferenceSnapshot(settings)
        defer { snapshot.restore(to: settings) }

        XCTAssertEqual(TagOverlayLayout.defaultLayout, .sunburst)
        for layout in TagOverlayLayout.allCases {
            settings.layout = layout
            XCTAssertEqual(UserDefaults.standard.string(forKey: TagSettings.layoutKey), layout.rawValue)
        }
    }

    func testGridScaleClampsToSupportedRange() {
        let settings = TagSettings.shared
        let snapshot = PreferenceSnapshot(settings)
        defer { snapshot.restore(to: settings) }

        settings.gridScale = 0.1
        XCTAssertEqual(settings.gridScale, 0.75)

        settings.gridScale = 2.0
        XCTAssertEqual(settings.gridScale, 1.45)
    }

    func testResetPreferencesRestoresTaggingDefaults() {
        let settings = TagSettings.shared
        let snapshot = PreferenceSnapshot(settings)
        defer { snapshot.restore(to: settings) }

        settings.modifierKey = .command
        settings.gridScale = 1.35
        settings.layout = .grid

        settings.resetPreferencesToDefaults()

        XCTAssertEqual(settings.modifierKey, .option)
        XCTAssertEqual(settings.gridScale, 1.0)
        XCTAssertEqual(settings.layout, .sunburst)
    }

    private struct PreferenceSnapshot {
        let modifierKey: TagSettings.ModifierKey
        let gridScale: Double
        let layout: TagOverlayLayout

        @MainActor
        init(_ settings: TagSettings) {
            modifierKey = settings.modifierKey
            gridScale = settings.gridScale
            layout = settings.layout
        }

        @MainActor
        func restore(to settings: TagSettings) {
            settings.modifierKey = modifierKey
            settings.gridScale = gridScale
            settings.layout = layout
        }
    }

    private struct DefinitionSnapshot {
        let definitions: [TagDefinition]
        let recentTagIds: [UUID]

        @MainActor
        init(_ settings: TagSettings) {
            definitions = settings.definitions
            recentTagIds = settings.recentTagIds
        }

        @MainActor
        func restore(to settings: TagSettings) {
            settings.definitions = definitions
            settings.recentTagIds = recentTagIds
        }
    }
}
