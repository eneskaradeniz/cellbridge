import Foundation
import Network

/// Finds the phone by name on the local network (`_cellbridge._tcp`, advertised by the Android app), so its address never
/// has to be typed and a changed address is found again by itself.
@MainActor
final class BonjourDiscovery: ObservableObject {
    @Published private(set) var address: String?
    /// The phone's installation id from its TXT record: not secret, not derived from the pairing code.
    @Published private(set) var deviceId: String?

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

    deinit {
        browser?.cancel()
        probe?.cancel()
    }

    /// A browse result is a name, not an address: connecting to it once shows the IPv4 address the system resolved.
    private func resolve(_ results: Set<NWBrowser.Result>) {
        probe?.cancel()
        guard let result = results.first else {
            address = nil
            deviceId = nil
            return
        }
        if case .bonjour(let txt) = result.metadata { deviceId = txt["id"] }
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
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .main)
        probe = connection
    }
}
