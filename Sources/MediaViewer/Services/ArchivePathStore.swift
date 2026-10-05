import Foundation

/// Single source of truth for archive path persistence.
/// Keeps legacy keys in sync to prevent server/watcher/import path drift.
enum ArchivePathStore {
    static let archivePathKey = "archivePath"
    static let downloadServerArchiveDirKey = "downloadServerArchiveDir"
    private static let archivePathOverrideKeys = [
        "NODRAW_ARCHIVE_PATH",
        "MEDIAVIEWER_ARCHIVE_PATH"
    ]

    static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("MediaArchive")
    }

    static func currentPath(defaults: UserDefaults = .standard) -> URL {
        if let overridePath = overridePath() {
            return overridePath
        }

        let archiveRaw = normalizedPathString(defaults.string(forKey: archivePathKey))
        let downloadRaw = normalizedPathString(defaults.string(forKey: downloadServerArchiveDirKey))

        switch (archiveRaw, downloadRaw) {
        case (nil, nil):
            return defaultPath
        case (let archive?, nil):
            return URL(fileURLWithPath: archive)
        case (nil, let download?):
            return URL(fileURLWithPath: download)
        case (let archive?, let download?):
            if archive == download {
                return URL(fileURLWithPath: archive)
            }

            let archiveExists = FileManager.default.fileExists(atPath: archive)
            let downloadExists = FileManager.default.fileExists(atPath: download)

            if archiveExists && !downloadExists {
                return URL(fileURLWithPath: archive)
            }
            if downloadExists && !archiveExists {
                return URL(fileURLWithPath: download)
            }

            // Settings UI has historically written this key, so prefer it on ties.
            return URL(fileURLWithPath: download)
        }
    }

    static func setCurrentPath(_ path: URL, defaults: UserDefaults = .standard) {
        let normalized = path.standardizedFileURL.path
        defaults.set(normalized, forKey: archivePathKey)
        defaults.set(normalized, forKey: downloadServerArchiveDirKey)
    }

    @discardableResult
    static func reconciledPath(defaults: UserDefaults = .standard) -> URL {
        if let overridePath = overridePath() {
            return overridePath
        }

        let resolved = currentPath(defaults: defaults)
        setCurrentPath(resolved, defaults: defaults)
        return resolved
    }

    private static func overridePath() -> URL? {
        let env = ProcessInfo.processInfo.environment

        for key in archivePathOverrideKeys {
            guard let rawValue = normalizedPathString(env[key]) else { continue }
            return URL(fileURLWithPath: rawValue)
        }

        return nil
    }

    private static func normalizedPathString(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }
}
