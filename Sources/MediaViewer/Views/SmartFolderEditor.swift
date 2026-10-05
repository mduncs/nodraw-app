import SwiftUI
import Combine

// MARK: - Smart Folder Editor

/// Sheet for creating/editing smart folders with a rule builder.
struct SmartFolderEditor: View {
    @Environment(\.dismiss) var dismiss

    /// The folder being edited (nil for new folder)
    let existingFolder: SmartFolder?

    /// Callback when folder is saved
    let onSave: (SmartFolder) -> Void

    /// Callback to get preview count
    let getPreviewCount: (SmartFolder) async -> Int

    // MARK: - State

    @State private var name: String
    @State private var icon: String
    @State private var rules: [FilterRule]
    @State private var matchAll: Bool
    @State private var sortOrder: SortOrder

    @State private var previewCount: Int = 0
    @State private var isLoadingPreview: Bool = false
    @State private var appeared: Bool = false
    @State private var isRulesHelpPresented = false

    // Issue #12: Focus state for name field auto-select
    @FocusState private var isNameFieldFocused: Bool

    // Issue #9: Debounce for preview updates
    @State private var previewDebounceTask: Task<Void, Never>?

    // Issue #2: Track rule being edited for inline editing
    @State private var editingRuleIndex: Int? = nil

    // MARK: - Initialization

