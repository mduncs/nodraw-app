import Foundation

/// Menu clicks and keyboard commands must target the same mounted editor.
/// Text controls keep AppKit's responder-chain editing before entering this route.
enum ImageEditorMenuAction {
    case undo, redo, cut, copy, paste, selectAll, duplicate

    static let notification = Notification.Name("NoDraw.imageEditorMenuAction")

    @MainActor func send() {
        NotificationCenter.default.post(name: Self.notification, object: self)
    }

    @MainActor func perform(on session: AnnotationEditorSession, pasteImage: () -> Void) {
        switch self {
        case .undo: session.undo()
        case .redo: session.redo()
        case .cut: session.cutSelected()
        case .copy: session.copySelected()
        case .paste: if !session.pasteFromClipboard() { pasteImage() }
        case .selectAll: session.selectAll()
        case .duplicate: session.duplicateSelected()
        }
    }
}
