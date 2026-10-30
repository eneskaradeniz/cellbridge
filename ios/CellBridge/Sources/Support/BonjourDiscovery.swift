import Foundation
import Network

/// Finds the phone by name on the local network (`_cellbridge._tcp`, advertised by the Android app), so its address never
/// has to be typed and a changed address is found again by itself.
@MainActor
final class BonjourDiscovery: ObservableObject {
    @Published private(set) var address: String?
    /// The phone's installation id from its TXT record: not secret, not derived from the pairing code.
    @Published private(set) var deviceId: String?

    /// With several phones on the network, the one paired (its installation id from the QR code).
    var preferredId: String? {
        didSet { if oldValue != preferredId { resolve(lastResults) } }
    }

    var onLog: ((String) -> Void)?
    private var retry: Task<Void, Never>?
    private var lastResults: Set<NWBrowser.Result> = []
    private var browser: NWBrowser?
    private var probe: NWConnection?

    init() { start() }

    func start() {
        browser?.cancel()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_cellbridge._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.resolve(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.start() } }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// The announced address on one of this iPhone's own subnets; failing that, the first one announced.
    static func announcedAddress(_ list: String?) -> String? {
        let announced = (list ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter(isIPv4)
        return announced.first { sharesSubnet($0) } ?? announced.first
    }

    private static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    private static func sharesSubnet(_ address: String) -> Bool {
        let prefix = address.split(separator: ".").dropLast().joined(separator: ".")
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = pointer.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            if String(cString: buffer).split(separator: ".").dropLast().joined(separator: ".") == prefix { return true }
        }
        return false
    }

    private func resolveAgain() {
        retry?.cancel()
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            onLog?("bonjour: resolving again")
            resolve(lastResults)
        }
    }

    deinit {
        browser?.cancel()
        probe?.cancel()
    }

    /// A browse result is a name, not an address: connecting to it once shows the IPv4 address the system resolved.
    private func resolve(_ results: Set<NWBrowser.Result>) {
        probe?.cancel()
        retry?.cancel()
        lastResults = results
        onLog?("bonjour: \(results.count) phone(s) announcing")
        let match = results.first { result in
            if case .bonjour(let txt) = result.metadata { return preferredId != nil && txt["id"] == preferredId }
            return false
        }
        guard let result = match ?? results.first else {
            address = nil
            deviceId = nil
            return
        }
        if case .bonjour(let txt) = result.metadata {
            deviceId = txt["id"]
            // The phone says its own address in the TXT record: no name lookup, whose cached answer goes stale when the address changes.
            if let announced = Self.announcedAddress(txt["ip"]) {
                address = announced
                return
            }
        }
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint, case .ipv4(let ip) = host {
                    let text = "\(ip)".split(separator: "%").first.map(String.init)
                    Task { @MainActor in self?.address = text }
                }
                connection.cancel()
            case .failed, .waiting:
                // The name is there but its address did not resolve (a stale record, the network still settling): look again.
                connection.cancel()
                Task { @MainActor in self?.resolveAgain() }
            default:
                break
            }
        }
        connection.start(queue: .main)
        probe = connection
    }
}
