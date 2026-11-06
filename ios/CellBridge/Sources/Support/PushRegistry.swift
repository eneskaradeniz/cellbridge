import Foundation
import PushKit

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

    // The ordinary notification token, for texts: Apple issues it to the app delegate (`AppDelegate`), not to PushKit.
    nonisolated private static let alertTokenKey = "alertPushToken"
    var alertToken: String? { UserDefaults.standard.string(forKey: Self.alertTokenKey) }

    /// The app delegate got a notification token: kept even if it arrives before the model exists. True when it differs from the one held.
    nonisolated static func store(alertToken hex: String) -> Bool {
        guard UserDefaults.standard.string(forKey: alertTokenKey) != hex else { return false }
        UserDefaults.standard.set(hex, forKey: alertTokenKey)
        return true
    }

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
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        return .pushToken(token: token, env: env, topic: bundleId + ".voip", key: PushKeyStore.key().base64EncodedString(),
                          alertToken: alertToken, alertTopic: alertToken == nil ? nil : bundleId)
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
