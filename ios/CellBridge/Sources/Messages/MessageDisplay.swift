import Foundation

/// How a text's state and time are put into words. Pure, so the wording is tested.
enum MessageDisplay {
    /// The host's short failure codes, and our own "not confirmed", as a sentence a person can act on.
    static func failure(_ reason: String) -> String {
        switch reason {
        case "invalid": return "invalid number or empty message"
        case "failed": return "the phone could not send it"
        case "not confirmed": return "no answer from the phone: it may or may not have gone out"
        default: return "the phone could not send it"
        }
    }

    /// "14:32" today, "Yesterday 14:32", otherwise "29 Oct 14:32".
    static func timestamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday " + time
        }
        return date.formatted(.dateTime.day().month(.abbreviated)) + " " + time
    }

    /// The header above a day's texts in a conversation.
    static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// Consecutive texts grouped by calendar day, oldest first.
    static func days(_ messages: [TextMessage], calendar: Calendar = .current) -> [(day: Date, messages: [TextMessage])] {
        var result: [(day: Date, messages: [TextMessage])] = []
        for message in messages {
            let day = calendar.startOfDay(for: message.date)
            if let last = result.last, last.day == day {
                result[result.count - 1].messages.append(message)
            } else {
                result.append((day, [message]))
            }
        }
        return result
    }

    /// The line under a bubble: nothing for a received text beyond its time; for one we send, how far it got.
    static func statusLine(for message: TextMessage, now: Date = Date()) -> (text: String, failed: Bool) {
        let time = timestamp(message.date, now: now)
        switch (message.direction, message.status) {
        case (.incoming, _), (_, .received): return (time, false)
        case (.outgoing, .sending): return ("Sending…", false)
        case (.outgoing, .sent): return ("Sent · " + time, false)
        case (.outgoing, .failed(let reason)): return ("Not sent: " + failure(reason) + " · " + time, true)
        }
    }
}
