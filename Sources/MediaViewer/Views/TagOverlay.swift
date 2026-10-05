import SwiftUI
import AppKit

// MARK: - TagOverlay

/// Hold-to-tag selector. Hold the modifier, then click tags, or release over one to
/// toggle it. Typing filters every layout, path-aware. While the modifier is held,
/// releasing it toggles the highlighted match. Tab, the filter field or + keeps the
/// selector open after release so a name can be typed normally.
struct TagOverlay: View {
    let currentTags: [String]
    let onTagsChanged: ([String]) -> Void
    var onDismiss: (() -> Void)?
    var position: CGPoint?
    @Binding var hoveredTagName: String?

    @ObservedObject private var tagSettings = TagSettings.shared
    @State private var selectedTags: Set<String> = []
    /// Typing must survive releasing the hold-to-tag modifier.
    var onBeginTextEntry: () -> Void = {}

    // Filter / new-tag entry
    @State private var query: String = ""
    @State private var highlightIndex: Int = 0
    @FocusState private var isQueryFocused: Bool
    @State private var isPinned = false
    @State private var resultsContentHeight: CGFloat = 0

    // Wheel drill-down (sunburst and radial). Empty = top level.
    @State private var wheelPath: [TagWheelLayout.Focus] = []
    @State private var hoveredSegmentID: String?
    @State private var drillTransition = false

    // Grid
    @State private var expandedRootIDs: Set<UUID>
    @State private var gridContentHeight: CGFloat = 0
    @State private var gridResizeStartScale: Double?

    /// Last name offered to the host as the release target, and tags added this
    /// session. Recents are recorded on close so the recents row never reorders
    /// under the pointer.
    @State private var releaseCandidate: String?
    @State private var usedTagNames: [String] = []
    @StateObject private var keyMonitor = TagOverlayKeyMonitor()

    /// Grid sections start expanded only for small vocabularies.
    private static let expandAllGridRootsUpTo = 60
    private static let resultLimit = 80

    init(currentTags: [String], onTagsChanged: @escaping ([String]) -> Void, onDismiss: (() -> Void)? = nil, position: CGPoint? = nil, hoveredTagName: Binding<String?> = .constant(nil), onBeginTextEntry: @escaping () -> Void = {}) {
        self.currentTags = currentTags
        self.onTagsChanged = onTagsChanged
        self.onDismiss = onDismiss
        self.position = position
        self._hoveredTagName = hoveredTagName
        self.onBeginTextEntry = onBeginTextEntry
        self._selectedTags = State(initialValue: Set(currentTags))
        let settings = TagSettings.shared
        self._expandedRootIDs = State(initialValue: settings.definitions.count <= Self.expandAllGridRootsUpTo
            ? Set(settings.rootTags().map(\.id))
            : [])
    }

