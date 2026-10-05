import SwiftUI
import AppKit
import GRDB

@MainActor
final class AboutPanelController {
    static let shared = AboutPanelController()

    private var panel: NSPanel?

    private init() { }

    func show() {
        if let panel {
            present(panel)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "About NoDraw"
        panel.isReleasedWhenClosed = false
        // Match the app's dark workbench regardless of the system appearance.
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: AboutView())
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.center()

        self.panel = panel
        present(panel)
    }

    /// Isolated background QA must never take focus from the user's frontmost app.
    private func present(_ panel: NSPanel) {
        if BackgroundQAConfiguration.usesNonactivatingWindows {
            panel.orderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

struct AboutView: View {
    @State private var itemCountText: String = "Loading…"
    @State private var deletedCountText: String = "Loading…"
    @State private var databaseSizeText: String = "Loading…"

    private let dependencies = [
        "GRDB",
        "Yams",
        "SubjectIsolation",
        "PhotoPipeline",
        "DataTable"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)

                VStack(alignment: .leading, spacing: 4) {
                    Text("NoDraw")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("A fast, keyboard-first viewer for your local media archive.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Version \(BuildInfo.versionDisplay) · built \(buildDateText)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            section("library") {
                row("Items", itemCountText)
                row("Recently Deleted", deletedCountText)
                row("Database", databaseSizeText)
                row("Archive", abbreviatedPath(ArchivePathStore.currentPath().path), monospaced: true)
            }

            section("system") {
                row("macOS", osVersionString)
                row("Built with", dependencies.joined(separator: " · "))
            }
        }
        .padding(20)
        .frame(width: 460, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(hex: 0x1e1e1e))
        .preferredColorScheme(.dark)
        .task {
            await refreshDatabaseInfo()
        }
    }

    /// Lowercase section labels match the app's metadata panel.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 5) { content() }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .system(size: 12).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var buildDateText: String {
        guard let date = ISO8601DateFormatter().date(from: BuildInfo.buildDate) else { return BuildInfo.buildDate }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private var osVersionString: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private func refreshDatabaseInfo() async {
        do {
            // Same active/deleted split as the sidebar: Recently Deleted is not in the library count.
            let counts = try await DatabaseManager.shared.read { db -> (Int, Int) in
                let active = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE (deletedAt IS NULL OR deletedAt = '')") ?? 0
                let deleted = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_items WHERE deletedAt IS NOT NULL AND deletedAt != ''") ?? 0
                return (active, deleted)
            }
            itemCountText = counts.0.formatted()
            deletedCountText = counts.1.formatted()
        } catch {
            itemCountText = "Unavailable"
            deletedCountText = "Unavailable"
        }

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: AppPaths.databaseURL.path)
            if let fileSize = attributes[.size] as? NSNumber {
                databaseSizeText = ByteCountFormatter.string(
                    fromByteCount: fileSize.int64Value,
                    countStyle: .file
                )
            } else {
                databaseSizeText = "Unknown"
            }
        } catch {
            databaseSizeText = "Not found"
        }
    }
}
