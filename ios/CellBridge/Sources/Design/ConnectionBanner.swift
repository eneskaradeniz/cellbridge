import SwiftUI

/// What the user needs to know about the link to the phone, in words and a colour.
enum LinkStatus: Equatable {
    case disconnected
    case connecting
    case connected(capabilities: [String])
    case refused
    /// Connecting for a while without an answer: wrong address, or not on the phone's network.
    case unreachable

    init(_ state: ControlClient.State, unreachable: Bool = false) {
        switch state {
        case .idle: self = .disconnected
        case .connecting: self = unreachable ? .unreachable : .connecting
        case .connected(let capabilities): self = .connected(capabilities: capabilities)
        case .rejected: self = .refused
        }
    }

    var title: String {
        switch self {
        case .disconnected: return String(localized: "Not connected")
        case .connecting: return String(localized: "Connecting…")
        case .connected: return String(localized: "Connected")
        case .refused: return String(localized: "Pairing code refused")
        case .unreachable: return String(localized: "Phone not reachable")
        }
    }

    var detail: String {
        switch self {
        case .disconnected: return String(localized: "Tap to connect to the phone")
        case .connecting: return String(localized: "Looking for the phone")
        case .connected(let capabilities):
            let names = ["calls": String(localized: "Calls"), "sms": String(localized: "Texts"), "audio": String(localized: "Voice")]
            return capabilities.compactMap { names[$0] }.joined(separator: " · ")
        case .refused: return String(localized: "Check the code on the phone")
        case .unreachable: return String(localized: "Join the phone's hotspot or check the address")
        }
    }

    var color: Color {
        switch self {
        case .connected: return .green
        case .connecting, .unreachable: return .orange
        case .disconnected, .refused: return .red
        }
    }
}

/// Sits in the glass accessory above the tab bar while the phone is out of reach; gone when all is well.
struct ConnectionBanner: View {
    let status: LinkStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if status == .connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "bolt.horizontal.fill").foregroundStyle(status.color)
                }
                Text(status.title).fontWeight(.semibold)
                Text(status.detail).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(status.title). \(status.detail)")
        .accessibilityAddTraits(.isButton)
    }
}
