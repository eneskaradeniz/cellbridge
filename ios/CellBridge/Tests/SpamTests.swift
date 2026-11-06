import XCTest
@testable import CellBridge

@MainActor
final class SpamTests: XCTestCase {
    private var sent: [ClientMessage] = []
    private func center() -> SpamCenter {
        sent = []
        return SpamCenter(transmit: { [unowned self] in sent.append($0) }, defaults: UserDefaults(suiteName: "spam-\(UUID().uuidString)")!)
    }

    func testSpamMessagesEncode() {
        XCTAssertEqual(ClientMessage.contactsSync(keys: ["5321234567"]).encoded(), #"{"keys":["5321234567"],"type":"contacts_sync"}"#)
        XCTAssertEqual(ClientMessage.spamReport(number: "+90555", body: "x").encoded(), #"{"body":"x","number":"+90555","type":"spam_report"}"#)
        XCTAssertEqual(ClientMessage.spamReport(number: "+90555", body: nil).encoded(), #"{"number":"+90555","type":"spam_report"}"#)
        XCTAssertEqual(ClientMessage.spamNot(number: "1").encoded(), #"{"number":"1","type":"spam_not"}"#)
        XCTAssertEqual(ClientMessage.spamSettings(strict: true).encoded(), #"{"strict":true,"type":"spam_settings"}"#)
        XCTAssertEqual(ClientMessage.spamListRequest.encoded(), #"{"type":"spam_list_request"}"#)
    }

    func testSpamListAndBlockedDecode() {
        let item = #"{"id":"c1","kind":"call","number":"0850","ts":5,"reason":"marketing"}"#
        guard case .spamList(let items, let strict, let screening) = ServerMessage.decode(#"{"type":"spam_list","items":[\#(item)],"strict":true,"screening":false}"#)
        else { return XCTFail("not a spam_list") }
        XCTAssertEqual(items, [SpamItem(id: "c1", kind: "call", number: "0850", body: nil, ts: 5, reason: "marketing")])
        XCTAssertTrue(strict)
        XCTAssertFalse(screening)
        XCTAssertEqual(ServerMessage.decode(#"{"type":"spam_blocked","item":\#(item)}"#),
                       .spamBlocked(SpamItem(id: "c1", kind: "call", number: "0850", body: nil, ts: 5, reason: "marketing")))
    }

    func testContactsAreSentOnceAsLastTenDigitsAndResentAtLogin() {
        let spam = center()
        let contacts = [Contact(id: "1", name: "A", numbers: [LabeledNumber(label: "m", value: "+90 532 123 45 67")]),
                        Contact(id: "2", name: "B", numbers: [LabeledNumber(label: "m", value: "0532 123 45 67")])]
        spam.syncContacts(contacts) // not supported yet: kept for the login
        XCTAssertTrue(sent.isEmpty)
        spam.connected(capabilities: ["spam"])
        XCTAssertEqual(sent, [.contactsSync(keys: ["5321234567"]), .spamListRequest])
        sent = []
        spam.syncContacts(contacts) // unchanged
        XCTAssertTrue(sent.isEmpty)
    }

    func testNotSpamDropsThatNumbersItemsAndAsksTheHost() {
        let spam = center()
        spam.handle(.spamList(items: [SpamItem(id: "a", kind: "sms", number: "+905321234567", body: "x", ts: 1, reason: "gambling"),
                                      SpamItem(id: "b", kind: "call", number: "05321234567", body: nil, ts: 2, reason: "reported"),
                                      SpamItem(id: "c", kind: "call", number: "08501112233", body: nil, ts: 3, reason: "marketing")],
                              strict: false, screening: true))
        spam.notSpam(spam.items[0])
        XCTAssertEqual(spam.items.map(\.id), ["c"])
        XCTAssertEqual(sent, [.spamNot(number: "+905321234567")])
    }

    func testBlockedItemIsAddedOnceAndCountsAsUnseenUntilOpened() {
        let spam = center()
        let item = SpamItem(id: "a", kind: "call", number: "1", body: nil, ts: Int64(Date().timeIntervalSince1970 * 1000), reason: "unknown")
        spam.handle(.spamBlocked(item))
        spam.handle(.spamBlocked(item))
        XCTAssertEqual(spam.items.count, 1)
        XCTAssertEqual(spam.unseen, 1)
        spam.markSeen()
        XCTAssertEqual(spam.unseen, 0)
    }
}
