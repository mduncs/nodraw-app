import SwiftUI

/// One tag rendered as a compact capsule: colour dot (or state symbol), a single
/// truncating line, and an optional remove button. Shared by the tag surfaces so a
/// tag reads the same in the tagging HUD, rules, import presets and pickers.
struct TagChip: View {
    enum Size {
        case small, regular

        var font: Font { self == .small ? .caption2 : .caption }
        var dot: CGFloat { self == .small ? 6 : 8 }
        var horizontalPadding: CGFloat { self == .small ? 6 : 8 }
        var verticalPadding: CGFloat { self == .small ? 2 : 3 }
    }

    let name: String
    var size: Size = .regular
    /// Replaces the colour dot, e.g. a staged add/remove state.
    var symbol: String? = nil
    /// Overrides the tag's own colour (red for a staged removal).
    var tint: Color? = nil
    var isStruckThrough = false
    var isEmphasized = false
    var maxWidth: CGFloat = 200
    var onRemove: (() -> Void)? = nil

    private var color: Color { tint ?? TagSettings.shared.colorOnly(for: name) }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size.dot + 1, weight: .bold))
                    .foregroundStyle(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: size.dot, height: size.dot)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
            }
            Text(name)
                .font(isEmphasized ? size.font.weight(.semibold) : size.font)
                .strikethrough(isStruckThrough)
                .lineLimit(1)
                .truncationMode(.middle)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: size.dot, weight: .bold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Remove \(name)")
                .accessibilityLabel("Remove \(name)")
            }
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, size.horizontalPadding)
        .padding(.vertical, size.verticalPadding)
        .background(Capsule().fill(color.opacity(0.2)))
        .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
        .help(TagSettings.shared.fullPath(ofTagNamed: name) ?? name)
    }
}
