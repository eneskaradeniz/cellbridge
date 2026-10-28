import CallKit
import XCTest
@testable import CellBridge

final class CallBookTests: XCTestCase {
    func testRepeatedRingForTheSameCallIsIgnored() {
        var book = CallBook()
        XCTAssertNotNil(book.ring(callId: "c1"))
        XCTAssertNil(book.ring(callId: "c1")) // the host re-sends rings after a reconnect
        XCTAssertNotNil(book.ring(callId: "c2"))
    }

    func testMapsBetweenCallKitAndHostIdentity() throws {
        var book = CallBook()
        let uuid = try XCTUnwrap(book.ring(callId: "c1"))
        XCTAssertEqual(book.callId(for: uuid), "c1")
        XCTAssertFalse(book.isAnswered(uuid))
        book.markAnswered(uuid)
        XCTAssertTrue(book.isAnswered(uuid))
    }

    func testHostEndingRemovesTheCallOnce() throws {
        var book = CallBook()
        let uuid = try XCTUnwrap(book.ring(callId: "c1"))
        XCTAssertEqual(book.end(callId: "c1"), uuid)
        XCTAssertNil(book.end(callId: "c1"))
        XCTAssertNil(book.callId(for: uuid))
    }

    func testLocalEndRemovesTheCall() throws {
        var book = CallBook()
        let uuid = try XCTUnwrap(book.ring(callId: "c1"))
        book.end(uuid: uuid)
        XCTAssertNil(book.end(callId: "c1")) // the host's later `ended` finds nothing to do
    }

    func testActiveListsRingingAndAnsweredCallsOldestFirst() throws {
        var book = CallBook()
        let first = try XCTUnwrap(book.ring(callId: "c1", title: "Ali", now: Date(timeIntervalSince1970: 100)))
        let second = try XCTUnwrap(book.ring(callId: "c2", title: "Veli", now: Date(timeIntervalSince1970: 200)))
        book.markAnswered(first, now: Date(timeIntervalSince1970: 150))

        XCTAssertEqual(book.active, [
            ActiveCall(id: first, title: "Ali", answeredAt: Date(timeIntervalSince1970: 150)),
            ActiveCall(id: second, title: "Veli", answeredAt: nil),
        ])
        XCTAssertTrue(book.active[0].isAnswered)
        XCTAssertFalse(book.active[1].isAnswered)

        book.end(uuid: first)
        XCTAssertEqual(book.active.map(\.title), ["Veli"])
    }

    func testEndReasonsMapToCallKit() {
        XCTAssertEqual(CallBook.callKitReason(for: .missed), .unanswered)
        XCTAssertEqual(CallBook.callKitReason(for: .rejected), .declinedElsewhere)
        XCTAssertEqual(CallBook.callKitReason(for: nil), .remoteEnded)
    }
}
