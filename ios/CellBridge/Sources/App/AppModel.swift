import AVFoundation
import Combine
import Foundation

/// Wires the pieces together and owns the settings the user edits on the main screen.
@MainActor
final class AppModel: ObservableObject {
    @Published var host: String { didSet { UserDefaults.standard.set(host, forKey: "host") } }
    @Published var token: String { didSet { TokenStore.save(token) } }
    @Published private(set) var events: [String] = []

    let client = ControlClient()
    private(set) var messages: MessageCoordinator!
    private let notifier = Notifier()
    let gateway = GatewayDiscovery()
    private var calls: CallCoordinator!
    private var keepAlive: KeepAlive!
    private var bag = Set<AnyCancellable>()
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        host = UserDefaults.standard.string(forKey: "host") ?? ""
        token = TokenStore.load()
        keepAlive = KeepAlive(log: { [weak self] in self?.log($0) })
        let audio = AudioBridge(keepAlive: keepAlive, log: { [weak self] in self?.log($0) })
        calls = CallCoordinator(
            audio: audio,
            host: { [weak self] in self?.effectiveHost ?? "" },
            hostOffersAudio: { [weak self] in
                if case .connected(let capabilities) = self?.client.state { return capabilities.contains("audio") }
                return false
            },
            send: { [weak self] in self?.client.send($0) },
            log: { [weak self] in self?.log($0) }
        )
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        messages = MessageCoordinator(
            store: MessageStore(url: support.appendingPathComponent("CellBridge/messages.json")),
            transmit: { [weak self] in self?.client.send($0) },
            notify: { [weak self] in self?.notifier.notify(id: $0, title: $1, body: $2) },
            log: { [weak self] in self?.log($0) }
        )
        client.onLog = { [weak self] in self?.log($0) }
        client.onMessage = { [weak self] message in
            self?.log(Self.describe(message))
            self?.calls.handle(message)
            self?.messages.handle(message)
        }
        // Sends that never got an answer cannot be confirmed once the connection is gone.
        client.$state.removeDuplicates().sink { [weak self] state in
            if case .connected = state { return }
            self?.messages.connectionLost()
        }.store(in: &bag)
        messages.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        // Forward state changes of the nested object so the main screen refreshes.
        client.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        calls.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        gateway.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
    }

    /// What will actually be dialed: the typed host, else the detected gateway.
    var effectiveHost: String { host.isEmpty ? (gateway.address ?? "") : host }

    /// Texts can be sent while connected to a host that is the default SMS app.
    var canSendSms: Bool {
        if case .connected(let capabilities) = client.state { return capabilities.contains("sms") }
        return false
    }

    var canConnect: Bool { !effectiveHost.isEmpty && !token.isEmpty }

    func connect() {
        Task { _ = await AVAudioApplication.requestRecordPermission() } // ask now, not in the middle of a call
        notifier.requestPermission()
        keepAlive.start()
        client.connect(host: effectiveHost, token: token.uppercased())
    }

    func disconnect() { client.disconnect() }

    var activeCalls: [ActiveCall] { calls.active }

    func endCall(_ id: UUID) { calls.end(id) }

    var speakerOn: Bool { calls.speaker }

    func toggleSpeaker() { calls.speaker.toggle() }

    private func log(_ text: String) {
        events = Array(([stamp.string(from: Date()) + " " + text] + events).prefix(40))
    }

    private static func describe(_ message: ServerMessage) -> String {
        switch message {
        case .helloAck(_, let capabilities): return "connected, host offers \(capabilities.joined(separator: ", "))"
        case .ring(let callId, _, _): return "ring \(callId.prefix(8))"
        case .ended(let callId, let reason): return "ended \(callId.prefix(8)) \(reason?.rawValue ?? "")"
        case .sms(let id, _, _, _): return "sms \(id)" // never log the sender or the text
        case .smsResult(let clientId, let ok, _): return "sms result \(clientId.prefix(8)) \(ok ? "sent" : "failed")"
        case .error(let code, _): return "error \(code)"
        }
    }
}
