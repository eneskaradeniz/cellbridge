import XCTest
@testable import CellBridge

final class HistoryProtocolTests: XCTestCase {
    func testCallLogDecodes() {
        let text = #"{"type":"call_log","entries":[{"id":"11","number":"+90555","name":"Ali","kind":"missed","ts":1000,"duration":0},{"id":"12","number":"+90556","kind":"outgoing","ts":2000,"duration":31}]}"#
        XCTAssertEqual(ServerMessage.decode(text), .callLog(entries: [
            HostCall(id: "11", number: "+90555", name: "Ali", kind: "missed", ts: 1000, duration: 0),
            HostCall(id: "12", number: "+90556", name: nil, kind: "outgoing", ts: 2000, duration: 31),
        ]))
    }

    func testSmsHistoryDecodes() {
        let text = #"{"type":"sms_history","items":[{"id":"1793","peer":"+90555","body":"merhaba","ts":1000,"dir":"in"},{"id":"out-7","peer":"+90555","body":"selam","ts":2000,"dir":"out"}]}"#
        XCTAssertEqual(ServerMessage.decode(text), .smsHistory(items: [
            HostText(id: "1793", peer: "+90555", body: "merhaba", ts: 1000, outgoing: false),
            HostText(id: "out-7", peer: "+90555", body: "selam", ts: 2000, outgoing: true),
        ]))
    }

