import Foundation

enum DownloadToolSearchPaths {
    static var launchdDirectories: [URL] {
        uniqueDirectories([
            AppPaths.binDirectory,
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true)
        ])
    }

    static var environmentDirectories: [URL] {
        let rawPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return uniqueDirectories(
            rawPath
                .split(separator: ":")
                .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        )
    }

    static var executableSearchDirectories: [URL] {
        uniqueDirectories(launchdDirectories + environmentDirectories)
    }

    static var launchdPath: String {
        launchdDirectories.map(\.path).joined(separator: ":")
    }

    static func uniqueDirectories(_ directories: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        for directory in directories {
            let normalized = directory.standardizedFileURL
            guard seen.insert(normalized.path).inserted else { continue }
            result.append(normalized)
        }

        return result
    }
}

/// Manages downloading and updating standalone tool binaries for the download server.
/// Tools are fetched from GitHub releases and stored in AppPaths.binDirectory (or custom target).
actor DependencyManager {

    static let shared = DependencyManager()

    // MARK: - Types

    enum ReleaseAssetMatch: Sendable {
        case exact
        case contains
    }

    struct ToolInfo: Sendable {
        let name: String
        let repo: String           // "owner/repo"
        let assetPattern: String   // substring match on release asset name
        let isArchive: Bool        // whether asset is .tar.xz / .zip that needs extraction
        let executableName: String // name of binary after extraction
        let targetDirectory: URL?  // nil = default binDirectory
        let installable: Bool
        let versionArguments: [String]?
        let pythonModuleName: String?
        let allowExecutableFallback: Bool
        let releaseAssetMatch: ReleaseAssetMatch

        init(
            name: String,
            repo: String,
            assetPattern: String,
            isArchive: Bool,
            executableName: String,
            targetDirectory: URL?,
            installable: Bool = true,
            versionArguments: [String]? = ["--version"],
            pythonModuleName: String? = nil,
            allowExecutableFallback: Bool = true,
            releaseAssetMatch: ReleaseAssetMatch = .contains
        ) {
            self.name = name
            self.repo = repo
            self.assetPattern = assetPattern
            self.isArchive = isArchive
            self.executableName = executableName
            self.targetDirectory = targetDirectory
            self.installable = installable
            self.versionArguments = versionArguments
            self.pythonModuleName = pythonModuleName
            self.allowExecutableFallback = allowExecutableFallback
            self.releaseAssetMatch = releaseAssetMatch
        }

        func matchesReleaseAsset(named assetName: String) -> Bool {
            switch releaseAssetMatch {
            case .exact:
                return assetName == assetPattern
            case .contains:
                return assetName.contains(assetPattern)
            }
        }
    }

    struct ToolStatus: Sendable, Identifiable {
        var id: String { name }
        let name: String
        let installed: Bool
        let version: String?
        let binaryPath: URL?
        let sourceDescription: String?
        let searchedPaths: [String]
        let installable: Bool
    }

    struct InstallResult: Sendable {
        let tool: String
        let success: Bool
        let error: String?
    }

    struct UpdateInfo: Sendable {
        let tool: String
        let currentVersion: String
        let latestVersion: String
    }

    enum DependencyError: Error, LocalizedError {
        case noRelease(String)
        case noMatchingAsset(String)
        case downloadFailed(String)
        case extractionFailed(String)
        case verificationFailed(String)
        case rateLimited(resetDate: Date)
        case notInstallable(String)

        var errorDescription: String? {
            switch self {
            case .noRelease(let tool): return "No release found for \(tool)"
            case .noMatchingAsset(let tool): return "No matching asset for \(tool)"
            case .downloadFailed(let msg): return "Download failed: \(msg)"
            case .extractionFailed(let msg): return "Extraction failed: \(msg)"
            case .verificationFailed(let msg): return "Binary verification failed: \(msg)"
            case .rateLimited(let resetDate):
                let formatter = DateFormatter()
                formatter.dateStyle = .none
                formatter.timeStyle = .short
                return "GitHub API rate limited. Resets at \(formatter.string(from: resetDate))"
            case .notInstallable(let tool):
                return "\(tool) is provided by the download server runtime, not installed as a standalone app-support binary."
            }
        }
    }

    // MARK: - Release Cache

    private struct CachedRelease: Codable {
        let assetURL: String
        let version: String
        let etag: String?
        let fetchedAt: Date
    }

    /// TTL for install checks (do we have the latest binary?)
    private static let installCacheTTL: TimeInterval = 3600        // 1 hour
    /// TTL for update-available checks (is there a newer version?)
    private static let updateCheckCacheTTL: TimeInterval = 86400   // 24 hours

    // MARK: - Tool Registry

    /// Video normalization is healthy only when the encoder and probe from the
    /// same managed toolchain are both resolvable. Keeping the pair explicit also
    /// makes clean-machine readiness and Settings status agree with server needs.
    static let requiredMediaExecutableNames = ["ffmpeg", "ffprobe"]

    static var tools: [ToolInfo] {
        #if arch(arm64)
        let mediaToolAssetSuffix = "darwin-arm64"
        let serverAsset = "media-archiver-darwin-arm64"
        #else
        let mediaToolAssetSuffix = "darwin-x64"
        let serverAsset = "media-archiver-darwin-x64"
        #endif

        return [
            ToolInfo(
                name: "yt-dlp",
                repo: "yt-dlp/yt-dlp",
                assetPattern: "yt-dlp_macos",
                isArchive: false,
                executableName: "yt-dlp",
                targetDirectory: nil,
                installable: false,
                pythonModuleName: "yt_dlp",
                allowExecutableFallback: false
            ),
            ToolInfo(
                name: "gallery-dl",
                repo: "mikf/gallery-dl",
                assetPattern: "gallery-dl.bin",
                isArchive: false,
                executableName: "gallery-dl",
                targetDirectory: nil,
                installable: false,
                pythonModuleName: "gallery_dl"
            ),
            ToolInfo(
                name: "ffmpeg",
                repo: "eugeneware/ffmpeg-static",
                assetPattern: "ffmpeg-\(mediaToolAssetSuffix)",
                isArchive: false,
                executableName: "ffmpeg",
                targetDirectory: nil,
                versionArguments: ["-version"],
                releaseAssetMatch: .exact
            ),
            ToolInfo(
                name: "ffprobe",
                repo: "eugeneware/ffmpeg-static",
                assetPattern: "ffprobe-\(mediaToolAssetSuffix)",
                isArchive: false,
                executableName: "ffprobe",
                targetDirectory: nil,
                versionArguments: ["-version"],
                releaseAssetMatch: .exact
            ),
            ToolInfo(
                name: "dezoomify-rs",
                repo: "lovasoa/dezoomify-rs",
                assetPattern: "apple-darwin",
                isArchive: true,
                executableName: "dezoomify-rs",
                targetDirectory: nil
            ),
            ToolInfo(
                name: "media-archiver",
                repo: "mduncs/url-saver",
                assetPattern: serverAsset,
                isArchive: false,
                executableName: "media-archiver",
                targetDirectory: AppPaths.downloadServerDirectory,
                versionArguments: nil
            ),
        ]
    }

    // MARK: - State

    private var installedVersions: [String: String] = [:]  // tool name -> version
    private let binDir = AppPaths.binDirectory
    private var releaseCache: [String: CachedRelease] = [:]
    private let cacheURL = AppPaths.appDataDirectory.appendingPathComponent("github-release-cache.json")

    private enum ToolResolutionKind {
        case executable(URL)
        case pythonModule(python: URL, module: String)
        case bundledRuntime(URL)
        case developmentServer(URL)
    }

    private struct ToolResolution {
        let kind: ToolResolutionKind
        let binaryPath: URL?
        let sourceDescription: String
        let searchedPaths: [String]
    }

    // MARK: - Init

    init() {
        releaseCache = Self.loadReleaseCacheFromDisk(
            at: AppPaths.appDataDirectory.appendingPathComponent("github-release-cache.json")
        )
    }

    // MARK: - Public API

    /// Resolve the target directory for a given tool
    private func targetDir(for tool: ToolInfo) -> URL {
        tool.targetDirectory ?? binDir
    }

    /// Check status of all tools, detecting installed versions via `--version`
    func checkAll() async -> [ToolStatus] {
        var statuses: [ToolStatus] = []
        for tool in Self.tools {
            let searchedPaths = searchedExecutablePaths(for: tool)
            let resolution = resolve(tool: tool, searchedPaths: searchedPaths)
            let installed = resolution != nil

            var version: String? = installedVersions[tool.name]
            if installed && version == nil {
                version = detectVersion(tool: tool, resolution: resolution)
                if let v = version {
                    installedVersions[tool.name] = v
                }
            }

            statuses.append(ToolStatus(
                name: tool.name,
                installed: installed,
                version: version,
                binaryPath: resolution?.binaryPath,
                sourceDescription: resolution?.sourceDescription,
                searchedPaths: resolution?.searchedPaths ?? searchedPaths.map(\.path),
                installable: tool.installable
            ))
        }
        return statuses
    }

    /// Check if a specific tool is installed
    func isInstalled(_ toolName: String) -> Bool {
        guard let tool = Self.tools.first(where: { $0.name == toolName }) else { return false }
        return resolve(tool: tool, searchedPaths: searchedExecutablePaths(for: tool)) != nil
    }

    /// Install a tool from its GitHub release
    func install(_ toolName: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let tool = Self.tools.first(where: { $0.name == toolName }) else {
            throw DependencyError.noRelease(toolName)
        }
        guard tool.installable else {
            throw DependencyError.notInstallable(toolName)
        }

        // Fetch latest release from GitHub API
        let (assetURL, version) = try await fetchLatestRelease(tool: tool, ttl: Self.installCacheTTL)

        // Download the asset
        let tempFile = try await downloadAsset(url: assetURL, progress: progress)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let dir = targetDir(for: tool)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destPath = dir.appendingPathComponent(tool.executableName)
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dependency-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        let stagedPath = stagingDir.appendingPathComponent(tool.executableName)

        if tool.isArchive {
            // Extract archive into a staging location first so a bad download cannot
            // replace a working installed tool.
            try await extractArchive(tempFile, executable: tool.executableName, to: stagedPath)
        } else {
            // Direct binary -- stage and chmod before replacing any installed copy.
            try FileManager.default.copyItem(at: tempFile, to: stagedPath)
        }

        // Make executable
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: stagedPath.path
        )

        // Verify binary actually runs on this architecture
        let valid = verifyBinary(at: stagedPath, name: toolName)
        if !valid {
            throw DependencyError.verificationFailed(
                "\(toolName) binary failed --version check (bad CPU type or corrupted)"
            )
        }

        try installVerifiedBinary(from: stagedPath, to: destPath, toolName: toolName)

        // Detect real version string from the binary itself
        let resolution = resolve(tool: tool, searchedPaths: searchedExecutablePaths(for: tool))
        let detectedVersion = detectVersion(tool: tool, resolution: resolution) ?? version
        installedVersions[toolName] = detectedVersion
        logInfo("Installed \(toolName) \(detectedVersion) at \(destPath.path)")
    }

    /// Install all tools, returning per-tool results. Does not abort on individual failures.
    /// Uses a concurrency limit of 2 for parallel downloads.
    func installAll(progress: (@Sendable (String, Double) -> Void)? = nil) async -> [InstallResult] {
        let toolList = Self.tools.filter(\.installable)
        let totalCount = Double(toolList.count)

        // Use TaskGroup with a manual concurrency limit of 2
        let results = await withTaskGroup(of: InstallResult.self, returning: [InstallResult].self) { group in
            var completed: [InstallResult] = []
            completed.reserveCapacity(toolList.count)
            var nextIndex = 0

            // Seed with up to 2 concurrent tasks
            func addNextTask() -> Bool {
                guard nextIndex < toolList.count else { return false }
                let tool = toolList[nextIndex]
                let index = nextIndex
                nextIndex += 1

                group.addTask { [weak self] in
                    guard let self = self else {
                        return InstallResult(tool: tool.name, success: false, error: "DependencyManager deallocated")
                    }
                    do {
                        try await self.install(tool.name) { fraction in
                            let overallBase = Double(index) / totalCount
                            let overallStep = 1.0 / totalCount
                            progress?(tool.name, overallBase + fraction * overallStep)
                        }
                        return InstallResult(tool: tool.name, success: true, error: nil)
                    } catch {
                        logError("Failed to install \(tool.name): \(error.localizedDescription)")
                        return InstallResult(tool: tool.name, success: false, error: error.localizedDescription)
                    }
                }
                return true
            }

            // Seed 2 tasks
            _ = addNextTask()
            _ = addNextTask()

            // As each completes, add the next
            for await result in group {
                completed.append(result)
                progress?(result.tool, Double(completed.count) / totalCount)
                _ = addNextTask()
            }

            return completed
        }

        progress?("done", 1.0)
        return results
    }

    /// Check installed tools for available updates using cached release data (24hr TTL).
    func checkForUpdates() async -> [UpdateInfo] {
        var updates: [UpdateInfo] = []

        for tool in Self.tools {
            guard tool.installable else { continue }
            let path = targetDir(for: tool).appendingPathComponent(tool.executableName)
            guard FileManager.default.isExecutableFile(atPath: path.path) else { continue }

            let resolution = resolve(tool: tool, searchedPaths: searchedExecutablePaths(for: tool))
            let currentVersion = installedVersions[tool.name] ?? detectVersion(tool: tool, resolution: resolution)
            guard let current = currentVersion else { continue }

            do {
                let (_, latestVersion) = try await fetchLatestRelease(
                    tool: tool, ttl: Self.updateCheckCacheTTL
                )
                if latestVersion != current {
                    updates.append(UpdateInfo(
                        tool: tool.name,
                        currentVersion: current,
                        latestVersion: latestVersion
                    ))
                }
            } catch {
                logWarning("Update check failed for \(tool.name): \(error.localizedDescription)")
            }
        }

        return updates
    }

    /// Path to the bin directory (for passing as MEDIA_ARCHIVER_BIN env var)
    func binDirectoryPath() -> String {
        binDir.path
    }

    // MARK: - Version Detection

    private func searchedExecutablePaths(for tool: ToolInfo) -> [URL] {
        executableCandidates(for: tool).map {
            $0.appendingPathComponent(tool.executableName)
        }
    }

    private func executableCandidates(for tool: ToolInfo) -> [URL] {
        var directories: [URL] = []
        directories.append(targetDir(for: tool))
        directories.append(contentsOf: DownloadToolSearchPaths.executableSearchDirectories)
        return DownloadToolSearchPaths.uniqueDirectories(directories)
    }

    private func resolve(tool: ToolInfo, searchedPaths: [URL]) -> ToolResolution? {
        if let moduleName = tool.pythonModuleName {
            if let bundled = resolveBundledRuntime(for: tool, searchedPaths: searchedPaths) {
                return bundled
            }

            if let python = resolvePythonModule(moduleName) {
                return ToolResolution(
                    kind: .pythonModule(python: python, module: moduleName),
                    binaryPath: python,
                    sourceDescription: "server Python package",
                    searchedPaths: searchedPaths.map(\.path)
                )
            }

            guard tool.allowExecutableFallback else {
                return nil
            }
        }

        if let executable = resolveExecutable(tool: tool) {
            return ToolResolution(
                kind: .executable(executable.url),
                binaryPath: executable.url,
                sourceDescription: executable.sourceDescription,
                searchedPaths: searchedPaths.map(\.path)
            )
        }

        if tool.name == "media-archiver",
           let developmentServer = Self.resolveDevelopmentServerRuntime() {
            return ToolResolution(
                kind: .developmentServer(developmentServer.python),
                binaryPath: developmentServer.python,
                sourceDescription: "development Python server",
                searchedPaths: searchedPaths.map(\.path)
            )
        }

        return nil
    }

    private func resolveExecutable(tool: ToolInfo) -> (url: URL, sourceDescription: String)? {
        if tool.name == "media-archiver", let server = Self.resolveMediaArchiverExecutable() {
            return server
        }

        if let bundled = Bundle.main.url(forResource: tool.executableName, withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return (bundled, "app bundle")
        }

        if let found = Self.firstExecutable(
            named: tool.executableName,
            in: executableCandidates(for: tool)
        ) {
            let source = found.deletingLastPathComponent().standardizedFileURL == targetDir(for: tool).standardizedFileURL
                ? "Application Support"
                : "server PATH"
            return (found, source)
        }

        return nil
    }

    private func resolveBundledRuntime(for tool: ToolInfo, searchedPaths: [URL]) -> ToolResolution? {
        guard tool.name != "media-archiver",
              let mediaArchiver = Self.resolveMediaArchiverExecutable(),
              Self.looksLikeStandaloneBinary(mediaArchiver.url) else {
            return nil
        }

        return ToolResolution(
            kind: .bundledRuntime(mediaArchiver.url),
            binaryPath: mediaArchiver.url,
            sourceDescription: "bundled with media-archiver",
            searchedPaths: searchedPaths.map(\.path)
        )
    }

    private func resolvePythonModule(_ moduleName: String) -> URL? {
        for python in Self.serverPythonCandidates() {
            guard FileManager.default.isExecutableFile(atPath: python.path) else { continue }
            let check = Self.runProcess(
                executableURL: python,
                arguments: ["-c", "import \(moduleName)"],
                timeout: 3
            )
            if check?.exitCode == 0 {
                return python
            }
        }

        return nil
    }

    /// Run the resolved tool version command and parse the first non-empty line.
    private func detectVersion(tool: ToolInfo, resolution: ToolResolution?) -> String? {
        guard let resolution else { return nil }

        let result: (exitCode: Int32, output: String)?
        switch resolution.kind {
        case .executable(let executable):
            guard let versionArguments = tool.versionArguments else { return nil }
            result = Self.runProcess(
                executableURL: executable,
                arguments: versionArguments,
                timeout: 5
            )

        case .pythonModule(let python, let module):
            result = Self.runProcess(
                executableURL: python,
                arguments: ["-m", module, "--version"],
                timeout: 5
            )

        case .bundledRuntime, .developmentServer:
            return nil
        }

        guard result?.exitCode == 0 else { return nil }
        return result?.output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    // MARK: - Binary Verification

    /// Run `{binary} --version` to verify the binary is valid and matches this architecture.
    private func verifyBinary(at path: URL, name: String) -> Bool {
        guard let tool = Self.tools.first(where: { $0.name == name }),
              let versionArguments = tool.versionArguments else {
            return FileManager.default.isExecutableFile(atPath: path.path)
        }

        guard let result = Self.runProcess(
            executableURL: path,
            arguments: versionArguments,
            timeout: 10
        ) else {
            logWarning("\(name) binary verification timed out")
            return false
        }

        let ok = result.exitCode == 0
        if !ok {
            logWarning("\(name) version check exited with status \(result.exitCode)")
        }
        return ok
    }

    static func firstExecutable(named name: String, in directories: [URL], fileManager: FileManager = .default) -> URL? {
        for directory in DownloadToolSearchPaths.uniqueDirectories(directories) {
            let candidate = directory.appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    static func executableURL(named name: String, fileManager: FileManager = .default) -> URL? {
        guard let tool = tools.first(where: { $0.name == name }) else {
            return firstExecutable(
                named: name,
                in: DownloadToolSearchPaths.executableSearchDirectories,
                fileManager: fileManager
            )
        }

        let targetDirectory = tool.targetDirectory ?? AppPaths.binDirectory
        let directories = DownloadToolSearchPaths.uniqueDirectories(
            [targetDirectory] + DownloadToolSearchPaths.executableSearchDirectories
        )
        return firstExecutable(named: tool.executableName, in: directories, fileManager: fileManager)
    }

    static func resolveMediaArchiverExecutable() -> (url: URL, sourceDescription: String)? {
        if let bundled = Bundle.main.url(forResource: "media-archiver", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return (bundled, "app bundle")
        }

        let localBinary = AppPaths.downloadServerDirectory.appendingPathComponent("media-archiver")
        if FileManager.default.isExecutableFile(atPath: localBinary.path) {
            return (localBinary, "Application Support")
        }

        #if DEBUG
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspaceRoot = repoRoot.deletingLastPathComponent()

        let devBinaryCandidates = [
            workspaceRoot.appendingPathComponent("url-saver/dist/media-archiver"),
            repoRoot.appendingPathComponent("dist/media-archiver")
        ]
        for devBinary in devBinaryCandidates where FileManager.default.isExecutableFile(atPath: devBinary.path) {
            return (devBinary, "development build")
        }
        #endif

        return nil
    }

    static func serverPythonCandidates() -> [URL] {
        var candidates: [URL] = []

        if let mediaArchiver = resolveMediaArchiverExecutable()?.url,
           let launcherPython = pythonExecutableFromLauncher(mediaArchiver) {
            candidates.append(launcherPython)
        }

        #if DEBUG
        for serverDir in developmentServerDirectories() {
            candidates.append(serverDir.appendingPathComponent(".venv/bin/python"))
            candidates.append(serverDir.appendingPathComponent(".venv/bin/python3"))
            candidates.append(serverDir.appendingPathComponent("venv/bin/python"))
            candidates.append(serverDir.appendingPathComponent("venv/bin/python3"))
        }
        #endif

        if let python3 = firstExecutable(named: "python3", in: DownloadToolSearchPaths.executableSearchDirectories) {
            candidates.append(python3)
        }

        return uniqueURLs(candidates)
    }

    static func resolveDevelopmentServerRuntime() -> (python: URL, serverDir: URL)? {
        #if DEBUG
        for serverDir in developmentServerDirectories() {
            let mainPy = serverDir.appendingPathComponent("main.py")
            guard FileManager.default.fileExists(atPath: mainPy.path) else { continue }

            let pythonCandidates = [
                serverDir.appendingPathComponent(".venv/bin/python"),
                serverDir.appendingPathComponent(".venv/bin/python3"),
                serverDir.appendingPathComponent("venv/bin/python"),
                serverDir.appendingPathComponent("venv/bin/python3")
            ]

            if let python = firstExecutable(
                named: "python",
                in: pythonCandidates.map { $0.deletingLastPathComponent() }
            ) {
                return (python, serverDir)
            }

            if let python3 = firstExecutable(
                named: "python3",
                in: pythonCandidates.map { $0.deletingLastPathComponent() }
            ) {
                return (python3, serverDir)
            }

            return (URL(fileURLWithPath: "/usr/bin/env"), serverDir)
        }
        #endif

        return nil
    }

    private static func developmentServerDirectories() -> [URL] {
        #if DEBUG
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspaceRoot = repoRoot.deletingLastPathComponent()

        return [
            repoRoot.appendingPathComponent("server"),
            workspaceRoot.appendingPathComponent("url-saver/server")
        ]
        #else
        return []
        #endif
    }

    static func pythonExecutableFromLauncher(_ launcherURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: launcherURL, options: .mappedIfSafe),
              let text = String(data: Data(data.prefix(16 * 1024)), encoding: .utf8),
              text.hasPrefix("#!") else {
            return nil
        }

        var assignments: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let equalIndex = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<equalIndex])
            guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                continue
            }

            var value = String(line[line.index(after: equalIndex)...])
                .trimmingCharacters(in: .whitespaces)
            value = stripShellQuotes(value)
            value = expandShellVariables(value, assignments: assignments)
            assignments[name] = value
        }

        guard let pythonPath = assignments["PYTHON"], !pythonPath.isEmpty else { return nil }
        return URL(fileURLWithPath: pythonPath)
    }

    private static func stripShellQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func expandShellVariables(_ value: String, assignments: [String: String]) -> String {
        var expanded = value
        for (name, replacement) in assignments {
            expanded = expanded.replacingOccurrences(of: "$\(name)", with: replacement)
            expanded = expanded.replacingOccurrences(of: "${\(name)}", with: replacement)
        }
        return expanded
    }

    private static func looksLikeStandaloneBinary(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              !data.isEmpty else {
            return false
        }

        if data.starts(with: Data([0x23, 0x21])) {
            return false
        }

        return true
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> (exitCode: Int32, output: String)? {
        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
        } catch {
            logWarning("Tool process failed to launch: \(error.localizedDescription)")
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if proc.isRunning {
            proc.terminate()
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (proc.terminationStatus, output)
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        for url in urls {
            let normalized = url.standardizedFileURL
            guard seen.insert(normalized.path).inserted else { continue }
            result.append(normalized)
        }

        return result
    }

    // MARK: - GitHub API

    private func fetchLatestRelease(tool: ToolInfo, ttl: TimeInterval) async throws -> (URL, String) {
        // Check cache first
        if let cached = releaseCache[tool.name] {
            let age = Date().timeIntervalSince(cached.fetchedAt)
            if age < ttl, let url = URL(string: cached.assetURL) {
                return (url, cached.version)
            }
        }

        let apiURL = URL(string: "https://api.github.com/repos/\(tool.repo)/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NoDraw", forHTTPHeaderField: "User-Agent")

        // Send ETag for conditional request if we have a cached entry
        if let cachedEtag = releaseCache[tool.name]?.etag {
            request.setValue(cachedEtag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DependencyError.noRelease(tool.name)
        }

        // Check rate limit headers
        if let remainingStr = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
           let remaining = Int(remainingStr), remaining <= 5 {
            logWarning("GitHub API rate limit low: \(remaining) requests remaining for \(tool.name)")
        }

        // Handle rate limited response
        if httpResponse.statusCode == 403 {
            var resetDate = Date().addingTimeInterval(3600)  // fallback: 1 hour
            if let resetStr = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset"),
               let resetTimestamp = TimeInterval(resetStr) {
                resetDate = Date(timeIntervalSince1970: resetTimestamp)
            }
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            logError("GitHub API rate limited for \(tool.name). Resets at \(formatter.string(from: resetDate))")
            throw DependencyError.rateLimited(resetDate: resetDate)
        }

        // 304 Not Modified -- return cached data
        if httpResponse.statusCode == 304, let cached = releaseCache[tool.name],
           let url = URL(string: cached.assetURL) {
            // Refresh the timestamp so TTL resets
            releaseCache[tool.name] = CachedRelease(
                assetURL: cached.assetURL,
                version: cached.version,
                etag: cached.etag,
                fetchedAt: Date()
            )
            saveReleaseCacheToDisk()
            return (url, cached.version)
        }

        guard httpResponse.statusCode == 200 else {
            throw DependencyError.noRelease(tool.name)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw DependencyError.noRelease(tool.name)
        }

        // Find the configured asset. Exact matching is required for raw media
        // binaries so similarly named LICENSE, README, and .gz assets cannot be
        // staged as executables.
        guard let asset = assets.first(where: {
            guard let assetName = $0["name"] as? String else { return false }
            return tool.matchesReleaseAsset(named: assetName)
        }),
              let downloadURL = (asset["browser_download_url"] as? String).flatMap({ URL(string: $0) }) else {
            throw DependencyError.noMatchingAsset(tool.name)
        }

        // Cache the result
        let etag = httpResponse.value(forHTTPHeaderField: "ETag")
        releaseCache[tool.name] = CachedRelease(
            assetURL: downloadURL.absoluteString,
            version: tagName,
            etag: etag,
            fetchedAt: Date()
        )
        saveReleaseCacheToDisk()

        return (downloadURL, tagName)
    }

    private func downloadAsset(url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw DependencyError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        // Move to a known temp location (URLSession temp files can vanish).
        // Preserve the release asset filename so archive extraction can detect
        // formats such as .tar.xz and .zip.
        let rawFileName = response.suggestedFilename?.isEmpty == false
            ? response.suggestedFilename!
            : url.lastPathComponent
        let safeFileName = rawFileName.isEmpty ? "asset" : rawFileName
        let stableTempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(safeFileName)")
        try FileManager.default.moveItem(at: tempURL, to: stableTempURL)

        progress?(1.0)
        return stableTempURL
    }

    private func installVerifiedBinary(from stagedPath: URL, to destPath: URL, toolName: String) throws {
        let fm = FileManager.default
        let backupPath = destPath.deletingLastPathComponent()
            .appendingPathComponent(".\(destPath.lastPathComponent).previous-\(UUID().uuidString)")
        let hadExistingBinary = fm.fileExists(atPath: destPath.path)

        if hadExistingBinary {
            try fm.moveItem(at: destPath, to: backupPath)
        }

        do {
            try fm.moveItem(at: stagedPath, to: destPath)
            if hadExistingBinary {
                try? fm.removeItem(at: backupPath)
            }
        } catch {
            if hadExistingBinary {
                try? fm.removeItem(at: destPath)
                try? fm.moveItem(at: backupPath, to: destPath)
            }
            throw DependencyError.downloadFailed(
                "Could not install \(toolName); previous binary was preserved. \(error.localizedDescription)"
            )
        }
    }

    private func extractArchive(_ archiveURL: URL, executable: String, to destPath: URL) async throws {
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractDir) }

        let archiveName = archiveURL.lastPathComponent

        // Determine extraction command
        let process = Process()
        if archiveName.hasSuffix(".tar.xz") || archiveName.hasSuffix(".tar.gz") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["xf", archiveURL.path, "-C", extractDir.path]
        } else if archiveName.hasSuffix(".zip") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", archiveURL.path, "-d", extractDir.path]
        } else {
            // Try as raw binary
            try? FileManager.default.removeItem(at: destPath)
            try FileManager.default.copyItem(at: archiveURL, to: destPath)
            return
        }

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DependencyError.extractionFailed("tar/unzip exit code \(process.terminationStatus)")
        }

        // Find the executable in extracted contents
        guard let found = findExecutable(named: executable, in: extractDir) else {
            throw DependencyError.extractionFailed("Could not find \(executable) in archive")
        }

        try? FileManager.default.removeItem(at: destPath)
        try FileManager.default.moveItem(at: found, to: destPath)
    }

    private func findExecutable(named name: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent == name {
                return url
            }
        }
        return nil
    }

    // MARK: - Release Cache Persistence

    /// Load cache from disk (nonisolated so it can be called from init)
    private static func loadReleaseCacheFromDisk(at url: URL) -> [String: CachedRelease] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode([String: CachedRelease].self, from: data) else { return [:] }
        return cache
    }

    private func saveReleaseCacheToDisk() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(releaseCache) else { return }
        do {
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            logWarning("Failed to save release cache: \(error.localizedDescription)")
        }
    }
}
