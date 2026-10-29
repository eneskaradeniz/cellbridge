import XCTest
@testable import CellBridge

final class MessageReadStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testIncomingStartsUnreadAndOurOwnTextsAreRead() throws {
        let store = MessageStore(url: nil)
        try store.receive(hostId: "1", from: "+905551112233", body: "hi", date: t0)
        _ = try store.queueOutgoing(to: "+905551112233", body: "yo", date: t0.addingTimeInterval(1))
        let conversation = try XCTUnwrap(store.conversations.first)
        XCTAssertEqual(conversation.unreadCount, 1)
        try store.markRead(key: conversation.key)
        XCTAssertEqual(store.conversations.first?.unreadCount, 0)
        try store.markUnread(key: conversation.key)
        XCTAssertEqual(store.conversations.first?.unreadCount, 1)
    }

    func testTextsSavedBeforeTheFieldExistedDecodeAsRead() throws {
        let json = #"[{"id":"a","peer":"1","body":"x","date":"2026-01-01T00:00:00Z","direction":"incoming","status":{"received":{}}}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let messages = try decoder.decode([TextMessage].self, from: Data(json.utf8))
        XCTAssertTrue(messages[0].isRead)
    }

    func testRemoveConversationKeepsTheOthers() throws {
        let store = MessageStore(url: nil)
        try store.receive(hostId: "1", from: "+905551112233", body: "a", date: t0)
        try store.receive(hostId: "2", from: "+905559998877", body: "b", date: t0)
        try store.removeConversation(key: MessageStore.key(for: "+905551112233"))
        XCTAssertEqual(store.conversations.map(\.peer), ["+905559998877"])
    }

    func testRemoveByIdForgetsOnlyThatText() throws {
        let store = MessageStore(url: nil)
        try store.receive(hostId: "1", from: "+905551112233", body: "a", date: t0)
        try store.receive(hostId: "2", from: "+905551112233", body: "b", date: t0.addingTimeInterval(1))
        try store.remove(ids: ["in-1"])
        XCTAssertEqual(store.messages.map(\.body), ["b"])
    }
}

final class RecentGroupTests: XCTestCase {
    private func record(_ number: String, _ outcome: CallRecord.Outcome = .answered, _ direction: CallRecord.Direction = .incoming) -> CallRecord {
        CallRecord(id: UUID(), number: number, title: number, direction: direction, outcome: outcome, date: Date(), duration: 1)
    }

    func testConsecutiveCallsFromTheSameNumberShareARow() {
        let groups = RecentGroup.group([record("1"), record("1"), record("2"), record("1")])
        XCTAssertEqual(groups.map(\.records.count), [2, 1, 1])
    }

    func testMissedAndAnsweredCallsStaySeparate() {
        XCTAssertEqual(RecentGroup.group([record("1", .missed), record("1", .answered)]).count, 2)
        XCTAssertEqual(RecentGroup.group([record("1", .answered, .incoming), record("1", .noAnswer, .outgoing)]).count, 2)
    }

    func testCallsWithoutANumberNeverJoin() {
        XCTAssertEqual(RecentGroup.group([record(""), record("")]).count, 2)
    }
}

final class MessageLinksTests: XCTestCase {
    private func links(_ text: String) -> [String] {
        MessageLinks.attributed(text).runs.compactMap { $0.link?.absoluteString }
    }

    func testPhoneNumbersBecomeTelLinks() {
        XCTAssertEqual(links("Ara: 0532 111 22 33 olur mu"), ["tel:05321112233"])
    }

    func testWebAddressesStayWebLinks() {
        XCTAssertEqual(links("bak https://example.com/x"), ["https://example.com/x"])
    }

    func testPlainTextHasNoLinks() {
        XCTAssertEqual(links("see you at nine"), [])
    }
}
