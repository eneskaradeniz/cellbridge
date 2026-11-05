import Foundation

/// Wire format of the control channel; keep in sync with docs/protocol.md and Android's Messages.kt.
let protocolVersion = 1

enum ClientMessage: Equatable {
    case hello(token: String)
    case answer(callId: String, udpPort: Int?)
    case reject(callId: String)
    case hangup(callId: String)
    case ringAck(callId: String)
    case dtmf(callId: String, digit: String)
    case transferToHost(callId: String)
    case transferAccept(callId: String, udpPort: Int?)
    case dial(clientId: String, number: String, udpPort: Int?)
    case smsAck(id: String)
    case smsSend(clientId: String, to: String, body: String)
    case callLogRequest(after: String?, since: Int64?)
    case smsHistoryRequest(since: Int64?)
    case pushToken(token: String, env: String, topic: String, key: String)

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
        case .ringAck(let callId):
            object = ["type": "ring_ack", "callId": callId]
        case .dtmf(let callId, let digit):
            object = ["type": "dtmf", "callId": callId, "digit": digit]
        case .transferToHost(let callId):
            object = ["type": "transfer_to_host", "callId": callId]
        case .transferAccept(let callId, let udpPort):
            object = ["type": "transfer_accept", "callId": callId]
            if let udpPort { object["udpPort"] = udpPort }
        case .dial(let clientId, let number, let udpPort):
            object = ["type": "dial", "clientId": clientId, "number": number]
            if let udpPort { object["udpPort"] = udpPort }
        case .smsAck(let id):
            object = ["type": "sms_ack", "id": id]
        case .smsSend(let clientId, let to, let body):
            object = ["type": "sms_send", "clientId": clientId, "to": to, "body": body]
        case .callLogRequest(let after, let since):
            object = ["type": "call_log_request"]
            if let after { object["after"] = after }
            if let since { object["since"] = since }
        case .smsHistoryRequest(let since):
            object = ["type": "sms_history_request"]
            if let since { object["since"] = since }
        case .pushToken(let token, let env, let topic, let key):
            object = ["type": "push_token", "token": token, "env": env, "topic": topic, "key": key]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

enum EndReason: String, Equatable {
    case missed, rejected
}

/// A row of the phone's call log (docs/protocol.md `call_log`). `kind` is incoming, outgoing, missed or rejected.
struct HostCall: Equatable {
    let id: String
    let number: String
    let name: String?
    let kind: String
    let ts: Int64
    let duration: Int
}

/// A text from the phone's database (docs/protocol.md `sms_history`).
struct HostText: Equatable {
    let id: String
    let peer: String
    let body: String
    let ts: Int64
    let outgoing: Bool
}

/// What the phone plays during a call that is not in the relayed audio (docs/protocol.md `tone`).
enum ToneCommand: Equatable {
    case generator(Int)
    case media(String)
    case stop
}

enum ServerMessage: Equatable {
    case helloAck(version: Int, capabilities: [String])
    case callList(callIds: [String])
    case tone(ToneCommand)
    case capabilities([String])
    case ring(callId: String, number: String?, name: String?)
    case ended(callId: String, reason: EndReason?)
    case dialResult(clientId: String, ok: Bool, callId: String?, error: String?)
    case answered(callId: String)
    case sms(id: String, from: String, body: String, ts: Int64)
    case smsResult(clientId: String, ok: Bool, error: String?)
    case hostStatus(HostInfo)
    case smsStatus(clientId: String, delivered: Bool)
    case transferResult(callId: String, ok: Bool)
    case transferOffer(callId: String, number: String?, connectedAt: Int64?)
    case callLog(entries: [HostCall])
    case smsHistory(items: [HostText])
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
        case "call_list":
            guard let callIds = object["callIds"] as? [String] else { return nil }
            return .callList(callIds: callIds)
        case "tone":
            switch object["action"] as? String {
            case "stop": return .tone(.stop)
            case "start":
                if object["kind"] as? String == "generator", let id = (object["id"] as? NSNumber)?.intValue { return .tone(.generator(id)) }
                if object["kind"] as? String == "media", let name = object["name"] as? String { return .tone(.media(name)) }
                return nil
            default: return nil
            }
        case "capabilities":
            guard let list = object["capabilities"] as? [String] else { return nil }
            return .capabilities(list)
        case "ring":
            guard let callId = object["callId"] as? String else { return nil }
            return .ring(callId: callId, number: object["number"] as? String, name: object["name"] as? String)
        case "ended":
            guard let callId = object["callId"] as? String else { return nil }
            return .ended(callId: callId, reason: (object["reason"] as? String).flatMap(EndReason.init(rawValue:)))
        case "dial_result":
            guard let clientId = object["clientId"] as? String, let ok = object["ok"] as? Bool else { return nil }
            return .dialResult(clientId: clientId, ok: ok, callId: object["callId"] as? String, error: object["error"] as? String)
        case "answered":
            guard let callId = object["callId"] as? String else { return nil }
            return .answered(callId: callId)
        case "sms":
            guard let id = object["id"] as? String, let from = object["from"] as? String,
                  let body = object["body"] as? String, let ts = (object["ts"] as? NSNumber)?.int64Value else { return nil }
            return .sms(id: id, from: from, body: body, ts: ts)
        case "sms_result":
            guard let clientId = object["clientId"] as? String, let ok = object["ok"] as? Bool else { return nil }
            return .smsResult(clientId: clientId, ok: ok, error: object["error"] as? String)
        case "sms_status":
            guard let clientId = object["clientId"] as? String, let status = object["status"] as? String else { return nil }
            return .smsStatus(clientId: clientId, delivered: status == "delivered")
        case "host_status":
            return .hostStatus(HostInfo(battery: (object["battery"] as? NSNumber)?.intValue, charging: object["charging"] as? Bool ?? false,
                                        signal: (object["signal"] as? NSNumber)?.intValue, operatorName: object["operator"] as? String))
        case "transfer_result":
            guard let callId = object["callId"] as? String, let ok = object["ok"] as? Bool else { return nil }
            return .transferResult(callId: callId, ok: ok)
        case "transfer_offer":
            guard let callId = object["callId"] as? String else { return nil }
            return .transferOffer(callId: callId, number: object["number"] as? String,
                                  connectedAt: (object["connectedAt"] as? NSNumber)?.int64Value)
        case "call_log":
            let rows = object["entries"] as? [[String: Any]] ?? []
            return .callLog(entries: rows.compactMap { row in
                guard let id = row["id"] as? String, let number = row["number"] as? String, let kind = row["kind"] as? String,
                      let ts = (row["ts"] as? NSNumber)?.int64Value else { return nil }
                return HostCall(id: id, number: number, name: row["name"] as? String, kind: kind, ts: ts,
                                duration: (row["duration"] as? NSNumber)?.intValue ?? 0)
            })
        case "sms_history":
            let rows = object["items"] as? [[String: Any]] ?? []
            return .smsHistory(items: rows.compactMap { row in
                guard let id = row["id"] as? String, let peer = row["peer"] as? String, let body = row["body"] as? String,
                      let ts = (row["ts"] as? NSNumber)?.int64Value, let dir = row["dir"] as? String else { return nil }
                return HostText(id: id, peer: peer, body: body, ts: ts, outgoing: dir == "out")
            })
        case "error":
            guard let code = object["code"] as? String else { return nil }
            return .error(code: code, message: object["message"] as? String)
        default:
            return nil
        }
    }
}
