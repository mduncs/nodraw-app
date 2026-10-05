import SwiftUI

struct LibrarySettingsTab: View {
    @Environment(SettingsStore.self) private var settings
    @ObservedObject private var tagSettings = TagSettings.shared

    @State private var isAddingPreset = false
    @State private var newPresetName = ""
    @State private var newPresetTags: [String] = []
    @State private var newPresetTagInput = ""
    /// Last deleted preset and its position, kept so the deletion can be undone.
    @State private var recentlyDeletedPreset: (preset: ImportTagPreset, index: Int)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                archiveSection

                SettingsSection(
                    title: "Content Filters",
                    icon: "line.3.horizontal.decrease.circle",
                    description: "Hide items the on-device ML pipeline flagged. Items stay in the library and reappear when turned off."
                ) {
                    SettingsToggle(
                        "Hide junk items",
                        description: "Exclude low-signal captures and utility screenshots.",
                        isOn: Binding(
                            get: { settings.hideJunkItems },
                            set: { settings.hideJunkItems = $0 }
                        )
                    )

                    SettingsToggle(
                        "Hide safety-flagged items",
                        description: "Suppress items that were flagged during processing.",
                        isOn: Binding(
                            get: { settings.hideSafetyFlagged },
                            set: { settings.hideSafetyFlagged = $0 }
                        )
                    )
                }

                importTagPresetsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Archive

    /// Read-only: where the library lives. Otherwise the path was only visible from
    /// Downloads, and only while the download server was enabled.
    private var archiveSection: some View {
        let archive = ArchivePathStore.currentPath()
        return SettingsSection(
            title: "Archive",
            icon: "externaldrive",
            description: "The folder NoDraw watches. Each item is a sidecar .md file with its media beside it."
        ) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text(Self.abbreviatedPath(archive.path))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(archive.path)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([archive])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private static func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Import Tag Presets

    private var importTagPresetsSection: some View {
        SettingsSection(
            title: "Import Tag Presets",
            icon: "tag.square",
            description: "Offered when you drop files into the library. The starred preset is preselected; you can still change or skip tags per import."
        ) {
            let presets = settings.importTagPresets

            if let deleted = recentlyDeletedPreset {
                HStack(spacing: 8) {
                    Label("Deleted preset ‘\(deleted.preset.name)’", systemImage: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") { restoreDeletedPreset() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button {
                        recentlyDeletedPreset = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Dismiss")
                }
            }

            if presets.isEmpty && !isAddingPreset {
                Text("No presets yet. Add one to auto-tag imported files.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            ForEach(presets) { preset in
                presetRow(preset)
            }

            if isAddingPreset {
                addPresetForm
            } else {
                Button {
                    isAddingPreset = true
                } label: {
                    Label("Add Preset", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentOrange)
            }
        }
    }

    private func presetRow(_ preset: ImportTagPreset) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(preset.name)
                        .font(.subheadline.weight(.medium))
                    if preset.isDefault {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                    }
                }

                HStack(spacing: 4) {
                    ForEach(preset.tags.prefix(6), id: \.self) { tag in
                        TagChip(name: tag, size: .small)
                    }
                    if preset.tags.count > 6 {
                        Text("+\(preset.tags.count - 6)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button {
                let newDefault: UUID? = preset.isDefault ? nil : preset.id
                settings.setDefaultPreset(newDefault)
            } label: {
                Image(systemName: preset.isDefault ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(preset.isDefault ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(preset.isDefault ? "Remove as default" : "Set as default")

            Button {
                deletePreset(preset)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete preset (tags already on items are not affected)")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    private var addPresetForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )

            if !newPresetTags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(newPresetTags, id: \.self) { tag in
                        TagChip(name: tag, size: .small, onRemove: { newPresetTags.removeAll { $0 == tag } })
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Add tag…", text: $newPresetTagInput)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.06))
                    )
                    .onSubmit { addTagToNewPreset() }

                Button { addTagToNewPreset() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Color.accentOrange, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(newPresetTagInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            let suggestions = presetTagSuggestions
            if !suggestions.isEmpty {
                HStack(spacing: 4) {
                    ForEach(suggestions, id: \.definition.id) { match in
                        Button {
                            addTagToNewPreset(match.definition.name)
                        } label: {
                            TagChip(name: match.definition.name, size: .small, symbol: "plus")
                        }
                        .buttonStyle(.plain)
                        .help(match.ancestorLabel.isEmpty ? "Existing tag" : "Existing tag in \(match.ancestorLabel)")
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Save") {
                    saveNewPreset()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentOrange)
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty || newPresetTags.isEmpty)

                Button("Cancel") {
                    resetAddForm()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentOrange.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Helpers

    private var presetTagSuggestions: [TagDefinitionSearch.Match] {
        let excluded = Set(tagSettings.definitions
            .filter { definition in newPresetTags.contains { TagCanonicalizer.key($0) == TagCanonicalizer.key(definition.name) } }
            .map(\.id))
        return TagDefinitionSearch.matches(
            query: newPresetTagInput,
            in: tagSettings.definitions,
            excluding: excluded,
            limit: 5
        )
    }

    /// Existing tags keep their established spelling; canonical duplicates are ignored.
    private func addTagToNewPreset(_ rawName: String? = nil) {
        let input = rawName ?? newPresetTagInput
        if let name = TagDefinitionSearch.resolvedDisplayName(for: input, in: tagSettings.definitions) {
            TagDefinitionSearch.appendUnique(name, to: &newPresetTags)
        }
        newPresetTagInput = ""
    }

    private func deletePreset(_ preset: ImportTagPreset) {
        var presets = settings.importTagPresets
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets.remove(at: index)
        settings.importTagPresets = presets
        recentlyDeletedPreset = (preset, index)
    }

    private func restoreDeletedPreset() {
        guard let deleted = recentlyDeletedPreset else { return }
        var presets = settings.importTagPresets
        if !presets.contains(where: { $0.id == deleted.preset.id }) {
            presets.insert(deleted.preset, at: min(deleted.index, presets.count))
            settings.importTagPresets = presets
            if deleted.preset.isDefault {
                settings.setDefaultPreset(deleted.preset.id)
            }
        }
        recentlyDeletedPreset = nil
    }

    private func saveNewPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !newPresetTags.isEmpty else { return }
        let preset = ImportTagPreset(name: name, tags: newPresetTags)
        var presets = settings.importTagPresets
        presets.append(preset)
        settings.importTagPresets = presets
        resetAddForm()
    }

    private func resetAddForm() {
        isAddingPreset = false
        newPresetName = ""
        newPresetTags = []
        newPresetTagInput = ""
    }
}
