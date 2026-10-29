import XCTest
@testable import CellBridge

final class HostStatusTests: XCTestCase {
    func testStatusDecodes() {
        let message = ServerMessage.decode(#"{"type":"host_status","battery":78,"charging":true,"signal":3,"operator":"Turkcell"}"#)
        XCTAssertEqual(message, .hostStatus(HostInfo(battery: 78, charging: true, signal: 3, operatorName: "Turkcell")))
    }

    func testMissingFieldsAreNil() {
        XCTAssertEqual(ServerMessage.decode(#"{"type":"host_status"}"#), .hostStatus(HostInfo(battery: nil, charging: false, signal: nil, operatorName: nil)))
    }

    func testSummaryShowsBatterySignalAndOperator() {
        XCTAssertTrue(HostInfo(battery: 41, charging: false, signal: 2, operatorName: "Turkcell").summary.hasPrefix("41%"))
        XCTAssertTrue(HostInfo(battery: 41, charging: false, signal: 2, operatorName: "Turkcell").summary.hasSuffix("●●○○"))
    }

    func testLowOnlyWhenNotCharging() {
        XCTAssertTrue(HostInfo(battery: 25, charging: false, signal: nil, operatorName: nil).isLow)
        XCTAssertFalse(HostInfo(battery: 25, charging: true, signal: nil, operatorName: nil).isLow)
        XCTAssertFalse(HostInfo(battery: 80, charging: false, signal: nil, operatorName: nil).isLow)
    }

    func testTheWarningComesOnceAndRearmsAfterCharging() {
        var warned = false
        var result = BatteryAlert.evaluate(level: 35, charging: false, warned: warned)
        XCTAssertFalse(result.warn)
        result = BatteryAlert.evaluate(level: 20, charging: false, warned: warned)
        XCTAssertTrue(result.warn)
        warned = result.warned
        XCTAssertFalse(BatteryAlert.evaluate(level: 15, charging: false, warned: warned).warn) // already told
        warned = BatteryAlert.evaluate(level: 50, charging: false, warned: warned).warned // recovered
        XCTAssertFalse(warned)
        XCTAssertTrue(BatteryAlert.evaluate(level: 19, charging: false, warned: warned).warn)
        XCTAssertFalse(BatteryAlert.evaluate(level: 10, charging: true, warned: false).warn) // charging: no warning
    }
}
