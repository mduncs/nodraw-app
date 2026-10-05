import SwiftUI

// MARK: - TagRulesSettingsView

struct TagRulesSettingsView: View {
    /// The app's live store; nil while the library is loading.
    var mediaStore: MediaStore?

    @ObservedObject private var engine = TagRuleEngine.shared
    @ObservedObject private var tagSettings = TagSettings.shared
    @State private var showingEditor: Bool = false
    @State private var editingRule: TagRule? = nil
    @State private var isApplyingAll: Bool = false
    @State private var applyResult: ApplyResult? = nil
    @State private var confirmDelete: TagRule? = nil
    @State private var confirmApplyAll: Bool = false
    @State private var loadError: String? = nil
    @State private var actionError: String? = nil

    private struct ApplyResult {
        let tagsApplied: Int
        let itemsAffected: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            rulesList
        }
        .task {
            do {
                try await engine.loadRules()
            } catch {
                loadError = error.localizedDescription
                logError("TagRulesSettingsView: failed to load rules: \(error)")
            }
        }
        .sheet(isPresented: $showingEditor) {
            TagRuleEditorSheet(
                engine: engine,
                tagSettings: tagSettings,
                editingRule: editingRule,
                mediaStore: mediaStore
            )
        }
        .alert("Delete Rule", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let rule = confirmDelete {
                    deleteRule(rule)
                    confirmDelete = nil
                }
            }
        } message: {
            if let rule = confirmDelete {
                Text("Delete rule \"\(rule.name)\"? Tags it already applied stay on their items.")
            }
        }
        .confirmationDialog(
            "Run \(enabledRuleCount) enabled rule\(enabledRuleCount == 1 ? "" : "s") on the whole library?",
            isPresented: $confirmApplyAll,
            titleVisibility: .visible
        ) {
            Button("Apply to All Items") { applyAllRules() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every item, including existing ones, is checked and matching rule tags are added. Nothing is removed. This can't be undone with ⌘Z.")
        }
    }

    private var enabledRuleCount: Int { engine.rules.filter(\.enabled).count }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(rulesSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // Re-apply all button
                if !engine.rules.isEmpty {
                    Button {
                        confirmApplyAll = true
                    } label: {
                        HStack(spacing: 4) {
                            if isApplyingAll {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                            }
                            Text(isApplyingAll ? "Applying…" : "Re-apply All")
                                .font(.caption)
                        }
                        .foregroundStyle(isApplyingAll ? .secondary : Color.accentOrange)
                    }
                    .buttonStyle(.plain)
                    .disabled(isApplyingAll || mediaStore == nil || enabledRuleCount == 0)
                    .help(applyAllHelp)
                }

                // The empty state carries its own Add Rule button.
                if !engine.rules.isEmpty {
                    addRuleButton
                }
            }

            // Apply result toast
            if let result = applyResult {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Applied \(result.tagsApplied) tag\(result.tagsApplied == 1 ? "" : "s") to \(result.itemsAffected) item\(result.itemsAffected == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.green.opacity(0.1))
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let error = actionError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        actionError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Dismiss")
                }
            }

            // Load error
            if let error = loadError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Failed to load rules: \(error)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var addRuleButton: some View {
        Button {
            editingRule = nil
            showingEditor = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Text("Add Rule")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentOrange)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add tag rule")
    }

    private var rulesSummary: String {
        let total = engine.rules.count
        // The empty state below already explains rules; don't repeat it here.
        guard total > 0 else { return "" }
        let enabled = enabledRuleCount
        return "\(total) rule\(total == 1 ? "" : "s") · \(enabled) enabled · run automatically on new items"
    }

    private var applyAllHelp: String {
        if mediaStore == nil { return "Available once the library finishes loading" }
        if enabledRuleCount == 0 { return "Enable a rule first" }
        return "Run all enabled rules on every existing item (adds tags only)"
    }

    // MARK: - Rules List

    @ViewBuilder
    private var rulesList: some View {
        if engine.rules.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 2) {
                // Enabled rules first
                let enabled = engine.rules.filter(\.enabled).sorted { $0.priority < $1.priority }
                let disabled = engine.rules.filter { !$0.enabled }.sorted { $0.priority < $1.priority }

                ForEach(enabled) { rule in
                    ruleRow(rule)
                }

                if !disabled.isEmpty && !enabled.isEmpty {
                    Divider()
                        .background(Color.white.opacity(0.05))
                        .padding(.vertical, 4)
                }

                ForEach(disabled) { rule in
                    ruleRow(rule)
                        .opacity(0.5)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.rays")
                .font(.largeTitle)
                .foregroundStyle(.secondary.opacity(0.5))

            Text("No tag rules yet")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("Rules auto-tag new items by where they came from or what on-device analysis found, like tagging everything from r/aesthetic with ‘aesthetic’.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)

            addRuleButton
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Rule Row

    private func ruleRow(_ rule: TagRule) -> some View {
        RuleRowView(
            rule: rule,
            tagSettings: tagSettings,
            onToggle: { toggleRule(rule) },
            onEdit: {
                editingRule = rule
                showingEditor = true
            },
            onDelete: { confirmDelete = rule }
        )
    }

    // MARK: - Actions

    private func toggleRule(_ rule: TagRule) {
        var updated = rule
        updated.enabled.toggle()
        updated.updatedAt = Date()
        Task {
            do {
                try await engine.updateRule(updated)
            } catch {
                logError("TagRulesSettingsView: toggle failed: \(error)")
                actionError = "Could not \(updated.enabled ? "enable" : "disable") ‘\(rule.name)’: \(error.localizedDescription)"
            }
        }
    }

    private func deleteRule(_ rule: TagRule) {
        Task {
            do {
                try await engine.deleteRule(rule)
            } catch {
                logError("TagRulesSettingsView: delete failed: \(error)")
                actionError = "Could not delete ‘\(rule.name)’: \(error.localizedDescription)"
            }
        }
    }

    private func applyAllRules() {
        // The app's store, so library views observe the change and its write-back
        // queue owns the sidecar edits.
        guard let store = mediaStore else { return }
        isApplyingAll = true
        applyResult = nil
        actionError = nil
        Task {
            do {
                let result = try await engine.applyRulesToAll(mediaStore: store)
                applyResult = ApplyResult(
                    tagsApplied: result.tagsApplied,
                    itemsAffected: result.itemsAffected
                )
                // Auto-dismiss result after 5 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    withAnimation { applyResult = nil }
                }
            } catch {
                logError("TagRulesSettingsView: apply all failed: \(error)")
                actionError = "Re-apply stopped: \(error.localizedDescription). Tags added before the error remain."
            }
            isApplyingAll = false
        }
    }
}

// MARK: - RuleRowView

private struct RuleRowView: View {
    let rule: TagRule
    let tagSettings: TagSettings
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // Enabled toggle
            Toggle("Enabled", isOn: Binding(
                get: { rule.enabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(rule.enabled ? "Disable rule" : "Enable rule")

            // Rule info
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(ruleDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            TagChip(name: rule.tagName, maxWidth: 220)

            // Hover actions keep their space so the chip column never shifts.
            HStack(spacing: 2) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Edit rule")
                .accessibilityLabel("Edit \(rule.name)")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Delete rule")
                .accessibilityLabel("Delete \(rule.name)")
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { onEdit() }
        .contextMenu {
            Button("Edit") { onEdit() }
            Button(rule.enabled ? "Disable" : "Enable") { onToggle() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
        .accessibilityLabel("Rule: \(rule.name)")
    }

    private var ruleDescription: String {
        let field = rule.sourceField.displayName.lowercased()
        let op = rule.matchType.symbol
        return "\(field) \(op) \(rule.pattern)"
    }
}
