import Foundation

/// What the host blocked and the spam settings; the host keeps the list, this mirrors it (docs/protocol.md "Spam filter").
@MainActor
final class SpamCenter: ObservableObject {
    @Published private(set) var items: [SpamItem] = []
    @Published private(set) var strict = false
    /// False while the host cannot screen calls (the Android role is not given); texts are filtered anyway.
    @Published private(set) var screening = true
    /// The host offers the `spam` capability.
    @Published private(set) var supported = false
    @Published private(set) var seenAt: Date

    private let transmit: (ClientMessage) -> Void
    private let defaults: UserDefaults
    private var lastContactKeys: [String]?

    init(transmit: @escaping (ClientMessage) -> Void, defaults: UserDefaults = .standard) {
        self.transmit = transmit
        self.defaults = defaults
        seenAt = Date(timeIntervalSince1970: defaults.double(forKey: "spamSeenAt"))
    }

    /// Blocked since the list was last opened.
    var unseen: Int { items.filter { Date(timeIntervalSince1970: Double($0.ts) / 1000) > seenAt }.count }

    func markSeen() {
        seenAt = Date()
        defaults.set(seenAt.timeIntervalSince1970, forKey: "spamSeenAt")
    }

    func connected(capabilities: [String]) {
        supported = capabilities.contains("spam")
        guard supported else { return }
        if let lastContactKeys { transmit(.contactsSync(keys: lastContactKeys)) }
        transmit(.spamListRequest)
    }

    func handle(_ message: ServerMessage) {
        switch message {
        case .spamList(let list, let strict, let screening):
            items = list
            self.strict = strict
            self.screening = screening
        case .spamBlocked(let item):
            if !items.contains(where: { $0.id == item.id }) { items.insert(item, at: 0) }
        default:
            break
        }
    }

    /// The numbers of the contacts, by their last ten digits (the same key the host compares), without names.
    func syncContacts(_ contacts: [Contact]) {
        let keys = Array(Set(contacts.flatMap { $0.numbers.map { MessageStore.key(for: $0.value) } }
            .filter { $0.allSatisfy(\.isNumber) })).sorted()
        guard keys != lastContactKeys else { return }
        lastContactKeys = keys
        if supported { transmit(.contactsSync(keys: keys)) }
    }

    func report(number: String, body: String? = nil) { transmit(.spamReport(number: number, body: body)) }

    func notSpam(_ item: SpamItem) {
        items.removeAll { MessageStore.key(for: $0.number) == MessageStore.key(for: item.number) }
        transmit(.spamNot(number: item.number))
    }

    func setStrict(_ on: Bool) {
        strict = on
        transmit(.spamSettings(strict: on))
    }

    /// The host's reason code in words.
    static func reasonText(_ reason: String) -> String {
        switch reason {
        case "reported": String(localized: "You reported this number")
        case "range": String(localized: "Number close to a reported one")
        case "same_text": String(localized: "Same text as a reported one")
        case "marketing": String(localized: "Marketing number")
        case "foreign": String(localized: "Foreign number")
        case "withheld": String(localized: "Hidden number")
        case "gambling": String(localized: "Betting ad")
        case "scam": String(localized: "Looks like a scam")
        case "link": String(localized: "Suspicious link")
        case "unknown": String(localized: "Not in your contacts")
        default: reason
        }
    }
}
