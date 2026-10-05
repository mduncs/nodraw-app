import Foundation
import AppKit
import Observation

enum AnnotationColorDefaults {
    static var systemAccentRGBA: Int {
        let color = NSColor.controlAccentColor
            .withAlphaComponent(1)
            .usingColorSpace(.sRGB) ?? NSColor.systemBlue
        let red = byte(color.redComponent)
        let green = byte(color.greenComponent)
        let blue = byte(color.blueComponent)
        return (red << 24) | (green << 16) | (blue << 8) | 0xFF
    }

    private static func byte(_ component: CGFloat) -> Int {
        Int((max(0, min(1, component)) * 255).rounded())
    }
}

struct ImportTagPreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var tags: [String]
    var isDefault: Bool

    init(id: UUID = UUID(), name: String, tags: [String], isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.tags = tags
        self.isDefault = isDefault
    }
}

@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    static let minimumTaggingHUDWidth = 320.0
    static let defaultTaggingHUDWidth = 600.0
    static let maximumTaggingHUDWidth = 900.0

    static func clampedTaggingHUDWidth(_ width: Double) -> Double {
        min(max(width, minimumTaggingHUDWidth), maximumTaggingHUDWidth)
    }

    private let defaults = UserDefaults.standard

    /// Keys "Reset all settings" must leave alone. Import presets are user-authored
    /// data; the archive directory selects which library opens; the server and
    /// login-item flags mirror launchd / SMAppService registrations that deleting a
    /// preference cannot undo, so clearing them would only desync the toggles.
    static let resetPreservedKeys: Set<String> = [
        "importTagPresets",
        "downloadServerEnabled",
        "downloadServerArchiveDir",
        "launchAtLogin"
    ]

    /// Preferences cleared by `resetToDefaults()`.
    static let managedKeys: [String] = [
        "videoAutoplay",
        "videoMuteByDefault",
        "videoHoverPreview",
        "videoLoopEnabled",
        "hideJunkItems",
        "hideSafetyFlagged",
        "thumbnailQualityTier",
        "defaultSortOrder",
        "lastSortOrder",
        "defaultSearchScope",
        "showFocusSidebar",
        "deleteFilesFromDisk",
        "skipDeleteConfirmation",
        "canvasSnapToGrid",
        "canvasGridSize",
        "annotationDefaultStrokeWidth",
        "annotationDefaultColor",
        "annotationEnhancedEditor",
        "duplicateHashThreshold",
        "duplicateVectorThreshold",
        "autoScanOnImport",
        BackgroundProcessingIntensity.defaultsKey,
        "fsrsDeckSize",
        "fsrsRetentionTarget",
        "clusterCount",
        "showDuplicateFolderSidebar",
        "showDuplicateMetadataPanel",
        "sidebarFoldersExpanded",
        "sidebarSmartFoldersExpanded",
        "sidebarBoardsExpanded",
        "sidebarCanvasExpanded",
        "sidebarVisualExpanded",
        "sidebarPlatformsExpanded",
        "sidebarTagsExpanded",
        "sidebarTriageExpanded",
        "sidebarColorsExpanded",
        "showSidebarColors",
        "export.includeCaption",
        "export.includeSource",
        "export.includeCreator",
        "export.includeCopyright",
        "export.includeKeywords",
        "export.includeDate",
        "export.outputFormat",
        "export.jpegQuality",
        "taggingHUDHelpUseCount",
        "taggingHUDWidth",
        "taggingQueueResumeItemID",
        "tagTreeExpandedNodeIDs",
        "tagModifierKey",
        "tagGridThreshold",
        "tagAlwaysUseGrid",
        "tagAlwaysUseRadio"
    ]

    private var resetTick: Int = 0

    private init() { }

    func resetToDefaults() {
        withMutation(keyPath: \.resetTick) {
            for key in Self.managedKeys {
                defaults.removeObject(forKey: key)
            }
            TagSettings.shared.resetPreferencesToDefaults()
            resetTick &+= 1
        }
    }

    var videoAutoplay: Bool {
        get { boolSetting(\.videoAutoplay, key: "videoAutoplay", default: true) }
        set { setBoolSetting(\.videoAutoplay, key: "videoAutoplay", value: newValue) }
    }

    var videoMuteByDefault: Bool {
        get { boolSetting(\.videoMuteByDefault, key: "videoMuteByDefault", default: true) }
        set { setBoolSetting(\.videoMuteByDefault, key: "videoMuteByDefault", value: newValue) }
    }

    var videoHoverPreview: Bool {
        get { boolSetting(\.videoHoverPreview, key: "videoHoverPreview", default: true) }
        set { setBoolSetting(\.videoHoverPreview, key: "videoHoverPreview", value: newValue) }
    }

    var videoLoopEnabled: Bool {
        get { boolSetting(\.videoLoopEnabled, key: "videoLoopEnabled", default: false) }
        set { setBoolSetting(\.videoLoopEnabled, key: "videoLoopEnabled", value: newValue) }
    }

    var hideJunkItems: Bool {
        get { boolSetting(\.hideJunkItems, key: "hideJunkItems", default: true) }
        set { setBoolSetting(\.hideJunkItems, key: "hideJunkItems", value: newValue) }
    }

    var hideSafetyFlagged: Bool {
        get { boolSetting(\.hideSafetyFlagged, key: "hideSafetyFlagged", default: true) }
        set { setBoolSetting(\.hideSafetyFlagged, key: "hideSafetyFlagged", value: newValue) }
    }

    var thumbnailQualityTier: String {
        get { stringSetting(\.thumbnailQualityTier, key: "thumbnailQualityTier", default: "medium") }
        set { setStringSetting(\.thumbnailQualityTier, key: "thumbnailQualityTier", value: newValue) }
    }

    var defaultSortOrder: String {
        get { stringSetting(\.defaultSortOrder, key: "defaultSortOrder", default: "date_desc") }
        set { setStringSetting(\.defaultSortOrder, key: "defaultSortOrder", value: newValue) }
    }

    var lastSortOrder: SortOrder {
        get {
            access(keyPath: \.lastSortOrder)
            let rawValue = defaults.string(forKey: "lastSortOrder")
                ?? defaults.string(forKey: "defaultSortOrder")
                ?? SortOrder.archivedDateDescending.rawValue
            return SortOrder(rawValue: rawValue) ?? .archivedDateDescending
        }
        set {
            withMutation(keyPath: \.lastSortOrder) {
                defaults.set(newValue.rawValue, forKey: "lastSortOrder")
            }
        }
    }

    var defaultSearchScope: SearchScope {
        get {
            access(keyPath: \.defaultSearchScope)
            let rawValue = defaults.string(forKey: "defaultSearchScope") ?? SearchScope.all.rawValue
            return SearchScope(rawValue: rawValue) ?? .all
        }
        set {
            withMutation(keyPath: \.defaultSearchScope) {
                defaults.set(newValue.rawValue, forKey: "defaultSearchScope")
            }
        }
    }

    var showFocusSidebar: Bool {
        get { boolSetting(\.showFocusSidebar, key: "showFocusSidebar", default: true) }
        set { setBoolSetting(\.showFocusSidebar, key: "showFocusSidebar", value: newValue) }
    }

    var deleteFilesFromDisk: Bool {
        get { boolSetting(\.deleteFilesFromDisk, key: "deleteFilesFromDisk", default: false) }
        set { setBoolSetting(\.deleteFilesFromDisk, key: "deleteFilesFromDisk", value: newValue) }
    }

    var skipDeleteConfirmation: Bool {
        get { boolSetting(\.skipDeleteConfirmation, key: "skipDeleteConfirmation", default: false) }
        set { setBoolSetting(\.skipDeleteConfirmation, key: "skipDeleteConfirmation", value: newValue) }
    }

    var launchAtLogin: Bool {
        get { boolSetting(\.launchAtLogin, key: "launchAtLogin", default: false) }
        set { setBoolSetting(\.launchAtLogin, key: "launchAtLogin", value: newValue) }
    }

    var canvasSnapToGrid: Bool {
        get { boolSetting(\.canvasSnapToGrid, key: "canvasSnapToGrid", default: false) }
        set { setBoolSetting(\.canvasSnapToGrid, key: "canvasSnapToGrid", value: newValue) }
    }

    var canvasGridSize: Int {
        get { positiveIntSetting(\.canvasGridSize, key: "canvasGridSize", default: 20) }
        set { setIntSetting(\.canvasGridSize, key: "canvasGridSize", value: max(8, newValue)) }
    }

    var annotationDefaultStrokeWidth: Int {
        get { positiveIntSetting(\.annotationDefaultStrokeWidth, key: "annotationDefaultStrokeWidth", default: 3) }
        set { setIntSetting(\.annotationDefaultStrokeWidth, key: "annotationDefaultStrokeWidth", value: max(1, newValue)) }
    }

    var annotationDefaultColor: Int {
        get {
            access(keyPath: \.annotationDefaultColor)
            guard defaults.object(forKey: "annotationDefaultColor") != nil else {
                return AnnotationColorDefaults.systemAccentRGBA
            }
            let value = defaults.integer(forKey: "annotationDefaultColor")
            return value > 0 ? value : AnnotationColorDefaults.systemAccentRGBA
        }
        set { setIntSetting(\.annotationDefaultColor, key: "annotationDefaultColor", value: newValue) }
    }

    var annotationDefaultColorUsesSystemAccent: Bool {
        access(keyPath: \.annotationDefaultColor)
        return defaults.object(forKey: "annotationDefaultColor") == nil
    }

    func useSystemAnnotationDefaultColor() {
        withMutation(keyPath: \.annotationDefaultColor) {
            defaults.removeObject(forKey: "annotationDefaultColor")
        }
    }

    var annotationEnhancedEditor: Bool {
        get { boolSetting(\.annotationEnhancedEditor, key: "annotationEnhancedEditor", default: true) }
        set { setBoolSetting(\.annotationEnhancedEditor, key: "annotationEnhancedEditor", value: newValue) }
    }

    var duplicateHashThreshold: Int {
        get { positiveIntSetting(\.duplicateHashThreshold, key: "duplicateHashThreshold", default: 6) }
        set { setIntSetting(\.duplicateHashThreshold, key: "duplicateHashThreshold", value: max(1, newValue)) }
    }

    var duplicateVectorThreshold: Double {
        get { positiveDoubleSetting(\.duplicateVectorThreshold, key: "duplicateVectorThreshold", default: 0.92) }
        set { setDoubleSetting(\.duplicateVectorThreshold, key: "duplicateVectorThreshold", value: min(max(newValue, 0.5), 1.0)) }
    }

    var autoScanOnImport: Bool {
        get { boolSetting(\.autoScanOnImport, key: "autoScanOnImport", default: false) }
        set { setBoolSetting(\.autoScanOnImport, key: "autoScanOnImport", value: newValue) }
    }

    var backgroundProcessingIntensity: BackgroundProcessingIntensity {
        get {
            access(keyPath: \.backgroundProcessingIntensity)
            let rawValue = defaults.string(forKey: BackgroundProcessingIntensity.defaultsKey)
                ?? BackgroundProcessingIntensity.defaultValue.rawValue
            return BackgroundProcessingIntensity(rawValue: rawValue) ?? .defaultValue
        }
        set {
            withMutation(keyPath: \.backgroundProcessingIntensity) {
                defaults.set(newValue.rawValue, forKey: BackgroundProcessingIntensity.defaultsKey)
            }
        }
    }

    var fsrsDeckSize: Int {
        get { positiveIntSetting(\.fsrsDeckSize, key: "fsrsDeckSize", default: 50) }
        set { setIntSetting(\.fsrsDeckSize, key: "fsrsDeckSize", value: max(10, newValue)) }
    }

    var fsrsRetentionTarget: Double {
        get { positiveDoubleSetting(\.fsrsRetentionTarget, key: "fsrsRetentionTarget", default: 0.9) }
        set { setDoubleSetting(\.fsrsRetentionTarget, key: "fsrsRetentionTarget", value: min(max(newValue, 0.5), 0.99)) }
    }

    var clusterCount: Int {
        get { positiveIntSetting(\.clusterCount, key: "clusterCount", default: 20) }
        set { setIntSetting(\.clusterCount, key: "clusterCount", value: max(4, newValue)) }
    }

    var downloadServerEnabled: Bool {
        get { boolSetting(\.downloadServerEnabled, key: "downloadServerEnabled", default: false) }
        set { setBoolSetting(\.downloadServerEnabled, key: "downloadServerEnabled", value: newValue) }
    }

    var downloadServerArchiveDir: String {
        get {
            access(keyPath: \.downloadServerArchiveDir)
            return ArchivePathStore.currentPath(defaults: defaults).path
        }
        set {
            withMutation(keyPath: \.downloadServerArchiveDir) {
                let normalized = URL(fileURLWithPath: newValue).standardizedFileURL
                ArchivePathStore.setCurrentPath(normalized, defaults: defaults)
            }
        }
    }

    // MARK: - Duplicate Review

    var showDuplicateFolderSidebar: Bool {
        get { boolSetting(\.showDuplicateFolderSidebar, key: "showDuplicateFolderSidebar", default: true) }
        set { setBoolSetting(\.showDuplicateFolderSidebar, key: "showDuplicateFolderSidebar", value: newValue) }
    }

    var showDuplicateMetadataPanel: Bool {
        get { boolSetting(\.showDuplicateMetadataPanel, key: "showDuplicateMetadataPanel", default: false) }
        set { setBoolSetting(\.showDuplicateMetadataPanel, key: "showDuplicateMetadataPanel", value: newValue) }
    }

    // MARK: - Sidebar

    var sidebarFoldersExpanded: Bool {
        get { boolSetting(\.sidebarFoldersExpanded, key: "sidebarFoldersExpanded", default: true) }
        set { setBoolSetting(\.sidebarFoldersExpanded, key: "sidebarFoldersExpanded", value: newValue) }
    }

    var sidebarSmartFoldersExpanded: Bool {
        get { boolSetting(\.sidebarSmartFoldersExpanded, key: "sidebarSmartFoldersExpanded", default: true) }
        set { setBoolSetting(\.sidebarSmartFoldersExpanded, key: "sidebarSmartFoldersExpanded", value: newValue) }
    }

    var sidebarBoardsExpanded: Bool {
        get { boolSetting(\.sidebarBoardsExpanded, key: "sidebarBoardsExpanded", default: true) }
        set { setBoolSetting(\.sidebarBoardsExpanded, key: "sidebarBoardsExpanded", value: newValue) }
    }

    var sidebarCanvasExpanded: Bool {
        get { boolSetting(\.sidebarCanvasExpanded, key: "sidebarCanvasExpanded", default: true) }
        set { setBoolSetting(\.sidebarCanvasExpanded, key: "sidebarCanvasExpanded", value: newValue) }
    }

    var sidebarVisualExpanded: Bool {
        get { boolSetting(\.sidebarVisualExpanded, key: "sidebarVisualExpanded", default: true) }
        set { setBoolSetting(\.sidebarVisualExpanded, key: "sidebarVisualExpanded", value: newValue) }
    }

    var sidebarPlatformsExpanded: Bool {
        get { boolSetting(\.sidebarPlatformsExpanded, key: "sidebarPlatformsExpanded", default: true) }
        set { setBoolSetting(\.sidebarPlatformsExpanded, key: "sidebarPlatformsExpanded", value: newValue) }
    }

    var sidebarTagsExpanded: Bool {
        get { boolSetting(\.sidebarTagsExpanded, key: "sidebarTagsExpanded", default: true) }
        set { setBoolSetting(\.sidebarTagsExpanded, key: "sidebarTagsExpanded", value: newValue) }
    }

    var sidebarTriageExpanded: Bool {
        get { boolSetting(\.sidebarTriageExpanded, key: "sidebarTriageExpanded", default: true) }
        set { setBoolSetting(\.sidebarTriageExpanded, key: "sidebarTriageExpanded", value: newValue) }
    }

    var sidebarColorsExpanded: Bool {
        get { boolSetting(\.sidebarColorsExpanded, key: "sidebarColorsExpanded", default: false) }
        set { setBoolSetting(\.sidebarColorsExpanded, key: "sidebarColorsExpanded", value: newValue) }
    }

    var showSidebarColors: Bool {
        get { boolSetting(\.showSidebarColors, key: "showSidebarColors", default: false) }
        set { setBoolSetting(\.showSidebarColors, key: "showSidebarColors", value: newValue) }
    }

    // MARK: - Export Options

    var exportIncludeCaption: Bool {
        get { boolSetting(\.exportIncludeCaption, key: "export.includeCaption", default: true) }
        set { setBoolSetting(\.exportIncludeCaption, key: "export.includeCaption", value: newValue) }
    }

    var exportIncludeSource: Bool {
        get { boolSetting(\.exportIncludeSource, key: "export.includeSource", default: true) }
        set { setBoolSetting(\.exportIncludeSource, key: "export.includeSource", value: newValue) }
    }

    var exportIncludeCreator: Bool {
        get { boolSetting(\.exportIncludeCreator, key: "export.includeCreator", default: true) }
        set { setBoolSetting(\.exportIncludeCreator, key: "export.includeCreator", value: newValue) }
    }

    var exportIncludeCopyright: Bool {
        get { boolSetting(\.exportIncludeCopyright, key: "export.includeCopyright", default: false) }
        set { setBoolSetting(\.exportIncludeCopyright, key: "export.includeCopyright", value: newValue) }
    }

    var exportIncludeKeywords: Bool {
        get { boolSetting(\.exportIncludeKeywords, key: "export.includeKeywords", default: true) }
        set { setBoolSetting(\.exportIncludeKeywords, key: "export.includeKeywords", value: newValue) }
    }

    var exportIncludeDate: Bool {
        get { boolSetting(\.exportIncludeDate, key: "export.includeDate", default: true) }
        set { setBoolSetting(\.exportIncludeDate, key: "export.includeDate", value: newValue) }
    }

    var exportOutputFormat: String {
        get { stringSetting(\.exportOutputFormat, key: "export.outputFormat", default: ExportFormat.jpeg.rawValue) }
        set { setStringSetting(\.exportOutputFormat, key: "export.outputFormat", value: newValue) }
    }

    var exportJpegQuality: Double {
        get { positiveDoubleSetting(\.exportJpegQuality, key: "export.jpegQuality", default: 0.92) }
        set { setDoubleSetting(\.exportJpegQuality, key: "export.jpegQuality", value: newValue) }
    }

    // MARK: - Tagging HUD

    var taggingHUDHelpUseCount: Int {
        get { intSetting(\.taggingHUDHelpUseCount, key: "taggingHUDHelpUseCount", default: 0) }
        set { setIntSetting(\.taggingHUDHelpUseCount, key: "taggingHUDHelpUseCount", value: newValue) }
    }

    var taggingHUDWidth: Double {
        get {
            let stored = positiveDoubleSetting(
                \.taggingHUDWidth,
                key: "taggingHUDWidth",
                default: Self.defaultTaggingHUDWidth
            )
            return Self.clampedTaggingHUDWidth(stored)
        }
        set {
            setDoubleSetting(
                \.taggingHUDWidth,
                key: "taggingHUDWidth",
                value: Self.clampedTaggingHUDWidth(newValue)
            )
        }
    }

    /// Last visible item in an interrupted tagging queue. A new queue only resumes it when
    /// the item is still present in the requested scope.
    var taggingQueueResumeItemID: UUID? {
        get {
            access(keyPath: \.taggingQueueResumeItemID)
            guard let rawValue = defaults.string(forKey: "taggingQueueResumeItemID") else { return nil }
            return UUID(uuidString: rawValue)
        }
        set {
            withMutation(keyPath: \.taggingQueueResumeItemID) {
                if let newValue {
                    defaults.set(newValue.uuidString, forKey: "taggingQueueResumeItemID")
                } else {
                    defaults.removeObject(forKey: "taggingQueueResumeItemID")
                }
            }
        }
    }

    /// Expanded rows in the Settings tag hierarchy, stored by stable definition UUID.
    var tagTreeExpandedNodeIDs: Set<UUID> {
        get {
            access(keyPath: \.tagTreeExpandedNodeIDs)
            let rawValues = defaults.stringArray(forKey: "tagTreeExpandedNodeIDs") ?? []
            return Set(rawValues.compactMap(UUID.init(uuidString:)))
        }
        set {
            withMutation(keyPath: \.tagTreeExpandedNodeIDs) {
                defaults.set(newValue.map(\.uuidString).sorted(), forKey: "tagTreeExpandedNodeIDs")
            }
        }
    }

    // MARK: - Import Tag Presets

    var importTagPresets: [ImportTagPreset] {
        get {
            access(keyPath: \.importTagPresets)
            guard let data = defaults.data(forKey: "importTagPresets"),
                  let decoded = try? JSONDecoder().decode([ImportTagPreset].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            withMutation(keyPath: \.importTagPresets) {
                defaults.set(try? JSONEncoder().encode(newValue), forKey: "importTagPresets")
            }
        }
    }

    var defaultImportPreset: ImportTagPreset? {
        importTagPresets.first { $0.isDefault }
    }

    func setDefaultPreset(_ presetId: UUID?) {
        var presets = importTagPresets
        for i in presets.indices { presets[i].isDefault = (presets[i].id == presetId) }
        importTagPresets = presets
    }

    // MARK: - Shared Accessors

    private func boolSetting(
        _ keyPath: KeyPath<SettingsStore, Bool>,
        key: String,
        default defaultValue: Bool
    ) -> Bool {
        access(keyPath: keyPath)
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private func setBoolSetting(
        _ keyPath: WritableKeyPath<SettingsStore, Bool>,
        key: String,
        value: Bool
    ) {
        withMutation(keyPath: keyPath) {
            defaults.set(value, forKey: key)
        }
    }

    private func stringSetting(
        _ keyPath: KeyPath<SettingsStore, String>,
        key: String,
        default defaultValue: String
    ) -> String {
        access(keyPath: keyPath)
        return defaults.string(forKey: key) ?? defaultValue
    }

    private func setStringSetting(
        _ keyPath: WritableKeyPath<SettingsStore, String>,
        key: String,
        value: String
    ) {
        withMutation(keyPath: keyPath) {
            defaults.set(value, forKey: key)
        }
    }

    private func intSetting(
        _ keyPath: KeyPath<SettingsStore, Int>,
        key: String,
        default defaultValue: Int
    ) -> Int {
        access(keyPath: keyPath)
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.integer(forKey: key)
    }

    private func positiveIntSetting(
        _ keyPath: KeyPath<SettingsStore, Int>,
        key: String,
        default defaultValue: Int
    ) -> Int {
        let value = intSetting(keyPath, key: key, default: defaultValue)
        return value > 0 ? value : defaultValue
    }

    private func setIntSetting(
        _ keyPath: WritableKeyPath<SettingsStore, Int>,
        key: String,
        value: Int
    ) {
        withMutation(keyPath: keyPath) {
            defaults.set(value, forKey: key)
        }
    }

    private func positiveDoubleSetting(
        _ keyPath: KeyPath<SettingsStore, Double>,
        key: String,
        default defaultValue: Double
    ) -> Double {
        access(keyPath: keyPath)
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        let value = defaults.double(forKey: key)
        return value > 0 ? value : defaultValue
    }

    private func setDoubleSetting(
        _ keyPath: WritableKeyPath<SettingsStore, Double>,
        key: String,
        value: Double
    ) {
        withMutation(keyPath: keyPath) {
            defaults.set(value, forKey: key)
        }
    }
}
