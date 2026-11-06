import ActivityKit
import Foundation

/// The Live Activity of a call that runs on the phone itself (docs/protocol.md "Live Activity"). The host starts, updates and ends it by
/// push, so these names and types are part of the protocol: `attributes-type` is this type's name, `content-state` this state's coding.
struct CallActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// `active` or `holding`.
        var status: String
        /// When the call connected, ms since 1970: the timer counts from here.
        var connectedAtMs: Int64
        var outgoing: Bool
        /// The number, sealed like every push body (see `PushSeal.openLive`). The widget cannot open it (iOS gives the process
        /// that draws a Live Activity no Keychain), so the app does and writes the result into `name`.
        var sealed: String
        /// Who is on the line, as the app resolved it from `sealed`; absent in the host's pushes.
        var name: String?

        var connectedAt: Date { Date(timeIntervalSince1970: Double(connectedAtMs) / 1000) }
        var isHolding: Bool { status == "holding" }
    }

    var callId: String

    /// What a button on the activity opens to take the call over.
    var takeOverURL: URL {
        var components = URLComponents()
        components.scheme = "cellbridge"
        components.host = "takeover"
        components.queryItems = [URLQueryItem(name: "call", value: callId)]
        return components.url!
    }
}
