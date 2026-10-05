import AppKit
import SwiftUI

/// Editor commands that need host or viewport state rather than the document session.
enum EditorKeyCommand: Equatable {
    case zoomIn, zoomOut, zoomToFit, actualSize, zoomToSelection
    /// Return applies the pending contextual action, e.g. lifting a selected subject.
    case confirm
    case selectTool(AnnotationTool)
    case spacePan(Bool)
}

/// Session-scoped keyboard routing. Text controls retain their normal editing commands.
struct EditorKeyboardModifier: ViewModifier {
    @ObservedObject var session: AnnotationEditorSession
    let onDone: () -> Void
    let onPasteImage: () -> Void
    /// Returns whether the host handled the command; unhandled keys continue to the app.
    var onCommand: (EditorKeyCommand) -> Bool = { _ in false }

    func body(content: Content) -> some View {
        content.background(EditorKeyboardMonitor(session: session, onDone: onDone, onPasteImage: onPasteImage,
                                                 onCommand: onCommand)
            .frame(width: 0, height: 0))
    }
}

private struct EditorKeyboardMonitor: NSViewRepresentable {
    let session: AnnotationEditorSession
    let onDone: () -> Void
    let onPasteImage: () -> Void
    let onCommand: (EditorKeyCommand) -> Bool

    func makeNSView(context: Context) -> EditorKeyboardMonitorView {
        let view = EditorKeyboardMonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: EditorKeyboardMonitorView, context: Context) {
        view.session = session
        view.onDone = onDone
        view.onPasteImage = onPasteImage
        view.onCommand = onCommand
    }

    static func dismantleNSView(_ view: EditorKeyboardMonitorView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class EditorKeyboardMonitorView: NSView {
    weak var session: AnnotationEditorSession?
    var onDone: () -> Void = {}
    var onPasteImage: () -> Void = {}
    var onCommand: (EditorKeyCommand) -> Bool = { _ in false }
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var isSpaceDown = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            // A Space release must always end panning, even after focus moved into a text field.
            if event.type == .keyUp {
                return event.keyCode == 49 && self.endSpacePan() ? nil : event
            }
            guard window.isKeyWindow, event.window === window, !self.isEditingText(window.firstResponder),
                  let session = self.session else { return event }
            return self.handle(event, session: session) ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.endSpacePan() }
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        _ = endSpacePan()
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    private func isEditingText(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSTextView { return text.isEditable }
        if let text = responder as? NSTextField { return text.isEditable }
        return false
    }

    private func endSpacePan() -> Bool {
        guard isSpaceDown else { return false }
        isSpaceDown = false
        _ = onCommand(.spacePan(false))
        return true
    }

    /// Exposed for focused routing tests; production input arrives through the local monitor.
    func handle(_ event: NSEvent, session: AnnotationEditorSession) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if modifiers == .command || modifiers == [.command, .shift] {
            switch key {
            case "z":
                if modifiers.contains(.shift) { session.redo() } else { session.undo() }
            case "c" where modifiers == .command: session.copySelected()
            case "x" where modifiers == .command: session.cutSelected()
            case "v" where modifiers == .command:
                if !session.pasteFromClipboard() { onPasteImage() }
            case "a" where modifiers == .command: session.selectAll()
            case "d" where modifiers == .command: session.duplicateSelected()
            case "=", "+": return onCommand(.zoomIn)
            case "-", "_": return onCommand(.zoomOut)
            case "0" where modifiers == .command: return onCommand(.zoomToFit)
            case "1" where modifiers == .command: return onCommand(.actualSize)
            case "2" where modifiers == .command: return onCommand(.zoomToSelection)
            default:
                // Brackets by key code: Shift changes the reported characters to braces.
                // ⌘] / ⌘[ step within the layer; adding Shift jumps to the front or back.
                switch event.keyCode {
                case 30:
                    if modifiers.contains(.shift) { session.bringToFront() } else { session.bringForward() }
                case 33:
                    if modifiers.contains(.shift) { session.sendToBack() } else { session.sendBackward() }
                default: return false
                }
            }
            return true
        }
        guard modifiers.isEmpty || modifiers == .shift else { return false }
        switch event.keyCode {
        case 51, 117: // Backspace / forward delete: never delete the underlying archive item.
            session.deleteSelected()
            return true
        case 53:
            if session.selectedShapeIds.isEmpty { onDone() }
            else { session.clearSelection() }
            return true
        case 36, 76: // Return / Enter
            return modifiers.isEmpty && onCommand(.confirm)
        case 49 where modifiers.isEmpty: // Space: hold to pan, repeats swallowed
            if !event.isARepeat, !isSpaceDown {
                isSpaceDown = onCommand(.spacePan(true))
                return isSpaceDown
            }
            return isSpaceDown
        case 123, 124, 125, 126:
            let amount: CGFloat = modifiers.contains(.shift) ? 0.01 : 0.001
            let delta: NormalizedPoint
            switch event.keyCode {
            case 123: delta = NormalizedPoint(x: -amount, y: 0)
            case 124: delta = NormalizedPoint(x: amount, y: 0)
            case 125: delta = NormalizedPoint(x: 0, y: amount)
            default: delta = NormalizedPoint(x: 0, y: -amount)
            }
            if !session.selectedShapeIds.isEmpty {
                session.execute(.moveShapes(shapeIds: Array(session.selectedShapeIds), delta: delta), description: "Nudge Selection")
            }
            return true
        default:
            // T and C are advertised tool keys that the app-wide annotation shortcuts do not claim;
            // without this the Item menu's plain-T "Add Tag…" fired inside the editor.
            guard modifiers.isEmpty else { return false }
            switch key {
            case "t": return onCommand(.selectTool(.text))
            case "c": return onCommand(.selectTool(.ellipse))
            default: return false
            }
        }
    }
}
