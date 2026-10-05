import SwiftUI

/// Local edits are already durable in the library. This surface reports the
/// separate step of writing them to archive metadata, without interrupting work.
struct MetadataSyncStatusView: View {
    let queue: WriteBackQueue
    @State private var statuses: [MetadataOutbox.Status] = []
    @State private var showingDetails = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var working = false

    private var attentionCount: Int {
        statuses.filter { $0.state == "conflict" || $0.state == "retry" }.count
    }

    var body: some View {
        Group {
            if !statuses.isEmpty || loadError != nil || showingDetails {
                Button {
                    showingDetails.toggle()
                } label: {
                    Label(summary, systemImage: attentionCount > 0 || loadError != nil
                          ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .help("Inspect changes waiting to be written to archive metadata")
                .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                    details
                }
                .padding(8)
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(3)) }
                catch { break }
            }
        }
    }

    private var summary: String {
        if loadError != nil { return "Metadata status unavailable" }
        if attentionCount > 0 { return "Metadata: \(attentionCount) need attention" }
        if statuses.isEmpty { return "Metadata up to date" }
        return "Saving metadata: \(statuses.count) changes"
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Archive metadata").font(.headline)
            Text("Your changes are saved in the library. This shows whether they have also reached the archive files.")
                .font(.callout).foregroundStyle(.secondary)
            if let message = actionError ?? loadError {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if statuses.isEmpty && loadError == nil {
                Label("All changes written", systemImage: "checkmark.circle")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(statuses.prefix(100).enumerated()), id: \.offset) { _, status in
                            statusRow(status)
                            Divider()
                        }
                        if statuses.count > 100 {
                            Text("Showing 100 of \(statuses.count) changes.").foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            HStack {
                Button("Retry writes") {
                    Task {
                        await queue.retry()
                        await refresh()
                    }
                }
                .disabled(working || !statuses.contains { $0.state == "retry" || $0.state == "pending" })
                Spacer()
                Button("Done") { showingDetails = false }
            }
        }
        .padding(16)
        .frame(width: 430)
    }

    private func statusRow(_ status: MetadataOutbox.Status) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(URL(fileURLWithPath: status.metadataPath).deletingPathExtension().lastPathComponent)
                .fontWeight(.medium).lineLimit(2)
            Text("\(fieldLabel(status.field)) · \(stateLabel(status.state))")
                .font(.caption).foregroundStyle(.secondary)
            if status.state == "conflict" {
                Text("This field also changed in the archive file.").font(.callout)
                Text("Your edit: \(displayValue(status.desiredJSON))").textSelection(.enabled)
                Text("File value: \(displayValue(status.externalJSON ?? "null"))").textSelection(.enabled)
                HStack {
                    Button("Keep my edit") { resolve(status, keepLocal: true) }
                    if status.field != "annotated" {
                        Button("Use file value") { resolve(status, keepLocal: false) }
                    }
                }
                .disabled(working)
            } else if let error = status.error {
                Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .font(.callout)
    }

    private func resolve(_ status: MetadataOutbox.Status, keepLocal: Bool) {
        guard let id = UUID(uuidString: status.itemID) else { return }
        working = true
        actionError = nil
        Task {
            do {
                try await queue.resolveConflict(itemID: id, field: status.field,
                                                revision: status.revision, keepLocal: keepLocal)
                NotificationCenter.default.post(name: .mediaStoreDidChange, object: nil)
            } catch {
                actionError = "Could not resolve this change: \(error.localizedDescription)"
            }
            working = false
            await refresh()
        }
    }

    private func refresh() async {
        do {
            statuses = try await queue.statuses()
            loadError = nil
        } catch {
            loadError = "Could not check archive writes: \(error.localizedDescription)"
        }
    }

    private func fieldLabel(_ field: String) -> String {
        switch field {
        case "tags": return "Tags"
        case "notes": return "Note"
        case "starred": return "Star"
        case "deleted": return "Trash state"
        case "annotated": return "Annotation state"
        default: return field.capitalized
        }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "conflict": return "Choose a value"
        case "retry": return "Write failed — retry available"
        case "inFlight": return "Writing"
        default: return "Waiting to write"
        }
    }

    private func displayValue(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        else { return json }
        if value is NSNull { return "None" }
        if let values = value as? [String] { return values.isEmpty ? "None" : values.joined(separator: ", ") }
        if let string = value as? String { return string.isEmpty ? "None" : string }
        if let boolean = value as? Bool { return boolean ? "Yes" : "No" }
        return json
    }
}
