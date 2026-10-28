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
