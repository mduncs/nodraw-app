import Foundation
import UniformTypeIdentifiers

/// One outcome per external provider, kept in drop order even when callbacks finish out of order.
struct ImportDropEntry: Sendable {
    let position: Int
    let scope: ImportSecurityScope?
    let error: ImportError?
}

struct ImportDropBatch: Sendable {
    let entries: [ImportDropEntry]
    var scopes: [ImportSecurityScope] {
        var seen = Set<String>()
        return entries.compactMap(\.scope).filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }
    var errors: [ImportError] { entries.compactMap(\.error) }

    func merging(_ result: ImportResult) -> ImportResult {
        Self.adding(errors: errors, to: result)
    }

    static func adding(errors: [ImportError], to result: ImportResult) -> ImportResult {
        ImportResult(importedCount: result.importedCount, skippedCount: result.skippedCount,
                     failedCount: result.failedCount + errors.count, createdItemIds: result.createdItemIds,
                     errors: errors + result.errors, cancelledCount: result.cancelledCount, skippedItems: result.skippedItems)
    }
}

enum ImportDropDecoder {
    static func decode(item: NSSecureCoding?, error: Error?, position: Int, suggestedName: String?, archivePath: URL? = nil) -> ImportDropEntry {
        let label = "Drop item \(position + 1)" + (suggestedName.map { " · \($0)" } ?? "")
        if let error {
            return ImportDropEntry(position: position, scope: nil, error: ImportError(filename: label,
                reason: "The source app could not provide this file: \(error.localizedDescription). Drop the file again from Finder."))
        }
        guard let url = fileURL(item), url.isFileURL else {
            return ImportDropEntry(position: position, scope: nil, error: ImportError(filename: label,
                reason: "The drop did not contain a usable file URL. Drop the file again from Finder."))
        }
        let scope = ImportSecurityScope(url)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let archiveResident = archivePath.map { ImportLibraryDuplicatePrevention.isInArchive(url, archivePath: $0) } ?? false
        guard exists, !isDirectory.boolValue || archiveResident else {
            return ImportDropEntry(position: position, scope: nil, error: ImportError(
                filename: "Drop item \(position + 1) · \(url.lastPathComponent)",
                reason: isDirectory.boolValue ? "Folders cannot be imported. Drop individual media files from this folder." : "The source file is missing or unavailable. Restore it at this location and retry, or drop it again from Finder.",
                sourceURL: isDirectory.boolValue ? nil : url))
        }
        return ImportDropEntry(position: position, scope: scope, error: nil)
    }

    static func load(_ providers: [NSItemProvider], archivePath: URL? = nil, completion: @escaping (ImportDropBatch) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var entries: [Int: ImportDropEntry] = [:]
        for (position, provider) in providers.enumerated() {
            group.enter()
            let name = provider.suggestedName
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                let entry = decode(item: item, error: error, position: position, suggestedName: name, archivePath: archivePath)
                lock.lock()
                entries[position] = entry
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(ImportDropBatch(entries: providers.indices.compactMap { entries[$0] }))
        }
    }

    private static func fileURL(_ item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
            if let string = String(data: data, encoding: .utf8) { return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        if let string = item as? String { return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}
