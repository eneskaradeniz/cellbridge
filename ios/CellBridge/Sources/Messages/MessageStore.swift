import Foundation

struct TextMessage: Codable, Identifiable, Equatable {
    enum Direction: String, Codable { case incoming, outgoing }
    enum Status: Codable, Equatable {
        case received
        case sending
        case sent
        case failed(String)
    }

    /// Incoming: `in-<host id>`, so a replayed text is recognised. Outgoing: the client id sent with `sms_send`.
    let id: String
    let peer: String
    let body: String
    let date: Date
    let direction: Direction
    var status: Status
}

struct Conversation: Identifiable, Equatable {
    let key: String
    let messages: [TextMessage]
    var id: String { key }
    var last: TextMessage { messages[messages.count - 1] }
    var peer: String { last.peer }
}

/// All texts, persisted as one JSON file. A text only counts as received once it is on disk: the caller acknowledges
/// it to the host after `receive` returns, so a failed write leaves it for the host to re-send.
final class MessageStore {
    private(set) var messages: [TextMessage] = []
    private let url: URL?

    /// `url` nil keeps everything in memory (tests).
    init(url: URL?) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url) else { return }
        if let loaded = try? Self.decoder.decode([TextMessage].self, from: data) {
            messages = loaded
        } else {
            // Do not overwrite what we cannot read; keep it for inspection and start fresh.
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
        }
    }

    /// False if this host id was stored before. Throws if it could not be written; nothing is stored then.
    @discardableResult
    func receive(hostId: String, from: String, body: String, date: Date) throws -> Bool {
        let id = "in-" + hostId
        guard !messages.contains(where: { $0.id == id }) else { return false }
        try append(TextMessage(id: id, peer: from, body: body, date: date, direction: .incoming, status: .received))
        return true
    }

    func queueOutgoing(to: String, body: String, date: Date = Date()) throws -> TextMessage {
        let message = TextMessage(id: UUID().uuidString, peer: to, body: body, date: date, direction: .outgoing, status: .sending)
        try append(message)
        return message
    }

    func apply(clientId: String, ok: Bool, error: String?) throws {
        try update { $0.id == clientId && $0.status == .sending } to: { $0.status = ok ? .sent : .failed(error ?? "failed") }
    }

    /// The connection dropped before the host answered: we cannot know whether these went out, and resending could
    /// send a text twice, so they are reported as unconfirmed and left to the user.
    func failPending(reason: String) throws {
        try update { $0.status == .sending } to: { $0.status = .failed(reason) }
    }

    /// Forgets one text (a failed one that is being sent again).
    func remove(id: String) throws {
        let before = messages
        messages.removeAll { $0.id == id }
        guard messages != before else { return }
        do { try persist() } catch {
            messages = before
            throw error
        }
    }

    var conversations: [Conversation] {
        Dictionary(grouping: messages, by: { Self.key(for: $0.peer) })
            .map { Conversation(key: $0.key, messages: $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.last.date > $1.last.date }
    }

    /// "+90 555 111 22 33" and "0555 111 22 33" are the same person: compare the last ten digits.
    static func key(for peer: String) -> String {
        let digits = peer.filter(\.isNumber)
        return digits.count >= 7 ? String(digits.suffix(10)) : peer.lowercased()
    }

    // MARK: private

    private func append(_ message: TextMessage) throws {
        messages.append(message)
        do { try persist() } catch {
            messages.removeLast()
            throw error
        }
    }

    private func update(where matches: (TextMessage) -> Bool, to change: (inout TextMessage) -> Void) throws {
        let before = messages
        for index in messages.indices where matches(messages[index]) { change(&messages[index]) }
        guard messages != before else { return }
        do { try persist() } catch {
            messages = before
            throw error
        }
    }

    private func persist() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Readable after the first unlock so a text that arrives while the phone is locked can still be saved.
        try Self.encoder.encode(messages).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
