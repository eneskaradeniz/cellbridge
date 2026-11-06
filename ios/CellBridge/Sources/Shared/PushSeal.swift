import CryptoKit
import Foundation

/// The sealed box the host puts in a push (docs/protocol.md): base64(nonce 12 + AES-256-GCM ciphertext + tag), context-bound.
/// Compiled into the app and into the notification service extension.
enum PushSeal {
    struct Call: Equatable {
        let callId: String
        let number: String?
        let name: String?
    }

    /// A received text, as the host seals it into an alert push.
    struct Text: Equatable {
        let id: String
        let from: String
        let body: String
        let date: Date
    }

    private static let context = Data("cellbridge-push-v1".utf8)

    private static func plain(_ sealed: String, key: Data) -> [String: Any]? {
        guard key.count == 32, let bytes = Data(base64Encoded: sealed),
              let box = try? AES.GCM.SealedBox(combined: bytes),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: context) else { return nil }
        return try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
    }

    /// Nil when the box is damaged, was sealed under another key, or does not carry a call id.
    static func open(_ sealed: String, key: Data) -> Call? {
        guard let object = plain(sealed, key: key), let callId = object["callId"] as? String, !callId.isEmpty else { return nil }
        func text(_ name: String) -> String? { (object[name] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return Call(callId: callId, number: text("number"), name: text("name"))
    }

    /// Nil when the box is damaged, was sealed under another key, or does not carry a text.
    static func openText(_ sealed: String, key: Data) -> Text? {
        guard let object = plain(sealed, key: key), let id = object["id"] as? String, !id.isEmpty,
              let from = object["from"] as? String, let body = object["body"] as? String else { return nil }
        let millis = (object["ts"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
        return Text(id: id, from: from, body: body, date: Date(timeIntervalSince1970: millis / 1000))
    }

    /// Only the tests seal (the host does it in production).
    static func seal(_ call: Call, key: Data, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> String {
        var object: [String: Any] = ["callId": call.callId]
        if let number = call.number { object["number"] = number }
        if let name = call.name { object["name"] = name }
        return try seal(object, key: key, nonce: nonce)
    }

    static func seal(_ text: Text, key: Data, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> String {
        try seal(["id": text.id, "from": text.from, "body": text.body, "ts": Int64(text.date.timeIntervalSince1970 * 1000)], key: key, nonce: nonce)
    }

    private static func seal(_ object: [String: Any], key: Data, nonce: AES.GCM.Nonce) throws -> String {
        let plain = try JSONSerialization.data(withJSONObject: object)
        return try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: nonce, authenticating: context).combined!.base64EncodedString()
    }
}