    private var allTags: [TagDefinition] {
        tagSettings.definitions.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Canonical keys of the working selection. Items can carry a spelling that
    /// differs from the definition (e.g. "Cats" vs "cats"); both are the same tag.
    private var selectedKeys: Set<String> {
        Set(selectedTags.map(TagCanonicalizer.key))
    }

    private func isSelected(_ name: String) -> Bool {
        selectedKeys.contains(TagCanonicalizer.key(name))
    }

    private var hasHierarchy: Bool {
        tagSettings.definitions.contains { $0.parentId != nil }
    }

    /// IDs of every ancestor of a selected tag, so collapsed or off-screen branches
    /// can show that they contain part of the selection.
    private var selectedAncestorIDs: Set<UUID> {
        let keys = selectedKeys
        var result = Set<UUID>()
        for definition in tagSettings.definitions where keys.contains(TagCanonicalizer.key(definition.name)) {
            result.formUnion(tagSettings.ancestors(of: definition.id).map(\.id))
        }
        return result
    }

    private var scale: CGFloat { CGFloat(tagSettings.gridScale) }

    /// A flat vocabulary has nothing for a second ring, so it uses the one-ring wheel.
    private var wheelStyle: TagWheelLayout.Style? {
        switch tagSettings.layout {
        case .grid: return nil
        case .radial: return .radial
        case .sunburst: return hasHierarchy ? .sunburst : .radial
        }
    }

    private var wheelDiameter: CGFloat { (400 * scale).rounded() }
    private var baseGridWidth: CGFloat { hasHierarchy ? 640 : 540 }
    private var gridWidth: CGFloat { (baseGridWidth * scale).rounded() }
    private var gridMaxHeight: CGFloat { (480 * scale).rounded() }

    private var surfaceWidth: CGFloat { wheelStyle == nil ? gridWidth : wheelDiameter }
    private var bodyMaxHeight: CGFloat { wheelStyle == nil ? gridMaxHeight : wheelDiameter }

    var body: some View {
        let rows = resultRows
        VStack(spacing: 8) {
            header(rows: rows)

            if !TagCanonicalizer.key(query).isEmpty {
                resultsList(rows)
            } else if let style = wheelStyle {
                wheel(style: style)
            } else {
                tagGrid
            }

            footer
        }
        .frame(width: surfaceWidth)
        .modifier(KeepInsideWindow())
        .onChange(of: selectedTags) { _, newValue in
            onTagsChanged(Array(newValue).sorted())
        }
        .onChange(of: query) { _, _ in
            highlightIndex = 0
            offerHighlightAsReleaseTarget()
        }
        .onChange(of: isQueryFocused) { _, focused in
            if focused { pin() }
        }
        .onAppear {
            keyMonitor.start(onKeyDown: handleKeyDown, onFlagsChanged: handleFlagsChanged)
        }
        .onDisappear {
            keyMonitor.stop()
            for name in usedTagNames.reversed() {
                tagSettings.recordTagUsage(named: name)
            }
        }
        .background(
            Button("") { onDismiss?() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
        )
    }

    // MARK: - Header (filter, recents, breadcrumb)

    private func header(rows: [ResultRow]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                ZStack(alignment: .leading) {
                    if query.isEmpty {
                        Text(isQueryFocused ? "Search or name a new tag" : "Type to filter \(tagSettings.definitions.count) tags")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($isQueryFocused)
                        .onSubmit { activateHighlight() }
                        .onExitCommand {
                            if query.isEmpty { onDismiss?() } else { query = "" }
                        }
                }

                if !query.isEmpty {
                    Text("\(rows.filter(\.isTag).count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }

                Button(action: beginTyping) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.accentOrange))
                }
                .buttonStyle(.plain)
                .help("Search or add a tag · stays open after you release \(modifierSymbol); click outside to close")
            }

            if query.isEmpty {
                if wheelStyle != nil, !wheelPath.isEmpty {
                    breadcrumb
                } else if !recentTags.isEmpty {
                    recentsRow
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(surfaceBackground(cornerRadius: 10))
    }

    private var recentTags: [TagDefinition] {
        Array(tagSettings.recentTags.prefix(8))
    }

    private var recentsRow: some View {
        HStack(spacing: 5) {
            Text("Recent")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            // Chips that do not fit the width are dropped rather than wrapped.
            ViewThatFits(in: .horizontal) {
                ForEach(stride(from: recentTags.count, through: 1, by: -1).map { $0 }, id: \.self) { count in
                    HStack(spacing: 5) {
                        ForEach(recentTags.prefix(count)) { tag in
                            recentChip(tag)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func recentChip(_ tag: TagDefinition) -> some View {
        let selected = isSelected(tag.name)
        return Button {
            toggleTag(tag.name)
        } label: {
            HStack(spacing: 4) {
                Circle().fill(tag.color).frame(width: 6, height: 6)
                Text(tag.name)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: 74)
                    .fixedSize()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(selected ? tag.color.opacity(0.35) : Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(selected ? tag.color.opacity(0.8) : Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { offerReleaseTarget(tag.name) } else if hoveredTagName == tag.name { offerReleaseTarget(nil) }
        }
        .help(tagSettings.fullPath(of: tag.id))
    }

    private var breadcrumb: some View {
        HStack(spacing: 3) {
            crumbButton("All", depth: 0)
            ForEach(Array(wheelPath.enumerated()), id: \.offset) { index, focus in
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                crumbButton(crumbTitle(for: focus), depth: index + 1)
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private func crumbTitle(for focus: TagWheelLayout.Focus) -> String {
        let name = focus.parentID.flatMap { id in tagSettings.definitions.first { $0.id == id }?.name } ?? "All"
        return focus.offset > 0 ? "\(name) (more)" : name
    }

    private func crumbButton(_ title: String, depth: Int) -> some View {
        let isCurrent = depth == wheelPath.count
        return Button {
            guard !isCurrent else { return }
            navigateWheel(to: Array(wheelPath.prefix(depth)))
        } label: {
            Text(title)
                .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text(footerHint)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            ForEach(TagGridSizePreset.allCases, id: \.self) { preset in
                let selected = preset.isSelected(scale: tagSettings.gridScale)
                Button {
                    tagSettings.gridScale = preset.scale
                } label: {
                    Text(preset.label)
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 16)
                        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentOrange.opacity(0.25) : Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.accentOrange.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color.accentOrange : .secondary)
                .help(preset.help)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(hex: 0x161616).opacity(0.9)))
    }

    private var modifierSymbol: String {
        switch tagSettings.modifierKey {
        case .option: return "⌥"
        case .control: return "⌃"
        case .command: return "⌘"
        case .optionShift: return "⌥⇧"
        }
    }

    private var footerHint: String {
        if !isPinned, let name = hoveredTagName {
            return "release \(modifierSymbol) to toggle \(name)"
        }
        if !query.isEmpty {
            return isPinned ? "↑↓ pick · ⏎ toggle · esc clear" : "↑↓ pick · ⏎ toggle · ⇥ keep open"
        }
        switch wheelStyle {
        case .some: return "click toggles · double-click or rim opens · type to filter"
        case .none: return "click toggles · ▸ expands · type to filter"
        }
    }

    // MARK: - Filter results

    private enum ResultRow: Identifiable {
        case tag(TagDefinitionSearch.Match)
        case create(String)

        var id: String {
            switch self {
            case .tag(let match): return match.definition.id.uuidString
            case .create(let name): return "create-\(name)"
            }
        }

        var isTag: Bool {
            if case .tag = self { return true }
            return false
        }

        var tagName: String? {
            if case .tag(let match) = self { return match.definition.name }
            return nil
        }
    }

    /// Ranked, path-aware matches, then an explicit create row when the typed name
    /// is not an existing tag. The create row is last so Return picks a match first.
    private var resultRows: [ResultRow] {
        guard !TagCanonicalizer.key(query).isEmpty else { return [] }
        var rows = TagDefinitionSearch.matches(query: query, in: tagSettings.definitions, limit: Self.resultLimit)
            .map(ResultRow.tag)
        if let name = TagDefinitionSearch.resolvedDisplayName(for: query, in: tagSettings.definitions),
           TagDefinitionSearch.existingDefinition(named: name, in: tagSettings.definitions) == nil {
            rows.append(.create(name))
        }
        return rows
    }

    private func resultsList(_ rows: [ResultRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        resultRow(row, index: index)
                            .id(index)
                    }
                    if rows.filter(\.isTag).count >= Self.resultLimit {
                        Text("Showing the first \(Self.resultLimit) · keep typing to narrow")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { resultsContentHeight = $0 }
            }
            .onChange(of: highlightIndex) { _, index in
                proxy.scrollTo(index)
            }
        }
        .frame(width: surfaceWidth, height: min(max(resultsContentHeight, 40), bodyMaxHeight))
        .background(surfaceBackground(cornerRadius: 12))
        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
    }

    @ViewBuilder
    private func resultRow(_ row: ResultRow, index: Int) -> some View {
        let highlighted = index == highlightIndex
        switch row {
        case .tag(let match):
            let tag = match.definition
            let selected = isSelected(tag.name)
            Button {
                highlightIndex = index
                toggleTag(tag.name)
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(tag.color).frame(width: 8, height: 8)
                    Text(tag.name)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !match.ancestors.isEmpty {
                        Text(match.ancestorLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? tag.color.opacity(0.28) : (highlighted ? Color.white.opacity(0.08) : .clear)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(highlighted ? Color.accentOrange.opacity(0.8) : .clear, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    highlightIndex = index
                    offerReleaseTarget(tag.name)
                }
            }
        case .create(let name):
            Button {
                highlightIndex = index
                createTag(named: name)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentOrange)
                    Text("Create “\(name)”")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? Color.white.opacity(0.08) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(highlighted ? Color.accentOrange.opacity(0.8) : .clear, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    highlightIndex = index
                    offerReleaseTarget(nil)
                }
            }
        }
    }

    // MARK: - Wheel (sunburst / radial)

    private var wheelFocus: TagWheelLayout.Focus { wheelPath.last ?? .root }

    private func wheel(style: TagWheelLayout.Style) -> some View {
        let diameter = wheelDiameter
        let focusName = wheelFocus.parentID.flatMap { id in tagSettings.definitions.first { $0.id == id }?.name }
        let layout = TagWheelLayout(style: style, diameter: diameter, focus: wheelFocus, focusParentName: focusName) { parentID in
            parentID.map { tagSettings.children(of: $0) } ?? tagSettings.rootTags()
        }
        let ancestorIDs = selectedAncestorIDs
        let center = CGPoint(x: diameter / 2, y: diameter / 2)

        return ZStack {
            ForEach(layout.segments) { segment in
                TagWheelSegmentView(
                    segment: segment,
                    isSelected: segment.kind.isTag && segment.tag.map { isSelected($0.name) } == true,
                    isHovered: hoveredSegmentID == segment.id,
                    containsSelection: segment.tag.map { ancestorIDs.contains($0.id) } == true
                )
            }
            wheelHub(layout: layout)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let point = CGPoint(x: location.x - center.x, y: location.y - center.y)
                let segment = layout.segment(at: point)
                hoveredSegmentID = segment?.id
                if let segment, case .tag(let tag) = segment.kind {
                    offerReleaseTarget(tag.name)
                } else {
                    offerReleaseTarget(nil)
                }
            case .ended:
                hoveredSegmentID = nil
                offerReleaseTarget(nil)
            }
        }
        .gesture(
            SpatialTapGesture().onEnded { value in
                let point = CGPoint(x: value.location.x - center.x, y: value.location.y - center.y)
                handleWheelTap(at: point, layout: layout)
            }
        )
        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
        .opacity(drillTransition ? 0 : 1)
        .scaleEffect(drillTransition ? 0.85 : 1)
    }

    private func handleWheelTap(at point: CGPoint, layout: TagWheelLayout) {
        if layout.isInsideHub(point) {
            if !wheelPath.isEmpty { navigateWheel(to: Array(wheelPath.dropLast())) }
            return
        }
        guard let segment = layout.segment(at: point) else { return }
        switch segment.kind {
        case .tag(let tag):
            // A double-click opens a branch. Its first click already toggled the tag,
            // so the second click toggles it back before drilling in.
            let isDoubleClick = (NSApp?.currentEvent?.clickCount ?? 1) >= 2
            if isDoubleClick, !tagSettings.isLeaf(tag.id) {
                toggleTag(tag.name)
                navigateWheel(to: wheelPath + [TagWheelLayout.Focus(parentID: tag.id)])
            } else {
                toggleTag(tag.name)
            }
        case .more(_, let focus):
            navigateWheel(to: wheelPath + [focus])
        case .drill(let tag):
            navigateWheel(to: wheelPath + [TagWheelLayout.Focus(parentID: tag.id)])
        }
    }

    private func navigateWheel(to path: [TagWheelLayout.Focus]) {
        withAnimation(.easeInOut(duration: 0.12)) {
            drillTransition = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            wheelPath = path
            hoveredSegmentID = nil
            offerReleaseTarget(nil)
            withAnimation(.easeInOut(duration: 0.15)) {
                drillTransition = false
            }
        }
    }

    private func wheelHub(layout: TagWheelLayout) -> some View {
        let hubDiameter = layout.metrics.hubRadius * 2 - 4
        let hovered = layout.segments.first { $0.id == hoveredSegmentID }

        return Circle()
            .fill(Color(hex: 0x1a1a1a))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .frame(width: hubDiameter, height: hubDiameter)
            .overlay(
                VStack(spacing: 2) {
                    if let hovered {
                        hubText(for: hovered)
                    } else if !wheelPath.isEmpty {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                        Text(crumbTitle(for: wheelFocus))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    } else if layout.segments.isEmpty {
                        Text("no tags")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(selectedTags.count)")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                        Text(selectedTags.count == 1 ? "tag" : "tags")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: hubDiameter * 0.82)
            )
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func hubText(for segment: TagWheelLayout.Segment) -> some View {
        switch segment.kind {
        case .tag(let tag):
            let ancestors = tagSettings.ancestors(of: tag.id).reversed().map(\.name)
            Text(tag.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if !ancestors.isEmpty {
                Text(ancestors.joined(separator: " › "))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .multilineTextAlignment(.center)
            }
            if !tagSettings.isLeaf(tag.id) {
                Text("\(tagSettings.childCount(of: tag.id)) inside · double-click")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        case .more(let count, _):
            Text("+\(count) more")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text("click to show")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        case .drill(let tag):
            Text("Open")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(tag.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Grid Layout

    private var tagGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if allTags.isEmpty {
                    Text("No tags yet · press + to add one")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else if hasHierarchy {
                    let ancestorIDs = selectedAncestorIDs
                    ForEach(tagSettings.rootTags()) { root in
                        rootSection(root, containsSelection: ancestorIDs.contains(root.id))
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 200), spacing: 6, alignment: .topLeading)],
                              alignment: .leading, spacing: 6) {
                        ForEach(allTags) { tag in
                            tagGridPill(tag, path: nil)
                        }
                    }
                }
            }
            .padding(10)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { gridContentHeight = $0 }
        }
        .frame(width: gridWidth, height: min(max(gridContentHeight, 60), gridMaxHeight))
        .background(surfaceBackground(cornerRadius: 12))
        .overlay(alignment: .bottomTrailing) {
            tagGridResizeHandle
        }
        .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 10)
    }

    /// One top-level tag: a header row that toggles the tag itself and expands its
    /// subtree, and when expanded, every descendant as a pill with its sub-path.
    private func rootSection(_ root: TagDefinition, containsSelection: Bool) -> some View {
        let descendants = flattenedDescendants(of: root)
        let isExpanded = expandedRootIDs.contains(root.id)
        let selectedInside = descendants.filter { isSelected($0.tag.name) }.count

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if descendants.isEmpty {
                    Color.clear.frame(width: 14, height: 14)
                } else {
                    Button {
                        toggleExpanded(root.id)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse" : "Expand")
                }

                tagGridPill(root, path: nil)
                    .fixedSize()

                if !descendants.isEmpty {
                    Button {
                        toggleExpanded(root.id)
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(descendants.count)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                            if !isExpanded {
                                Text(descendants.prefix(6).map(\.tag.name).joined(separator: ", "))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary.opacity(0.8))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if selectedInside > 0 || (containsSelection && !isExpanded) {
                    HStack(spacing: 2) {
                        Text("\(selectedInside)")
                        Image(systemName: "checkmark")
                    }
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(root.color.opacity(0.45)))
                }
            }

            if isExpanded, !descendants.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 220), spacing: 6, alignment: .topLeading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(descendants, id: \.tag.id) { entry in
                        tagGridPill(entry.tag, path: entry.path)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 9).fill(root.color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(root.color.opacity(0.22), lineWidth: 1))
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedRootIDs.contains(id) {
            expandedRootIDs.remove(id)
        } else {
            expandedRootIDs.insert(id)
        }
    }

    /// Depth-first descendants in sibling order, each with its path below `root`.
    private func flattenedDescendants(of root: TagDefinition) -> [(tag: TagDefinition, path: String?)] {
        var result: [(tag: TagDefinition, path: String?)] = []
        var visited: Set<UUID> = [root.id]
        func visit(_ parent: TagDefinition, trail: [String]) {
            for child in tagSettings.children(of: parent.id) where visited.insert(child.id).inserted {
                result.append((child, trail.isEmpty ? nil : trail.joined(separator: " › ")))
                visit(child, trail: trail + [child.name])
            }
        }
        visit(root, trail: [])
        return result
    }

    private var tagGridResizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.55))
            .frame(width: 24, height: 24)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomTrailingRadius: 12)
                    .fill(Color.white.opacity(0.08))
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if gridResizeStartScale == nil {
                            gridResizeStartScale = tagSettings.gridScale
                        }
                        let start = gridResizeStartScale ?? tagSettings.gridScale
                        let dominantDelta = max(value.translation.width / baseGridWidth, value.translation.height / 480)
                        tagSettings.gridScale = start + Double(dominantDelta)
                    }
                    .onEnded { _ in
                        gridResizeStartScale = nil
                    }
            )
            .help("Resize tag selector")
    }

    private func tagGridPill(_ tag: TagDefinition, path: String?) -> some View {
        let selected = isSelected(tag.name)

        return Button {
            toggleTag(tag.name)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(tag.color)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 0) {
                    Text(tag.name)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let path {
                        Text(path)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Spacer(minLength: 2)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? tag.color.opacity(0.3) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? tag.color.opacity(0.85) : Color.white.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                offerReleaseTarget(tag.name)
            } else if hoveredTagName == tag.name {
                offerReleaseTarget(nil)
            }
        }
    }

    private func surfaceBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(hex: 0x161616).opacity(0.96))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    // MARK: - Keyboard

    /// Local-monitor key handling. Returns true when the event is consumed. While the
    /// overlay is up it owns Delete and Return, so a held modifier plus Backspace can
    /// never reach an item-deleting shortcut underneath.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        if isQueryFocused {
            switch event.keyCode {
            case 125: moveHighlight(by: 1); return true
            case 126: moveHighlight(by: -1); return true
            default: return false // the text field handles typing, Return and Escape
            }
        }

        let flags = event.modifierFlags.intersection([.command, .control])
        if !flags.isEmpty, !flags.isSubset(of: tagSettings.modifierKey.eventFlag) {
            return false // real shortcuts (⌘Q, ⌘W …) keep working
        }

        switch event.keyCode {
        case 53: // Escape: clear the filter, then leave a branch, then close
            if !query.isEmpty {
                query = ""
            } else if !wheelPath.isEmpty {
                navigateWheel(to: Array(wheelPath.dropLast()))
            } else {
                onDismiss?()
            }
            return true
        case 51, 117: // Delete / Forward Delete
            if !query.isEmpty { query.removeLast() }
            return true
        case 36, 76: // Return / Enter
            activateHighlight()
            return true
        case 125: moveHighlight(by: 1); return true
        case 126: moveHighlight(by: -1); return true
        case 123, 124: return true
        case 48: // Tab: keep the selector open and type normally
            beginTyping()
            return true
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
              }) else {
            return false
        }
        query += characters
        return true
    }

    /// Modifier released while held (not pinned): the host toggles the offered tag.
    /// Remember it for recents if that toggle adds it.
    private func handleFlagsChanged(_ event: NSEvent) {
        guard !isPinned, !event.modifierFlags.contains(tagSettings.modifierKey.eventFlag),
              let name = releaseCandidate, !isSelected(name) else { return }
        usedTagNames.append(name)
    }

    private func moveHighlight(by delta: Int) {
        let rows = resultRows
        guard !rows.isEmpty else { return }
        highlightIndex = (highlightIndex + delta + rows.count) % rows.count
        offerHighlightAsReleaseTarget()
    }

    private func offerHighlightAsReleaseTarget() {
        let rows = resultRows
        guard rows.indices.contains(highlightIndex) else {
            if !TagCanonicalizer.key(query).isEmpty { offerReleaseTarget(nil) }
            return
        }
        offerReleaseTarget(rows[highlightIndex].tagName)
    }

    private func activateHighlight() {
        let rows = resultRows
        if rows.indices.contains(highlightIndex) {
            switch rows[highlightIndex] {
            case .tag(let match): toggleTag(match.definition.name)
            case .create(let name): createTag(named: name)
            }
        } else if let name = hoveredTagName {
            toggleTag(name)
        }
    }

    private func pin() {
        guard !isPinned else { return }
        isPinned = true
        onBeginTextEntry()
    }

    private func beginTyping() {
        pin()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isQueryFocused = true
        }
    }

    // MARK: - Selection

    /// The host toggles `hoveredTagName` when the modifier is released.
    private func offerReleaseTarget(_ name: String?) {
        releaseCandidate = name
        if hoveredTagName != name {
            hoveredTagName = name
        }
    }

    private func createTag(named rawName: String) {
        // Reuse an existing definition's spelling; otherwise create the tag as typed.
        guard let name = TagDefinitionSearch.resolvedDisplayName(for: rawName, in: tagSettings.definitions) else { return }
        if TagDefinitionSearch.existingDefinition(named: name, in: tagSettings.definitions) == nil {
            tagSettings.addTag(name: name)
        }
        if !isSelected(name) {
            selectedTags.insert(name)
            usedTagNames.append(name)
        }
        query = ""
    }

    private func toggleTag(_ name: String) {
        offerReleaseTarget(nil)

        let key = TagCanonicalizer.key(name)
        let existing = selectedTags.filter { TagCanonicalizer.key($0) == key }
        if existing.isEmpty {
            selectedTags.insert(name)
            usedTagNames.append(name)
        } else {
            // Remove the item's own spelling(s), not just an exact match.
            selectedTags.subtract(existing)
        }
    }
}

private extension TagWheelLayout.Kind {
    var isTag: Bool {
        if case .tag = self { return true }
        return false
    }
}

// MARK: - Key monitor

/// App-local key capture for the overlay's lifetime. Local monitors run before key
/// equivalents and the responder chain, so typed letters reach the filter even while
/// the hold modifier is down.
final class TagOverlayKeyMonitor: ObservableObject {
    private var keyMonitor: Any?
    private var flagsMonitor: Any?

    func start(onKeyDown: @escaping (NSEvent) -> Bool, onFlagsChanged: @escaping (NSEvent) -> Void) {
        stop()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            onKeyDown(event) ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            onFlagsChanged(event)
            return event
        }
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        keyMonitor = nil
        flagsMonitor = nil
    }

    deinit { stop() }
}

// MARK: - Keep inside window

/// Hosts centre the overlay on the pointer and clamp for a ~360 pt picker. Larger
/// layouts shift themselves back inside the window instead of clipping at an edge.
struct KeepInsideWindow: ViewModifier {
    @State private var correction: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .offset(correction)
            // Measured outside the offset, so the frame is the un-shifted layout frame.
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow,
                      let bounds = window.contentView?.bounds else { return }
                correction = Self.correction(for: frame, within: CGRect(origin: .zero, size: bounds.size))
            }
    }

