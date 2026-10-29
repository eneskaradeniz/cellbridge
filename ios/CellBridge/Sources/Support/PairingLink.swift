import Foundation

/// What the QR code on the phone's screen holds: `cellbridge://pair?code=…&id=…&port=…&host=…` (docs/protocol.md).
struct PairingLink: Equatable {
    let code: String
    let deviceId: String
    let host: String?
    let port: Int

    static func parse(_ text: String) -> PairingLink? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "cellbridge", components.host == "pair" else { return nil }
        func value(_ name: String) -> String? { components.queryItems?.first { $0.name == name }?.value }
        guard let rawCode = value("code"), let id = value("id"), !id.isEmpty else { return nil }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard (4...32).contains(code.count), code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let host = value("host").flatMap { $0.isEmpty || !HostAddress.isValid($0) ? nil : $0 }
        return PairingLink(code: code, deviceId: id, host: host, port: value("port").flatMap(Int.init) ?? 8765)
    }
}
