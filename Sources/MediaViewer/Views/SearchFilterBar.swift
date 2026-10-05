import SwiftUI
import Combine

private struct FileTypeFilterOption: Identifiable {
    let label: String
    let token: String
    let icon: String
    var id: String { token }
}

struct SearchFilterBar: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = SearchFilterBarViewModel()
    @ObservedObject private var tagSettings = TagSettings.shared
    @FocusState private var isSearchFocused: Bool
    @State private var expandedCategory: FilterCategory?
    @State private var draft: LibraryFilterDraft?
    @State private var draftDestination: SidebarSelection?
    @State private var tagSearch = ""
    /// Tags active when the popover opened; listed first and fixed for the session so rows never jump.
    @State private var pinnedTagKeys: Set<String> = []
    @State private var showColorPicker = false
    @State private var showViewOptions = false
    @State private var advancedQuery = false

    enum FilterCategory: String, CaseIterable {
        case platform = "Platform", tags = "Tags", type = "Type", color = "Color"
        var icon: String {
            switch self {
            case .platform: return "globe"
            case .tags: return "tag"
            case .type: return "doc.on.doc"
            case .color: return "paintpalette"
            }
        }
    }

    private let fileTypeFilters = [
        FileTypeFilterOption(label: "Images", token: "image", icon: "photo"),
        FileTypeFilterOption(label: "Video", token: "video", icon: "video"),
        FileTypeFilterOption(label: "Audio", token: "audio", icon: "waveform"),
        FileTypeFilterOption(label: "Documents", token: "document", icon: "doc.text")
    ]
    private let fileExtensionFilters = [
        FileTypeFilterOption(label: "JPEG", token: "jpg,jpeg", icon: "photo"),
        FileTypeFilterOption(label: "PNG", token: "png", icon: "photo"),
        FileTypeFilterOption(label: "GIF", token: "gif", icon: "livephoto"),
        FileTypeFilterOption(label: "WEBP", token: "webp", icon: "photo"),
        FileTypeFilterOption(label: "HEIC", token: "heic", icon: "photo"),
        FileTypeFilterOption(label: "MP4", token: "mp4", icon: "video"),
        FileTypeFilterOption(label: "MOV", token: "mov", icon: "video"),
        FileTypeFilterOption(label: "WEBM", token: "webm", icon: "video"),
        FileTypeFilterOption(label: "PDF", token: "pdf", icon: "doc.richtext")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Widest first. Every child is fixed-size, so when a layout does not fit the
            // next one is used; the last resort folds the filter chips into one menu so
            // nothing falls off the edge.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    backButton
                    searchField(idealWidth: 300)
                    HStack(spacing: 5) { categoryButtons; quickFilters; viewModeToggle }
                    trailingControls
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { backButton; searchField(idealWidth: 220); trailingControls }
                    HStack(spacing: 5) { categoryButtons; quickFilters; Spacer(minLength: 8); viewModeToggle }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { backButton; searchField(idealWidth: 130); trailingControls }
                    HStack(spacing: 5) { collapsedFilterMenu; Spacer(minLength: 0) }
                }
            }
            if appState.hasLibrarySearchOrFilters {
                LibraryActiveFiltersView()
                    .padding(.top, 3)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color(hex: 0x252525))
        .task(id: appState.mediaStore != nil) { await viewModel.configure(with: appState) }
        .onReceive(appState.$isFilterBarFocused) { shouldFocus in
            if shouldFocus { isSearchFocused = true; appState.isFilterBarFocused = false }
        }
    }

    private var backButton: some View {
        Button { appState.navigateBack() } label: {
            // contentShape: a plain button otherwise only hit-tests the 7×12 pt glyph.
            Image(systemName: "chevron.left").frame(width: 20, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!appState.canNavigateBack)
        .help("Back to the previous detail, search or destination")
        .accessibilityLabel("Back").accessibilityIdentifier("library-back")
    }

    private var trailingControls: some View {
        HStack(spacing: 8) {
            resultCountBadge
            Button { showViewOptions.toggle() } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Sort, density and display options")
            .accessibilityLabel("View options")
            .popover(isPresented: $showViewOptions, arrowEdge: .bottom) { viewOptions }
            inspectorToggle
        }
        .fixedSize()
    }

    private func toggleCategory(_ category: FilterCategory) {
        isSearchFocused = false
        if expandedCategory == category { closeCategory() }
        else {
            closeCategory()
            draft = LibraryFilterDraft(appState)
            draftDestination = appState.sidebarSelection
            if category == .tags {
                tagSearch = ""
                let parsed = MediaFilterBuilder.parseSearchInput(appState.filterText)
                pinnedTagKeys = Set(parsed.tags + parsed.tagFilters.map(\.name))
            }
            expandedCategory = category
        }
    }

    /// Last-resort toolbar: the same categories and quick filters behind one menu. Each
    /// category's popover is anchored on the menu so the staged draft flow is unchanged.
    private var collapsedFilterMenu: some View {
        let activeCount = FilterCategory.allCases.filter(categoryActive).count
            + (appState.starredFilter == true ? 1 : 0) + (appState.hasOCRFilter == true ? 1 : 0)
        return Menu {
            ForEach(FilterCategory.allCases, id: \.self) { category in
                Button { toggleCategory(category) } label: {
                    Label(category.rawValue + "…", systemImage: categoryActive(category) ? "checkmark.circle.fill" : category.icon)
                }
            }
            Divider()
            Toggle("Starred", isOn: Binding(get: { appState.starredFilter == true }, set: { on in
                appState.commitLibraryFilterChange { appState.starredFilter = on ? true : nil }
            }))
            Toggle("Has text", isOn: Binding(get: { appState.hasOCRFilter == true }, set: { on in
                appState.commitLibraryFilterChange { appState.hasOCRFilter = on ? true : nil }
            }))
        } label: {
            Label(activeCount > 0 ? "Filters (\(activeCount))" : "Filters", systemImage: "line.3.horizontal.decrease.circle")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton).fixedSize()
        .foregroundStyle(activeCount > 0 ? Color.accentColor : .primary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(activeCount > 0 ? Color.accentColor.opacity(0.15) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
        .background {
            ForEach(FilterCategory.allCases, id: \.self) { category in
                Color.clear.popover(isPresented: categoryBinding(category), arrowEdge: .bottom) { categoryPopover(category) }
            }
        }
        .accessibilityLabel("Filters")
        .accessibilityValue(activeCount > 0 ? "\(activeCount) active" : "none")
        .accessibilityIdentifier("filter-overflow-menu")
    }

    private var categoryButtons: some View {
        ForEach(FilterCategory.allCases, id: \.self) { category in
            Button {
                toggleCategory(category)
            } label: {
                Label(category.rawValue, systemImage: category.icon)
                    .font(.system(size: 11))
                    .fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 5)
                    .background(categoryActive(category) ? Color.accentColor.opacity(0.15) : Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .foregroundStyle(categoryActive(category) ? Color.accentColor : .primary)
            .accessibilityLabel("\(category.rawValue) filters")
            .accessibilityValue(categoryActive(category) ? "active" : "none")
            .accessibilityAddTraits(categoryActive(category) ? [.isSelected] : [])
            .accessibilityIdentifier("filter-\(category.rawValue.lowercased())")
            .popover(isPresented: categoryBinding(category), arrowEdge: .bottom) { categoryPopover(category) }
        }
    }

    private var quickFilters: some View {
        Group {
            quickFilter("Starred", icon: "star", active: appState.starredFilter == true) {
                appState.starredFilter = appState.starredFilter == true ? nil : true
            }
            quickFilter("Has text", icon: "text.viewfinder", active: appState.hasOCRFilter == true) {
                appState.hasOCRFilter = appState.hasOCRFilter == true ? nil : true
            }
        }
    }

    private func quickFilter(_ label: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            closeCategory()
            isSearchFocused = false
            appState.commitLibraryFilterChange(action)
        } label: {
            Label(label, systemImage: icon).font(.system(size: 11)).fixedSize()
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(active ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain)
            .foregroundStyle(active ? Color.accentColor : .secondary)
            .accessibilityLabel("\(label) filter").accessibilityValue(active ? "enabled" : "disabled")
            .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func searchField(idealWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Search in", selection: Binding(get: { appState.searchScope }, set: { scope in
                    appState.commitLibraryFilterChange { appState.searchScope = scope }
                })) {
                    ForEach(SearchScope.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Divider()
                Toggle("Show query syntax", isOn: $advancedQuery)
            } label: {
                Text(appState.searchScope.displayName).font(.caption).fixedSize()
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Search scope: \(appState.searchScope.displayName)")
            TextField(searchPlaceholder, text: Binding(
                get: { advancedQuery ? appState.filterText : MediaFilterBuilder.searchQueryText(from: appState.filterText) },
                set: { text in
                    appState.updateSearchText(advancedQuery ? text : LibraryFilterPresentation.replacingFreeText(in: appState.filterText, with: text))
                }
            ))
            .textFieldStyle(.plain).font(.system(size: 12)).focused($isSearchFocused)
            .accessibilityLabel("Search \(appState.searchScope.displayName)")
            .accessibilityIdentifier("search-filter-input")
            .accessibilityHint(advancedQuery ? "Search text and structured query tokens" : "Use filter buttons for tags, types and colors; choose Show query syntax for advanced entry")
            if !MediaFilterBuilder.searchQueryText(from: appState.filterText).isEmpty || (advancedQuery && !appState.filterText.isEmpty) {
                Button {
                    appState.commitSearchText(advancedQuery ? "" : LibraryFilterPresentation.tokens(in: appState.filterText).map(\.raw).joined(separator: " "))
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).accessibilityLabel(advancedQuery ? "Clear query text and typed filters" : "Clear search text")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(hex: 0x1a1a1a), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isSearchFocused ? Color.accentColor.opacity(0.65) : Color.secondary.opacity(0.15)))
        .frame(minWidth: 130, idealWidth: idealWidth, maxWidth: .infinity)
        .layoutPriority(1)
    }

    private var searchPlaceholder: String {
        if advancedQuery { return "Search / tag:… / type:…" }
        switch appState.searchScope {
        case .all: return "Search all text…"
        case .ocrOnly: return "Search extracted text…"
        case .notesOnly: return "Search notes…"
        case .authorOnly: return "Search authors…"
        case .visual: return "Describe an image…"
        }
    }

    private var resultCountBadge: some View {
        Text(viewModel.isCounting ? "…" : viewModel.resultCount.map { $0.formatted() } ?? "—")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .frame(minWidth: 22, alignment: .trailing)
            .padding(.horizontal, 2)
            .help(viewModel.countError ?? "Matches in \(appState.libraryDestinationLabel)")
            .accessibilityLabel(viewModel.isCounting ? "Updating result count" : viewModel.resultCount.map { "\($0) matching items" } ?? "Result count unavailable")
    }

    private func categoryActive(_ category: FilterCategory) -> Bool {
        let tokens = LibraryFilterPresentation.tokens(in: appState.filterText)
        switch category {
        case .platform: return appState.platformFilter != nil || tokens.contains { $0.key == "platform" }
        case .tags: return tokens.contains { LibraryFilterPresentation.tagKeys.contains($0.key) }
        case .type: return tokens.contains { LibraryFilterPresentation.typeKeys.contains($0.key) }
        case .color: return !appState.colorFilters.isEmpty || appState.colorSearchRGB != nil
        }
    }

    private func categoryBinding(_ category: FilterCategory) -> Binding<Bool> {
        Binding(get: { expandedCategory == category }, set: { visible in
            if !visible && expandedCategory == category { closeCategory() }
        })
    }

    private func closeCategory(apply: Bool = true) {
        if apply, draftDestination == appState.sidebarSelection { draft?.apply(to: appState) }
        draft = nil
        draftDestination = nil
        expandedCategory = nil
    }

    private func updateDraft(_ change: (inout LibraryFilterDraft) -> Void) {
        var value = draft ?? LibraryFilterDraft(appState)
        change(&value)
        draft = value
    }

    private var draftText: String { draft?.text ?? appState.filterText }

    @ViewBuilder private func categoryPopover(_ category: FilterCategory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(category.rawValue).font(.headline)
                Spacer()
                Button("Clear") { clearCategory(category) }.buttonStyle(.borderless).font(.caption)
            }
            switch category {
            case .platform: platformOptions
            case .tags: tagOptions
            case .type: typeOptions
            case .color: colorOptions
            }
            Divider()
            HStack {
                Text("Apply on Done or click away").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { closeCategory(apply: false) }.controlSize(.small)
                Button("Done") { closeCategory() }.controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }.padding(12).frame(width: category == .color ? 340 : 400)
    }

    private func clearCategory(_ category: FilterCategory) {
        updateDraft { value in
            switch category {
            case .platform:
                value.platform = nil
                value.text = LibraryFilterPresentation.removing(keys: ["platform"], from: value.text)
            case .tags: value.text = LibraryFilterPresentation.removing(keys: LibraryFilterPresentation.tagKeys, from: value.text)
            case .type: value.text = LibraryFilterPresentation.removing(keys: LibraryFilterPresentation.typeKeys, from: value.text)
            case .color: value.colors = []; value.preciseColor = nil
            }
        }
    }

    private var platformOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Narrow \(appState.libraryDestinationLabel). Conflicting platforms have no matches.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = viewModel.platformError {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button("Retry totals") { Task { await viewModel.refreshPlatforms() } }
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.availablePlatforms, id: \.self) { platform in
                        let selected = draft?.platform.map(MediaStore.canonicalPlatformName) == platform ||
                            MediaFilterBuilder.parseSearchInput(draftText).platforms.map(MediaStore.canonicalPlatformName).contains(platform)
                        Button {
                            updateDraft { value in
                                if selected {
                                    if value.platform.map(MediaStore.canonicalPlatformName) == platform { value.platform = nil }
                                    for token in LibraryFilterPresentation.tokens(in: value.text) where token.key == "platform" && MediaStore.canonicalPlatformName(token.value) == platform {
                                        value.text = LibraryFilterPresentation.removing(token, from: value.text)
                                    }
                                } else {
                                    value.platform = platform
                                    value.text = LibraryFilterPresentation.removing(keys: ["platform"], from: value.text)
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle").frame(width: 16)
                                Text(LibraryFilterPresentation.platformName(platform))
                                Spacer()
                                Text((viewModel.platformCounts[platform] ?? 0).formatted()).foregroundStyle(.secondary).monospacedDigit()
                            }.font(.caption).padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel("\(LibraryFilterPresentation.platformName(platform)) platform filter")
                            .accessibilityValue(selected ? "enabled" : "disabled")
                    }
                }
            }.frame(maxHeight: 260)
            Text("Counts are archive totals, not filtered estimates.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var matchingTags: [TagDefinition] {
        let matches = tagSettings.definitions.filter { tagSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(tagSearch) }
        guard !pinnedTagKeys.isEmpty else { return matches }
        let pinned = matches.filter { pinnedTagKeys.contains(TagCanonicalizer.key($0.name)) }
        return pinned + matches.filter { !pinnedTagKeys.contains(TagCanonicalizer.key($0.name)) }
    }

    private var tagOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Find a tag…", text: $tagSearch).textFieldStyle(.roundedBorder).accessibilityLabel("Find tag filter")
            Text("Click a tag to include it; use its menu to exclude or match exactly (without child tags). All tag rules must match.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if matchingTags.isEmpty { Text("No matching tags").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(matchingTags) { definition in
                        tagRow(definition)
                    }
                }
            }.frame(maxHeight: 280)
            Text("\(matchingTags.count) of \(tagSettings.definitions.count) tags").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private enum TagMode: String, CaseIterable {
        case off = "Off", include = "Include", exclude = "Exclude", includeExact = "Include exact", excludeExact = "Exclude exact"
        var isExclude: Bool { self == .exclude || self == .excludeExact }
        var symbol: String {
            switch self {
            case .off: return "circle"
            case .include, .includeExact: return "checkmark.circle.fill"
            case .exclude, .excludeExact: return "minus.circle.fill"
            }
        }
        var prefix: String {
            switch self {
            case .off: return ""
            case .include: return "tag"
            case .exclude: return "-tag"
            case .includeExact: return "tag-only"
            case .excludeExact: return "-tag-only"
            }
        }
    }

    private func tagMode(_ name: String) -> TagMode {
        let parsed = MediaFilterBuilder.parseSearchInput(draftText)
        let key = TagCanonicalizer.key(name)
        if let filter = parsed.tagFilters.last(where: { $0.name == key }) {
            switch (filter.polarity, filter.scope) {
            case (.include, .subtree): return .include
            case (.exclude, .subtree): return .exclude
            case (.include, .exact): return .includeExact
            case (.exclude, .exact): return .excludeExact
            }
        }
        return parsed.tags.contains(key) ? .include : .off
    }

    private func setTagMode(_ mode: TagMode, for definition: TagDefinition) {
        updateDraft { value in
            for token in LibraryFilterPresentation.tokens(in: value.text)
            where LibraryFilterPresentation.tagKeys.contains(token.key) && TagCanonicalizer.key(token.value) == TagCanonicalizer.key(definition.name) {
                value.text = LibraryFilterPresentation.removing(token, from: value.text)
            }
            if mode != .off {
                let quoted = definition.name.contains(where: \.isWhitespace) ? "\"\(definition.name)\"" : definition.name
                value.text = [value.text, "\(mode.prefix):\(quoted)"].filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
    }

    /// Dense row: clicking the name toggles the common Include rule; the trailing menu
    /// only spells out a mode when one is set, so a long list is not a wall of "Off".
    private func tagRow(_ definition: TagDefinition) -> some View {
        let mode = tagMode(definition.name)
        let tint: Color = mode == .off ? .secondary : (mode.isExclude ? .orange : .accentColor)
        return HStack(spacing: 6) {
            Button { setTagMode(mode == .off ? .include : .off, for: definition) } label: {
                HStack(spacing: 7) {
                    Image(systemName: mode.symbol).font(.system(size: 11)).foregroundStyle(tint).frame(width: 14)
                    Circle().fill(definition.color).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(definition.name).font(.caption).lineLimit(1).truncationMode(.middle)
                        .strikethrough(mode.isExclude, color: .orange.opacity(0.7))
                    Spacer(minLength: 4)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(mode == .off ? "Include \(definition.name) and its child tags" : "Turn off this tag rule")
            .accessibilityLabel("\(definition.name) tag filter")
            .accessibilityValue(mode.rawValue)
            .accessibilityHint("Toggles Include. Use the mode menu to exclude or match exactly.")
            Menu {
                ForEach(TagMode.allCases, id: \.self) { option in
                    Button { setTagMode(option, for: definition) } label: {
                        if option == mode { Label(option.rawValue, systemImage: "checkmark") } else { Text(option.rawValue) }
                    }
                }
            } label: {
                Text(mode == .off ? "" : mode.rawValue).font(.caption2).foregroundStyle(tint)
            }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
            .help("Include, exclude, or match this tag exactly")
            .accessibilityLabel("Filter mode for \(definition.name)")
            .accessibilityValue(mode.rawValue)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(mode == .off ? Color.clear : tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
    }

    private var typeOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Match any selected kind or extension.").font(.caption).foregroundStyle(.secondary)
            typeGroup("Media kind", options: fileTypeFilters, key: "type")
            Divider()
            typeGroup("File extension", options: fileExtensionFilters, key: "ext")
        }
    }

    private func typeGroup(_ title: String, options: [FileTypeFilterOption], key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 4) {
                ForEach(options) { option in
                    let active = typeOptionActive(option, key: key)
                    Button {
                        updateDraft { value in
                            if key == "ext" {
                                value.text = LibraryFilterPresentation.togglingExtensions(option.token, in: value.text)
                                return
                            }
                            let tokens = LibraryFilterPresentation.tokens(in: value.text).filter { token in
                                if key == "type" { return token.key == key && token.value.lowercased() == option.token }
                                return ["ext", "extension", "format", "file"].contains(token.key) && Set(token.value.lowercased().split(separator: ",").map(String.init)).isSubset(of: Set(option.token.split(separator: ",").map(String.init)))
                            }
                            for token in tokens { value.text = LibraryFilterPresentation.removing(token, from: value.text) }
                            if !active { value.text = [value.text, "\(key):\(option.token)"].filter { !$0.isEmpty }.joined(separator: " ") }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: active ? "checkmark.square.fill" : "square").frame(width: 14)
                            Text(option.label)
                            Spacer(minLength: 0)
                        }.font(.caption).padding(6).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(option.label) \(key == "type" ? "kind" : "extension") filter")
                        .accessibilityValue(active ? "enabled" : "disabled")
                }
            }
        }
    }

    private func typeOptionActive(_ option: FileTypeFilterOption, key: String) -> Bool {
        LibraryFilterPresentation.tokens(in: draftText).contains { token in
            if key == "type" { return token.key == key && token.value.lowercased() == option.token }
            let candidates = Set(option.token.split(separator: ",").map(String.init))
            return ["ext", "extension", "format", "file"].contains(token.key) && !Set(token.value.lowercased().split(separator: ",").map(String.init)).isDisjoint(with: candidates)
        }
    }

    private var colorOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Match any selected color. Precise color, when set, must also match.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                ForEach(ColorBucket.allCases, id: \.self) { bucket in
                    let active = draft?.colors.contains(bucket) ?? false
                    let color = bucket.uiColor
                    Button {
                        updateDraft { value in
                            if active { value.colors.remove(bucket) } else { value.colors.insert(bucket) }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Circle().fill(Color(red: color.red, green: color.green, blue: color.blue)).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 0.5))
                            Text(bucket.displayName).font(.caption)
                            Spacer(minLength: 0)
                            if active { Image(systemName: "checkmark").font(.caption) }
                        }.padding(6).contentShape(Rectangle())
                            .background(active ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(bucket.displayName) color filter")
                        .accessibilityValue(active ? "enabled" : "disabled")
                }
            }
            Divider()
            Button { showColorPicker = true } label: { Label("Precise color…", systemImage: "eyedropper").font(.caption) }
                .buttonStyle(.borderless)
                .popover(isPresented: $showColorPicker, arrowEdge: .trailing) {
                    PrecisionColorSearchPopover(colorSearch: Binding(get: { draft?.preciseColor }, set: { color in updateDraft { $0.preciseColor = color } }), stagesSelection: true)
                }
            if let precise = draft?.preciseColor {
                ColorSearchChip(colorSearch: precise) { updateDraft { $0.preciseColor = nil } }
            }
        }
    }

    private var viewOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("View options").font(.headline)
            sortMenu
            HStack { shuffleButton; if appState.isShuffleActive { reshuffleButton } }
            if appState.browseMode == .grid {
                Divider()
                Text("Grid density").font(.caption).foregroundStyle(.secondary)
                densitySlider
                Toggle("Group similar aspect ratios", isOn: $appState.useHybridLayout).font(.caption)
                    .help("Group similar aspect ratios into rows between columns")
                Toggle("Show color bars", isOn: $appState.showColorBars).font(.caption)
            }
            Divider()
            Button("Command Palette  ⌘K") { showViewOptions = false; appState.showCommandPalette = true }
                .buttonStyle(.borderless).font(.caption)
        }.padding(12).frame(width: 270)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SortOrder.allCases, id: \.self) { order in
                Button {
                    isSearchFocused = false
                    appState.commitLibraryFilterChange {
                        appState.sortOrder = order
                    }
                } label: {
                    if appState.sortOrder == order && !appState.isShuffleActive {
                        Label(order.displayName, systemImage: "checkmark")
                    } else {
                        Text(order.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                Text(appState.isShuffleActive ? "Sort" : appState.sortOrder.displayName)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .foregroundStyle(appState.isShuffleActive ? .secondary : Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(appState.isShuffleActive ? Color.clear : Color.accentColor.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(appState.isShuffleActive ? Color.clear : Color.accentColor.opacity(0.2), lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .help(appState.isShuffleActive ? "Sorting is ignored while shuffle is active" : "Sort library")
        .accessibilityLabel("Sort order")
    }

    private var shuffleButton: some View {
        Button {
            isSearchFocused = false
            appState.toggleShuffle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "shuffle")
                    .font(.system(size: 11))
                Text("Shuffle")
                    .font(.system(size: 11))
            }
            .foregroundStyle(appState.isShuffleActive ? Color.accentColor : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(appState.isShuffleActive ? Color.accentColor.opacity(0.1) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(appState.isShuffleActive ? Color.accentColor.opacity(0.2) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(appState.isShuffleActive ? "Turn shuffle off" : "Turn shuffle on")
        .accessibilityLabel("Shuffle")
        .accessibilityValue(appState.isShuffleActive ? "enabled" : "disabled")
        .accessibilityAddTraits(appState.isShuffleActive ? [.isSelected] : [])
    }

    private var reshuffleButton: some View {
        Button {
            isSearchFocused = false
            appState.reshuffle()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .help("Reshuffle")
        .accessibilityLabel("Reshuffle")
    }

    // MARK: - View Mode Toggle

    /// Hidden with the table browser (`FeatureFlags.tableBrowser`); code kept.
    @ViewBuilder private var viewModeToggle: some View {
        if FeatureFlags.tableBrowser { browseModePicker }
    }

    private var browseModePicker: some View {
        Picker("", selection: $appState.browseMode) {
            Label("Grid", systemImage: "square.grid.2x2")
                .tag(AppState.BrowseMode.grid)
            Label("Table", systemImage: "tablecells")
                .tag(AppState.BrowseMode.table)
        }
        .pickerStyle(.segmented)
        .frame(width: 130)
        .accessibilityLabel("View mode")
        .accessibilityValue(appState.browseMode == .grid ? "Grid" : "Table")
    }

    // MARK: - Density Slider

    private var densitySlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.grid.3x3")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $appState.gridDensity, in: 0...1)
                .frame(width: 80)
                .accessibilityLabel("Grid density")
                .accessibilityValue("\(Int(appState.gridDensity * 100)) percent")
            Image(systemName: "square.grid.2x2")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .help("Density: \(Int(appState.gridDensity * 100))%")
    }

    // MARK: - Inspector Toggle

    private var inspectorToggle: some View {
        Toggle(isOn: $appState.showInspectorPanel) {
            Image(systemName: "sidebar.right")
                .font(.caption)
        }
        .toggleStyle(.button)
        .help(appState.showInspectorPanel ? "Hide inspector (⌘I)" : "Show inspector (⌘I)")
        .accessibilityLabel("Inspector panel")
        .accessibilityValue(appState.showInspectorPanel ? "visible" : "hidden")
        .accessibilityHint("Toggle metadata inspector panel")
        .accessibilityIdentifier("inspector-toggle")
    }


}

// VIEW_MODEL

// MARK: - Filter Toggle Chip

struct FilterToggleChip: View {
    let label: String
    let icon: String
    let isActive: Bool
    let activeColor: Color
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isActive ? activeColor.opacity(0.2) : Color.clear)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isActive ? activeColor : Color.secondary.opacity(0.3),
                                lineWidth: 1
                            )
                    )
            )
            .foregroundStyle(isActive ? activeColor : .secondary)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(label) filter")
        .accessibilityValue(isActive ? "enabled" : "disabled")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

// MARK: - Platform Filter Chip

struct PlatformFilterChip: View {
    let platform: String
    let isSelected: Bool
    var count: Int? = nil
    let action: () -> Void

    @State private var isHovered: Bool = false

    private var platformIcon: String {
        switch platform.lowercased() {
        case "twitter", "x": return "bird"
        case "instagram": return "camera"
        case "reddit": return "link"
        case "tumblr": return "t.square"
        case "bluesky", "bsky": return "cloud"
        case "mastodon": return "elephant"
        default: return "globe"
        }
    }

    private var platformColor: Color {
        switch platform.lowercased() {
        case "twitter", "x": return .blue
        case "instagram": return .pink
        case "reddit": return .orange
        case "tumblr": return .indigo
        case "bluesky", "bsky": return .cyan
        case "mastodon": return .purple
        default: return .gray
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: platformIcon)
                    .font(.caption2)
                Text(LibraryFilterPresentation.platformName(platform))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let count = count {
                    Text(count.formatted(.number))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isSelected ? AnyShapeStyle(platformColor.opacity(0.8)) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isSelected ? platformColor.opacity(0.2) : Color.clear)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isSelected ? platformColor : Color.secondary.opacity(0.3),
                                lineWidth: 1
                            )
                    )
            )
            .foregroundStyle(isSelected ? platformColor : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(LibraryFilterPresentation.platformName(platform)) platform filter, \((count ?? 0).formatted(.number)) items")
        .accessibilityValue(isSelected ? "enabled" : "disabled")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Preview

#if DEBUG
struct SearchFilterBar_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            SearchFilterBar()
                .environmentObject(AppState())

            Spacer()
        }
        .frame(width: 1000, height: 200)
        .background(Color(hex: 0x1a1a1a))
        .preferredColorScheme(.dark)
    }
}
#endif