    init(
        existingFolder: SmartFolder?,
        onSave: @escaping (SmartFolder) -> Void,
        getPreviewCount: @escaping (SmartFolder) async -> Int
    ) {
        self.existingFolder = existingFolder
        self.onSave = onSave
        self.getPreviewCount = getPreviewCount

        // Initialize state from existing or defaults
        _name = State(initialValue: existingFolder?.name ?? "New Smart Folder")
        _icon = State(initialValue: existingFolder?.icon ?? "folder.badge.gearshape")
        _rules = State(initialValue: existingFolder?.rules ?? [])
        _matchAll = State(initialValue: existingFolder?.matchAll ?? true)
        _sortOrder = State(initialValue: existingFolder?.sortOrder ?? .archivedDateDescending)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Name and icon
                    nameSection

                    Divider()

                    // Match mode
                    matchModeSection

                    Divider()

                    // Rules
                    rulesSection

                    Divider()

                    // Sort order
                    sortSection
                }
                .padding()
            }

            Divider()

            // Footer with preview and actions
            footer
        }
        .frame(width: 500, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .scaleEffect(appeared ? 1.0 : 0.95)
        .opacity(appeared ? 1.0 : 0)
        .task {
            await updatePreview()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.15)) {
                appeared = true
            }
            // Issue #12: Auto-focus and select name field on appear
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isNameFieldFocused = true
            }
        }
        .onChange(of: rules) { _, _ in
            debouncedPreviewUpdate()
        }
        .onChange(of: matchAll) { _, _ in
            debouncedPreviewUpdate()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(existingFolder == nil ? "New Smart Folder" : "Edit Smart Folder")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding()
    }

    // MARK: - Name Section

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name & Icon")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                // Issue #10: Icon picker with human-readable names
                Menu {
                    ForEach(iconOptions, id: \.name) { option in
                        Button {
                            icon = option.name
                        } label: {
                            Label(option.displayName, systemImage: option.name)
                        }
                    }
                } label: {
                    Image(systemName: icon)
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .help("Choose an icon for this smart folder")

                // Issue #12: TextField with focus state
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFieldFocused)
                    .onSubmit {
                        isNameFieldFocused = false
                    }
            }
        }
    }

    // Issue #10: Icon options with display names
    private var iconOptions: [(name: String, displayName: String)] {
        [
            ("folder.badge.gearshape", "Smart Folder"),
            ("star.fill", "Star"),
            ("clock", "Clock"),
            ("tag", "Tag"),
            ("tag.slash", "No Tag"),
            ("text.quote", "Text"),
            ("video", "Video"),
            ("photo", "Photo"),
            ("camera", "Camera"),
            ("bird", "Bird"),
            ("heart.fill", "Heart"),
            ("bookmark.fill", "Bookmark"),
            ("exclamationmark.triangle", "Warning"),
            ("doc.text", "Document"),
            ("gearshape.2", "Gears"),
            ("paintpalette", "Palette"),
            ("person.crop.circle", "Person"),
            ("globe", "Globe")
        ]
    }

    // MARK: - Match Mode Section

    private var matchModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Match Mode")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Picker("", selection: $matchAll) {
                Text("Match ALL rules").tag(true)
                Text("Match ANY rule").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - Rules Section

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Rules")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                // Issue #15: Help button with rule descriptions
                Button {
                    isRulesHelpPresented.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show smart-folder rule help")
                .accessibilityLabel("Smart-folder rule help")
                .popover(isPresented: $isRulesHelpPresented, arrowEdge: .top) {
                    ruleHelpPopover
                }

                Spacer()

                // Issue #11: Add keyboard shortcut
                Menu {
                    ForEach(RuleType.allCases, id: \.self) { ruleType in
                        Button {
                            addRule(type: ruleType)
                        } label: {
                            Label(ruleType.displayName, systemImage: ruleType.iconName)
                        }
                        .help(ruleType.helpText)
                    }
                } label: {
                    Label("Add Rule", systemImage: "plus.circle")
                        .font(.subheadline)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            if rules.isEmpty {
                // Issue #15: Better help text when no rules
                VStack(spacing: 8) {
                    Text("No rules defined.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Add rules to filter items. Without rules, this folder will show all items.")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
            } else {
                // Issue #5: Add drag-to-reorder with onMove
                VStack(spacing: 8) {
                    ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                        RuleRow(
                            rule: rule,
                            isEditing: editingRuleIndex == index,
                            onUpdate: { newRule in
                                rules[index] = newRule
                            },
                            onDelete: {
                                rules.remove(at: index)
                                if editingRuleIndex == index {
                                    editingRuleIndex = nil
                                }
                            },
                            onEdit: {
                                editingRuleIndex = editingRuleIndex == index ? nil : index
                            },
                            onMoveUp: index > 0 ? {
                                rules.swapAt(index, index - 1)
                            } : nil,
                            onMoveDown: index < rules.count - 1 ? {
                                rules.swapAt(index, index + 1)
                            } : nil
                        )
                    }
                }
            }
        }
    }

    private var ruleHelpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rule help")
                .font(.headline)
            Text("ALL requires every rule to match. ANY requires at least one. With no rules, the folder shows all items.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(RuleType.allCases, id: \.self) { type in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(type.displayName).font(.caption.weight(.medium))
                            Text(type.helpText).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: - Sort Section

    private var sortSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sort Order")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Picker("", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { order in
                    Text(order.displayName).tag(order)
                }
            }
            .labelsHidden()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            // Preview count
            HStack(spacing: 6) {
                if isLoadingPreview {
                    ProgressView()
                        .scaleEffect(0.6)
                } else if rules.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                } else {
                    Image(systemName: "number")
                        .foregroundStyle(.secondary)
                }
                Text(rules.isEmpty ? "No rules: shows all \(previewCount) items" : "\(previewCount) items match")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Actions
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.cancelAction)

            // Issue #13: Show warning for empty rules, but allow save
            Button("Save") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            .help(rules.isEmpty ? "Warning: No rules defined - folder will show all items" : "Save this smart folder")
        }
        .padding()
    }

    // MARK: - Actions

    // Issue #2: After adding rule, immediately start editing it
    private func addRule(type: RuleType) {
        let newRule = type.defaultRule
        rules.append(newRule)
        // Automatically open the editor for the new rule
        editingRuleIndex = rules.count - 1
    }

    private func save() {
        let folder = SmartFolder(
            id: existingFolder?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            icon: icon,
            rules: rules,
            matchAll: matchAll,
            sortOrder: sortOrder,
            createdAt: existingFolder?.createdAt ?? Date(),
            updatedAt: Date()
        )
        onSave(folder)
        dismiss()
    }

    // Issue #9: Debounced preview update (300ms)
    private func debouncedPreviewUpdate() {
        previewDebounceTask?.cancel()
        previewDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard !Task.isCancelled else { return }
            await updatePreview()
        }
    }

    private func updatePreview() async {
        isLoadingPreview = true
        let folder = SmartFolder(
            id: existingFolder?.id ?? UUID(),
            name: name,
            icon: icon,
            rules: rules,
            matchAll: matchAll,
            sortOrder: sortOrder
        )
        previewCount = await getPreviewCount(folder)
        isLoadingPreview = false
    }
}

