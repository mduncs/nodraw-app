import SwiftUI

/// A column definition for use with `ColumnToggleMenu`.
public struct ColumnDef: Identifiable, Equatable {
    public let id: String
    public let label: String
    public var isVisible: Bool

    public init(id: String, label: String, isVisible: Bool = true) {
        self.id = id
        self.label = label
        self.isVisible = isVisible
    }
}

/// Menu button that shows checkboxes for toggling column visibility.
public struct ColumnToggleMenu: View {
    @Binding var columns: [ColumnDef]
    let onReset: (() -> Void)?

    public init(columns: Binding<[ColumnDef]>, onReset: (() -> Void)? = nil) {
        self._columns = columns
        self.onReset = onReset
    }

    public var body: some View {
        Menu {
            ForEach($columns) { $column in
                Toggle(column.label, isOn: $column.isVisible)
            }

            if let onReset = onReset {
                Divider()
                Button("Reset to Defaults", action: onReset)
            }
        } label: {
            Label("Columns", systemImage: "line.3.horizontal.decrease")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 90)
    }
}

/// Toolbar button variant of column toggle (for use in `.toolbar {}`).
public struct ColumnToggleToolbarButton: View {
    @Binding var columns: [ColumnDef]
    let onReset: (() -> Void)?

    public init(columns: Binding<[ColumnDef]>, onReset: (() -> Void)? = nil) {
        self._columns = columns
        self.onReset = onReset
    }

    public var body: some View {
        Menu {
            ForEach($columns) { $column in
                Toggle(column.label, isOn: $column.isVisible)
            }

            if let onReset = onReset {
                Divider()
                Button("Reset to Defaults", action: onReset)
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .help("Toggle column visibility")
    }
}
