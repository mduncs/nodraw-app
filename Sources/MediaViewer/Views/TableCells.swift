import SwiftUI

// MARK: - Star Toggle Cell

/// Inline star toggle - single click to toggle
struct StarToggleCell: View {
    let starred: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: starred ? "star.fill" : "star")
                .font(.system(size: 13))
                .foregroundStyle(starred ? .yellow : .secondary.opacity(0.6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(starred ? "Starred" : "Not starred")
    }
}

// MARK: - Editable Text Cell

/// Text cell that supports inline editing via double-click.
/// Used for Author and Platform fields.
struct EditableTextCell: View {
    let text: String?
    let placeholder: String
    let onSave: (String) -> Void

    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        Group {
            if isEditing {
                TextField(placeholder, text: $editText, onCommit: {
                    commitEdit()
                })
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .onExitCommand { cancelEdit() }
            } else {
                Text(text ?? "-")
                    .font(.system(size: 12))
                    .foregroundStyle(text != nil ? .primary : .tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        editText = text ?? ""
                        isEditing = true
                    }
            }
        }
        .contextMenu {
            if let text = text, !text.isEmpty {
                Button("Copy \"\(text)\"") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            Button("Edit...") {
                editText = text ?? ""
                isEditing = true
            }
        }
    }

    private func commitEdit() {
        isEditing = false
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != (text ?? "") {
            onSave(trimmed)
        }
    }

    private func cancelEdit() {
        isEditing = false
    }
}

// MARK: - Tags Cell

/// Inline tag chips with add button
struct TagsCell: View {
    let tags: [String]
    let onAddTag: () -> Void
    let onRemoveTag: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(3), id: \.self) { tag in
                let color = TagSettings.shared.colorOnly(for: tag)
                HStack(spacing: 2) {
                    Text(tag)
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(color.opacity(0.15))
                )
                .foregroundStyle(color)
                .contextMenu {
                    Button("Copy \"\(tag)\"") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tag, forType: .string)
                    }
                    Button("Remove tag") { onRemoveTag(tag) }
                }
            }

            if tags.count > 3 {
                Text("+\(tags.count - 3)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(tags.dropFirst(3).joined(separator: ", "))
            }

            Button(action: onAddTag) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Add tag")
            .accessibilityLabel("Add tag")
        }
    }
}

// MARK: - Notes Cell

/// Truncated notes with click-to-edit popover
struct NotesCell: View {
    let notes: String?
    let onSave: (String?) -> Void

    @State private var isEditing = false
    @State private var editText: String = ""

    var body: some View {
        HStack(spacing: 4) {
            if let notes = notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            } else {
                Text("-")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                editText = notes ?? ""
                isEditing = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .contextMenu {
            if let notes = notes, !notes.isEmpty {
                Button("Copy Notes") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(notes, forType: .string)
                }
            }
            Button("Edit Notes...") {
                editText = notes ?? ""
                isEditing = true
            }
        }
        .popover(isPresented: $isEditing) {
            NotesEditPopover(text: $editText, onSave: { newText in
                isEditing = false
                let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                onSave(trimmed.isEmpty ? nil : trimmed)
            }, onCancel: {
                isEditing = false
            })
        }
    }
}

/// Popover for editing notes inline
private struct NotesEditPopover: View {
    @Binding var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(width: 280, height: 120)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack(spacing: 8) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)
                Button("Save") { onSave(text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
    }
}

// MARK: - Date Cell

/// Formatted date display with copy context menu
struct DateCell: View {
    let date: Date?

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        Text(date.map { Self.formatter.string(from: $0) } ?? "-")
            .font(.system(size: 12))
            .foregroundStyle(date != nil ? .primary : .tertiary)
            .lineLimit(1)
            .contextMenu {
                if let date = date {
                    Button("Copy Date") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.formatter.string(from: date), forType: .string)
                    }
                }
            }
    }
}

// MARK: - Score Cell

/// Displays an ML score as a percentage bar with numeric value
struct ScoreCell: View {
    let score: Double?

    var body: some View {
        if let score = score {
            HStack(spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.15))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(scoreColor(score))
                            .frame(width: geo.size.width * min(max(score, 0), 1))
                    }
                }
                .frame(height: 6)

                Text(String(format: "%.0f", score * 100))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }
        } else {
            Text("-")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    private func scoreColor(_ score: Double) -> Color {
        if score >= 0.7 { return .green }
        if score >= 0.4 { return .orange }
        return .red
    }
}

// MARK: - Pipeline Status Cell

/// Displays pipeline processing status with colored indicator
struct PipelineStatusCell: View {
    let status: String?

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(status ?? "none")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var statusColor: Color {
        switch status {
        case "complete": return .green
        case "processing", "phase1": return .blue
        case "pending": return .orange
        case "failed": return .red
        default: return .secondary.opacity(0.4)
        }
    }
}

// MARK: - Text Cell

/// Read-only text display (platform, author, URL, etc.) with copy support
struct TextCell: View {
    let text: String?

    var body: some View {
        Text(text ?? "-")
            .font(.system(size: 12))
            .foregroundStyle(text != nil ? .primary : .tertiary)
            .lineLimit(1)
            .textSelection(.enabled)
            .contextMenu {
                if let text = text, !text.isEmpty {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
    }
}
