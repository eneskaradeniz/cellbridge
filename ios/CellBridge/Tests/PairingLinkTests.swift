import XCTest
@testable import CellBridge

final class PairingLinkTests: XCTestCase {
    func testAFullLinkParses() {
        let link = PairingLink.parse("cellbridge://pair?code=ab12cd34&id=1234-abcd&port=8765&host=192.168.1.155")
        XCTAssertEqual(link, PairingLink(code: "AB12CD34", deviceId: "1234-abcd", host: "192.168.1.155", port: 8765))
    }

    func testHostAndPortAreOptional() {
        XCTAssertEqual(PairingLink.parse("cellbridge://pair?code=AB12CD34&id=x"), PairingLink(code: "AB12CD34", deviceId: "x", host: nil, port: 8765))
    }

    func testABadAddressIsDroppedNotTrusted() {
        XCTAssertNil(PairingLink.parse("cellbridge://pair?code=AB12CD34&id=x&host=evil%20host")?.host)
    }

    func testOtherThingsAreRefused() {
        XCTAssertNil(PairingLink.parse("https://example.com/pair?code=AB12CD34&id=x"))
        XCTAssertNil(PairingLink.parse("cellbridge://call?code=AB12CD34&id=x"))
        XCTAssertNil(PairingLink.parse("cellbridge://pair?id=x"))
        XCTAssertNil(PairingLink.parse("cellbridge://pair?code=AB&id=x"))
        XCTAssertNil(PairingLink.parse("cellbridge://pair?code=AB12!D34&id=x"))
        XCTAssertNil(PairingLink.parse("not a link"))
    }
}
