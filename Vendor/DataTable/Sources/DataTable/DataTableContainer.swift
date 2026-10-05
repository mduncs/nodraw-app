import SwiftUI

/// Container view that wraps SwiftUI Table content and adds footer,
/// copy support, export, and toolbar controls.
///
/// Usage:
/// ```swift
/// DataTableContainer(
///     itemCount: items.count,
///     selectedCount: selection.count,
///     onCopy: { copySelectedItems() },
///     onExport: { exportCSV() }
/// ) {
///     Table(items, selection: $selection, sortOrder: $sort) {
///         TableColumn("Name", value: \.name) { Text($0.name) }
///     }
/// }
/// ```
public struct DataTableContainer<Content: View>: View {
    let itemCount: Int
    let selectedCount: Int
    let onCopy: (() -> String)?
    let onExport: (() -> Void)?
    let showFooter: Bool
    let toolbarContent: AnyView?
    let content: Content

    public init(
        itemCount: Int,
        selectedCount: Int,
        showFooter: Bool = true,
        onCopy: (() -> String)? = nil,
        onExport: (() -> Void)? = nil,
        toolbar: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.itemCount = itemCount
        self.selectedCount = selectedCount
        self.showFooter = showFooter
        self.onCopy = onCopy
        self.onExport = onExport
        self.toolbarContent = toolbar
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Optional toolbar
            if let toolbar = toolbarContent {
                toolbar
            }

            // Main table content
            content
                .copyableTable(formatter: onCopy)

            // Footer
            if showFooter {
                DataTableFooter(
                    totalCount: itemCount,
                    selectedCount: selectedCount,
                    onExport: onExport
                )
            }
        }
    }
}

// MARK: - Convenience init with toolbar builder

extension DataTableContainer {
    public init<Toolbar: View>(
        itemCount: Int,
        selectedCount: Int,
        showFooter: Bool = true,
        onCopy: (() -> String)? = nil,
        onExport: (() -> Void)? = nil,
        @ViewBuilder toolbar: () -> Toolbar,
        @ViewBuilder content: () -> Content
    ) {
        self.itemCount = itemCount
        self.selectedCount = selectedCount
        self.showFooter = showFooter
        self.onCopy = onCopy
        self.onExport = onExport
        self.toolbarContent = AnyView(toolbar())
        self.content = content()
    }
}

// MARK: - View Extension for copy support

struct CopyableTableModifier: ViewModifier {
    let formatter: (() -> String)?

    func body(content: Content) -> some View {
        content
            .onCopyCommand {
                guard let formatter = formatter else { return [] }
                let text = formatter()
                guard !text.isEmpty else { return [] }
                return [NSItemProvider(object: text as NSString)]
            }
    }
}

extension View {
    /// Adds Cmd+C copy support to a table view.
    /// The formatter closure should return a TSV/CSV string of selected items.
    public func copyableTable(formatter: (() -> String)?) -> some View {
        modifier(CopyableTableModifier(formatter: formatter))
    }
}
