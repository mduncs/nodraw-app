import SwiftUI

enum BatchDeleteConfirmationCopy {
    static func message(deleteFromDisk: Bool) -> String {
        deleteFromDisk
            ? "This will remove the items from the library and move their files to Trash."
            : "This will remove the items from the library. Files on disk will not be deleted."
    }
}

// MARK: - BatchActionBar

/// Floating action bar that appears when multiple items are selected.
/// Shows selection count and batch action buttons.
struct BatchActionBar: View {
    let selectedCount: Int
    var statusText: String? = nil
    let onStarAll: () -> Void
    let onUnstarAll: () -> Void
    let onAddTag: () -> Void
    let onRemoveTag: () -> Void
    /// Called to request deletion. The container owns the shared confirmation so
    /// context-menu and selection-bar deletes use the same captured policy.
    let onDelete: () -> Void
    let onClearSelection: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Selection count
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentOrange)
                    .accessibilityHidden(true)
                Text("\(selectedCount) items selected")
                    .font(.subheadline.weight(.medium))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(selectedCount) items selected")

            Divider()
                .frame(height: 20)

            // Action buttons
            HStack(spacing: 8) {
                BatchActionButton(
                    icon: "star.fill",
                    label: "Star All",
                    action: onStarAll
                )

                BatchActionButton(
                    icon: "star.slash",
                    label: "Unstar All",
                    action: onUnstarAll
                )

                BatchActionButton(
                    icon: "tag.fill",
                    label: "Add Tag",
                    action: onAddTag
                )

                BatchActionButton(
                    icon: "tag.slash",
                    label: "Remove Tag",
                    action: onRemoveTag
                )

                Divider()
                    .frame(height: 20)

                BatchActionButton(
                    icon: "trash",
                    label: "Delete",
                    isDestructive: true,
                    action: onDelete
                )
            }
            .disabled(statusText != nil)

            Spacer()

            if let statusText {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(statusText)
                .accessibilityAddTraits(.updatesFrequently)
            }

            // Clear selection
            Button(action: onClearSelection) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear selection (Escape)")
            .disabled(statusText != nil)
            .accessibilityLabel("Clear selection")
            .accessibilityIdentifier("batch-action-clear-selection")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("batch-action-bar")
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - BatchActionButton

struct BatchActionButton: View {
    let icon: String
    let label: String
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(isDestructive ? Color.red : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier("batch-action-\(label.lowercased().replacingOccurrences(of: " ", with: "-"))")
        .accessibilityHint(isDestructive ? "Deletes selected items" : "Applies action to selected items")
    }
}

// MARK: - Tag Input Sheet

/// Sheet for entering a tag to add/remove from selected items
struct BatchTagInputSheet: View {
    let title: String
    let existingTags: [String]
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var tagInput: String = ""
    @FocusState private var isInputFocused: Bool

    private var filteredTags: [String] {
        let query = TagCanonicalizer.key(tagInput)
        if query.isEmpty {
            return existingTags
        }
        return existingTags.filter { TagCanonicalizer.key($0).hasPrefix(query) }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)

            TextField("Enter tag...", text: $tagInput)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .onSubmit {
                    submitTag()
                }

            if !filteredTags.isEmpty {
                ScrollView {
                    FlowLayout(spacing: 6) {
                        ForEach(filteredTags, id: \.self) { tag in
                            Button {
                                tagInput = tag
                                submitTag()
                            } label: {
                                TagChip(name: tag, size: .regular, maxWidth: 140)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }

            if !tagInput.isEmpty && filteredTags.isEmpty {
                Text("no matching tags")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape)

                Button("Apply") {
                    submitTag()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(tagInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            isInputFocused = true
        }
    }

    private func submitTag() {
        let trimmed = tagInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

// MARK: - Preview

#if DEBUG
struct BatchActionBar_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Spacer()

            BatchActionBar(
                selectedCount: 12,
                statusText: "Starring 12 items…",
                onStarAll: {},
                onUnstarAll: {},
                onAddTag: {},
                onRemoveTag: {},
                onDelete: {},
                onClearSelection: {}
            )
            .padding()
        }
        .frame(width: 800, height: 400)
        .background(Color(hex: 0x1a1a1a))
    }
}
#endif
