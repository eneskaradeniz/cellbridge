import CryptoKit
import XCTest
@testable import CellBridge

final class PushTests: XCTestCase {
    private let key = Data((0..<32).map { UInt8($0) })
    // Sealed by the Android host's PushCrypto test vector (key 0..31, nonce 100..111): the two phones must agree on the bytes.
    private let hostBox = "ZGVmZ2hpamtsbW5vMzm9BxWFH/ocWH2L91FY327gaH/mDpYAheuOY8KTkH2h2HHxfiCoN9/fWlGcL6/tIXnZi0loPNFvnaLTME9cyiEDfKyeXRM="

    func testOpensABoxSealedByTheHost() {
        XCTAssertEqual(PushSeal.open(hostBox, key: key), PushSeal.Call(callId: "c-42", number: "+905551112233", name: "Ali"))
    }

    func testRoundTripsAndOptionalFieldsStayOptional() throws {
        let call = PushSeal.Call(callId: "c-7", number: nil, name: nil)
        XCTAssertEqual(PushSeal.open(try PushSeal.seal(call, key: key), key: key), call)
    }

    func testAnotherKeyOrDamageOpensToNothing() throws {
        XCTAssertNil(PushSeal.open(hostBox, key: Data(repeating: 9, count: 32)))
        var bytes = Data(base64Encoded: hostBox)!
        bytes[20] ^= 1
        XCTAssertNil(PushSeal.open(bytes.base64EncodedString(), key: key))
        XCTAssertNil(PushSeal.open("not base64 !!", key: key))
        XCTAssertNil(PushSeal.open(hostBox, key: Data(repeating: 1, count: 5)))
    }

    func testTheCallUUIDIsStableAndPerCall() {
        XCTAssertEqual(CallBook.incomingUUID(forCallId: "c-1"), CallBook.incomingUUID(forCallId: "c-1"))
        XCTAssertNotEqual(CallBook.incomingUUID(forCallId: "c-1"), CallBook.incomingUUID(forCallId: "c-2"))
    }

    func testARingAfterThePushIsTheSameCall() {
        var book = CallBook()
        let first = book.ring(callId: "c-1")
        XCTAssertEqual(first, CallBook.incomingUUID(forCallId: "c-1"))
        XCTAssertNil(book.ring(callId: "c-1")) // the connection's own ring for the call the push already showed
    }

    func testPushTokenMessageMatchesTheProtocol() throws {
        let text = ClientMessage.pushToken(token: "ab12", env: "sandbox", topic: "com.x.cellbridge.voip", key: "S0VZ", alertToken: nil, alertTopic: nil).encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(object, ["type": "push_token", "token": "ab12", "env": "sandbox", "topic": "com.x.cellbridge.voip", "key": "S0VZ"])
    }

    func testPushTokenMessageCarriesTheTextTokenWhenThereIsOne() throws {
        let text = ClientMessage.pushToken(token: "ab12", env: "sandbox", topic: "com.x.cellbridge.voip", key: "S0VZ",
                                           alertToken: "cd34", alertTopic: "com.x.cellbridge").encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(object["alert_token"], "cd34")
        XCTAssertEqual(object["alert_topic"], "com.x.cellbridge")
    }

    func testATextRoundTripsAndKeepsItsTimeToTheMillisecond() throws {
        let text = PushSeal.Text(id: "1793", from: "+905551112233", body: "Merhaba, nasılsın? 👋", date: Date(timeIntervalSince1970: 1_700_000_000.123))
        let opened = try XCTUnwrap(PushSeal.openText(try PushSeal.seal(text, key: key), key: key))
        XCTAssertEqual(opened.id, "1793")
        XCTAssertEqual(opened.from, "+905551112233")
        XCTAssertEqual(opened.body, "Merhaba, nasılsın? 👋")
        XCTAssertEqual(opened.date.timeIntervalSince1970, 1_700_000_000.123, accuracy: 0.001)
    }

    func testATextBoxIsNotACallAndTheOtherWayRound() throws {
        let text = PushSeal.Text(id: "1", from: "+90555", body: "x", date: Date())
        XCTAssertNil(PushSeal.open(try PushSeal.seal(text, key: key), key: key))
        XCTAssertNil(PushSeal.openText(hostBox, key: key))
        XCTAssertNil(PushSeal.openText(try PushSeal.seal(text, key: key), key: Data(repeating: 9, count: 32)))
    }

    func testPushedTextsAreRememberedAndOnlyTheNewestKept() {
        let id = "test-\(UUID().uuidString)"
        XCTAssertFalse(PushedTexts.contains(id))
        PushedTexts.insert(id)
        XCTAssertTrue(PushedTexts.contains(id))
        for n in 0..<210 { PushedTexts.insert("filler-\(n)") }
        XCTAssertFalse(PushedTexts.contains(id)) // pushed out by the 200 newer ones
        XCTAssertTrue(PushedTexts.contains("filler-209"))
    }

    func testTheKeyIsCreatedOnceAndStaysTheSame() {
        let first = PushKeyStore.key()
        XCTAssertEqual(first.count, 32)
        XCTAssertEqual(PushKeyStore.key(), first)
        XCTAssertEqual(PushKeyStore.existing(), first)
    }
}
