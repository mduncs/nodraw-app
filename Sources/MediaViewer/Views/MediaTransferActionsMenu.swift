import SwiftUI
import AppKit

/// Native menu adapters share the same action/source inventory with the catalog.
struct MediaTransferActionsMenu: View {
    @EnvironmentObject private var appState: AppState
    let context: MediaActionContext
    var body: some View {
        ForEach(MediaTransferSource.allCases) { source in
            Menu(source.label) {
                ForEach(MediaFileAction.allCases, id: \.self) { action in
                    Button(action.title) { action.perform(context: context, source: source, appState: appState) }
                        .disabled(!context.isEnabled(action, source: source))
                }
            }
            .disabled((try? context.resolve(source)) == nil)
        }
    }
}

@MainActor
enum MediaTransferMenuPresenter {
    private final class Invocation: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func invoke(_ sender: NSMenuItem) { run() }
    }

    static func present(context: MediaActionContext, appState: AppState) {
        let menu = NSMenu(title: "Transfer")
        menu.autoenablesItems = false
        var targets: [Invocation] = []
        for source in MediaTransferSource.allCases {
            let parent = NSMenuItem(title: source.label, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: source.label)
            submenu.autoenablesItems = false
            for action in MediaFileAction.allCases {
                let target = Invocation { action.perform(context: context, source: source, appState: appState) }
                targets.append(target)
                let item = NSMenuItem(title: action.title, action: #selector(Invocation.invoke(_:)), keyEquivalent: "")
                item.target = target
                item.isEnabled = context.isEnabled(action, source: source)
                submenu.addItem(item)
            }
            parent.submenu = submenu
            parent.isEnabled = (try? context.resolve(source)) != nil
            menu.addItem(parent)
        }
        withExtendedLifetime(targets) {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}
