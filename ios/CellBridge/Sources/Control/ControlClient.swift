import Foundation

/// The single WebSocket to the host (docs/protocol.md): hello with the pairing token, ping every 10 s,
/// reconnect after 2 s, trying the next candidate address after each failed attempt. One connection at a time; connect() while connected replaces it.
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
    /// The address of the host this client is connected to (answered the hello); nil otherwise.
    private(set) var connectedHost: String?
    /// Called with the address that answered the hello, so the app can remember it.
    var onReached: ((String) -> Void)?
    /// Called after every ping the host answered.
    var onAlive: (() -> Void)?

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var runner: Task<Void, Never>?
    private var hostProvider: (() -> [String])?
    private var token = ""

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10 // a dead host should fail fast so we can retry
        session = URLSession(configuration: configuration)
    }

    /// `host` is asked again before every attempt, so a host that moved (the hotspot's subnet changed) is found again;
    /// it lists the addresses to try, best first, and a failed attempt moves on to the next one.
    func connect(host: @escaping () -> [String], token: String) {
        disconnect()
        hostProvider = host
        self.token = token
        state = .connecting
        runner = Task { await run() }
    }

    /// Drops the current connection (if any) and starts over at once; a no-op when the user disconnected.
    func restart() {
        guard let hostProvider, runner != nil else { return }
        connect(host: hostProvider, token: token)
    }

    func disconnect() {
        hostProvider = nil
        connectedHost = nil
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

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            let hosts = hostProvider?() ?? []
            let host = hosts.isEmpty ? "" : hosts[attempt % hosts.count]
            guard !host.isEmpty, let url = URL(string: "ws://\(host):8765/") else {
                state = .connecting // no address yet (the gateway is still being discovered): look again shortly
                try? await Task.sleep(for: .seconds(1))
                continue
            }
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
                    let next = handle(message)
                    if case .connected = state, connectedHost == nil {
                        connectedHost = host
                        attempt = 0
                        onReached?(host)
                    }
                    if next == .stop {
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
            if connectedHost == nil { attempt += 1 } // never got an answer: try the next candidate
            connectedHost = nil
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
            // A dead connection (the phone left the network without closing it) can leave a ping unanswered for minutes: give it 5 s.
            let alive = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let once = Once()
                task.sendPing { error in if once.take() { continuation.resume(returning: error == nil) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if once.take() { continuation.resume(returning: false) } }
            }
            if !alive {
                task.cancel(with: .goingAway, reason: nil)
                return
            }
            onAlive?()
        }
    }
}

/// Lets exactly one of two racing callbacks win.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
