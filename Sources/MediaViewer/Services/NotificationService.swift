import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private static let warningThrottlePrefix = "notification.warning.lastShown."
    private let center: UNUserNotificationCenter?

    private override init() {
        if Bundle.main.bundleURL.pathExtension == "app" {
            center = UNUserNotificationCenter.current()
        } else {
            center = nil
        }
        super.init()
        center?.delegate = self
    }

    func requestPermission() {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        guard let center else { return }

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logWarning("Notification permission request failed: \(error.localizedDescription)")
                return
            }
            logInfo("Notification permission granted: \(granted)")
        }
    }

    func showDownloadComplete(title: String, url: URL?, itemCount: Int?) {
        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.subtitle = title.isEmpty ? "Archived media item" : title

        var bodyParts: [String] = []
        if let itemCount {
            bodyParts.append(itemCount == 1 ? "1 item saved" : "\(itemCount) items saved")
        }
        if let url {
            bodyParts.append(url.host ?? url.absoluteString)
        }
        content.body = bodyParts.isEmpty ? "Your media was archived successfully." : bodyParts.joined(separator: " • ")
        content.sound = .default

        enqueue(content: content, identifierPrefix: "download.complete")
    }

    func showDownloadFailed(title: String, error: String) {
        let content = UNMutableNotificationContent()
        content.title = "Download Failed"
        content.subtitle = title.isEmpty ? "Unable to archive media" : title
        content.body = error.isEmpty ? "An unknown error occurred." : error
        content.sound = .default

        enqueue(content: content, identifierPrefix: "download.failed")
    }

    func showWarning(
        title: String,
        body: String,
        dedupeKey: String,
        minimumInterval: TimeInterval = 60 * 60 * 12
    ) {
        guard shouldDeliverWarning(for: dedupeKey, minimumInterval: minimumInterval) else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        enqueue(content: content, identifierPrefix: "warning.\(dedupeKey)")
    }

    private func shouldDeliverWarning(for dedupeKey: String, minimumInterval: TimeInterval) -> Bool {
        let key = Self.warningThrottlePrefix + dedupeKey
        let now = Date().timeIntervalSince1970
        let lastShown = UserDefaults.standard.double(forKey: key)
        guard now - lastShown >= minimumInterval else { return false }
        UserDefaults.standard.set(now, forKey: key)
        return true
    }

    private func enqueue(content: UNNotificationContent, identifierPrefix: String) {
        guard !BackgroundQAConfiguration.isEnabled else { return }
        guard let center else { return }

        let request = UNNotificationRequest(
            identifier: "\(identifierPrefix).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                logWarning("Failed to post local notification: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
