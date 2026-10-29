import XCTest
@testable import CellBridge

final class HostAddressTests: XCTestCase {
    func testEmptyMeansAutomatic() {
        XCTAssertTrue(HostAddress.isValid(""))
        XCTAssertTrue(HostAddress.isValid("  "))
    }

    func testIPv4AndHostNamesAreAccepted() {
        XCTAssertTrue(HostAddress.isValid("192.168.43.1"))
        XCTAssertTrue(HostAddress.isValid(" 192.168.1.155 "))
        XCTAssertTrue(HostAddress.isValid("phone.local"))
    }

    func testTyposAreRejected() {
        XCTAssertFalse(HostAddress.isValid("192.168.43"))
        XCTAssertFalse(HostAddress.isValid("999.1.1.1"))
        XCTAssertFalse(HostAddress.isValid("192.168.43.1:8765"))
        XCTAssertFalse(HostAddress.isValid("my phone"))
        XCTAssertFalse(HostAddress.isValid("a..b"))
    }
}

final class SmsLengthTests: XCTestCase {
    func testShortPlainTextIsOneSms() {
        XCTAssertEqual(SmsLength.measure("hello"), .init(units: 5, perMessage: 160, parts: 1))
        XCTAssertEqual(SmsLength.measure("").parts, 0)
    }

    func testLongPlainTextSplitsAt153() {
        let measure = SmsLength.measure(String(repeating: "a", count: 161))
        XCTAssertEqual(measure.perMessage, 153)
        XCTAssertEqual(measure.parts, 2)
    }

    func testExtendedCharactersCountTwice() {
        XCTAssertEqual(SmsLength.measure("€").units, 2)
    }

    func testTurkishLettersSwitchToTheShortLimit() {
        let measure = SmsLength.measure("Akşam görüşelim mi?")
        XCTAssertEqual(measure.perMessage, 70)
        XCTAssertEqual(measure.parts, 1)
        XCTAssertEqual(SmsLength.measure(String(repeating: "ş", count: 71)).parts, 2)
    }
}
