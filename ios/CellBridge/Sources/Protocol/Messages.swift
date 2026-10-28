import Foundation

/// Wire format of the control channel; keep in sync with docs/protocol.md and Android's Messages.kt.
let protocolVersion = 1

enum ClientMessage: Equatable {
    case hello(token: String)
    case answer(callId: String, udpPort: Int?)
    case reject(callId: String)
    case hangup(callId: String)

    func encoded() -> String {
        var object: [String: Any]
        switch self {
        case .hello(let token):
            object = ["type": "hello", "version": protocolVersion, "token": token]
        case .answer(let callId, let udpPort):
            object = ["type": "answer", "callId": callId]
            if let udpPort { object["udpPort"] = udpPort }
        case .reject(let callId):
            object = ["type": "reject", "callId": callId]
        case .hangup(let callId):
            object = ["type": "hangup", "callId": callId]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

enum EndReason: String, Equatable {
    case missed, rejected
}

enum ServerMessage: Equatable {
    case helloAck(version: Int, capabilities: [String])
    case ring(callId: String, number: String?, name: String?)
    case ended(callId: String, reason: EndReason?)
    case error(code: String, message: String?)

    /// Returns nil for anything that is not a message this client understands; unknown types are ignored on purpose
    /// so a newer host can add messages without breaking an older client.
    static func decode(_ text: String) -> ServerMessage? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "hello_ack":
            guard let version = object["version"] as? Int else { return nil }
            return .helloAck(version: version, capabilities: object["capabilities"] as? [String] ?? [])
        case "ring":
            guard let callId = object["callId"] as? String else { return nil }
            return .ring(callId: callId, number: object["number"] as? String, name: object["name"] as? String)
        case "ended":
            guard let callId = object["callId"] as? String else { return nil }
            return .ended(callId: callId, reason: (object["reason"] as? String).flatMap(EndReason.init(rawValue:)))
        case "error":
            guard let code = object["code"] as? String else { return nil }
            return .error(code: code, message: object["message"] as? String)
        default:
            return nil
        }
    }
}
