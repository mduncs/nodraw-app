import Foundation

/// Opt-in isolated QA/preview launches. Normal launches do not change queue policy.
/// The user-facing editor preview keeps normal window behavior; background QA does not.
enum BackgroundQAConfiguration {
    enum Mode: Equatable {
        case normal, backgroundQA, editorPreview
    }

    static func mode(for arguments: [String]) -> Mode {
        if arguments.contains("--background-qa") { return .backgroundQA }
        if arguments.contains("--editor-preview") { return .editorPreview }
        return .normal
    }

    static let launchMode = mode(for: CommandLine.arguments)
    static let isEnabled = launchMode != .normal
    static let usesNonactivatingWindows = launchMode == .backgroundQA
    static var logsDirectory: URL? {
        guard isEnabled,
              let isolation = try? validate(environment: ProcessInfo.processInfo.environment) else { return nil }
        return isolation.appData.appendingPathComponent("logs", isDirectory: true)
    }

    struct Isolation: Equatable {
        let appData: URL
        let archive: URL
    }

    enum ConfigurationError: LocalizedError {
        case missingPaths, unsafePath, overlappingPaths, maintenanceSuppressed, archiveChangeSuppressed
        var errorDescription: String? {
            switch self {
            case .missingPaths: "Isolated QA/preview requires explicit NODRAW_APP_SUPPORT_DIR and NODRAW_ARCHIVE_PATH."
            case .unsafePath: "Isolated QA/preview requires absolute directories, not a home, default live-data directory, or filesystem root."
            case .overlappingPaths: "Isolated QA/preview app-data and archive directories must be separate."
            case .maintenanceSuppressed: "This isolated preview suppresses background enrichment, model loading, notifications, and download-server changes."
            case .archiveChangeSuppressed: "This preview uses its own sample library. Import photos into it instead of changing the archive folder."
            }
        }
    }

    static func validate(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Isolation {
        guard let app = environment["NODRAW_APP_SUPPORT_DIR"], let archive = environment["NODRAW_ARCHIVE_PATH"],
              !app.isEmpty, !archive.isEmpty else { throw ConfigurationError.missingPaths }
        guard app.hasPrefix("/"), archive.hasPrefix("/") else { throw ConfigurationError.unsafePath }
        let roots = [app, archive].map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
        let forbidden = [home, home.appendingPathComponent("MediaArchive")] +
            ["NoDraw", "MediaViewer", "com.nodraw.app", "media-viewer", "com.mediaviewer"].map {
                home.appendingPathComponent("Library/Application Support/\($0)")
            }
        for root in roots {
            guard root.path != "/", root.path != home.standardizedFileURL.resolvingSymlinksInPath().path else { throw ConfigurationError.unsafePath }
            for live in forbidden.dropFirst() {
                let path = live.standardizedFileURL.resolvingSymlinksInPath().path
                guard root.path != path, !root.path.hasPrefix(path + "/") else { throw ConfigurationError.unsafePath }
            }
        }
        guard roots[0] != roots[1], !roots[0].path.hasPrefix(roots[1].path + "/"),
              !roots[1].path.hasPrefix(roots[0].path + "/") else { throw ConfigurationError.overlappingPaths }
        return Isolation(appData: roots[0], archive: roots[1])
    }
}
