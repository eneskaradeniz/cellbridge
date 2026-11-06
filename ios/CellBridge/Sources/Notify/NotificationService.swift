import Contacts
import UserNotifications

/// Opens the sealed text push (docs/protocol.md) and puts sender and text on the screen in place of the generic "New message".
/// Anything that goes wrong leaves the generic notice as it is.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var original: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        original = request.content
        guard let sealed = request.content.userInfo["cb"] as? String, let key = PushKeyStore.existing(),
              let text = PushSeal.openText(sealed, key: key),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return contentHandler(request.content) }
        content.title = Self.name(for: text.from) ?? text.from
        content.body = text.body
        content.sound = .default
        content.threadIdentifier = text.from // one stack per sender, like the notices the app posts itself
        content.userInfo = ["peer": text.from, "smsId": text.id] // the sealed box is not needed any more; "peer" makes a tap open the thread
        PushedTexts.insert(text.id)
        contentHandler(content)
    }

    /// Out of time: Apple wants the best version we have, which is the generic notice.
    override func serviceExtensionTimeWillExpire() {
        if let handler, let original { handler(original) }
    }

    /// The contact's name when the app may read contacts (the permission is the app's) and the number matches one; nil otherwise.
    private static func name(for number: String) -> String? {
        guard number.contains(where: \.isNumber), CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        let contacts = try? CNContactStore().unifiedContacts(
            matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: number)),
            keysToFetch: [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
        )
        return contacts?.first.flatMap { CNContactFormatter.string(from: $0, style: .fullName) }
    }
}
