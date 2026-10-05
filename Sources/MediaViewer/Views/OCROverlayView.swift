import SwiftUI
import AppKit
import PhotoPipeline

// MARK: - OCROverlayView

/// Overlay view that displays bounding boxes for detected OCR text blocks.
/// Renders block-level (paragraph) groups with hover/select interaction.
struct OCROverlayView: View {
    @Binding var blocks: [SerializableTextBlock]
    let imageSize: CGSize  // Image dimensions in PIXELS (Vision API uses pixel coordinates)
    let displaySize: CGSize  // Current display size of the image (in points)

    @Binding var hoveredBlock: SerializableTextBlock?
    @Binding var selectedBlock: SerializableTextBlock?

    @State private var copiedBlockId: String?

    var body: some View {
        GeometryReader { geometry in
            let scaleX = displaySize.width / imageSize.width
            let scaleY = displaySize.height / imageSize.height
            let centerX = displaySize.width / 2
            let centerY = displaySize.height / 2

            // NOTE: Using .offset() instead of .position() because .position()
            // expands each child's frame to fill the parent, breaking hit-testing.
            // With .offset(), each block keeps its actual frame size so onHover/
            // onTapGesture only fire for the correct block under the cursor.
            ZStack {
                ForEach(blocks) { block in
                    let blockRect = block.swiftUIRect(imageSize: imageSize)
                    let displayBlockRect = CGRect(
                        x: blockRect.origin.x * scaleX,
                        y: blockRect.origin.y * scaleY,
                        width: blockRect.width * scaleX,
                        height: blockRect.height * scaleY
                    )
                    let blockW = displayBlockRect.width + 4
                    let blockH = displayBlockRect.height + 2

                    let isBlockHovered = hoveredBlock?.id == block.id
                    let isBlockSelected = selectedBlock?.id == block.id
                    let justCopied = copiedBlockId == block.id

                    RoundedRectangle(cornerRadius: 3)
                        .fill(blockFillColor(block))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(blockStrokeColor(block), lineWidth: blockStrokeWidth(block))
                        )
                        .overlay(alignment: .topLeading) {
                            if (isBlockHovered || isBlockSelected) && block.textRole != .body {
                                Text(block.role)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule().fill(roleColor(block.textRole).opacity(0.7))
                                    )
                                    .padding(3)
                            }
                        }
                        // "Copied!" flash on successful tap-copy
                        .overlay {
                            if justCopied {
                                Text("Copied!")
                                    .font(.caption.bold())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.85)))
                                    .transition(.opacity)
                            }
                        }
                        .frame(width: blockW, height: blockH)
                        .contentShape(Rectangle())
                        .onHover { isHovered in
                            if isHovered {
                                hoveredBlock = block
                                NSCursor.pointingHand.push()
                            } else if hoveredBlock?.id == block.id {
                                hoveredBlock = nil
                                NSCursor.pop()
                            }
                        }
                        .onTapGesture {
                            // Match sidebar behavior: a single click copies immediately.
                            selectedBlock = block
                            copyText(block.text)
                            withAnimation(.easeInOut(duration: 0.15)) {
                                copiedBlockId = block.id
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                guard copiedBlockId == block.id else { return }
                                withAnimation { copiedBlockId = nil }
                            }
                        }
                        .help(block.text)
                        .offset(
                            x: displayBlockRect.midX - centerX,
                            y: displayBlockRect.midY - centerY
                        )
                }
            }
            .frame(width: displaySize.width, height: displaySize.height)
        }
    }

    // MARK: - Role Colors

    private func roleColor(_ role: TextRole) -> Color {
        switch role {
        case .heading:   return .blue
        case .caption:   return .purple
        case .sidebar:   return .green
        case .tableCell: return .teal
        case .formLabel: return .gray
        case .formValue: return .gray
        case .body:      return .accentOrange
        }
    }

    private func blockFillColor(_ block: SerializableTextBlock) -> Color {
        let base = roleColor(block.textRole)
        if selectedBlock?.id == block.id {
            return base.opacity(0.4)
        } else if hoveredBlock?.id == block.id {
            return base.opacity(0.35)
        } else {
            return base.opacity(0.08)
        }
    }

    private func blockStrokeColor(_ block: SerializableTextBlock) -> Color {
        let base = roleColor(block.textRole)
        if selectedBlock?.id == block.id || hoveredBlock?.id == block.id {
            return base
        }
        return base.opacity(0.5)
    }

    private func blockStrokeWidth(_ block: SerializableTextBlock) -> CGFloat {
        let isHeading = block.textRole == .heading
        if selectedBlock?.id == block.id { return isHeading ? 4 : 3 }
        if hoveredBlock?.id == block.id { return isHeading ? 3.5 : 2.5 }
        return isHeading ? 2 : 1
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - OCROverlayToggleButton

/// Toolbar button to toggle OCR overlay visibility.
struct OCROverlayToggleButton: View {
    @Binding var isEnabled: Bool
    let hasOCRText: Bool

    @State private var isHovered = false

    var body: some View {
        Button {
            isEnabled.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isEnabled ? "text.viewfinder" : "doc.text.viewfinder")
                    .font(.body)
                if isEnabled {
                    Text("Hide Text")
                        .font(.caption)
                }
            }
            .foregroundStyle(isEnabled ? Color.accentOrange : (isHovered ? .primary : .secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isEnabled ? Color.accentOrange.opacity(0.15) : (isHovered ? Color.white.opacity(0.1) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(isEnabled ? "Hide text regions" : "Show detected text regions")
        .disabled(!hasOCRText)
        .opacity(hasOCRText ? 1 : 0.5)
    }
}

// MARK: - OCRTextTooltip

/// Tooltip showing the text content of a hovered/selected block.
struct OCRTextTooltip: View {
    let block: SerializableTextBlock?
    let isSelected: Bool

    var body: some View {
        if let block = block {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(isSelected ? "Selected Text" : "Text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    // Show role badge for non-body blocks
                    if block.textRole != .body {
                        Text(block.role)
                            .font(.caption2)
                            .foregroundStyle(Self.tooltipRoleColor(block.textRole).opacity(0.9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Self.tooltipRoleColor(block.textRole).opacity(0.15)))
                    }

                    Spacer()

                    if isSelected {
                        Text("Copied to clipboard")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }

                Text(block.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(3)

                if block.confidence < 0.9 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text("Low confidence: \(Int(block.confidence * 100))%")
                            .font(.caption2)
                    }
                    .foregroundStyle(.orange)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: 0x2a2a2a))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
            .frame(maxWidth: 280)
        }
    }

    static func tooltipRoleColor(_ role: TextRole) -> Color {
        switch role {
        case .heading:   return .blue
        case .caption:   return .purple
        case .sidebar:   return .green
        case .tableCell: return .teal
        case .formLabel: return .gray
        case .formValue: return .gray
        case .body:      return .accentOrange
        }
    }
}

// MARK: - Preview

#if DEBUG
struct OCROverlayView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color(hex: 0x1a1a1a)

            OCROverlayView(
                blocks: .constant([
                    SerializableTextBlock(
                        id: "block-0",
                        text: "Hello World. This is a test paragraph.",
                        lines: [
                            SerializableTextObservation(text: "Hello World.", boundingBox: SerializableCGRect(rect: CGRect(x: 0.1, y: 0.72, width: 0.3, height: 0.06)), confidence: 0.95),
                            SerializableTextObservation(text: "This is a test paragraph.", boundingBox: SerializableCGRect(rect: CGRect(x: 0.1, y: 0.64, width: 0.4, height: 0.06)), confidence: 0.88)
                        ],
                        boundingBox: SerializableCGRect(rect: CGRect(x: 0.1, y: 0.64, width: 0.4, height: 0.14)),
                        confidence: 0.915,
                        role: "body",
                        columnIndex: 0
                    )
                ]),
                imageSize: CGSize(width: 800, height: 600),
                displaySize: CGSize(width: 400, height: 300),
                hoveredBlock: .constant(nil),
                selectedBlock: .constant(nil)
            )
            .frame(width: 400, height: 300)
        }
        .frame(width: 500, height: 400)
    }
}
#endif