// MARK: - Rule Type

/// Enum for rule type picker
enum RuleType: String, CaseIterable {
    case platform
    case author
    case starred
    case hasTag
    case tagsEmpty
    case hasText
    case hasVideo
    case hasNotes
    case dateRange
    case colorBucket
    case parseStatus
    case isProcessed
    case isMetadataOnly
    case hasContextImage  // Issue #4: Added missing hasContextImage
    case shape
    case fileExtension

    var displayName: String {
        switch self {
        case .platform: return "Platform"
        case .author: return "Author"
        case .starred: return "Starred"
        case .hasTag: return "Has Tag"
        case .tagsEmpty: return "No Tags"
        case .hasText: return "Contains Text"
        case .hasVideo: return "Has Video"
        case .hasNotes: return "Has Notes"
        case .dateRange: return "Date Range"
        case .colorBucket: return "Color"
        case .parseStatus: return "Parse Status"
        case .isProcessed: return "Processed"
        case .isMetadataOnly: return "Metadata Only"
        case .hasContextImage: return "Has Context Image"
        case .shape: return "Shape"
        case .fileExtension: return "File Extension"
        }
    }

    // Issue #15: Icons for each rule type
    var iconName: String {
        switch self {
        case .platform: return "globe"
        case .author: return "person"
        case .starred: return "star"
        case .hasTag: return "tag"
        case .tagsEmpty: return "tag.slash"
        case .hasText: return "text.quote"
        case .hasVideo: return "video"
        case .hasNotes: return "note.text"
        case .dateRange: return "calendar"
        case .colorBucket: return "paintpalette"
        case .parseStatus: return "exclamationmark.triangle"
        case .isProcessed: return "gearshape"
        case .isMetadataOnly: return "doc.text"
        case .hasContextImage: return "photo.on.rectangle"
        case .shape: return "rectangle.landscape.rotate"
        case .fileExtension: return "doc.badge.ellipsis"
        }
    }

    // Issue #15: Help text for each rule type
    var helpText: String {
        switch self {
        case .platform: return "Filter by source platform (Twitter, Instagram, etc.)"
        case .author: return "Filter by author/username"
        case .starred: return "Show starred or unstarred items"
        case .hasTag: return "Show items with a specific tag"
        case .tagsEmpty: return "Show items without any tags"
        case .hasText: return "Search within OCR-extracted text"
        case .hasVideo: return "Show items with or without video"
        case .hasNotes: return "Show items with or without notes"
        case .dateRange: return "Filter by archived or original date"
        case .colorBucket: return "Filter by dominant color"
        case .parseStatus: return "Filter by metadata parsing status"
        case .isProcessed: return "Show processed or unprocessed items"
        case .isMetadataOnly: return "Show items without media files"
        case .hasContextImage: return "Show items with context screenshots"
        case .shape: return "Filter by aspect ratio (landscape, portrait, square, panoramic)"
        case .fileExtension: return "Filter by file extension"
        }
    }

