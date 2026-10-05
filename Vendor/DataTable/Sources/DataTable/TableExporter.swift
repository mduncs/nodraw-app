import SwiftUI
import UniformTypeIdentifiers

/// Utility for exporting table data to CSV/TSV files.
public enum TableExporter {

    /// Present a save dialog and write CSV data to the chosen location.
    /// - Parameters:
    ///   - csv: The CSV string content to save
    ///   - filename: Suggested filename (without extension)
    @MainActor
    public static func exportCSV(_ csv: String, filename: String = "export") {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(filename).csv"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Present a save dialog and write TSV data to the chosen location.
    @MainActor
    public static func exportTSV(_ tsv: String, filename: String = "export") {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tabSeparatedText]
        panel.nameFieldStringValue = "\(filename).tsv"
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try tsv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Copy TSV-formatted text to the system clipboard.
    public static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Formatting Helpers

    /// Escape a field for CSV output (handles commas, quotes, newlines).
    public static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }

    /// Build a CSV string from rows of fields.
    /// - Parameters:
    ///   - headers: Column header names
    ///   - rows: Array of rows, each row is an array of field strings
    public static func buildCSV(headers: [String], rows: [[String]]) -> String {
        var lines: [String] = []
        lines.append(headers.map { csvEscape($0) }.joined(separator: ","))
        for row in rows {
            lines.append(row.map { csvEscape($0) }.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// Build a TSV string from rows of fields (for clipboard copy).
    public static func buildTSV(headers: [String]? = nil, rows: [[String]]) -> String {
        var lines: [String] = []
        if let headers = headers {
            lines.append(headers.joined(separator: "\t"))
        }
        for row in rows {
            lines.append(row.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }
}
