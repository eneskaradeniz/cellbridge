import Foundation
import UserNotifications

/// Local notifications for texts that arrive while the app is not in front (the WebSocket stays up in the background).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the sender's number when a text's notification is tapped.
    var onOpen: ((String) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// The number on the app icon.
    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }

    /// `id` is the host's text id, so a replayed text replaces its notification instead of stacking another.
    func notify(id: String, peer: String, kind: String?, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = kind.map { ["kind": $0] } ?? ["peer": peer]
        if kind == nil { content.threadIdentifier = peer } // one stack per sender in Notification Centre
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "sms-" + id, content: content, trigger: nil))
    }

    private let linkDownId = "link-down"

    /// The phone refuses the pairing code. One notification id, so repeats replace each other.
    func linkDown(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["kind": "link"]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: linkDownId, content: content, trigger: nil))
    }

    /// Back online, or the user disconnected on purpose: no notice pending or left on the lock screen.
    func clearLinkDown() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [linkDownId])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [linkDownId])
    }

    /// A tap opens that conversation. The completion-handler form, called on the main queue: the `async` form finished
    /// on a Swift concurrency thread, and UIKit aborts the app when its completion handler runs off the main thread.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        if content.userInfo["kind"] != nil { return completionHandlerOnMain(completionHandler) } // a battery warning and the like: nothing to open
        // Notifications posted before `peer` was stored carry the sender's number as their title.
        let peer = content.userInfo["peer"] as? String ?? (content.title.isEmpty ? nil : content.title)
        DispatchQueue.main.async {
            if let peer { MainActor.assumeIsolated { self.onOpen?(peer) } }
            completionHandler()
        }
    }

    private nonisolated func completionHandlerOnMain(_ handler: @escaping () -> Void) { DispatchQueue.main.async { handler() } }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async { completionHandler([.banner, .sound]) }
    }
}
