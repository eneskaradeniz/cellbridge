import XCTest
@testable import CellBridge

@MainActor
final class BonjourAnnouncementTests: XCTestCase {
    func testTakesTheFirstValidAddress() {
        XCTAssertEqual(BonjourDiscovery.announcedAddress("203.0.113.9,203.0.113.10"), "203.0.113.9")
    }

    func testIgnoresJunkAndEmpty() {
        XCTAssertNil(BonjourDiscovery.announcedAddress(nil))
        XCTAssertNil(BonjourDiscovery.announcedAddress(""))
        XCTAssertNil(BonjourDiscovery.announcedAddress("not an address,"))
        XCTAssertEqual(BonjourDiscovery.announcedAddress("junk, 203.0.113.9"), "203.0.113.9")
    }
}
