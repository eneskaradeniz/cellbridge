import AVFoundation
import Contacts
import UserNotifications
import XCTest
@testable import CellBridge

final class PermissionTests: XCTestCase {
    func testContactsMapping() {
        XCTAssertEqual(PermissionState(CNAuthorizationStatus.authorized), .granted)
        XCTAssertEqual(PermissionState(CNAuthorizationStatus.limited), .granted)
        XCTAssertEqual(PermissionState(CNAuthorizationStatus.notDetermined), .notDetermined)
        XCTAssertEqual(PermissionState(CNAuthorizationStatus.denied), .denied)
        XCTAssertEqual(PermissionState(CNAuthorizationStatus.restricted), .denied)
    }

    func testCameraMapping() {
        XCTAssertEqual(PermissionState(AVAuthorizationStatus.authorized), .granted)
        XCTAssertEqual(PermissionState(AVAuthorizationStatus.notDetermined), .notDetermined)
        XCTAssertEqual(PermissionState(AVAuthorizationStatus.denied), .denied)
        XCTAssertEqual(PermissionState(AVAuthorizationStatus.restricted), .denied)
    }

    func testMicrophoneMapping() {
        XCTAssertEqual(PermissionState(AVAudioApplication.recordPermission.granted), .granted)
        XCTAssertEqual(PermissionState(AVAudioApplication.recordPermission.undetermined), .notDetermined)
        XCTAssertEqual(PermissionState(AVAudioApplication.recordPermission.denied), .denied)
    }

    func testNotificationsMapping() {
        XCTAssertEqual(PermissionState(UNAuthorizationStatus.authorized), .granted)
        XCTAssertEqual(PermissionState(UNAuthorizationStatus.provisional), .granted)
        XCTAssertEqual(PermissionState(UNAuthorizationStatus.notDetermined), .notDetermined)
        XCTAssertEqual(PermissionState(UNAuthorizationStatus.denied), .denied)
    }

    func testUnpairedIdleSaysToScanNotToConnect() {
        XCTAssertEqual(LinkStatus(.idle, paired: false), .unpaired)
        XCTAssertEqual(LinkStatus(.idle, paired: true), .disconnected)
        XCTAssertEqual(LinkStatus(.connecting, unreachable: true, paired: false), .unreachable)
    }
}
