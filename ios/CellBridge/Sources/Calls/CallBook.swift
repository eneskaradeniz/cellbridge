import CallKit
import Foundation

/// A call as the UI shows it.
struct ActiveCall: Identifiable, Equatable {
    let id: UUID
    let title: String
    let answeredAt: Date?
    var isAnswered: Bool { answeredAt != nil }
}

/// Which CallKit call belongs to which host call, and what we have done with it. Pure state, no CallKit objects.
struct CallBook {
    private struct Entry {
        let callId: String
        let title: String
        let since: Date
        var answeredAt: Date?
    }

    private var entries: [UUID: Entry] = [:]

    /// Calls that are ringing or in progress, oldest first.
    var active: [ActiveCall] {
        entries.sorted { $0.value.since < $1.value.since }
            .map { ActiveCall(id: $0.key, title: $0.value.title, answeredAt: $0.value.answeredAt) }
    }

    /// Registers a ringing call; nil if the host already told us about it (it re-sends rings after a reconnect).
    mutating func ring(callId: String, title: String = "", now: Date = Date()) -> UUID? {
        guard !entries.values.contains(where: { $0.callId == callId }) else { return nil }
        let uuid = UUID()
        entries[uuid] = Entry(callId: callId, title: title, since: now)
        return uuid
    }

    func callId(for uuid: UUID) -> String? { entries[uuid]?.callId }

    func isAnswered(_ uuid: UUID) -> Bool { entries[uuid]?.answeredAt != nil }

    mutating func markAnswered(_ uuid: UUID, now: Date = Date()) { entries[uuid]?.answeredAt = now }

    /// Removes the call the host ended; returns its CallKit identity, nil if it was never reported or is already gone.
    mutating func end(callId: String) -> UUID? {
        guard let uuid = entries.first(where: { $0.value.callId == callId })?.key else { return nil }
        entries[uuid] = nil
        return uuid
    }

    /// Removes a call ended from our side (user hung up / declined).
    mutating func end(uuid: UUID) { entries[uuid] = nil }

    /// How a host-side ending shows up in the system call UI.
    static func callKitReason(for reason: EndReason?) -> CXCallEndedReason {
        switch reason {
        case .missed: return .unanswered
        case .rejected: return .declinedElsewhere
        case nil: return .remoteEnded
        }
    }
}
