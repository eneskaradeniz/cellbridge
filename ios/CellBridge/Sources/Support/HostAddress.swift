import Foundation

/// Whether what was typed in the address field can be a host: an IPv4 address or a host name. Empty means "automatic".
enum HostAddress {
    static func isValid(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) {
            // Only numbers: it has to be a whole IPv4 address, not a host name that happens to look like one.
            return parts.count == 4 && parts.allSatisfy { Int($0).map { $0 <= 255 } ?? false }
        }
        let label = "[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?"
        return trimmed.range(of: "^\(label)(\\.\(label))*$", options: .regularExpression) != nil
    }
}
