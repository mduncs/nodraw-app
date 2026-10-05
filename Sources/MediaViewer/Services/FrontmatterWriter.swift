import Foundation
import Yams
import Darwin

/// Both processes lock the stable adjacent inode; never unlink the lock file.
enum FrontmatterWriter {
    enum WriterError: Error, LocalizedError {
        case noFrontmatter, invalidYAML, fileNotFound, symbolicLink, concurrentModification
        var errorDescription: String? {
            switch self {
            case .noFrontmatter: return "File has no frontmatter block"
            case .invalidYAML: return "Frontmatter must be a YAML mapping"
            case .fileNotFound: return "Metadata file is missing; restore it and retry"
            case .symbolicLink: return "Metadata sidecars must be regular files, not symbolic links"
            case .concurrentModification: return "The metadata file changed during publication; the edit remains pending"
            }
        }
    }

    struct FrontmatterBounds {
        let yamlText: String
        let bodyStartIndex: String.Index
    }

    @discardableResult
    static func processFrontmatter(at url: URL, transform: (inout [String: Any]) throws -> Void) throws -> String {
        try withLockedSidecar(at: url) { target in
            let content = try String(contentsOf: target, encoding: .utf8)
            let updated = try processContent(content, transform: transform)
            if updated != content { try writeAtomically(updated, original: content, to: target) }
            return updated
        }
    }

    static func withLockedSidecar<T>(at url: URL, _ body: (URL) throws -> T) throws -> T {
        // Resolve only the parent, matching the server's exact lock namespace.
        let target = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        let lockURL = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).nodraw-lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw posixError() }
        }
        defer { flock(descriptor, LOCK_UN) }
        guard FileManager.default.fileExists(atPath: target.path) else { throw WriterError.fileNotFound }
        if try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            throw WriterError.symbolicLink
        }
        return try body(target)
    }

    static func processContent(_ content: String, transform: (inout [String: Any]) throws -> Void) throws -> String {
        let bounds = try parseBoundaries(content)
        let loaded = try SidecarYAML.load(yaml: bounds.yamlText)
        guard loaded == nil || loaded is [String: Any] else { throw WriterError.invalidYAML }
        var yaml = loaded as? [String: Any] ?? [:]
        try transform(&yaml)
        let newline = content.contains("\r\n") ? "\r\n" : "\n"
        let serialized = try Yams.dump(object: yaml, allowUnicode: true, sortKeys: true)
            .trimmingCharacters(in: .newlines).replacingOccurrences(of: "\n", with: newline)
        let bom = content.hasPrefix("\u{FEFF}") ? "\u{FEFF}" : ""
        return "\(bom)---\(newline)\(serialized)\(newline)---\(content[bounds.bodyStartIndex...])"
    }

    static func parseBoundaries(_ content: String) throws -> FrontmatterBounds {
        let source = content as NSString
        let opening = try NSRegularExpression(pattern: "\\A(?:\\x{FEFF})?[ \\t]*---(?:\\r\\n|\\n)")
        guard let start = opening.firstMatch(in: content, range: NSRange(location: 0, length: source.length)) else {
            throw WriterError.noFrontmatter
        }
        let yamlStart = NSMaxRange(start.range)
        let closing = try NSRegularExpression(pattern: "(?m)^---(?=\\r?$)")
        guard let end = closing.firstMatch(in: content, range: NSRange(location: yamlStart, length: source.length - yamlStart)),
              let bodyRange = Range(NSRange(location: NSMaxRange(end.range), length: 0), in: content) else {
            throw WriterError.noFrontmatter
        }
        return FrontmatterBounds(yamlText: source.substring(with: NSRange(location: yamlStart, length: end.range.location - yamlStart)), bodyStartIndex: bodyRange.lowerBound)
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    /// Copy all metadata (Finder Date Added, xattrs, ACLs), modify only staging's
    /// data fork, retain a recoverable previous version, then atomically publish.
    private static func writeAtomically(_ content: String, original: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).nodraw-tmp")
        let backup = directory.appendingPathComponent(".\(url.lastPathComponent).nodraw-previous")
        let backupStaging = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).nodraw-backup-tmp")
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: backupStaging)
        }
        guard copyfile(url.path, staging.path, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else { throw posixError() }
        let handle = try FileHandle(forWritingTo: staging)
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(content.utf8))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard try Data(contentsOf: url) == Data(original.utf8) else { throw WriterError.concurrentModification }
        guard copyfile(url.path, backupStaging.path, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else { throw posixError() }
        let backupHandle = try FileHandle(forWritingTo: backupStaging)
        try backupHandle.synchronize()
        try backupHandle.close()
        guard Darwin.rename(backupStaging.path, backup.path) == 0 else { throw posixError() }
        // Cooperating writers are serialized by flock. This final comparison
        // detects editors that ignore the lock, but cannot eliminate the tiny
        // compare/rename race with such an editor.
        guard try Data(contentsOf: url) == Data(original.utf8) else { throw WriterError.concurrentModification }
        guard Darwin.rename(staging.path, url.path) == 0 else { throw posixError() }
        let parent = Darwin.open(directory.path, O_RDONLY)
        guard parent >= 0 else { throw posixError() }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw posixError() }
    }
}
