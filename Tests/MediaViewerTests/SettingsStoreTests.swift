import XCTest
@testable import MediaViewer

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testWP04QueryPreferencesPersistThroughSettingsStore() {
        let defaults = UserDefaults.standard
        let keys = ["lastSortOrder", "defaultSearchScope", "showSidebarColors"]
        let snapshot = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = snapshot[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        for key in keys {
            defaults.removeObject(forKey: key)
        }

        let settings = SettingsStore.shared
        XCTAssertEqual(settings.lastSortOrder, .archivedDateDescending)
        XCTAssertEqual(settings.defaultSearchScope, .all)
        XCTAssertFalse(settings.showSidebarColors)

        settings.lastSortOrder = .authorAscending
        settings.defaultSearchScope = .ocrOnly
        settings.showSidebarColors = true

        XCTAssertEqual(defaults.string(forKey: "lastSortOrder"), SortOrder.authorAscending.rawValue)
        XCTAssertEqual(defaults.string(forKey: "defaultSearchScope"), SearchScope.ocrOnly.rawValue)
        XCTAssertTrue(defaults.bool(forKey: "showSidebarColors"))
        XCTAssertEqual(settings.lastSortOrder, .authorAscending)
        XCTAssertEqual(settings.defaultSearchScope, .ocrOnly)
        XCTAssertTrue(settings.showSidebarColors)
    }

    func testTaggingHUDWidthPersistsAndClampsToUsableBounds() {
        let defaults = UserDefaults.standard
        let key = "taggingHUDWidth"
        let savedValue = defaults.object(forKey: key)
        defer {
            if let savedValue {
                defaults.set(savedValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        let settings = SettingsStore.shared
        XCTAssertEqual(settings.taggingHUDWidth, SettingsStore.defaultTaggingHUDWidth)

        settings.taggingHUDWidth = 720
        XCTAssertEqual(defaults.double(forKey: key), 720)
        XCTAssertEqual(settings.taggingHUDWidth, 720)

        settings.taggingHUDWidth = 100
        XCTAssertEqual(settings.taggingHUDWidth, SettingsStore.minimumTaggingHUDWidth)
        XCTAssertEqual(defaults.double(forKey: key), SettingsStore.minimumTaggingHUDWidth)

        settings.taggingHUDWidth = 2_000
        XCTAssertEqual(settings.taggingHUDWidth, SettingsStore.maximumTaggingHUDWidth)
        XCTAssertEqual(defaults.double(forKey: key), SettingsStore.maximumTaggingHUDWidth)
    }

    func testResetClearsPreferencesButKeepsUserDataAndSystemRegistrations() {
        let defaults = UserDefaults.standard
        let keys = SettingsStore.managedKeys + Array(SettingsStore.resetPreservedKeys)
        let snapshot = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        let tagSettings = TagSettings.shared
        let savedTagPrefs = (tagSettings.modifierKey, tagSettings.layout, tagSettings.gridScale)
        defer {
            for key in keys {
                if let value = snapshot[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            (tagSettings.modifierKey, tagSettings.layout, tagSettings.gridScale) = savedTagPrefs
        }

        XCTAssertTrue(SettingsStore.resetPreservedKeys.isDisjoint(with: SettingsStore.managedKeys))

        let settings = SettingsStore.shared
        let preset = ImportTagPreset(name: "Screenshots", tags: ["Screenshot"])
        settings.importTagPresets = [preset]
        settings.launchAtLogin = true
        settings.downloadServerEnabled = true
        let archivePath = settings.downloadServerArchiveDir
        settings.hideJunkItems = true
        settings.deleteFilesFromDisk = true

        settings.resetToDefaults()

        XCTAssertNil(defaults.object(forKey: "hideJunkItems"))
        XCTAssertNil(defaults.object(forKey: "deleteFilesFromDisk"))
        XCTAssertFalse(settings.deleteFilesFromDisk)
        XCTAssertEqual(settings.importTagPresets, [preset])
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertTrue(settings.downloadServerEnabled)
        XCTAssertEqual(settings.downloadServerArchiveDir, archivePath)
    }

    func testTaggingResumeAndExpandedTreeIDsRoundTrip() {
        let defaults = UserDefaults.standard
        let keys = ["taggingQueueResumeItemID", "tagTreeExpandedNodeIDs"]
        let snapshot = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = snapshot[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let settings = SettingsStore.shared
        let resumeID = UUID()
        let expandedIDs: Set<UUID> = [UUID(), UUID()]
        settings.taggingQueueResumeItemID = resumeID
        settings.tagTreeExpandedNodeIDs = expandedIDs

        XCTAssertEqual(settings.taggingQueueResumeItemID, resumeID)
        XCTAssertEqual(settings.tagTreeExpandedNodeIDs, expandedIDs)

        settings.taggingQueueResumeItemID = nil
        XCTAssertNil(settings.taggingQueueResumeItemID)
    }
}
