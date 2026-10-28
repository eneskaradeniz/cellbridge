#if DEBUG
import Foundation

/// Debug-only launch switches for looking at the screens without a phone: `-sampleData YES` fills them with made-up
/// contacts, texts and calls (kept in a temporary folder), `-sampleTab 2` opens a tab, `-sampleThread YES` opens the
/// first conversation, `-sampleCall ringing|talking|calling` shows the call screen.
enum Sample {
    private static let defaults = UserDefaults.standard

    static var enabled: Bool { defaults.bool(forKey: "sampleData") }
    static var startTab: AppTab? { defaults.object(forKey: "sampleTab") == nil ? nil : AppTab(rawValue: defaults.integer(forKey: "sampleTab")) }
    static var opensThread: Bool { defaults.bool(forKey: "sampleThread") }
    static var call: String? { defaults.string(forKey: "sampleCall") }

    static let contacts: [Contact] = [
        Contact(id: "1", name: "Ayşe Yılmaz", numbers: [LabeledNumber(label: "mobile", value: "+90 532 111 22 33")]),
        Contact(id: "2", name: "Kerem Demir", numbers: [LabeledNumber(label: "mobile", value: "+90 533 222 33 44"), LabeledNumber(label: "work", value: "+90 212 555 01 02")]),
        Contact(id: "3", name: "Çağrı Kaya", numbers: [LabeledNumber(label: "mobile", value: "+90 535 333 44 55")]),
        Contact(id: "4", name: "Deniz Arslan", numbers: [LabeledNumber(label: "mobile", value: "+90 536 444 55 66")]),
        Contact(id: "5", name: "Elif Şahin", numbers: [LabeledNumber(label: "home", value: "+90 216 444 66 77")]),
        Contact(id: "6", name: "Kardeşim", numbers: [LabeledNumber(label: "mobile", value: "+90 537 555 66 77")]),
    ]

    static func seed(messages: MessageStore, calls: CallLog, now: Date = Date()) {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        try? messages.receive(hostId: "1", from: "+90 532 111 22 33", body: "Akşam görüşelim mi? Yemeğe çıkarız.", date: ago(95))
        let reply = try? messages.queueOutgoing(to: "+90 532 111 22 33", body: "Olur, saat kaçta?", date: ago(92))
        if let reply { try? messages.apply(clientId: reply.id, ok: true, error: nil) }
        try? messages.receive(hostId: "2", from: "+90 532 111 22 33", body: "Yedi gibi nasıl? Ben seni alırım.", date: ago(90))
        let ok = try? messages.queueOutgoing(to: "+90 532 111 22 33", body: "Harika, görüşürüz!", date: ago(88))
        if let ok { try? messages.apply(clientId: ok.id, ok: true, error: nil) }
        _ = try? messages.queueOutgoing(to: "+90 532 111 22 33", body: "Bir de dün konuştuğumuz belgeyi unutma.", date: ago(2))
        try? messages.receive(hostId: "3", from: "+90 537 555 66 77", body: "Annem seni sordu, bir ara ara.", date: ago(60 * 26))
        let bad = try? messages.queueOutgoing(to: "+90 533 222 33 44", body: "Toplantı ertelendi.", date: ago(300))
        if let bad { try? messages.apply(clientId: bad.id, ok: false, error: "failed") }
        try? messages.receive(hostId: "4", from: "Garanti BBVA", body: "Kartınızla 249,90 TL tutarında alışveriş yapılmıştır.", date: ago(60 * 50))

        func record(_ number: String, _ title: String, _ direction: CallRecord.Direction, _ outcome: CallRecord.Outcome, _ minutes: Double, _ duration: Double) {
            try? calls.record(CallRecord(id: UUID(), number: number, title: title, direction: direction, outcome: outcome, date: ago(minutes), duration: duration))
        }
        record("+90 535 333 44 55", "Çağrı Kaya", .incoming, .answered, 60 * 30, 1254)
        record("+90 536 444 55 66", "Deniz Arslan", .incoming, .missed, 60 * 8, 0)
        record("+90 537 555 66 77", "Kardeşim", .outgoing, .answered, 60 * 3, 312)
        record("+90 532 111 22 33", "Ayşe Yılmaz", .outgoing, .noAnswer, 40, 0)
        record("+90 555 010 20 30", "+90 555 010 20 30", .incoming, .declined, 12, 0)
    }

    static func activeCall(now: Date = Date()) -> ActiveCall? {
        switch call {
        case "ringing": return ActiveCall(id: UUID(), title: "Ayşe Yılmaz", answeredAt: nil)
        case "talking": return ActiveCall(id: UUID(), title: "Kardeşim", answeredAt: now.addingTimeInterval(-83))
        case "calling": return ActiveCall(id: UUID(), title: "Kerem Demir", answeredAt: nil, isOutgoing: true)
        default: return nil
        }
    }
}
#endif
