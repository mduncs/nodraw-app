import SwiftUI

struct OrganizationSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @Environment(SettingsStore.self) private var settings
    @ObservedObject private var tagSettings = TagSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Tag Hierarchy
                SettingsSection(
                    title: "Tag Hierarchy",
                    icon: "tag",
                    description: "Drag rows to nest or reorder. Rename and delete apply to every tagged item; delete shows the item count first and Edit ▸ Undo restores it."
                ) {
                    // The app's live store, so library views refresh and its write-back
                    // queue owns the sidecar edits.
                    TagTreeEditor(
                        tagSettings: tagSettings,
                        mediaStore: appState.mediaStore,
                        undoStack: appState.undoStack
                    )
                }

                // Tagging Behavior
                SettingsSection(
                    title: "Hold-to-Tag Selector",
                    icon: "hand.tap",
                    description: "The tag picker that appears while a modifier key is held over the grid or in focus view. The tagging queue HUD uses its own number/letter keys."
                ) {
                    // Modifier key picker
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Modifier key")
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                            Text("Hold over the grid or in focus view to open the selector; release over a tag to toggle it")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $tagSettings.modifierKey) {
                            ForEach(TagSettings.ModifierKey.allCases, id: \.self) { key in
                                Text(key.displayName).tag(key)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }

                    // Layout preference
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tag selector layout")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)

                        Picker("Layout", selection: $tagSettings.layout) {
                            ForEach(TagOverlayLayout.allCases) { layout in
                                Text(layout.title).tag(layout)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 280)

                        Text(tagSettings.layout.summary + " Every layout filters as you type and shows recent tags.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Text("Size")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            ForEach(TagGridSizePreset.allCases, id: \.self) { preset in
                                Button(preset.title) {
                                    tagSettings.gridScale = preset.scale
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .foregroundStyle(preset.isSelected(scale: tagSettings.gridScale) ? Color.accentOrange : .secondary)
                                .help("Selector size \(preset.title) · also in the selector footer")
                            }
                            Text("\(Int((tagSettings.gridScale * 100).rounded()))%")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Tag Rules
                SettingsSection(
                    title: "Tag Rules",
                    icon: "wand.and.rays",
                    description: "Enabled rules tag new items as they are added, by origin (subreddit, board, channel, artist, platform, source tag) or on-device analysis labels."
                ) {
                    TagRulesSettingsView(mediaStore: appState.mediaStore)
                }

                SettingsSection(
                    title: "Sidebar",
                    icon: "sidebar.left",
                    description: "Choose which optional library sections appear in the sidebar."
                ) {
                    SettingsToggle(
                        "Show Colors section",
                        description: "Restore the legacy sidebar color filters. Top-bar color filtering remains available either way.",
                        isOn: Binding(
                            get: { settings.showSidebarColors },
                            set: { settings.showSidebarColors = $0 }
                        )
                    )
                }

                // Duplicate Detection
                SettingsSection(
                    title: "Duplicate Detection",
                    icon: "doc.on.doc",
                    description: "How the duplicate scan groups items. Review decides what happens; scanning never merges or deletes."
                ) {
                    DuplicateSettingsContent(settings: settings) {
                        appState.findDuplicates()
                    }
                }

                // Rediscover
                if FeatureFlags.rediscover {
                    SettingsSection(
                        title: "Rediscover",
                        icon: "clock.arrow.2.circlepath",
                        description: "Surface old media using spaced repetition."
                    ) {
                        RediscoverSettingsContent(settings: settings)
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Duplicate Settings Content

private struct DuplicateSettingsContent: View {
    let settings: SettingsStore
    let openReview: () -> Void

    /// `DuplicateDetector` caps the fingerprint distance at 8 bits; larger stored
    /// values behave exactly like 8.
    private static let maxEffectiveHashDistance = 8

    private enum SensitivityPreset: String, CaseIterable {
        case low = "Low"
        case medium = "Medium"
        case high = "High"

        var hashThreshold: Int {
            switch self {
            case .low: return 10
            case .medium: return 6
            case .high: return 4
            }
        }

        var vectorThreshold: Double {
            switch self {
            case .low: return 0.85
            case .medium: return 0.92
            case .high: return 0.95
            }
        }

        var description: String {
            switch self {
            case .low: return "Loosest: more look-alikes, more false matches"
            case .medium: return "Balanced: catches most re-saves and resizes"
            case .high: return "Strict: only near-identical images"
            }
        }
    }

    private var effectiveHashDistance: Int {
        min(Self.maxEffectiveHashDistance, settings.duplicateHashThreshold)
    }

    /// Compared on the distance the scanner actually uses. The legacy visual
    /// similarity value no longer affects matching, so it is not part of the match.
    private var currentPreset: SensitivityPreset? {
        SensitivityPreset.allCases.first {
            min(Self.maxEffectiveHashDistance, $0.hashThreshold) == effectiveHashDistance
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // How it works info
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text("How it works")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("A scan finds two kinds of groups. Exact duplicates: every declared media file matches byte for byte (full-file SHA-256, same file count); the settings below never change these. Look-alikes: images whose perceptual fingerprints differ by at most the distance below. Semantic (AI) similarity is not used. Scans only suggest groups; nothing moves until you decide in Duplicate Review.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Duplicate Review", action: openReview)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Shows Duplicate Review in the main window")
                        .padding(.top, 2)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            // Sensitivity presets
            VStack(alignment: .leading, spacing: 10) {
                Text("Look-alike sensitivity")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)

                HStack(spacing: 10) {
                    ForEach(SensitivityPreset.allCases, id: \.rawValue) { preset in
                        PresetButton(
                            title: preset.rawValue,
                            description: preset.description,
                            isSelected: currentPreset == preset
                        ) {
                            settings.duplicateHashThreshold = preset.hashThreshold
                            settings.duplicateVectorThreshold = preset.vectorThreshold
                        }
                    }
                }

                if currentPreset == nil {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10))
                        Text("Custom settings")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Color.accentOrange)
                }
            }

            SettingsSlider(
                "Fingerprint distance",
                description: "Look-alikes only: maximum differing fingerprint bits (1–8). Lower is stricter; higher finds more possible look-alikes.",
                value: Binding(
                    get: { Double(effectiveHashDistance) },
                    set: { settings.duplicateHashThreshold = Int($0.rounded()) }
                ),
                in: 1...Double(Self.maxEffectiveHashDistance),
                format: "%.0f bits"
            )

            // Auto-scan toggle
            SettingsToggle(
                "Scan after file imports",
                description: "After files are dropped or imported, run a library-wide scan in the background. Browser downloads don't trigger it.",
                isOn: Binding(
                    get: { settings.autoScanOnImport },
                    set: { settings.autoScanOnImport = $0 }
                )
            )

            HStack {
                Spacer()
                Button("Reset Duplicate Defaults") {
                    settings.duplicateHashThreshold = SensitivityPreset.medium.hashThreshold
                    settings.duplicateVectorThreshold = SensitivityPreset.medium.vectorThreshold
                    settings.autoScanOnImport = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Rediscover Settings Content

private struct RediscoverSettingsContent: View {
    let settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // How it works info
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text("What is Rediscover?")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Uses spaced repetition to help you revisit saved media at optimal intervals.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            // Session size
            SettingsSlider(
                "Session size",
                description: "Maximum number of items per review session.",
                value: Binding(
                    get: { Double(settings.fsrsDeckSize) },
                    set: { settings.fsrsDeckSize = Int($0) }
                ),
                in: 10...200,
                format: "%.0f items"
            )

            // Review frequency (display as percentage)
            SettingsSlider(
                "Review frequency",
                description: frequencyDescription,
                value: Binding(
                    get: { settings.fsrsRetentionTarget * 100 },
                    set: { settings.fsrsRetentionTarget = $0 / 100 }
                ),
                in: 70...95,
                format: "%.0f%%"
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Examples")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("95%: frequent reviews, around 5 day intervals")
                Text("90%: balanced reviews, around 7 day intervals")
                Text("70%: relaxed reviews, around 14 day intervals")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Reset Rediscover Defaults") {
                    settings.fsrsDeckSize = 50
                    settings.fsrsRetentionTarget = 0.9
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var frequencyDescription: String {
        switch settings.fsrsRetentionTarget {
        case 0.93...1.0: return "Frequent reviews (~5 day intervals)"
        case 0.85..<0.93: return "Balanced reviews (~7 day intervals)"
        default: return "Relaxed reviews (~14 day intervals)"
        }
    }
}

// MARK: - Preset Button

private struct PresetButton: View {
    let title: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .secondary)

                Text(description)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentOrange.opacity(0.15) : (isHovered ? Color.white.opacity(0.06) : Color.white.opacity(0.04)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentOrange.opacity(0.5) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
