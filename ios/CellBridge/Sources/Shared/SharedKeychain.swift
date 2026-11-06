import Foundation
import Security

/// Keychain items the app and its notification service extension both read. They live in a keychain access group named in
/// Info.plist (`CBKeychainGroup`, built from the signing team's prefix), so no team id is written into the source.
/// Without the entitlement (unit tests, an unsigned build) items fall back to the process's own default group.
enum SharedKeychain {
    private static let service = "cellbridge.shared"

    private static var group: String? { Bundle.main.object(forInfoDictionaryKey: "CBKeychainGroup") as? String }

    private static func query(_ account: String, grouped: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if grouped, let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    static func read(_ account: String) -> Data? {
        for grouped in [true, false] {
            var request = query(account, grouped: grouped)
            request[kSecReturnData as String] = true
            var result: AnyObject?
            if SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data { return data }
            if group == nil { break }
        }
        return nil
    }

    @discardableResult
    static func write(_ account: String, _ data: Data) -> Bool {
        for grouped in [true, false] {
            SecItemDelete(query(account, grouped: grouped) as CFDictionary)
            var item = query(account, grouped: grouped)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock // a push can arrive while the phone is locked
            if SecItemAdd(item as CFDictionary, nil) == errSecSuccess { return true }
            if group == nil { break }
        }
        return false
    }
}

/// The 32 random bytes shared with the host so only the two phones can read what a push carries. Created once by the app, kept in
/// the shared Keychain group so the notification extension can open text pushes with it.
enum PushKeyStore {
    private static let account = "push-key"

    /// For the extension: never creates a key, only reads the one the app made.
    static func existing() -> Data? {
        guard let data = SharedKeychain.read(account), data.count == 32 else { return nil }
        return data
    }

    static func key() -> Data {
        if let data = existing() { return data }
        // The key the first versions kept under the app's own service name moves to the shared group (the host already has it).
        let legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "cellbridge",
            kSecAttrAccount as String: account,
        ]
        var request = legacy
        request[kSecReturnData as String] = true
        var result: AnyObject?
        if SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let old = result as? Data, old.count == 32 {
            if SharedKeychain.write(account, old) { SecItemDelete(legacy as CFDictionary) }
            return old
        }
        let fresh = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        SharedKeychain.write(account, fresh)
        return fresh
    }
}

/// Ids of the texts a push has already put on the screen, so the same text replayed over the control channel is not announced twice.
/// The extension writes, the app reads; the newest 200 are kept.
enum PushedTexts {
    private static let account = "pushed-texts"
    private static let limit = 200

    private static func load() -> [String] {
        SharedKeychain.read(account).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    static func contains(_ id: String) -> Bool { load().contains(id) }

    static func insert(_ id: String) {
        var ids = load().filter { $0 != id }
        ids.append(id)
        if let data = try? JSONEncoder().encode(Array(ids.suffix(limit))) { SharedKeychain.write(account, data) }
    }
}