    var defaultRule: FilterRule {
        switch self {
        case .platform:
            return .platform(.equals("twitter"))
        case .author:
            return .author(.contains(""))
        case .starred:
            return .starred(true)
        case .hasTag:
            return .hasTag("")
        case .tagsEmpty:
            return .tagsEmpty
        case .hasText:
            return .hasText(.contains(""))
        case .hasVideo:
            return .hasVideo(true)
        case .hasNotes:
            return .hasNotes(true)
        case .dateRange:
            return .dateRange(DateRangeFilter(field: .archived, range: .lastNDays(7)))
        case .colorBucket:
            return .colorBucket(.red)
        case .parseStatus:
            return .parseStatus(.hasIssues)
        case .isProcessed:
            return .isProcessed(false)
        case .isMetadataOnly:
            return .isMetadataOnly(true)
        case .hasContextImage:  // Issue #4: Default rule for hasContextImage
            return .hasContextImage(true)
        case .shape:
            return .shape(.landscape)
        case .fileExtension:
            return .fileExtension(Set(["gif", "webp"]))
        }
    }
}

// MARK: - Rule Row

/// Individual rule editor row with inline editing support
struct RuleRow: View {
    let rule: FilterRule
    let isEditing: Bool
    let onUpdate: (FilterRule) -> Void
    let onDelete: () -> Void
    let onEdit: () -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack(spacing: 8) {
                // Rule description
                Text(rule.description)
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer()

                Button { onMoveUp?() } label: {
                    Image(systemName: "arrow.up")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(onMoveUp == nil)
                .help("Move rule up")
                .accessibilityLabel("Move rule up")

                Button { onMoveDown?() } label: {
                    Image(systemName: "arrow.down")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(onMoveDown == nil)
                .help("Move rule down")
                .accessibilityLabel("Move rule down")

                // Issue #1: Edit button
                Button {
                    onEdit()
                } label: {
                    Image(systemName: isEditing ? "chevron.up.circle.fill" : "pencil.circle")
                        .foregroundStyle(isEditing ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit this rule")

                // Menu with more options
                Menu {
                    Button {
                        onEdit()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    Divider()

                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Issue #1, #2, #3: Inline editor when expanded
            if isEditing {
                RuleEditor(rule: rule, onUpdate: onUpdate)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Rule Editor

/// Inline editor for rule values
struct RuleEditor: View {
    let rule: FilterRule
    let onUpdate: (FilterRule) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            switch rule {
            // Issue #6: Platform picker
            case .platform(let filter):
                PlatformEditor(filter: filter) { newFilter in
                    onUpdate(.platform(newFilter))
                }

            // Author editor
            case .author(let filter):
                StringFilterEditor(filter: filter, placeholder: "Author name") { newFilter in
                    onUpdate(.author(newFilter))
                }

            // Starred toggle
            case .starred(let value):
                Toggle("Starred", isOn: Binding(
                    get: { value },
                    set: { onUpdate(.starred($0)) }
                ))
                .toggleStyle(.switch)

            // Issue #3: Tag editor with placeholder
            case .hasTag(let tag):
                HStack {
                    Text("Tag:")
                    TextField("Enter tag name", text: Binding(
                        get: { tag },
                        set: { onUpdate(.hasTag($0)) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

            // No editor needed for tagsEmpty
            case .tagsEmpty:
                Text("Shows items with no tags assigned")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            // Issue #3: Text filter editor
            case .hasText(let filter):
                StringFilterEditor(filter: filter, placeholder: "Search text") { newFilter in
                    onUpdate(.hasText(newFilter))
                }

            // Video toggle
            case .hasVideo(let value):
                Toggle("Has Video", isOn: Binding(
                    get: { value },
                    set: { onUpdate(.hasVideo($0)) }
                ))
                .toggleStyle(.switch)

            // Notes toggle
            case .hasNotes(let value):
                Toggle("Has Notes", isOn: Binding(
                    get: { value },
                    set: { onUpdate(.hasNotes($0)) }
                ))
                .toggleStyle(.switch)

            // Issue #7: Date range editor
            case .dateRange(let filter):
                DateRangeEditor(filter: filter) { newFilter in
                    onUpdate(.dateRange(newFilter))
                }

            // Issue #8: Color bucket picker
            case .colorBucket(let bucket):
                ColorBucketPicker(selected: bucket) { newBucket in
                    onUpdate(.colorBucket(newBucket))
                }

            // Issue #14: Parse status picker
            case .parseStatus(let filter):
                ParseStatusEditor(filter: filter) { newFilter in
                    onUpdate(.parseStatus(newFilter))
                }

            // Processed toggle
            case .isProcessed(let value):
                Toggle("Is Processed", isOn: Binding(
                    get: { value },
                    set: { onUpdate(.isProcessed($0)) }
                ))
                .toggleStyle(.switch)

            // Metadata only toggle
            case .isMetadataOnly(let value):
                Toggle("Metadata Only", isOn: Binding(
                    get: { value },
                    set: { onUpdate(.isMetadataOnly($0)) }
                ))
                .toggleStyle(.switch)

            // Issue #4: Context image toggle
            case .hasContextImage(let value):
                Toggle("Has Context Image", isOn: Binding(
                    get: { value },
                    set: { onUpdate(.hasContextImage($0)) }
                ))
                .toggleStyle(.switch)

            // Shape filter
            case .shape(let filter):
                Picker("Shape", selection: Binding(
                    get: { filter },
                    set: { onUpdate(.shape($0)) }
                )) {
                    ForEach(ShapeFilter.allCases, id: \.self) { shape in
                        Text(shape.description).tag(shape)
                    }
                }

            // File extension filter
            case .fileExtension(let extensions):
                HStack {
                    Text("Extensions:")
                    TextField("jpg, png, gif", text: Binding(
                        get: { extensions.sorted().joined(separator: ", ") },
                        set: { input in
                            let exts = Set(input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                            onUpdate(.fileExtension(exts))
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

            }
        }
    }
}

// MARK: - Platform Editor (Issue #6)

struct PlatformEditor: View {
    let filter: PlatformFilter
    let onUpdate: (PlatformFilter) -> Void

    // Known platforms from the codebase
    private let knownPlatforms = ["twitter", "instagram", "reddit", "youtube", "tiktok", "tumblr", "bluesky"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Platform:")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Quick select buttons for known platforms
            HStack(spacing: 4) {
                ForEach(knownPlatforms, id: \.self) { platform in
                    Button {
                        onUpdate(.equals(platform))
                    } label: {
                        Text(LibraryFilterPresentation.platformName(platform))
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                isSelected(platform) ? Color.accentColor : Color.secondary.opacity(0.2),
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                            .foregroundStyle(isSelected(platform) ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Custom platform input
            HStack {
                Text("Or custom:")
                TextField("Custom platform", text: Binding(
                    get: { currentPlatformValue },
                    set: { onUpdate(.equals($0)) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 150)
            }
        }
    }

    private var currentPlatformValue: String {
        switch filter {
        case .equals(let value): return value
        case .oneOf(let values): return values.joined(separator: ", ")
        }
    }

    private func isSelected(_ platform: String) -> Bool {
        switch filter {
        case .equals(let value): return value == platform
        case .oneOf(let values): return values.contains(platform)
        }
    }
}

// MARK: - String Filter Editor

struct StringFilterEditor: View {
    let filter: StringFilter
    let placeholder: String
    let onUpdate: (StringFilter) -> Void

    @State private var filterType: StringFilterType = .contains
    @State private var value: String = ""

    enum StringFilterType: String, CaseIterable {
        case equals = "is exactly"
        case contains = "contains"
        case startsWith = "starts with"
        case isEmpty = "is empty"
        case isNotEmpty = "is not empty"
    }

    init(filter: StringFilter, placeholder: String, onUpdate: @escaping (StringFilter) -> Void) {
        self.filter = filter
        self.placeholder = placeholder
        self.onUpdate = onUpdate

        // Initialize from current filter
        switch filter {
        case .equals(let v):
            _filterType = State(initialValue: .equals)
            _value = State(initialValue: v)
        case .contains(let v):
            _filterType = State(initialValue: .contains)
            _value = State(initialValue: v)
        case .startsWith(let v):
            _filterType = State(initialValue: .startsWith)
            _value = State(initialValue: v)
        case .isEmpty:
            _filterType = State(initialValue: .isEmpty)
        case .isNotEmpty:
            _filterType = State(initialValue: .isNotEmpty)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Match type:", selection: $filterType) {
                ForEach(StringFilterType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: filterType) { _, newType in
                updateFilter()
            }

            if filterType != .isEmpty && filterType != .isNotEmpty {
                TextField(placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: value) { _, _ in
                        updateFilter()
                    }
            }
        }
    }

    private func updateFilter() {
        let newFilter: StringFilter
        switch filterType {
        case .equals:
            newFilter = .equals(value)
        case .contains:
            newFilter = .contains(value)
        case .startsWith:
            newFilter = .startsWith(value)
        case .isEmpty:
            newFilter = .isEmpty
        case .isNotEmpty:
            newFilter = .isNotEmpty
        }
        onUpdate(newFilter)
    }
}

// MARK: - Date Range Editor (Issue #7)

struct DateRangeEditor: View {
    let filter: DateRangeFilter
    let onUpdate: (DateRangeFilter) -> Void

    @State private var dateField: DateRangeFilter.DateField = .archived
    @State private var rangeType: RangeTypeSelection = .lastNDays
    @State private var daysCount: Int = 7
    @State private var afterDate: Date = Date()
    @State private var beforeDate: Date = Date()
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date()

    enum RangeTypeSelection: String, CaseIterable {
        case lastNDays = "Last N days"
        case thisMonth = "This month"
        case thisYear = "This year"
        case after = "After date"
        case before = "Before date"
        case between = "Between dates"
    }

    init(filter: DateRangeFilter, onUpdate: @escaping (DateRangeFilter) -> Void) {
        self.filter = filter
        self.onUpdate = onUpdate

        _dateField = State(initialValue: filter.field)

        switch filter.range {
        case .lastNDays(let n):
            _rangeType = State(initialValue: .lastNDays)
            _daysCount = State(initialValue: n)
        case .thisMonth:
            _rangeType = State(initialValue: .thisMonth)
        case .thisYear:
            _rangeType = State(initialValue: .thisYear)
        case .after(let date):
            _rangeType = State(initialValue: .after)
            _afterDate = State(initialValue: date)
        case .before(let date):
            _rangeType = State(initialValue: .before)
            _beforeDate = State(initialValue: date)
        case .between(let start, let end):
            _rangeType = State(initialValue: .between)
            _startDate = State(initialValue: start)
            _endDate = State(initialValue: end)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Date field picker
            Picker("Date field:", selection: $dateField) {
                Text("Archived date").tag(DateRangeFilter.DateField.archived)
                Text("Original date").tag(DateRangeFilter.DateField.original)
            }
            .pickerStyle(.segmented)
            .onChange(of: dateField) { _, _ in
                updateFilter()
            }

            // Range type picker
            Picker("Range:", selection: $rangeType) {
                ForEach(RangeTypeSelection.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: rangeType) { _, _ in
                updateFilter()
            }

            // Additional inputs based on range type
            switch rangeType {
            case .lastNDays:
                HStack {
                    Text("Days:")
                    TextField("", value: $daysCount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .onChange(of: daysCount) { _, _ in
                            updateFilter()
                        }
                }

            case .after:
                DatePicker("After:", selection: $afterDate, displayedComponents: .date)
                    .onChange(of: afterDate) { _, _ in
                        updateFilter()
                    }

            case .before:
                DatePicker("Before:", selection: $beforeDate, displayedComponents: .date)
                    .onChange(of: beforeDate) { _, _ in
                        updateFilter()
                    }

            case .between:
                DatePicker("From:", selection: $startDate, displayedComponents: .date)
                    .onChange(of: startDate) { _, _ in
                        updateFilter()
                    }
                DatePicker("To:", selection: $endDate, displayedComponents: .date)
                    .onChange(of: endDate) { _, _ in
                        updateFilter()
                    }

            case .thisMonth, .thisYear:
                EmptyView()
            }
        }
    }

    private func updateFilter() {
        let range: DateRangeFilter.RangeType
        switch rangeType {
        case .lastNDays:
            range = .lastNDays(max(1, daysCount))
        case .thisMonth:
            range = .thisMonth
        case .thisYear:
            range = .thisYear
        case .after:
            range = .after(afterDate)
        case .before:
            range = .before(beforeDate)
        case .between:
            range = .between(startDate, endDate)
        }
        onUpdate(DateRangeFilter(field: dateField, range: range))
    }
}

// MARK: - Color Bucket Picker (Issue #8)

struct ColorBucketPicker: View {
    let selected: ColorBucket
    let onUpdate: (ColorBucket) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select color:")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Color grid
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))], spacing: 8) {
                ForEach(ColorBucket.allCases, id: \.self) { bucket in
                    Button {
                        onUpdate(bucket)
                    } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(
                                red: bucket.uiColor.red,
                                green: bucket.uiColor.green,
                                blue: bucket.uiColor.blue
                            ))
                            .frame(width: 36, height: 36)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(selected == bucket ? Color.accentColor : Color.clear, lineWidth: 3)
                            )
                            .overlay(
                                selected == bucket ?
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.white)
                                        .font(.caption.bold())
                                        .shadow(radius: 1)
                                    : nil
                            )
                    }
                    .buttonStyle(.plain)
                    .help(bucket.displayName)
                }
            }
        }
    }
}

// MARK: - Parse Status Editor (Issue #14)

struct ParseStatusEditor: View {
    let filter: ParseStatusFilter
    let onUpdate: (ParseStatusFilter) -> Void

    @State private var filterType: ParseStatusFilterType = .hasIssues
    @State private var selectedStatus: ParseStatus = .success

    enum ParseStatusFilterType: String, CaseIterable {
        case hasIssues = "Has issues"
        case equals = "Is exactly"
        case notEquals = "Is not"
    }

    init(filter: ParseStatusFilter, onUpdate: @escaping (ParseStatusFilter) -> Void) {
        self.filter = filter
        self.onUpdate = onUpdate

        switch filter {
        case .hasIssues:
            _filterType = State(initialValue: .hasIssues)
        case .equals(let status):
            _filterType = State(initialValue: .equals)
            _selectedStatus = State(initialValue: status)
        case .notEquals(let status):
            _filterType = State(initialValue: .notEquals)
            _selectedStatus = State(initialValue: status)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Filter type:", selection: $filterType) {
                ForEach(ParseStatusFilterType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: filterType) { _, _ in
                updateFilter()
            }

            if filterType != .hasIssues {
                Picker("Status:", selection: $selectedStatus) {
                    Text("Success").tag(ParseStatus.success)
                    Text("Partial").tag(ParseStatus.partial)
                    Text("Failed").tag(ParseStatus.failed)
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedStatus) { _, _ in
                    updateFilter()
                }
            }

            // Explanation text
            Text(explanationText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var explanationText: String {
        switch filterType {
        case .hasIssues:
            return "Shows items where parsing had issues (partial or failed)"
        case .equals:
            return "Shows items with exactly this parse status"
        case .notEquals:
            return "Shows items that don't have this parse status"
        }
    }

    private func updateFilter() {
        let newFilter: ParseStatusFilter
        switch filterType {
        case .hasIssues:
            newFilter = .hasIssues
        case .equals:
            newFilter = .equals(selectedStatus)
        case .notEquals:
            newFilter = .notEquals(selectedStatus)
        }
        onUpdate(newFilter)
    }
}

// MARK: - Preview

#if DEBUG
struct SmartFolderEditor_Previews: PreviewProvider {
    static var previews: some View {
        SmartFolderEditor(
            existingFolder: nil,
            onSave: { _ in },
            getPreviewCount: { _ in 42 }
        )
    }
}
#endif
