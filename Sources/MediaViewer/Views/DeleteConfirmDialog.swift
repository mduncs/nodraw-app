import SwiftUI

enum FocusDeleteScope: Equatable {
    case currentFile
    case wholeItem
}

enum FocusDeleteScopePolicy {
    static func toolbarScope(fileCount: Int) -> FocusDeleteScope {
        fileCount > 1 ? .currentFile : .wholeItem
    }
}

enum DeleteConfirmationCopy {
    static func title(scope: FocusDeleteScope, itemCount: Int, fileCount: Int, contextFileCount: Int) -> String {
        guard itemCount == 1 else { return "Delete \(itemCount) items?" }
        if scope == .currentFile { return "Delete this file?" }
        if fileCount == 0 {
            if contextFileCount == 0 { return "Delete this item?" }
            let label = contextFileCount == 1 ? "screenshot" : "screenshots"
            return "Delete item and \(contextFileCount) context \(label)?"
        }
        if fileCount == 1 && contextFileCount == 0 { return "Delete this item?" }
        if fileCount == 1 && contextFileCount > 0 {
            let label = contextFileCount == 1 ? "screenshot" : "screenshots"
            return "Delete item and \(contextFileCount) context \(label)?"
        }
        let associatedCount = fileCount - 1 + contextFileCount
        return "Delete item and \(associatedCount) associated files?"
    }

    static func detail(scope: FocusDeleteScope, fileCount: Int, contextFileCount: Int) -> String {
        if scope == .currentFile {
            return contextFileCount > 0 ? "Current file of \(fileCount) · context screenshot retained" : "Current file of \(fileCount)"
        }
        var parts: [String] = fileCount > 0 ? ["\(fileCount) file\(fileCount == 1 ? "" : "s")"] : []
        if contextFileCount > 0 {
            let label = contextFileCount == 1 ? "screenshot" : "screenshots"
            parts.append("\(contextFileCount) context \(label)")
        }
        return parts.joined(separator: " + ")
    }
}

/// Confirmation dialog for delete operations.
/// Shows contextual info about items/files being deleted and warns if deleting from disk.
struct DeleteConfirmDialog: View {
    let scope: FocusDeleteScope
    let itemCount: Int
    let fileCount: Int
    let contextFileCount: Int
    let deleteFromDisk: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Binding var skipFutureConfirmations: Bool

    @State private var isDeleting = false

    /// Convenience init for backward compatibility
    init(
        itemCount: Int,
        fileCount: Int,
        hasContext: Bool,
        scope: FocusDeleteScope = .wholeItem,
        deleteFromDisk: Bool,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        skipFutureConfirmations: Binding<Bool>
    ) {
        self.itemCount = itemCount
        self.scope = scope
        self.fileCount = fileCount
        self.contextFileCount = hasContext ? 1 : 0
        self.deleteFromDisk = deleteFromDisk
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self._skipFutureConfirmations = skipFutureConfirmations
    }

    /// Full init with explicit context file count
    init(
        itemCount: Int,
        fileCount: Int,
        contextFileCount: Int,
        scope: FocusDeleteScope = .wholeItem,
        deleteFromDisk: Bool,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        skipFutureConfirmations: Binding<Bool>
    ) {
        self.itemCount = itemCount
        self.scope = scope
        self.fileCount = fileCount
        self.contextFileCount = contextFileCount
        self.deleteFromDisk = deleteFromDisk
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self._skipFutureConfirmations = skipFutureConfirmations
    }

    var body: some View {
        VStack(spacing: 16) {
            // Icon
            Image(systemName: deleteFromDisk ? "trash.fill" : "trash")
                .font(.largeTitle)
                .foregroundStyle(deleteFromDisk ? .red : .secondary)

            // Title
            Text(titleText)
                .font(.headline)
                .foregroundStyle(.white)
                .accessibilityIdentifier("deleteConfirmTitle")

            // Details
            Text(detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Warning (if deleting from disk)
            if deleteFromDisk {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(scope == .currentFile
                         ? "This file will be moved to Trash. It cannot be restored if Trash is emptied."
                         : "Files will be moved to Trash. They cannot be restored if Trash is emptied.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.15))
                )
            }

            // Soft delete is recoverable; say where it goes so "Delete" doesn't read as final.
            if !deleteFromDisk && scope == .wholeItem {
                Label(itemCount == 1 ? "Moves to Recently Deleted, where it can be restored."
                                     : "They move to Recently Deleted, where they can be restored.",
                      systemImage: "arrow.uturn.backward.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Don't ask again checkbox - only for soft deletes (not disk deletes)
            if !deleteFromDisk {
                Toggle(isOn: $skipFutureConfirmations) {
                    Text("Don't ask again")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("skipConfirmationCheckbox")
            }

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(isDeleting)
                    .accessibilityIdentifier("cancelButton")

                Button(primaryActionLabel) {
                    isDeleting = true
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .tint(deleteFromDisk ? .red : .accentOrange)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isDeleting)
                .accessibilityIdentifier("deleteButton")
            }
        }
        .padding(32)
        .frame(minWidth: 360, idealWidth: 400)
        .background(Color(hex: 0x2a2a2a))
        .cornerRadius(12)
        .shadow(radius: 20)
        .accessibilityIdentifier("deleteConfirmDialog")
    }

    private var titleText: String {
        DeleteConfirmationCopy.title(scope: scope, itemCount: itemCount, fileCount: fileCount, contextFileCount: contextFileCount)
    }

    private var detailText: String {
        DeleteConfirmationCopy.detail(scope: scope, fileCount: fileCount, contextFileCount: contextFileCount)
    }

    private var primaryActionLabel: String {
        if deleteFromDisk {
            return scope == .currentFile ? "Move File to Trash" : "Move to Trash"
        }
        return scope == .currentFile ? "Delete File" : "Delete"
    }
}

// MARK: - Preview

#if DEBUG
struct DeleteConfirmDialog_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color(hex: 0x1a1a1a)
                .ignoresSafeArea()

            DeleteConfirmDialog(
                itemCount: 1,
                fileCount: 1,
                hasContext: false,
                deleteFromDisk: false,
                onConfirm: {},
                onCancel: {},
                skipFutureConfirmations: .constant(false)
            )
        }
        .frame(width: 400, height: 300)
        .previewDisplayName("Single Item - Soft Delete")

        ZStack {
            Color(hex: 0x1a1a1a)
                .ignoresSafeArea()

            DeleteConfirmDialog(
                itemCount: 1,
                fileCount: 3,
                hasContext: true,
                deleteFromDisk: true,
                onConfirm: {},
                onCancel: {},
                skipFutureConfirmations: .constant(false)
            )
        }
        .frame(width: 400, height: 350)
        .previewDisplayName("Multi-file + Context - Disk Delete")

        ZStack {
            Color(hex: 0x1a1a1a)
                .ignoresSafeArea()

            DeleteConfirmDialog(
                itemCount: 5,
                fileCount: 12,
                hasContext: true,
                deleteFromDisk: true,
                onConfirm: {},
                onCancel: {},
                skipFutureConfirmations: .constant(false)
            )
        }
        .frame(width: 400, height: 350)
        .previewDisplayName("Multiple Items - Disk Delete")
    }
}
#endif
