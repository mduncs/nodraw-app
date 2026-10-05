import Foundation
import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class UpdaterService: NSObject {
    static let shared = UpdaterService()

    private let appcastURLKey = "sparkleAppcastURL"
    #if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
    #endif

    private override init() {
        super.init()
        configureUpdaterIfPossible()
    }

    var canCheckForUpdates: Bool {
        #if canImport(Sparkle)
        updaterController != nil
        #else
        false
        #endif
    }

    func checkForUpdates() {
        #if canImport(Sparkle)
        guard let updaterController else {
            showNotConfiguredAlert()
            return
        }
        updaterController.checkForUpdates(nil)
        #else
        showNotConfiguredAlert(message: "Sparkle is not linked in this build.")
        #endif
    }

    private func configureUpdaterIfPossible() {
        #if canImport(Sparkle)
        guard let appcastString = UserDefaults.standard.string(forKey: appcastURLKey),
              !appcastString.isEmpty,
              let appcastURL = URL(string: appcastString) else {
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.feedURL = appcastURL
        updaterController = controller
        #endif
    }

    private func showNotConfiguredAlert(message: String = "Set UserDefaults key 'sparkleAppcastURL' to enable Sparkle updates.") {
        let alert = NSAlert()
        alert.messageText = "Updater Not Configured"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
