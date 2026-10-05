import SwiftUI
import AppKit

struct KeyboardMenuEntry: Equatable {
    let id: String
    let enabled: Bool
    let action: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.enabled == rhs.enabled }
}

private struct KeyboardMenuEntries: PreferenceKey {
    static var defaultValue: [KeyboardMenuEntry] { [] }
    static func reduce(value: inout [KeyboardMenuEntry], nextValue: () -> [KeyboardMenuEntry]) { value += nextValue() }
}

private struct KeyboardMenuItem: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    let id: String
    let action: () -> Void
    func body(content: Content) -> some View {
        content.preference(key: KeyboardMenuEntries.self, value: [.init(id: id, enabled: enabled, action: action)])
            .accessibilityIdentifier("context-menu-\(id)")
    }
}

/// Shared production navigation state, also exercised without a foreground window.
struct KeyboardMenuSelection {
    var selectedID: String?
    mutating func move(_ offset: Int, entries: [KeyboardMenuEntry]) {
        let enabled = entries.filter(\.enabled)
        guard !enabled.isEmpty else { selectedID = nil; return }
        let current = enabled.firstIndex { $0.id == selectedID }
        let index = current.map { ($0 + offset + enabled.count) % enabled.count } ?? (offset < 0 ? enabled.count - 1 : 0)
        selectedID = enabled[index].id
    }
    func selected(in entries: [KeyboardMenuEntry]) -> KeyboardMenuEntry? {
        entries.first { $0.id == selectedID && $0.enabled }
    }
}

@MainActor
enum KeyboardMenuFocus {
    static weak var active: KeyboardMenuKeyView?
    static func release() { active?.releaseFocus() }
    /// Global shortcuts consult this BEFORE their text-field Escape handling.
    static func handle(_ event: NSEvent) -> Bool {
        guard let active, active.window === event.window else { return false }
        return active.handle(event)
    }
}

final class KeyboardMenuKeyView: NSView {
    var entries: [KeyboardMenuEntry] = []
    var selection = KeyboardMenuSelection()
    var onSelection: ((String?) -> Void)?
    var onDismiss: (() -> Void)?
    private weak var previousResponder: NSResponder?
    private weak var previousWindow: NSWindow?
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func releaseFocus() {
        if KeyboardMenuFocus.active === self { KeyboardMenuFocus.active = nil }
        if previousWindow?.firstResponder === self { previousWindow?.makeFirstResponder(previousResponder) }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            releaseFocus()
        }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            if KeyboardMenuFocus.active === self { KeyboardMenuFocus.active = nil }
            if previousWindow?.firstResponder === self { previousWindow?.makeFirstResponder(previousResponder) }
            return
        }
        previousResponder = window.firstResponder
        previousWindow = window
        KeyboardMenuFocus.active = self
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.window === window, KeyboardMenuFocus.active === self else { return }
            window?.makeFirstResponder(self)
        }
    }
    override func keyDown(with event: NSEvent) { _ = handle(event) }
    func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: releaseFocus(); onDismiss?()
        case 125, 124: selection.move(1, entries: entries); onSelection?(selection.selectedID)
        case 126, 123: selection.move(-1, entries: entries); onSelection?(selection.selectedID)
        case 48: selection.move(event.modifierFlags.contains(.shift) ? -1 : 1, entries: entries); onSelection?(selection.selectedID)
        case 115: selection.selectedID = entries.first(where: \.enabled)?.id; onSelection?(selection.selectedID)
        case 119: selection.selectedID = entries.last(where: \.enabled)?.id; onSelection?(selection.selectedID)
        case 36, 76, 49: selection.selected(in: entries)?.action()
        default: break // A menu owns input; letter shortcuts must not reach the library.
        }
        return true
    }
}

private struct KeyboardMenuCapture: NSViewRepresentable {
    var entries: [KeyboardMenuEntry]
    @Binding var selected: String?
    let dismiss: () -> Void
    func makeNSView(context: Context) -> KeyboardMenuKeyView { KeyboardMenuKeyView() }
    func updateNSView(_ view: KeyboardMenuKeyView, context: Context) {
        view.entries = entries
        view.selection.selectedID = selected
        view.onSelection = { selected = $0 }
        view.onDismiss = dismiss
    }
}

private struct KeyboardMenuContainer: ViewModifier {
    @Binding var selected: String?
    let dismiss: () -> Void
    @State private var entries: [KeyboardMenuEntry] = []
    func body(content: Content) -> some View {
        content.onPreferenceChange(KeyboardMenuEntries.self) {
            entries = $0
            if selected == nil { selected = $0.first(where: \.enabled)?.id }
        }
            .background(KeyboardMenuCapture(entries: entries, selected: $selected, dismiss: dismiss))
    }
}

extension View {
    func keyboardMenuItem(_ id: String, action: @escaping () -> Void) -> some View {
        modifier(KeyboardMenuItem(id: id, action: {
            KeyboardMenuFocus.release()
            action()
        }))
    }
    func keyboardMenu(selected: Binding<String?>, dismiss: @escaping () -> Void) -> some View {
        modifier(KeyboardMenuContainer(selected: selected, dismiss: dismiss))
    }
}
