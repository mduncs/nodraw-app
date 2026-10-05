import SwiftUI
import AppKit

struct DownloadsSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var serverManager = DownloadServerManager.shared

    @State private var toolStatuses: [DependencyManager.ToolStatus] = []
    @State private var isCheckingTools = false
    @State private var isInstalling = false
    @State private var installProgress: (tool: String, fraction: Double)?
    @State private var userMessage: String?
    @State private var userMessageIsError = false
    @State private var uptime: TimeInterval = 0
    @State private var extensionStatus: DownloadServerManager.HealthData.ExtensionStatus?

    private var missingTools: [DependencyManager.ToolStatus] {
        toolStatuses.filter { !$0.installed }
    }

    private var missingInstallableTools: [DependencyManager.ToolStatus] {
        missingTools.filter(\.installable)
    }

    private var allToolsInstalled: Bool {
        !toolStatuses.isEmpty && missingTools.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSection(
                    title: "Download Server",
                    icon: "arrow.down.circle",
                    description: "Optional local server that saves pages from the NoDraw browser extension (Firefox or Chrome)."
                ) {
                    serverControls
                }

                SettingsSection(
                    title: "Download Tools",
                    icon: "shippingbox",
                    description: "Standalone tools used by the local server."
                ) {
                    dependenciesControls
                }

                if serverManager.isEnabled {
                    SettingsSection(
                        title: "Server Logs",
                        icon: "doc.text",
                        description: "Recent launchd output from the local server."
                    ) {
                        logsControls
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await refreshAll()
        }
        .task(id: serverManager.isRunning) {
            guard serverManager.isRunning else {
                uptime = 0
                extensionStatus = nil
                return
            }

            while !Task.isCancelled && serverManager.isRunning {
                await refreshServerHealthSnapshot()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var serverControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsToggle(
                "Enable download server",
                description: "Creates a launchd background service when started. Installing the browser extension stays manual.",
                isOn: Binding(
                    get: { serverManager.isEnabled },
                    set: { newValue in
                        userMessage = nil
                        if newValue {
                            serverManager.isEnabled = true
                        } else {
                            serverManager.isEnabled = false
                            serverManager.disable()
                        }
                    }
                )
            )

            if serverManager.isEnabled {
                SettingsDividerLine()

                settingRow(
                    title: "Archive folder",
                    detail: "\(abbreviatedPath(serverManager.archiveDirectory)) · also the library's archive",
                    buttonTitle: "Choose…",
                    action: chooseArchiveDirectory
                )
                .disabled(BackgroundQAConfiguration.isEnabled)

                SettingsDividerLine()

                statusRow(
                    title: serverManager.isRunning ? "Server running" : "Server stopped",
                    detail: serverStatusDetail,
                    icon: serverManager.isRunning ? "checkmark.circle.fill" : "xmark.circle",
                    color: serverManager.isRunning ? .green : .red
                ) {
                    HStack(spacing: 8) {
                        Button("Refresh") {
                            Task { await refreshServerStatus() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if serverManager.isRunning {
                            Button("Restart") {
                                restartServer()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Stop") {
                                serverManager.stop()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Button("Start") {
                                startServer()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.accentOrange)
                            .controlSize(.small)
                            .disabled(!allToolsInstalled || isInstalling)
                            .help(allToolsInstalled ? "Start the local download server" : unavailableToolsHelpText)
                        }
                    }
                }

                statusRow(
                    title: "Browser extension",
                    detail: extensionStatusText,
                    icon: extensionStatus?.seenEver == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    color: extensionStatus?.seenEver == true ? .green : .orange
                )

                if let userMessage {
                    messageRow(userMessage, isError: userMessageIsError)
                }
            } else {
                Text("Downloads are disabled. Your local library, imports, browsing, search, and tagging still work.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dependenciesControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow(
                title: dependencySummaryTitle,
                detail: dependencySummaryDetail,
                icon: allToolsInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                color: allToolsInstalled ? .green : .orange
            )

            SettingsDividerLine()

            if isCheckingTools && toolStatuses.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking installed tools…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(toolStatuses) { status in
                        toolRow(status)
                    }
                }
            }

            if let progress = installProgress {
                HStack(spacing: 10) {
                    Text("Installing \(progress.tool)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress.fraction)
                        .frame(width: 120)
                }
            }

            HStack(spacing: 8) {
                Spacer()

                Button("Refresh") {
                    Task { await refreshToolStatus() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isCheckingTools || isInstalling)

                Button(isInstalling ? "Installing…" : "Install Missing") {
                    installMissingTools()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentOrange)
                .controlSize(.small)
                .disabled(isInstalling || missingInstallableTools.isEmpty)
            }
        }
    }

    private var logsControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Spacer()

                Button("Refresh") {
                    serverManager.refreshLogs()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button("Copy") {
                    let text = serverManager.lastLog.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(serverManager.lastLog.isEmpty)

                Button("Clear") {
                    clearLogs()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if serverManager.lastLog.isEmpty {
                        Text("No log output yet")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(Array(serverManager.lastLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(lineContainsError(line) ? .red : .secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private func toolRow(_ status: DependencyManager.ToolStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: status.installed ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 13))
                .foregroundStyle(status.installed ? Color.green : Color.red)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                Text(toolDetail(for: status))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !status.installed && status.installable {
                Button("Install") {
                    installTool(status.name)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isInstalling)
            }
        }
    }

    private func settingRow(title: String, detail: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private func statusRow<Actions: View>(
        title: String,
        detail: String,
        icon: String,
        color: Color,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            actions()
        }
    }

    private func statusRow(title: String, detail: String, icon: String, color: Color) -> some View {
        statusRow(title: title, detail: detail, icon: icon, color: color) {
            EmptyView()
        }
    }

    private func messageRow(_ message: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "xmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(isError ? Color.red : Color.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(isError ? Color.red : Color.orange)
            Spacer()
        }
    }

    private var dependencySummaryTitle: String {
        if toolStatuses.isEmpty {
            return "Tool status unknown"
        }
        if allToolsInstalled {
            return "All download tools available"
        }
        return "\(missingTools.count) download tool\(missingTools.count == 1 ? "" : "s") not found"
    }

    private var dependencySummaryDetail: String {
        let installPath = abbreviatedPath(AppPaths.binDirectory.path)
        if serverManager.isEnabled {
            return "Checks bundled tools, app support, server Python packages, and launchd PATH. App-installed downloads go under \(installPath)."
        }
        return "Download server is disabled; these tools only affect web saves. App-installed downloads go under \(installPath)."
    }

    private var serverStatusDetail: String {
        guard serverManager.isRunning else {
            if allToolsInstalled {
                return "Ready to start on port \(DownloadServerManager.port)"
            }
            return unavailableToolsHelpText
        }

        if uptime > 0 {
            return "Port \(DownloadServerManager.port), uptime \(formattedUptime)"
        }
        return "Running on port \(DownloadServerManager.port)"
    }

    private var extensionStatusText: String {
        guard serverManager.isRunning else {
            return "Start the server, then open Firefox or Chrome with the NoDraw extension enabled"
        }
        guard let extensionStatus else {
            return "No heartbeat received yet"
        }

        if extensionStatus.seenEver {
            if extensionStatus.active, let secondsAgo = extensionStatus.lastSeenSecondsAgo {
                return "Connected \(Self.relativeAge(secondsAgo))"
            }
            if let secondsAgo = extensionStatus.lastSeenSecondsAgo {
                return "Last seen \(Self.relativeAge(secondsAgo))"
            }
            return "Detected"
        }

        return "No heartbeat received yet"
    }

    /// "just now", "42s ago", "5m ago", "3h ago", "2d ago".
    static func relativeAge(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        switch total {
        case ..<5: return "just now"
        case ..<60: return "\(total)s ago"
        case ..<3600: return "\(total / 60)m ago"
        case ..<86_400: return "\(total / 3600)h ago"
        default: return "\(total / 86_400)d ago"
        }
    }

    private var formattedUptime: String {
        let total = Int(uptime)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "\(total)s"
    }

    private var unavailableToolsHelpText: String {
        if missingInstallableTools.isEmpty {
            return "Resolve unavailable download runtime components before starting"
        }
        return "Install missing download tools before starting"
    }

    private func toolDetail(for status: DependencyManager.ToolStatus) -> String {
        let state: String
        if status.installed {
            let versionText = status.version.map { "Available: \($0)" } ?? "Available"
            let sourceText = status.sourceDescription.map { " via \($0)" } ?? ""
            let pathText = status.binaryPath.map { " at \(abbreviatedPath($0.path))" } ?? ""
            state = "\(versionText)\(sourceText)\(pathText)"
        } else {
            state = status.installable
                ? "Not found in app support, app bundle, server Python, or launchd PATH"
                : "Not found in the active download server runtime"
        }

        switch status.name {
        case "media-archiver":
            return "\(state). Runs the local download server."
        case "yt-dlp":
            return "\(state). Handles YouTube, video posts, and broad site fallback."
        case "gallery-dl":
            return "\(state). Handles galleries and image-heavy sites."
        case "ffmpeg":
            return "\(state). Supports video/audio post-processing."
        case "dezoomify-rs":
            return "\(state). Supports deep-zoom museum and archive images."
        default:
            return state
        }
    }

    private func refreshAll() async {
        await refreshToolStatus()
        await refreshServerStatus()
        serverManager.refreshLogs()
    }

    private func refreshToolStatus() async {
        guard !isCheckingTools else { return }
        isCheckingTools = true
        toolStatuses = await DependencyManager.shared.checkAll()
        isCheckingTools = false
    }

    private func refreshServerStatus() async {
        await serverManager.refreshStatus()
        await refreshServerHealthSnapshot()
    }

    private func refreshServerHealthSnapshot() async {
        guard let healthData = await serverManager.fetchHealthData() else {
            uptime = 0
            extensionStatus = nil
            return
        }

        uptime = healthData.uptimeSeconds ?? 0
        extensionStatus = healthData.extensionStatus
    }

    private func chooseArchiveDirectory() {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        let panel = NSOpenPanel()
        panel.title = "Select Archive Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = ArchivePathStore.currentPath()

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let normalizedURL = url.standardizedFileURL
        serverManager.archiveDirectory = normalizedURL.path
        Task {
            await appState.updateArchivePath(normalizedURL)
            if serverManager.isRunning {
                try? await serverManager.reconfigure()
                await refreshServerStatus()
            }
        }
    }

    private func installTool(_ name: String) {
        guard !isInstalling else { return }
        isInstalling = true
        userMessage = nil
        installProgress = (name, 0)

        Task {
            do {
                try await DependencyManager.shared.install(name) { fraction in
                    Task { @MainActor in
                        installProgress = (name, fraction)
                    }
                }
                userMessage = "Installed \(name)."
                userMessageIsError = false
            } catch {
                userMessage = "Failed to install \(name): \(error.localizedDescription)"
                userMessageIsError = true
                logError("Failed to install \(name): \(error.localizedDescription)")
            }

            installProgress = nil
            isInstalling = false
            await refreshToolStatus()
        }
    }

    private func installMissingTools() {
        guard !isInstalling else { return }
        isInstalling = true
        userMessage = nil

        Task {
            let statuses = await DependencyManager.shared.checkAll()
            let missing = statuses.filter { !$0.installed && $0.installable }
            var failures: [String] = []

            for status in missing {
                installProgress = (status.name, 0)
                do {
                    try await DependencyManager.shared.install(status.name) { fraction in
                        Task { @MainActor in
                            installProgress = (status.name, fraction)
                        }
                    }
                } catch {
                    failures.append(status.name)
                    logError("Failed to install \(status.name): \(error.localizedDescription)")
                }
            }

            installProgress = nil
            isInstalling = false
            await refreshToolStatus()

            if failures.isEmpty {
                userMessage = missing.isEmpty ? "All download tools are already installed." : "Installed missing download tools."
                userMessageIsError = false
            } else {
                userMessage = "Failed to install: \(failures.joined(separator: ", ")). Existing binaries were preserved."
                userMessageIsError = true
            }
        }
    }

    private func startServer() {
        userMessage = nil

        guard allToolsInstalled else {
            userMessage = unavailableToolsHelpText
            userMessageIsError = true
            return
        }

        Task {
            do {
                serverManager.isEnabled = true
                try serverManager.enable()
                try? await Task.sleep(for: .seconds(2))
                await refreshServerStatus()

                if serverManager.isRunning {
                    userMessage = "Download server started."
                    userMessageIsError = false
                } else {
                    userMessage = "Server configuration was written, but the health check did not pass. Check Server Logs."
                    userMessageIsError = true
                }
            } catch {
                userMessage = error.localizedDescription
                userMessageIsError = true
            }
        }
    }

    private func restartServer() {
        userMessage = nil

        Task {
            do {
                try await serverManager.restart()
                await refreshServerStatus()
            } catch {
                userMessage = error.localizedDescription
                userMessageIsError = true
            }
        }
    }

    private func clearLogs() {
        FileManager.default.createFile(atPath: DownloadServerManager.logFileURL.path, contents: Data())
        FileManager.default.createFile(atPath: DownloadServerManager.errorLogFileURL.path, contents: Data())
        serverManager.refreshLogs()
    }

    private func lineContainsError(_ line: String) -> Bool {
        line.range(of: "error", options: .caseInsensitive) != nil
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

private struct SettingsDividerLine: View {
    var body: some View {
        Divider()
            .background(Color.white.opacity(0.08))
    }
}
