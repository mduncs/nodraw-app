import SwiftUI

// MARK: - TagRuleEditorSheet

struct TagRuleEditorSheet: View {
    @ObservedObject var engine: TagRuleEngine
    @ObservedObject var tagSettings: TagSettings
    @Environment(\.dismiss) private var dismiss

    var editingRule: TagRule?
    var prefilledSourceField: SourceField? = nil
    var prefilledPattern: String? = nil
    /// The app's live store when the caller has it; preview is read-only either way.
    var mediaStore: MediaStore? = nil

    @State private var name: String = ""
    @State private var sourceField: SourceField = .subreddit
    @State private var matchType: MatchType = .exact
    @State private var pattern: String = ""
    @State private var tagName: String = ""
    @State private var enabled: Bool = true
    @State private var previewCount: Int? = nil
    @State private var isLoadingPreview: Bool = false
    @State private var isSaving: Bool = false
    @State private var nameWasManuallyEdited: Bool = false
    @State private var pipelineProcessedCount: Int = 0
    @State private var pipelineTotalCount: Int = 0
    @State private var isAutoGenerating: Bool = false
    @State private var saveError: String? = nil
    @State private var previewError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(editingRule == nil ? "New Tag Rule" : "Edit Tag Rule")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close without saving")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
                .background(Color.white.opacity(0.1))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Source field picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Source Field")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Source Field", selection: $sourceField) {
                            Section("Metadata") {
                                ForEach(SourceField.allCases.filter { !$0.isMLField }, id: \.self) { field in
                                    Text(field.displayName).tag(field)
                                }
                            }
                            Section("ML Pipeline") {
                                ForEach(SourceField.allCases.filter { $0.isMLField }, id: \.self) { field in
                                    Text(field.displayName).tag(field)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()

                        if sourceField.isMLField {
                            HStack(spacing: 6) {
                                Image(systemName: "cpu")
                                    .foregroundStyle(.orange)
                                    .font(.caption)
                                Text(pipelineCoverageText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.orange.opacity(0.1))
                            )
                        }
                    }

                    // Match type picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Match Type")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Match Type", selection: $matchType) {
                            ForEach(MatchType.allCases, id: \.self) { mt in
                                Text(mt.displayName).tag(mt)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 300)
                    }

                    // Pattern value
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pattern")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField(sourceField.patternPlaceholder, text: $pattern)
                            .textFieldStyle(.plain)
                            .font(.callout.monospaced())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(hex: 0x2a2a2a))
                            )
                            .onChange(of: pattern) { _, _ in
                                autoGenerateName()
                            }
                        if let hint = sourceField.matchingHint {
                            Text(hint)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // Tag picker
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Apply Tag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        tagPickerField
                    }

                    // Rule name
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Rule Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Rule name", text: $name)
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(hex: 0x2a2a2a))
                            )
                            .onChange(of: name) { _, _ in
                                if !isAutoGenerating {
                                    nameWasManuallyEdited = true
                                }
                            }
                    }

                    // Enabled toggle
                    Toggle(isOn: $enabled) {
                        Text("Enabled")
                            .font(.callout)
                            .foregroundStyle(.white)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(16)
            }

            Divider()
                .background(Color.white.opacity(0.1))

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            // Action buttons
            HStack {
                Button("Preview") {
                    loadPreview()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canSave || isLoadingPreview)
                .help("Count existing items this rule would tag; nothing is changed")

                previewStatus

                Spacer(minLength: 8)

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)

                Button {
                    saveRule()
                } label: {
                    HStack(spacing: 4) {
                        if isSaving {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                        }
                        Text(editingRule == nil ? "Add Rule" : "Save")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(canSave ? Color.accentOrange : Color.gray.opacity(0.3))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSave || isSaving)
            }
            .padding(16)
        }
        .frame(width: 420, height: 520)
        .background(Color(hex: 0x1a1a1a))
        .preferredColorScheme(.dark)
        .onAppear {
            if let rule = editingRule {
                name = rule.name
                sourceField = rule.sourceField
                matchType = rule.matchType
                pattern = rule.pattern
                tagName = rule.tagName
                enabled = rule.enabled
                nameWasManuallyEdited = true
            } else if let field = prefilledSourceField {
                sourceField = field
                if let pat = prefilledPattern {
                    pattern = pat
                }
            }
        }
        .task { await loadPipelineStats() }
        .onChange(of: "\(sourceField)|\(matchType)|\(pattern)|\(tagName)") { _, _ in
            // A count for a different rule would mislead.
            previewCount = nil
            previewError = nil
        }
    }

    /// Preview outcome beside its button, where the result is always visible.
    @ViewBuilder
    private var previewStatus: some View {
        if isLoadingPreview {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Checking…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let previewError {
            Label(previewError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(previewError)
        } else if let count = previewCount {
            Text("Matches \(count) existing item\(count == 1 ? "" : "s")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Tag Picker

    @State private var tagSearchText: String = ""
    @State private var showingTagSuggestions: Bool = false

    private var tagPickerField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !tagName.isEmpty {
                    TagChip(name: tagName, maxWidth: 320) {
                        tagName = ""
                        tagSearchText = ""
                        autoGenerateName()
                    }
                } else {
                    TextField("Search or type tag name", text: $tagSearchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(hex: 0x2a2a2a))
                        )
                        .onSubmit {
                            // Reuse an existing tag's spelling; otherwise keep the typed
                            // display name (identity is canonical either way).
                            if let resolved = TagDefinitionSearch.resolvedDisplayName(
                                for: tagSearchText,
                                in: tagSettings.definitions
                            ) {
                                tagName = resolved
                                tagSearchText = ""
                                showingTagSuggestions = false
                                autoGenerateName()
                            }
                        }
                        .onChange(of: tagSearchText) { _, newValue in
                            showingTagSuggestions = !newValue.isEmpty
                        }
                }
            }

            if showingTagSuggestions && tagName.isEmpty {
                let filtered = TagDefinitionSearch.matches(
                    query: tagSearchText,
                    in: tagSettings.definitions,
                    limit: 8
                )
                let typed = TagCanonicalizer.displayName(tagSearchText)
                let isNewTag = TagDefinitionSearch.existingDefinition(named: typed, in: tagSettings.definitions) == nil
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.definition.id) { match in
                        Button {
                            tagName = match.definition.name
                            tagSearchText = ""
                            showingTagSuggestions = false
                            autoGenerateName()
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(match.definition.color)
                                    .frame(width: 8, height: 8)
                                Text(match.definition.name)
                                    .font(.callout)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                if !match.ancestorLabel.isEmpty {
                                    Text(match.ancestorLabel)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if isNewTag && !typed.isEmpty {
                        Text("Return uses new tag ‘\(typed)’; it joins the tag list once the rule tags an item")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(hex: 0x2a2a2a))
                )
            }
        }
    }

    // MARK: - Pipeline Coverage

    private var pipelineCoverageText: String {
        if pipelineTotalCount == 0 { return "No items in library" }
        if pipelineProcessedCount == 0 {
            return "The ML pipeline hasn't analyzed any items yet. Use Backfill in Settings ▸ Processing ▸ ML Pipeline."
        }
        return "Matches against ML data (\(pipelineProcessedCount)/\(pipelineTotalCount) items analyzed)"
    }

    private func loadPipelineStats() async {
        let db = DatabaseManager.shared
        pipelineProcessedCount = (try? await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE pipeline_status = 'complete'")
        }) ?? 0
        pipelineTotalCount = (try? await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE (deletedAt IS NULL OR deletedAt = '')")
        }) ?? 0
    }

    // MARK: - Validation

    private var canSave: Bool {
        !pattern.trimmingCharacters(in: .whitespaces).isEmpty &&
        !tagName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Auto-name

    private func autoGenerateName() {
        guard !nameWasManuallyEdited || name.isEmpty else { return }
        let p = pattern.trimmingCharacters(in: .whitespaces)
        let t = tagName.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !t.isEmpty else {
            if !nameWasManuallyEdited {
                isAutoGenerating = true
                name = ""
                isAutoGenerating = false
            }
            return
        }
        isAutoGenerating = true
        nameWasManuallyEdited = false
        name = sourceField.autoName(pattern: p, tag: t)
        isAutoGenerating = false
    }

    // MARK: - Preview

    private func loadPreview() {
        guard canSave else { return }
        isLoadingPreview = true
        previewCount = nil
        let rule = buildRule()
        previewError = nil
        Task {
            do {
                // Preview is read-only, so a standalone store on the shared database is
                // safe when the caller did not pass the app's store.
                let store = mediaStore ?? MediaStore()
                let count = try await engine.previewRuleMatch(rule, mediaStore: store)
                previewCount = count
            } catch {
                logError("TagRuleEditorSheet: preview failed: \(error)")
                previewCount = nil
                previewError = "Preview failed: \(error.localizedDescription)"
            }
            isLoadingPreview = false
        }
    }

    // MARK: - Save

    private func saveRule() {
        guard canSave else { return }
        isSaving = true
        saveError = nil
        let rule = buildRule()
        Task {
            do {
                if editingRule != nil {
                    try await engine.updateRule(rule)
                } else {
                    try await engine.addRule(rule)
                }
                dismiss()
            } catch {
                logError("TagRuleEditorSheet: save failed: \(error)")
                saveError = "Could not save the rule: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }

    private func buildRule() -> TagRule {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let effectiveName = trimmedName.isEmpty
            ? sourceField.autoName(pattern: pattern, tag: tagName)
            : trimmedName

        return TagRule(
            id: editingRule?.id ?? UUID(),
            name: effectiveName,
            enabled: enabled,
            sourceField: sourceField,
            matchType: matchType,
            pattern: pattern.trimmingCharacters(in: .whitespaces),
            tagName: TagDefinitionSearch.resolvedDisplayName(for: tagName, in: tagSettings.definitions)
                ?? TagCanonicalizer.displayName(tagName),
            priority: editingRule?.priority ?? engine.rules.count,
            createdAt: editingRule?.createdAt ?? Date(),
            updatedAt: Date()
        )
    }
}

// MARK: - SourceField Display Helpers

extension SourceField {
    var displayName: String {
        switch self {
        case .subreddit: return "Subreddit"
        case .boardName: return "Board Name"
        case .blogName: return "Blog Name"
        case .channelName: return "Channel Name"
        case .artistName: return "Artist Name"
        case .galleryName: return "Gallery Name"
        case .platform: return "Platform"
        case .sourceTag: return "Source Tag"
        case .sceneLabel: return "Scene Label"
        case .detectedObject: return "Detected Object"
        case .safetyFlag: return "Safety Flag"
        case .curationScore: return "Curation Score"
        case .junkFlag: return "Junk Flag"
        }
    }

    var patternPlaceholder: String {
        switch self {
        case .subreddit: return "e.g. aesthetic"
        case .boardName: return "e.g. wg"
        case .blogName: return "e.g. photography-blog"
        case .channelName: return "e.g. photography"
        case .artistName: return "e.g. banksy"
        case .galleryName: return "e.g. favorites"
        case .platform: return "e.g. reddit"
        case .sourceTag: return "e.g. landscape"
        case .sceneLabel: return "e.g. outdoor, beach"
        case .detectedObject: return "e.g. cat, bicycle"
        case .safetyFlag: return "safe or unsafe"
        case .curationScore: return "e.g. 0.75"
        case .junkFlag: return "junk or not_junk"
        }
    }

    var metadataLabel: String {
        switch self {
        case .subreddit: return "subreddit"
        case .boardName: return "board"
        case .blogName: return "blog"
        case .channelName: return "channel"
        case .artistName: return "artist"
        case .galleryName: return "gallery"
        case .platform: return "platform"
        case .sourceTag: return "source tag"
        case .sceneLabel: return "scene"
        case .detectedObject: return "object"
        case .safetyFlag: return "safety"
        case .curationScore: return "curation"
        case .junkFlag: return "junk"
        }
    }

    func autoName(pattern: String, tag: String) -> String {
        switch self {
        case .subreddit: return "r/\(pattern) → \(tag)"
        case .boardName: return "/\(pattern)/ → \(tag)"
        case .blogName: return "blog:\(pattern) → \(tag)"
        case .channelName: return "#\(pattern) → \(tag)"
        case .artistName: return "@\(pattern) → \(tag)"
        case .galleryName: return "gallery:\(pattern) → \(tag)"
        case .platform: return "\(pattern) → \(tag)"
        case .sourceTag: return "tag:\(pattern) → \(tag)"
        case .sceneLabel: return "scene:\(pattern) → \(tag)"
        case .detectedObject: return "object:\(pattern) → \(tag)"
        case .safetyFlag: return "safety:\(pattern) → \(tag)"
        case .curationScore: return "curation:\(pattern) → \(tag)"
        case .junkFlag: return "junk:\(pattern) → \(tag)"
        }
    }

    /// How the engine compares this field, where that is not obvious.
    var matchingHint: String? {
        switch self {
        case .curationScore:
            return "Scores are compared as two-decimal text, not numerically: Exact 0.75 matches only 0.75; Starts With 0.8 matches 0.80–0.89."
        case .safetyFlag:
            return "Values are exactly ‘safe’ or ‘unsafe’."
        case .junkFlag:
            return "Values are exactly ‘junk’ or ‘not_junk’."
        default:
            return nil
        }
    }

    func formatValue(_ value: String) -> String {
        switch self {
        case .subreddit: return "r/\(value)"
        case .boardName: return "/\(value)/"
        case .blogName: return value
        case .channelName: return value
        case .artistName: return value
        case .galleryName: return value
        case .platform: return value
        case .sourceTag: return value
        case .sceneLabel: return value
        case .detectedObject: return value
        case .safetyFlag: return value
        case .curationScore: return value
        case .junkFlag: return value
        }
    }
}

// MARK: - MatchType Display Helpers

extension MatchType {
    var displayName: String {
        switch self {
        case .exact: return "Exact"
        case .contains: return "Contains"
        case .prefix: return "Starts With"
        }
    }

    var symbol: String {
        switch self {
        case .exact: return "="
        case .contains: return "~"
        case .prefix: return "^"
        }
    }
}
