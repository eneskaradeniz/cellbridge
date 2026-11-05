import XCTest
@testable import CellBridge

final class MessagesTests: XCTestCase {
    func testDecodesTheCallListAndALaterCapabilityList() {
        XCTAssertEqual(ServerMessage.decode(#"{"type":"call_list","callIds":["a","b"]}"#), .callList(callIds: ["a", "b"]))
        XCTAssertEqual(ServerMessage.decode(#"{"type":"call_list","callIds":[]}"#), .callList(callIds: []))
        XCTAssertNil(ServerMessage.decode(#"{"type":"call_list"}"#))
        XCTAssertEqual(ServerMessage.decode(#"{"type":"capabilities","capabilities":["calls","audio"]}"#), .capabilities(["calls", "audio"]))
    }

    func testHelloCarriesVersionAndToken() {
        XCTAssertEqual(ClientMessage.hello(token: "ABC23456").encoded(), #"{"token":"ABC23456","type":"hello","version":1}"#)
    }

    func testAnswerOmitsAbsentUdpPortAndIncludesPresentOne() {
        XCTAssertEqual(ClientMessage.answer(callId: "c1", udpPort: nil).encoded(), #"{"callId":"c1","type":"answer"}"#)
        XCTAssertEqual(ClientMessage.answer(callId: "c1", udpPort: 40123).encoded(), #"{"callId":"c1","type":"answer","udpPort":40123}"#)
    }

    func testRejectAndHangup() {
        XCTAssertEqual(ClientMessage.reject(callId: "c1").encoded(), #"{"callId":"c1","type":"reject"}"#)
        XCTAssertEqual(ClientMessage.hangup(callId: "c1").encoded(), #"{"callId":"c1","type":"hangup"}"#)
    }

    func testDecodesHelloAckWithCapabilities() {
        XCTAssertEqual(ServerMessage.decode(#"{"type":"hello_ack","version":1,"capabilities":["calls","audio"]}"#),
                       .helloAck(version: 1, capabilities: ["calls", "audio"]))
    }

    func testDecodesRingWithAndWithoutOptionalFields() {
        XCTAssertEqual(ServerMessage.decode(#"{"type":"ring","callId":"c1"}"#), .ring(callId: "c1", number: nil, name: nil))
        XCTAssertEqual(ServerMessage.decode(#"{"type":"ring","callId":"c1","number":"+90555","name":"Ali"}"#),
                       .ring(callId: "c1", number: "+90555", name: "Ali"))
    }

    func testDecodesEndedReasons() {
        XCTAssertEqual(ServerMessage.decode(#"{"type":"ended","callId":"c1"}"#), .ended(callId: "c1", reason: nil))
        XCTAssertEqual(ServerMessage.decode(#"{"type":"ended","callId":"c1","reason":"missed"}"#), .ended(callId: "c1", reason: .missed))
        XCTAssertEqual(ServerMessage.decode(#"{"type":"ended","callId":"c1","reason":"rejected"}"#), .ended(callId: "c1", reason: .rejected))
        XCTAssertEqual(ServerMessage.decode(#"{"type":"ended","callId":"c1","reason":"future"}"#), .ended(callId: "c1", reason: nil))
    }

    func testDecodesError() {
        XCTAssertEqual(ServerMessage.decode(#"{"type":"error","code":"unauthorized"}"#), .error(code: "unauthorized", message: nil))
    }

    func testIgnoresUnknownTypesAndGarbage() {
        XCTAssertNil(ServerMessage.decode(#"{"type":"sms","id":"1"}"#))
        XCTAssertNil(ServerMessage.decode("not json"))
        XCTAssertNil(ServerMessage.decode(#"{"type":"ring"}"#))
    }

    func testSmsAckAndSendEncoding() {
        XCTAssertEqual(ClientMessage.smsAck(id: "7").encoded(), #"{"id":"7","type":"sms_ack"}"#)
        XCTAssertEqual(ClientMessage.smsSend(clientId: "k1", to: "+90555", body: "selam").encoded(),
                       #"{"body":"selam","clientId":"k1","to":"+90555","type":"sms_send"}"#)
    }

    func testDecodesSmsAndItsResult() {
        XCTAssertEqual(ServerMessage.decode(#"{"type":"sms","id":"7","from":"+90555","body":"selam","ts":1700000000000}"#),
                       .sms(id: "7", from: "+90555", body: "selam", ts: 1_700_000_000_000))
        XCTAssertEqual(ServerMessage.decode(#"{"type":"sms_result","clientId":"k1","ok":true}"#),
                       .smsResult(clientId: "k1", ok: true, error: nil))
        XCTAssertEqual(ServerMessage.decode(#"{"type":"sms_result","clientId":"k1","ok":false,"error":"invalid"}"#),
                       .smsResult(clientId: "k1", ok: false, error: "invalid"))
        XCTAssertNil(ServerMessage.decode(#"{"type":"sms","id":"7"}"#))
    }

    func testDialEncodingWithAndWithoutUdpPort() {
        XCTAssertEqual(ClientMessage.dial(clientId: "d1", number: "+90555", udpPort: nil).encoded(),
                       #"{"clientId":"d1","number":"+90555","type":"dial"}"#)
        XCTAssertEqual(ClientMessage.dial(clientId: "d1", number: "+90555", udpPort: 40000).encoded(),
                       #"{"clientId":"d1","number":"+90555","type":"dial","udpPort":40000}"#)
    }

    func testDecodesDialResultAndAnswered() {
        XCTAssertEqual(ServerMessage.decode(#"{"type":"dial_result","clientId":"d1","ok":true,"callId":"o1"}"#),
                       .dialResult(clientId: "d1", ok: true, callId: "o1", error: nil))
        XCTAssertEqual(ServerMessage.decode(#"{"type":"dial_result","clientId":"d1","ok":false,"error":"emergency"}"#),
                       .dialResult(clientId: "d1", ok: false, callId: nil, error: "emergency"))
        XCTAssertEqual(ServerMessage.decode(#"{"type":"answered","callId":"o1"}"#), .answered(callId: "o1"))
        XCTAssertNil(ServerMessage.decode(#"{"type":"dial_result","ok":true}"#))
    }
}
