import CryptoKit
import Foundation
import PushKit
import Security

/// The sealed box the host puts in a VoIP push (docs/protocol.md): base64(nonce 12 + AES-256-GCM ciphertext + tag), context-bound.
enum PushSeal {
    struct Call: Equatable {
        let callId: String
        let number: String?
        let name: String?
    }

    private static let context = Data("cellbridge-push-v1".utf8)

    /// Nil when the box is damaged, was sealed under another key, or does not carry a call id.
    static func open(_ sealed: String, key: Data) -> Call? {
        guard key.count == 32, let bytes = Data(base64Encoded: sealed),
              let box = try? AES.GCM.SealedBox(combined: bytes),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: context),
              let object = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let callId = object["callId"] as? String, !callId.isEmpty else { return nil }
        func text(_ name: String) -> String? { (object[name] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return Call(callId: callId, number: text("number"), name: text("name"))
    }

    /// Only the tests seal (the host does it in production).
    static func seal(_ call: Call, key: Data, nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> String {
        var object: [String: Any] = ["callId": call.callId]
        if let number = call.number { object["number"] = number }
        if let name = call.name { object["name"] = name }
        let plain = try JSONSerialization.data(withJSONObject: object)
        return try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: nonce, authenticating: context).combined!.base64EncodedString()
    }
}

/// The 32 random bytes shared with the host so only the two phones can read what a push carries. Created once, kept in the Keychain.
enum PushKeyStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: Bundle.main.bundleIdentifier ?? "cellbridge",
        kSecAttrAccount as String: "push-key",
    ]

    static func key() -> Data {
        var request = query
        request[kSecReturnData as String] = true
        var result: AnyObject?
        if SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        let fresh = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = fresh
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock // a push can arrive while the phone is locked
        SecItemAdd(item as CFDictionary, nil)
        return fresh
    }
}

/// Registers for VoIP pushes (so a closed app can ring) and hands each push's call to the call coordinator.
/// Must be started at launch: iOS delivers a push to a closed app only if the app registers again as it starts.
@MainActor
final class PushRegistry: NSObject, PKPushRegistryDelegate {
    private let registry = PKPushRegistry(queue: .main)
    private static let tokenKey = "pushToken"

    /// A push arrived: the call it carries (nil if it could not be read) and the block to run once the call is reported to CallKit.
    var onCall: ((PushSeal.Call?, @escaping () -> Void) -> Void)?
    /// Apple gave this app a (new) push token.
    var onToken: (() -> Void)?

    private(set) var token: String? = UserDefaults.standard.string(forKey: PushRegistry.tokenKey)

    func start() {
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    /// What tells the host where and how to reach this app; nil until Apple has issued a token.
    var message: ClientMessage? {
        guard let token else { return nil }
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        return .pushToken(token: token, env: env, topic: (Bundle.main.bundleIdentifier ?? "") + ".voip", key: PushKeyStore.key().base64EncodedString())
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let hex = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated {
            token = hex
            UserDefaults.standard.set(hex, forKey: Self.tokenKey)
            onToken?()
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        MainActor.assumeIsolated {
            token = nil
            UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
                                  completion: @escaping () -> Void) {
        let sealed = payload.dictionaryPayload["cb"] as? String
        MainActor.assumeIsolated {
            let call = sealed.flatMap { PushSeal.open($0, key: PushKeyStore.key()) }
            if let onCall { onCall(call, completion) } else { completion() }
        }
    }
}
