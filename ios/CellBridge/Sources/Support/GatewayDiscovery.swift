import Foundation
import Network

/// On the phone's hotspot the host is the Wi-Fi gateway, and its subnet is not fixed, so ask the system.
@MainActor
final class GatewayDiscovery: ObservableObject {
    @Published private(set) var address: String?
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let ipv4 = path.gateways.compactMap { endpoint -> String? in
                guard case .hostPort(let host, _) = endpoint, case .ipv4(let address) = host else { return nil }
                return "\(address)".split(separator: "%").first.map(String.init)
            }.first
            Task { @MainActor in self?.address = ipv4 }
        }
        monitor.start(queue: .main)
    }

    deinit { monitor.cancel() }
}
