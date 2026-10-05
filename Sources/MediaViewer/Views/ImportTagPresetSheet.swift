import SwiftUI

struct ImportTagPresetSheet: View {
    let fileCount: Int
    let onImport: ([String], ImportOptions) -> Void
    let onCancel: () -> Void

    @State private var selectedPresetId: UUID?
    @State private var customTags: [String] = []
    @State private var tagInput: String = ""
    @State private var useFileDateAsArchiveDate = false
    @ObservedObject private var tagSettings = TagSettings.shared

    private var settings: SettingsStore { SettingsStore.shared }

    private var presets: [ImportTagPreset] { settings.importTagPresets }

    /// Preset plus custom tags, canonically de-duplicated ("Cats" and "cats" are one tag).
    private var effectiveTags: [String] {
        var tags: [String] = []
        if let presetId = selectedPresetId,
           let preset = presets.first(where: { $0.id == presetId }) {
            tags.append(contentsOf: preset.tags)
        }
        tags.append(contentsOf: customTags)
        return TagDefinitionSearch.uniqued(tags)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var suggestions: [String] {
        let existingKeys = Set(effectiveTags.map(TagCanonicalizer.key))
        let excluded = Set(tagSettings.definitions
            .filter { existingKeys.contains(TagCanonicalizer.key($0.name)) }
            .map(\.id))
        return TagDefinitionSearch.matches(
            query: tagInput,
            in: tagSettings.definitions,
            excluding: excluded,
            limit: 5
        ).map(\.definition.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    presetSection
                    customTagSection
                    Divider().opacity(0.3)
                    optionsSection
                }
                .padding(20)
            }
            Divider().opacity(0.3)
            footer
        }
        .frame(width: 400, height: 500)
        .background(Color(hex: 0x1e1e1e))
        .onAppear {
            if let defaultPreset = presets.first(where: { $0.isDefault }) {
                selectedPresetId = defaultPreset.id
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import \(fileCount) file\(fileCount == 1 ? "" : "s")")
                    .font(.headline)
                Text("Tags and options apply to everything in this drop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(16)
    }

    // MARK: - Presets

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Presets")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if presets.isEmpty {
                Text("No presets yet. Add them in Settings ▸ Library.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(presets) { preset in
                    presetRow(preset)
                }
            }
        }
    }

    private func presetRow(_ preset: ImportTagPreset) -> some View {
        let isSelected = selectedPresetId == preset.id
        return Button {
            selectedPresetId = isSelected ? nil : preset.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentOrange : .secondary)
                    .font(.body)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(preset.name)
                            .font(.subheadline.weight(.medium))
                        if preset.isDefault {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.yellow)
                        }
                    }
                    tagChips(preset.tags)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentOrange.opacity(0.12) : Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.accentOrange.opacity(0.5) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Custom Tags

    private var customTagSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Additional Tags")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if !customTags.isEmpty {
                tagChips(customTags, removable: true)
            }

            HStack(spacing: 8) {
                TextField("Add tag…", text: $tagInput)
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
                    .onSubmit { addCustomTag() }

                Button(action: addCustomTag) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                        .background(Color.accentOrange, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !suggestions.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            TagDefinitionSearch.appendUnique(suggestion, to: &customTags)
                            tagInput = ""
                        } label: {
                            TagChip(name: suggestion, size: .small, symbol: "plus")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Date Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            optionToggle("Use file dates as archive dates",
                         detail: "Items land in the timeline at the files' original dates instead of today.",
                         isOn: $useFileDateAsArchiveDate)
            Text("Files already in your library are skipped and keep their existing tags and notes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func optionToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: - Footer

    private var importOptions: ImportOptions {
        ImportOptions(useFileDateAsArchiveDate: useFileDateAsArchiveDate).forFileDrop
    }

    private var footer: some View {
        HStack {
            let count = effectiveTags.count
            if count > 0 {
                Text("\(count) tag\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Skip Tags") {
                onImport([], importOptions)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button("Import") {
                onImport(
                    effectiveTags,
                    importOptions
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentOrange)
            .keyboardShortcut(tagInput.isEmpty ? KeyboardShortcut(.return, modifiers: []) : nil)
            .help(tagInput.isEmpty ? "Import (Return)" : "Return adds the typed tag first")
        }
        .padding(16)
    }

    // MARK: - Helpers

    /// Existing tags keep their established spelling; a tag already in the preset
    /// or list (in any case) is not added twice.
    private func addCustomTag() {
        defer { tagInput = "" }
        guard let name = TagDefinitionSearch.resolvedDisplayName(for: tagInput, in: tagSettings.definitions) else { return }
        var current = effectiveTags
        guard TagDefinitionSearch.appendUnique(name, to: &current) else { return }
        customTags.append(name)
    }

    @ViewBuilder
    private func tagChips(_ tags: [String], removable: Bool = false) -> some View {
        FlowLayout(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                TagChip(name: tag, size: .small,
                        onRemove: removable ? { customTags.removeAll { $0 == tag } } : nil)
            }
        }
    }
}
