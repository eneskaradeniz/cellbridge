import Foundation

/// One finished call as the Recents list shows it.
struct CallRecord: Codable, Identifiable, Equatable {
    enum Direction: String, Codable { case incoming, outgoing }
    enum Outcome: String, Codable { case answered, missed, declined, noAnswer, failed }

    /// Who ended the call, which decides how an unanswered one is labelled.
    enum Ender: Equatable {
        case host(EndReason?)
        case local
        case dialRefused
    }

    let id: UUID
    let number: String
    let title: String
    let direction: Direction
    let outcome: Outcome
    let date: Date
    let duration: TimeInterval
    /// The phone's call log id once the record is known to the phone (docs/protocol.md `call_log`).
    var hostId: String?

    var isMissed: Bool { outcome == .missed }

    static func make(_ detail: CallBook.Detail, endedBy ender: Ender, now: Date = Date(), id: UUID = UUID()) -> CallRecord {
        let outcome: Outcome
        if detail.answeredAt != nil {
            outcome = .answered
        } else if detail.outgoing {
            outcome = ender == .dialRefused ? .failed : .noAnswer
        } else {
            switch ender {
            case .host(.rejected), .local: outcome = .declined
            default: outcome = .missed // the caller gave up
            }
        }
        return CallRecord(
            id: id, number: detail.number, title: detail.title, direction: detail.outgoing ? .outgoing : .incoming,
            outcome: outcome, date: detail.since, duration: detail.answeredAt.map { now.timeIntervalSince($0) } ?? 0
        )
    }
}

/// The call history, newest first, persisted as one JSON file (like the message store).
final class CallLog {
    private(set) var entries: [CallRecord] = []
    private let url: URL?
    private static let limit = 500

    /// `url` nil keeps everything in memory (tests).
    init(url: URL?) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url) else { return }
        if let loaded = try? Self.decoder.decode([CallRecord].self, from: data) {
            entries = loaded
        } else {
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
        }
    }

    func record(_ record: CallRecord) throws {
        let before = entries
        entries.insert(record, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        do { try persist() } catch {
            entries = before
            throw error
        }
    }

    /// Forgets the given calls (swipe or menu delete).
    func remove(ids: Set<UUID>) throws {
        let before = entries
        entries.removeAll { ids.contains($0.id) }
        guard entries != before else { return }
        do { try persist() } catch {
            entries = before
            throw error
        }
    }

    /// Adds what the phone's call log has and this phone does not: calls that came in while the app was away, and the
    /// phone's id for calls it saw live (matched by number, direction and time, so nothing shows twice). Returns how many
    /// records were added.
    @discardableResult
    func merge(host calls: [HostCall]) throws -> Int {
        let before = entries
        var added = 0
        for call in calls.sorted(by: { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }) {
            if entries.contains(where: { $0.hostId == call.id }) { continue }
            let date = Date(timeIntervalSince1970: Double(call.ts) / 1000)
            let direction: CallRecord.Direction = call.kind == "outgoing" ? .outgoing : .incoming
            let key = MessageStore.key(for: call.number)
            if let index = entries.firstIndex(where: {
                $0.hostId == nil && $0.direction == direction && MessageStore.key(for: $0.number) == key
                    && abs($0.date.timeIntervalSince(date)) <= 90
            }) {
                entries[index].hostId = call.id
                continue
            }
            let outcome: CallRecord.Outcome
            switch call.kind {
            case "missed": outcome = .missed
            case "rejected": outcome = .declined
            case "outgoing": outcome = call.duration > 0 ? .answered : .noAnswer
            default: outcome = .answered
            }
            entries.append(CallRecord(id: UUID(), number: call.number, title: call.name ?? call.number, direction: direction,
                                      outcome: outcome, date: date, duration: TimeInterval(call.duration), hostId: call.id))
            added += 1
        }
        entries.sort { $0.date > $1.date }
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        guard entries != before else { return 0 }
        do { try persist() } catch {
            entries = before
            throw error
        }
        return added
    }

    func clear() throws {
        let before = entries
        entries = []
        do { try persist() } catch {
            entries = before
            throw error
        }
    }

    private func persist() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(entries).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
