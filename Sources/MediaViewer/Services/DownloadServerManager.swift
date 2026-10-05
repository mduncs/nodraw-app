import Foundation
import Combine

// MARK: - DownloadServerManager (launchd-based)

/// Manages the download server via launchd.
/// Writes/loads/unloads a LaunchAgent plist so the server runs independently of the app.
/// The app only writes config and checks health — launchd owns the process lifecycle.
@MainActor
final class DownloadServerManager: ObservableObject {

    static let shared = DownloadServerManager()

    // MARK: - Constants

    static let plistLabel = "com.nodraw.download-server"
    nonisolated static let port = 8847

    private static let launchAgentsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    private static let startupDelaySeconds = 5
    private static let startupHealthTimeout = TimeInterval(startupDelaySeconds + 10)

    private static var plistURL: URL {
        launchAgentURL(for: plistLabel)
    }

    private static var logURL: URL {
        URL(fileURLWithPath: "/tmp/nodraw-server.log")
    }

    private static var errorLogURL: URL {
        URL(fileURLWithPath: "/tmp/nodraw-server.error.log")
    }

    /// Fully obsolete launch agents owned by older app versions.
    /// These can be unloaded and moved out of LaunchAgents immediately.
    private static let obsoletePlistLabels = [
        "com.mediaviewer.download-server"
    ]

    /// Older service labels that may still exist from pre-integration setups.
    /// Unload them when the integrated server takes over, but only archive
    /// them when they are clearly stale.
    private static let legacyPlistLabels = [
        "com.mediaarchiver.server"
    ]

    private static var legacyPlistArchiveDirectory: URL {
        AppPaths.appDataDirectory.appendingPathComponent("LegacyLaunchAgents", isDirectory: true)
    }

