import SwiftUI
import AppKit

// MARK: - Settings Theme

private enum SettingsTheme {
    static let sidebarBackground = Color(hex: 0x1a1a1a)
    static let contentBackground = Color(hex: 0x1e1e1e)
    static let cardBackground = Color(hex: 0x252525)
    static let divider = Color.white.opacity(0.08)
    static let cardBorder = Color.white.opacity(0.06)
}

struct SettingsRootView: View {
    @State private var selectedTab: SettingsTab?

    init(initialTab: SettingsTab = .general) {
        _selectedTab = State(initialValue: initialTab)
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case library = "Library"
        case downloads = "Downloads"
        case playback = "Playback"
        case organization = "Organization"
        case processing = "Processing"
        case advanced = "Advanced"

        var id: Self { self }

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .library: return "photo.on.rectangle.fill"
            case .downloads: return "arrow.down.circle.fill"
            case .playback: return "play.rectangle.fill"
            case .organization: return "tag.fill"
            case .processing: return "cpu.fill"
            case .advanced: return "wrench.and.screwdriver.fill"
            }
        }

        var accentColor: Color {
            switch self {
            case .general: return .gray
            case .library: return .blue
            case .downloads: return .green
            case .playback: return .teal
            case .organization: return Color.accentOrange
            case .processing: return .purple
            case .advanced: return .red
            }
        }
    }

    var body: some View {
        HSplitView {
            // Sidebar
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    SettingsTabRow(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        action: { selectedTab = tab }
                    )
                }
                Spacer()
            }
            .padding(12)
            .frame(minWidth: 170, maxWidth: 220)
            .background(SettingsTheme.sidebarBackground)

            // Content
            Group {
                switch selectedTab ?? .general {
                case .general:
                    GeneralSettingsTab()
                case .library:
                    LibrarySettingsTab()
                case .downloads:
                    DownloadsSettingsTab()
                case .playback:
                    PlaybackSettingsTab()
                case .organization:
                    OrganizationSettingsTab()
                case .processing:
                    ProcessingSettingsTab()
                case .advanced:
                    AdvancedSettingsTab()
                }
            }
            .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(SettingsTheme.contentBackground)
        }
        .frame(
            minWidth: 840,
            idealWidth: 1020,
            maxWidth: .infinity,
            minHeight: 680,
            idealHeight: 860,
            maxHeight: .infinity
        )
        .background(SettingsWindowResizableHelper())
        .preferredColorScheme(.dark)
    }
}

// MARK: - Settings Tab Row

private struct SettingsTabRow: View {
    let tab: SettingsRootView.SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? tab.accentColor : .secondary)
                    .frame(width: 20)

                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : .secondary)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? tab.accentColor.opacity(0.15) : (isHovered ? Color.white.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? tab.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// NSViewRepresentable that injects .resizable into the Settings window's styleMask.
/// SwiftUI's Settings scene creates non-resizable windows by default — this fixes that.
private struct SettingsWindowResizableHelper: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.styleMask.insert(.resizable)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window, !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
    }
}
