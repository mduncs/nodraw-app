import SwiftUI
import AppKit

/// First-launch onboarding.
///
/// Deliberately minimal: the only thing NoDraw needs before it can be useful is
/// an archive folder. Everything else (web saves, the download server, the
/// browser extension) is optional power-user plumbing that lives in
/// Settings → Downloads, not on the critical first-run path.
struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var selectedArchiveURL: URL?
    @State private var validation: ArchiveValidation?
    @State private var isValidating: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            hero

            Divider().opacity(0.4)

            folderPicker

            Spacer(minLength: 12)

            Text("Want to save media from the web? Set up the optional Firefox or Chrome extension any time in Settings ▸ Downloads.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            footer
        }
        .padding(32)
        .frame(minWidth: 640, minHeight: 460)
        .background(Color(hex: 0x1a1a1a))
        .onAppear(perform: preselectExistingArchive)
    }

    private var hero: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .cornerRadius(14)

            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to NoDraw")
                    .font(.title.bold())
                Text("A fast, keyboard-first viewer for your local media archive.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your archive folder")
                .font(.headline)

            Text("NoDraw watches this folder, indexes its metadata, and keeps your library in sync. Nothing is moved or modified without your action.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(action: chooseArchiveFolder) {
                HStack(spacing: 10) {
                    Image(systemName: selectedArchiveURL == nil ? "folder.badge.plus" : "folder.fill")
                        .foregroundStyle(selectedArchiveURL == nil ? Color.accentColor : .primary)
                    Text(selectedArchiveURL?.path ?? "Choose Folder…")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(selectedArchiveURL == nil ? .secondary : .primary)
                    Spacer()
                    if selectedArchiveURL != nil {
                        Text("Change")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            statusRow
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if isValidating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking folder…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let validation {
            HStack(spacing: 8) {
                Image(systemName: validation.iconName)
                    .foregroundStyle(validation.tint)
                Text(validation.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: finishOnboarding) {
                Text("Open Library")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!(validation?.isUsable ?? false))
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    /// A folder that already exists at the configured location (default ~/MediaArchive)
    /// is offered up front, so a returning setup is one click. Nothing is saved until
    /// Open Library.
    private func preselectExistingArchive() {
        guard selectedArchiveURL == nil else { return }
        let current = ArchivePathStore.currentPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        validateSelection(current)
    }

    private func chooseArchiveFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Media Archive Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = ArchivePathStore.currentPath()

        guard panel.runModal() == .OK, let url = panel.url else { return }
        validateSelection(url)
    }

    private func validateSelection(_ url: URL) {
        selectedArchiveURL = url
        validation = nil
        isValidating = true

        Task.detached(priority: .userInitiated) {
            let result = OnboardingView.validate(url)
            await MainActor.run {
                self.validation = result
                self.isValidating = false
            }
        }
    }

    private func finishOnboarding() {
        if let selectedArchiveURL {
            let standardized = selectedArchiveURL.standardizedFileURL
            ArchivePathStore.setCurrentPath(standardized)
            DownloadServerManager.shared.archiveDirectory = standardized.path
        }
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        onComplete()
    }

    // MARK: - Validation

    /// Mirrors `AppCoordinator.verifyArchiveFolder` so first-run users learn about
    /// a bad folder choice here, in onboarding, instead of as a post-"Open Library"
    /// failure screen.
    nonisolated private static func validate(_ url: URL) -> ArchiveValidation {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return ArchiveValidation(status: .missing, itemCount: nil)
        }
        guard isDir.boolValue else {
            return ArchiveValidation(status: .invalid, itemCount: nil)
        }
        guard fm.isReadableFile(atPath: url.path) else {
            return ArchiveValidation(status: .noAccess, itemCount: nil)
        }

        let writable = fm.isWritableFile(atPath: url.path)
        let count = estimateMarkdownItems(at: url)

        if !writable {
            return ArchiveValidation(status: .readOnly, itemCount: count)
        }
        return ArchiveValidation(status: count > 0 ? .healthy : .empty, itemCount: count)
    }

    nonisolated private static func estimateMarkdownItems(at folderURL: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var count = 0
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "md" {
                count += 1
            }
        }
        return count
    }
}

/// Lightweight validation result for the onboarding folder picker.
private struct ArchiveValidation: Sendable {
    let status: ArchiveStatus
    let itemCount: Int?

    var isUsable: Bool { status.isUsable }

    var iconName: String {
        switch status {
        case .healthy, .empty: return "checkmark.circle.fill"
        case .readOnly: return "exclamationmark.triangle.fill"
        default: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch status {
        case .healthy, .empty: return .green
        case .readOnly: return .orange
        default: return .red
        }
    }

    var message: String {
        switch status {
        case .healthy:
            let n = itemCount ?? 0
            return "Looks good — about \(n.formatted()) item\(n == 1 ? "" : "s") found."
        case .empty:
            return "Empty folder — new items will appear here as you add them."
        case .readOnly:
            return "This folder is read-only. You can browse, but tags and edits won't be saved."
        case .missing:
            return "That folder no longer exists. Choose another."
        case .invalid:
            return "That isn't a folder. Choose a directory."
        case .noAccess:
            return "NoDraw can't read that folder. Check permissions or choose another."
        case .notConfigured, .unknown:
            return "Choose a folder to continue."
        }
    }
}
