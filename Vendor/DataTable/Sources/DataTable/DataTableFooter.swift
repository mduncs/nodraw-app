import SwiftUI

/// Footer bar for table views showing item count, selection info, and optional actions.
public struct DataTableFooter: View {
    let totalCount: Int
    let selectedCount: Int
    let onExport: (() -> Void)?

    public init(
        totalCount: Int,
        selectedCount: Int,
        onExport: (() -> Void)? = nil
    ) {
        self.totalCount = totalCount
        self.selectedCount = selectedCount
        self.onExport = onExport
    }

    public var body: some View {
        HStack(spacing: 8) {
            // Item count
            Text(countText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            // Export button
            if let onExport = onExport {
                Button(action: onExport) {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var countText: String {
        if selectedCount > 0 {
            return "\(selectedCount) of \(totalCount) selected"
        }
        return "\(totalCount) items"
    }
}
