import Foundation

// MARK: - Table Column Definition

struct TableColumnDef: Identifiable, Codable, Equatable {
    let id: String
    var label: String
    var width: CGFloat
    var minWidth: CGFloat
    var isVisible: Bool

    enum ColumnType: String, Codable {
        case thumbnail
        case text
        case date
        case bool
        case tags
        case multilineText
        case numeric
    }

    var type: ColumnType
}

// MARK: - Table Browser Config

struct TableBrowserConfig: Codable, Equatable {
    var columns: [TableColumnDef]
    var rowHeight: CGFloat

    private static let defaultsKey = "tableBrowserConfig"

    static let `default` = TableBrowserConfig(
        columns: [
            TableColumnDef(id: "thumbnail", label: "Preview", width: 48, minWidth: 32, isVisible: true, type: .thumbnail),
            TableColumnDef(id: "platform", label: "Platform", width: 90, minWidth: 60, isVisible: true, type: .text),
            TableColumnDef(id: "author", label: "Author", width: 120, minWidth: 80, isVisible: true, type: .text),
            TableColumnDef(id: "starred", label: "Star", width: 40, minWidth: 32, isVisible: true, type: .bool),
            TableColumnDef(id: "tags", label: "Tags", width: 180, minWidth: 100, isVisible: true, type: .tags),
            TableColumnDef(id: "notes", label: "Notes", width: 200, minWidth: 100, isVisible: true, type: .multilineText),
            TableColumnDef(id: "archivedDate", label: "Archived", width: 130, minWidth: 90, isVisible: true, type: .date),
            TableColumnDef(id: "originalDate", label: "Created", width: 130, minWidth: 90, isVisible: true, type: .date),
            TableColumnDef(id: "downloadDate", label: "Downloaded", width: 130, minWidth: 90, isVisible: false, type: .date),
            TableColumnDef(id: "importDate", label: "Imported", width: 130, minWidth: 90, isVisible: false, type: .date),
            TableColumnDef(id: "uploadDate", label: "Uploaded", width: 130, minWidth: 90, isVisible: false, type: .date),
            TableColumnDef(id: "sourceURL", label: "Source URL", width: 200, minWidth: 120, isVisible: false, type: .text),
            TableColumnDef(id: "aspectRatio", label: "Aspect Ratio", width: 80, minWidth: 60, isVisible: false, type: .numeric),
            TableColumnDef(id: "folder", label: "Folder", width: 100, minWidth: 70, isVisible: false, type: .text),
            TableColumnDef(id: "ocrText", label: "OCR Text", width: 200, minWidth: 100, isVisible: false, type: .multilineText),
            TableColumnDef(id: "parseStatus", label: "Status", width: 80, minWidth: 60, isVisible: false, type: .text),
        ],
        rowHeight: 36
    )

    // MARK: - Persistence

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    static func load() -> TableBrowserConfig {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(TableBrowserConfig.self, from: data) else {
            return .default
        }
        return config
    }

    var visibleColumns: [TableColumnDef] {
        columns.filter(\.isVisible)
    }

    mutating func toggleColumn(_ id: String) {
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return }
        columns[index].isVisible.toggle()
    }

    mutating func moveColumn(from source: IndexSet, to destination: Int) {
        columns.move(fromOffsets: source, toOffset: destination)
    }
}
