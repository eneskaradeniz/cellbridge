import Foundation

/// How the Android phone is doing (docs/protocol.md `host_status`).
struct HostInfo: Equatable {
    var battery: Int?
    var charging: Bool
    /// Cellular signal bars, 0 to 4.
    var signal: Int?
    var operatorName: String?

    /// "78% · charging · Turkcell ●●●○"
    var summary: String {
        var parts: [String] = []
        if let battery { parts.append("\(battery)%") }
        if charging { parts.append(String(localized: "charging")) }
        if let operatorName { parts.append(operatorName) }
        if let signal {
            let bars = max(0, min(4, signal))
            parts.append(String(repeating: "●", count: bars) + String(repeating: "○", count: 4 - bars))
        }
        return parts.joined(separator: " · ")
    }

    var isLow: Bool { !charging && (battery ?? 100) <= 30 }
}

/// When to tell the user that the phone is about to run out: once at 20%, again only after it has been charged or is back
/// above 30%.
enum BatteryAlert {
    static func evaluate(level: Int?, charging: Bool, warned: Bool) -> (warn: Bool, warned: Bool) {
        guard let level else { return (false, warned) }
        if charging || level >= 30 { return (false, false) }
        if level <= 20 && !warned { return (true, true) }
        return (false, warned)
    }
}