    private static func launchAgentURL(for label: String) -> URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist")
    }

    // MARK: - Published State

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastLog: [String] = []

    // MARK: - Configuration

    var isEnabled: Bool {
        get { SettingsStore.shared.downloadServerEnabled }
        set {
            objectWillChange.send()
            SettingsStore.shared.downloadServerEnabled = newValue
        }
    }

    var archiveDirectory: String {
        get { SettingsStore.shared.downloadServerArchiveDir }
        set {
            objectWillChange.send()
            SettingsStore.shared.downloadServerArchiveDir = newValue
        }
    }

    // Job completion polling for local notifications
    private var jobPollingTask: Task<Void, Never>?
    private var seenJobIDs: Set<String> = []
    private var seenJobOrder: [String] = []
    private let maxSeenJobs = 200

    // MARK: - Lifecycle

    /// Called during app init. If enabled, verify server is running via health check.
    /// If not healthy but enabled, try to load the plist.
    func startIfNeeded() async {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        cleanupObsoletePlists()
        guard isEnabled else { return }

        // Migrate older plist labels if present
        migrateLegacyPlists()

        let needsReconfigure = isPlistArchiveDirectoryOutOfSync()

        if await healthCheck() {
            if needsReconfigure {
                do {
                    try await reconfigure()
                } catch {
                    logError("Failed to reconfigure download server archive path: \(error.localizedDescription)")
                    isRunning = true
                    refreshLogs()
                    startJobPolling()
                }
            } else {
                isRunning = true
                refreshLogs()
                startJobPolling()
            }
            return
        }

        // Plist exists but server not responding — try loading
        if FileManager.default.fileExists(atPath: Self.plistURL.path) {
            if needsReconfigure {
                do {
                    try await reconfigure()
                    return
                } catch {
                    logError("Failed to reconfigure download server archive path: \(error.localizedDescription). Falling back to existing launchd config.")
                }
            }

            launchctlLoad()
            let healthy = await waitForHealthy(timeout: Self.startupHealthTimeout)
            isRunning = healthy
            if healthy {
                refreshLogs()
                startJobPolling()
            } else {
                stopJobPolling()
            }
        } else {
            // No plist — write and load
            do {
                try enable()
            } catch {
                logError("Failed to start download server: \(error.localizedDescription)")
            }
        }
    }

    private func isPlistArchiveDirectoryOutOfSync() -> Bool {
        guard FileManager.default.fileExists(atPath: Self.plistURL.path) else {
            return false
        }
        guard let plistArchiveDirectory = readPlistArchiveDirectory() else {
            return true
        }
        let expected = URL(fileURLWithPath: archiveDirectory).standardizedFileURL.path
        return plistArchiveDirectory != expected
    }

    private func readPlistArchiveDirectory() -> String? {
        guard let snapshot = LaunchAgentPlistSnapshot(contentsOf: Self.plistURL) else { return nil }
        return snapshot.standardizedArchiveDirectory
    }

    /// Enable the server: resolve binary, write plist, load via launchctl.
    func enable() throws {
        guard !BackgroundQAConfiguration.isEnabled else { throw BackgroundQAConfiguration.ConfigurationError.maintenanceSuppressed }
        cleanupObsoletePlists()
        migrateLegacyPlists()

        let resolved = try resolveBinary()
        let plistData = try generatePlist(binary: resolved)

        // Write plist atomically
        let plistDir = Self.plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: plistDir, withIntermediateDirectories: true)
        try plistData.write(to: Self.plistURL, options: .atomic)

        launchctlLoad()

        Task {
            let healthy = await waitForHealthy(timeout: Self.startupHealthTimeout)
            isRunning = healthy
            if healthy {
                refreshLogs()
                logInfo("Download server enabled on port \(Self.port)")
                startJobPolling()
            } else {
                logWarning("Download server plist loaded but health check failed")
                stopJobPolling()
            }
        }
    }

    /// Disable the server: unload plist, remove file.
    func disable() {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        launchctlUnload()

        try? FileManager.default.removeItem(at: Self.plistURL)
        isRunning = false
        stopJobPolling()
        logInfo("Download server disabled")
    }

    /// Start the service (load existing plist).
    func start() async throws {
        guard !BackgroundQAConfiguration.isEnabled else { throw BackgroundQAConfiguration.ConfigurationError.maintenanceSuppressed }
        cleanupObsoletePlists()
        migrateLegacyPlists()

        guard FileManager.default.fileExists(atPath: Self.plistURL.path) else {
            try enable()
            return
        }
        launchctlLoad()
        let healthy = await waitForHealthy(timeout: Self.startupHealthTimeout)
        isRunning = healthy
        if healthy {
            refreshLogs()
            startJobPolling()
        } else {
            stopJobPolling()
        }
    }

    /// Stop the service (unload but keep plist for next boot).
    func stop() {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        launchctlUnload()
        isRunning = false
        stopJobPolling()
    }

    /// Restart: unload, reload.
    func restart() async throws {
        guard !BackgroundQAConfiguration.isEnabled else { throw BackgroundQAConfiguration.ConfigurationError.maintenanceSuppressed }
        launchctlUnload()
        try await Task.sleep(nanoseconds: 500_000_000)
        try await start()
    }

    /// Reconfigure: regenerate plist with current settings, reload.
    func reconfigure() async throws {
        guard !BackgroundQAConfiguration.isEnabled else { throw BackgroundQAConfiguration.ConfigurationError.maintenanceSuppressed }
        cleanupObsoletePlists()
        migrateLegacyPlists()

        let resolved = try resolveBinary()
        let plistData = try generatePlist(binary: resolved)

        launchctlUnload()
        try plistData.write(to: Self.plistURL, options: .atomic)
        launchctlLoad()

        let healthy = await waitForHealthy(timeout: Self.startupHealthTimeout)
        isRunning = healthy
        if healthy {
            startJobPolling()
        } else {
            stopJobPolling()
        }
    }

    /// Check if the server is responding.
    nonisolated func healthCheck() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Fetch health endpoint JSON and parse uptime + extension readiness fields. Returns nil on failure.
    nonisolated func fetchHealthData() async -> HealthData? {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let uptimeSeconds = json["uptime_seconds"] as? Double
                let extensionStatus = parseExtensionStatus(from: json["extension"])
                return HealthData(
                    uptimeSeconds: uptimeSeconds,
                    extensionStatus: extensionStatus
                )
            }
            // Server responded 200 but no uptime field - still healthy
            return HealthData(uptimeSeconds: nil, extensionStatus: nil)
        } catch {
            return nil
        }
    }

    nonisolated private func parseExtensionStatus(from rawValue: Any?) -> HealthData.ExtensionStatus? {
        guard let json = rawValue as? [String: Any] else { return nil }
        return HealthData.ExtensionStatus(
            seenEver: boolValue(json["seen_ever"]),
            active: boolValue(json["active"]),
            lastSeenAt: json["last_seen_at"] as? String,
            lastSeenSecondsAgo: doubleValue(json["last_seen_seconds_ago"]),
            extensionID: json["extension_id"] as? String,
            extensionVersion: json["extension_version"] as? String,
            browser: json["browser"] as? String
        )
    }

    nonisolated private func boolValue(_ value: Any?) -> Bool {
        if let boolValue = value as? Bool { return boolValue }
        if let number = value as? NSNumber { return number.boolValue }
        if let stringValue = value as? String { return NSString(string: stringValue).boolValue }
        return false
    }

    nonisolated private func doubleValue(_ value: Any?) -> Double? {
        if let doubleValue = value as? Double { return doubleValue }
        if let number = value as? NSNumber { return number.doubleValue }
        if let stringValue = value as? String { return Double(stringValue) }
        return nil
    }

    struct HealthData: Sendable {
        let uptimeSeconds: Double?
        let extensionStatus: ExtensionStatus?

        var extensionSeenEver: Bool {
            extensionStatus?.seenEver ?? false
        }

        struct ExtensionStatus: Sendable {
            let seenEver: Bool
            let active: Bool
            let lastSeenAt: String?
            let lastSeenSecondsAgo: Double?
            let extensionID: String?
            let extensionVersion: String?
            let browser: String?
        }
    }

    struct LaunchAgentPlistSnapshot: Equatable {
        let label: String
        let workingDirectory: String?
        let programArguments: [String]
        let environmentVariables: [String: String]

        init?(contentsOf url: URL) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            self.init(data: data)
        }

        init?(data: Data) {
            guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                return nil
            }
            self.init(dictionary: plist)
        }

        init?(dictionary: [String: Any]) {
            guard let rawLabel = dictionary["Label"] as? String else { return nil }
            let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { return nil }

            let workingDirectory = (dictionary["WorkingDirectory"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let programArguments = (dictionary["ProgramArguments"] as? [Any] ?? []).compactMap { value in
                if let stringValue = value as? String {
                    return stringValue
                }
                if let numberValue = value as? NSNumber {
                    return numberValue.stringValue
                }
                return nil
            }

            let rawEnvironment = dictionary["EnvironmentVariables"] as? [String: Any] ?? [:]
            var environmentVariables: [String: String] = [:]
            for (key, value) in rawEnvironment {
                if let stringValue = value as? String {
                    environmentVariables[key] = stringValue
                } else if let numberValue = value as? NSNumber {
                    environmentVariables[key] = numberValue.stringValue
                }
            }

            self.label = label
            self.workingDirectory = workingDirectory
            self.programArguments = programArguments
            self.environmentVariables = environmentVariables
        }

        var standardizedArchiveDirectory: String? {
            guard let rawValue = environmentVariables["MEDIA_ARCHIVER_DIR"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawValue.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: rawValue).standardizedFileURL.path
        }

        var pointsToLegacyMediaViewerWorkspace: Bool {
            trackedPaths.contains { $0.contains("/media-viewer/") }
        }

        func referencesMissingPaths(fileManager: FileManager = .default) -> Bool {
            trackedPaths.contains { !fileManager.fileExists(atPath: $0) }
        }

        private var trackedPaths: [String] {
            var seen = Set<String>()
            var paths: [String] = []

            func append(_ rawPath: String?) {
                guard let rawPath else { return }
                let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("/") else { return }
                let normalized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
                guard seen.insert(normalized).inserted else { return }
                paths.append(normalized)
            }

            append(workingDirectory)

            for (index, argument) in programArguments.enumerated() {
                let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if trimmed.hasPrefix("/") {
                    append(trimmed)
                    continue
                }

                append(derivedProgramArgumentPath(for: index, argument: trimmed))
            }

            return paths
        }

        private func derivedProgramArgumentPath(for index: Int, argument: String) -> String? {
            guard index > 0,
                  let workingDirectory,
                  !workingDirectory.isEmpty,
                  looksLikeRelativePath(argument) else {
                return nil
            }

            return URL(
                fileURLWithPath: argument,
                relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)
            ).standardizedFileURL.path
        }

        private func looksLikeRelativePath(_ argument: String) -> Bool {
            argument.hasPrefix("./")
                || argument.hasPrefix("../")
                || argument.contains("/")
                || argument.hasSuffix(".py")
        }
    }

    /// Refresh the running status via health check.
    func refreshStatus() async {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        let healthy = await healthCheck()
        isRunning = healthy
        if healthy {
            startJobPolling()
        } else {
            stopJobPolling()
        }
    }

    /// Public access to the log file URL for clearing/reading.
    static var logFileURL: URL { logURL }
    static var errorLogFileURL: URL { errorLogURL }

    // MARK: - Plist Generation

    private enum ResolvedBinary {
        case standalone(URL)
        case python(venvPython: URL, serverDir: URL)
    }

    private func generatePlist(binary: ResolvedBinary, archiveDirectory resolvedArchiveDirectory: String? = nil) throws -> Data {
        let binDir = AppPaths.binDirectory.path

        var programArgs: [String]
        var workingDir: String

        switch binary {
        case .standalone(let url):
            programArgs = [url.path]
            workingDir = AppPaths.downloadServerDirectory.path

        case .python(let python, let serverDir):
            if python.path == "/usr/bin/env" {
                programArgs = ["/usr/bin/env", "python3", "-m", "uvicorn", "main:app",
                               "--host", "127.0.0.1", "--port", "\(Self.port)"]
            } else {
                programArgs = [python.path, "-m", "uvicorn", "main:app",
                               "--host", "127.0.0.1", "--port", "\(Self.port)"]
            }
            workingDir = serverDir.path
        }

        programArgs = delayedLaunchProgramArguments(programArgs)

        var envVars: [String: String] = [
            "MEDIA_ARCHIVER_PORT": "\(Self.port)",
            "MEDIA_ARCHIVER_DIR": resolvedArchiveDirectory ?? archiveDirectory,
            "PATH": DownloadToolSearchPaths.launchdPath
        ]
        if !binDir.isEmpty {
            envVars["MEDIA_ARCHIVER_BIN"] = binDir
        }

        let plist: [String: Any] = [
            "Label": Self.plistLabel,
            "ProgramArguments": programArgs,
            "WorkingDirectory": workingDir,
            "RunAtLoad": true,
            "KeepAlive": [
                "Crashed": true,
                "SuccessfulExit": false
            ],
            "ThrottleInterval": 30,
            "EnvironmentVariables": envVars,
            "StandardOutPath": Self.logURL.path,
            "StandardErrorPath": Self.errorLogURL.path
        ]

        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    func generateStandaloneLaunchAgentPlistForTesting(
        binary: URL,
        archiveDirectory: String
    ) throws -> Data {
        try generatePlist(binary: .standalone(binary), archiveDirectory: archiveDirectory)
    }

    private func delayedLaunchProgramArguments(_ programArguments: [String]) -> [String] {
        guard Self.startupDelaySeconds > 0,
              let executable = programArguments.first else {
            return programArguments
        }

        return [
            "/bin/sh",
            "-c",
            "sleep \(Self.startupDelaySeconds); exec \"$0\" \"$@\"",
            executable
        ] + Array(programArguments.dropFirst())
    }

    // MARK: - Binary Resolution

    private func resolveBinary() throws -> ResolvedBinary {
        if let resolved = DependencyManager.resolveMediaArchiverExecutable() {
            return .standalone(resolved.url)
        }

        #if DEBUG
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workspaceRoot = repoRoot.deletingLastPathComponent()

        // Dev: venv Python fallback
        let serverDirCandidates = [
            workspaceRoot.appendingPathComponent("url-saver/server"),
            repoRoot.appendingPathComponent("server")
        ]
        for serverDir in serverDirCandidates {
            let pythonMain = serverDir.appendingPathComponent("main.py")
            guard FileManager.default.fileExists(atPath: pythonMain.path) else { continue }

            let venvPython = serverDir.appendingPathComponent("venv/bin/python3")
            let python = FileManager.default.isExecutableFile(atPath: venvPython.path)
                ? venvPython
                : URL(fileURLWithPath: "/usr/bin/env")
            return .python(venvPython: python, serverDir: serverDir)
        }
        #endif

        throw DownloadServerError.binaryNotFound
    }

    // MARK: - launchctl

    @discardableResult
    private func launchctl(_ arguments: [String]) -> Int32? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return nil
        }
    }

    private func launchctlLoad() {
        _ = launchctl(["load", Self.plistURL.path])
    }

    private func launchctlUnload() {
        _ = launchctl(["unload", Self.plistURL.path])
    }

    // MARK: - Health Check Polling

    private func startJobPolling() {
        guard jobPollingTask == nil else { return }

        jobPollingTask = Task { [weak self] in
            guard let self else { return }

            await self.primeSeenJobs()

            while !Task.isCancelled {
                await self.pollJobUpdates()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func stopJobPolling() {
        jobPollingTask?.cancel()
        jobPollingTask = nil
        seenJobIDs.removeAll()
        seenJobOrder.removeAll()
    }

    private func primeSeenJobs() async {
        let completed = await fetchJobs(status: "completed", limit: 5)
        let failed = await fetchJobs(status: "failed", limit: 5)

        for job in completed + failed {
            if let id = job["id"] as? String {
                markJobSeen(id)
            }
        }
    }

    private func pollJobUpdates() async {
        let completed = await fetchJobs(status: "completed", limit: 5)
        handleJobUpdates(completed, status: "completed")

        let failed = await fetchJobs(status: "failed", limit: 5)
        handleJobUpdates(failed, status: "failed")
    }

    private func handleJobUpdates(_ jobs: [[String: Any]], status: String) {
        for job in jobs.reversed() {
            guard let id = job["id"] as? String else { continue }
            guard !seenJobIDs.contains(id) else { continue }

            markJobSeen(id)

            let title = notificationTitle(from: job)
            if status == "completed" {
                let url: URL? = {
                    guard let urlString = job["url"] as? String else { return nil }
                    return URL(string: urlString)
                }()

                NotificationService.shared.showDownloadComplete(
                    title: title,
                    url: url,
                    itemCount: notificationItemCount(from: job)
                )
            } else if status == "failed" {
                NotificationService.shared.showDownloadFailed(
                    title: title,
                    error: notificationError(from: job)
                )
            }
        }
    }

    private func markJobSeen(_ id: String) {
        seenJobIDs.insert(id)
        seenJobOrder.append(id)

        while seenJobOrder.count > maxSeenJobs {
            let removed = seenJobOrder.removeFirst()
            seenJobIDs.remove(removed)
        }
    }

    private func notificationTitle(from job: [String: Any]) -> String {
        if let title = job["page_title"] as? String, !title.isEmpty {
            return title
        }
        if let metadata = job["metadata"] as? [String: Any],
           let title = metadata["title"] as? String,
           !title.isEmpty {
            return title
        }
        if let urlString = job["url"] as? String,
           let url = URL(string: urlString),
           let host = url.host,
           !host.isEmpty {
            return host
        }
        return "Media download"
    }

    private func notificationItemCount(from job: [String: Any]) -> Int? {
        guard let metadata = job["metadata"] as? [String: Any] else { return nil }
        if let count = metadata["media_count"] as? Int {
            return count
        }
        if let count = metadata["media_count"] as? Double {
            return Int(count)
        }
        return nil
    }

    private func notificationError(from job: [String: Any]) -> String {
        if let error = job["error"] as? String, !error.isEmpty {
            return error
        }
        if let metadata = job["metadata"] as? [String: Any],
           let errorCategory = metadata["error_category"] as? String,
           !errorCategory.isEmpty {
            return errorCategory
        }
        return "Unknown error"
    }

    nonisolated private func fetchJobs(status: String, limit: Int) async -> [[String: Any]] {
        guard let encodedStatus = status.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "http://127.0.0.1:\(Self.port)/jobs?status=\(encodedStatus)&limit=\(limit)") else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let jobs = json["jobs"] as? [[String: Any]] else {
                return []
            }
            return jobs
        } catch {
            return []
        }
    }

    private func waitForHealthy(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await healthCheck() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    // MARK: - Log Reading

    /// Read last 200 lines from the launchd log file.
    func refreshLogs() {
        guard FileManager.default.fileExists(atPath: Self.logURL.path) else {
            lastLog = ["No log file yet"]
            return
        }

        // Read last ~32KB of the log file (seek to tail)
        do {
            let handle = try FileHandle(forReadingFrom: Self.logURL)
            defer { handle.closeFile() }

            let fileSize = handle.seekToEndOfFile()
            let readSize: UInt64 = min(fileSize, 32 * 1024)
            handle.seek(toFileOffset: fileSize - readSize)

            let data = handle.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8) {
                let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                lastLog = Array(lines.suffix(200))
            }
        } catch {
            lastLog = ["Error reading log: \(error.localizedDescription)"]
        }
    }

    // MARK: - Migration

    private func cleanupObsoletePlists() {
        for obsoleteLabel in Self.obsoletePlistLabels {
            handleLegacyPlist(label: obsoleteLabel, alwaysArchive: true)
        }
    }

    /// Detect and unload older plist labels so the current label can take over cleanly.
    private func migrateLegacyPlists() {
        for legacyLabel in Self.legacyPlistLabels {
            handleLegacyPlist(label: legacyLabel, alwaysArchive: false)
        }
    }

    private func handleLegacyPlist(label: String, alwaysArchive: Bool) {
        let legacyPath = Self.launchAgentURL(for: label)
        guard FileManager.default.fileExists(atPath: legacyPath.path) else { return }

        let snapshot = LaunchAgentPlistSnapshot(contentsOf: legacyPath)
        logInfo("Found legacy plist \(label), migrating...")

        _ = launchctl(["unload", legacyPath.path])

        guard alwaysArchive || shouldArchiveLegacyPlist(snapshot) else {
            logInfo("Legacy server plist unloaded. Old plist kept at \(legacyPath.path)")
            return
        }

        do {
            let archivedPath = try archiveLegacyPlist(at: legacyPath, label: label)
            logInfo("Legacy server plist archived at \(archivedPath.path)")
        } catch {
            logWarning("Failed to archive legacy plist \(label): \(error.localizedDescription)")
        }
    }

    private func shouldArchiveLegacyPlist(_ snapshot: LaunchAgentPlistSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.pointsToLegacyMediaViewerWorkspace || snapshot.referencesMissingPaths()
    }

    private func archiveLegacyPlist(at legacyPath: URL, label: String) throws -> URL {
        let fm = FileManager.default
        let archiveDir = Self.legacyPlistArchiveDirectory
        try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let timestamp = Self.legacyArchiveTimestamp()
        var destination = archiveDir
            .appendingPathComponent("\(label)-\(timestamp)", isDirectory: false)
            .appendingPathExtension("plist")
        var suffix = 1

        while fm.fileExists(atPath: destination.path) {
            destination = archiveDir
                .appendingPathComponent("\(label)-\(timestamp)-\(suffix)", isDirectory: false)
                .appendingPathExtension("plist")
            suffix += 1
        }

        try fm.moveItem(at: legacyPath, to: destination)
        return destination
    }

    private static func legacyArchiveTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - Errors

enum DownloadServerError: Error, LocalizedError {
    case binaryNotFound
    case plistWriteFailed

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Download server not installed. Use the Dependencies section to install it."
        case .plistWriteFailed:
            return "Failed to write server configuration."
        }
    }
}
