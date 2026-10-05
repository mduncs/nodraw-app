import SwiftUI
import AppKit
import Combine

enum TagSuggestionEngine {
    static func suggestions(
        query: String,
        existingTags: [String],
        recentlyUsedTags: [String],
        excluding excludedTags: [String]
    ) -> [String] {
        let excludedKeys = Set(excludedTags.map(TagCanonicalizer.key))
        var seen = Set<String>()
        let uniqueExisting = existingTags.filter {
            let key = TagCanonicalizer.key($0)
            return !key.isEmpty && !excludedKeys.contains(key) && seen.insert(key).inserted
        }

        let trimmedQuery = TagCanonicalizer.displayName(query)
        if trimmedQuery.isEmpty {
            let byKey = Dictionary(uniqueKeysWithValues: uniqueExisting.map { (TagCanonicalizer.key($0), $0) })
            var recentSeen = Set<String>()
            return recentlyUsedTags.compactMap { recent in
                let key = TagCanonicalizer.key(recent)
                guard !key.isEmpty, recentSeen.insert(key).inserted else { return nil }
                return byKey[key]
            }
        }

        let recentRank = Dictionary(
            recentlyUsedTags.enumerated().map { (TagCanonicalizer.key($0.element), $0.offset) },
            uniquingKeysWith: min
        )
        return uniqueExisting.compactMap { tag -> (String, Int)? in
            guard let score = TagCanonicalizer.matchScore(query: trimmedQuery, candidate: tag) else { return nil }
            return (tag, score)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            let lhsRecent = recentRank[TagCanonicalizer.key(lhs.0)] ?? Int.max
            let rhsRecent = recentRank[TagCanonicalizer.key(rhs.0)] ?? Int.max
            if lhsRecent != rhsRecent { return lhsRecent < rhsRecent }
            return lhs.0.localizedStandardCompare(rhs.0) == .orderedAscending
        }.map(\.0)
    }
}

// MARK: - TagInputPopover

/// Quick tag input popover that appears when pressing 't'.
/// Shows autocomplete suggestions from existing tags.
struct TagInputPopover: View {
    @Binding var isPresented: Bool
    let existingTags: [String]
    let recentlyUsedTags: [String]  // Subset of frequently/recently used tags
    let onAddTag: (String) -> Void

    @State private var inputText: String = ""
    @State private var selectedSuggestionIndex: Int = 0
    @State private var addedTags: [String] = []  // Multi-tag entry: tags added this session
    @State private var showSuccessFlash: Bool = false  // Visual confirmation
    @FocusState private var isInputFocused: Bool
    @State private var eventMonitor: Any? = nil
    @State private var validationError: String?
    @State private var filteredSuggestions: [String] = []

    private var trimmedInput: String { TagCanonicalizer.displayName(inputText) }

    // Issue #6: When empty, show recently used (5-10 tags max), not all tags
    // Issue #9: Check if typed text exactly matches an existing tag
    private var typedTagExists: Bool {
        let inputKey = TagCanonicalizer.key(inputText)
        return existingTags.contains { TagCanonicalizer.key($0) == inputKey }
    }

    // Issue #10: Include "create new" option in selectable items
    // Returns true if we should show "create new" option
    private var showCreateNewOption: Bool {
        !trimmedInput.isEmpty && !typedTagExists
    }

    // Total selectable items (suggestions + create new if applicable)
    private var totalSelectableItems: Int {
        filteredSuggestions.count + (showCreateNewOption ? 1 : 0)
    }

    // Is "create new" currently selected?
    private var isCreateNewSelected: Bool {
        showCreateNewOption && selectedSuggestionIndex == filteredSuggestions.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Show tags applied during this open session. They are status, not fake undo controls.
            if !addedTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(addedTags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                Text(tag)
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.accentOrange.opacity(0.3))
                            .cornerRadius(4)
                            .accessibilityLabel("Applied tag \(tag) in this session")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .background(Color(hex: 0x1f1f1f))
            }

