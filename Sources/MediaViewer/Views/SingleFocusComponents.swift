import SwiftUI

// MARK: - BackButton

/// Back button with proper hit target (44pt min) and hover/press feedback.
struct BackButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.medium))
                Text("Back")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isPressed ? .primary : (isHovered ? .primary : .secondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
            )
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityLabel("Back")
        .accessibilityHint("Close detail view and return to grid")
    }
}

// MARK: - FolderPositionIndicator

/// Compact position indicator for the subset of current results in this folder.
/// Labels the scope so it cannot be mistaken for the active search-result position.
struct FolderPositionIndicator: View {
    let folderName: String
    let position: (index: Int, total: Int)?
    let onPrev: () -> Void
    let onNext: () -> Void

    private var canGoPrev: Bool {
        guard let pos = position else { return false }
        return pos.index > 1
    }

    private var canGoNext: Bool {
        guard let pos = position else { return false }
        return pos.index < pos.total
    }

    var body: some View {
        HStack(spacing: 6) {
            // Prev button
            Button(action: onPrev) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(canGoPrev ? Color.secondary : Color.secondary.opacity(0.3))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoPrev)
            .help("\(AppCommandCatalog.previousInFolder.help) (\(folderName))")
            .accessibilityLabel(AppCommandCatalog.previousInFolder.title)

            // Position display
            if let pos = position {
                HStack(spacing: 4) {
                    Text("Folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(pos.index)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Color.accentOrange)
                    Text("of")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(pos.total)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Folder result \(pos.index) of \(pos.total) in \(folderName)")
            }

            // Next button
            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(canGoNext ? Color.secondary : Color.secondary.opacity(0.3))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoNext)
            .help("\(AppCommandCatalog.nextInFolder.help) (\(folderName))")
            .accessibilityLabel(AppCommandCatalog.nextInFolder.title)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.04))
        )
    }
}

// MARK: - Focus Toolbar Controls

struct FocusToolbarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var isActive: Bool = false
    var activeColor: Color = .accentColor
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? activeColor : (isHovered ? .primary : .secondary))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? activeColor.opacity(0.14) : (isHovered ? Color.white.opacity(0.1) : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityLabel(accessibilityLabel)
    }
}

struct SubImagePositionBadge: View {
    let index: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("\(index)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.accentOrange)
            Text("of")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(total)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Media \(index) of \(total)")
    }
}

// MARK: - ShortcutsHelpOverlay

/// Modal overlay showing keyboard shortcuts for focus view.
/// Dismissed by clicking outside, pressing Escape, or pressing ? again.
struct ShortcutsHelpOverlay: View {
    @Binding var isPresented: Bool

    private var entries: [CommandReferenceEntry] {
        AppCommandCatalog.focusHelpEntries
    }

    var body: some View {
        ZStack {
            // Dim background - tap to dismiss
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            // Shortcuts panel
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                    Button { isPresented = false } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .background(Color.white.opacity(0.2))

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        HStack {
                            Text(entry.input)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .foregroundStyle(Color.accentOrange)
                                .frame(width: 108, alignment: .leading)
                            Text(entry.title)
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
            }
            .padding(24)
            .frame(width: 430)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: 0x2a2a2a))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
            )
        }
        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
    }
}
