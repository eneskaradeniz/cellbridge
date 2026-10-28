import XCTest
@testable import CellBridge

final class EventLogTests: XCTestCase {
    private func temporaryLog(maxBytes: Int = 200_000) -> (EventLog, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("events.log")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (EventLog(url: url, maxBytes: maxBytes), url)
    }

    func testRecentReturnsTheNewestLinesOldestFirst() {
        let (log, _) = temporaryLog()
        for i in 1...5 { log.append("line \(i)") }
        XCTAssertEqual(log.recent(3), ["line 3", "line 4", "line 5"])
        XCTAssertEqual(log.recent(50).count, 5)
    }

    func testAMissingFileIsAnEmptyLog() {
        let (log, _) = temporaryLog()
        XCTAssertEqual(log.recent(10), [])
    }

    func testLinesSurviveANewInstance() {
        let (log, url) = temporaryLog()
        log.append("before the restart")
        XCTAssertEqual(log.recent(1), ["before the restart"]) // also waits for the write
        XCTAssertEqual(EventLog(url: url).recent(10), ["before the restart"])
    }

    func testTheOlderHalfIsDroppedOnceTheLimitIsPassed() {
        let (log, url) = temporaryLog(maxBytes: 400)
        for i in 1...100 { log.append("event number \(i)") }
        let lines = log.recent(1_000)
        XCTAssertLessThan(lines.count, 100)
        XCTAssertEqual(lines.last, "event number 100") // the newest always stays
        XCTAssertEqual(lines.first.map { Int($0.dropFirst("event number ".count)) ?? 0 }.map { $0 > 1 }, true)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertLessThan(size, 800)
    }
}