            // Input field
            HStack(spacing: 8) {
                Image(systemName: "tag")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                // Issue #8: Use system font instead of monospaced
                TextField("Add tag…", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(.body))
                    .focused($isInputFocused)
                    .onSubmit {
                        submitTag()
                    }
                    .accessibilityLabel("Tag name")
                    .accessibilityValue(validationError ?? inputText)

                // Issue #3: Success flash indicator
                if showSuccessFlash {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                        .font(.caption)
                        .transition(.scale.combined(with: .opacity))
                }

                if !inputText.isEmpty && !showSuccessFlash {
                    Button(action: { inputText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear tag search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(hex: 0x252525))

            Divider()
                .background(Color.white.opacity(0.1))

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Tag input error: \(validationError)")
            }

            if trimmedInput.isEmpty && !filteredSuggestions.isEmpty {
                Text("Recent")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
            }

            // Suggestions list with ScrollViewReader for Issue #7
            if !filteredSuggestions.isEmpty || showCreateNewOption {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(filteredSuggestions.enumerated()), id: \.element) { index, tag in
                                Button {
                                    inputText = tag
                                    submitTag()
                                } label: {
                                    TagSuggestionRow(
                                        tag: tag,
                                        isSelected: index == selectedSuggestionIndex,
                                        searchText: inputText,
                                        // Issue #9: Show "exists" badge when exact match
                                        isExactMatch: TagCanonicalizer.key(tag) == TagCanonicalizer.key(inputText)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(index)  // Issue #7: ID for scroll-to
                                .accessibilityLabel("Add tag \(tag)")
                                .accessibilityValue(index == selectedSuggestionIndex ? "Selected suggestion" : "")
                            }

                            // Issue #10: Create new option included in selectable items
                            if showCreateNewOption {
                                Button {
                                    submitTag()
                                } label: {
                                HStack {
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(Color.accentOrange)
                                    Text("Create ‘\(trimmedInput)’")
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    // Issue #9: "new tag" indicator
                                    Text("new")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.accentOrange.opacity(0.2))
                                        .cornerRadius(2)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(isCreateNewSelected ? Color.accentOrange.opacity(0.2) : Color(hex: 0x2a2a2a))
                                }
                                .buttonStyle(.plain)
                                .id(filteredSuggestions.count)  // ID for scroll-to
                                .accessibilityLabel("Create new tag \(trimmedInput)")
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    // Issue #7: Scroll to selection when it changes
                    .onChange(of: selectedSuggestionIndex) { _, newIndex in
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            } else if inputText.isEmpty && filteredSuggestions.isEmpty {
                // Issue #6: Show hint when no recent tags available
                Text("Type to search \(existingTags.count) tags")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            // Hint footer
            HStack(spacing: 10) {
                keyHint("↩", "add")
                keyHint("⇥", "complete")
                keyHint("↑↓", "select")
                Spacer(minLength: 0)
                keyHint("esc", "close")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(hex: 0x1f1f1f))
        }
        .frame(width: 300)  // Room for the parent path beside each suggestion
        .background(Color(hex: 0x1a1a1a))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
        .onAppear {
            isInputFocused = true
            selectedSuggestionIndex = 0
            refreshSuggestions()
            setupKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
        .onChange(of: inputText) { _, _ in
            selectedSuggestionIndex = 0
            validationError = nil
            refreshSuggestions()
        }
        .onChange(of: addedTags) { _, _ in
            refreshSuggestions()
        }
    }

    private func keyHint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.caption2.monospaced())
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))
            Text(action)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Issue #1: Use NSEvent local monitor for keyboard navigation
    // The TextField captures focus, so we use a local event monitor to intercept keys

    private func setupKeyboardMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 126: // Up arrow
                if selectedSuggestionIndex > 0 {
                    selectedSuggestionIndex -= 1
                }
                return nil  // Consume event
            case 125: // Down arrow
                if selectedSuggestionIndex < totalSelectableItems - 1 {
                    selectedSuggestionIndex += 1
                }
                return nil
            case 48: // Tab - Issue #5: autocomplete from selected suggestion
                if !filteredSuggestions.isEmpty && selectedSuggestionIndex < filteredSuggestions.count {
                    inputText = filteredSuggestions[selectedSuggestionIndex]
                }
                return nil
            case 53: // Escape
                isPresented = false
                return nil
            default:
                return event  // Pass through other keys
            }
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func refreshSuggestions() {
        filteredSuggestions = Array(TagSuggestionEngine.suggestions(
            query: inputText,
            existingTags: existingTags,
            recentlyUsedTags: recentlyUsedTags,
            excluding: addedTags
        ).prefix(trimmedInput.isEmpty ? 8 : 40))
        if selectedSuggestionIndex >= totalSelectableItems {
            selectedSuggestionIndex = max(0, totalSelectableItems - 1)
        }
    }

    private func submitTag() {
        let tagToAdd: String

        // Issue #2: When a suggestion is selected, use it (not just typed text)
        if !filteredSuggestions.isEmpty && selectedSuggestionIndex < filteredSuggestions.count {
            // Use the selected suggestion
            tagToAdd = filteredSuggestions[selectedSuggestionIndex]
        } else if isCreateNewSelected || (filteredSuggestions.isEmpty && !inputText.isEmpty) {
            // Creating a new tag
            tagToAdd = trimmedInput
        } else {
            tagToAdd = trimmedInput
        }

        guard !TagCanonicalizer.key(tagToAdd).isEmpty else {
            validationError = "Enter a tag name."
            return
        }

        // Check if tag was already added this session
        guard !addedTags.contains(where: {
            TagCanonicalizer.key($0) == TagCanonicalizer.key(tagToAdd)
        }) else {
            validationError = "‘\(tagToAdd)’ was already applied in this session."
            return
        }

        onAddTag(tagToAdd)

        // Issue #3: Show success flash animation
        withAnimation(.easeInOut(duration: 0.1)) {
            showSuccessFlash = true
        }

        // Issue #4: Multi-tag entry - add to session list, clear input, stay open
        addedTags.append(tagToAdd)
        inputText = ""
        selectedSuggestionIndex = 0

        // Hide success flash after 150ms
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.1)) {
                showSuccessFlash = false
            }
        }
    }
}

