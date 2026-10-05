import SwiftUI

// MARK: - Tagging HUD

struct TaggingHUD: View {
    private enum FocusTarget: Hashable {
        case newTagButton
        case newTagField
        case findField
    }

    @ObservedObject var viewModel: TaggingQueueViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(SettingsStore.self) private var settings
    @State private var showOverflowPopover = false
    @State private var isCreatingTag = false
    @State private var newTagName = ""
    /// Whole-tree leaf search; typing here bypasses the queue's key bindings.
    @State private var findQuery = ""
    @FocusState private var focusTarget: FocusTarget?
    @GestureState private var resizeTranslation: CGFloat = 0

    private var helpOpacity: Double {
        settings.taggingHUDHelpUseCount >= 5 ? 0.5 : 1.0
    }

    private var panelWidth: CGFloat {
        CGFloat(SettingsStore.clampedTaggingHUDWidth(
            settings.taggingHUDWidth + Double(resizeTranslation)
        ))
    }

    var body: some View {
        VStack(spacing: 8) {
            topRow
            progressBar
            onboardingHint
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    itemTagsSection
                    tagChipsSection
                    overflowSection
                    findTagSection
                    createTagSection
                    selectedTagsSection
                    queueStatusSection
                    historySection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 80, maxHeight: 360)
        }
        .padding(16)
        .frame(width: panelWidth)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .trailing) {
            resizeHandle
        }
        .onAppear {
            settings.taggingHUDHelpUseCount += 1
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tagging queue")
        .accessibilityValue(viewModel.progressDescription)
    }

    // MARK: - Top Row

    private var topRow: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text("[\(viewModel.currentIndex + 1)/\(viewModel.totalCount)]")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Item \(viewModel.currentIndex + 1) of \(viewModel.totalCount)")

                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        breadcrumb
                            .fixedSize()
                    }
                    .scrollIndicators(.visible)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        if let id = viewModel.navigationPath.last?.id {
                            proxy.scrollTo(id, anchor: .trailing)
                        }
                    }
                    .onChange(of: viewModel.navigationPath.map(\.id)) { _, path in
                        if let id = path.last {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(id, anchor: .trailing)
                            }
                        }
                    }
                }

                Button {
                    Task { await undoAndSyncFocus() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.history.isEmpty)
                .help("Undo the last tagging action (Command-Z or Shift-Return)")

                Button {
                    Task { await confirmAndSyncFocus() }
                } label: {
                    Label(
                        viewModel.currentIndex + 1 >= viewModel.totalCount ? "Apply & Finish" : "Apply & Next",
                        systemImage: "checkmark"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.isPerformingAction)
                .help("Apply the pending changes and continue (Return)")

                Button("Skip") {
                    Task { await skipAndSyncFocus() }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(viewModel.isPerformingAction)
                .help("Skip this item without changing its tags (Tab)")
            }

            HStack(spacing: 8) {
                Button {
                    if viewModel.moveToPreviousItem(), let item = viewModel.currentItem {
                        appState.openSingleFocus(item)
                    }
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canMoveBackward || viewModel.isPerformingAction)

                Button {
                    if viewModel.moveToNextItem(), let item = viewModel.currentItem {
                        appState.openSingleFocus(item)
                    }
                } label: {
                    Label("Next", systemImage: "chevron.right")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canMoveForward || viewModel.isPerformingAction)

                Spacer()

                Text("\(viewModel.completedCount) reviewed · \(viewModel.changedCount) changed · \(viewModel.skippedCount) skipped")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "\(viewModel.completedCount) reviewed, \(viewModel.changedCount) changed, "
                            + "\(viewModel.skippedCount) skipped"
                    )
            }

            ScrollView(.horizontal) {
                helpText
                    .fixedSize()
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Breadcrumb (M7: no trailing chevron)

    @ViewBuilder
    private var breadcrumb: some View {
        if !viewModel.navigationPath.isEmpty {
            let willApplyDrilled = viewModel.selectedLeafTags.isEmpty
            HStack(spacing: 0) {
                Button {
                    viewModel.jumpToLevel(-1)
                } label: {
                    Image(systemName: "house")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                ForEach(Array(viewModel.navigationPath.enumerated()), id: \.element.id) { index, node in
                    Text(" › ")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    let isLast = index == viewModel.navigationPath.count - 1
                    Button {
                        viewModel.jumpToLevel(index)
                    } label: {
                        Text(node.name)
                            .font(isLast ? .caption.bold() : .caption)
                            .foregroundStyle(isLast && willApplyDrilled ? Color.accentColor : .secondary)
                            .underline(isLast && willApplyDrilled)
                    }
                    .buttonStyle(.plain)
                    .id(node.id)
                }
            }
            .accessibilityLabel("Path: \(viewModel.navigationPath.map(\.name).joined(separator: " › "))")
        }
    }

    // MARK: - Help Text (L4: inline with breadcrumb row, dims after use)

    private var helpText: some View {
        HStack(spacing: 10) {
            enterHelpLabel
            Text("Tab: skip")
            Text("←/→: browse")
            Text("Esc: back")
            Text("\u{21E7}\u{21A9}/\u{2318}Z: undo")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .opacity(helpOpacity)
    }

    @ViewBuilder
    private var enterHelpLabel: some View {
        if viewModel.selectedLeafTags.isEmpty,
           let lastDrilled = viewModel.navigationPath.last {
            let suffix = viewModel.currentIndex + 1 >= viewModel.totalCount ? " + finish" : " + next"
            Text("Enter: '\(lastDrilled.name)'" + suffix)
                .foregroundStyle(Color.accentColor.opacity(0.7))
        } else {
            Text(viewModel.currentIndex + 1 >= viewModel.totalCount
                 ? "Enter: confirm + finish"
                 : "Enter: confirm + next")
        }
    }

    // MARK: - L8: Progress Bar

    private var progressBar: some View {
        ProgressView(value: Double(viewModel.completedCount), total: Double(max(viewModel.totalCount, 1)))
            .tint(.accentColor)
            .padding(.vertical, 1)
            .accessibilityLabel("Queue progress")
            .accessibilityValue(viewModel.progressDescription)
    }

    // MARK: - M4: Onboarding Hint

    @ViewBuilder
    private var onboardingHint: some View {
        if viewModel.showOnboardingHint {
            Text("Press number/letter keys to navigate tags")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .transition(.opacity)
        }
    }

    // MARK: - H2: Tag Chips with Directional Slide Transition

    private var itemTagsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("On this item")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)

            if viewModel.existingTags.isEmpty {
                Text("No tags")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(viewModel.existingTags, id: \.self) { tag in
                        let isRemoving = viewModel.stagingState(for: tag) == .removing
                        let canStage = viewModel.canStageTag(named: tag)
                        Button {
                            viewModel.toggleLeafTag(named: tag)
                        } label: {
                            TagChip(
                                name: tag,
                                size: .small,
                                symbol: isRemoving ? "minus.circle.fill" : nil,
                                tint: isRemoving ? .red : nil,
                                isStruckThrough: isRemoving
                            )
                            // Parent tags follow their leaves; show them as context.
                            .opacity(canStage ? 1 : 0.55)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canStage)
                        .help(
                            viewModel.canStageTag(named: tag)
                                ? (isRemoving ? "Cancel removal" : "Stage this tag for removal")
                                : "Parent tags are shown here but changed through their leaf tags"
                        )
                        .accessibilityLabel(
                            isRemoving
                                ? "Keep existing tag \(tag); currently staged for removal"
                                : "Remove existing tag \(tag)"
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            viewModel.existingTags.isEmpty
                ? "This item has no tags"
                : "Tags on item: \(viewModel.existingTags.joined(separator: ", "))"
        )
    }

    private var tagChipsSection: some View {
        FlowLayout(spacing: 6) {
            ForEach(viewModel.currentLevel.filter { $0.keyBinding != nil }) { node in
                TagKeyChip(
                    node: node,
                    stagingState: viewModel.stagingState(for: node.name),
                    action: { viewModel.selectNode(node) }
                )
            }
        }
        .id(viewModel.navigationPath.map(\.id))
        .transition(.asymmetric(
            insertion: .move(edge: viewModel.navigationDirection == .forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: viewModel.navigationDirection == .forward ? .leading : .trailing).combined(with: .opacity)
        ))
    }

    // MARK: - M3: Overflow Section

    @ViewBuilder
    private var overflowSection: some View {
        let overflowNodes = viewModel.currentLevel.filter { $0.keyBinding == nil }
        if !overflowNodes.isEmpty {
            Button {
                showOverflowPopover.toggle()
            } label: {
                Text("+\(overflowNodes.count) without shortcuts")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .underline()
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showOverflowPopover, arrowEdge: .top) {
                OverflowTagsPopover(
                    nodes: overflowNodes,
                    stagingState: { viewModel.stagingState(for: $0) },
                    onNodeSelected: { node in
                        viewModel.selectNode(node)
                        if !node.isLeaf {
                            showOverflowPopover = false
                        }
                    }
                )
            }
        }
    }

    // MARK: - Find Any Tag

    /// Reach any leaf in a large tree without drilling: canonical fuzzy match on the
    /// name or its parents, shown with the path. Selecting stages exactly like a key.
    private var findTagSection: some View {
        let results = viewModel.tagSearchResults(for: findQuery)
        let hasQuery = !TagCanonicalizer.key(findQuery).isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Find any tag…", text: $findQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($focusTarget, equals: .findField)
                    .onSubmit {
                        // Return stages the best match and keeps the field ready.
                        if let first = results.first {
                            viewModel.toggleLeafTag(named: first.definition.name)
                            findQuery = ""
                        }
                    }
                    .onExitCommand {
                        findQuery = ""
                        focusTarget = nil
                    }
                    .accessibilityLabel("Find any tag")
                if hasQuery {
                    Button {
                        findQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))

            if hasQuery {
                if results.isEmpty {
                    Text("No leaf tags match. “New tag here” creates one.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(results, id: \.definition.id) { match in
                            TagSearchResultRow(
                                match: match,
                                stagingState: viewModel.stagingState(for: match.definition.name),
                                action: { viewModel.toggleLeafTag(named: match.definition.name) }
                            )
                        }
                    }
                    Text("Return stages the first match · Esc clears")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Inline Tag Creation

    @ViewBuilder
    private var createTagSection: some View {
        if isCreatingTag {
            VStack(alignment: .leading, spacing: 6) {
                TextField("New tag name", text: $newTagName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusTarget, equals: .newTagField)
                    .onSubmit(createTag)
                    .onExitCommand(perform: cancelTagCreation)
                    .onChange(of: newTagName) { _, _ in
                        viewModel.clearTagCreationError()
                    }

                HStack(spacing: 8) {
                    Text(creationLocationLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Button("Cancel", action: cancelTagCreation)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                    Button("Create", action: createTag)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                if let error = viewModel.tagCreationError {
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Tag creation error: \(error.message)")
                }
            }
        } else {
            Button {
                isCreatingTag = true
                newTagName = ""
                viewModel.clearTagCreationError()
                DispatchQueue.main.async {
                    focusTarget = .newTagField
                }
            } label: {
                Label("New tag here", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help(creationLocationLabel)
            .focused($focusTarget, equals: .newTagButton)
            .accessibilityHint(creationLocationLabel)
        }
    }

    private var creationLocationLabel: String {
        if let branch = viewModel.navigationPath.last {
            return "Creates under \(branch.name)"
        }
        return "Creates at the tag root"
    }

    private func createTag() {
        guard viewModel.createTag(named: newTagName) else { return }
        newTagName = ""
        isCreatingTag = false
        focusTarget = .newTagButton
    }

    private func cancelTagCreation() {
        newTagName = ""
        isCreatingTag = false
        focusTarget = .newTagButton
        viewModel.clearTagCreationError()
    }

    // MARK: - Selected Tags

    @ViewBuilder
    private var selectedTagsSection: some View {
        if !viewModel.selectedLeafTags.isEmpty || !viewModel.stagedRemovalTags.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Pending changes")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)

                if !viewModel.pendingAdditions.isEmpty {
                    pendingRow("Add") {
                        ForEach(viewModel.pendingAdditions, id: \.self) { tag in
                            Button {
                                viewModel.toggleLeafTag(named: tag)
                            } label: {
                                TagChip(name: tag, size: .small, symbol: "plus.circle.fill", isEmphasized: true)
                            }
                            .buttonStyle(.plain)
                            .help("Unstage \(tag)")
                            .accessibilityLabel("Remove pending tag \(tag)")
                        }
                    }
                }

                if !viewModel.pendingRemovals.isEmpty {
                    pendingRow("Remove") {
                        ForEach(viewModel.pendingRemovals, id: \.self) { tag in
                            Button {
                                viewModel.toggleLeafTag(named: tag)
                            } label: {
                                TagChip(name: tag, size: .small, symbol: "minus.circle.fill", tint: .red,
                                        isStruckThrough: true, isEmphasized: true)
                            }
                            .buttonStyle(.plain)
                            .help("Keep \(tag)")
                            .accessibilityLabel("Keep tag \(tag); cancel pending removal")
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                "Pending additions: \(viewModel.pendingAdditions.joined(separator: ", ")); "
                    + "pending removals: \(viewModel.pendingRemovals.joined(separator: ", "))"
            )
        }
    }

    private func pendingRow<Content: View>(_ title: String, @ViewBuilder chips: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
            FlowLayout(spacing: 4) { chips() }
        }
    }

    // MARK: - Session History

    @ViewBuilder
    private var queueStatusSection: some View {
        if viewModel.isPerformingAction {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving tag changes…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Saving tag changes")
        } else if let error = viewModel.operationError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .accessibilityLabel("Tagging error: \(error)")
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !viewModel.history.isEmpty {
            Divider()

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Session history", systemImage: "clock.arrow.circlepath")
                        .font(.caption.bold())
                    Spacer()
                    Text("\(viewModel.history.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(viewModel.history.reversed())) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Item \(entry.queueIndex + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Text(historyDescription(for: entry))
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    private func historyDescription(for entry: TaggingQueueViewModel.HistoryEntry) -> String {
        if entry.wasSkipped { return "Skipped" }
        var parts: [String] = []
        if !entry.addedTags.isEmpty {
            parts.append("Added: \(entry.addedTags.sorted().joined(separator: ", "))")
        }
        if !entry.removedTags.isEmpty {
            parts.append("Removed: \(entry.removedTags.sorted().joined(separator: ", "))")
        }
        return parts.isEmpty ? "Confirmed with no changes" : parts.joined(separator: "; ")
    }

    // MARK: - Resize Handle

    private var resizeHandle: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 3, height: 34)
        }
        .frame(width: 14)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($resizeTranslation) { value, state, _ in
                    state = value.translation.width
                }
                .onEnded { value in
                    settings.taggingHUDWidth = SettingsStore.clampedTaggingHUDWidth(
                        settings.taggingHUDWidth + Double(value.translation.width)
                    )
                }
        )
        .help("Drag to resize the tagging panel")
        .accessibilityElement()
        .accessibilityLabel("Resize tagging panel")
        .accessibilityValue("\(Int(panelWidth)) points wide")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                settings.taggingHUDWidth += 40
            case .decrement:
                settings.taggingHUDWidth -= 40
            @unknown default:
                break
            }
        }
    }

    @MainActor
    private func skipAndSyncFocus() async {
        await viewModel.skipItem()
        if viewModel.isActive, let item = viewModel.currentItem {
            appState.openSingleFocus(item)
        } else {
            appState.taggingQueue = nil
        }
    }

    @MainActor
    private func undoAndSyncFocus() async {
        await viewModel.undoAndGoBack()
        if viewModel.isActive, let item = viewModel.currentItem {
            appState.openSingleFocus(item)
        } else {
            appState.taggingQueue = nil
        }
    }

    @MainActor
    private func confirmAndSyncFocus() async {
        await viewModel.confirmAndAdvance()
        if viewModel.isActive, let item = viewModel.currentItem {
            appState.openSingleFocus(item)
        } else if viewModel.operationError == nil {
            appState.taggingQueue = nil
        }
    }
}

// MARK: - Overflow Tags Popover (M3)

private struct OverflowTagsPopover: View {
    let nodes: [TagTreeNode]
    let stagingState: (String) -> TaggingQueueViewModel.TagStagingState
    let onNodeSelected: (TagTreeNode) -> Void

    @State private var filter = ""
    @FocusState private var isFilterFocused: Bool

    /// Canonical fuzzy filter, best match first; unfiltered keeps tree order.
    private var visibleNodes: [TagTreeNode] {
        let query = TagCanonicalizer.displayName(filter)
        guard !TagCanonicalizer.key(query).isEmpty else { return nodes }
        return nodes.compactMap { node -> (TagTreeNode, Int)? in
            TagCanonicalizer.matchScore(query: query, candidate: node.name).map { (node, $0) }
        }
        .sorted { $0.1 < $1.1 }
        .map(\.0)
    }

    var body: some View {
        let visible = visibleNodes
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Filter \(nodes.count) tags", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .focused($isFilterFocused)
                    .onSubmit {
                        if let first = visible.first { onNodeSelected(first) }
                    }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(visible) { node in
                        OverflowTagRow(
                            node: node,
                            stagingState: stagingState(node.name),
                            onNodeSelected: onNodeSelected
                        )
                    }
                }
            }

            if visible.isEmpty {
                Text("No matches at this level")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .frame(minWidth: 280, maxWidth: 280, maxHeight: 320)
        .onAppear { DispatchQueue.main.async { isFilterFocused = true } }
    }
}

/// One whole-tree search hit: name, parent path and staging state.
private struct TagSearchResultRow: View {
    let match: TagDefinitionSearch.Match
    let stagingState: TaggingQueueViewModel.TagStagingState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(match.definition.color)
                    .frame(width: 8, height: 8)
                Text(match.definition.name)
                    .font(.caption)
                    .lineLimit(1)
                if !match.ancestorLabel.isEmpty {
                    Text(match.ancestorLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                switch stagingState {
                case .available:
                    EmptyView()
                case .onItem:
                    Text("on item").font(.caption2).foregroundStyle(.secondary)
                case .adding:
                    Image(systemName: "plus.circle.fill").font(.caption2).foregroundStyle(match.definition.color)
                case .removing:
                    Image(systemName: "minus.circle.fill").font(.caption2).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                stagingState == .adding ? match.definition.color.opacity(0.18)
                    : stagingState == .removing ? Color.red.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(stagingState == .onItem ? "Stage removal of" : "Toggle") \(match.definition.name)\(match.ancestorLabel.isEmpty ? "" : " in \(match.ancestorLabel)")")
    }
}

private struct OverflowTagRow: View {
    let node: TagTreeNode
    let stagingState: TaggingQueueViewModel.TagStagingState
    let onNodeSelected: (TagTreeNode) -> Void

    var body: some View {
        Button {
            onNodeSelected(node)
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(node.color)
                    .frame(width: 10, height: 10)
                Text(node.name)
                    .font(.caption)
                if !node.isLeaf {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if stagingState != .available {
                    Image(systemName: stagingState == .removing ? "minus.circle.fill" : "checkmark")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stagingState != .available ? node.color.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tag Key Chip

struct TagKeyChip: View {
    let node: TagTreeNode
    let stagingState: TaggingQueueViewModel.TagStagingState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(String(node.keyBinding ?? " "))
                    .font(.caption.monospaced().bold())
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Circle()
                    .fill(node.color)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5)
                    )

                Text(node.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 150, alignment: .leading)

                if !node.isLeaf {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if stagingState == .onItem {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if stagingState == .adding {
                    Image(systemName: "plus.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(node.color)
                } else if stagingState == .removing {
                    Image(systemName: "minus.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(stagingState == .adding
                          ? node.color.opacity(0.25)
                          : stagingState == .removing
                            ? Color.red.opacity(0.18)
                            : stagingState == .onItem
                              ? node.color.opacity(0.12)
                              : Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        stagingState == .removing ? Color.red.opacity(0.7)
                            : stagingState != .available ? node.color.opacity(0.7) : Color.white.opacity(0.1),
                        lineWidth: stagingState == .available ? 1 : 1.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let action = node.isLeaf ? "Toggle" : "Open"
        let state: String
        switch stagingState {
        case .available: state = "not on item"
        case .onItem: state = "already on item"
        case .adding: state = "staged to add"
        case .removing: state = "staged to remove"
        }
        return "\(action) \(node.name), \(state), shortcut \(node.keyBinding.map(String.init) ?? "none")"
    }
}
