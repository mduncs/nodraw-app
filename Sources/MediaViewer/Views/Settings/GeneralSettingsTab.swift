import SwiftUI
import ServiceManagement

struct GeneralSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @Environment(SettingsStore.self) private var settings

    /// Reason the last launch-at-login change did not take effect, if any.
    @State private var loginItemError: String?
    @State private var loginItemStatus: SMAppService.Status = SMAppService.mainApp.status

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSection(
                    title: "Library View",
                    icon: "rectangle.3.group",
                    description: "These change the open library right away and are remembered between launches."
                ) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Sort")
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                            Text("Same as the sort menu in the library toolbar.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Routed like the toolbar menu so Back history stays consistent.
                        Picker("", selection: Binding(
                            get: { appState.sortOrder },
                            set: { order in
                                appState.commitLibraryFilterChange { appState.sortOrder = order }
                            }
                        )) {
                            ForEach(SortOrder.allCases, id: \.self) { order in
                                Text(order.displayName).tag(order)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 170)
                    }

                    SettingsSlider(
                        "Grid density",
                        description: "Lower shows more, smaller items; higher shows larger previews. Same as ⌘− / ⌘+.",
                        value: Binding(
                            get: { Double(appState.gridDensity) * 100 },
                            set: { appState.gridDensity = CGFloat($0 / 100) }
                        ),
                        in: 0...100,
                        format: "%.0f%%"
                    )
                }

                SettingsSection(
                    title: "Deleting Items",
                    icon: "trash",
                    description: "Deleted items go to Recently Deleted in the sidebar, where they can be restored."
                ) {
                    SettingsToggle(
                        "Also move media files to Trash",
                        description: settings.deleteFilesFromDisk
                            ? "On: the item's media files also go to the macOS Trash when it is deleted."
                            : "Off: deleting only removes the item from the library; its files stay on disk.",
                        isOn: Binding(
                            get: { settings.deleteFilesFromDisk },
                            set: { settings.deleteFilesFromDisk = $0 }
                        )
                    )

                    SettingsToggle(
                        "Confirm before deleting",
                        description: "Applies to the Delete key and focus view. Grid and table context-menu deletes always ask.",
                        isOn: Binding(
                            get: { !settings.skipDeleteConfirmation },
                            set: { settings.skipDeleteConfirmation = !$0 }
                        )
                    )
                }

                SettingsSection(
                    title: "Startup",
                    icon: "power",
                    description: "Registered with macOS as a login item."
                ) {
                    SettingsToggle(
                        "Launch at login",
                        description: "Start NoDraw automatically when you sign in.",
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { setLaunchAtLogin($0) }
                        )
                    )

                    if let loginItemError {
                        Label(loginItemError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if loginItemStatus == .requiresApproval {
                        HStack(spacing: 8) {
                            Label("macOS needs your approval before NoDraw can open at login.", systemImage: "hand.raised")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Open Login Items…") {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { loginItemStatus = SMAppService.mainApp.status }
    }

    /// Register first, then store the preference, so the toggle never claims a
    /// state macOS rejected.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            let status = SMAppService.mainApp.status
            if enabled {
                try SMAppService.mainApp.register()
            } else if status == .enabled || status == .requiresApproval {
                // Unregistering an item macOS never registered throws; nothing to undo then.
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't \(enabled ? "turn on" : "turn off") launch at login: \(error.localizedDescription)"
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        loginItemStatus = SMAppService.mainApp.status
    }
}