// MARK: - TagSuggestionRow

private struct TagSuggestionRow: View {
    let tag: String
    let isSelected: Bool
    let searchText: String
    let isExactMatch: Bool  // Issue #9: Show "exists" badge when exact match

    /// Parent path, so same-looking names in different branches can be told apart.
    private var ancestorLabel: String {
        let settings = TagSettings.shared
        guard let definition = TagDefinitionSearch.existingDefinition(named: tag, in: settings.definitions) else { return "" }
        return settings.ancestors(of: definition.id).reversed().map(\.name).joined(separator: " › ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(TagSettings.shared.colorOnly(for: tag))
                .frame(width: 7, height: 7)

            highlightedText
                .lineLimit(1)
                .layoutPriority(1)

            let path = ancestorLabel
            if !path.isEmpty {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 4)

            // Issue #9: Show "exists" indicator for exact matches
            if isExactMatch {
                Text("exists")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentOrange.opacity(0.2) : Color.clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var highlightedText: some View {
        if searchText.isEmpty {
            Text(tag)
                .font(.caption)
        } else if let range = tag.range(of: searchText, options: .caseInsensitive) {
            let before = String(tag[..<range.lowerBound])
            let match = String(tag[range])
            let after = String(tag[range.upperBound...])

            HStack(spacing: 0) {
                Text(before)
                    .font(.caption)
                Text(match)
                    .font(.caption)
                    .foregroundStyle(Color.accentOrange)
                    .fontWeight(.semibold)
                Text(after)
                    .font(.caption)
            }
        } else {
            Text(tag)
                .font(.caption)
        }
    }
}

// MARK: - TagInputOverlay

/// Overlay container that positions the tag input near the selected item
struct TagInputOverlay: View {
    @Binding var isPresented: Bool
    let selectedItemID: UUID?
    let existingTags: [String]
    let recentlyUsedTags: [String]
    let onAddTag: (String) -> Void

    var body: some View {
        if isPresented {
            ZStack {
                // Dismiss background
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        isPresented = false
                    }

                // Popover (centered for simplicity - could position near selection)
                TagInputPopover(
                    isPresented: $isPresented,
                    existingTags: existingTags,
                    recentlyUsedTags: recentlyUsedTags,
                    onAddTag: onAddTag
                )
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.15)))
        }
    }
}

// MARK: - Preview

#if DEBUG
struct TagInputPopover_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color(hex: 0x1a1a1a)
                .ignoresSafeArea()

            TagInputPopover(
                isPresented: .constant(true),
                existingTags: ["art", "inspiration", "meme", "screenshot", "tutorial", "reference", "design", "photo", "video", "music"],
                recentlyUsedTags: ["art", "inspiration", "meme"],
                onAddTag: { tag in
                    logDebug("Adding tag: \(tag)")
                }
            )
        }
        .frame(width: 400, height: 400)
    }
}
#endif
