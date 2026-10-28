import XCTest
@testable import CellBridge

final class MessageStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testReceivingTheSameHostIdTwiceStoresItOnce() throws {
        let store = MessageStore(url: nil)
        XCTAssertTrue(try store.receive(hostId: "7", from: "+905551112233", body: "selam", date: t0))
        XCTAssertFalse(try store.receive(hostId: "7", from: "+905551112233", body: "selam", date: t0)) // replay after reconnect
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages[0].status, .received)
    }

    func testOutgoingLifecycleSentAndFailed() throws {
        let store = MessageStore(url: nil)
        let ok = try store.queueOutgoing(to: "+905551112233", body: "bir")
        let bad = try store.queueOutgoing(to: "+905551112233", body: "iki")
        XCTAssertEqual(store.messages.map(\.status), [.sending, .sending])

        try store.apply(clientId: ok.id, ok: true, error: nil)
        try store.apply(clientId: bad.id, ok: false, error: "invalid")
        XCTAssertEqual(store.messages.map(\.status), [.sent, .failed("invalid")])
    }

    func testAResultForAnUnknownOrFinishedSendChangesNothing() throws {
        let store = MessageStore(url: nil)
        let sent = try store.queueOutgoing(to: "+905551112233", body: "bir")
        try store.apply(clientId: sent.id, ok: true, error: nil)
        try store.apply(clientId: sent.id, ok: false, error: "late duplicate") // must not flip a finished send
        try store.apply(clientId: "nope", ok: true, error: nil)
        XCTAssertEqual(store.messages.map(\.status), [.sent])
    }

    func testLosingTheConnectionMarksOnlyPendingSendsAsUnconfirmed() throws {
        let store = MessageStore(url: nil)
        let done = try store.queueOutgoing(to: "+905551112233", body: "bir")
        _ = try store.queueOutgoing(to: "+905551112233", body: "iki")
        try store.apply(clientId: done.id, ok: true, error: nil)
        try store.receive(hostId: "1", from: "+905551112233", body: "gelen", date: t0)

        try store.failPending(reason: "not confirmed")
        XCTAssertEqual(store.messages.map(\.status), [.sent, .failed("not confirmed"), .received])
    }

    func testConversationsGroupByNumberFormatAndSortByLatest() throws {
        let store = MessageStore(url: nil)
        try store.receive(hostId: "1", from: "+90 555 111 22 33", body: "a", date: t0)
        _ = try store.queueOutgoing(to: "0555 111 22 33", body: "b", date: t0.addingTimeInterval(10)) // same person, local format
        try store.receive(hostId: "2", from: "+905559998877", body: "c", date: t0.addingTimeInterval(20))

        let conversations = store.conversations
        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(conversations[0].last.body, "c") // newest conversation first
        XCTAssertEqual(conversations[1].messages.map(\.body), ["a", "b"])
    }

    func testShortSenderNamesStayDistinct() {
        XCTAssertEqual(MessageStore.key(for: "BANKA"), "banka")
        XCTAssertNotEqual(MessageStore.key(for: "BANKA"), MessageStore.key(for: "TURKCELL"))
        XCTAssertEqual(MessageStore.key(for: "+90 555 111 22 33"), MessageStore.key(for: "0555 111 22 33"))
    }

    func testPersistsAcrossRestartsAndKeepsUnreadableFilesAside() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("messages.json")

        let first = MessageStore(url: url)
        try first.receive(hostId: "7", from: "+905551112233", body: "kalici", date: t0)
        let second = MessageStore(url: url)
        XCTAssertEqual(second.messages, first.messages)
        XCTAssertFalse(try second.receive(hostId: "7", from: "+905551112233", body: "kalici", date: t0)) // still deduped after a restart

        try Data("not json".utf8).write(to: url)
        let third = MessageStore(url: url)
        XCTAssertTrue(third.messages.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
    }

    func testAFailedWriteLeavesNothingStoredSoTheHostWillResend() throws {
        // A path under a regular file cannot be created as a directory, so every write fails.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = MessageStore(url: file.appendingPathComponent("sub/messages.json"))

        XCTAssertThrowsError(try store.receive(hostId: "7", from: "+905551112233", body: "x", date: t0))
        XCTAssertTrue(store.messages.isEmpty)
    }
}
