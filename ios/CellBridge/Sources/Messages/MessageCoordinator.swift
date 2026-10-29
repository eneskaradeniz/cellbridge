import Foundation

/// Connects the host's texts to the store and the screen: saves, then acknowledges, then notifies.
@MainActor
final class MessageCoordinator: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []

    private let store: MessageStore
    private let transmit: (ClientMessage) -> Void
    private let notify: (_ id: String, _ title: String, _ body: String) -> Void
    private let log: (String) -> Void
    /// An ack covers every earlier text, so after a failed save no later ack may go out until the host replays.
    private var ackBlocked = false
    /// The conversation on screen while the app is in front; a text for it is read on arrival and makes no notification.
    var viewingKey: String?

    init(store: MessageStore, transmit: @escaping (ClientMessage) -> Void,
         notify: @escaping (String, String, String) -> Void, log: @escaping (String) -> Void) {
        self.store = store
        self.transmit = transmit
        self.notify = notify
        self.log = log
        conversations = store.conversations
    }

    func handle(_ message: ServerMessage) {
        switch message {
        case .sms(let id, let from, let body, let ts):
            receive(id: id, from: from, body: body, date: Date(timeIntervalSince1970: Double(ts) / 1000))
        case .smsResult(let clientId, let ok, let error):
            do { try store.apply(clientId: clientId, ok: ok, error: error) } catch { log("could not save a send result: \(error.localizedDescription)") }
            refresh()
        default:
            break
        }
    }

    /// Queues the text and asks the host to send it; its result arrives as `sms_result`.
    func send(to: String, body: String) {
        do {
            let message = try store.queueOutgoing(to: to, body: body)
            refresh()
            transmit(.smsSend(clientId: message.id, to: to, body: body))
        } catch {
            log("could not save the text to send: \(error.localizedDescription)")
        }
    }

    /// Sends a failed text again as a new one (the failed entry goes), so a retry never leaves two copies on screen.
    func retry(_ message: TextMessage) {
        guard message.direction == .outgoing, case .failed = message.status else { return }
        do { try store.remove(id: message.id) } catch { return log("could not retry: \(error.localizedDescription)") }
        send(to: message.peer, body: message.body)
    }

    /// The connection dropped: sends the host never answered cannot be confirmed, and the host will replay unacked texts.
    func connectionLost() {
        ackBlocked = false
        do { try store.failPending(reason: "not confirmed") } catch { log("could not update pending sends: \(error.localizedDescription)") }
        refresh()
    }

    var unreadCount: Int { conversations.reduce(0) { $0 + $1.unreadCount } }

    func markRead(key: String) {
        do { try store.markRead(key: key) } catch { log("could not mark as read: \(error.localizedDescription)") }
        refresh()
    }

    func markUnread(key: String) {
        do { try store.markUnread(key: key) } catch { log("could not mark as unread: \(error.localizedDescription)") }
        refresh()
    }

    func delete(conversation key: String) {
        do { try store.removeConversation(key: key) } catch { log("could not delete the conversation: \(error.localizedDescription)") }
        refresh()
    }

    func delete(message id: String) {
        do { try store.remove(ids: [id]) } catch { log("could not delete the text: \(error.localizedDescription)") }
        refresh()
    }

    private func receive(id: String, from: String, body: String, date: Date) {
        do {
            let isNew = try store.receive(hostId: id, from: from, body: body, date: date)
            let watching = viewingKey == MessageStore.key(for: from)
            if isNew && watching { try? store.markRead(key: MessageStore.key(for: from)) }
            refresh()
            if !ackBlocked { transmit(.smsAck(id: id)) } // only once it is on disk
            if isNew && !watching { notify(id, from, body) }
        } catch {
            ackBlocked = true // not acknowledged, so the host re-sends it (and everything after it) next time
            log("could not save text \(id): \(error.localizedDescription)")
        }
    }

    private func refresh() { conversations = store.conversations }
}
