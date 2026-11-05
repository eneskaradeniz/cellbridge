import CallKit
import Foundation

/// A call as the UI shows it.
struct ActiveCall: Identifiable, Equatable {
    let id: UUID
    let title: String
    let answeredAt: Date?
    var isOutgoing = false
    /// The call is over; the screen shows it for a moment before it goes away.
    var isEnded = false
    var isAnswered: Bool { answeredAt != nil }
}

/// Which CallKit call belongs to which host call, and what we have done with it. Pure state, no CallKit objects.
/// An outgoing call exists here from the moment the user taps Call, before the host has told us its call id.
struct CallBook {
    /// What the call log needs to know about a call when it ends.
    struct Detail: Equatable {
        let number: String
        let title: String
        let outgoing: Bool
        let since: Date
        let answeredAt: Date?
    }

    private struct Entry {
        var callId: String?
        let number: String
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
            .map { ActiveCall(id: $0.key, title: $0.value.title, answeredAt: $0.value.answeredAt, isOutgoing: $0.value.outgoing) }
    }

    /// Host ids of the calls shown here that the host no longer lists: they ended while the connection was down.
    /// Calls without a host id yet (a dial still waiting for its answer) are never among them.
    func vanished(from live: [String]) -> [String] {
        entries.values.compactMap(\.callId).filter { !live.contains($0) }
    }

    /// Registers a ringing call; nil if the host already told us about it (it re-sends rings after a reconnect).
    mutating func ring(callId: String, title: String = "", now: Date = Date(), number: String = "") -> UUID? {
        guard !entries.values.contains(where: { $0.callId == callId }) else { return nil }
        let uuid = UUID()
        entries[uuid] = Entry(callId: callId, number: number, title: title, since: now, outgoing: false)
        return uuid
    }

    /// The user tapped Call; the host's call id arrives later with `dial_result`.
    mutating func startOutgoing(_ uuid: UUID, title: String, now: Date = Date(), number: String? = nil) {
        entries[uuid] = Entry(callId: nil, number: number ?? title, title: title, since: now, outgoing: true)
    }

    func detail(for uuid: UUID) -> Detail? {
        entries[uuid].map { Detail(number: $0.number, title: $0.title, outgoing: $0.outgoing, since: $0.since, answeredAt: $0.answeredAt) }
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

    func isEndRequested(_ uuid: UUID) -> Bool { entries[uuid]?.endRequested ?? false }

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
