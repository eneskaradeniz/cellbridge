import XCTest
@testable import CellBridge

@MainActor
final class MessageCoordinatorTests: XCTestCase {
    private var sent: [ClientMessage] = []
    private var notified: [String] = []
    private var logs: [String] = []

    private func coordinator(store: MessageStore = MessageStore(url: nil)) -> MessageCoordinator {
        MessageCoordinator(store: store, transmit: { self.sent.append($0) },
                           notify: { id, _, _ in self.notified.append(id) }, log: { self.logs.append($0) })
    }

    private func sms(_ id: String, _ body: String = "selam") -> ServerMessage {
        .sms(id: id, from: "+905551112233", body: body, ts: 1_700_000_000_000)
    }

    func testAReceivedTextIsSavedAcknowledgedAndNotifiedOnce() {
        let c = coordinator()
        c.handle(sms("7"))
        XCTAssertEqual(c.conversations.count, 1)
        XCTAssertEqual(sent, [.smsAck(id: "7")])
        XCTAssertEqual(notified, ["7"])

        c.handle(sms("7")) // replay after a reconnect: acknowledged again, but not shown or notified twice
        XCTAssertEqual(c.conversations[0].messages.count, 1)
        XCTAssertEqual(sent, [.smsAck(id: "7"), .smsAck(id: "7")])
        XCTAssertEqual(notified, ["7"])
    }

    func testATextThatCannotBeSavedIsNeitherAcknowledgedNorLaterOnesUntilTheHostReplays() throws {
        // A path under a regular file cannot be written; removing the file later makes writes work again.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: blocker)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let c = coordinator(store: MessageStore(url: blocker.appendingPathComponent("messages.json")))

        c.handle(sms("5"))
        XCTAssertTrue(sent.isEmpty) // not on disk, so not acknowledged
        XCTAssertTrue(notified.isEmpty)
        XCTAssertEqual(logs.count, 1)

        try FileManager.default.removeItem(at: blocker) // writes succeed from now on
        c.handle(sms("6"))
        XCTAssertTrue(sent.isEmpty, "acking 6 would also acknowledge the lost 5")

        c.connectionLost() // the host replays 5 and 6 on the next connection
        c.handle(sms("5"))
        c.handle(sms("6"))
        XCTAssertEqual(sent, [.smsAck(id: "5"), .smsAck(id: "6")])
    }

    func testSendingQueuesTheTextAndTransmitsItWithItsClientId() throws {
        let c = coordinator()
        c.send(to: "+905551112233", body: "giden")

        guard case .smsSend(let clientId, let to, let body)? = sent.first else { return XCTFail("nothing sent") }
        XCTAssertEqual(to, "+905551112233")
        XCTAssertEqual(body, "giden")
        XCTAssertEqual(c.conversations[0].last.status, .sending)

        c.handle(.smsResult(clientId: clientId, ok: true, error: nil))
        XCTAssertEqual(c.conversations[0].last.status, .sent)
    }

    func testAFailedResultAndALostConnectionAreShown() {
        let c = coordinator()
        c.send(to: "+905551112233", body: "bir")
        c.send(to: "+905551112233", body: "iki")
        guard case .smsSend(let firstId, _, _)? = sent.first else { return XCTFail("nothing sent") }

        c.handle(.smsResult(clientId: firstId, ok: false, error: "invalid"))
        c.connectionLost() // the second never got an answer
        XCTAssertEqual(c.conversations[0].messages.map(\.status), [.failed("invalid"), .failed("not confirmed")])
    }
}
