import SwiftUI

/// Recovery surface for deliberately unassigned data, not a silent empty editor.
struct RetainedAssetDataView: View {
    let store: MediaStore
    let itemID: UUID?
    let displayedAssetID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var issues: [ItemAssetStore.AssociationIssue] = []
    @State private var assets: [ItemAsset] = []
    @State private var selectedAssetID: UUID?
    @State private var error: String?
    @State private var savedContent: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Retained File Data").font(.title2.weight(.semibold))
            Text("These annotations and analysis were kept because a file changed or its original file could not be identified. Nothing listed here was discarded.")
                .foregroundStyle(.secondary)
            if !assets.isEmpty {
                Picker("Attach annotations to", selection: $selectedAssetID) {
                    Text("Choose a file").tag(Optional<UUID>.none)
                    ForEach(assets) { asset in
                        Text("\(asset.url.lastPathComponent)\(asset.role == .context ? " (Context)" : "")")
                            .tag(Optional(asset.assetID))
                    }
                }
            }
            List(issues, id: \.recordID) { issue in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(kind(issue.table)).fontWeight(.medium)
                        Spacer()
                        Text(reason(issue.reason)).foregroundStyle(.secondary)
                    }
                    if let path = issue.sourcePath {
                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption).textSelection(.enabled)
                    } else if let index = issue.originalIndex, index >= 0, index < Int.max {
                        Text("Original file position: \(index + 1)").font(.caption).foregroundStyle(.secondary)
                    }
                    if issue.table == "annotations" {
                        if itemID != nil {
                            Button("Attach to Selected File") { Task { await attach(issue) } }
                                .disabled(selectedAssetID == nil)
                        }
                        Button("View Saved Annotation Data") {
                            Task {
                                do { savedContent[issue.recordID] = try await store.retainedAnnotationContent(recordID: issue.recordID) }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                        if let content = savedContent[issue.recordID] {
                            ScrollView { Text(content).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                                .frame(maxHeight: 140)
                                .accessibilityLabel("Saved annotation data")
                        }
                        if issue.reason == "orphaned-item" {
                            Text("Original item is missing (\(issue.itemID.uuidString)). This data was not assigned to another file.")
                                .font(.caption).textSelection(.enabled)
                        }
                    } else {
                        Text("Run analysis on the current file to generate a new result.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay { if issues.isEmpty { ContentUnavailableView("No Retained Data", systemImage: "checkmark.circle") } }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 380)
        .task {
            selectedAssetID = displayedAssetID
            await reload()
        }
    }

    private func reload() async {
        do {
            issues = try await store.assetAssociationIssues(itemID: itemID)
            if let itemID { assets = try await store.fetchAssets(itemID: itemID) }
        } catch { self.error = error.localizedDescription }
    }

    private func attach(_ issue: ItemAssetStore.AssociationIssue) async {
        guard let selectedAssetID, let itemID else { return }
        do {
            try await store.reattachAnnotation(recordID: issue.recordID, itemID: itemID, to: selectedAssetID)
            error = nil
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    private func kind(_ table: String) -> String {
        switch table {
        case "annotations": return "Annotations"
        case "media_file_ocr": return "Recognized Text"
        case "video_segments": return "Video Analysis"
        default: return "Transcript"
        }
    }

    private func reason(_ state: String) -> String {
        switch state {
        case "replacement": return "File content changed"
        case "removed": return "Original file removed"
        case "unverified": return "Original file unavailable"
        case "combined-duplicate": return "Competing combined data"
        case "retained-draft": return "Draft saved after file changed"
        case "orphaned-item": return "Original library item missing"
        default: return "Original file needs review"
        }
    }
}
