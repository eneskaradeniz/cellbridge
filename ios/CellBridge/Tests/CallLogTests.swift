import XCTest
@testable import CellBridge

final class CallLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func detail(outgoing: Bool, answered: Bool) -> CallBook.Detail {
        CallBook.Detail(number: "+905551112233", title: "Ali", outgoing: outgoing, since: t0,
                        answeredAt: answered ? t0.addingTimeInterval(3) : nil)
    }

    func testAnsweredCallsKeepTheirDurationInBothDirections() {
        let incoming = CallRecord.make(detail(outgoing: false, answered: true), endedBy: .local, now: t0.addingTimeInterval(63))
        XCTAssertEqual(incoming.outcome, .answered)
        XCTAssertEqual(incoming.direction, .incoming)
        XCTAssertEqual(incoming.duration, 60)
        XCTAssertEqual(incoming.date, t0)

        let outgoing = CallRecord.make(detail(outgoing: true, answered: true), endedBy: .host(nil), now: t0.addingTimeInterval(13))
        XCTAssertEqual(outgoing.outcome, .answered)
        XCTAssertEqual(outgoing.duration, 10)
    }

    func testUnansweredIncomingCallsAreMissedOrDeclined() {
        XCTAssertEqual(CallRecord.make(detail(outgoing: false, answered: false), endedBy: .host(.missed)).outcome, .missed)
        XCTAssertEqual(CallRecord.make(detail(outgoing: false, answered: false), endedBy: .host(nil)).outcome, .missed)
        XCTAssertEqual(CallRecord.make(detail(outgoing: false, answered: false), endedBy: .host(.rejected)).outcome, .declined)
        XCTAssertEqual(CallRecord.make(detail(outgoing: false, answered: false), endedBy: .local).outcome, .declined)
    }

    func testUnansweredOutgoingCallsAreNoAnswerOrFailed() {
        XCTAssertEqual(CallRecord.make(detail(outgoing: true, answered: false), endedBy: .local).outcome, .noAnswer)
        XCTAssertEqual(CallRecord.make(detail(outgoing: true, answered: false), endedBy: .host(nil)).outcome, .noAnswer)
        XCTAssertEqual(CallRecord.make(detail(outgoing: true, answered: false), endedBy: .dialRefused).outcome, .failed)
    }

    func testOnlyMissedCallsCountAsMissed() {
        XCTAssertTrue(CallRecord.make(detail(outgoing: false, answered: false), endedBy: .host(.missed)).isMissed)
        XCTAssertFalse(CallRecord.make(detail(outgoing: false, answered: false), endedBy: .local).isMissed)
    }

    func testNewestFirstAndPersistedAcrossRestarts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("calls.json")

        let log = CallLog(url: url)
        let older = CallRecord.make(detail(outgoing: true, answered: true), endedBy: .local, now: t0.addingTimeInterval(10))
        let newer = CallRecord.make(detail(outgoing: false, answered: false), endedBy: .host(.missed))
        try log.record(older)
        try log.record(newer)
        XCTAssertEqual(log.entries, [newer, older])
        XCTAssertEqual(CallLog(url: url).entries, [newer, older])

        try log.clear()
        XCTAssertTrue(CallLog(url: url).entries.isEmpty)
    }

    func testTheLogIsBounded() throws {
        let log = CallLog(url: nil)
        for _ in 0..<510 { try log.record(CallRecord.make(detail(outgoing: true, answered: false), endedBy: .local)) }
        XCTAssertEqual(log.entries.count, 500)
    }

    func testUnreadableFilesAreKeptAsideAndAFailedWriteChangesNothing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("calls.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(CallLog(url: url).entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))

        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let failing = CallLog(url: blocker.appendingPathComponent("sub/calls.json"))
        XCTAssertThrowsError(try failing.record(CallRecord.make(detail(outgoing: true, answered: false), endedBy: .local)))
        XCTAssertTrue(failing.entries.isEmpty)
    }
}
