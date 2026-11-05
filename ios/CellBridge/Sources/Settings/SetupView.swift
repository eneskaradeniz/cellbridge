import SwiftUI

/// One permission: what it is for, whether it is on, and the one thing to press about it.
struct PermissionRow: View {
    @EnvironmentObject var permissions: PermissionCenter
    let kind: PermissionKind

    private var symbol: String {
        switch kind {
        case .camera: return "camera"
        case .contacts: return "person.crop.circle"
        case .microphone: return "mic"
        case .notifications: return "bell"
        }
    }

    private var title: LocalizedStringKey {
        switch kind {
        case .camera: return "Camera"
        case .contacts: return "Contacts"
        case .microphone: return "Microphone"
        case .notifications: return "Notifications"
        }
    }

    private var purpose: LocalizedStringKey {
        switch kind {
        case .camera: return "Scans the QR code on the phone, once."
        case .contacts: return "Shows names instead of numbers. Contacts stay on this iPhone."
        case .microphone: return "Sends your voice to the call."
        case .notifications: return "Tells you about new texts."
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 28).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(purpose).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            switch permissions.state(kind) {
            case .granted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Allowed")
            case .notDetermined:
                Button("Allow") { Task { await permissions.request(kind) } }.buttonStyle(.bordered)
            case .denied:
                Button("Open Settings") { PermissionCenter.openSystemSettings() }.buttonStyle(.bordered).tint(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// What the QR scanner shows when there is nothing to scan with: the camera is off for the app, or there is none.
struct CameraUnavailableView: View {
    let denied: Bool
    let enterByHand: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                denied ? "Camera Access Is Off" : "No Camera",
                systemImage: "camera.fill",
                description: Text(denied
                    ? "Allow the camera in iOS Settings to scan the QR code. You can also scan it with the iPhone's Camera app, or type the pairing code by hand."
                    : "This iPhone has no camera that can scan. Type the pairing code by hand."))
            if denied {
                Button("Open Settings") { PermissionCenter.openSystemSettings() }.buttonStyle(.borderedProminent)
            }
            Button("Enter the code by hand", action: enterByHand).buttonStyle(.bordered)
        }
    }
}

/// The QR scanner sheet, asking for the camera first and explaining itself when the answer is no.
struct ScanSheet: View {
    @EnvironmentObject var permissions: PermissionCenter
    let onCode: (String) -> Void
    let cancel: () -> Void
    let enterByHand: () -> Void
    @State private var noCamera = false

    var body: some View {
        NavigationStack {
            Group {
                switch permissions.state(.camera) {
                case .granted:
                    if noCamera {
                        CameraUnavailableView(denied: false, enterByHand: enterByHand)
                    } else {
                        QRScannerView(onCode: onCode, onUnavailable: { noCamera = true }).ignoresSafeArea()
                    }
                case .notDetermined:
                    ProgressView()
                case .denied:
                    CameraUnavailableView(denied: true, enterByHand: enterByHand)
                }
            }
            .navigationTitle("Scan the QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) } }
        }
        .task {
            await permissions.refresh()
            if permissions.state(.camera) == .notDetermined { await permissions.request(.camera) }
        }
    }
}

/// First run: pair with the phone and answer the permission questions in one place, with the reason next to each.
/// Everything here can also be done later from Settings.
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var scanFailed = false
    @State private var typing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: model.isPaired ? "checkmark.circle.fill" : "qrcode.viewfinder")
                            .frame(width: 28).foregroundStyle(model.isPaired ? Color.green : Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pair with the phone")
                            Text(model.isPaired ? "Paired." : "Open CellBridge on the Android phone and scan the QR code shown there.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if !model.isPaired { Button("Scan") { scanning = true }.buttonStyle(.borderedProminent) }
                    }
                    if !model.isPaired { NavigationLink("Enter the code by hand") { PhoneDetailsView() } }
                } footer: {
                    if scanFailed { Text("That is not a CellBridge QR code.").foregroundStyle(.red) }
                }
                Section {
                    ForEach([PermissionKind.contacts, .microphone, .notifications]) { PermissionRow(kind: $0) }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("You can change these any time in Settings.")
                }
            }
            .navigationTitle("Set Up CellBridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(isPresented: $typing) { PhoneDetailsView() }
            .sheet(isPresented: $scanning) {
                ScanSheet(
                    onCode: { text in
                        scanning = false
                        scanFailed = !model.handleScan(text)
                    },
                    cancel: { scanning = false },
                    enterByHand: { scanning = false; typing = true })
            }
        }
    }
}
