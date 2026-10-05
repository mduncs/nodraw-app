import SwiftUI

// MARK: - UndoToastView

/// Toast notification showing action description with undo button.
/// Appears bottom-center, auto-dismisses after 4 seconds.
/// Dark background with orange accent button per SPEC.
struct UndoToastView: View {
    let toast: UndoToast
    let onUndo: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            // Action description
            Text(toast.message)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.white)

            if toast.showUndo {
                // Undo button
                Button(action: onUndo) {
                    Text("Undo")
                        .font(.system(.body, design: .monospaced, weight: .medium))
                        .foregroundColor(Color.accentOrange)
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .scaleEffect(isHovered ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: isHovered)

                // Keyboard hint
                Text("(Cmd+Z)")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
            }

            // Dismiss button
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: 0x2a2a2a))
                .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - UndoToastContainer

/// Container that manages toast positioning and animations.
/// Place this at the bottom of your main content view.
struct UndoToastContainer: View {
    @ObservedObject var undoStack: UndoStack
    let onUndo: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear

            if let toast = undoStack.currentToast {
                UndoToastView(
                    toast: toast,
                    onUndo: onUndo,
                    onDismiss: {
                        undoStack.dismissToast()
                    }
                )
                .padding(.bottom, 60)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toast.id)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: undoStack.currentToast?.id)
    }
}

// MARK: - Keyboard Handler for Undo/Redo

/// NSViewRepresentable that captures Cmd+Z and Cmd+Shift+Z for undo/redo.
struct UndoKeyHandler: NSViewRepresentable {
    let onUndo: () -> Void
    let onRedo: () -> Void

    func makeNSView(context: Context) -> UndoKeyCaptureView {
        let view = UndoKeyCaptureView()
        view.onUndo = onUndo
        view.onRedo = onRedo
        return view
    }

    func updateNSView(_ nsView: UndoKeyCaptureView, context: Context) {
        nsView.onUndo = onUndo
        nsView.onRedo = onRedo
    }
}

/// NSView that captures keyboard shortcuts for undo/redo.
class UndoKeyCaptureView: NSView {
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Check for Cmd+Z (undo) or Cmd+Shift+Z (redo)
        guard event.modifierFlags.contains(.command) else {
            super.keyDown(with: event)
            return
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              characters == "z" else {
            super.keyDown(with: event)
            return
        }

        if event.modifierFlags.contains(.shift) {
            // Cmd+Shift+Z = redo
            onRedo?()
        } else {
            // Cmd+Z = undo
            onUndo?()
        }
    }
}

// MARK: - Preview

#if DEBUG
struct UndoToastView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color(hex: 0x1a1a1a)

            VStack {
                Spacer()

                UndoToastView(
                    toast: UndoToast(message: "Starred 5 items", showUndo: true),
                    onUndo: {},
                    onDismiss: {}
                )
                .padding(.bottom, 60)
            }
        }
        .frame(width: 600, height: 400)
        .previewDisplayName("With Undo")

        ZStack {
            Color(hex: 0x1a1a1a)

            VStack {
                Spacer()

                UndoToastView(
                    toast: UndoToast(message: "Undid: Starred 5 items", showUndo: false),
                    onUndo: {},
                    onDismiss: {}
                )
                .padding(.bottom, 60)
            }
        }
        .frame(width: 600, height: 400)
        .previewDisplayName("After Undo")
    }
}
#endif
