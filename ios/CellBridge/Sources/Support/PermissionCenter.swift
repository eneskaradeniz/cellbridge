import AVFoundation
import Contacts
import SwiftUI
import UserNotifications

enum PermissionState: Equatable {
    case granted, notDetermined, denied

    init(_ status: CNAuthorizationStatus) {
        switch status {
        case .authorized, .limited: self = .granted // limited still lists the contacts the user shared
        case .notDetermined: self = .notDetermined
        default: self = .denied
        }
    }

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notDetermined
        default: self = .denied
        }
    }

    init(_ permission: AVAudioApplication.recordPermission) {
        switch permission {
        case .granted: self = .granted
        case .undetermined: self = .notDetermined
        default: self = .denied
        }
    }

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral: self = .granted
        case .notDetermined: self = .notDetermined
        default: self = .denied
        }
    }
}

enum PermissionKind: CaseIterable, Identifiable {
    case camera, contacts, microphone, notifications
    var id: Self { self }
}

/// What the user has allowed, in one place: the setup sheet and Settings both read it, and it is re-read whenever the app comes
/// to the front because the user can change any of these in iOS Settings at any time.
@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var states: [PermissionKind: PermissionState] = [:]
    /// Called after the contacts answer changes, so the address book is loaded (or dropped).
    var onContactsChanged: (() -> Void)?

    func state(_ kind: PermissionKind) -> PermissionState { states[kind] ?? .notDetermined }

    /// Kinds the app can still ask about (the camera is asked for when the scanner opens).
    var pending: [PermissionKind] { [.contacts, .microphone, .notifications].filter { state($0) == .notDetermined } }

    func refresh() async {
        var next: [PermissionKind: PermissionState] = [
            .camera: PermissionState(AVCaptureDevice.authorizationStatus(for: .video)),
            .contacts: PermissionState(CNContactStore.authorizationStatus(for: .contacts)),
            .microphone: PermissionState(AVAudioApplication.shared.recordPermission),
        ]
        next[.notifications] = PermissionState(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
        let contactsChanged = next[.contacts] != states[.contacts]
        if next != states { states = next }
        if contactsChanged { onContactsChanged?() }
    }

    func request(_ kind: PermissionKind) async {
        switch kind {
        case .camera: _ = await AVCaptureDevice.requestAccess(for: .video)
        case .contacts: _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .microphone: _ = await AVAudioApplication.requestRecordPermission()
        case .notifications: _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
        await refresh()
    }

    static func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