    static func correction(for frame: CGRect, within bounds: CGRect, margin: CGFloat = 8) -> CGSize {
        func axis(_ minValue: CGFloat, _ maxValue: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            let low = lower + margin, high = upper - margin
            if maxValue - minValue >= high - low { return low - minValue } // too big: pin leading edge
            if minValue < low { return low - minValue }
            if maxValue > high { return high - maxValue }
            return 0
        }
        return CGSize(
            width: axis(frame.minX, frame.maxX, bounds.minX, bounds.maxX),
            height: axis(frame.minY, frame.maxY, bounds.minY, bounds.maxY)
        )
    }
}

// MARK: - TagWheelSegmentView

private struct TagWheelSegmentView: View {
    let segment: TagWheelLayout.Segment
    let isSelected: Bool
    let isHovered: Bool
    let containsSelection: Bool

    private var shape: PieSliceShape {
        PieSliceShape(
            startAngle: .degrees(segment.startDegrees),
            endAngle: .degrees(segment.endDegrees),
            outerRadius: segment.outer,
            innerRadius: segment.inner
        )
    }

    private var fill: Color {
        switch segment.kind {
        case .tag(let tag):
            if isSelected { return tag.color.opacity(0.95) }
            if isHovered { return tag.color.opacity(0.78) }
            return tag.color.opacity(segment.ring == 0 ? 0.5 : 0.36)
        case .more:
            return Color.white.opacity(isHovered ? 0.18 : 0.08)
        case .drill(let tag):
            if isHovered { return tag.color.opacity(0.85) }
            return tag.color.opacity(containsSelection ? 0.75 : 0.28)
        }
    }

