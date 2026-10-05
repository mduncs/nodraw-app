import SwiftUI

// MARK: - AnnotationModeToggle

/// Button to toggle annotation mode on/off
struct AnnotationModeToggle: View {
    @Binding var isActive: Bool
    var hasAnnotations: Bool = false

    @State private var isHovered = false

    var body: some View {
        Button(action: { isActive.toggle() }) {
            HStack(spacing: 6) {
                Image(systemName: isActive ? "pencil.slash" : "pencil.tip.crop.circle")
                    .font(.body)
                    .overlay(alignment: .topTrailing) {
                        // Indicator dot for existing annotations, pinned to the icon rather than the label
                        if hasAnnotations && !isActive {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                                .offset(x: 3, y: -3)
                        }
                    }

                if !isActive {
                    Text("Edit image")
                        .font(.subheadline.weight(.medium))
                }
            }
            .foregroundStyle(isActive ? Color.accentColor : (isHovered ? .primary : .secondary))
            .padding(.horizontal, isActive ? 8 : 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.15) : (isHovered ? Color.white.opacity(0.1) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .keyboardShortcut("\\", modifiers: .command)
        .help(isActive ? "Exit image editor (Esc or ⌘\\)" : helpText)
        .accessibilityLabel(isActive ? "Exit image editor" : "Open image editor")
        .accessibilityIdentifier("annotation-mode-toggle")
        .accessibilityValue(isActive ? "active" : (hasAnnotations ? "has annotations" : ""))
    }

    /// Contrasts with the in-place File tools: edits live in layers and the source file is never rewritten.
    private var helpText: String {
        "Edit image nondestructively; the original file stays untouched (A or ⌘\\)"
            + (hasAnnotations ? " · has saved edits" : "")
    }
}
