import Foundation

/// The single WebSocket to the host (docs/protocol.md): hello with the pairing token, ping every 10 s,
/// reconnect after 2 s. One connection at a time; connect() while connected replaces it.
@MainActor
final class ControlClient: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected(capabilities: [String])
        /// The host refused us (wrong token / version); retrying would not help.
        case rejected(code: String)
    }

    @Published private(set) var state: State = .idle
    var onMessage: ((ServerMessage) -> Void)?
    var onLog: ((String) -> Void)?

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var runner: Task<Void, Never>?

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10 // a dead host should fail fast so we can retry
        session = URLSession(configuration: configuration)
    }

    func connect(host: String, token: String) {
        disconnect()
        guard let url = URL(string: "ws://\(host):8765/") else { return onLog?("bad host \(host)") ?? () }
        state = .connecting
        runner = Task { await run(url: url, token: token) }
    }

    func disconnect() {
        runner?.cancel()
        runner = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .idle
    }

    func send(_ message: ClientMessage) {
        task?.send(.string(message.encoded())) { [weak self] error in
            if let error { Task { @MainActor in self?.onLog?("send failed: \(error.localizedDescription)") } }
        }
    }

    // MARK: connection loop

    private func run(url: URL, token: String) async {
        while !Task.isCancelled {
            let task = session.webSocketTask(with: url)
            self.task = task
            task.resume()
            state = .connecting
            let pinger = Task { await pingLoop(task) }
            do {
                try await task.send(.string(ClientMessage.hello(token: token).encoded()))
                while true {
                    guard case .string(let text) = try await task.receive() else { continue }
                    guard let message = ServerMessage.decode(text) else { continue }
                    if handle(message) == .stop {
                        pinger.cancel()
                        task.cancel(with: .normalClosure, reason: nil)
                        return
                    }
                }
            } catch {
                if !Task.isCancelled { onLog?("connection lost: \(error.localizedDescription)") }
            }
            pinger.cancel()
            task.cancel(with: .goingAway, reason: nil)
            if Task.isCancelled { return }
            state = .connecting
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private enum Next { case keepGoing, stop }

    private func handle(_ message: ServerMessage) -> Next {
        switch message {
        case .helloAck(let version, let capabilities):
            guard version == protocolVersion else {
                state = .rejected(code: "unsupported_version")
                return .stop
            }
            state = .connected(capabilities: capabilities)
        case .error(let code, _) where ["unauthorized", "unsupported_version", "expected_hello"].contains(code):
            state = .rejected(code: code)
            return .stop
        default:
            break
        }
        onMessage?(message)
        return .keepGoing
    }

    /// A ping that gets no pong closes the socket, which makes the receive loop reconnect.
    private func pingLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            if Task.isCancelled { return }
            let alive = await withCheckedContinuation { continuation in
                task.sendPing { error in continuation.resume(returning: error == nil) }
            }
            if !alive {
                task.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }
}
