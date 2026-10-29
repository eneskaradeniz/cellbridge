import XCTest
@testable import CellBridge

final class DialInputTests: XCTestCase {
    func testPastedNumbersLoseSpacesDashesAndBrackets() {
        XCTAssertEqual(DialInput.sanitize("+90 (532) 111-22 33"), "+905321112233")
        XCTAssertEqual(DialInput.sanitize("0532 111 22 33\n"), "05321112233")
    }

    func testPlusOnlyStaysInFront() {
        XCTAssertEqual(DialInput.sanitize("+90+532"), "+90532")
        XCTAssertEqual(DialInput.sanitize("90+532"), "90532")
    }

    func testTextWithoutDigitsBecomesEmpty() {
        XCTAssertEqual(DialInput.sanitize("call me"), "")
        XCTAssertEqual(DialInput.sanitize(""), "")
    }
}
