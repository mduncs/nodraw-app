import SwiftUI

/// The textual query remains available to power users. Ordinary controls present
/// the same constraints as names, and clearing/removal uses the real parser.
enum LibraryFilterPresentation {
    /// Brand-cased platform label for display only; stored values and query tokens stay lowercase.
    static func platformName(_ raw: String) -> String {
        let key = MediaStore.canonicalPlatformName(raw)
        return platformNames[key] ?? key.capitalized
    }

    private static let platformNames = [
        "youtube": "YouTube", "tiktok": "TikTok", "x": "X", "googlearts": "Google Arts",
        "deviantart": "DeviantArt", "artstation": "ArtStation", "github": "GitHub",
    ]

    struct Token: Identifiable, Equatable {
        let raw: String
        let key: String
        let value: String
        let label: String
        var id: String { raw }
    }

    static func tokens(in text: String) -> [Token] {
        var seen = Set<String>()
        return MediaFilterBuilder.tokenizeSearchInput(text).compactMap { raw in
            let parsed = MediaFilterBuilder.parseSearchInput(raw)
            guard parsed.hasStructuredFilters,
                  let colon = raw.firstIndex(of: ":"), seen.insert(raw).inserted else { return nil }
            let key = String(raw[..<colon]).lowercased()
            let value = parsed.exactAuthor ?? String(raw[raw.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let label: String
            switch key {
            case "tag", "tags": label = value.lowercased() == "none" ? "Without tags" : "Tag: \(value) + children"
            case "-tag", "not-tag", "exclude-tag": label = "Without tag: \(value) + children"
            case "tag-only", "tags-only": label = "Tag: \(value) only"
            case "-tag-only", "not-tag-only", "exclude-tag-only": label = "Without tag: \(value) only"
            case "type": label = "Kind: \(value.capitalized)"
            case "ext", "extension", "format", "file": label = "Format: \(value.uppercased())"
            case "platform": label = "Platform: \(platformName(value))"
            case "folder": label = "Folder: \(value)"
            case "recent": label = "Archived in last \(value.hasSuffix("d") ? String(value.dropLast()) : value) days"
            case "ratio", "aspect", "aspectratio", "dims", "dim", "dimensions": label = "Shape: \(value)"
            case "author": label = "Author: \(value)"
            case "source", "url": label = "Source contains: \(value)"
            case "ocr": label = "Extracted text: \(value)"
            case "note", "notes": label = "Notes: \(value)"
            default: label = "\(key.capitalized): \(value)"
            }
            return Token(raw: raw, key: key, value: value, label: label)
        }
    }

    static func removing(_ token: Token, from text: String) -> String {
        MediaFilterBuilder.tokenizeSearchInput(text).filter { $0 != token.raw }.joined(separator: " ")
    }

    static func removing(keys: Set<String>, from text: String) -> String {
        let removed = Set(tokens(in: text).filter { keys.contains($0.key) }.map(\.raw))
        return MediaFilterBuilder.tokenizeSearchInput(text).filter { !removed.contains($0) }.joined(separator: " ")
    }

    static func replacingFreeText(in text: String, with freeText: String) -> String {
        ([freeText] + tokens(in: text).map(\.raw)).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Toggle an extension inside a combined advanced token without dropping its neighbours.
    static func togglingExtensions(_ extensions: String, in text: String) -> String {
        let choices = Set(extensions.lowercased().split(separator: ",").map(String.init))
        let formatTokens = tokens(in: text).filter { ["ext", "extension", "format", "file"].contains($0.key) }
        let isActive = formatTokens.contains { !Set($0.value.lowercased().split(separator: ",").map(String.init)).isDisjoint(with: choices) }
        guard isActive else { return [text, "ext:\(extensions)"].filter { !$0.isEmpty }.joined(separator: " ") }
        let affected = Dictionary(uniqueKeysWithValues: formatTokens.map { ($0.raw, $0) })
        return MediaFilterBuilder.tokenizeSearchInput(text).compactMap { raw -> String? in
            guard let token = affected[raw] else { return raw }
            let remaining = token.value.lowercased().split(separator: ",").map(String.init).filter { !choices.contains($0) }
            return remaining.isEmpty ? nil : "\(token.key):\(remaining.joined(separator: ","))"
        }.joined(separator: " ")
    }

    static let tagKeys: Set<String> = ["tag", "tags", "-tag", "not-tag", "exclude-tag", "tag-only", "tags-only", "-tag-only", "not-tag-only", "exclude-tag-only"]
    static let typeKeys: Set<String> = ["type", "ext", "extension", "format", "file"]
}

@MainActor
extension AppState {
    var hasLibraryNarrowingFilters: Bool {
        MediaFilterBuilder.hasStructuredSearchFilters(in: filterText) || dateRangeFilter != nil ||
        platformFilter != nil || starredFilter != nil || hasOCRFilter != nil ||
        !colorFilters.isEmpty || colorSearchRGB != nil || !pipelineAttributeFilters.isEmpty
    }

    var hasLibrarySearchOrFilters: Bool { !filterText.isEmpty || hasLibraryNarrowingFilters }

    /// Destination and safety preferences are not query controls. Both remain explicit.
    func resetLibrarySearchAndFilters() {
        commitLibraryFilterChange { clearLibrarySearchAndFilterState() }
    }

    /// Uncommitted mutation; callers wrap it in exactly one history transition.
    func clearLibrarySearchAndFilterState() {
        filterText = ""
        dateRangeFilter = nil
        platformFilter = nil
        starredFilter = nil
        hasOCRFilter = nil
        colorFilters = []
        colorSearchRGB = nil
        pipelineAttributeFilters = []
    }

    var libraryDestinationLabel: String {
        switch sidebarSelection {
        case .allMedia: return "All Media"
        case .platform(let name): return LibraryFilterPresentation.platformName(name)
        case .folder(let name): return name
        case .folderYear(let year): return String(year)
        case .tag(let name): return "Tag: \(name)"
        case .smartFolder: return activeSmartFolder?.name ?? "Smart folder"
        case .recentlyDeleted: return "Recently Deleted"
        default: return "Current destination"
        }
    }
}

struct LibraryFilterDraft: Equatable {
    var text: String
    var platform: String?
    var colors: Set<ColorBucket>
    var preciseColor: ColorSearchRGB?

    @MainActor init(_ appState: AppState) {
        text = appState.filterText
        platform = appState.platformFilter
        colors = appState.colorFilters
        preciseColor = appState.colorSearchRGB
    }

    @MainActor func apply(to appState: AppState) {
        guard self != LibraryFilterDraft(appState) else { return }
        appState.commitLibraryFilterChange {
            // @Published also emits for equal assignments. Only change the edited
            // dimensions so a popover commit cannot invalidate unrelated queries.
            if appState.filterText != text { appState.filterText = text }
            if appState.platformFilter != platform { appState.platformFilter = platform }
            if appState.colorFilters != colors { appState.colorFilters = colors }
            if appState.colorSearchRGB != preciseColor { appState.colorSearchRGB = preciseColor }
        }
    }
}

struct LibraryActiveFiltersView: View {
    enum Layout { case toolbar, centered }
    /// Toolbar rows pin Reset to the trailing edge; the empty state keeps it beside the chips.
    var layout: Layout = .toolbar
    @EnvironmentObject var appState: AppState
    @State private var showingAll = false

    private struct Chip: Identifiable {
        let id: String
        let label: String
        let remove: () -> Void
    }

    private var chips: [Chip] {
        var values = LibraryFilterPresentation.tokens(in: appState.filterText).map { token in
            Chip(id: "token-" + token.raw, label: token.label) {
                appState.commitLibraryFilterChange {
                    appState.filterText = LibraryFilterPresentation.removing(token, from: appState.filterText)
                }
            }
        }
        if let platform = appState.platformFilter {
            values.append(Chip(id: "platform", label: "Platform: \(LibraryFilterPresentation.platformName(platform))") { mutate { appState.platformFilter = nil } })
        }
        if let starred = appState.starredFilter {
            values.append(Chip(id: "starred", label: starred ? "Starred" : "Not starred") { mutate { appState.starredFilter = nil } })
        }
        if let text = appState.hasOCRFilter {
            values.append(Chip(id: "ocr", label: text ? "Has extracted text" : "No extracted text") { mutate { appState.hasOCRFilter = nil } })
        }
        if let range = appState.dateRangeFilter {
            let start = range.lowerBound.formatted(date: .abbreviated, time: .omitted)
            let end = range.upperBound.formatted(date: .abbreviated, time: .omitted)
            values.append(Chip(id: "date", label: "Archived: \(start) – \(end)") { mutate { appState.dateRangeFilter = nil } })
        }
        for color in appState.colorFilters.sorted(by: { $0.displayName < $1.displayName }) {
            values.append(Chip(id: "color-" + color.rawValue, label: "Color: " + color.displayName) { mutate { appState.colorFilters.remove(color) } })
        }
        if let color = appState.colorSearchRGB {
            values.append(Chip(id: "precise", label: "Precise color: \(color.r), \(color.g), \(color.b)") { mutate { appState.colorSearchRGB = nil } })
        }
        for (index, attribute) in appState.pipelineAttributeFilters.enumerated() {
            values.append(Chip(id: "attribute-\(index)", label: "\(attribute.module.rawValue.capitalized): \(attribute.key)") {
                mutate { appState.pipelineAttributeFilters.removeAll { $0 == attribute } }
            })
        }
        return values
    }

    private func mutate(_ action: () -> Void) { appState.commitLibraryFilterChange(action) }

    var body: some View {
        HStack(spacing: 8) {
            if !chips.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) {
                        ForEach(Array(chips.prefix(3))) { chip in chipView(chip).fixedSize() }
                        if chips.count > 3 { allButton(label: "+\(chips.count - 3) more") }
                    }
                    allButton(label: "\(chips.count) active filters")
                }
            } else {
                Text("Search in \(appState.libraryDestinationLabel)").font(.caption).lineLimit(1)
            }
            if layout == .toolbar { Spacer(minLength: 0) }
            Button("Reset") { appState.resetLibrarySearchAndFilters() }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Clear search and all filters; keep the current destination")
                .accessibilityLabel("Reset search and all filters")
        }
        .popover(isPresented: $showingAll, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Active filters").font(.headline)
                Text("Narrowing \(appState.libraryDestinationLabel). All groups must match; kinds/extensions and color buckets each match any selected option.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(chips) { chip in chipView(chip) }
                    }
                }.frame(maxHeight: 300)
                Button("Done") { showingAll = false }.frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(12).frame(width: 360)
        }
    }

    private func allButton(label: String) -> some View {
        Button(label) { showingAll = true }.buttonStyle(.borderless).font(.caption)
            .accessibilityLabel("Show all \(chips.count) active filters")
    }

    private func chipView(_ chip: Chip) -> some View {
        HStack(spacing: 6) {
            Text(chip.label).font(.caption).fixedSize(horizontal: false, vertical: true)
            Button(action: chip.remove) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain).accessibilityLabel("Remove \(chip.label)").help("Remove \(chip.label)")
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct LibraryEmptyResultsView: View {
    @EnvironmentObject var appState: AppState
    /// "No matches" only when a search or filter is narrowing things; otherwise the destination
    /// itself is empty and the copy says so.
    private var isFiltered: Bool { appState.hasLibrarySearchOrFilters }
    private var isEmptyLibrary: Bool { !isFiltered && appState.sidebarSelection == .allMedia }

    private var symbol: String {
        if isFiltered { return "magnifyingglass" }
        if isEmptyLibrary { return "photo.on.rectangle.angled" }
        if case .smartFolder = appState.sidebarSelection { return "gearshape.2" }
        return "tray"
    }

    private var title: String {
        if isFiltered { return "No matches in \(appState.libraryDestinationLabel)" }
        if isEmptyLibrary { return "Your library is empty" }
        return "\(appState.libraryDestinationLabel) is empty"
    }

    private var message: String {
        if isFiltered {
            return "These choices must all match. Remove a filter, reset this search, or choose a broader destination."
        }
        if isEmptyLibrary {
            return "Drop images or videos onto this window to import them, or save posts with the NoDraw browser extension."
        }
        if case .smartFolder = appState.sidebarSelection {
            return "No items currently match this smart folder's rules."
        }
        return "Nothing here yet."
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(message)
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if isFiltered { LibraryActiveFiltersView(layout: .centered) }
            if appState.sidebarSelection != .allMedia {
                // One Back step returns to this exact empty query.
                Button("Browse All Media") { appState.commitLibraryDestinationChange(.allMedia, clearingQuery: true) }
                    .help("Show everything: All Media with search and filters cleared")
            }
        }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
