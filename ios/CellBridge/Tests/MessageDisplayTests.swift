import XCTest
@testable import CellBridge

final class MessageDisplayTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return c
    }
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    private func message(_ direction: TextMessage.Direction, _ status: TextMessage.Status, at when: Date) -> TextMessage {
        TextMessage(id: UUID().uuidString, peer: "+905551112233", body: "x", date: when, direction: direction, status: status)
    }

    func testFailureReasonsReadAsSentences() {
        XCTAssertTrue(MessageDisplay.failure("invalid").contains("invalid number"))
        XCTAssertTrue(MessageDisplay.failure("not confirmed").contains("may or may not"))
        XCTAssertEqual(MessageDisplay.failure("failed"), MessageDisplay.failure("something the host adds later"))
    }

    func testDaysGroupConsecutiveTextsOfTheSameCalendarDay() {
        let a = message(.incoming, .received, at: date(27, 23, 50))
        let b = message(.outgoing, .sent, at: date(28, 0, 5)) // minutes later, but the next day
        let c = message(.incoming, .received, at: date(28, 9))
        let days = MessageDisplay.days([a, b, c], calendar: calendar)
        XCTAssertEqual(days.map { $0.messages.count }, [1, 2])
    }

    func testDayTitleToday_Yesterday_OlderDays() {
        let now = date(28, 15)
        XCTAssertEqual(MessageDisplay.dayTitle(date(28, 8), now: now, calendar: calendar), "Today")
        XCTAssertEqual(MessageDisplay.dayTitle(date(27, 22), now: now, calendar: calendar), "Yesterday")
        XCTAssertFalse(["Today", "Yesterday"].contains(MessageDisplay.dayTitle(date(20, 8), now: now, calendar: calendar)))
    }

    func testStatusLineFollowsHowFarTheTextGot() {
        let now = date(28, 15)
        XCTAssertEqual(MessageDisplay.statusLine(for: message(.outgoing, .sending, at: now), now: now).text, "Sending…")
        let sent = MessageDisplay.statusLine(for: message(.outgoing, .sent, at: date(28, 14, 32)), now: now)
        XCTAssertTrue(sent.text.hasPrefix("Sent · "))
        XCTAssertFalse(sent.failed)
        let failed = MessageDisplay.statusLine(for: message(.outgoing, .failed("invalid"), at: now), now: now)
        XCTAssertTrue(failed.failed)
        XCTAssertTrue(failed.text.hasPrefix("Not sent: invalid number"))
        let received = MessageDisplay.statusLine(for: message(.incoming, .received, at: date(28, 14, 32)), now: now)
        XCTAssertFalse(received.text.contains("Sent"))
    }

    func testTimestampSaysYesterdayAndFallsBackToTheDate() {
        let now = date(28, 15)
        XCTAssertTrue(MessageDisplay.timestamp(date(27, 9), now: now, calendar: calendar).hasPrefix("Yesterday "))
        XCTAssertFalse(MessageDisplay.timestamp(date(20, 9), now: now, calendar: calendar).hasPrefix("Yesterday"))
    }
}
