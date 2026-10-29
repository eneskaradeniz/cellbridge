import Foundation
import UserNotifications

/// Local notifications for texts that arrive while the app is not in front (the WebSocket stays up in the background).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    /// The number on the app icon.
    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }

    /// `id` is the host's text id, so a replayed text replaces its notification instead of stacking another.
    func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "sms-" + id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