    func testRingAckEncodes() {
        XCTAssertEqual(ClientMessage.ringAck(callId: "c1").encoded(), #"{"callId":"c1","type":"ring_ack"}"#)
    }

    func testDtmfEncodes() {
        XCTAssertEqual(ClientMessage.dtmf(callId: "c1", digit: "5").encoded(), #"{"callId":"c1","digit":"5","type":"dtmf"}"#)
    }

    func testTransferMessagesRoundTrip() {
        XCTAssertEqual(ClientMessage.transferToHost(callId: "c1").encoded(), #"{"callId":"c1","type":"transfer_to_host"}"#)
        XCTAssertEqual(ClientMessage.transferAccept(callId: "c1", udpPort: 4000).encoded(), #"{"callId":"c1","type":"transfer_accept","udpPort":4000}"#)
        XCTAssertEqual(ServerMessage.decode(#"{"type":"transfer_result","callId":"c1","ok":true}"#), .transferResult(callId: "c1", ok: true))
        XCTAssertEqual(ServerMessage.decode(#"{"type":"transfer_offer","callId":"c1","number":"+90555"}"#), .transferOffer(callId: "c1", number: "+90555", connectedAt: nil))
        XCTAssertEqual(ServerMessage.decode(#"{"type":"transfer_offer","callId":"c1"}"#), .transferOffer(callId: "c1", number: nil, connectedAt: nil))
        XCTAssertEqual(ServerMessage.decode(#"{"type":"transfer_offer","callId":"c1","connectedAt":1700000000000}"#),
                       .transferOffer(callId: "c1", number: nil, connectedAt: 1_700_000_000_000))
    }

    func testRequestsEncode() {
        XCTAssertEqual(ClientMessage.callLogRequest(after: "10", since: nil).encoded(), #"{"after":"10","type":"call_log_request"}"#)
        XCTAssertEqual(ClientMessage.callLogRequest(after: nil, since: 500).encoded(), #"{"since":500,"type":"call_log_request"}"#)
        XCTAssertEqual(ClientMessage.smsHistoryRequest(since: 5).encoded(), #"{"since":5,"type":"sms_history_request"}"#)
    }
}

final class CallLogMergeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    private func host(_ id: String, _ number: String = "+905551112233", kind: String = "incoming", at: Date, duration: Int = 10) -> HostCall {
        HostCall(id: id, number: number, name: nil, kind: kind, ts: ms(at), duration: duration)
    }

    func testMissedCallsFromWhileAwayAreAdded() throws {
        let log = CallLog(url: nil)
        XCTAssertEqual(try log.merge(host: [host("5", kind: "missed", at: t0, duration: 0)]), 1)
        XCTAssertEqual(log.entries.first?.outcome, .missed)
        XCTAssertEqual(log.entries.first?.hostId, "5")
        XCTAssertEqual(log.entries.first?.date, t0)
    }

    func testAKnownCallIsNotAddedTwice() throws {
        let log = CallLog(url: nil)
        try log.merge(host: [host("5", at: t0)])
        XCTAssertEqual(try log.merge(host: [host("5", at: t0)]), 0)
        XCTAssertEqual(log.entries.count, 1)
    }

    func testACallSeenLiveAdoptsThePhonesId() throws {
        let log = CallLog(url: nil)
        let live = CallRecord(id: UUID(), number: "0555 111 22 33", title: "Ali", direction: .incoming, outcome: .answered,
                              date: t0.addingTimeInterval(4), duration: 60)
        try log.record(live)
        XCTAssertEqual(try log.merge(host: [host("9", at: t0)]), 0) // same number (any format), same direction, 4 s apart
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries.first?.hostId, "9")
        XCTAssertEqual(log.entries.first?.id, live.id)
    }

    func testDifferentDirectionOrTimeStaysSeparate() throws {
        let log = CallLog(url: nil)
        try log.record(CallRecord(id: UUID(), number: "+905551112233", title: "x", direction: .outgoing, outcome: .answered,
                                  date: t0, duration: 5))
        XCTAssertEqual(try log.merge(host: [host("1", at: t0)]), 1) // incoming at the same time: another call
        XCTAssertEqual(try log.merge(host: [host("2", kind: "outgoing", at: t0.addingTimeInterval(600))]), 1) // 10 min later
        XCTAssertEqual(log.entries.count, 3)
    }

    func testOutcomesFollowTheKind() throws {
        let log = CallLog(url: nil)
        try log.merge(host: [
            host("1", kind: "outgoing", at: t0, duration: 0),
            host("2", kind: "outgoing", at: t0.addingTimeInterval(1000), duration: 30),
            host("3", kind: "rejected", at: t0.addingTimeInterval(2000), duration: 0),
        ])
        let byId = Dictionary(uniqueKeysWithValues: log.entries.map { ($0.hostId ?? "", $0.outcome) })
        XCTAssertEqual(byId["1"], .noAnswer)
        XCTAssertEqual(byId["2"], .answered)
        XCTAssertEqual(byId["3"], .declined)
    }

    func testEntriesStayNewestFirst() throws {
        let log = CallLog(url: nil)
        try log.merge(host: [host("1", at: t0), host("2", "+905559998877", at: t0.addingTimeInterval(100))])
        XCTAssertEqual(log.entries.map(\.hostId), ["2", "1"])
    }
}

final class MessageHistoryMergeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    func testOldTextsAreAddedAsRead() throws {
        let store = MessageStore(url: nil)
        let added = try store.mergeHistory([
            HostText(id: "1793", peer: "+905551112233", body: "merhaba", ts: ms(t0), outgoing: false),
            HostText(id: "out-7", peer: "+905551112233", body: "selam", ts: ms(t0.addingTimeInterval(5)), outgoing: true),
        ])
        XCTAssertEqual(added, 2)
        XCTAssertEqual(store.messages.map(\.body), ["merhaba", "selam"])
        XCTAssertTrue(store.messages.allSatisfy(\.isRead))
        XCTAssertEqual(store.conversations.first?.unreadCount, 0)
    }

    func testATextSeenLiveIsNotAddedAgain() throws {
        let store = MessageStore(url: nil)
        try store.receive(hostId: "1793", from: "+905551112233", body: "merhaba", date: t0)
        XCTAssertEqual(try store.mergeHistory([HostText(id: "1793", peer: "+905551112233", body: "merhaba", ts: ms(t0), outgoing: false)]), 0)
        XCTAssertEqual(store.messages.count, 1)
    }

    func testATextSentFromHereIsNotAddedAgain() throws {
        let store = MessageStore(url: nil)
        _ = try store.queueOutgoing(to: "0555 111 22 33", body: "selam", date: t0)
        let host = HostText(id: "out-7", peer: "+905551112233", body: "selam", ts: ms(t0.addingTimeInterval(30)), outgoing: true)
        XCTAssertEqual(try store.mergeHistory([host]), 0)
        XCTAssertEqual(store.messages.count, 1)
    }

    func testMergingTwiceChangesNothing() throws {
        let store = MessageStore(url: nil)
        let items = [HostText(id: "1", peer: "+905551112233", body: "a", ts: ms(t0), outgoing: false),
                     HostText(id: "out-2", peer: "+905551112233", body: "b", ts: ms(t0.addingTimeInterval(500)), outgoing: true)]
        try store.mergeHistory(items)
        XCTAssertEqual(try store.mergeHistory(items), 0)
        XCTAssertEqual(store.messages.count, 2)
    }
}