    var body: some View {
        ZStack {
            shape.fill(fill)
            shape.stroke(Color(hex: 0x111111), lineWidth: 1.5)
            if isSelected {
                shape.stroke(Color.white, lineWidth: 2)
            } else if isHovered {
                shape.stroke(Color.white.opacity(0.6), lineWidth: 1.5)
            } else if containsSelection, segment.kind.isTag {
                shape.stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }

            if let label = segment.label {
                Text(isSelected ? "✓ \(label.text)" : label.text)
                    .font(.system(size: label.fontSize, weight: isSelected || isHovered ? .semibold : .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: label.maxLength)
                    .rotationEffect(.degrees(label.rotationDegrees))
                    .offset(x: label.center.x, y: label.center.y)
            }
        }
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .animation(.easeOut(duration: 0.1), value: isSelected)
        .allowsHitTesting(false) // TagWheelLayout.segment(at:) owns hit testing
    }
}

// MARK: - PieSliceShape

private struct PieSliceShape: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let outerRadius: CGFloat
    let innerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)

        var path = Path()

        let innerStart = CGPoint(
            x: center.x + innerRadius * cos(CGFloat(startAngle.radians)),
            y: center.y + innerRadius * sin(CGFloat(startAngle.radians))
        )
        path.move(to: innerStart)

        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )

        let outerEnd = CGPoint(
            x: center.x + outerRadius * cos(CGFloat(endAngle.radians)),
            y: center.y + outerRadius * sin(CGFloat(endAngle.radians))
        )
        path.addLine(to: outerEnd)

        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: endAngle,
            endAngle: startAngle,
            clockwise: true
        )

        path.closeSubpath()

        return path
    }
}

// MARK: - Preview

#if DEBUG
extension TagOverlay {
    /// Seeds filter and drill state for offscreen evidence captures and previews.
    init(previewTags: [String], query: String = "", drillPath: [TagWheelLayout.Focus] = []) {
        self.init(currentTags: previewTags, onTagsChanged: { _ in })
        _query = State(initialValue: query)
        _wheelPath = State(initialValue: drillPath)
    }
}

struct TagOverlay_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color(hex: 0x1a1a1a)
                .ignoresSafeArea()

            TagOverlay(
                currentTags: ["art", "inspiration"],
                onTagsChanged: { _ in }
            )
        }
        .frame(width: 700, height: 700)
    }
}
#endif
