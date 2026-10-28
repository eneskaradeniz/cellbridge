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
/// An outgoing call exists here from the moment the user taps Call, before the host has told us its call id.
struct CallBook {
    private struct Entry {
        var callId: String?
        let title: String
        let since: Date
        let outgoing: Bool
        var answeredAt: Date?
        /// The user hung up before the host answered `dial`; the hang-up goes out as soon as the call id is known.
        var endRequested = false
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
        entries[uuid] = Entry(callId: callId, title: title, since: now, outgoing: false)
        return uuid
    }

    /// The user tapped Call; the host's call id arrives later with `dial_result`.
    mutating func startOutgoing(_ uuid: UUID, title: String, now: Date = Date()) {
        entries[uuid] = Entry(callId: nil, title: title, since: now, outgoing: true)
    }

    /// `dial_result` succeeded. True if the user already hung up and the host must be told now.
    mutating func attach(callId: String, to uuid: UUID) -> Bool {
        guard entries[uuid] != nil else { return false }
        entries[uuid]?.callId = callId
        return entries[uuid]?.endRequested ?? false
    }

    /// The user ended a dialing call before the host knew its id: remember it, `attach` reports it back.
    mutating func requestEnd(_ uuid: UUID) { entries[uuid]?.endRequested = true }

    func callId(for uuid: UUID) -> String? { entries[uuid]?.callId }

    func isOutgoing(_ uuid: UUID) -> Bool { entries[uuid]?.outgoing ?? false }

    func isAnswered(_ uuid: UUID) -> Bool { entries[uuid]?.answeredAt != nil }

    func uuid(forCallId callId: String) -> UUID? { entries.first { $0.value.callId == callId }?.key }

    mutating func markAnswered(_ uuid: UUID, now: Date = Date()) { entries[uuid]?.answeredAt = now }

    /// Removes the call the host ended; returns its CallKit identity, nil if it was never reported or is already gone.
    mutating func end(callId: String) -> UUID? {
        guard let uuid = uuid(forCallId: callId) else { return nil }
        entries[uuid] = nil
        return uuid
    }

    /// Removes a call ended from our side (user hung up / declined) or whose dial failed.
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
