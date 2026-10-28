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

    func testOutgoingCallExistsBeforeTheHostKnowsItsId() throws {
        var book = CallBook()
        let uuid = UUID()
        book.startOutgoing(uuid, title: "Ali", now: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(book.isOutgoing(uuid))
        XCTAssertNil(book.callId(for: uuid))
        XCTAssertEqual(book.active.map(\.title), ["Ali"])

        XCTAssertFalse(book.attach(callId: "o1", to: uuid)) // nobody hung up meanwhile
        XCTAssertEqual(book.callId(for: uuid), "o1")
        XCTAssertEqual(book.uuid(forCallId: "o1"), uuid)

        book.markAnswered(uuid)
        XCTAssertTrue(book.isAnswered(uuid))
        XCTAssertEqual(book.end(callId: "o1"), uuid)
    }

    func testHangingUpWhileDialingIsRememberedUntilTheCallIdArrives() {
        var book = CallBook()
        let uuid = UUID()
        book.startOutgoing(uuid, title: "Ali")
        book.requestEnd(uuid)
        XCTAssertTrue(book.attach(callId: "o1", to: uuid)) // now the host must be told to hang up
    }

    func testAFailedDialLeavesNothingBehind() {
        var book = CallBook()
        let uuid = UUID()
        book.startOutgoing(uuid, title: "Ali")
        book.end(uuid: uuid)
        XCTAssertTrue(book.active.isEmpty)
        XCTAssertFalse(book.attach(callId: "late", to: uuid)) // a stray late result changes nothing
        XCTAssertNil(book.uuid(forCallId: "late"))
    }

    func testIncomingCallsAreNotOutgoingAndRingsStillDedupe() throws {
        var book = CallBook()
        let uuid = try XCTUnwrap(book.ring(callId: "c1"))
        XCTAssertFalse(book.isOutgoing(uuid))
        XCTAssertNil(book.ring(callId: "c1"))
        let outgoing = UUID()
        book.startOutgoing(outgoing, title: "Ali") // an outgoing call without an id never blocks a ring
        XCTAssertNotNil(book.ring(callId: "c2"))
    }
}

final class DialErrorTests: XCTestCase {
    func testEveryHostErrorHasAWordedMessage() {
        XCTAssertTrue(CallCoordinator.message(forDialError: "emergency").contains("Emergency"))
        XCTAssertTrue(CallCoordinator.message(forDialError: "invalid").contains("valid"))
        XCTAssertTrue(CallCoordinator.message(forDialError: "busy").contains("progress"))
        XCTAssertEqual(CallCoordinator.message(forDialError: "failed"), CallCoordinator.message(forDialError: nil))
        XCTAssertEqual(CallCoordinator.message(forDialError: "something new"), CallCoordinator.message(forDialError: "failed"))
    }
}
