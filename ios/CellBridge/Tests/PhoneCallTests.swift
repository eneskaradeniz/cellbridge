import XCTest
@testable import CellBridge

final class PhoneCallTests: XCTestCase {
    func testCallStateDecodes() {
        let text = #"{"type":"call_state","calls":[{"callId":"c1","number":"+90555","direction":"out","status":"active","connectedAt":1700000000000,"onClient":false},{"callId":"c2","direction":"in","status":"ringing","onClient":true}]}"#
        guard case .callState(let calls) = ServerMessage.decode(text) else { return XCTFail("not a call_state") }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0], PhoneCall(callId: "c1", number: "+90555", outgoing: true, status: .active,
                                           connectedAt: Date(timeIntervalSince1970: 1_700_000_000), onClient: false))
        XCTAssertEqual(calls[1].status, .ringing)
        XCTAssertNil(calls[1].connectedAt)
        XCTAssertTrue(calls[1].onClient)
    }

    func testAnUnknownStatusIsLeftOut() {
        let text = #"{"type":"call_state","calls":[{"callId":"c1","direction":"in","status":"weird","onClient":false}]}"#
        guard case .callState(let calls) = ServerMessage.decode(text) else { return XCTFail("not a call_state") }
        XCTAssertTrue(calls.isEmpty)
    }

    func testOnlyActiveCallsStillOnThePhoneAndNotKnownAreTakeable() {
        func call(_ id: String, _ status: PhoneCall.Status, onClient: Bool = false) -> PhoneCall {
            PhoneCall(callId: id, number: nil, outgoing: false, status: status, connectedAt: nil, onClient: onClient)
        }
        let all = [call("ringing", .ringing), call("dialing", .dialing), call("active", .active), call("held", .holding),
                   call("carried", .active, onClient: true), call("mine", .active)]
        let takeable = PhoneCall.takeable(all, knows: { $0 == "mine" })
        XCTAssertEqual(takeable.map(\.callId), ["active"]) // a held call cannot be resumed from here, so it stays on the phone
    }

    func testClientMessagesMatchTheProtocol() throws {
        func object(_ m: ClientMessage) throws -> [String: String] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(m.encoded().utf8)) as? [String: String])
        }
        XCTAssertEqual(try object(.callStateRequest), ["type": "call_state_request"])
        XCTAssertEqual(try object(.transferRequest(callId: "c1")), ["type": "transfer_request", "callId": "c1"])
    }
}
